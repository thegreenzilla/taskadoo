-- Taskadoo – remove the STAGING test data added by add_test_data.sql.
-- Deletes the bookings marked [TEST], every account ending in @test.taskadoo.ph. Evaluation times are kept – close or delete them in Evaluations → Calendar.
delete from public.payout_lines where job_id in (select id from public.jobs where notes like '[TEST]%' or revisit_of in (select id from public.jobs where notes like '[TEST]%'));
delete from public.payouts p where not exists (select 1 from public.payout_lines l where l.payout_id = p.id)
  and assembler_id in (select id from public.profiles where email like '%@test.taskadoo.ph');
delete from public.jobs where revisit_of in (select id from public.jobs where notes like '[TEST]%');
delete from public.jobs where notes like '[TEST]%';
delete from public.applications where user_id in (select id from public.profiles where email like '%@test.taskadoo.ph');
delete from auth.users where email like '%@test.taskadoo.ph';
select 'test data removed' as done;
