-- Taskadoo – v1.8: new Taskadooer sign-up (driver's license photo, code A, QR ticket, re-apply after a wait),
-- automatic evaluation times from hub rules + walk-ins, map pins and distance matching, time limit to accept, open job board.
-- Paste the whole file into Supabase → SQL Editor → Run. Safe to run more than once. Run AFTER the earlier files.

-- ───────────────────────── Defaults (only fills in what is missing; Admin changes them in Settings) ─────────────────────────
update public.settings set value = jsonb_build_object(
    'match_km', 30,          -- Dispatch suggests Taskadooers within this distance of the customer
    'offer_minutes', 30,     -- a Taskadooer has this long to accept an offer (0 = no limit)
    'reapply_months', 3,     -- after a failed evaluation the same license can apply again after this many months
    'past_work', true) || value   -- ask for optional photos of past work at sign-up
  where key = 'main';
-- every hub gets booking rules (days open 0=Sun…6=Sat, hours, interview length, seats per time, days ahead, closed times)
update public.settings set value = jsonb_set(value, '{hubs}', (
    select coalesce(jsonb_agg(jsonb_build_object('days', jsonb_build_array(1,2,3,4,5,6), 'start', '09:00', 'end', '16:00', 'len', 60,
             'seats', 5, 'window', 14, 'off', jsonb_build_array('12:00'), 'walkin', true) || h), '[]'::jsonb)
    from jsonb_array_elements(coalesce(value->'hubs', '[]'::jsonb)) h))
  where key = 'main';

-- ───────────────────────── Home location (Taskadooers) and job location ─────────────────────────
alter table public.profiles add column if not exists home_address text not null default '';
alter table public.profiles add column if not exists home_lat double precision;
alter table public.profiles add column if not exists home_lng double precision;
grant update (home_address, home_lat, home_lng) on public.profiles to authenticated;

alter table public.jobs add column if not exists lat double precision;
alter table public.jobs add column if not exists lng double precision;
alter table public.jobs add column if not exists lead_offer_at timestamptz;     -- when the lead offer was sent (time limit)
alter table public.jobs add column if not exists helper_offer_at timestamptz;
alter table public.jobs add column if not exists open_board boolean not null default false;   -- offered to all available nearby
alter table public.jobs add column if not exists open_at timestamptz;

-- straight-line distance in km
create or replace function public.km_between(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select case when lat1 is null or lng1 is null or lat2 is null or lng2 is null then null else
    round((6371 * 2 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2) + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))::numeric, 1)::double precision end
$$;

-- ───────────────────────── Applications: license, QR code, re-apply ─────────────────────────
alter table public.applications add column if not exists code text;
alter table public.applications add column if not exists lic_no text;           -- letter + 10 digits, no dashes
alter table public.applications add column if not exists blocked boolean not null default false;   -- fake document etc.: can't apply again
create unique index if not exists applications_code_idx on public.applications(code);
create index if not exists applications_lic_idx on public.applications(lic_no);
update public.applications set code = 'TK-' || upper(substr(md5(id::text), 1, 6)) where code is null;

alter table public.eval_slots add column if not exists auto boolean not null default false;   -- made from the hub rules
alter table public.eval_slots add column if not exists walkin boolean not null default false;
create unique index if not exists eval_slots_hub_time_idx on public.eval_slots(hub, starts_at) where not walkin;

create or replace function public.lic_norm(t text) returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Can this license apply? null = yes, otherwise {error: nolicense | active | wait | blocked, until}
create or replace function public.lic_status(p_number text, p_me uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare n text := public.lic_norm(p_number); a public.applications;
  months int := coalesce((select (value->>'reapply_months')::int from public.settings where key = 'main'), 3);
begin
  if n !~ '^[A-Z][0-9]{10}$' then return jsonb_build_object('error', 'nolicense'); end if;
  for a in select * from public.applications where lic_no = n and user_id is distinct from p_me order by created_at desc loop
    if a.blocked then return jsonb_build_object('error', 'blocked'); end if;
    if a.status in ('draft', 'booked', 'passed', 'no_show') then return jsonb_build_object('error', 'active'); end if;
    if a.status = 'failed' and a.evaluated_at + make_interval(months => months) > now() then
      return jsonb_build_object('error', 'wait', 'until', ((a.evaluated_at + make_interval(months => months)) at time zone 'Asia/Manila')::date);
    end if;
  end loop;
  return null;
end $$;
-- for the sign-up page before the account exists
create or replace function public.check_license(p_number text) returns jsonb
language sql stable security definer set search_path = public as $$ select public.lic_status(p_number, auth.uid()) $$;

-- Save the form. Can be called again while not yet evaluated; after a failed result it starts a new try once the wait is over.
create or replace function public.app_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid(); r text := public.my_role(); a public.applications; d jsonb := '{}'::jsonb; bd date; ls jsonb; n text;
  cfg jsonb := coalesce((select value from public.settings where key = 'main'), '{}'::jsonb);
  min_age int := coalesce((cfg->>'min_age')::int, 21); months int := coalesce((cfg->>'reapply_months')::int, 3); had boolean;
begin
  if r is null then raise exception 'Please sign in first.'; end if;
  if r <> 'customer' then raise exception 'This account is already % – no application needed.', case r when 'assembler' then 'a Taskadooer' else r end; end if;
  select * into a from public.applications where user_id = me for update;
  had := found;
  if had and a.status = 'passed' then raise exception 'Your application has already been decided.'; end if;
  if had and a.status = 'failed' then
    if a.blocked then raise exception 'Sorry, we can''t process your application. Please contact Taskadoo.'; end if;
    if a.evaluated_at + make_interval(months => months) > now() then
      raise exception 'You can apply again from %.', to_char((a.evaluated_at + make_interval(months => months)) at time zone 'Asia/Manila', 'Mon DD, YYYY'); end if;
    update public.applications set status = 'draft', docs = '{}'::jsonb, score = '{}'::jsonb, result_note = '', slot_id = null, moved = 0,
      emp_verified = null, evaluated_by = null, evaluator_name = '', evaluated_at = null, events = public.add_event(events, 'reapplied')
      where id = a.id returning * into a;
  end if;
  p := coalesce(p, '{}'::jsonb);
  if coalesce(p->>'birth_date','') <> '' then
    begin bd := (p->>'birth_date')::date; exception when others then raise exception 'Please enter your birth date.'; end;
    if bd > (now() at time zone 'Asia/Manila')::date - make_interval(years => min_age) then
      raise exception 'You must be at least % years old to be a Taskadooer.', min_age; end if;
    if bd < date '1940-01-01' then raise exception 'Please check your birth date.'; end if;
  end if;
  if p ? 'lic_no' then
    n := public.lic_norm(p->>'lic_no');
    ls := public.lic_status(n, me);
    if ls is not null then
      raise exception '%', case ls->>'error' when 'nolicense' then 'Please check your license number: 1 letter and 10 digits, e.g. N01-23-456789.'
        when 'active' then 'This driver''s license is already used in another application.'
        when 'wait' then 'You can apply again from ' || to_char((ls->>'until')::date, 'Mon DD, YYYY') || '.'
        else 'Sorry, we can''t process your application. Please contact Taskadoo.' end;
    end if;
  end if;
  if jsonb_typeof(p->'lic_codes') = 'array' and not (p->'lic_codes' ? 'A') then
    raise exception 'You need code A (motorcycle) on your driver''s license to be a Taskadooer.'; end if;
  -- keep only known fields
  d := jsonb_strip_nulls(jsonb_build_object(
    'birth_date', nullif(p->>'birth_date',''), 'sex', case when p->>'sex' in ('M','F') then p->>'sex' end,
    'lic_no', case when n is not null then substr(n,1,3) || '-' || substr(n,4,2) || '-' || substr(n,6) end,
    'lic_exp', nullif(p->>'lic_exp',''), 'lic_codes', case when jsonb_typeof(p->'lic_codes') = 'array' then p->'lic_codes' end,
    'home_address', left(nullif(trim(p->>'home_address'),''),300), 'home_city', left(nullif(p->>'home_city',''),80),
    'home_lat', case when p->>'home_lat' ~ '^-?[0-9.]+$' then (p->>'home_lat')::numeric end,
    'home_lng', case when p->>'home_lng' ~ '^-?[0-9.]+$' then (p->>'home_lng')::numeric end,
    'base_area', left(coalesce(nullif(p->>'home_city',''), nullif(p->>'base_area','')),80),
    'travel_km', case when p ? 'travel_km' then least(greatest(coalesce((p->>'travel_km')::int,0),0),100) end,
    'years', left(nullif(p->>'years',''),20), 'tools', case when p ? 'tools' then (p->>'tools')::boolean end,
    'commitment', case when p->>'commitment' in ('Full-time','Part-time') then p->>'commitment' end,
    'brands', case when jsonb_typeof(p->'brands') = 'array' then p->'brands' end,
    'skills', case when jsonb_typeof(p->'skills') = 'array' then p->'skills' end,
    'mober', case when p ? 'mober' then (p->>'mober')::boolean end, 'employee_id', left(nullif(trim(p->>'employee_id'),''),40),
    'gcash_name', left(nullif(trim(p->>'gcash_name'),''),120), 'gcash_number', left(nullif(regexp_replace(coalesce(p->>'gcash_number',''),'[^0-9+]','','g'),''),20),
    'consent_at', case when (p->>'consent')::boolean then now() end));
  if p ? 'mober' and not coalesce((p->>'mober')::boolean, false) then d := d || jsonb_build_object('employee_id', null); end if;
  if not had then
    insert into public.applications (user_id, data, lic_no, code, events)
      values (me, jsonb_strip_nulls(d), n, 'TK-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)), public.add_event('[]'::jsonb, 'started'))
    returning * into a;
  else
    update public.applications set data = jsonb_strip_nulls(data || d), lic_no = coalesce(n, lic_no),
      code = coalesce(code, 'TK-' || upper(substr(md5(gen_random_uuid()::text), 1, 6))),
      emp_verified = case when d ? 'employee_id' and d->>'employee_id' is distinct from data->>'employee_id' then null else emp_verified end
    where id = a.id returning * into a;
  end if;
  update public.profiles set requested_role = 'assembler',
    full_name = coalesce(nullif(left(trim(p->>'full_name'),120),''), full_name),
    mobile = coalesce(nullif(left(trim(p->>'mobile'),40),''), mobile),
    area = coalesce(a.data->>'base_area', area)
  where id = me;
  return public.app_row(a);
end $$;

-- Document photos: lic (driver's license), nbi, med, id (old), work1–3 (past work). Uploaded first to storage "apps/<user id>/…".
create or replace function public.app_doc(p_kind text, p_path text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.applications;
begin
  if p_kind not in ('lic','id','nbi','med','work1','work2','work3') then raise exception 'Unknown document.'; end if;
  if p_path !~ ('^' || auth.uid() || '/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$') then raise exception 'Bad file.'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'apps' and o.name = p_path) then raise exception 'The photo did not upload. Please try again.'; end if;
  select * into a from public.applications where user_id = auth.uid() for update;
  if not found then raise exception 'Start your application first.'; end if;
  if a.status in ('passed','failed') then raise exception 'Your application has already been decided.'; end if;
  update public.applications set docs = docs || jsonb_build_object(p_kind, jsonb_build_object('path', p_path, 'at', now(), 'ok', null, 'note', ''))
    where id = a.id returning * into a;
  return public.app_row(a);
end $$;

-- The evaluator photographs a document at the hub (applicant didn't upload it)
create or replace function public.app_doc_staff(p_app uuid, p_kind text, p_path text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.applications;
begin
  if not public.is_evaluator() then raise exception 'Only evaluators can add documents.'; end if;
  if p_kind not in ('lic','nbi','med') then raise exception 'Unknown document.'; end if;
  select * into a from public.applications where id = p_app for update;
  if not found then raise exception 'Application not found.'; end if;
  if p_path !~ ('^' || a.user_id || '/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$') then raise exception 'Bad file.'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'apps' and o.name = p_path) then raise exception 'The photo did not upload. Please try again.'; end if;
  update public.applications set docs = docs || jsonb_build_object(p_kind, jsonb_build_object('path', p_path, 'at', now(), 'ok', null, 'note', '', 'by_staff', true)),
    events = public.add_event(events, 'doc_staff', p_kind) where id = a.id returning * into a;
  return public.app_row(a);
end $$;
drop policy if exists "apps files upload" on storage.objects;
create policy "apps files upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'apps' and (split_part(name, '/', 1) = auth.uid()::text or public.is_evaluator()));

-- ───────────────────────── Evaluation times from the hub rules ─────────────────────────
-- Makes the times for the next "window" days from each hub's rules; removes unbooked automatic times that no longer fit the rules.
create or replace function public.eval_slots_ensure() returns void
language plpgsql security definer set search_path = public as $$
declare h jsonb; d date; m int; t timestamptz; today date := (now() at time zone 'Asia/Manila')::date; wanted timestamptz[]; s0 int; e0 int; ln int;
begin
  for h in select * from jsonb_array_elements(coalesce((select value->'hubs' from public.settings where key = 'main'), '[]'::jsonb)) loop
    if not (h ? 'days') then continue; end if;
    wanted := '{}';
    s0 := split_part(coalesce(h->>'start','09:00'), ':', 1)::int * 60 + split_part(coalesce(h->>'start','09:00'), ':', 2)::int;
    e0 := split_part(coalesce(h->>'end','16:00'), ':', 1)::int * 60 + split_part(coalesce(h->>'end','16:00'), ':', 2)::int;
    ln := greatest(coalesce((h->>'len')::int, 60), 15);
    for i in 0..least(greatest(coalesce((h->>'window')::int, 14), 1), 60) loop
      d := today + i;
      if not ((h->'days') @> to_jsonb(extract(dow from d)::int)) then continue; end if;
      m := s0;
      while m + ln <= e0 loop
        if not (coalesce(h->'off', '[]'::jsonb) ? (lpad((m / 60)::text, 2, '0') || ':' || lpad((m % 60)::text, 2, '0'))) then
          t := (d + make_interval(mins => m)) at time zone 'Asia/Manila';
          wanted := wanted || t;
          if t > now() then
            insert into public.eval_slots (hub, starts_at, seats, auto) values (h->>'name', t, greatest(coalesce((h->>'seats')::int, 5), 1), true)
            on conflict (hub, starts_at) where not walkin do update set seats = excluded.seats, active = true where eval_slots.auto;
          end if;
        end if;
        m := m + ln;
      end loop;
    end loop;
    delete from public.eval_slots s where s.auto and s.hub = h->>'name' and s.starts_at > now() and not (s.starts_at = any(wanted))
      and not exists (select 1 from public.applications a where a.slot_id = s.id);
  end loop;
end $$;

create or replace function public.eval_slot_list() returns table (id bigint, hub text, starts_at timestamptz, seats int, booked int, active boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public.eval_slots_ensure();
  return query select s.id, s.hub, s.starts_at, s.seats, public.slot_booked(s.id), s.active from public.eval_slots s
    where (s.active and not s.walkin and s.starts_at > now()) or (public.is_evaluator() and s.starts_at > now() - interval '60 days')
    order by s.starts_at;
end $$;

-- what must be filled in before booking
create or replace function public.app_missing(a public.applications) returns text[]
language plpgsql stable as $$
declare miss text[] := '{}'; mober boolean := coalesce((a.data->>'mober')::boolean, false);
begin
  if a.data->>'birth_date' is null then miss := array_append(miss, 'birth date'); end if;
  if a.lic_no is null then miss := array_append(miss, 'driver''s license number'); end if;
  if not coalesce(a.data->'lic_codes' ? 'A', false) then miss := array_append(miss, 'code A (motorcycle) on your license'); end if;
  if not (a.docs ? 'lic') then miss := array_append(miss, 'photo of your driver''s license'); end if;
  if a.data->>'home_address' is null then miss := array_append(miss, 'home address'); end if;
  if a.data->>'commitment' is null then miss := array_append(miss, 'full-time or part-time'); end if;
  if a.data->>'gcash_number' is null or a.data->>'gcash_name' is null then miss := array_append(miss, 'GCash name and number'); end if;
  if mober and a.data->>'employee_id' is null then miss := array_append(miss, 'Mober employee ID'); end if;
  return miss;
end $$;

-- Book (or move, once) the evaluation. At least 1 hour ahead.
create or replace function public.app_book(p_slot bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.applications; s public.eval_slots; old public.eval_slots; miss text[];
begin
  select * into a from public.applications where user_id = auth.uid() for update;
  if not found then raise exception 'Fill in your application first.'; end if;
  if a.status not in ('draft','booked','no_show') then raise exception 'Your application has already been decided.'; end if;
  miss := public.app_missing(a);
  if array_length(miss, 1) > 0 then raise exception 'Still missing: %.', array_to_string(miss, ', '); end if;
  select * into s from public.eval_slots where id = p_slot for update;
  if not found or not s.active or s.walkin then raise exception 'That time is no longer available.'; end if;
  if s.starts_at < now() + interval '1 hour' then raise exception 'Please pick a time at least 1 hour from now.'; end if;
  if a.status = 'booked' and a.slot_id = p_slot then return public.app_row(a); end if;
  if public.slot_booked(p_slot) >= s.seats then raise exception 'Someone just booked that time. Please pick another.'; end if;
  if a.status = 'booked' then
    if a.moved >= 1 then raise exception 'You can move your evaluation only once. Please contact Taskadoo.'; end if;
    select * into old from public.eval_slots where id = a.slot_id;
    if found and old.starts_at < now() + interval '2 hours' then raise exception 'Your evaluation is in less than 2 hours – it can no longer be moved.'; end if;
    update public.applications set slot_id = p_slot, moved = moved + 1,
      events = public.add_event(events, 'moved', to_char(s.starts_at at time zone 'Asia/Manila', 'Mon DD, HH12:MI AM')) where id = a.id returning * into a;
  else
    update public.applications set slot_id = p_slot, status = 'booked',
      events = public.add_event(events, 'booked', to_char(s.starts_at at time zone 'Asia/Manila', 'Mon DD, HH12:MI AM')) where id = a.id returning * into a;
  end if;
  return public.app_row(a);
end $$;

-- Walk-in at the hub (scanned the poster QR): evaluation today, now
create or replace function public.app_book_walkin(p_hub text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.applications; miss text[]; sid bigint; t timestamptz := date_trunc('minute', now());
begin
  select * into a from public.applications where user_id = auth.uid() for update;
  if not found then raise exception 'Fill in your application first.'; end if;
  if a.status not in ('draft','no_show') then raise exception 'You already have an evaluation booked.'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce((select value->'hubs' from public.settings where key = 'main'), '[]'::jsonb)) h
                 where h->>'name' = p_hub and coalesce((h->>'walkin')::boolean, true)) then raise exception 'Walk-ins are not open at this hub.'; end if;
  miss := public.app_missing(a);
  if array_length(miss, 1) > 0 then raise exception 'Still missing: %.', array_to_string(miss, ', '); end if;
  insert into public.eval_slots (hub, starts_at, seats, walkin) values (p_hub, t, 1, true) returning id into sid;
  update public.applications set slot_id = sid, status = 'booked', events = public.add_event(events, 'walkin', p_hub) where id = a.id returning * into a;
  return public.app_row(a);
end $$;

-- result: passed (becomes a Taskadooer), failed (p_block = can't apply again), no_show (can book again)
drop function if exists public.app_decide(uuid, text, jsonb, text);
create or replace function public.app_decide(p_app uuid, p_result text, p_score jsonb default '{}'::jsonb, p_note text default '', p_block boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.applications; mober boolean; k text;
begin
  if not public.is_evaluator() then raise exception 'Only evaluators can record results.'; end if;
  if p_result not in ('passed','failed','no_show') then raise exception 'Choose Pass, Fail or No-show.'; end if;
  select * into a from public.applications where id = p_app for update;
  if not found then raise exception 'Application not found.'; end if;
  if a.status <> 'booked' then raise exception 'Only booked evaluations can get a result.'; end if;
  mober := coalesce((a.data->>'mober')::boolean, false);
  if p_result = 'passed' then
    foreach k in array case when mober then array['lic','med'] else array['lic','nbi','med'] end loop
      if k = 'lic' and not (a.docs ? 'lic') and (a.docs ? 'id') then continue; end if;   -- applied before v1.8 with a valid ID
      if coalesce((a.docs->k->>'ok')::boolean, false) is not true then
        raise exception 'Check the documents first: % is not marked OK.', case k when 'lic' then 'the driver''s license' when 'nbi' then 'the NBI clearance' else 'the medical certificate' end;
      end if;
    end loop;
    if (a.docs ? 'id') and not (a.docs ? 'lic') and coalesce((a.docs->'id'->>'ok')::boolean, false) is not true then
      raise exception 'Check the documents first: the valid ID is not marked OK.'; end if;
    if mober and a.emp_verified is not true then raise exception 'Confirm the Mober employee ID first.'; end if;
  end if;
  if p_result = 'failed' and length(trim(coalesce(p_note,''))) < 3 then raise exception 'Write a short note on why.'; end if;
  update public.applications set status = p_result, score = coalesce(p_score, '{}'::jsonb), result_note = left(trim(coalesce(p_note,'')),1000),
    blocked = (p_result = 'failed' and coalesce(p_block, false)),
    evaluated_by = auth.uid(), evaluator_name = coalesce(public.my_name(), ''), evaluated_at = now(),
    slot_id = case when p_result = 'no_show' then null else slot_id end,
    events = public.add_event(events, p_result, left(trim(coalesce(p_note,'')),200) || case when p_result = 'failed' and p_block then ' (blocked)' else '' end)
  where id = a.id returning * into a;
  if p_result = 'passed' then
    update public.profiles set role = 'assembler', requested_role = '', area = coalesce(a.data->>'base_area', area),
      home_address = coalesce(a.data->>'home_address', home_address),
      home_lat = coalesce((a.data->>'home_lat')::double precision, home_lat), home_lng = coalesce((a.data->>'home_lng')::double precision, home_lng),
      radius_km = coalesce((a.data->>'travel_km')::int, radius_km)
    where id = a.user_id;
  end if;
  return public.app_row(a);
end $$;

-- ───────────────────────── Bookings keep the map pin ─────────────────────────
create or replace function public.create_booking(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r text := public.my_role();
  cfg jsonb := coalesce((select value from public.settings where key = 'main'), '{}'::jsonb);
  it jsonb; c public.catalog; q int;
  lines jsonb := '[]'::jsonb; tot numeric := 0; crw int := 1;
  d date; today date := (now() at time zone 'Asia/Manila')::date;
  j public.jobs; la double precision; lo double precision;
begin
  if r is null then raise exception 'Please sign in first.'; end if;
  if r = 'assembler' then raise exception 'Taskadooer accounts cannot make bookings.'; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then
    raise exception 'Your cart is empty.'; end if;
  if jsonb_array_length(p->'items') > 60 then raise exception 'Too many items in one booking.'; end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    select * into c from public.catalog where id = (it->>'id')::bigint and active;
    if not found then raise exception 'An item in your cart is no longer available.'; end if;
    q := greatest(1, least(50, coalesce((it->>'qty')::int, 1)));
    lines := lines || jsonb_build_array(jsonb_build_object('id', c.id, 'sku', c.sku, 'brand', c.brand, 'name', c.name,
      'emoji', c.emoji, 'qty', q, 'fee', c.fee, 'crew', c.crew, 'minutes', c.minutes));
    tot := tot + c.fee * q;
    crw := greatest(crw, c.crew);
  end loop;
  begin d := (p->>'date')::date; exception when others then raise exception 'Please choose a date.'; end;
  if d is null or d < today then raise exception 'Please choose a date from today onwards.'; end if;
  if d > today + 120 then raise exception 'Bookings open up to 120 days ahead.'; end if;
  if coalesce(p->>'slot','') = '' or not (coalesce(cfg->'slots','[]'::jsonb) ? (p->>'slot')) then
    raise exception 'Please choose a time slot.'; end if;
  if length(trim(coalesce(p->>'name',''))) < 2 then raise exception 'Please enter the customer name.'; end if;
  if length(regexp_replace(coalesce(p->>'mobile',''), '\D', '', 'g')) < 10 then raise exception 'Please enter a valid mobile number.'; end if;
  if length(trim(coalesce(p->>'address',''))) < 5 then raise exception 'Please enter the full address.'; end if;
  begin la := (p->>'lat')::double precision; lo := (p->>'lng')::double precision; exception when others then la := null; lo := null; end;
  if la is not null and (la < 4 or la > 22 or lo < 115 or lo > 128) then la := null; lo := null; end if;   -- outside the Philippines

  insert into public.jobs (source, customer_id, company, customer_name, mobile, address, area, job_date, slot, notes,
                           items, crew, total, commission_pct, lead_pct, lat, lng, events)
  values (case r when 'enterprise' then 'enterprise' when 'customer' then 'customer' else 'staff' end,
          case when r in ('customer','enterprise') then auth.uid() end,
          left(case when r = 'enterprise' then coalesce((select company from public.profiles where id = auth.uid()),'')
                    else coalesce(p->>'company','') end, 120),
          left(trim(p->>'name'),120), left(trim(p->>'mobile'),40), left(trim(p->>'address'),300),
          left(coalesce(p->>'area',''),80), d, p->>'slot', left(coalesce(p->>'notes',''),1000),
          lines, crw, tot,
          coalesce((cfg->>'commission')::numeric, 22), coalesce((cfg->>'lead_pct')::numeric, 55), la, lo,
          public.add_event('[]'::jsonb, 'booked'))
  returning * into j;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(j.id::text, 4, '0')
    where id = j.id returning * into j;
  return jsonb_build_object('id', j.id, 'code', j.code, 'total', j.total, 'crew', j.crew);
end $$;

-- staff can fix the pin of a booking
create or replace function public.set_job_pin(p_job bigint, p_lat double precision, p_lng double precision) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'Only dispatchers can change the pin.'; end if;
  update public.jobs set lat = p_lat, lng = p_lng, events = public.add_event(events, 'pin') where id = p_job;
end $$;

-- ───────────────────────── Dispatch: nearest Taskadooers first ─────────────────────────
drop function if exists public.assembler_list(date, text);
drop function if exists public.assembler_list(date, text, double precision, double precision);
create or replace function public.assembler_list(p_date date default null, p_slot text default null,
  p_lat double precision default null, p_lng double precision default null) returns table (
  id uuid, full_name text, mobile text, area text, jobs_that_day int, done_jobs int,
  online boolean, avail text, rating numeric, ratings int, skills text[], mober_emp boolean, km double precision, radius_km int, has_home boolean)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name,''), p.email), p.mobile, p.area,
    (select count(*)::int from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id)
       and j.job_date = p_date and j.status not in ('cancelled')),
    (select count(*)::int from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id) and j.status = 'done'),
    p.online and (p.online_at at time zone 'Asia/Manila')::date = (now() at time zone 'Asia/Manila')::date,
    public.avail_on(p, p_date, p_slot),
    (select round(avg(j.rating), 1) from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id) and j.rating is not null),
    (select count(*)::int from public.jobs j where (j.lead_id = p.id or j.helper_id = p.id) and j.rating is not null),
    p.skills, p.mober_emp, public.km_between(p.home_lat, p.home_lng, p_lat, p_lng), p.radius_km, p.home_lat is not null
  from public.profiles p
  where p.role = 'assembler' and p.active and public.is_staff()
  order by 2
$$;

-- ───────────────────────── Time limit to accept + open job board ─────────────────────────
-- Offers not accepted in time go back to Dispatch ("Not answered"). Called when Dispatch or a Taskadooer loads jobs.
create or replace function public.expire_offers() returns int
language plpgsql security definer set search_path = public as $$
declare mins int := coalesce((select (value->>'offer_minutes')::int from public.settings where key = 'main'), 30); j public.jobs; n int := 0;
begin
  if mins <= 0 then return 0; end if;
  for j in select * from public.jobs where status in ('assigned','accepted')
             and ((lead_id is not null and not lead_ok and lead_offer_at < now() - make_interval(mins => mins))
               or (helper_id is not null and not helper_ok and helper_offer_at < now() - make_interval(mins => mins))) for update loop
    if j.lead_id is not null and not j.lead_ok and j.lead_offer_at < now() - make_interval(mins => mins) then
      update public.jobs set events = public.add_event(events, 'expired', lead_name), lead_id = null, lead_name = '', lead_offer_at = null,
        helper_id = case when helper_ok then helper_id end, helper_name = case when helper_ok then helper_name else '' end,
        status = 'new' where id = j.id returning * into j;
      -- an accepted extra Taskadooer moves up to lead
      if j.helper_id is not null then
        update public.jobs set lead_id = helper_id, lead_name = helper_name, lead_ok = true, helper_id = null, helper_name = '', helper_ok = false,
          status = 'assigned' where id = j.id returning * into j;
      end if;
      n := n + 1;
    end if;
    if j.helper_id is not null and not j.helper_ok and j.helper_offer_at < now() - make_interval(mins => mins) then
      update public.jobs set events = public.add_event(events, 'expired', helper_name), helper_id = null, helper_name = '', helper_offer_at = null,
        status = case when lead_id is null then 'new' else 'assigned' end where id = j.id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- assign_job: remember when each person got the offer
create or replace function public.assign_job(p_job bigint, p_lead uuid, p_helper uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare j public.jobs; ln text := ''; hn text := ''; pr public.profiles; a text;
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
    if pr.id is distinct from j.lead_id then
      a := public.avail_on(pr, j.job_date, j.slot);
      if a = 'time_off' then raise exception '% took this day off.', ln; end if;
      if a = 'shift' then raise exception '% has a Mober shift on this day.', ln; end if;
    end if;
  end if;
  if p_helper is not null then
    select * into pr from public.profiles where id = p_helper and role = 'assembler' and active;
    if not found then raise exception 'The extra Taskadooer must be an active Taskadooer.'; end if;
    hn := coalesce(nullif(pr.full_name,''), pr.email);
    if pr.id is distinct from j.helper_id then
      a := public.avail_on(pr, j.job_date, j.slot);
      if a = 'time_off' then raise exception '% took this day off.', hn; end if;
      if a = 'shift' then raise exception '% has a Mober shift on this day.', hn; end if;
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

-- Dispatcher: offer a job to everyone available nearby (first to accept gets it), or stop offering
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
    events = public.add_event(events, case when p_on then 'offered_all' else 'offer_all_stopped' end) where id = p_job;
end $$;

-- Is this open job for me? (free that day, online for same-day jobs, within the distance)
create or replace function public.board_fits(j public.jobs, p public.profiles) returns double precision
language plpgsql stable security definer set search_path = public as $$
declare km double precision; lim double precision;
  match_km int := coalesce((select (value->>'match_km')::int from public.settings where key = 'main'), 30);
begin
  if not j.open_board or j.lead_id = p.id or j.helper_id = p.id then return null; end if;
  if not (j.status = 'new' or (j.status = 'assigned' and j.crew > 1 and j.helper_id is null)) then return null; end if;
  if public.avail_on(p, j.job_date, j.slot) <> 'ok' then return null; end if;
  if j.job_date = (now() at time zone 'Asia/Manila')::date and not (p.online and (p.online_at at time zone 'Asia/Manila')::date = j.job_date) then return null; end if;
  km := public.km_between(p.home_lat, p.home_lng, j.lat, j.lng);
  lim := least(match_km, coalesce(nullif(p.radius_km, 0), match_km));
  if km is null then return case when p.area <> '' and p.area = j.area then -1 else null end; end if;
  return case when km <= lim then km else null end;
end $$;

-- Open jobs a Taskadooer can take (only what they need to decide; the address shows after they take it)
create or replace function public.open_jobs() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'code', j.code, 'company', j.company, 'area', j.area, 'job_date', j.job_date, 'slot', j.slot,
      'items', j.items, 'crew', j.crew, 'total', j.total, 'commission_pct', j.commission_pct, 'lead_pct', j.lead_pct,
      'role', case when j.lead_id is null then 'lead' else 'helper' end, 'km', nullif(public.board_fits(j, p), -1)) order by j.job_date, j.id), '[]'::jsonb)
  from public.jobs j, public.profiles p
  where p.id = auth.uid() and p.role = 'assembler' and p.active and public.board_fits(j, p) is not null
$$;

-- Take an open job – first come, first served
create or replace function public.claim_job(p_job bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare j public.jobs; p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid() and role = 'assembler' and active;
  if not found then raise exception 'Only Taskadooers can take jobs.'; end if;
  select * into j from public.jobs where id = p_job for update;
  if not found or public.board_fits(j, p) is null then raise exception 'Sorry, someone else just took this job.'; end if;
  if j.lead_id is null then
    update public.jobs set lead_id = p.id, lead_name = coalesce(nullif(p.full_name,''), p.email), lead_ok = true, lead_offer_at = now(),
      status = 'assigned', events = public.add_event(events, 'claimed', 'lead') where id = p_job returning * into j;
  else
    update public.jobs set helper_id = p.id, helper_name = coalesce(nullif(p.full_name,''), p.email), helper_ok = true, helper_offer_at = now(),
      events = public.add_event(events, 'claimed', 'extra') where id = p_job returning * into j;
  end if;
  if j.lead_ok and (j.helper_id is null or j.helper_ok) and (j.crew <= 1 or j.helper_id is not null) then
    update public.jobs set status = 'accepted', open_board = false where id = p_job returning * into j;
  end if;
  return to_jsonb(j);
end $$;

revoke all on function public.check_license(text) from public;
grant execute on function public.check_license(text) to anon, authenticated;
revoke all on function public.lic_status(text,uuid), public.app_doc_staff(uuid,text,text), public.eval_slots_ensure(), public.app_book_walkin(text),
  public.app_decide(uuid,text,jsonb,text,boolean), public.set_job_pin(bigint,double precision,double precision),
  public.assembler_list(date,text,double precision,double precision), public.expire_offers(), public.offer_all(bigint,boolean),
  public.board_fits(public.jobs,public.profiles), public.open_jobs(), public.claim_job(bigint), public.app_missing(public.applications) from public, anon;
grant execute on function public.app_doc_staff(uuid,text,text), public.app_book_walkin(text), public.app_decide(uuid,text,jsonb,text,boolean),
  public.set_job_pin(bigint,double precision,double precision), public.assembler_list(date,text,double precision,double precision),
  public.expire_offers(), public.offer_all(bigint,boolean), public.open_jobs(), public.claim_job(bigint), public.km_between(double precision,double precision,double precision,double precision)
  to authenticated;
