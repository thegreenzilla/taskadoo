-- Taskadoo v2.2 – Business portal for Mober and other business accounts:
-- business rate (% off) and failed-visit fee per business, booking many jobs at once (one per SO),
-- "Report to" the customer or a hub (hub runs share a batch), problems reported by the business.
-- Safe to run more than once. Paste the whole file into Supabase → SQL Editor → Run.

-- ───────────────────────── Business terms on the account ─────────────────────────
alter table public.profiles add column if not exists biz_rate_pct numeric(5,2) not null default 0;     -- % off the catalogue
alter table public.profiles add column if not exists biz_fail_fee numeric(12,2) not null default 500;  -- failed visit (customer not home / cancels at the door)
alter table public.profiles add column if not exists biz_hubs jsonb not null default '[]'::jsonb;      -- [{id, name, address, lat, lng}]
grant update (biz_rate_pct, biz_fail_fee, biz_hubs) on public.profiles to authenticated;

-- Only Admin can change a business's rate and failed-visit fee
create or replace function public.guard_profile() returns trigger
language plpgsql set search_path = public as $$
begin
  -- SQL Editor / service connections are not limited
  if current_user not in ('anon','authenticated') then return new; end if;
  if not public.is_admin() or new.id = auth.uid() then
    new.role := old.role;
    new.active := old.active;
    new.email := old.email;
    if not public.is_admin() then
      new.requested_role := old.requested_role; new.mober_emp := old.mober_emp;
      new.biz_rate_pct := old.biz_rate_pct; new.biz_fail_fee := old.biz_fail_fee;
    end if;
  end if;
  new.id := old.id;
  new.created_at := old.created_at;
  return new;
end $$;

-- ───────────────────────── Business job details ─────────────────────────
alter table public.jobs add column if not exists so_no text not null default '';           -- the business's sales order number
alter table public.jobs add column if not exists delivered_on date;
alter table public.jobs add column if not exists report_to text not null default 'customer' check (report_to in ('customer','hub'));
alter table public.jobs add column if not exists hub_name text not null default '';
alter table public.jobs add column if not exists hub_address text not null default '';
alter table public.jobs add column if not exists hub_lat double precision;
alter table public.jobs add column if not exists hub_lng double precision;
alter table public.jobs add column if not exists batch_id uuid;                             -- hub run: these jobs go together with the same Taskadooers
alter table public.jobs add column if not exists stop_no int;
alter table public.jobs add column if not exists rate_pct numeric(5,2) not null default 0;   -- business discount used for this job
alter table public.jobs add column if not exists list_total numeric(12,2);                   -- catalogue total before the discount
create index if not exists jobs_batch_idx on public.jobs(batch_id);

update public.settings set value = value || jsonb_build_object('biz_dispute_days', 7) where key = 'main' and not value ? 'biz_dispute_days';

-- Business bookings get the business's rate (also bookings made from the catalogue)
create or replace function public.apply_biz_rate() returns trigger
language plpgsql security definer set search_path = public as $$
declare r numeric;
begin
  if new.source = 'enterprise' and new.customer_id is not null and new.revisit_of is null then
    select biz_rate_pct into r from public.profiles where id = new.customer_id;
    new.list_total := new.total;
    if coalesce(r, 0) > 0 then
      new.rate_pct := least(r, 90);
      new.total := round(new.total * (1 - least(r, 90) / 100), 2);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists jobs_biz_rate on public.jobs;
create trigger jobs_biz_rate before insert on public.jobs for each row execute function public.apply_biz_rate();

-- A business pays its own failed-visit fee (default ₱500)
create or replace function public.biz_fail_fee() returns trigger
language plpgsql security definer set search_path = public as $$
declare f numeric;
begin
  if new.status = 'failed_visit' and old.status is distinct from 'failed_visit' and new.source = 'enterprise' and new.customer_id is not null then
    select biz_fail_fee into f from public.profiles where id = new.customer_id;
    if f is not null then new.fee_kept := f; end if;
  end if;
  return new;
end $$;
drop trigger if exists jobs_biz_fail_fee on public.jobs;
create trigger jobs_biz_fail_fee before update on public.jobs for each row execute function public.biz_fail_fee();

-- ───────────────────────── Saved hubs (the business manages its own) ─────────────────────────
create or replace function public.biz_save_hub(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles; hubs jsonb; h jsonb; hid text;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.role <> 'enterprise' or not me.active then raise exception 'Only business accounts can do this.'; end if;
  if length(trim(coalesce(p->>'name',''))) < 2 then raise exception 'Give the hub a name.'; end if;
  if length(trim(coalesce(p->>'address',''))) < 5 then raise exception 'Enter the hub address.'; end if;
  hid := coalesce(nullif(p->>'id',''), 'h' || substr(md5(random()::text), 1, 8));
  h := jsonb_build_object('id', hid, 'name', left(trim(p->>'name'), 80), 'address', left(trim(p->>'address'), 300),
    'lat', case when (p->>'lat') ~ '^-?[0-9.]+$' then (p->>'lat')::double precision end,
    'lng', case when (p->>'lng') ~ '^-?[0-9.]+$' then (p->>'lng')::double precision end);
  select coalesce(jsonb_agg(x), '[]'::jsonb) into hubs from jsonb_array_elements(me.biz_hubs) x where x->>'id' <> hid;
  if coalesce(p->>'remove','') = 'true' then h := null; else hubs := hubs || jsonb_build_array(h); end if;
  update public.profiles set biz_hubs = hubs where id = me.id;
  return hubs;
end $$;

-- ───────────────────────── Book many jobs at once (one per SO) ─────────────────────────
-- p: {report_to: customer|hub, hub_id, date, time (hub only), rows: [{so_no, delivered_on, customer_name, mobile, address, area, lat, lng,
--      date, time (customer only), items: [{id, qty}], crew 1|2, notes}]}
create or replace function public.create_biz_booking(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles; cfg jsonb := coalesce((select value from public.settings where key = 'main'), '{}'::jsonb);
  rep text := coalesce(p->>'report_to', 'customer'); hub jsonb; batch uuid; hd date; ht text;
  rw jsonb; n int := 0; it jsonb; c public.catalog; q int; lines jsonb; tot numeric; crw int; wanted int;
  d date; t text; dl date; la double precision; lo double precision; today date := (now() at time zone 'Asia/Manila')::date;
  j public.jobs; res jsonb := '[]'::jsonb; pre text;
begin
  select * into me from public.profiles where id = auth.uid();
  if not found or me.role <> 'enterprise' or not me.active then raise exception 'Only approved business accounts can book this way.'; end if;
  if rep not in ('customer','hub') then raise exception 'Choose where the Taskadooer reports to.'; end if;
  if jsonb_typeof(p->'rows') <> 'array' or jsonb_array_length(p->'rows') = 0 then raise exception 'Add at least one job.'; end if;
  if jsonb_array_length(p->'rows') > 100 then raise exception 'Up to 100 jobs at a time.'; end if;
  if rep = 'hub' then
    select x into hub from jsonb_array_elements(me.biz_hubs) x where x->>'id' = p->>'hub_id';
    if hub is null then raise exception 'Choose the hub they report to.'; end if;
    begin hd := (p->>'date')::date; exception when others then hd := null; end;
    if hd is null or hd < today or hd > today + 120 then raise exception 'Choose the day they report to the hub (today up to 120 days ahead).'; end if;
    ht := upper(trim(coalesce(p->>'time','')));
    if ht !~ '^(1[0-2]|[1-9]):[0-5][0-9] (AM|PM)$' then raise exception 'Choose the time they report to the hub.'; end if;
    if public.job_start(hd, ht) < now() then raise exception 'That report time has already passed.'; end if;
    batch := gen_random_uuid();
  end if;
  for rw in select * from jsonb_array_elements(p->'rows') loop
    n := n + 1; pre := 'Row ' || n || ': ';
    lines := '[]'::jsonb; tot := 0; crw := 1;
    if jsonb_typeof(rw->'items') <> 'array' or jsonb_array_length(rw->'items') = 0 then raise exception '%add the items to assemble.', pre; end if;
    for it in select * from jsonb_array_elements(rw->'items') loop
      select * into c from public.catalog where id = (it->>'id')::bigint and active;
      if not found then raise exception '%an item is not in the catalogue.', pre; end if;
      q := greatest(1, least(50, coalesce((it->>'qty')::int, 1)));
      lines := lines || jsonb_build_array(jsonb_build_object('id', c.id, 'sku', c.sku, 'brand', c.brand, 'name', c.name,
        'emoji', c.emoji, 'qty', q, 'fee', c.fee, 'crew', c.crew, 'minutes', c.minutes));
      tot := tot + c.fee * q; crw := greatest(crw, c.crew);
    end loop;
    wanted := greatest(1, least(2, coalesce((rw->>'crew')::int, 1)));
    if wanted < crw then wanted := crw; end if;
    if length(trim(coalesce(rw->>'so_no',''))) < 2 then raise exception '%enter the SO number.', pre; end if;
    begin dl := nullif(rw->>'delivered_on','')::date; exception when others then raise exception '%the delivery date is not a date.', pre; end;
    if rep = 'hub' then d := hd; t := ht;
    else
      begin d := (rw->>'date')::date; exception when others then d := null; end;
      if d is null or d < today or d > today + 120 then raise exception '%choose the visit day (today up to 120 days ahead).', pre; end if;
      t := upper(trim(coalesce(rw->>'time','')));
      if t !~ '^(1[0-2]|[1-9]):[0-5][0-9] (AM|PM)$' then raise exception '%choose the visit time.', pre; end if;
      if public.job_start(d, t) < now() then raise exception '%that time has already passed.', pre; end if;
    end if;
    if dl is not null and d < dl then raise exception '%the visit must be on or after the delivery date.', pre; end if;
    if length(trim(coalesce(rw->>'customer_name',''))) < 2 then raise exception '%enter the customer name.', pre; end if;
    if length(regexp_replace(coalesce(rw->>'mobile',''), '\D', '', 'g')) < 10 then raise exception '%enter a valid mobile number.', pre; end if;
    if length(trim(coalesce(rw->>'address',''))) < 5 then raise exception '%enter the full address.', pre; end if;
    begin la := (rw->>'lat')::double precision; lo := (rw->>'lng')::double precision; exception when others then la := null; lo := null; end;
    if la is not null and (la < 4 or la > 22 or lo < 115 or lo > 128) then la := null; lo := null; end if;
    insert into public.jobs (source, customer_id, company, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total,
      commission_pct, lead_pct, lat, lng, so_no, delivered_on, report_to, hub_name, hub_address, hub_lat, hub_lng, batch_id, stop_no, events)
    values ('enterprise', me.id, left(coalesce(nullif(me.company,''), me.full_name, ''), 120), left(trim(rw->>'customer_name'), 120), left(trim(rw->>'mobile'), 40),
      left(trim(rw->>'address'), 300), left(coalesce(rw->>'area',''), 80), d, t, left(coalesce(rw->>'notes',''), 1000), lines, wanted, tot,
      coalesce((cfg->>'commission')::numeric, 22), coalesce((cfg->>'lead_pct')::numeric, 55), la, lo,
      left(trim(rw->>'so_no'), 60), dl, rep, coalesce(hub->>'name',''), coalesce(hub->>'address',''),
      (hub->>'lat')::double precision, (hub->>'lng')::double precision, batch, case when rep = 'hub' then n end,
      public.add_event('[]'::jsonb, 'booked', case when rep = 'hub' then 'report to ' || (hub->>'name') else '' end))
    returning * into j;
    update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(j.id::text, 4, '0') where id = j.id returning * into j;
    res := res || jsonb_build_array(jsonb_build_object('id', j.id, 'code', j.code, 'so_no', j.so_no, 'total', j.total));
  end loop;
  return jsonb_build_object('batch', batch, 'jobs', res);
end $$;

-- ───────────────────────── Hub runs: same Taskadooers for every job in the run ─────────────────────────
-- jobs of the same hub run never count as double-booking each other
create or replace function public.job_clash(p_uid uuid, p_job public.jobs) returns text
language plpgsql stable security definer set search_path = public as $$
declare gap int := coalesce((select (value->>'travel_min')::int from public.settings where key = 'main'), 60);
  s1 timestamptz; e1 timestamptz; r text;
begin
  if p_uid is null or p_job.job_date is null then return null; end if;
  s1 := public.job_start(p_job.job_date, p_job.slot);
  -- a hub run takes as long as all its jobs together
  e1 := s1 + make_interval(mins => gap + coalesce((select sum(public.job_minutes(b))::int from public.jobs b where p_job.batch_id is not null and b.batch_id = p_job.batch_id), public.job_minutes(p_job)));
  select o.code || ' at ' || o.slot into r from public.jobs o
   where o.id <> coalesce(p_job.id, -1) and (p_job.batch_id is null or o.batch_id is distinct from p_job.batch_id)
     and (o.lead_id = p_uid or o.helper_id = p_uid) and o.job_date = p_job.job_date
     and o.status in ('assigned','accepted','travelling','arrived','in_progress')
     and public.job_start(o.job_date, o.slot) < e1
     and s1 < public.job_start(o.job_date, o.slot) + make_interval(mins => public.job_minutes(o) + gap)
   order by o.slot limit 1;
  return r;
end $$;

-- the dispatcher gives a whole hub run to the same Taskadooers
create or replace function public.assign_batch(p_batch uuid, p_lead uuid, p_helper uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare jid bigint; n int := 0;
begin
  if not public.is_staff() then raise exception 'Only dispatchers can assign jobs.'; end if;
  for jid in select id from public.jobs where batch_id = p_batch and status in ('new','assigned','accepted') order by stop_no, id loop
    perform public.assign_job(jid, p_lead, p_helper); n := n + 1;
  end loop;
  if n = 0 then raise exception 'Nothing left to assign in this hub run.'; end if;
  return n;
end $$;

-- offer to everyone nearby: a hub run is offered as one
create or replace function public.offer_all(p_job bigint, p_on boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  if not public.is_staff() then raise exception 'Only dispatchers can do this.'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found then raise exception 'Job not found.'; end if;
  if p_on and not (j.status = 'new' or (j.status = 'assigned' and j.crew > 1 and j.helper_id is null)) then
    raise exception 'Only jobs that still need a Taskadooer can be offered to all.'; end if;
  update public.jobs set open_board = p_on, open_at = case when p_on then now() else open_at end,
    events = public.add_event(events, case when p_on then 'offered_all' else 'offer_all_stopped' end)
    where id = p_job or (j.batch_id is not null and batch_id = j.batch_id and status in ('new','assigned'));
end $$;

-- distance for a hub run is measured to the hub
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
  km := case when j.report_to = 'hub' and j.hub_lat is not null then public.km_between(p.home_lat, p.home_lng, j.hub_lat, j.hub_lng)
             else public.km_between(p.home_lat, p.home_lng, j.lat, j.lng) end;
  lim := least(match_km, coalesce(nullif(p.radius_km, 0), match_km));
  if km is null then return case when p.area <> '' and p.area = j.area then -1 else null end; end if;
  return case when km <= lim then km else null end;
end $$;

-- open jobs: also say where to report and which hub run they belong to
create or replace function public.open_jobs() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'code', j.code, 'company', j.company, 'area', j.area, 'job_date', j.job_date, 'slot', j.slot,
      'items', j.items, 'crew', j.crew, 'total', j.total, 'commission_pct', j.commission_pct, 'lead_pct', j.lead_pct,
      'report_to', j.report_to, 'hub_name', j.hub_name, 'hub_address', j.hub_address, 'batch_id', j.batch_id, 'stop_no', j.stop_no,
      'role', case when j.lead_id is null then 'lead' else 'helper' end, 'km', nullif(public.board_fits(j, p), -1)) order by j.job_date, j.stop_no, j.id), '[]'::jsonb)
  from public.jobs j, public.profiles p
  where p.id = auth.uid() and p.role = 'assembler' and p.active and public.board_fits(j, p) is not null
$$;

-- take an open job – a hub run is taken whole
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
  return to_jsonb(j);
end $$;

-- suggestions: distance to the hub for hub runs
create or replace function public.job_candidates(p_job bigint) returns table (
  id uuid, full_name text, mobile text, area text, online boolean, avail text, rating numeric, ratings int, skills text[], mober_emp boolean,
  km double precision, radius_km int, has_home boolean, done_jobs int, jobs_week int, years text, eval_avg numeric, busy text)
language plpgsql stable security definer set search_path = public as $$
declare j public.jobs; wk date; tla double precision; tlo double precision;
begin
  if not public.is_staff() then raise exception 'Only dispatchers can see this.'; end if;
  select * into j from public.jobs where jobs.id = p_job;
  if not found then raise exception 'Job not found.'; end if;
  wk := date_trunc('week', j.job_date)::date;
  tla := case when j.report_to = 'hub' and j.hub_lat is not null then j.hub_lat else j.lat end;
  tlo := case when j.report_to = 'hub' and j.hub_lat is not null then j.hub_lng else j.lng end;
  return query
  select p.id, coalesce(nullif(p.full_name,''), p.email), p.mobile, p.area,
    p.online and (p.online_at at time zone 'Asia/Manila')::date = (now() at time zone 'Asia/Manila')::date,
    public.avail_on(p, j.job_date, j.slot),
    (select round(avg(x.rating), 1) from public.jobs x where (x.lead_id = p.id or x.helper_id = p.id) and x.rating is not null),
    (select count(*)::int from public.jobs x where (x.lead_id = p.id or x.helper_id = p.id) and x.rating is not null),
    p.skills, p.mober_emp, public.km_between(p.home_lat, p.home_lng, tla, tlo), p.radius_km, p.home_lat is not null,
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

-- ───────────────────────── Problems: the business reports for its customer ─────────────────────────
create or replace function public.report_problem(p_job bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare j public.jobs; win interval;
begin
  select * into j from public.jobs where id = p_job for update;
  if not found or (j.customer_id is distinct from auth.uid()) then raise exception 'Booking not found.'; end if;
  if j.status <> 'done' then raise exception 'You can report a problem once the job is completed.'; end if;
  if j.dispute <> '' then raise exception 'A problem was already reported for this job.'; end if;
  win := case when j.source = 'enterprise'
    then make_interval(days => coalesce((select (value->>'biz_dispute_days')::int from public.settings where key = 'main'), 7))
    else make_interval(hours => j.dispute_hours) end;
  if now() > j.completed_at + win then
    raise exception 'The time to report a problem has passed. Please contact Taskadoo.'; end if;
  if length(trim(coalesce(p_note,''))) < 5 then raise exception 'Tell us what is wrong.'; end if;
  update public.jobs set dispute = 'open', dispute_note = left(trim(p_note),2000), dispute_at = now(),
    events = public.add_event(events, 'dispute', left(trim(p_note),300)) where id = p_job;
end $$;

revoke all on function public.biz_save_hub(jsonb), public.create_biz_booking(jsonb), public.assign_batch(uuid,uuid,uuid) from public, anon;
grant execute on function public.biz_save_hub(jsonb), public.create_biz_booking(jsonb), public.assign_batch(uuid,uuid,uuid) to authenticated;
