-- =====================================================================
-- 017_billing_rules.sql      (needs 014 + 016; 015 optional)
-- DDD Hostel — Director's billing rules
--   a) Calendar billing: fee due on the 1st of every month. Joining-date cycle
--      switched off (app can no longer run generate_anniversary_dues).
--   b) Due on the 1st, Overdue from the 2nd  -> app_settings.fee_grace_days = 0
--      (Director can change later; read by the app).
--   c/d) Joining month is PRO-RATA:
--        fee = monthly_fee x (days from joining date to month end, inclusive)
--              / days in that month, rounded to nearest rupee.
--        e.g. Rs 9,000, joined 15-09-2026 -> 16/30 -> Rs 4,800 for 15-30 Sept.
--        Joined on the 1st -> full month. Next months full from the 1st.
--      generate_monthly_dues, record_fee_payment, record_partial_payment
--      create the joining-month due with the pro-rata amount and
--      period_from = joining date.
--   e) Never-billed student: paid_till = day before JOINING DATE.
--   g) Old dues / payments are NOT changed here. Existing unpaid joining-
--      month dues are listed by 017_run_checks.sql STEP 1b and changed only
--      by the separate 017b_prorata_existing.sql after you approve the list.
-- One transaction, idempotent.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)') is null then
    raise exception '017 aborted: run 014 first.';
  end if;
  if to_regprocedure('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)') is null then
    raise exception '017 aborted: run 016 first.';
  end if;
end $$;

-- a) calendar billing only: Joining-date cycle switched off for good
update public.app_settings set value = 'calendar' where key = 'billing_mode' and value is distinct from 'calendar';
revoke execute on function public.generate_anniversary_dues(date) from public, anon, authenticated;

-- b) grace days setting (0 = overdue from the 2nd)
insert into public.app_settings(key, value) values ('fee_grace_days', '0')
on conflict (key) do nothing;

-- c) pro-rata helper: fee for calendar month p_month for a student who joined on p_joining
create or replace function public.ddd_month_fee(p_fee numeric, p_joining date, p_month date)
returns numeric language sql immutable as $$
  select case
    when p_joining is null or coalesce(p_fee, 0) <= 0 then coalesce(p_fee, 0)
    when date_trunc('month', p_joining) = date_trunc('month', p_month) and extract(day from p_joining) > 1
      then round(p_fee
                 * ((date_trunc('month', p_joining) + interval '1 month - 1 day')::date - p_joining + 1)
                 / extract(day from (date_trunc('month', p_joining) + interval '1 month - 1 day'))::numeric, 0)
    else p_fee
  end;
$$;

-- d) calendar generator: joining month pro-rata, periods filled; still skips existing rows
create or replace function public.generate_monthly_dues(p_month date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare cnt int := 0; r record; m_start date := date_trunc('month', p_month)::date;
        m_end date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
begin
  for r in
    select id, hostel_id, monthly_fee, joining_date from public.students
    where status = 'active'
      and joining_date is not null
      and date_trunc('month', joining_date)::date <= m_start   -- future joiners skip
      and coalesce(monthly_fee, 0) > 0                          -- zero/null fee skip
  loop
    insert into public.monthly_dues(student_id, hostel_id, month, fee_amount, period_from, period_to)
    values (r.id, r.hostel_id, m_start, public.ddd_month_fee(r.monthly_fee, r.joining_date, m_start),
            greatest(m_start, r.joining_date), m_end)
    on conflict (student_id, month) do nothing;
    cnt := cnt + 1;
  end loop;
  return cnt;
end; $function$;

-- e) never-billed fallback = day before joining date
create or replace function public.compute_paid_till(p_student uuid, p_joining date, p_fee numeric)
returns date language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from monthly_dues where student_id = p_student and coalesce(pending, 0) > 0)
      then (select min(coalesce(period_from, month)) - 1
              from monthly_dues where student_id = p_student and coalesce(pending, 0) > 0)
    when exists (select 1 from monthly_dues where student_id = p_student)
      then (select max(coalesce(period_to, (date_trunc('month', month) + interval '1 month - 1 day')::date))
              from monthly_dues where student_id = p_student)
    when p_joining is not null and coalesce(p_fee, 0) > 0
      then p_joining - 1
    else null
  end;
$$;

-- record_fee_payment (014) with pro-rata joining month
create or replace function public.record_fee_payment(
  p_student_id     uuid,
  p_months         int,
  p_amount         numeric,
  p_discount       numeric default 0,
  p_mode           text    default 'cash',
  p_payment_date   date    default null,
  p_transaction_id text    default null,
  p_remarks        text    default null,
  p_group_id       uuid    default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s            public.students%rowtype;
  v_group      uuid := coalesce(p_group_id, gen_random_uuid());
  v_today      date := (now() at time zone 'Asia/Kolkata')::date;
  v_pdate      date := coalesce(p_payment_date, (now() at time zone 'Asia/Kolkata')::date);
  v_mode       text;
  v_receipt    text;
  v_start      date;
  m            date;
  d            public.monthly_dues%rowtype;
  v_months     date[]    := '{}';
  v_due_ids    uuid[]    := '{}';
  v_owed       numeric[] := '{}';
  v_gross      numeric := 0;
  v_plan_disc  numeric := 0;
  v_disc       numeric;
  v_disc_i     numeric;
  v_disc_left  numeric;
  i            int;
  v_guard      int := 0;
  v_paid_till  date;
begin
  -- idempotency (double submit)
  if p_group_id is not null and exists (select 1 from fee_payments where advance_group_id = p_group_id) then
    return (select jsonb_build_object(
              'group_id', p_group_id, 'duplicate', true,
              'receipt_number', min(receipt_number),
              'period_from', min(period_from), 'period_to', max(period_to),
              'months', count(*), 'net', sum(amount), 'discount', sum(discount_amount),
              'gross', sum(amount + discount_amount),
              'paid_till', (select paid_till from students where id = min(student_id::text)::uuid))
            from fee_payments where advance_group_id = p_group_id);
  end if;

  select * into s from students where id = p_student_id for update;   -- serialises payments per student
  if not found then raise exception 'Student not found'; end if;

  -- same access rule as fee_payments_write RLS
  if not (auth.uid() is null                                   -- SQL editor / service role
          or is_director() or is_accountant()
          or s.hostel_id in (select my_hostels())) then
    raise exception 'Not allowed for this hostel' using errcode = '42501';
  end if;

  if coalesce((select value from app_settings where key = 'billing_mode'), 'calendar') <> 'calendar' then
    raise exception 'Multi-month payment works only in calendar billing mode';
  end if;
  if p_months is null or p_months < 1 or p_months > 36 then
    raise exception 'Months must be between 1 and 36';
  end if;
  if s.joining_date is null then
    raise exception 'Student has no Joining Date — set it first';
  end if;
  if coalesce(s.monthly_fee, 0) <= 0 then
    raise exception 'Student Monthly Fee is 0 — set it first';
  end if;
  if coalesce(p_discount, 0) < 0 or p_amount is null or p_amount < 0 then
    raise exception 'Amount/discount cannot be negative';
  end if;
  if coalesce(p_discount, 0) > 0 and auth.uid() is not null and not is_director() then
    raise exception 'Only the Director can give a discount' using errcode = '42501';
  end if;
  if v_pdate > v_today then
    raise exception 'Payment date cannot be in the future';
  end if;
  v_mode := coalesce(nullif(trim(p_mode), ''), 'cash');

  -- first month to cover: earliest unpaid due, else month after last due,
  -- else joining month
  select min(date_trunc('month', month))::date into v_start
    from monthly_dues where student_id = s.id and coalesce(pending, 0) > 0;
  if v_start is null then
    select (max(date_trunc('month', month)) + interval '1 month')::date into v_start
      from monthly_dues where student_id = s.id;
  end if;
  v_start := coalesce(v_start, date_trunc('month', s.joining_date)::date);

  -- collect the next p_months not-fully-paid calendar months
  m := v_start;
  while coalesce(array_length(v_months, 1), 0) < p_months loop
    v_guard := v_guard + 1;
    if v_guard > 240 then raise exception 'Could not find % unpaid months', p_months; end if;
    select * into d from monthly_dues
     where student_id = s.id and date_trunc('month', month) = m
     order by month limit 1;
    if not found then
      insert into monthly_dues(student_id, hostel_id, month, fee_amount, period_from, period_to, created_by)
      values (s.id, s.hostel_id, m, public.ddd_month_fee(s.monthly_fee, s.joining_date, m),
              greatest(m, s.joining_date), (m + interval '1 month - 1 day')::date, auth.uid())
      returning * into d;
    end if;
    if coalesce(d.pending, 0) > 0 then
      v_months  := v_months  || coalesce(d.period_from, m);
      v_due_ids := v_due_ids || d.id;
      v_owed    := v_owed    || d.pending;
      v_gross   := v_gross + d.pending;
    end if;
    m := (m + interval '1 month')::date;
  end loop;

  -- pre-approved plan discount (Director set plan_amount below standard)
  if p_months = s.plan_months and s.plan_amount is not null
     and s.plan_amount < round(s.monthly_fee * s.plan_months, 2) then
    v_plan_disc := round(s.monthly_fee * s.plan_months, 2) - s.plan_amount;
  end if;
  v_disc := least(v_gross, v_plan_disc + coalesce(p_discount, 0));

  if round(p_amount, 2) <> round(v_gross - v_disc, 2) then
    raise exception 'Amount mismatch: expected % (gross % - discount %), got %',
      round(v_gross - v_disc, 2), v_gross, v_disc, p_amount;
  end if;

  v_receipt := 'R-' || to_char(v_pdate, 'YYMMDD') || '-' || upper(substr(replace(v_group::text, '-', ''), 1, 6));

  -- allocate discount proportionally; remainder on the last month
  v_disc_left := v_disc;
  for i in 1 .. array_length(v_months, 1) loop
    if i = array_length(v_months, 1) then
      v_disc_i := v_disc_left;
    else
      v_disc_i := round(v_disc * v_owed[i] / nullif(v_gross, 0), 2);
      v_disc_i := least(v_disc_i, v_disc_left, v_owed[i]);
    end if;
    v_disc_left := v_disc_left - v_disc_i;

    update monthly_dues
       set discount    = coalesce(discount, 0) + v_disc_i,
           paid_amount = coalesce(paid_amount, 0) + (v_owed[i] - v_disc_i),
           status      = 'paid',
           period_from = coalesce(period_from, v_months[i]),
           period_to   = coalesce(period_to, (date_trunc('month', v_months[i]) + interval '1 month - 1 day')::date)
     where id = v_due_ids[i];

    insert into fee_payments(id, due_id, student_id, hostel_id, amount, discount_amount, payment_date,
                             mode, transaction_id, receipt_number, remarks, period_from, period_to,
                             advance_group_id, collected_by, created_by)
    values (gen_random_uuid(), v_due_ids[i], s.id, s.hostel_id, v_owed[i] - v_disc_i, v_disc_i, v_pdate,
            v_mode, p_transaction_id, v_receipt, p_remarks, v_months[i],
            (date_trunc('month', v_months[i]) + interval '1 month - 1 day')::date,
            v_group, auth.uid(), auth.uid());
  end loop;

  v_paid_till := public.recompute_paid_till(s.id);

  return jsonb_build_object(
    'group_id', v_group, 'duplicate', false, 'receipt_number', v_receipt,
    'period_from', v_months[1],
    'period_to', (date_trunc('month', v_months[array_length(v_months, 1)]) + interval '1 month - 1 day')::date,
    'months', array_length(v_months, 1),
    'gross', v_gross, 'discount', v_disc, 'net', v_gross - v_disc,
    'paid_till', v_paid_till);
end $$;

-- record_partial_payment (016) with pro-rata joining month
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
      values (s.id, s.hostel_id, m, public.ddd_month_fee(s.monthly_fee, s.joining_date, m),
              greatest(m, s.joining_date), (m + interval '1 month - 1 day')::date, auth.uid())
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
              v_mode, p_transaction_id, v_receipt, coalesce(p_remarks, 'Partial payment'), coalesce(d.period_from, m),
              (m + interval '1 month - 1 day')::date, v_group, auth.uid(), auth.uid());
      v_n := v_n + 1;
      v_first := coalesce(v_first, coalesce(d.period_from, m));
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

revoke all on function public.ddd_month_fee(numeric, date, date) from anon;
grant execute on function public.ddd_month_fee(numeric, date, date) to authenticated;
revoke all on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) to authenticated;
revoke all on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) to authenticated;
revoke all on function public.compute_paid_till(uuid, date, numeric) from public, anon, authenticated;

-- refresh paid_till only for never-billed students (no dues rows) — nothing else changes
update public.students s set paid_till = public.compute_paid_till(s.id)
 where not exists (select 1 from public.monthly_dues d where d.student_id = s.id)
   and s.paid_till is distinct from public.compute_paid_till(s.id);

commit;
