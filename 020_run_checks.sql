-- =====================================================================
-- 020_run_checks.sql — Supabase SQL Editor mein STEP by STEP chalayein
-- (har STEP ko alag select karke Run). 020 koi data / table / policy
-- nahi badalta: sirf 3 functions + 3 indexes banata hai.
-- =====================================================================

-- ---------- STEP 1: CONFIRM (read-only) — sab "true" / khali aana chahiye ----------
select 'has 017 (pro-rata)'   chk, to_regprocedure('public.ddd_month_fee(numeric,date,date)') is not null ok
union all select 'has 018 (salary_runs)', to_regclass('public.salary_runs') is not null
union all select 'has 019 (absent_days)', exists (select 1 from information_schema.columns where table_schema='public' and table_name='salary_runs' and column_name='absent_days')
union all select 'helpers is_director / is_accountant / my_hostels',
  to_regprocedure('public.is_director()') is not null and to_regprocedure('public.is_accountant()') is not null and to_regprocedure('public.my_hostels()') is not null
union all select '020 not run yet (dashboard_summary missing)', to_regprocedure('public.dashboard_summary(date,date,uuid)') is null;

-- STEP 1b: columns 020 reads — result must be EMPTY (0 rows)
select x.t as table_name, x.c as missing_column
from (values ('fee_payments','payment_date'), ('fee_payments','amount'), ('fee_payments','mode'), ('fee_payments','due_id'),
             ('fee_payments','collected_by'), ('fee_payments','receipt_number'),
             ('monthly_dues','month'), ('monthly_dues','payable'), ('monthly_dues','pending'), ('monthly_dues','period_from'), ('monthly_dues','period_to'),
             ('expenses','expense_date'), ('expenses','status'), ('expenses','amount'),
             ('students','joining_date'), ('students','exit_date'), ('students','paid_till'), ('students','monthly_fee'),
             ('complaints','created_at'), ('complaints','status'), ('complaints','resolution_date'),
             ('beds','bed_status'), ('salary_runs','paid_date'), ('salary_runs','net'), ('app_settings','value')) x(t, c)
where not exists (select 1 from information_schema.columns ic where ic.table_schema='public' and ic.table_name=x.t and ic.column_name=x.c);

-- STEP 1c: facts (result bhejein) — refunds / statuses
select 'fee_payments negative amounts (refunds)' what, count(*)::text val from fee_payments where amount < 0
union all select 'fee_payments status values', string_agg(distinct coalesce(status,'(null)'), ', ') from fee_payments
union all select 'expenses status values', string_agg(distinct coalesce(status,'(null)'), ', ') from expenses
union all select 'complaints status values', string_agg(distinct coalesce(status,'(null)'), ', ') from complaints
union all select 'payments with NULL payment_date', count(*)::text from fee_payments where payment_date is null
union all select 'students left without exit_date', count(*)::text from students where status = 'left' and exit_date is null;

-- STEP 1d: READ policies — 020 uses the same rule. Har row mein
-- is_director() / is_accountant() / my_hostels() hi dikhna chahiye.
select tablename, policyname, cmd, qual
from pg_policies
where schemaname = 'public'
  and tablename in ('fee_payments','monthly_dues','expenses','students','beds','complaints','hostels','salary_runs')
  and cmd in ('SELECT','ALL')
order by tablename, policyname;

-- ---------- STEP 2: BACKUP (sirf record; 020 data nahi badalta) ----------
create schema if not exists backup_020;
drop table if exists backup_020.fn_defs;
create table backup_020.fn_defs as
  select p.oid::regprocedure::text as fn, pg_get_functiondef(p.oid) as def, now() as saved_at
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('dashboard_summary','ddd_period_numbers','ddd_prev_period');
drop table if exists backup_020.counts;
create table backup_020.counts as
  select (select count(*) from fee_payments) payments, (select count(*) from monthly_dues) dues,
         (select count(*) from students) students, (select count(*) from expenses) expenses, now() as saved_at;
select 'backup_020 ready' msg, (select count(*) from backup_020.fn_defs) old_functions_saved, c.* from backup_020.counts c;

-- ---------- STEP 3: 020_dashboard_summary.sql poori file chalayein ----------
-- (Success aana chahiye; last line "notify pgrst" API ko turant reload karti hai)

-- ---------- STEP 4: VERIFY ----------
-- 4a: teeno true
select 'rpc exists' chk, to_regprocedure('public.dashboard_summary(date,date,uuid)') is not null ok
union all select 'helper not callable by app', not has_function_privilege('authenticated', 'public.ddd_period_numbers(date,date,boolean,uuid[],boolean)', 'execute')
union all select 'indexes', (select count(*) from pg_indexes where schemaname = 'public' and indexname like 'ddd_020_%') = 3;

-- 4b: HAR USER ke liye RPC numbers = RLS se dikhne wale rows ka seedha sum.
-- Har row mein match = true aana chahiye (Director ke liye expense bhi).
drop table if exists pg_temp.v020;
create temp table v020 (email text, role text, what text, rpc numeric, rls numeric, match boolean);
do $$
declare
  u record; j jsonb; t date := (now() at time zone 'Asia/Kolkata')::date;
  m1 date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  m2 date := (date_trunc('month', (now() at time zone 'Asia/Kolkata')) + interval '1 month - 1 day')::date;
  r_all numeric; r_mon numeric; r_bill numeric; r_stu numeric; r_pend numeric; r_exp numeric;
  out_rows text[] := '{}';
begin
  for u in select us.id, us.email, r.name as role from users us join roles r on r.id = us.role_id order by r.name, us.email limit 200 loop
    perform set_config('request.jwt.claim.sub', u.id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    j := public.dashboard_summary(m1, m2, null);
    r_mon := (select coalesce(sum(amount), 0) from fee_payments where payment_date between m1 and m2);
    r_bill := (select coalesce(sum(payable), 0) from monthly_dues where month between m1 and m2);
    r_exp := (select coalesce(sum(amount), 0) from expenses where status = 'approved' and expense_date between m1 and m2);
    r_stu := (select count(*) from students s where (s.joining_date is null or s.joining_date <= t) and (s.exit_date is null or s.exit_date > t)
      and (coalesce(s.status, 'active') <> 'left' or s.exit_date > t));
    r_pend := (select coalesce(sum(d.pending), 0) from monthly_dues d join students s on s.id = d.student_id
      where d.pending > 0 and coalesce(d.period_from, d.month) <= t
        and coalesce(s.status, 'active') <> 'left' and s.joining_date is not null and coalesce(s.monthly_fee, 0) > 0);
    r_all := (select coalesce(sum(amount), 0) from fee_payments where payment_date between '2000-01-01' and t);
    execute 'reset role';
    out_rows := out_rows
      || array[u.email || '|' || u.role || '|collected (this month)|' || (j->'cur'->>'collected') || '|' || r_mon,
               u.email || '|' || u.role || '|billed (this month)|' || (j->'cur'->>'billed') || '|' || r_bill,
               u.email || '|' || u.role || '|students (today)|' || (j->'snap'->>'students') || '|' || r_stu,
               u.email || '|' || u.role || '|pending (today)|' || (j->'snap'->>'pending') || '|' || r_pend,
               u.email || '|' || u.role || '|collected (all time)|' || (public.dashboard_summary('2000-01-01', t, null)->'cur'->>'collected') || '|' || r_all];
    if u.role = 'director' then
      out_rows := out_rows || (u.email || '|' || u.role || '|expense (this month)|' || (j->'cur'->>'expense') || '|' || r_exp);
    end if;
  end loop;
  insert into v020 select split_part(x, '|', 1), split_part(x, '|', 2), split_part(x, '|', 3),
                          nullif(split_part(x, '|', 4), '')::numeric, nullif(split_part(x, '|', 5), '')::numeric,
                          nullif(split_part(x, '|', 4), '')::numeric is not distinct from nullif(split_part(x, '|', 5), '')::numeric
                   from unnest(out_rows) x;
end $$;
select * from v020 order by match, role, email, what;
-- short form: 0 aana chahiye
select count(*) as mismatches from v020 where not match;
