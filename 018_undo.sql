-- =====================================================================
-- 018_undo.sql — ONLY if 018 ran but you want to go back.
-- Puts monthly_salary / advance back on employees (from the new tables),
-- restores the old salary_payments policies and removes the salary module.
-- WARNING: salary runs, edits, payments and advances recorded after 018
-- are deleted (copy them first if needed).  exit_date is kept.
-- =====================================================================
begin;
alter table public.employees add column if not exists monthly_salary numeric(10,2) default 0;
alter table public.employees add column if not exists advance numeric(10,2) default 0;
update public.employees e set monthly_salary = p.monthly_salary from public.staff_salary_profile p where p.employee_id = e.id;
update public.employees e set advance = greatest(0,
         coalesce((select sum(amount) from public.salary_advances a where a.employee_id = e.id), 0)
       - coalesce((select sum(advance_deduction) from public.salary_runs r where r.employee_id = e.id and r.status = 'paid'), 0));

drop trigger if exists trg_employees_profile on public.employees;
drop trigger if exists trg_employees_delete_guard on public.employees;
drop table if exists public.salary_edits, public.salary_runs, public.salary_advances, public.staff_salary_profile;
drop sequence if exists public.salary_slip_seq;
drop function if exists public.generate_salary(date);
drop function if exists public.salary_edit(uuid,numeric,numeric,numeric,numeric,boolean,text,text);
drop function if exists public.salary_pay(uuid,date,text,text,text);
drop function if exists public.salary_undo_payment(uuid,text);
drop function if exists public.salary_pay_all(date,date,text,uuid);
drop function if exists public.ddd_pf(numeric);
drop function if exists public.ddd_advance_available(uuid,uuid);
drop function if exists public.ddd_setting_num(text,numeric);
drop function if exists public.ddd_require_director();
drop function if exists public.ddd_guard_salary_write();
drop function if exists public.ddd_guard_employee_delete();
drop function if exists public.ddd_employee_has_salary(uuid);
drop function if exists public.ddd_employee_profile();
delete from public.app_settings where key in ('pf_employee_rate','pf_employer_rate','pf_wage_ceiling','pf_apply_ceiling');

drop policy if exists salary_payments_director on public.salary_payments;
drop policy if exists salary_payments_read  on public.salary_payments;
drop policy if exists salary_payments_write on public.salary_payments;
create policy salary_payments_read on public.salary_payments for select
  using (is_director() or is_accountant() or hostel_id in (select my_hostels()));
create policy salary_payments_write on public.salary_payments for all
  using (is_director() or is_accountant() or hostel_id in (select my_hostels()))
  with check (is_director() or is_accountant() or hostel_id in (select my_hostels()));
commit;
