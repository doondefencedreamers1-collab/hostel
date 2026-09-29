-- =====================================================================
-- 023a_run_checks.sql — Salary: September 2026 rows hatao + chalu mahine ka block
-- Supabase SQL Editor mein STEP by STEP (har STEP alag query tab mein).
-- Order: 019_staff_absent.sql pehle, phir ye.
-- =====================================================================

-- ---------- STEP 1: CONFIRM (read-only) — sab ok = true ----------
select '019 applied (absent_days column)' chk,
       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'salary_runs' and column_name = 'absent_days')::text ok
union all select 'Sep 2026 rows (info)', (select count(*) from public.salary_runs where month = date '2026-09-01')::text
union all select 'Sep 2026 rows all pending', (not exists (select 1 from public.salary_runs where month = date '2026-09-01' and status <> 'pending'))::text
union all select 'Sep 2026 rows with edits (info)', (select count(*) from public.salary_edits x join public.salary_runs r on r.id = x.run_id where r.month = date '2026-09-01')::text
union all select 'generate_salary guard state (info)',
       case when pg_get_functiondef('public.generate_salary(date)'::regprocedure) like '%m_start >= date_trunc(''month'', (now() at time zone ''Asia/Kolkata''))::date%' then 'already guarded'
            when pg_get_functiondef('public.generate_salary(date)'::regprocedure) like '%m_start > date_trunc(''month'', (now() at time zone ''Asia/Kolkata''))::date%' then 'old (future only)'
            else 'UNKNOWN — mujhe batayein' end;

-- ---------- STEP 2: BACKUP (undo isi se chalega) ----------
create schema if not exists backup_023;
revoke all on schema backup_023 from public, anon, authenticated;
create table if not exists backup_023.meta (k text primary key, v jsonb not null, saved_at timestamptz not null default now());
create table if not exists backup_023.salary_runs (like public.salary_runs);
create table if not exists backup_023.salary_edits (like public.salary_edits);
insert into backup_023.meta(k, v)
select 'fn:generate_salary(date)', to_jsonb(pg_get_functiondef('public.generate_salary(date)'::regprocedure))
on conflict (k) do nothing;
insert into backup_023.salary_runs
select r.* from public.salary_runs r
where r.month = date '2026-09-01' and not exists (select 1 from backup_023.salary_runs b where b.id = r.id);
insert into backup_023.salary_edits
select x.* from public.salary_edits x join public.salary_runs r on r.id = x.run_id
where r.month = date '2026-09-01' and not exists (select 1 from backup_023.salary_edits b where b.id = x.id);
select 'backup rows' k, (select count(*) from backup_023.salary_runs)::text v
union all select 'backup edits', (select count(*) from backup_023.salary_edits)::text
union all select 'function saved', (select count(*) from backup_023.meta where k = 'fn:generate_salary(date)')::text;

-- ---------- STEP 3: DRY RUN (read-only) — ye rows delete hongi ----------
select e.full_name, h.code as hostel, r.status, r.gross, r.net, r.advance_deduction,
       (select count(*) from backup_023.salary_runs b where b.id = r.id) as in_backup, r.id
from public.salary_runs r join public.employees e on e.id = r.employee_id left join public.hostels h on h.id = r.hostel_id
where r.month = date '2026-09-01'
order by h.code, e.full_name;

-- ---------- STEP 4: 023a_salary_guard.sql poori file chalayein ----------

-- ---------- STEP 5: VERIFY — sab ok = true ----------
select 'Sep 2026 rows deleted' chk, (not exists (select 1 from public.salary_runs where month = date '2026-09-01'))::text ok
union all select 'all deleted rows are in backup', (select count(*) from backup_023.salary_runs where month = date '2026-09-01')::text
union all select 'generate_salary blocks current month',
       (pg_get_functiondef('public.generate_salary(date)'::regprocedure) like '%m_start >= date_trunc(''month'', (now() at time zone ''Asia/Kolkata''))::date%')::text
union all select 'generate_salary still Director only', (pg_get_functiondef('public.generate_salary(date)'::regprocedure) like '%ddd_require_director%')::text
union all select 'anon cannot run generate_salary', (not has_function_privilege('anon', 'public.generate_salary(date)', 'execute'))::text
union all select 'Aug 2026 rows untouched (info)', (select count(*) from public.salary_runs where month = date '2026-08-01')::text;
