-- Taskadoo – TEST DATA for STAGING ONLY (never run this on the live/production database).
-- Adds sample people, evaluation times and bookings so testers have something to work with.
--
-- BEFORE YOU RUN: change the password on the line marked >>> below (at least 8 characters).
-- Every test account uses that password. Emails all end in @test.taskadoo.ph, for example:
--   assembler.juan@test.taskadoo.ph · dispatcher.carlo@test.taskadoo.ph · customer.rachel@test.taskadoo.ph
-- Safe to run more than once: people that already exist are kept, bookings are only added the first time.
-- To remove everything again, run remove_test_data.sql.

create or replace function pg_temp.tk_user(p_email text, p_name text, p_mobile text, p_company text, p_req text, p_pw text)
returns uuid language plpgsql as $$
declare uid uuid;
begin
  select id into uid from auth.users where email = p_email;
  if uid is not null then return uid; end if;
  uid := gen_random_uuid();
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', p_email,
    extensions.crypt(p_pw, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', p_name, 'mobile', p_mobile, 'company', p_company, 'requested_role', p_req),
    now(), now(), '', '', '', '', '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', p_email, 'email_verified', true), 'email', now(), now(), now());
  return uid;
end $$;

-- one history line, as if that person did it
create or replace function pg_temp.ev(p_action text, p_by uuid, p_name text, p_at timestamptz, p_note text default '')
returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('at', p_at, 'by', p_by, 'name', p_name, 'action', p_action, 'note', p_note))
$$;

-- catalogue items as they are saved on a booking
create or replace function pg_temp.items(p jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'sku', c.sku, 'brand', c.brand, 'name', c.name, 'emoji', c.emoji,
    'qty', (x->>'qty')::int, 'fee', c.fee, 'crew', c.crew, 'minutes', c.minutes)), '[]'::jsonb)
  from jsonb_array_elements(p) x join public.catalog c on c.sku = x->>'sku'
$$;

do $$
declare
  pw text := 'TYPE-A-PASSWORD';            -- >>> change this to the password you want for all test accounts
  today date := (now() at time zone 'Asia/Manila')::date;
  v_hub text := coalesce((select value->'hubs'->0->>'name' from public.settings where key = 'main'), 'Pasay Hub');
  com numeric := coalesce((select (value->>'commission')::numeric from public.settings where key = 'main'), 22);
  lp numeric := coalesce((select (value->>'lead_pct')::numeric from public.settings where key = 'main'), 55);
  juan uuid; maria uuid; pedro uuid; ana uuid; carlo uuid; liza uuid; rachel uuid; mark uuid; eve uuid; ben uuid; joy uuid;
  d date; t text; sid bigint; jid bigint; it jsonb; tot numeric; crw int;
begin
  if pw = 'TYPE-A-PASSWORD' or length(pw) < 8 then
    raise exception 'First change TYPE-A-PASSWORD (near the top) to a password of at least 8 characters, then Run again.';
  end if;

  -- ── People ──
  juan   := pg_temp.tk_user('assembler.juan@test.taskadoo.ph',   'Juan dela Cruz (test)', '09170000001', '', 'assembler', pw);
  maria  := pg_temp.tk_user('assembler.maria@test.taskadoo.ph',  'Maria Santos (test)',   '09170000002', '', 'assembler', pw);
  pedro  := pg_temp.tk_user('assembler.pedro@test.taskadoo.ph',  'Pedro Reyes (test)',    '09170000003', '', 'assembler', pw);
  ana    := pg_temp.tk_user('assembler.ana@test.taskadoo.ph',    'Ana Villanueva (test)', '09170000004', '', 'assembler', pw);
  carlo  := pg_temp.tk_user('dispatcher.carlo@test.taskadoo.ph', 'Carlo Mendoza (test)',  '09170000005', '', '', pw);
  liza   := pg_temp.tk_user('evaluator.liza@test.taskadoo.ph',   'Liza Garcia (test)',    '09170000006', '', '', pw);
  rachel := pg_temp.tk_user('customer.rachel@test.taskadoo.ph',  'Rachel Cruz (test)',    '09170000007', '', '', pw);
  mark   := pg_temp.tk_user('customer.mark@test.taskadoo.ph',    'Mark Tan (test)',       '09170000008', '', '', pw);
  eve    := pg_temp.tk_user('business.eve@test.taskadoo.ph',     'Eve Lim (test)',        '09170000009', 'IKEA Philippines (test)', 'enterprise', pw);
  ben    := pg_temp.tk_user('applicant.ben@test.taskadoo.ph',    'Ben Aquino (test)',     '09170000010', '', 'assembler', pw);
  joy    := pg_temp.tk_user('applicant.joy@test.taskadoo.ph',    'Joy Ramos (test)',      '09170000011', '', 'assembler', pw);

  update public.profiles set role = 'assembler', requested_role = '', area = 'Taguig (BGC)', gcash_name = full_name, gcash_number = mobile,
    skills = array['Beds & wardrobes','Shelving & storage'], online = (id in (juan, maria)), online_at = now()
    where id in (juan, maria, pedro, ana) and role <> 'assembler';
  update public.profiles set mober_emp = true,
    avail = '{"week":{"mon":{"m":"shift"},"tue":{"m":"shift"},"fri":{"m":"hours","from":"17:00","to":"22:00"}}}'::jsonb where id = juan;
  update public.profiles set avail = '{"week":{"sun":{"m":"off"}}}'::jsonb where id = pedro;
  update public.profiles set avail = jsonb_build_object('off', jsonb_build_array((today + 1)::text)) where id = ana;
  update public.profiles set role = 'dispatcher' where id = carlo and role = 'customer';
  update public.profiles set role = 'evaluator'  where id = liza  and role = 'customer';
  update public.profiles set role = 'enterprise', requested_role = '', area = 'Pasig' where id = eve and role = 'customer';
  update public.profiles set area = 'Makati City' where id in (rachel, mark) and area = '';

  -- ── Evaluation times: next 14 days (not Sundays), 9:00 AM and 1:00 PM at the first hub in Settings, 4 seats ──
  for i in 1..14 loop
    d := today + i;
    if extract(dow from d) <> 0 then
      foreach t in array array['09:00','13:00'] loop
        if not exists (select 1 from public.eval_slots where hub = v_hub and starts_at = (d + t::time) at time zone 'Asia/Manila') then
          insert into public.eval_slots (hub, starts_at, seats) values (v_hub, (d + t::time) at time zone 'Asia/Manila', 4);
        end if;
      end loop;
    end if;
  end loop;

  -- ── Applicants: Ben booked an evaluation, Joy still filling in the form ──
  select id into sid from public.eval_slots where hub = v_hub and starts_at > now() + interval '1 day' order by starts_at limit 1;
  insert into public.applications (user_id, status, data, slot_id, events)
  values (ben, 'booked', jsonb_build_object('birth_date', '1995-04-12', 'base_area', 'Pasay', 'travel_km', 15, 'years', '1–3 years',
            'brands', jsonb_build_array('IKEA'), 'skills', jsonb_build_array('Beds & wardrobes'), 'commitment', 'part', 'mober', false,
            'gcash_name', 'Ben Aquino', 'gcash_number', '09170000010'), sid, pg_temp.ev('booked', ben, 'Ben Aquino (test)', now()))
  on conflict (user_id) do nothing;
  insert into public.applications (user_id, status, data) values (joy, 'draft', jsonb_build_object('birth_date', '1998-09-01'))
  on conflict (user_id) do nothing;

  -- ── Bookings (only the first time) ──
  if exists (select 1 from public.jobs where notes like '[TEST]%') then return; end if;

  -- helper: insert one job, then give it a code
  -- 1. Needs an assembler – tomorrow, 2-person job (wardrobe + 2 nightstands)
  it := pg_temp.items('[{"sku":"IK-PAX-2D","qty":1},{"sku":"IK-MALM-NS","qty":2}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0), coalesce(max((x->>'crew')::int), 1) into tot, crw from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct, events)
  values ('customer', rachel, 'Rachel Cruz (test)', '09170000007', 'Serendra Tower 2, Unit 1408, 11th Ave', 'Taguig (BGC)', today + 1, '10:00 AM',
          '[TEST] Needs 2 assemblers', it, crw, tot, com, lp, pg_temp.ev('booked', rachel, 'Rachel Cruz (test)', now() - interval '2 hours'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 2. Accepted for TODAY – Juan can do the whole job flow (travel → arrive → checks → timer → photos → signature)
  it := pg_temp.items('[{"sku":"IK-BIL-BC","qty":2}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0) into tot from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, lead_ok, events)
  values ('customer', mark, 'Mark Tan (test)', '09170000008', '88 Ayala Ave, Unit 22B', 'Makati City', today, '3:00 PM',
          '[TEST] Do the full job flow today', it, 1, tot, com, lp, 'accepted', juan, 'Juan dela Cruz (test)', true,
          pg_temp.ev('booked', mark, 'Mark Tan (test)', now() - interval '1 day') || pg_temp.ev('assigned', carlo, 'Carlo Mendoza (test)', now() - interval '20 hours', 'Juan dela Cruz (test)')
          || pg_temp.ev('accepted', juan, 'Juan dela Cruz (test)', now() - interval '19 hours'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 3. Business booking waiting for Juan + Maria to accept (shows as a NEW OFFER in their app)
  it := pg_temp.items('[{"sku":"IK-KAL-16C","qty":1},{"sku":"IK-KAL-4C","qty":2}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0), coalesce(max((x->>'crew')::int), 1) into tot, crw from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, company, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, helper_id, helper_name, events)
  values ('enterprise', eve, 'IKEA Philippines (test)', 'Pedro Lopez', '09181112222', '12 Kapitolyo St', 'Pasig', today + 2, '1:00 PM',
          '[TEST] Offer for Juan and Maria', it, greatest(crw, 2), tot, com, lp, 'assigned', juan, 'Juan dela Cruz (test)', maria, 'Maria Santos (test)',
          pg_temp.ev('booked', eve, 'Eve Lim (test)', now() - interval '3 hours') || pg_temp.ev('assigned', carlo, 'Carlo Mendoza (test)', now() - interval '1 hour', 'Juan dela Cruz (test) + Maria Santos (test)'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 4. Completed 3 days ago, paid, rated 5 – ready for Monday's payout (Pedro)
  it := pg_temp.items('[{"sku":"IK-KAL-4C","qty":1}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0) into tot from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, lead_ok, arrived_at, started_at, finished_at, completed_at, signed_name, paid, paid_at,
                           rating, rating_note, rated_at, events)
  values ('customer', rachel, 'Rachel Cruz (test)', '09170000007', 'Serendra Tower 2, Unit 1408, 11th Ave', 'Taguig (BGC)', today - 3, '10:00 AM',
          '[TEST] Done, paid and rated', it, 1, tot, com, lp, 'done', pedro, 'Pedro Reyes (test)', true,
          ((today - 3) + time '09:58') at time zone 'Asia/Manila', ((today - 3) + time '10:05') at time zone 'Asia/Manila',
          ((today - 3) + time '11:20') at time zone 'Asia/Manila', ((today - 3) + time '11:30') at time zone 'Asia/Manila', 'Rachel Cruz', true, now() - interval '2 days',
          5, 'Very neat, cleaned up everything.', now() - interval '2 days',
          pg_temp.ev('booked', rachel, 'Rachel Cruz (test)', now() - interval '5 days') || pg_temp.ev('accepted', pedro, 'Pedro Reyes (test)', now() - interval '4 days')
          || pg_temp.ev('completed', pedro, 'Pedro Reyes (test)', ((today - 3) + time '11:30') at time zone 'Asia/Manila'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 5. Business job done 2 days ago by Juan + Maria, rated 4 (business jobs don't wait for payment)
  it := pg_temp.items('[{"sku":"IK-PAX-2D","qty":1}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0) into tot from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, company, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, lead_ok, helper_id, helper_name, helper_ok, arrived_at, started_at, finished_at, completed_at, signed_name,
                           addons, addons_total, rating, rating_note, rated_at, events)
  values ('enterprise', eve, 'IKEA Philippines (test)', 'Anna Lopez', '09181113333', '5 Ortigas Ave, Tower B 9F', 'Pasig', today - 2, '1:00 PM',
          '[TEST] Business job with an add-on', it, 2, tot + 350, com, lp, 'done', juan, 'Juan dela Cruz (test)', true, maria, 'Maria Santos (test)', true,
          ((today - 2) + time '13:12') at time zone 'Asia/Manila', ((today - 2) + time '13:20') at time zone 'Asia/Manila',
          ((today - 2) + time '16:05') at time zone 'Asia/Manila', ((today - 2) + time '16:15') at time zone 'Asia/Manila', 'Anna Lopez',
          '[{"id":"anchor","name":"Wall anchoring / anti-tip kit","price":350}]'::jsonb, 350, 4, 'Good work, arrived a bit late.', now() - interval '1 day',
          pg_temp.ev('booked', eve, 'Eve Lim (test)', now() - interval '4 days') || pg_temp.ev('accepted', juan, 'Juan dela Cruz (test)', now() - interval '3 days')
          || pg_temp.ev('accepted', maria, 'Maria Santos (test)', now() - interval '3 days') || pg_temp.ev('completed', juan, 'Juan dela Cruz (test)', ((today - 2) + time '16:15') at time zone 'Asia/Manila'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 6. Done 3 hours ago, customer reported a problem – shows under Dispatch → Needs attention
  it := pg_temp.items('[{"sku":"IK-MALM-NS","qty":2}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0) into tot from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, lead_ok, arrived_at, started_at, finished_at, completed_at, signed_name,
                           dispute, dispute_note, dispute_at, events)
  values ('customer', mark, 'Mark Tan (test)', '09170000008', '88 Ayala Ave, Unit 22B', 'Makati City', today, '8:00 AM',
          '[TEST] Customer reported a problem', it, 1, tot, com, lp, 'done', maria, 'Maria Santos (test)', true,
          now() - interval '6 hours', now() - interval '5 hours 50 minutes', now() - interval '4 hours', now() - interval '3 hours', 'Mark Tan',
          'open', 'One drawer does not close properly.', now() - interval '1 hour',
          pg_temp.ev('accepted', maria, 'Maria Santos (test)', now() - interval '1 day') || pg_temp.ev('completed', maria, 'Maria Santos (test)', now() - interval '3 hours')
          || pg_temp.ev('dispute', mark, 'Mark Tan (test)', now() - interval '1 hour', 'One drawer does not close properly.'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 7. Customer won't sign – Taskadoo has to decide (Needs attention)
  it := pg_temp.items('[{"sku":"IK-BIL-BC","qty":1}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0) into tot from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct,
                           status, lead_id, lead_name, lead_ok, arrived_at, started_at, finished_at, issue, issue_note, events)
  values ('customer', rachel, 'Rachel Cruz (test)', '09170000007', '21 Jupiter St, Bel-Air', 'Makati City', today, '10:00 AM',
          '[TEST] Customer would not sign', it, 1, tot, com, lp, 'issue', pedro, 'Pedro Reyes (test)', true,
          now() - interval '4 hours', now() - interval '3 hours 50 minutes', now() - interval '3 hours', 'no_sign', 'Says the shelves are uneven; I levelled them twice.',
          pg_temp.ev('accepted', pedro, 'Pedro Reyes (test)', now() - interval '1 day') || pg_temp.ev('no_sign', pedro, 'Pedro Reyes (test)', now() - interval '3 hours', 'Says the shelves are uneven'))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;

  -- 8. Next week, needs one assembler
  it := pg_temp.items('[{"sku":"IK-KAL-4C","qty":1},{"sku":"IK-BIL-BC","qty":1}]');
  select coalesce(sum((x->>'fee')::numeric * (x->>'qty')::int), 0) into tot from jsonb_array_elements(it) x;
  insert into public.jobs (source, customer_id, customer_name, mobile, address, area, job_date, slot, notes, items, crew, total, commission_pct, lead_pct, events)
  values ('customer', mark, 'Mark Tan (test)', '09170000008', '88 Ayala Ave, Unit 22B', 'Makati City', today + 7, '1:00 PM',
          '[TEST] Next week', it, 1, tot, com, lp, pg_temp.ev('booked', mark, 'Mark Tan (test)', now()))
  returning id into jid;
  update public.jobs set code = 'TD-' || to_char(now() at time zone 'Asia/Manila', 'YYMM') || '-' || lpad(jid::text, 4, '0') where id = jid;
end $$;

-- what was added
select role, count(*) as people from public.profiles where email like '%@test.taskadoo.ph' group by role
union all select 'bookings', count(*) from public.jobs where notes like '[TEST]%'
union all select 'evaluation times ahead', count(*) from public.eval_slots where starts_at > now();
