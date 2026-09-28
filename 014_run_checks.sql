-- =====================================================================
-- 014 RUN CHECKS — run each STEP separately in Supabase SQL Editor
-- (select the step's lines -> Run). None of these change fee data,
-- except STEP 2 which only COPIES data into a private backup schema.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 (a) CONFIRM — expect 2 rows: payable | s   and   pending | s
-- ---------------------------------------------------------------------
select attname, attgenerated
from pg_attribute
where attrelid = 'public.monthly_dues'::regclass
  and attname in ('payable', 'pending')
order by attname;


-- ---------------------------------------------------------------------
-- STEP 2 (b) BACKUP — copies 3 tables into schema backup_014
-- (not reachable from the app/API). Safe to re-run: it replaces the copy.
-- ---------------------------------------------------------------------
create schema if not exists backup_014;
revoke all on schema backup_014 from public, anon, authenticated;
drop table if exists backup_014.students, backup_014.monthly_dues, backup_014.fee_payments, backup_014.app_settings;
create table backup_014.students     as table public.students;
create table backup_014.monthly_dues as table public.monthly_dues;
create table backup_014.fee_payments as table public.fee_payments;
create table backup_014.app_settings as table public.app_settings;
-- check: live and backup counts must match (expect 611 / 2101 / 644 / 1 or current numbers)
select 'students' t, (select count(*) from public.students) live, (select count(*) from backup_014.students) backup
union all select 'monthly_dues', (select count(*) from public.monthly_dues), (select count(*) from backup_014.monthly_dues)
union all select 'fee_payments', (select count(*) from public.fee_payments), (select count(*) from backup_014.fee_payments)
union all select 'app_settings', (select count(*) from public.app_settings), (select count(*) from backup_014.app_settings);


-- ---------------------------------------------------------------------
-- STEP 4 (d) VERIFY after 014 — every row must say PASS
-- ---------------------------------------------------------------------
with c(check_name, ok, detail) as (
  select 'new student columns',
         (select count(*) from information_schema.columns where table_schema='public' and table_name='students'
           and column_name in ('fee_plan','plan_months','plan_amount','paid_till')) = 4, ''
  union all
  select 'new payment columns',
         (select count(*) from information_schema.columns where table_schema='public' and table_name='fee_payments'
           and column_name in ('discount_amount','advance_group_id')) = 2, ''
  union all
  select 'all students on monthly plan',
         not exists (select 1 from students where fee_plan is distinct from 'monthly' or plan_months is distinct from 1),
         (select count(*)::text from students) || ' students'
  union all
  select 'plan_amount = monthly_fee',
         not exists (select 1 from students where plan_amount is distinct from round(coalesce(monthly_fee,0),2)), ''
  union all
  select 'paid_till filled (joining date + fee > 0)',
         not exists (select 1 from students where joining_date is not null and coalesce(monthly_fee,0) > 0 and paid_till is null),
         (select count(*) filter (where paid_till is not null) || ' filled, '
               || count(*) filter (where paid_till is null) || ' empty (no joining date / zero fee)' from students)
  union all
  select 'paid_till matches formula',
         not exists (select 1 from students where paid_till is distinct from compute_paid_till(id)), ''
  union all
  select 'payments have period', not exists (select 1 from fee_payments where period_from is null or period_to is null),
         (select count(*)::text from fee_payments) || ' payments'
  union all
  select 'triggers (8)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in (
            'trg_monthly_dues_discount_guard','trg_fee_payments_discount_guard','trg_students_fee_plan',
            'trg_monthly_dues_paid_till','trg_students_paid_till','trg_fee_payments_delete_guard',
            'trg_monthly_dues_delete_guard','trg_students_delete_guard')) = 8, ''
  union all
  select 'functions (record/delete/paid_till)',
         to_regprocedure('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)') is not null
     and to_regprocedure('public.delete_fee_payment(uuid)') is not null
     and to_regprocedure('public.recompute_paid_till(uuid)') is not null, ''
  union all
  select 'app_settings policies (4, old rw gone)',
         (select count(*) from pg_policies where tablename='app_settings'
           and policyname in ('app_settings_read','app_settings_insert','app_settings_update','app_settings_delete')) = 4
     and not exists (select 1 from pg_policies where tablename='app_settings' and policyname='app_settings_rw'), ''
  union all
  select 'anniversary fn fixed (uses fee_amount)',
         pg_get_functiondef('public.generate_anniversary_dues(date)'::regprocedure) not like '%month, payable,%', ''
  union all
  select 'row counts unchanged vs backup',
         (select count(*) from students)     = (select count(*) from backup_014.students)
     and (select count(*) from monthly_dues) = (select count(*) from backup_014.monthly_dues)
     and (select count(*) from fee_payments) = (select count(*) from backup_014.fee_payments), ''
)
select case when ok then 'PASS' else 'FAIL' end result, check_name, detail from c;

-- Overview (info only)
select count(*) filter (where paid_till >= (now() at time zone 'Asia/Kolkata')::date) paid_up,
       count(*) filter (where paid_till <  (now() at time zone 'Asia/Kolkata')::date) due_or_overdue,
       count(*) filter (where paid_till is null) not_billable
from students where status = 'active';
