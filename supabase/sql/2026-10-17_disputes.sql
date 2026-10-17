-- Taskadoo – v1.2: problems after the job, "customer won't sign", "nobody home", cancellation fee, payout holds,
-- and no new bookings while a customer has an unpaid job.
-- Paste the whole file into Supabase → SQL Editor → Run. Safe to run more than once. Run AFTER 2026-10-16_phase1.sql.

-- ───────────────────────── New job fields ─────────────────────────
alter table public.jobs add column if not exists arrived_at timestamptz;
alter table public.jobs add column if not exists issue text not null default '';            -- '', no_sign, nobody_home
alter table public.jobs add column if not exists issue_note text not null default '';
alter table public.jobs add column if not exists fee_kept numeric(10,2) not null default 0;  -- late-cancel / failed-visit fee
alter table public.jobs add column if not exists dispute text not null default '';          -- '', open, resolved
alter table public.jobs add column if not exists dispute_note text not null default '';
alter table public.jobs add column if not exists dispute_at timestamptz;
alter table public.jobs add column if not exists resolution text not null default '';       -- accepted, revisit, partial, full, rejected
alter table public.jobs add column if not exists resolution_note text not null default '';
alter table public.jobs add column if not exists refund numeric(10,2) not null default 0;
alter table public.jobs add column if not exists resolved_at timestamptz;
alter table public.jobs add column if not exists dispute_hours int not null default 24;     -- snapshot of the rule at booking
alter table public.jobs add column if not exists revisit_of bigint references public.jobs(id) on delete set null;

-- new statuses: issue (on site, customer won't sign – Taskadoo decides), failed_visit (nobody home – closed with a fee)
alter table public.jobs drop constraint if exists jobs_status_check;
alter table public.jobs add constraint jobs_status_check check (status in
  ('new','assigned','accepted','travelling','arrived','in_progress','finished','issue','done','failed_visit','cancelled'));

-- default rules (only fills in what is missing; Admin changes them in Settings)
update public.settings set value = jsonb_build_object(
    'dispute_hours', 24, 'cancel_free_hours', 24, 'cancel_fee', 300,
    'fail_pct', 30, 'fail_max', 500, 'nobody_wait_min', 15) || value
  where key = 'main';

-- ───────────────────────── Helpers ─────────────────────────

-- Start of the booked slot (Manila time). Slots look like "8:00 AM"; anything else counts as 8:00 AM.
create or replace function public.job_start(p_date date, p_slot text) returns timestamptz
language plpgsql stable as $$
begin
  return (to_timestamp(p_date::text || ' ' || upper(trim(p_slot)), 'YYYY-MM-DD HH12:MI AM')::timestamp) at time zone 'Asia/Manila';
exception when others then
  return (p_date::timestamp + interval '8 hours') at time zone 'Asia/Manila';
end $$;

-- What the customer owes for a job (after refunds / fees)
create or replace function public.job_due(j public.jobs) returns numeric
language sql stable as $$
  select case when j.status = 'done' then greatest(j.total - j.refund, 0)
              when j.status in ('failed_visit','cancelled') then j.fee_kept
              else 0 end
$$;

-- No new booking while the customer has an unpaid job whose problem window has passed (businesses are billed monthly)
create or replace function public.block_unpaid() returns trigger
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if new.customer_id is null or new.source <> 'customer' then return new; end if;
  select code into c from public.jobs j
   where j.customer_id = new.customer_id and not j.paid and public.job_due(j) > 0 and j.dispute <> 'open'
     and coalesce(j.completed_at, j.updated_at) + make_interval(hours => j.dispute_hours) < now()
   order by j.id limit 1;
  if c is not null then
    raise exception 'Please settle your payment for % first. Contact Taskadoo if you already paid.', c;
  end if;
  new.dispute_hours := coalesce((select (value->>'dispute_hours')::int from public.settings where key = 'main'), 24);
  return new;
end $$;
drop trigger if exists jobs_block_unpaid on public.jobs;
create trigger jobs_block_unpaid before insert on public.jobs for each row execute function public.block_unpaid();

-- ───────────────────────── Cancelling (with late fee) ─────────────────────────
create or replace function public.cancel_booking(p_job bigint, p_reason text default '') returns void
language plpgsql security definer set search_path = public as $$
declare
  j public.jobs; cfg jsonb := coalesce((select value from public.settings where key = 'main'), '{}'::jsonb); fee numeric := 0;
begin
  select * into j from public.jobs where id = p_job for update;
  if not found then raise exception 'Booking not found.'; end if;
  if public.is_staff() then
    if j.status in ('done','cancelled','failed_visit') then raise exception 'This job is already closed.'; end if;
  elsif j.customer_id = auth.uid() then
    if j.status not in ('new','assigned','accepted') then raise exception 'The assembler is already on the way – please call us to cancel.'; end if;
    if now() > public.job_start(j.job_date, j.slot) - make_interval(hours => coalesce((cfg->>'cancel_free_hours')::int, 24)) then
      fee := least(j.total, coalesce((cfg->>'cancel_fee')::numeric, 300));
    end if;
  else raise exception 'Not allowed.'; end if;
  update public.jobs set status = 'cancelled', fee_kept = fee,
    events = public.add_event(events, 'cancelled', trim(left(coalesce(p_reason,''),300) || case when fee > 0 then ' (late cancellation fee ' || fee || ')' else '' end))
    where id = p_job;
end $$;

-- What cancelling now would cost (shown to the customer before they confirm)
create or replace function public.cancel_fee(p_job bigint) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare j public.jobs; cfg jsonb := coalesce((select value from public.settings where key = 'main'), '{}'::jsonb);
begin
  select * into j from public.jobs where id = p_job and (customer_id = auth.uid() or public.is_staff());
  if not found or public.is_staff() then return 0; end if;
  if now() > public.job_start(j.job_date, j.slot) - make_interval(hours => coalesce((cfg->>'cancel_free_hours')::int, 24)) then
    return least(j.total, coalesce((cfg->>'cancel_fee')::numeric, 300));
  end if;
  return 0;
end $$;

-- ───────────────────────── Assembler actions (adds no_sign and nobody_home) ─────────────────────────
create or replace function public.job_action(p_job bigint, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  j public.jobs; me uuid := auth.uid(); is_lead boolean; is_helper boolean; path text;
  cfg jsonb := coalesce((select value from public.settings where key = 'main'), '{}'::jsonb); fee numeric;
begin
  if public.my_role() <> 'assembler' then raise exception 'Only assemblers can do this.'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found then raise exception 'Job not found.'; end if;
  is_lead := coalesce(j.lead_id = me, false); is_helper := coalesce(j.helper_id = me, false);
  if not (is_lead or is_helper) then raise exception 'This job is not assigned to you.'; end if;
  p := coalesce(p, '{}'::jsonb);

  if p_action = 'accept' then
    if j.status not in ('assigned','accepted') then raise exception 'This offer is no longer open.'; end if;
    update public.jobs set lead_ok = lead_ok or is_lead, helper_ok = helper_ok or is_helper,
      events = public.add_event(events, 'accepted') where id = p_job returning * into j;
    if j.lead_ok and (j.helper_id is null or j.helper_ok) and (j.crew <= 1 or j.helper_id is not null) then
      update public.jobs set status = 'accepted' where id = p_job returning * into j;
    end if;

  elsif p_action = 'decline' then
    if j.status not in ('assigned','accepted') then raise exception 'This job has already started – please call dispatch.'; end if;
    if is_lead then
      update public.jobs set lead_id = null, lead_name = '', lead_ok = false, status = 'new',
        events = public.add_event(events, 'declined', left(coalesce(p->>'reason',''),300)) where id = p_job returning * into j;
    else
      update public.jobs set helper_id = null, helper_name = '', helper_ok = false,
        status = case when lead_id is null then 'new' else 'assigned' end,
        events = public.add_event(events, 'declined', left(coalesce(p->>'reason',''),300)) where id = p_job returning * into j;
    end if;

  elsif p_action in ('travel','arrive','start','finish') then
    if not is_lead then raise exception 'Only the lead assembler can update the job steps.'; end if;
    if p_action = 'travel' and j.status <> 'accepted' then raise exception 'The job must be accepted first.'; end if;
    if p_action = 'arrive' and j.status <> 'travelling' then raise exception 'Tap "Start travelling" first.'; end if;
    if p_action = 'start'  and j.status <> 'arrived' then raise exception 'Tap "I''ve arrived" first.'; end if;
    if p_action = 'finish' and j.status <> 'in_progress' then raise exception 'Start the assembly first.'; end if;
    if p_action = 'travel' and j.job_date > (now() at time zone 'Asia/Manila')::date then
      raise exception 'This job is not today yet.'; end if;
    update public.jobs set
      status = case p_action when 'travel' then 'travelling' when 'arrive' then 'arrived'
                             when 'start' then 'in_progress' else 'finished' end,
      arrived_at = case when p_action = 'arrive' then now() else arrived_at end,
      started_at = case when p_action = 'start' then now() else started_at end,
      finished_at = case when p_action = 'finish' then now() else finished_at end,
      events = public.add_event(events, p_action)
    where id = p_job returning * into j;

  elsif p_action = 'photo' then
    path := coalesce(p->>'path','');
    if j.status not in ('arrived','in_progress','finished') then raise exception 'Photos can be added once you have arrived.'; end if;
    if path !~ ('^' || p_job || '/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$') then raise exception 'Bad photo path.'; end if;
    if jsonb_array_length(j.photos) >= 20 then raise exception 'Maximum of 20 photos per job.'; end if;
    update public.jobs set photos = photos || jsonb_build_array(jsonb_build_object(
        'path', path, 'label', left(coalesce(p->>'label',''),60), 'at', now(), 'by', me))
      where id = p_job returning * into j;

  elsif p_action = 'complete' then
    if not is_lead then raise exception 'Only the lead assembler can complete the job.'; end if;
    if j.status <> 'finished' then raise exception 'Finish the assembly first.'; end if;
    if jsonb_array_length(j.photos) = 0 then raise exception 'Add at least one photo of the finished work.'; end if;
    path := coalesce(p->>'signature','');
    if path !~ ('^' || p_job || '/[A-Za-z0-9_-]+\.png$') then raise exception 'The customer must sign first.'; end if;
    if length(trim(coalesce(p->>'signed_name',''))) < 2 then raise exception 'Enter the name of the person signing.'; end if;
    update public.jobs set status = 'done', completed_at = now(), signature = path,
      signed_name = left(trim(p->>'signed_name'),120), events = public.add_event(events, 'completed')
    where id = p_job returning * into j;

  elsif p_action = 'no_sign' then
    if not is_lead then raise exception 'Only the lead assembler can report this.'; end if;
    if j.status <> 'finished' then raise exception 'Finish the assembly first.'; end if;
    if jsonb_array_length(j.photos) = 0 then raise exception 'Add photos of the finished work first.'; end if;
    if length(trim(coalesce(p->>'note',''))) < 5 then raise exception 'Say what the customer told you.'; end if;
    update public.jobs set status = 'issue', issue = 'no_sign', issue_note = left(trim(p->>'note'),1000), finished_at = coalesce(finished_at, now()),
      events = public.add_event(events, 'no_sign', left(trim(p->>'note'),300)) where id = p_job returning * into j;

  elsif p_action = 'nobody_home' then
    if not is_lead then raise exception 'Only the lead assembler can report this.'; end if;
    if j.status <> 'arrived' then raise exception 'Tap "I''ve arrived" first.'; end if;
    if now() < j.arrived_at + make_interval(mins => coalesce((cfg->>'nobody_wait_min')::int, 15)) then
      raise exception 'Please wait % minutes after arriving and try calling the customer.', coalesce((cfg->>'nobody_wait_min')::int, 15); end if;
    if jsonb_array_length(j.photos) = 0 then raise exception 'Take a photo of the door or building first.'; end if;
    fee := least(j.total * coalesce((cfg->>'fail_pct')::numeric, 30) / 100, coalesce((cfg->>'fail_max')::numeric, 500));
    update public.jobs set status = 'failed_visit', issue = 'nobody_home', issue_note = left(trim(coalesce(p->>'note','')),1000),
      fee_kept = round(fee, 2), completed_at = now(),
      events = public.add_event(events, 'nobody_home', left(trim(coalesce(p->>'note','')),300)) where id = p_job returning * into j;

  else
    raise exception 'Unknown action.';
  end if;
  return to_jsonb(j);
end $$;

-- ───────────────────────── Customer: report a problem ─────────────────────────
create or replace function public.report_problem(p_job bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  select * into j from public.jobs where id = p_job for update;
  if not found or (j.customer_id is distinct from auth.uid()) then raise exception 'Booking not found.'; end if;
  if j.status <> 'done' then raise exception 'You can report a problem once the job is completed.'; end if;
  if j.dispute <> '' then raise exception 'A problem was already reported for this job.'; end if;
  if now() > j.completed_at + make_interval(hours => j.dispute_hours) then
    raise exception 'The % hours to report a problem have passed. Please contact Taskadoo.', j.dispute_hours; end if;
  if length(trim(coalesce(p_note,''))) < 5 then raise exception 'Tell us what is wrong.'; end if;
  update public.jobs set dispute = 'open', dispute_note = left(trim(p_note),2000), dispute_at = now(),
    events = public.add_event(events, 'dispute', left(trim(p_note),300)) where id = p_job;
end $$;

-- ───────────────────────── Taskadoo decides (Dispatcher / Admin) ─────────────────────────
-- outcome: accepted (work is fine / customer confirmed), revisit (free visit to fix), partial (refund p_amount), full (refund all), rejected (dispute rejected)
create or replace function public.resolve_job(p_job bigint, p_outcome text, p_amount numeric default 0, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare j public.jobs; v_refund numeric := 0; nid bigint;
begin
  if not public.is_staff() then raise exception 'Only dispatchers and Admin can decide this.'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found then raise exception 'Job not found.'; end if;
  if not (j.status = 'issue' or j.dispute = 'open') then raise exception 'Nothing to decide on this job.'; end if;
  if p_outcome not in ('accepted','revisit','partial','full','rejected') then raise exception 'Choose an outcome.'; end if;
  if p_outcome = 'rejected' and j.status = 'issue' then p_outcome := 'accepted'; end if;
  if p_outcome = 'partial' then
    if coalesce(p_amount,0) <= 0 or p_amount >= j.total then raise exception 'Enter a refund between 1 and %.', j.total - 1; end if;
    v_refund := round(p_amount, 2);
  elsif p_outcome = 'full' then v_refund := j.total;
  end if;
  if length(trim(coalesce(p_note,''))) < 3 then raise exception 'Write a short note on what was decided.'; end if;
  if p_outcome = 'revisit' then
    insert into public.jobs (source, customer_id, company, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total,
                             commission_pct, lead_pct, revisit_of, events)
    values ('staff', j.customer_id, j.company, j.customer_name, j.mobile, j.address, j.area,
            greatest((now() at time zone 'Asia/Manila')::date + 1, j.job_date), j.slot,
            'Free re-visit to fix ' || j.code || '. ' || left(trim(p_note),500), j.items, j.crew, 0, j.commission_pct, j.lead_pct, j.id,
            public.add_event('[]'::jsonb, 'booked', 'Re-visit for ' || j.code))
    returning id into nid;
    update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(nid::text, 4, '0') where id = nid;
  end if;
  update public.jobs set
    status = case when status = 'issue' then 'done' else status end,
    completed_at = case when status = 'issue' then coalesce(finished_at, now()) else completed_at end,
    signed_name = case when status = 'issue' and signed_name = '' then 'Confirmed by Taskadoo' else signed_name end,
    dispute = case when dispute = 'open' then 'resolved' else dispute end,
    resolution = p_outcome, resolution_note = left(trim(p_note),1000), refund = v_refund, resolved_at = now(),
    events = public.add_event(events, 'resolved', p_outcome || case when v_refund > 0 then ' (refund ' || v_refund || ')' else '' end || ' – ' || left(trim(p_note),200))
  where id = p_job returning * into j;
  return jsonb_build_object('revisit_id', nid);
end $$;

-- Payments: also for failed-visit and late-cancellation fees
create or replace function public.mark_paid(p_job bigint, p_paid boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only Admin can record payments.'; end if;
  update public.jobs j set paid = p_paid, paid_at = case when p_paid then now() end,
    events = public.add_event(events, case when p_paid then 'paid' else 'unpaid' end)
  where id = p_job and public.job_due(j) > 0;
  if not found then raise exception 'Nothing is due on this job.'; end if;
end $$;

revoke all on function public.report_problem(bigint,text), public.resolve_job(bigint,text,numeric,text), public.cancel_fee(bigint),
  public.block_unpaid() from public, anon;
grant execute on function public.report_problem(bigint,text), public.resolve_job(bigint,text,numeric,text), public.cancel_fee(bigint),
  public.job_due(public.jobs), public.job_start(date,text) to authenticated;
