-- Taskadoo – STAGING ONLY: fresh sample bookings for TODAY for the test assembler Juan (run add_test_data.sql once first).
-- Run it again any day to get new ones. They are marked [TEST], so remove_test_data.sql removes them too.
do $$
declare
  today date := (now() at time zone 'Asia/Manila')::date;
  com numeric := coalesce((select (value->>'commission')::numeric from public.settings where key = 'main'), 22);
  lp numeric := coalesce((select (value->>'lead_pct')::numeric from public.settings where key = 'main'), 55);
  juan uuid := (select id from public.profiles where email = 'assembler.juan@test.taskadoo.ph');
  maria uuid := (select id from public.profiles where email = 'assembler.maria@test.taskadoo.ph');
  rachel uuid := (select id from public.profiles where email = 'customer.rachel@test.taskadoo.ph');
  mark uuid := (select id from public.profiles where email = 'customer.mark@test.taskadoo.ph');
  it jsonb; tot numeric; crw int; jid bigint;
begin
  if juan is null or maria is null or rachel is null or mark is null then
    raise exception 'Run add_test_data.sql first – the test people are missing.';
  end if;

  -- 1. Today 3:00 PM, already accepted by Juan (solo) – open it and do every step
  select jsonb_agg(jsonb_build_object('id', id, 'sku', sku, 'brand', brand, 'name', name, 'emoji', emoji, 'qty', 1, 'fee', fee, 'crew', crew, 'minutes', minutes)),
         sum(fee), max(crew) into it, tot, crw from public.catalog where sku in ('IK-MALM-NS', 'IK-BIL-BC');
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, lead_ok, events)
  values ('customer', rachel, 'Rachel Cruz (test)', '09170000007', 'Serendra Tower 2, Unit 1408, 11th Ave', 'Taguig (BGC)', today, '3:00 PM',
          '[TEST] Today – do every step', it, 1, tot, com, lp, 'accepted', juan, 'Juan dela Cruz (test)', true,
          public.add_event('[]'::jsonb, 'booked') || public.add_event('[]'::jsonb, 'assigned', 'Juan dela Cruz (test)'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 2. Today 1:00 PM, NEW OFFER for Juan + Maria (2-person wardrobe) – accept it in the app
  select jsonb_agg(jsonb_build_object('id', id, 'sku', sku, 'brand', brand, 'name', name, 'emoji', emoji, 'qty', 1, 'fee', fee, 'crew', crew, 'minutes', minutes)),
         sum(fee), max(crew) into it, tot, crw from public.catalog where sku = 'IK-PAX-2D';
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, helper_id, helper_name, events)
  values ('customer', mark, 'Mark Tan (test)', '09170000008', '88 Ayala Ave, Unit 22B', 'Makati City', today, '1:00 PM',
          '[TEST] Today – new offer', it, greatest(coalesce(crw, 2), 2), tot, com, lp, 'assigned', juan, 'Juan dela Cruz (test)', maria, 'Maria Santos (test)',
          public.add_event('[]'::jsonb, 'booked') || public.add_event('[]'::jsonb, 'assigned', 'Juan dela Cruz (test) + Maria Santos (test)'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 3. Tomorrow 10:00 AM, accepted by Juan – shows under "Tomorrow"
  select jsonb_agg(jsonb_build_object('id', id, 'sku', sku, 'brand', brand, 'name', name, 'emoji', emoji, 'qty', 1, 'fee', fee, 'crew', crew, 'minutes', minutes)),
         sum(fee), max(crew) into it, tot, crw from public.catalog where sku = 'IK-KAL-4C';
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, lead_ok, events)
  values ('customer', rachel, 'Rachel Cruz (test)', '09170000007', '21 Jupiter St, Bel-Air', 'Makati City', today + 1, '10:00 AM',
          '[TEST] Tomorrow', it, 1, tot, com, lp, 'accepted', juan, 'Juan dela Cruz (test)', true,
          public.add_event('[]'::jsonb, 'booked') || public.add_event('[]'::jsonb, 'assigned', 'Juan dela Cruz (test)'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;
end $$;

select code, job_date, slot, status, notes from public.jobs where notes like '[TEST] To%' and created_at > now() - interval '1 minute' order by id;
