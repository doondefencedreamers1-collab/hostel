-- =====================================================================
-- 017b_prorata_existing.sql  — OPTIONAL, run only after you approve the
-- list from 017_run_checks.sql STEP 1b.  Needs 017.
-- Changes ONLY joining-month dues that are still completely untouched:
--   joined after the 1st, paid_amount = 0, discount = 0, no payments,
--   fee_amount still = full monthly fee.  -> fee_amount = pro-rata,
--   period_from = joining date.  Nothing already paid is changed.
-- =====================================================================
begin;
do $$ begin
  if to_regprocedure('public.ddd_month_fee(numeric,date,date)') is null then
    raise exception '017b aborted: run 017 first.';
  end if;
end $$;
with c as (
  select d.id, s.monthly_fee, s.joining_date, d.month
  from public.monthly_dues d join public.students s on s.id = d.student_id
  where s.joining_date is not null and extract(day from s.joining_date) > 1
    and date_trunc('month', d.month) = date_trunc('month', s.joining_date)
    and coalesce(d.paid_amount, 0) = 0 and coalesce(d.discount, 0) = 0
    and not exists (select 1 from public.fee_payments f where f.due_id = d.id)
    and d.fee_amount = s.monthly_fee
)
update public.monthly_dues d
   set fee_amount  = public.ddd_month_fee(c.monthly_fee, c.joining_date, c.month),
       period_from = greatest(date_trunc('month', c.month)::date, c.joining_date),
       period_to   = coalesce(d.period_to, (date_trunc('month', c.month) + interval '1 month - 1 day')::date)
  from c where c.id = d.id;
commit;
