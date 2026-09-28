-- =====================================================================
-- 018_salary_module.sql      (needs 014..017)
-- DDD Hostel — Staff Salary Module (Director only)
--   * Salary, advance, PF, salary runs and edit history live in NEW
--     Director-only tables (RLS = is_director()). Managers/Accountants get
--     nothing from the API.
--   * employees.monthly_salary / employees.advance are copied into the new
--     tables and then REMOVED from employees (so a Manager can never read
--     them). Old salary_payments table -> Director only.
--   * Salary for month X is due on the 10th of month X+1.
--   * generate_salary(month): one row per active staff per month (unique),
--     pro-rata for joining/exit month, PF, auto advance recovery.
--   * salary_edit / salary_pay / salary_undo_payment / salary_pay_all:
--     Director only, with reason + history; paid rows locked.
--   * NET = gross - employee PF - advance cut - other cut + bonus (min 0).
-- One transaction, idempotent.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- A. PRE-CHECKS
-- ---------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.is_director()') is null or to_regprocedure('public.ddd_is_api_caller()') is null then
    raise exception '018 aborted: run 014 first.';
  end if;
  if to_regprocedure('public.ddd_month_fee(numeric,date,date)') is null then
    raise exception '018 aborted: run 017 first.';
  end if;
  if to_regclass('public.employees') is null then
    raise exception '018 aborted: employees table missing.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- B. SETTINGS (PF) — Director edits them in the app
-- ---------------------------------------------------------------------
insert into public.app_settings(key, value) values
  ('pf_employee_rate', '12'), ('pf_employer_rate', '12'),
  ('pf_wage_ceiling', '15000'), ('pf_apply_ceiling', 'true')
on conflict (key) do nothing;

-- staff exit date (for pro-rata of the leaving month) — not salary data
alter table public.employees add column if not exists exit_date date;

-- ---------------------------------------------------------------------
-- C. DIRECTOR-ONLY TABLES
-- ---------------------------------------------------------------------
create table if not exists public.staff_salary_profile (
  employee_id    uuid primary key references public.employees(id) on delete cascade,
  monthly_salary numeric(10,2) not null default 0 check (monthly_salary >= 0),
  pf_applicable  boolean not null default false,
  uan            text,
  pf_number      text,
  pf_wage        numeric(10,2) check (pf_wage is null or pf_wage >= 0),   -- null = monthly salary
  bank_account   text,
  ifsc           text,
  upi_id         text,
  updated_at     timestamptz default now(),
  updated_by     uuid
);

create table if not exists public.salary_advances (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  amount      numeric(10,2) not null check (amount > 0),
  given_on    date not null default ((now() at time zone 'Asia/Kolkata')::date),
  mode        text,
  note        text,
  kind        text not null default 'advance' check (kind in ('advance','opening')),
  created_at  timestamptz default now(),
  created_by  uuid
);
create index if not exists idx_salary_advances_emp on public.salary_advances(employee_id);

create sequence if not exists public.salary_slip_seq;

create table if not exists public.salary_runs (
  id                uuid primary key default gen_random_uuid(),
  employee_id       uuid not null references public.employees(id) on delete cascade,
  hostel_id         uuid references public.hostels(id) on delete set null,
  month             date not null check (extract(day from month) = 1),
  period_from       date not null,
  period_to         date not null,
  days_in_month     int  not null,
  base_salary       numeric(10,2) not null default 0,
  gross             numeric(10,2) not null default 0 check (gross >= 0),
  attendance_days   int  not null default 0,
  pf_on             boolean not null default false,
  pf_wage           numeric(10,2) not null default 0,
  employee_pf       numeric(10,2) not null default 0 check (employee_pf >= 0),
  employer_pf       numeric(10,2) not null default 0 check (employer_pf >= 0),
  advance_deduction numeric(10,2) not null default 0 check (advance_deduction >= 0),
  other_deduction   numeric(10,2) not null default 0 check (other_deduction >= 0),
  bonus             numeric(10,2) not null default 0 check (bonus >= 0),
  net               numeric(10,2) generated always as
                      (greatest(gross - employee_pf - advance_deduction - other_deduction + bonus, 0)) stored,
  status            text not null default 'pending' check (status in ('pending','paid')),
  paid_date         date,
  mode              text,
  txn_ref           text,
  remarks           text,
  slip_no           text unique,
  paid_by           uuid,
  generated_by      uuid,
  created_at        timestamptz default now(),
  updated_at        timestamptz default now(),
  unique (employee_id, month)
);
create index if not exists idx_salary_runs_month on public.salary_runs(month);

create table if not exists public.salary_edits (
  id        uuid primary key default gen_random_uuid(),
  run_id    uuid not null references public.salary_runs(id) on delete cascade,
  field     text not null,
  old_value text,
  new_value text,
  reason    text not null,
  edited_by uuid,
  edited_at timestamptz default now()
);
create index if not exists idx_salary_edits_run on public.salary_edits(run_id);

-- RLS: Director only (all four tables)
do $$
declare t text;
begin
  foreach t in array array['staff_salary_profile','salary_advances','salary_runs','salary_edits'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_director', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_director()) with check (public.is_director())', t || '_director', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
revoke all on sequence public.salary_slip_seq from anon, authenticated;

-- old (unused, empty) salary_payments -> Director only
do $$
begin
  if to_regclass('public.salary_payments') is not null then
    drop policy if exists salary_payments_read  on public.salary_payments;
    drop policy if exists salary_payments_write on public.salary_payments;
    drop policy if exists salary_payments_director on public.salary_payments;
    create policy salary_payments_director on public.salary_payments for all to authenticated
      using (public.is_director()) with check (public.is_director());
  end if;
end $$;

-- salary runs / edit history: only through the functions below (keeps lock + history)
create or replace function public.ddd_guard_salary_write() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() then
    raise exception 'Salary rows sirf app ke Salary buttons se badal sakte hain' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists trg_salary_runs_guard on public.salary_runs;
create trigger trg_salary_runs_guard before insert or update or delete on public.salary_runs
  for each row execute function public.ddd_guard_salary_write();
drop trigger if exists trg_salary_edits_guard on public.salary_edits;
create trigger trg_salary_edits_guard before insert or update or delete on public.salary_edits
  for each row execute function public.ddd_guard_salary_write();

drop trigger if exists trg_salary_runs_upd on public.salary_runs;
create trigger trg_salary_runs_upd before update on public.salary_runs
  for each row execute function public.set_updated_at();

-- audit (audit_logs is Director-only)
drop trigger if exists trg_salary_runs_audit on public.salary_runs;
create trigger trg_salary_runs_audit after insert or update or delete on public.salary_runs
  for each row execute function public.audit_trigger();
drop trigger if exists trg_salary_advances_audit on public.salary_advances;
create trigger trg_salary_advances_audit after insert or update or delete on public.salary_advances
  for each row execute function public.audit_trigger();
drop trigger if exists trg_staff_salary_profile_audit on public.staff_salary_profile;  -- (audit_trigger needs an id column)

-- a Manager deleting a staff member must not wipe salary history
create or replace function public.ddd_employee_has_salary(p_emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from salary_runs where employee_id = p_emp)
      or exists (select 1 from salary_advances where employee_id = p_emp);
$$;
create or replace function public.ddd_guard_employee_delete() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() and not public.is_director() and public.ddd_employee_has_salary(old.id) then
    raise exception 'Is staff ka salary record hai — sirf Director delete kar sakta hai. Status = left karein.'
      using errcode = '42501';
  end if;
  return old;
end $$;
drop trigger if exists trg_employees_delete_guard on public.employees;
create trigger trg_employees_delete_guard before delete on public.employees
  for each row execute function public.ddd_guard_employee_delete();

-- ---------------------------------------------------------------------
-- D. MOVE salary + advance OUT of employees (backfill first, then drop)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'employees' and column_name = 'monthly_salary') then
    execute $q$
      insert into public.staff_salary_profile(employee_id, monthly_salary)
      select id, coalesce(monthly_salary, 0) from public.employees
      on conflict (employee_id) do nothing $q$;
  else
    insert into public.staff_salary_profile(employee_id)
    select id from public.employees on conflict (employee_id) do nothing;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'employees' and column_name = 'advance') then
    execute $q$
      insert into public.salary_advances(employee_id, amount, given_on, mode, note, kind)
      select e.id, e.advance, (now() at time zone 'Asia/Kolkata')::date, 'opening', 'Opening advance (old staff table)', 'opening'
        from public.employees e
       where coalesce(e.advance, 0) > 0
         and not exists (select 1 from public.salary_advances a where a.employee_id = e.id and a.kind = 'opening') $q$;
  end if;
end $$;
alter table public.employees drop column if exists monthly_salary;
alter table public.employees drop column if exists advance;

-- every new staff member gets an (empty) salary profile
create or replace function public.ddd_employee_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.staff_salary_profile(employee_id) values (new.id) on conflict do nothing;
  return null;
end $$;
drop trigger if exists trg_employees_profile on public.employees;
create trigger trg_employees_profile after insert on public.employees
  for each row execute function public.ddd_employee_profile();

-- ---------------------------------------------------------------------
-- E. HELPERS
-- ---------------------------------------------------------------------
create or replace function public.ddd_setting_num(p_key text, p_default numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(trim(value), '')::numeric from app_settings where key = p_key), p_default);
$$;

-- PF on a (pro-rata) PF wage: returns {emp, empr}
create or replace function public.ddd_pf(p_wage numeric) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (
    select public.ddd_setting_num('pf_employee_rate', 12) er,
           public.ddd_setting_num('pf_employer_rate', 12) rr,
           public.ddd_setting_num('pf_wage_ceiling', 15000) ceil,
           coalesce((select value from app_settings where key = 'pf_apply_ceiling'), 'true') in ('true','yes','1') apply_c
  ), b as (
    select case when apply_c then least(coalesce(p_wage,0), ceil) else coalesce(p_wage,0) end base, er, rr from s
  )
  select jsonb_build_object('emp', round(base * er / 100, 0), 'empr', round(base * rr / 100, 0), 'base', base) from b;
$$;

-- advance still free to recover = advances - paid recoveries - pending cuts of OTHER runs
create or replace function public.ddd_advance_available(p_emp uuid, p_exclude_run uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select sum(amount) from salary_advances where employee_id = p_emp), 0)
       - coalesce((select sum(advance_deduction) from salary_runs
                    where employee_id = p_emp and (status = 'paid' or (status = 'pending' and id is distinct from p_exclude_run))), 0);
$$;

create or replace function public.ddd_require_director() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not (auth.uid() is null or public.is_director()) then
    raise exception 'Sirf Director salary dekh/badal sakta hai' using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- F. GENERATE SALARY for a month (never duplicates)
-- ---------------------------------------------------------------------
create or replace function public.generate_salary(p_month date) returns integer
language plpgsql security definer set search_path = public as $$
declare
  m_start date := date_trunc('month', p_month)::date;
  m_end   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  dim     int  := extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::int;
  r record; v_from date; v_to date; v_days int; v_gross numeric; v_pfw numeric; v_pf jsonb;
  v_emp numeric; v_empr numeric; v_att int; v_adv numeric; n int := 0;
begin
  perform public.ddd_require_director();
  if p_month is null then raise exception 'Month required'; end if;
  if m_start > date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date then
    raise exception 'Future month ki salary generate nahi ho sakti';
  end if;
  for r in
    select e.id, e.hostel_id, e.joining_date, e.exit_date, coalesce(e.status, 'active') status,
           p.monthly_salary, p.pf_applicable, p.pf_wage
      from employees e join staff_salary_profile p on p.employee_id = e.id
     where p.monthly_salary > 0
  loop
    if r.status = 'left' and r.exit_date is null then continue; end if;
    v_from := greatest(m_start, coalesce(r.joining_date, m_start));
    v_to   := least(m_end, coalesce(r.exit_date, m_end));
    if v_from > v_to then continue; end if;
    if exists (select 1 from salary_runs where employee_id = r.id and month = m_start) then continue; end if;
    v_days  := v_to - v_from + 1;
    v_gross := round(r.monthly_salary * v_days / dim, 0);
    v_pfw   := round(coalesce(r.pf_wage, r.monthly_salary) * v_days / dim, 0);
    if r.pf_applicable then
      v_pf := public.ddd_pf(v_pfw); v_emp := (v_pf->>'emp')::numeric; v_empr := (v_pf->>'empr')::numeric;
    else
      v_emp := 0; v_empr := 0;
    end if;
    select count(*) into v_att from staff_attendance
     where employee_id = r.id and present and date between v_from and v_to;
    v_adv := greatest(0, least(public.ddd_advance_available(r.id, null), v_gross - v_emp));
    insert into salary_runs(employee_id, hostel_id, month, period_from, period_to, days_in_month, base_salary,
                            gross, attendance_days, pf_on, pf_wage, employee_pf, employer_pf, advance_deduction, generated_by)
    values (r.id, r.hostel_id, m_start, v_from, v_to, dim, r.monthly_salary,
            v_gross, v_att, r.pf_applicable, v_pfw, v_emp, v_empr, v_adv, auth.uid())
    on conflict (employee_id, month) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- G. DIRECTOR EDIT (pending rows only, reason + history)
--    null argument = unchanged
-- ---------------------------------------------------------------------
create or replace function public.salary_edit(
  p_run uuid, p_gross numeric default null, p_advance numeric default null, p_other numeric default null,
  p_bonus numeric default null, p_pf_on boolean default null, p_remarks text default null, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r salary_runs%rowtype; v_pf jsonb; n_emp numeric; n_empr numeric; v_avail numeric; changed int := 0;
  g numeric; a numeric; o numeric; b numeric; pf boolean; rm text;
begin
  perform public.ddd_require_director();
  select * into r from salary_runs where id = p_run for update;
  if not found then raise exception 'Salary row not found'; end if;
  if r.status <> 'pending' then raise exception 'Paid salary locked hai — pehle "Undo payment" karein'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'Edit ka reason likhein (jaise "4 din chhutti")'; end if;
  g  := coalesce(p_gross, r.gross);   a := coalesce(p_advance, r.advance_deduction);
  o  := coalesce(p_other, r.other_deduction); b := coalesce(p_bonus, r.bonus);
  pf := coalesce(p_pf_on, r.pf_on);   rm := case when p_remarks is null then r.remarks else nullif(trim(p_remarks), '') end;
  if g < 0 or a < 0 or o < 0 or b < 0 then raise exception 'Amount negative nahi ho sakta'; end if;
  v_avail := public.ddd_advance_available(r.employee_id, r.id);
  if a > greatest(v_avail, 0) then
    raise exception 'Advance cut (%) outstanding advance (%) se zyada nahi ho sakta', a, greatest(v_avail, 0);
  end if;
  if pf then v_pf := public.ddd_pf(r.pf_wage); n_emp := (v_pf->>'emp')::numeric; n_empr := (v_pf->>'empr')::numeric;
  else n_emp := 0; n_empr := 0; end if;

  if g <> r.gross then insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by) values (r.id, 'gross', r.gross::text, g::text, trim(p_reason), auth.uid()); changed := changed + 1; end if;
  if a <> r.advance_deduction then insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by) values (r.id, 'advance_deduction', r.advance_deduction::text, a::text, trim(p_reason), auth.uid()); changed := changed + 1; end if;
  if o <> r.other_deduction then insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by) values (r.id, 'other_deduction', r.other_deduction::text, o::text, trim(p_reason), auth.uid()); changed := changed + 1; end if;
  if b <> r.bonus then insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by) values (r.id, 'bonus', r.bonus::text, b::text, trim(p_reason), auth.uid()); changed := changed + 1; end if;
  if pf <> r.pf_on then insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by) values (r.id, 'pf_on', r.pf_on::text, pf::text, trim(p_reason), auth.uid()); changed := changed + 1; end if;
  if rm is distinct from r.remarks then insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by) values (r.id, 'remarks', r.remarks, rm, trim(p_reason), auth.uid()); changed := changed + 1; end if;
  if changed = 0 then raise exception 'Kuch bhi badla nahi'; end if;

  update salary_runs set gross = g, advance_deduction = a, other_deduction = o, bonus = b,
         pf_on = pf, employee_pf = n_emp, employer_pf = n_empr, remarks = rm
   where id = r.id returning * into r;
  return to_jsonb(r);
end $$;

-- ---------------------------------------------------------------------
-- H. PAYMENT DONE / UNDO / PAY ALL
-- ---------------------------------------------------------------------
create or replace function public.salary_pay(p_run uuid, p_date date, p_mode text, p_txn text default null, p_remarks text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r salary_runs%rowtype; v_today date := (now() at time zone 'Asia/Kolkata')::date; v_mode text := lower(trim(coalesce(p_mode, '')));
        v_out numeric;
begin
  perform public.ddd_require_director();
  select * into r from salary_runs where id = p_run for update;
  if not found then raise exception 'Salary row not found'; end if;
  if r.status <> 'pending' then raise exception 'Ye salary pehle hi paid hai'; end if;
  if p_date is null or p_date > v_today then raise exception 'Paid date aaj ya pehle ki honi chahiye'; end if;
  if v_mode not in ('cash', 'upi', 'bank') then raise exception 'Mode Cash / UPI / Bank hona chahiye'; end if;
  v_out := coalesce((select sum(amount) from salary_advances where employee_id = r.employee_id), 0)
         - coalesce((select sum(advance_deduction) from salary_runs where employee_id = r.employee_id and status = 'paid'), 0);
  if r.advance_deduction > greatest(v_out, 0) then
    raise exception 'Advance cut (%) outstanding advance (%) se zyada hai — pehle Edit karein', r.advance_deduction, greatest(v_out, 0);
  end if;
  update salary_runs
     set status = 'paid', paid_date = p_date, mode = v_mode, txn_ref = nullif(trim(p_txn), ''),
         remarks = coalesce(nullif(trim(p_remarks), ''), remarks), paid_by = auth.uid(),
         slip_no = coalesce(slip_no, 'SAL-' || to_char(month, 'YYMM') || '-' || lpad(nextval('public.salary_slip_seq')::text, 4, '0'))
   where id = r.id returning * into r;
  insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by)
  values (r.id, 'status', 'pending', 'paid', 'Payment Done (' || v_mode || ')', auth.uid());
  return to_jsonb(r);
end $$;

create or replace function public.salary_undo_payment(p_run uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r salary_runs%rowtype;
begin
  perform public.ddd_require_director();
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'Undo ka reason likhein'; end if;
  select * into r from salary_runs where id = p_run for update;
  if not found then raise exception 'Salary row not found'; end if;
  if r.status <> 'paid' then raise exception 'Ye salary paid nahi hai'; end if;
  update salary_runs set status = 'pending', paid_date = null, mode = null, txn_ref = null, paid_by = null
   where id = r.id returning * into r;
  insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by)
  values (r.id, 'status', 'paid', 'pending', trim(p_reason), auth.uid());
  return to_jsonb(r);
end $$;

create or replace function public.salary_pay_all(p_month date, p_date date, p_mode text, p_hostel uuid default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare x record; n int := 0;
begin
  perform public.ddd_require_director();
  for x in select id from salary_runs
            where month = date_trunc('month', p_month)::date and status = 'pending'
              and (p_hostel is null or hostel_id = p_hostel)
            order by id
  loop
    perform public.salary_pay(x.id, p_date, p_mode, null, 'Pay All');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- I. PERMISSIONS
-- ---------------------------------------------------------------------
revoke all on function public.generate_salary(date) from public, anon;
revoke all on function public.salary_edit(uuid,numeric,numeric,numeric,numeric,boolean,text,text) from public, anon;
revoke all on function public.salary_pay(uuid,date,text,text,text) from public, anon;
revoke all on function public.salary_undo_payment(uuid,text) from public, anon;
revoke all on function public.salary_pay_all(date,date,text,uuid) from public, anon;
grant execute on function public.generate_salary(date) to authenticated;
grant execute on function public.salary_edit(uuid,numeric,numeric,numeric,numeric,boolean,text,text) to authenticated;
grant execute on function public.salary_pay(uuid,date,text,text,text) to authenticated;
grant execute on function public.salary_undo_payment(uuid,text) to authenticated;
grant execute on function public.salary_pay_all(date,date,text,uuid) to authenticated;
revoke all on function public.ddd_pf(numeric) from public, anon;
revoke all on function public.ddd_advance_available(uuid,uuid) from public, anon, authenticated;
revoke all on function public.ddd_setting_num(text,numeric) from public, anon;
revoke all on function public.ddd_employee_profile() from public, anon, authenticated;
revoke all on function public.ddd_employee_has_salary(uuid) from public, anon;
grant execute on function public.ddd_employee_has_salary(uuid) to authenticated;

commit;
