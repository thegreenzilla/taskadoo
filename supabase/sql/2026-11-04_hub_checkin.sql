-- Taskadoo v2.3 – hub check-in (2026-11-04)
-- Run once in Supabase → SQL Editor (staging first). Safe to run again.
-- Jobs booked "report to the hub": the Taskadooer sees the hub, the time, the items and the pay, but NOT the
-- customer (name, mobile, address, map pin, SO number, notes) until they check in at the hub.
-- Check-in: swipe in the Taskadooer app (phone within settings hub_radius_m, default 300 m, of the hub pin),
-- or the business (Mober hub dispatcher) / Taskadoo dispatcher marks them arrived.
-- Opens settings hub_open_min (default 30) minutes before the report time. 1 minute after the report time = late.

alter table public.jobs add column if not exists hub_in_at timestamptz;
alter table public.jobs add column if not exists hub_in_by text not null default '';     -- app | business | staff
alter table public.jobs add column if not exists hub_in_name text not null default '';   -- who did it
alter table public.jobs add column if not exists hub_in_m int;                           -- metres from the hub (app check-in)

-- ───────────────────────── What a Taskadooer may see ─────────────────────────
-- a hub job before check-in, seen by its Taskadooer: customer details blanked out
create or replace function public.job_for_me(j public.jobs) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when j.report_to = 'hub' and j.hub_in_at is null and not public.is_staff() and j.customer_id is distinct from auth.uid()
    then to_jsonb(j) || jsonb_build_object('customer_name', 'Stop ' || coalesce(j.stop_no, 1), 'mobile', '', 'address', '',
      'lat', null, 'lng', null, 'notes', '', 'so_no', '', 'customer_id', null, 'events', '[]'::jsonb, 'locked', true)
    else to_jsonb(j) end
$$;

-- the jobs table itself: a Taskadooer can't read a hub job until check-in (they get the masked copy below instead)
drop policy if exists jobs_read on public.jobs;
create policy jobs_read on public.jobs for select to authenticated
  using (public.is_staff() or customer_id = auth.uid()
    or ((lead_id = auth.uid() or helper_id = auth.uid()) and not (report_to = 'hub' and hub_in_at is null)));

-- my hub jobs that are still locked (masked)
create or replace function public.my_locked_jobs() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.job_for_me(j) order by j.job_date, j.stop_no, j.id), '[]'::jsonb)
  from public.jobs j
  where (j.lead_id = auth.uid() or j.helper_id = auth.uid()) and j.report_to = 'hub' and j.hub_in_at is null
$$;
grant execute on function public.my_locked_jobs() to authenticated;

-- ───────────────────────── Job steps: masked answer, no travelling before check-in ─────────────────────────
-- the existing job_action becomes job_action_core (only callable from inside the database)
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'job_action_core') then
    alter function public.job_action(bigint, text, jsonb) rename to job_action_core;
  end if;
end $$;
revoke all on function public.job_action_core(bigint, text, jsonb) from public, anon, authenticated;

create or replace function public.job_action(p_job bigint, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  select * into j from public.jobs where id = p_job;
  if found and p_action = 'travel' and j.report_to = 'hub' and j.hub_in_at is null then
    raise exception 'Check in at the hub first – swipe on the Check in tab.'; end if;
  perform public.job_action_core(p_job, p_action, p);
  select * into j from public.jobs where id = p_job;
  return public.job_for_me(j);
end $$;
grant execute on function public.job_action(bigint, text, jsonb) to authenticated;

-- taking an open job also answers with the masked copy
create or replace function public.claim_job(p_job bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare j public.jobs; p public.profiles; x public.jobs; jid bigint;
begin
  select * into p from public.profiles where id = auth.uid() and role = 'assembler' and active;
  if not found then raise exception 'Only Taskadooers can take jobs.'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found or public.board_fits(j, p) is null then raise exception 'Sorry, someone else just took this job.'; end if;
  for jid in select id from public.jobs where id = p_job or (j.batch_id is not null and batch_id = j.batch_id) order by stop_no, id loop
    select * into x from public.jobs where id = jid for update;
    if x.id <> p_job and public.board_fits(x, p) is null then continue; end if;
    if x.lead_id is null then
      update public.jobs set lead_id = p.id, lead_name = coalesce(nullif(p.full_name,''), p.email), lead_ok = true, lead_offer_at = now(),
        status = 'assigned', events = public.add_event(events, 'claimed', 'lead') where id = jid returning * into x;
    else
      update public.jobs set helper_id = p.id, helper_name = coalesce(nullif(p.full_name,''), p.email), helper_ok = true, helper_offer_at = now(),
        events = public.add_event(events, 'claimed', 'extra') where id = jid returning * into x;
    end if;
    if x.lead_ok and (x.helper_id is null or x.helper_ok) and (x.crew <= 1 or x.helper_id is not null) then
      update public.jobs set status = 'accepted', open_board = false where id = jid returning * into x;
    end if;
    if jid = p_job then j := x; end if;
  end loop;
  return public.job_for_me(j);
end $$;

-- ───────────────────────── Check-in ─────────────────────────
-- metres between two points (not rounded)
create or replace function public.m_between(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns int language sql immutable as $$
  select case when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null else
    round(6371000 * 2 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2) + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))::int end
$$;

-- shared rules: is the run there, is check-in open yet
create or replace function public.hub_run_first(p_batch uuid) returns public.jobs
language plpgsql stable security definer set search_path = public as $$
declare j public.jobs;
  open_min int := coalesce((select (value->>'hub_open_min')::int from public.settings where key = 'main'), 30);
begin
  select * into j from public.jobs where batch_id = p_batch and report_to = 'hub' and status <> 'cancelled' order by stop_no, id limit 1;
  if not found then raise exception 'Hub run not found.'; end if;
  if now() < public.job_start(j.job_date, j.slot) - make_interval(mins => open_min) then
    raise exception 'Check-in opens at % (% minutes before the report time).',
      to_char((public.job_start(j.job_date, j.slot) - make_interval(mins => open_min)) at time zone 'Asia/Manila', 'FMHH12:MI AM'), open_min;
  end if;
  return j;
end $$;

-- the Taskadooer swipes in the app
create or replace function public.hub_checkin(p_batch uuid, p_lat double precision default null, p_lng double precision default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare j public.jobs; me uuid := auth.uid(); st timestamptz; m int;
  rad int := coalesce((select (value->>'hub_radius_m')::int from public.settings where key = 'main'), 300);
begin
  if public.my_role() <> 'assembler' then raise exception 'Only Taskadooers can check in here.'; end if;
  if not exists (select 1 from public.jobs where batch_id = p_batch and (lead_id = me or helper_id = me) and status <> 'cancelled') then
    raise exception 'This hub run is not yours.'; end if;
  if not exists (select 1 from public.jobs where batch_id = p_batch and ((lead_id = me and lead_ok) or (helper_id = me and helper_ok))) then
    raise exception 'Accept the jobs first.'; end if;
  j := public.hub_run_first(p_batch);
  if j.hub_in_at is not null then return jsonb_build_object('at', j.hub_in_at, 'already', true); end if;
  st := public.job_start(j.job_date, j.slot);
  if j.hub_lat is not null and rad > 0 then
    if p_lat is null or p_lng is null then
      raise exception 'Turn on location so the app can see you are at the hub – or ask the hub dispatcher to check you in.'; end if;
    m := public.m_between(p_lat, p_lng, j.hub_lat, j.hub_lng);
    if m > rad then raise exception 'You are % m from %. Check in when you are at the hub (within % m).', m, j.hub_name, rad; end if;
  end if;
  update public.jobs set hub_in_at = now(), hub_in_by = 'app', hub_in_m = m,
    hub_in_name = coalesce((select nullif(full_name, '') from public.profiles where id = me), 'Taskadooer'),
    events = public.add_event(events, 'hub_in', 'app' || case when now() >= st + interval '1 minute' then ' · late' else '' end)
  where batch_id = p_batch and status <> 'cancelled';
  return jsonb_build_object('at', now(), 'late', now() >= st + interval '1 minute', 'm', m);
end $$;

-- the business (its own hub runs) or a Taskadoo dispatcher marks the Taskadooer arrived
create or replace function public.hub_mark_in(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare j public.jobs; st timestamptz; who text;
begin
  if public.is_staff() then who := 'staff';
  elsif public.my_role() = 'enterprise' and exists (select 1 from public.jobs where batch_id = p_batch and customer_id = auth.uid()) then who := 'business';
  else raise exception 'Not allowed.'; end if;
  j := public.hub_run_first(p_batch);
  if j.hub_in_at is not null then return jsonb_build_object('at', j.hub_in_at, 'already', true); end if;
  if j.lead_id is null then raise exception 'No Taskadooer is booked on this hub run yet.'; end if;
  st := public.job_start(j.job_date, j.slot);
  update public.jobs set hub_in_at = now(), hub_in_by = who, hub_in_name = public.my_name(),
    events = public.add_event(events, 'hub_in', who || case when now() >= st + interval '1 minute' then ' · late' else '' end)
  where batch_id = p_batch and status <> 'cancelled';
  return jsonb_build_object('at', now(), 'late', now() >= st + interval '1 minute');
end $$;

grant execute on function public.hub_checkin(uuid, double precision, double precision), public.hub_mark_in(uuid) to authenticated;
revoke all on function public.hub_run_first(uuid) from public, anon, authenticated;
