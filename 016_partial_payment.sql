-- =====================================================================
-- 016_partial_payment.sql   (needs 014; works with or without 015)
-- DDD Hostel — Partial payment (any amount, e.g. half a month)
--
-- record_partial_payment(student, amount, ...):
--   * amount is applied oldest-first: overdue months first, then the
--     next months (created as needed). The last month may stay PARTIAL.
--   * one fee_payments row per month touched, same receipt_number and
--     advance_group_id -> one receipt; Director delete_fee_payment()
--     removes the whole group and gives the amounts back.
--   * no discount here (discount only via full-month payment, Director).
--   * paid_till moves only when a month becomes fully paid.
--   * idempotent with p_group_id (double submit safe).
-- Idempotent, one transaction.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)') is null then
    raise exception '016 aborted: run 014 first.';
  end if;
end $$;

create or replace function public.record_partial_payment(
  p_student_id     uuid,
  p_amount         numeric,
  p_mode           text default 'cash',
  p_payment_date   date default null,
  p_transaction_id text default null,
  p_remarks        text default null,
  p_group_id       uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s          public.students%rowtype;
  v_group    uuid := coalesce(p_group_id, gen_random_uuid());
  v_today    date := (now() at time zone 'Asia/Kolkata')::date;
  v_pdate    date := coalesce(p_payment_date, (now() at time zone 'Asia/Kolkata')::date);
  v_mode     text := coalesce(nullif(trim(p_mode), ''), 'cash');
  v_receipt  text;
  v_left     numeric;
  v_alloc    numeric;
  v_start    date;
  m          date;
  d          public.monthly_dues%rowtype;
  v_n        int := 0;
  v_guard    int := 0;
  v_first    date;
  v_last     date;
  v_balance  numeric := 0;
  v_paid_till date;
begin
  if p_group_id is not null and exists (select 1 from fee_payments where advance_group_id = p_group_id) then
    return (select jsonb_build_object(
              'group_id', p_group_id, 'duplicate', true, 'partial', true,
              'receipt_number', min(receipt_number),
              'period_from', min(period_from), 'period_to', max(period_to),
              'months', count(*), 'net', sum(amount), 'discount', 0, 'gross', sum(amount),
              'paid_till', (select paid_till from students where id = min(student_id::text)::uuid))
            from fee_payments where advance_group_id = p_group_id);
  end if;

  select * into s from students where id = p_student_id for update;
  if not found then raise exception 'Student not found'; end if;
  if not (auth.uid() is null or is_director() or is_accountant()
          or s.hostel_id in (select my_hostels())) then
    raise exception 'Not allowed for this hostel' using errcode = '42501';
  end if;
  if coalesce((select value from app_settings where key = 'billing_mode'), 'calendar') <> 'calendar' then
    raise exception 'Partial payment works only in calendar billing mode';
  end if;
  if s.joining_date is null then raise exception 'Student has no Joining Date — set it first'; end if;
  if coalesce(s.monthly_fee, 0) <= 0 then raise exception 'Student Monthly Fee is 0 — set it first'; end if;
  if p_amount is null or round(p_amount, 2) <= 0 then raise exception 'Amount 0 se zyada hona chahiye'; end if;
  if round(p_amount, 2) > round(s.monthly_fee * 36, 2) then
    raise exception 'Amount bahut zyada hai (max 36 months ki fee)';
  end if;
  if v_pdate > v_today then raise exception 'Payment date cannot be in the future'; end if;

  -- same start rule as record_fee_payment
  select min(date_trunc('month', month))::date into v_start
    from monthly_dues where student_id = s.id and coalesce(pending, 0) > 0;
  if v_start is null then
    select (max(date_trunc('month', month)) + interval '1 month')::date into v_start
      from monthly_dues where student_id = s.id;
  end if;
  v_start := coalesce(v_start, date_trunc('month', s.joining_date)::date);

  v_receipt := 'R-' || to_char(v_pdate, 'YYMMDD') || '-' || upper(substr(replace(v_group::text, '-', ''), 1, 6));
  v_left := round(p_amount, 2);
  m := v_start;

  while v_left > 0 loop
    v_guard := v_guard + 1;
    if v_guard > 240 then raise exception 'Could not allocate amount'; end if;
    select * into d from monthly_dues
     where student_id = s.id and date_trunc('month', month) = m
     order by month limit 1;
    if not found then
      insert into monthly_dues(student_id, hostel_id, month, fee_amount, period_from, period_to, created_by)
      values (s.id, s.hostel_id, m, s.monthly_fee, m, (m + interval '1 month - 1 day')::date, auth.uid())
      returning * into d;
    end if;
    if coalesce(d.pending, 0) > 0 then
      v_alloc := least(v_left, d.pending);
      update monthly_dues
         set paid_amount = coalesce(paid_amount, 0) + v_alloc,
             status      = case when coalesce(pending, 0) - v_alloc <= 0 then 'paid' else 'partial' end,
             period_from = coalesce(period_from, m),
             period_to   = coalesce(period_to, (m + interval '1 month - 1 day')::date)
       where id = d.id;
      insert into fee_payments(id, due_id, student_id, hostel_id, amount, discount_amount, payment_date,
                               mode, transaction_id, receipt_number, remarks, period_from, period_to,
                               advance_group_id, collected_by, created_by)
      values (gen_random_uuid(), d.id, s.id, s.hostel_id, v_alloc, 0, v_pdate,
              v_mode, p_transaction_id, v_receipt, coalesce(p_remarks, 'Partial payment'), m,
              (m + interval '1 month - 1 day')::date, v_group, auth.uid(), auth.uid());
      v_n := v_n + 1;
      v_first := coalesce(v_first, m);
      v_last := m;
      v_balance := d.pending - v_alloc;
      v_left := v_left - v_alloc;
    end if;
    m := (m + interval '1 month')::date;
  end loop;

  v_paid_till := public.recompute_paid_till(s.id);
  return jsonb_build_object(
    'group_id', v_group, 'duplicate', false, 'partial', true, 'receipt_number', v_receipt,
    'period_from', v_first, 'period_to', (v_last + interval '1 month - 1 day')::date,
    'months', v_n, 'gross', round(p_amount, 2), 'discount', 0, 'net', round(p_amount, 2),
    'balance_month', v_last, 'balance', v_balance, 'paid_till', v_paid_till);
end $$;

revoke all on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) to authenticated;

commit;

-- verify (expect 1 row)
-- select to_regprocedure('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)');
