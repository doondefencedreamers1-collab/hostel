-- =====================================================================
-- 015_lock_payments.sql   (run AFTER the new index.html is live on Netlify)
-- DDD Hostel — payments only through record_fee_payment()
--
--   * fee_payments: NO direct insert/update from the app (any role).
--     New payments come only from record_fee_payment(); deletes only from
--     delete_fee_payment() (Director) — already enforced by 014.
--   * monthly_dues: Manager/Accountant cannot change paid_amount, status,
--     discount or fee_amount directly (Director / DB functions only).
--
--   An old cached app on someone's phone will get a clear
--   "refresh the app" error instead of writing half a payment.
-- Idempotent, one transaction. Needs 014.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)') is null then
    raise exception '015 aborted: run 014 first.';
  end if;
end $$;

create or replace function public.ddd_guard_payment_write() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() then
    raise exception 'Fee sirf "Receive" button se jama hoti hai. App purana hai — page refresh karein (Ctrl+Shift+R).'
      using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists trg_fee_payments_write_guard on public.fee_payments;
create trigger trg_fee_payments_write_guard
  before insert or update on public.fee_payments
  for each row execute function public.ddd_guard_payment_write();

-- monthly_dues guard: 014 rules + paid_amount / status lock
create or replace function public.ddd_guard_due_discount() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() and not public.is_director() then
    if tg_op = 'INSERT' then
      if coalesce(new.discount, 0) <> 0 then
        raise exception 'Only the Director can give a discount' using errcode = '42501';
      end if;
      if new.fee_amount < coalesce((select monthly_fee from public.students where id = new.student_id), 0) then
        raise exception 'Only the Director can reduce a due amount' using errcode = '42501';
      end if;
      if coalesce(new.paid_amount, 0) <> 0 or coalesce(new.status, 'pending') <> 'pending' then
        raise exception 'Fee sirf "Receive" button se jama hoti hai' using errcode = '42501';
      end if;
    else
      if new.discount is distinct from old.discount then
        raise exception 'Only the Director can give a discount' using errcode = '42501';
      end if;
      if new.fee_amount is distinct from old.fee_amount then
        raise exception 'Only the Director can change a due amount' using errcode = '42501';
      end if;
      if new.paid_amount is distinct from old.paid_amount or new.status is distinct from old.status then
        raise exception 'Fee sirf "Receive" button se jama hoti hai. App purana hai — page refresh karein (Ctrl+Shift+R).'
          using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $$;

commit;

-- verify (expect 1 row: trg_fee_payments_write_guard)
-- select tgname from pg_trigger where tgname = 'trg_fee_payments_write_guard';
