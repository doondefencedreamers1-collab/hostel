-- =====================================================================
-- 014 UNDO — ONLY if 014 ran successfully but you want to go back.
-- (If 014 FAILED, you do NOT need this: nothing was changed.)
-- Removes everything 014 added. Fee data (dues/payments amounts) made
-- before 014 is untouched; payments/discounts recorded AFTER 014 stay
-- as rows but lose their new columns (discount_amount, advance_group_id).
-- The fixed generate_anniversary_dues is kept (the old one was broken).
-- =====================================================================
begin;
drop trigger if exists trg_monthly_dues_discount_guard on public.monthly_dues;
drop trigger if exists trg_monthly_dues_paid_till      on public.monthly_dues;
drop trigger if exists trg_monthly_dues_delete_guard   on public.monthly_dues;
drop trigger if exists trg_fee_payments_discount_guard on public.fee_payments;
drop trigger if exists trg_fee_payments_delete_guard   on public.fee_payments;
drop trigger if exists trg_students_fee_plan           on public.students;
drop trigger if exists trg_students_paid_till          on public.students;
drop trigger if exists trg_students_delete_guard       on public.students;

drop function if exists public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid);
drop function if exists public.delete_fee_payment(uuid);
drop function if exists public.recompute_paid_till(uuid);
drop function if exists public.compute_paid_till(uuid);
drop function if exists public.compute_paid_till(uuid, date, numeric);
drop function if exists public.ddd_dues_recompute_paid_till();
drop function if exists public.ddd_students_recompute_paid_till();
drop function if exists public.ddd_students_fee_plan();
drop function if exists public.ddd_guard_due_discount();
drop function if exists public.ddd_guard_payment_discount();
drop function if exists public.ddd_guard_payment_delete();
drop function if exists public.ddd_guard_due_delete();
drop function if exists public.ddd_guard_student_delete();
drop function if exists public.ddd_is_api_caller();

drop index if exists public.idx_fee_payments_group;
drop index if exists public.idx_fee_payments_student;
alter table public.fee_payments drop constraint if exists fee_payments_discount_chk,
                                drop column if exists discount_amount,
                                drop column if exists advance_group_id;
alter table public.students drop constraint if exists students_fee_plan_chk,
                            drop constraint if exists students_plan_months_chk,
                            drop constraint if exists students_plan_amount_chk,
                            drop column if exists fee_plan,
                            drop column if exists plan_months,
                            drop column if exists plan_amount,
                            drop column if exists paid_till;

-- app_settings back to the old single policy
drop policy if exists app_settings_read   on public.app_settings;
drop policy if exists app_settings_insert on public.app_settings;
drop policy if exists app_settings_update on public.app_settings;
drop policy if exists app_settings_delete on public.app_settings;
drop policy if exists app_settings_rw     on public.app_settings;
create policy app_settings_rw on public.app_settings for all to authenticated using (true) with check (true);
commit;
