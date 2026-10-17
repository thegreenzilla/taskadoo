-- Taskadoo – test checklists on the What's new page (staging).
-- Stores the Worked / Problem / Skip result and note for each test, so everyone testing sees the same results.
-- Any signed-in, active account can read and write them (testers use customer, assembler, … accounts).
-- Paste into Supabase → SQL Editor → Run. Safe to run more than once. Harmless on production (tests only show on staging).

create table if not exists public.test_results (
  id      text primary key check (length(id) <= 20),
  status  text not null default '' check (status in ('', 'pass', 'fail', 'skip')),
  note    text not null default '' check (length(note) <= 2000),
  by      uuid,
  by_name text not null default '' check (length(by_name) <= 200),
  at      timestamptz not null default now()
);
alter table public.test_results enable row level security;

drop policy if exists tr_read on public.test_results;
drop policy if exists tr_add on public.test_results;
drop policy if exists tr_change on public.test_results;
create policy tr_read on public.test_results for select to authenticated using (public.my_role() is not null);
create policy tr_add on public.test_results for insert to authenticated with check (public.my_role() is not null and by = auth.uid());
create policy tr_change on public.test_results for update to authenticated using (public.my_role() is not null) with check (by = auth.uid());

grant select, insert, update on public.test_results to authenticated;
