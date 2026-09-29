-- =====================================================================
-- 020_undo.sql — 020 ko poora hata deta hai (sirf functions + indexes).
-- Koi data nahi badalta. Undo ke baad naya index.html Dashboard par
-- "020 abhi nahi chala" message dikhayega — isliye undo karein to
-- index.html bhi purana (PR se pehle wala) deploy karein.
-- =====================================================================
begin;
drop function if exists public.dashboard_summary(date, date, uuid);
drop function if exists public.ddd_period_numbers(date, date, boolean, uuid[], boolean);
drop function if exists public.ddd_period_numbers(date, date, uuid, boolean);
drop function if exists public.ddd_prev_period(date, date);
drop index if exists public.ddd_020_fee_payments_date;
drop index if exists public.ddd_020_expenses_date;
drop index if exists public.ddd_020_monthly_dues_month;
commit;
notify pgrst, 'reload schema';

-- check (dono false): 
-- select to_regprocedure('public.dashboard_summary(date,date,uuid)') is not null as rpc_left,
--        exists (select 1 from pg_indexes where indexname like 'ddd_020_%') as indexes_left;
-- backup_020 schema (sirf record) baad mein hatana ho to: drop schema backup_020 cascade;
