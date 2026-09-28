-- =====================================================================
-- 017 RUN CHECKS — run each STEP separately in SQL Editor.
-- =====================================================================

-- STEP 1 — CONFIRM (expect: t | t | f)  014+016 live, 017 not yet
select to_regprocedure('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)') is not null as has_014,
       to_regprocedure('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)') is not null as has_016,
       to_regprocedure('public.ddd_month_fee(numeric,date,date)') is not null as has_017;

-- STEP 2 — BACKUP into schema backup_017 (live = backup counts)
create schema if not exists backup_017;
revoke all on schema backup_017 from public, anon, authenticated;
drop table if exists backup_017.students, backup_017.monthly_dues, backup_017.fee_payments, backup_017.app_settings;
create table backup_017.students     as table public.students;
create table backup_017.monthly_dues as table public.monthly_dues;
create table backup_017.fee_payments as table public.fee_payments;
create table backup_017.app_settings as table public.app_settings;
select 'students' t, (select count(*) from public.students) live, (select count(*) from backup_017.students) backup
union all select 'monthly_dues', (select count(*) from public.monthly_dues), (select count(*) from backup_017.monthly_dues)
union all select 'fee_payments', (select count(*) from public.fee_payments), (select count(*) from backup_017.fee_payments);

-- STEP 1b — LIST (read-only): existing joining-month dues that 017b WOULD
-- change to pro-rata (joined after the 1st, nothing paid yet). Send me this.
select st.full_name, h.code hostel, st.joining_date, st.monthly_fee,
       d.month, d.fee_amount as now_amount,
       round(st.monthly_fee * ((date_trunc('month', st.joining_date) + interval '1 month - 1 day')::date - st.joining_date + 1)
             / extract(day from (date_trunc('month', st.joining_date) + interval '1 month - 1 day'))::numeric, 0) as prorata_amount
from monthly_dues d join students st on st.id = d.student_id left join hostels h on h.id = st.hostel_id
where st.joining_date is not null and extract(day from st.joining_date) > 1
  and date_trunc('month', d.month) = date_trunc('month', st.joining_date)
  and coalesce(d.paid_amount, 0) = 0 and coalesce(d.discount, 0) = 0
  and not exists (select 1 from fee_payments f where f.due_id = d.id)
  and d.fee_amount = st.monthly_fee
order by st.joining_date desc;

-- STEP 4 — VERIFY after 017 (every row PASS)
with c(check_name, ok) as (
  select 'pro-rata helper', to_regprocedure('public.ddd_month_fee(numeric,date,date)') is not null
  union all select 'pro-rata 9000 joined 15-09-2026 = 4800', public.ddd_month_fee(9000, '2026-09-15', '2026-09-01') = 4800
  union all select 'joined on 1st = full fee',              public.ddd_month_fee(9000, '2026-09-01', '2026-09-01') = 9000
  union all select 'next month = full fee',                 public.ddd_month_fee(9000, '2026-09-15', '2026-10-01') = 9000
  union all select 'fee_grace_days = 0',                    (select value from app_settings where key = 'fee_grace_days') = '0'
  union all select 'generator uses pro-rata',               pg_get_functiondef('public.generate_monthly_dues(date)'::regprocedure) like '%ddd_month_fee%'
  union all select 'record_fee_payment uses pro-rata',      pg_get_functiondef('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)'::regprocedure) like '%ddd_month_fee%'
  union all select 'record_partial_payment uses pro-rata',  pg_get_functiondef('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)'::regprocedure) like '%ddd_month_fee%'
  union all select 'old dues unchanged',   (select count(*) from monthly_dues) = (select count(*) from backup_017.monthly_dues)
       and not exists (select 1 from monthly_dues d join backup_017.monthly_dues b on b.id = d.id
                        where d.fee_amount <> b.fee_amount or d.paid_amount is distinct from b.paid_amount or d.discount is distinct from b.discount)
  union all select 'billing_mode = calendar',               (select value from app_settings where key = 'billing_mode') = 'calendar'
  union all select 'app cannot run joining-date generator', not has_function_privilege('authenticated', 'public.generate_anniversary_dues(date)', 'execute')
  union all select 'payments unchanged',   (select count(*) from fee_payments) = (select count(*) from backup_017.fee_payments)
)
select case when ok then 'PASS' else 'FAIL' end result, check_name from c;
