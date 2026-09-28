-- =====================================================================
-- 017a_fix_duplicate_dues.sql   (run BEFORE 017)
-- Problem: "Joining-date cycle" generator created a 2nd due row (day 2..31)
-- in the same calendar month where a 1st-of-month row already exists
-- -> students show double fee.
-- Fix (one transaction, idempotent):
--   1. backup monthly_dues into schema backup_017a
--   2. billing_mode -> 'calendar' (Director's rule a)
--   3. DELETE the extra non-1st-of-month row ONLY when
--        - a 1st-of-month row exists for the same student + month, AND
--        - the extra row is untouched: paid_amount 0, discount 0, no payments
--   4. Rows with money on them, or a student who has ONLY a non-1st row,
--      are NOT touched (listed by the check query for manual review).
--   paid_till is recalculated automatically (014 trigger).
-- =====================================================================
begin;

create schema if not exists backup_017a;
revoke all on schema backup_017a from public, anon, authenticated;
create table if not exists backup_017a.monthly_dues as table public.monthly_dues;

update public.app_settings set value = 'calendar' where key = 'billing_mode' and value is distinct from 'calendar';

delete from public.monthly_dues md
 where extract(day from md.month) <> 1
   and exists (select 1 from public.monthly_dues c
                where c.student_id = md.student_id
                  and c.month = date_trunc('month', md.month)::date)
   and coalesce(md.paid_amount, 0) = 0
   and coalesce(md.discount, 0) = 0
   and not exists (select 1 from public.fee_payments f where f.due_id = md.id);

commit;
