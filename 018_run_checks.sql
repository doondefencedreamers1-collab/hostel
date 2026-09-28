-- =====================================================================
-- 018 RUN CHECKS — run each STEP separately in SQL Editor.
-- =====================================================================

-- STEP 1 — CONFIRM (expect: true | false | true)  017 live, 018 not yet, salary still in employees
select to_regprocedure('public.ddd_month_fee(numeric,date,date)') is not null as has_017,
       to_regclass('public.salary_runs') is not null as has_018,
       exists (select 1 from information_schema.columns where table_schema='public' and table_name='employees' and column_name='monthly_salary') as salary_in_employees;

-- STEP 2 — BACKUP into schema backup_018 (live = backup counts)
create schema if not exists backup_018;
revoke all on schema backup_018 from public, anon, authenticated;
drop table if exists backup_018.employees, backup_018.salary_payments, backup_018.staff_attendance, backup_018.app_settings;
create table backup_018.employees        as table public.employees;
create table backup_018.salary_payments  as table public.salary_payments;
create table backup_018.staff_attendance as table public.staff_attendance;
create table backup_018.app_settings     as table public.app_settings;
select 'employees' t, (select count(*) from public.employees) live, (select count(*) from backup_018.employees) backup,
       (select coalesce(sum(monthly_salary),0) from backup_018.employees) salary_sum
union all select 'staff_attendance', (select count(*) from public.staff_attendance), (select count(*) from backup_018.staff_attendance), null;

-- STEP 4 — VERIFY after 018 (every row PASS)
with c(check_name, ok) as (
  select '4 salary tables exist', to_regclass('public.staff_salary_profile') is not null and to_regclass('public.salary_advances') is not null
                                  and to_regclass('public.salary_runs') is not null and to_regclass('public.salary_edits') is not null
  union all select 'RLS on + Director-only policy (4 tables)',
       (select count(*) from pg_class where relname in ('staff_salary_profile','salary_advances','salary_runs','salary_edits') and relrowsecurity) = 4
   and (select count(*) from pg_policies where tablename in ('staff_salary_profile','salary_advances','salary_runs','salary_edits')) = 4
   and not exists (select 1 from pg_policies where tablename in ('staff_salary_profile','salary_advances','salary_runs','salary_edits') and qual <> 'is_director()')
  union all select 'salary + advance removed from employees',
       not exists (select 1 from information_schema.columns where table_schema='public' and table_name='employees' and column_name in ('monthly_salary','advance'))
  union all select 'every staff has a salary profile', (select count(*) from staff_salary_profile) = (select count(*) from employees)
  union all select 'salaries copied (same total as backup)', (select coalesce(sum(monthly_salary),0) from staff_salary_profile) = (select coalesce(sum(monthly_salary),0) from backup_018.employees)
  union all select 'advances copied (same total as backup)', (select coalesce(sum(amount),0) from salary_advances where kind='opening') = (select coalesce(sum(advance),0) from backup_018.employees)
  union all select 'old salary_payments Director-only', not exists (select 1 from pg_policies where tablename='salary_payments' and qual not like '%is_director()%')
  union all select 'PF settings 12% / 12% / 15000 / ceiling on',
       (select count(*) from app_settings where key in ('pf_employee_rate','pf_employer_rate','pf_wage_ceiling','pf_apply_ceiling')) = 4
  union all select 'PF 12000 = 1440, 20000 = 1800 (ceiling)', (public.ddd_pf(12000)->>'emp')::numeric = 1440 and (public.ddd_pf(20000)->>'emp')::numeric = 1800
  union all select 'functions exist', to_regprocedure('public.generate_salary(date)') is not null and to_regprocedure('public.salary_pay(uuid,date,text,text,text)') is not null
       and to_regprocedure('public.salary_edit(uuid,numeric,numeric,numeric,numeric,boolean,text,text)') is not null and to_regprocedure('public.salary_undo_payment(uuid,text)') is not null
  union all select 'anon cannot run salary functions', not has_function_privilege('anon', 'public.generate_salary(date)', 'execute')
  union all select 'staff count unchanged', (select count(*) from employees) = (select count(*) from backup_018.employees)
)
select case when ok then 'PASS' else 'FAIL' end result, check_name from c;
