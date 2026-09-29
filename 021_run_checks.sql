-- =====================================================================
-- 021_run_checks.sql — duplicate cleanup, STEP by STEP (SQL Editor)
-- Kuch bhi merge tabhi hoga jab aap STEP 6 mein approved pairs daal kar
-- apply chalayenge. App ka hotfix (index.html) ke liye koi SQL nahi chahiye.
-- =====================================================================

-- ---------- STEP 1: CONFIRM (read-only) — sab true ----------
select 'has 014 (recompute_paid_till)' chk, to_regprocedure('public.recompute_paid_till(uuid)') is not null ok
union all select 'has 018 (salary_runs)', to_regclass('public.salary_runs') is not null
union all select '021 not installed yet', to_regprocedure('public.ddd_merge_duplicates(jsonb,boolean)') is null;

-- STEP 1b: jo tables students / employees ko point karti hain (LIVE foreign keys) — merge inhi ko move karega
select c.conrelid::regclass as table_name, a.attname as column_name, c.confrelid::regclass as points_to,
       case c.confdeltype when 'c' then 'on delete CASCADE' when 'n' then 'on delete SET NULL' else 'no action' end as on_delete
from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
where c.contype = 'f' and c.confrelid in ('public.students'::regclass, 'public.employees'::regclass)
order by 3, 1;

-- ---------- STEP 2: BACKUP (poori copy, merge se pehle) ----------
create schema if not exists backup_021;
drop table if exists backup_021.students_before;     create table backup_021.students_before     as select * from public.students;
drop table if exists backup_021.employees_before;    create table backup_021.employees_before    as select * from public.employees;
drop table if exists backup_021.monthly_dues_before; create table backup_021.monthly_dues_before as select * from public.monthly_dues;
drop table if exists backup_021.fee_payments_before; create table backup_021.fee_payments_before as select * from public.fee_payments;
drop table if exists backup_021.salary_profile_before; create table backup_021.salary_profile_before as select * from public.staff_salary_profile;
select (select count(*) from backup_021.students_before) students, (select count(*) from backup_021.employees_before) employees,
       (select count(*) from backup_021.monthly_dues_before) dues, (select count(*) from backup_021.fee_payments_before) payments,
       (select sum(amount) from backup_021.fee_payments_before) payments_total;

-- ---------- STEP 3: 021_merge_duplicates.sql poori file chalayein (sirf tool install hota hai) ----------

-- ---------- STEP 4: VERIFY install — teeno true ----------
select 'merge tool installed' chk, to_regprocedure('public.ddd_merge_duplicates(jsonb,boolean)') is not null ok
union all select 'app cannot call it', not has_function_privilege('authenticated', 'public.ddd_merge_duplicates(jsonb,boolean)', 'execute')
union all select 'backup tables', to_regclass('backup_021.rows') is not null and to_regclass('backup_021.merge_log') is not null;

-- ---------- STEP 5: DRY RUN (kuch save nahi hota) ----------
-- 021_duplicates_list.sql (D1 / D2) se keep_id, dup_id copy karke list banayein. Example:
-- select * from public.ddd_merge_duplicates('[
--   {"kind":"students",  "keep":"<keep_id>", "dup":"<dup_id>"},
--   {"kind":"employees", "keep":"<keep_id>", "dup":"<dup_id>"}
-- ]', false);
-- Har pair ke steps dikhenge; ⛔ BLOCKED wale pair list se hata dein.
-- Last row "fee_payments same: N rows, total ₹X — DRY RUN" hona chahiye.

-- ---------- STEP 6: APPLY (Director ke OK ke baad, wahi list, false -> true) ----------
-- select * from public.ddd_merge_duplicates('[ ...same list... ]', true);
-- merge_id note kar lein (undo ke liye).

-- ---------- STEP 7: CHECK after apply ----------
-- payments count / total STEP 2 jaisa hi hona chahiye:
select (select count(*) from fee_payments) payments_now, (select count(*) from backup_021.fee_payments_before) payments_before,
       (select sum(amount) from fee_payments) total_now, (select sum(amount) from backup_021.fee_payments_before) total_before,
       (select count(*) from fee_payments f where not exists (select 1 from students s where s.id = f.student_id)) payments_without_student;
-- merges done:
select merge_id, applied_at, undone_at, jsonb_array_length(pairs) pairs from backup_021.merge_log order by applied_at desc;
