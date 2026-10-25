-- Taskadoo v1.9 – Dispatch Center: suggested Taskadooers with the facts behind their score, and no double-booking.
-- Safe to run more than once. Paste the whole file into Supabase → SQL Editor → Run.

-- Settings: travel time kept free between two jobs of the same Taskadooer, and when an unfilled job "needs you"
update public.settings set value = value || jsonb_build_object('travel_min', 60) where key = 'main' and not value ? 'travel_min';
update public.settings set value = value || jsonb_build_object('urgent_hours', 3) where key = 'main' and not value ? 'urgent_hours';

-- How long a job takes (minutes from the items, at least an hour)
create or replace function public.job_minutes(j public.jobs) returns int
language sql stable set search_path = public as $$
  select greatest(60, coalesce((select sum(coalesce((it->>'minutes')::int, 60) * coalesce((it->>'qty')::int, 1))::int
    from jsonb_array_elements(coalesce(j.items, '[]'::jsonb)) it), 60))
$$;

-- Does this Taskadooer already have a job that overlaps this one (job time + travel)? Returns e.g. "TD-2610-0024 at 1:00 PM", else null.
create or replace function public.job_clash(p_uid uuid, p_job public.jobs) returns text
language plpgsql stable security definer set search_path = public as $$
declare gap int := coalesce((select (value->>'travel_min')::int from public.settings where key = 'main'), 60);
  s1 timestamptz; e1 timestamptz; r text;
begin
  if p_uid is null or p_job.job_date is null then return null; end if;
  s1 := public.job_start(p_job.job_date, p_job.slot); e1 := s1 + make_interval(mins => public.job_minutes(p_job) + gap);
  select o.code || ' at ' || o.slot into r from public.jobs o
   where o.id <> coalesce(p_job.id, -1) and (o.lead_id = p_uid or o.helper_id = p_uid) and o.job_date = p_job.job_date
     and o.status in ('assigned','accepted','travelling','arrived','in_progress')
     and public.job_start(o.job_date, o.slot) < e1
     and s1 < public.job_start(o.job_date, o.slot) + make_interval(mins => public.job_minutes(o) + gap)
   order by o.slot limit 1;
  return r;
end $$;

-- Dispatch: every active Taskadooer with what the suggestion score needs for this job
create or replace function public.job_candidates(p_job bigint) returns table (
  id uuid, full_name text, mobile text, area text, online boolean, avail text, rating numeric, ratings int, skills text[], mober_emp boolean,
  km double precision, radius_km int, has_home boolean, done_jobs int, jobs_week int, years text, eval_avg numeric, busy text)
language plpgsql stable security definer set search_path = public as $$
declare j public.jobs; wk date;
begin
  if not public.is_staff() then raise exception 'Only dispatchers can see this.'; end if;
  select * into j from public.jobs where jobs.id = p_job;
  if not found then raise exception 'Job not found.'; end if;
  wk := date_trunc('week', j.job_date)::date;   -- Monday of the job's week
  return query
  select p.id, coalesce(nullif(p.full_name,''), p.email), p.mobile, p.area,
    p.online and (p.online_at at time zone 'Asia/Manila')::date = (now() at time zone 'Asia/Manila')::date,
    public.avail_on(p, j.job_date, j.slot),
    (select round(avg(x.rating), 1) from public.jobs x where (x.lead_id = p.id or x.helper_id = p.id) and x.rating is not null),
    (select count(*)::int from public.jobs x where (x.lead_id = p.id or x.helper_id = p.id) and x.rating is not null),
    p.skills, p.mober_emp, public.km_between(p.home_lat, p.home_lng, j.lat, j.lng), p.radius_km, p.home_lat is not null,
    (select count(*)::int from public.jobs x where (x.lead_id = p.id or x.helper_id = p.id) and x.status = 'done'),
    (select count(*)::int from public.jobs x where (x.lead_id = p.id or x.helper_id = p.id) and x.id <> j.id
       and x.job_date >= wk and x.job_date < wk + 7 and x.status not in ('cancelled','new')),
    coalesce(a.data->>'years', ''),
    (select round(avg(v::numeric), 1) from jsonb_each_text(coalesce(a.score, '{}'::jsonb)) e(k, v) where v ~ '^[0-9.]+$'),
    case when p.id in (j.lead_id, j.helper_id) then null else public.job_clash(p.id, j) end
  from public.profiles p left join public.applications a on a.user_id = p.id
  where p.role = 'assembler' and p.active
  order by 2;
end $$;

-- assign_job: also refuses someone who already has a job at that time
create or replace function public.assign_job(p_job bigint, p_lead uuid, p_helper uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare j public.jobs; ln text := ''; hn text := ''; pr public.profiles; a text; c text;
begin
  if not public.is_staff() then raise exception 'Only dispatchers can assign jobs.'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found then raise exception 'Job not found.'; end if;
  if j.status not in ('new','assigned','accepted') then raise exception 'This job has already started – it can no longer be reassigned.'; end if;
  if p_lead is not null and p_lead = p_helper then raise exception 'Lead and extra Taskadooer must be different people.'; end if;
  if p_lead is null and p_helper is not null then raise exception 'Choose a lead Taskadooer first.'; end if;
  if p_lead is not null then
    select * into pr from public.profiles where id = p_lead and role = 'assembler' and active;
    if not found then raise exception 'The lead must be an active Taskadooer.'; end if;
    ln := coalesce(nullif(pr.full_name,''), pr.email);
    if pr.id is distinct from j.lead_id and pr.id is distinct from j.helper_id then
      a := public.avail_on(pr, j.job_date, j.slot);
      if a = 'time_off' then raise exception '% took this day off.', ln; end if;
      if a = 'shift' then raise exception '% has a Mober shift on this day.', ln; end if;
      c := public.job_clash(pr.id, j);
      if c is not null then raise exception '% is busy then (%).', ln, c; end if;
    end if;
  end if;
  if p_helper is not null then
    select * into pr from public.profiles where id = p_helper and role = 'assembler' and active;
    if not found then raise exception 'The extra Taskadooer must be an active Taskadooer.'; end if;
    hn := coalesce(nullif(pr.full_name,''), pr.email);
    if pr.id is distinct from j.helper_id and pr.id is distinct from j.lead_id then
      a := public.avail_on(pr, j.job_date, j.slot);
      if a = 'time_off' then raise exception '% took this day off.', hn; end if;
      if a = 'shift' then raise exception '% has a Mober shift on this day.', hn; end if;
      c := public.job_clash(pr.id, j);
      if c is not null then raise exception '% is busy then (%).', hn, c; end if;
    end if;
  end if;
  update public.jobs set
    lead_offer_at = case when lead_id is not distinct from p_lead then lead_offer_at else now() end,
    helper_offer_at = case when helper_id is not distinct from p_helper then helper_offer_at else now() end,
    lead_id = p_lead, helper_id = p_helper, lead_name = coalesce(ln,''), helper_name = coalesce(hn,''),
    lead_ok = case when lead_id is not distinct from p_lead then lead_ok else false end,
    helper_ok = case when helper_id is not distinct from p_helper then helper_ok else false end,
    status = case when p_lead is null then 'new' else 'assigned' end,
    events = public.add_event(events, 'assigned', trim(coalesce(ln,'') || case when hn <> '' then ' + ' || hn else '' end))
  where id = p_job;
  update public.jobs set status = 'accepted', open_board = false
    where id = p_job and lead_id is not null and lead_ok
      and (helper_id is null or helper_ok) and (crew <= 1 or helper_id is not null);
end $$;

-- Open job board: a Taskadooer who is busy at that time doesn't see the job
create or replace function public.board_fits(j public.jobs, p public.profiles) returns double precision
language plpgsql stable security definer set search_path = public as $$
declare km double precision; lim double precision;
  match_km int := coalesce((select (value->>'match_km')::int from public.settings where key = 'main'), 30);
begin
  if not j.open_board or j.lead_id = p.id or j.helper_id = p.id then return null; end if;
  if not (j.status = 'new' or (j.status = 'assigned' and j.crew > 1 and j.helper_id is null)) then return null; end if;
  if public.avail_on(p, j.job_date, j.slot) <> 'ok' then return null; end if;
  if j.job_date = (now() at time zone 'Asia/Manila')::date and not (p.online and (p.online_at at time zone 'Asia/Manila')::date = j.job_date) then return null; end if;
  if public.job_clash(p.id, j) is not null then return null; end if;
  km := public.km_between(p.home_lat, p.home_lng, j.lat, j.lng);
  lim := least(match_km, coalesce(nullif(p.radius_km, 0), match_km));
  if km is null then return case when p.area <> '' and p.area = j.area then -1 else null end; end if;
  return case when km <= lim then km else null end;
end $$;

revoke all on function public.job_minutes(public.jobs), public.job_clash(uuid, public.jobs), public.job_candidates(bigint) from public, anon;
grant execute on function public.job_candidates(bigint) to authenticated;
