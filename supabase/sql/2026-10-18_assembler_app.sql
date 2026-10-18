-- Taskadoo – v1.7: assembler app (online switch, calendar, pause timer, arrival checks, add-ons on site, customer ratings, scores).
-- Paste the whole file into Supabase → SQL Editor → Run. Safe to run more than once. Run AFTER the earlier files.

-- ───────────────────────── Assembler profile ─────────────────────────
alter table public.profiles add column if not exists online boolean not null default false;      -- taking same-day offers
alter table public.profiles add column if not exists online_at timestamptz;                        -- when the switch was last turned on (online counts for that day only)
alter table public.profiles add column if not exists avail jsonb not null default '{}'::jsonb;    -- {week:{mon:{m:'hours'|'off'|'shift',from:'08:00',to:'18:00'},…}, off:['YYYY-MM-DD',…]}
alter table public.profiles add column if not exists skills text[] not null default '{}';
alter table public.profiles add column if not exists radius_km int not null default 10;
alter table public.profiles add column if not exists mober_emp boolean not null default false;    -- Mober employee (rostered shift days get no offers)
grant update (online, online_at, avail, skills, radius_km, mober_emp) on public.profiles to authenticated;

-- people can change their own details, but not their role, status or Mober-employee flag
create or replace function public.guard_profile() returns trigger
language plpgsql set search_path = public as $$
begin
  -- SQL Editor / service connections are not limited
  if current_user not in ('anon','authenticated') then return new; end if;
  if not public.is_admin() or new.id = auth.uid() then
    new.role := old.role;
    new.active := old.active;
    new.email := old.email;
    if not public.is_admin() then new.requested_role := old.requested_role; new.mober_emp := old.mober_emp; end if;
  end if;
  new.id := old.id;
  new.created_at := old.created_at;
  return new;
end $$;

-- Passing the evaluation copies GCash, skills and the Mober-employee flag to the profile
create or replace function public.copy_gcash_on_pass() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'passed' and old.status is distinct from 'passed' then
    update public.profiles set gcash_name = coalesce(new.data->>'gcash_name', gcash_name), gcash_number = coalesce(new.data->>'gcash_number', gcash_number),
      skills = case when jsonb_typeof(new.data->'skills') = 'array' then array(select jsonb_array_elements_text(new.data->'skills')) else skills end,
      mober_emp = coalesce(new.emp_verified, false) or mober_emp
      where id = new.user_id;
  end if;
  return new;
end $$;
-- assemblers who passed before this update
update public.profiles p set
    skills = case when p.skills = '{}' and jsonb_typeof(a.data->'skills') = 'array' then array(select jsonb_array_elements_text(a.data->'skills')) else p.skills end,
    mober_emp = p.mober_emp or coalesce(a.emp_verified, false)
  from public.applications a where a.user_id = p.id and a.status = 'passed';

-- ───────────────────────── New job fields ─────────────────────────
alter table public.jobs add column if not exists paused_at timestamptz;                  -- assembly timer paused since
alter table public.jobs add column if not exists paused_secs int not null default 0;     -- total paused time
alter table public.jobs add column if not exists checks jsonb not null default '[]'::jsonb;   -- arrival box checks ticked
alter table public.jobs add column if not exists addons jsonb not null default '[]'::jsonb;   -- [{id,name,price}] offered on site, approved at sign-off
alter table public.jobs add column if not exists addons_total numeric(10,2) not null default 0;  -- already included in total
alter table public.jobs add column if not exists rating smallint check (rating between 1 and 5);
alter table public.jobs add column if not exists rating_note text not null default '';
alter table public.jobs add column if not exists rated_at timestamptz;

-- default add-on services and rules (only fills in what is missing; Admin changes them in Settings)
update public.settings set value = jsonb_build_object(
    'addons', jsonb_build_array(
      jsonb_build_object('id','anchor','name','Wall anchoring / anti-tip kit','desc','Secure tall units to the wall.','price',350),
      jsonb_build_object('id','haul','name','Old furniture haul-away','desc','Remove and dispose of the piece being replaced.','price',600),
      jsonb_build_object('id','cable','name','Cable management','desc','Route and hide cables behind the unit.','price',250),
      jsonb_build_object('id','clean','name','Extra room cleanup','desc','Vacuum and wipe-down beyond normal box removal.','price',200)),
    'photo_min', 2, 'late_min', 10) || value
  where key = 'main';

-- ───────────────────────── Availability ─────────────────────────
-- Can this assembler take a job on this date and slot?
-- ok | time_off | shift (Mober rostered shift) | day_off (weekly pattern) | outside (outside their hours)
create or replace function public.avail_on(p public.profiles, p_date date, p_slot text default null) returns text
language plpgsql stable set search_path = public as $$
declare d jsonb; t time;
begin
  if p_date is null then return 'ok'; end if;
  if coalesce(p.avail->'off', '[]'::jsonb) ? p_date::text then return 'time_off'; end if;
  d := p.avail->'week'->(lower(to_char(p_date, 'dy')));
  if d is null then return 'ok'; end if;                     -- weekly pattern not set up = any day
  if d->>'m' = 'shift' and p.mober_emp then return 'shift'; end if;
  if d->>'m' in ('off','shift') then return 'day_off'; end if;
  if p_slot is not null and coalesce(d->>'from','') <> '' and coalesce(d->>'to','') <> '' then
    t := (public.job_start(p_date, p_slot) at time zone 'Asia/Manila')::time;
    if t < (d->>'from')::time or t >= (d->>'to')::time then return 'outside'; end if;
  end if;
  return 'ok';
exception when others then return 'ok';
end $$;

-- Dispatcher's list of assemblers: availability, online, rating (replaces the v1 list)
drop function if exists public.assembler_list(date);
drop function if exists public.assembler_list(date, text);
create or replace function public.assembler_list(p_date date default null, p_slot text default null) returns table (
  id uuid, full_name text, mobile text, area text, jobs_that_day int, done_jobs int,
  online boolean, avail text, rating numeric, ratings int, skills text[], mober_emp boolean)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name,''), p.email), p.mobile, p.area,
    (select count(*)::int from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id)
       and j.job_date = p_date and j.status not in ('cancelled')),
    (select count(*)::int from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id) and j.status = 'done'),
    p.online and (p.online_at at time zone 'Asia/Manila')::date = (now() at time zone 'Asia/Manila')::date,
    public.avail_on(p, p_date, p_slot),
    (select round(avg(j.rating), 1) from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id) and j.rating is not null),
    (select count(*)::int from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id) and j.rating is not null),
    p.skills, p.mober_emp
  from public.profiles p
  where p.role = 'assembler' and p.active and public.is_staff()
  order by 2
$$;

-- Assigning: never on a day the assembler took off or a Mober rostered shift
create or replace function public.assign_job(p_job bigint, p_lead uuid, p_helper uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare j public.jobs; ln text := ''; hn text := ''; pr public.profiles; a text;
begin
  if not public.is_staff() then raise exception 'Only dispatchers can assign jobs.'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found then raise exception 'Job not found.'; end if;
  if j.status not in ('new','assigned','accepted') then raise exception 'This job has already started – it can no longer be reassigned.'; end if;
  if p_lead is not null and p_lead = p_helper then raise exception 'Lead and extra assembler must be different people.'; end if;
  if p_lead is null and p_helper is not null then raise exception 'Choose a lead assembler first.'; end if;
  if p_lead is not null then
    select * into pr from public.profiles where id = p_lead and role = 'assembler' and active;
    if not found then raise exception 'The lead must be an active assembler.'; end if;
    ln := coalesce(nullif(pr.full_name,''), pr.email);
    if pr.id is distinct from j.lead_id then
      a := public.avail_on(pr, j.job_date, j.slot);
      if a = 'time_off' then raise exception '% took this day off.', ln; end if;
      if a = 'shift' then raise exception '% has a Mober shift on this day.', ln; end if;
    end if;
  end if;
  if p_helper is not null then
    select * into pr from public.profiles where id = p_helper and role = 'assembler' and active;
    if not found then raise exception 'The extra assembler must be an active assembler.'; end if;
    hn := coalesce(nullif(pr.full_name,''), pr.email);
    if pr.id is distinct from j.helper_id then
      a := public.avail_on(pr, j.job_date, j.slot);
      if a = 'time_off' then raise exception '% took this day off.', hn; end if;
      if a = 'shift' then raise exception '% has a Mober shift on this day.', hn; end if;
    end if;
  end if;
  update public.jobs set
    lead_id = p_lead, helper_id = p_helper, lead_name = coalesce(ln,''), helper_name = coalesce(hn,''),
    lead_ok = case when lead_id is not distinct from p_lead then lead_ok else false end,
    helper_ok = case when helper_id is not distinct from p_helper then helper_ok else false end,
    status = case when p_lead is null then 'new' else 'assigned' end,
    events = public.add_event(events, 'assigned', trim(coalesce(ln,'') || case when hn <> '' then ' + ' || hn else '' end))
  where id = p_job;
  -- already-accepted people keep their acceptance; recheck whether the crew is complete
  update public.jobs set status = 'accepted'
    where id = p_job and lead_id is not null and lead_ok
      and (helper_id is null or helper_ok) and (crew <= 1 or helper_id is not null);
end $$;

-- ───────────────────────── Assembler actions (adds pause, resume, add-ons, arrival checks) ─────────────────────────
create or replace function public.job_action(p_job bigint, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  j public.jobs; me uuid := auth.uid(); is_lead boolean; is_helper boolean; path text;
  cfg jsonb := coalesce((select value from public.settings where key = 'main'), '{}'::jsonb); fee numeric;
  v_addons jsonb := '[]'::jsonb; v_sum numeric := 0; x text; a jsonb;
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
      checks = case when p_action = 'start' and jsonb_typeof(p->'checks') = 'array' then p->'checks' else checks end,
      -- finishing while paused: the paused minutes don't count as work
      paused_secs = case when p_action = 'finish' and paused_at is not null then paused_secs + extract(epoch from now() - paused_at)::int else paused_secs end,
      paused_at = case when p_action = 'finish' then null else paused_at end,
      finished_at = case when p_action = 'finish' then now() else finished_at end,
      events = public.add_event(events, p_action)
    where id = p_job returning * into j;

  elsif p_action in ('pause','resume') then
    if not is_lead then raise exception 'Only the lead assembler can pause the timer.'; end if;
    if j.status <> 'in_progress' then raise exception 'The timer only runs during assembly.'; end if;
    if p_action = 'pause' and j.paused_at is not null then raise exception 'The timer is already paused.'; end if;
    if p_action = 'resume' and j.paused_at is null then raise exception 'The timer is already running.'; end if;
    update public.jobs set
      paused_secs = case when p_action = 'resume' then paused_secs + extract(epoch from now() - paused_at)::int else paused_secs end,
      paused_at = case when p_action = 'pause' then now() else null end,
      events = public.add_event(events, p_action, left(coalesce(p->>'reason',''),200))
    where id = p_job returning * into j;

  elsif p_action = 'addons' then
    -- p: {ids:['anchor',…]} – prices come from Settings; the customer approves them when signing
    if not is_lead then raise exception 'Only the lead assembler can add services.'; end if;
    if j.status not in ('in_progress','finished') then raise exception 'Add-ons can be added during or right after the assembly.'; end if;
    for x in select distinct jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) loop
      select e into a from jsonb_array_elements(coalesce(cfg->'addons','[]'::jsonb)) e where e->>'id' = x and coalesce((e->>'off')::boolean, false) = false;
      if a is null then raise exception 'Unknown add-on service.'; end if;
      v_addons := v_addons || jsonb_build_array(jsonb_build_object('id', a->>'id', 'name', a->>'name', 'price', greatest(coalesce((a->>'price')::numeric, 0), 0)));
      v_sum := v_sum + greatest(coalesce((a->>'price')::numeric, 0), 0);
    end loop;
    update public.jobs set total = total - addons_total + v_sum, addons = v_addons, addons_total = v_sum,
      events = public.add_event(events, 'addons', coalesce((select string_agg(e->>'name', ', ') from jsonb_array_elements(v_addons) e), 'none'))
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

-- ───────────────────────── Customer rating ─────────────────────────
-- Seen only by Taskadoo staff and the assemblers on the job (never shown to other customers)
create or replace function public.rate_job(p_job bigint, p_stars int, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  select * into j from public.jobs where id = p_job for update;
  if not found or j.customer_id is distinct from auth.uid() then raise exception 'Booking not found.'; end if;
  if j.status <> 'done' then raise exception 'You can rate the job once it is completed.'; end if;
  if j.rating is not null then raise exception 'You already rated this job. Thank you!'; end if;
  if now() > j.completed_at + interval '14 days' then raise exception 'Ratings close 14 days after the job.'; end if;
  if p_stars is null or p_stars < 1 or p_stars > 5 then raise exception 'Choose 1 to 5 stars.'; end if;
  update public.jobs set rating = p_stars, rating_note = left(trim(coalesce(p_note,'')),1000), rated_at = now(),
    events = public.add_event(events, 'rated', p_stars || ' star(s)') where id = p_job;
end $$;

-- ───────────────────────── Assembler scores ─────────────────────────
-- For the assembler's own Profile and for staff: rating, acceptance, on-time arrival, first-visit completion, recent comments
create or replace function public.assembler_stats(p_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := coalesce(p_id, auth.uid()); late int; r jsonb;
begin
  if uid is distinct from auth.uid() and not public.is_staff() then raise exception 'Not allowed.'; end if;
  late := coalesce((select (value->>'late_min')::int from public.settings where key = 'main'), 10);
  with mine as (select * from public.jobs j where j.lead_id = uid or j.helper_id = uid),
  ev as (select e->>'action' act from public.jobs j, jsonb_array_elements(j.events) e
         where e->>'by' = uid::text and e->>'action' in ('accepted','declined'))
  select jsonb_build_object(
    'done', (select count(*) from mine where status = 'done'),
    'rating', (select round(avg(rating), 1) from mine where rating is not null),
    'ratings', (select count(*) from mine where rating is not null),
    'accepted', (select count(*) from ev where act = 'accepted'),
    'declined', (select count(*) from ev where act = 'declined'),
    'arrived', (select count(*) from mine where arrived_at is not null),
    'on_time', (select count(*) from mine where arrived_at is not null
                  and arrived_at <= public.job_start(job_date, slot) + make_interval(mins => late)),
    'closed', (select count(*) from mine where status in ('done','failed_visit') and revisit_of is null),
    'first_visit', (select count(*) from mine where status = 'done' and revisit_of is null and issue = ''
                      and resolution not in ('revisit','partial','full')),
    'comments', coalesce((select jsonb_agg(c) from (select jsonb_build_object('stars', rating, 'note', rating_note, 'at', rated_at) c
                  from mine where rating is not null order by rated_at desc limit 10) z), '[]'::jsonb)
  ) into r;
  return r;
end $$;

revoke all on function public.rate_job(bigint,int,text), public.assembler_stats(uuid), public.assembler_list(date,text),
  public.avail_on(public.profiles,date,text) from public, anon;
grant execute on function public.rate_job(bigint,int,text), public.assembler_stats(uuid), public.assembler_list(date,text),
  public.avail_on(public.profiles,date,text) to authenticated;
