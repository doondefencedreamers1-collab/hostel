-- =====================================================================
-- 014_fee_plan_paid_till.sql
-- DDD Hostel — Fee Plans + Advance Payments + "Paid Till" + Director-only discount
--
-- Run ONCE in Supabase SQL Editor (whole file). Safe to re-run (idempotent).
-- Runs in one transaction: if anything fails, nothing is changed.
--
-- What it does
--   A. Pre-checks (aborts safely if live schema is not what we expect)
--   B. New columns: students.fee_plan/plan_months/plan_amount/paid_till,
--                   fee_payments.discount_amount/advance_group_id
--   C. Director-only discount (DB-enforced) on monthly_dues + fee_payments
--      (+ manager/accountant cannot change a due's fee_amount = hidden discount)
--   D. students trigger: non-director plan_amount forced to monthly_fee x months;
--      paid_till is system-computed only
--   E. compute_paid_till / recompute_paid_till + auto-recompute on monthly_dues change
--   F. record_fee_payment(): atomic multi-month (advance) payment, calendar mode
--   G. generate_anniversary_dues fix (it inserted into generated columns)
--   H. app_settings: write = Director only, read = all logged-in users
--   I. Backfill
--   J. Director-only payment delete (whole advance group) + delete guards
--
-- Role lookup: uses the same is_director() / is_accountant() / my_hostels()
-- that the existing RLS policies use.
-- "Trusted" callers = anything not running as the API roles (authenticated/anon):
-- SQL Editor (postgres), service_role, and SECURITY DEFINER functions below.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- A. PRE-CHECKS
-- ---------------------------------------------------------------------
do $$
begin
  if (select attgenerated from pg_attribute
       where attrelid = 'public.monthly_dues'::regclass and attname = 'pending') is distinct from 's'
  or (select attgenerated from pg_attribute
       where attrelid = 'public.monthly_dues'::regclass and attname = 'payable') is distinct from 's' then
    raise exception '014 aborted: monthly_dues.payable/pending are not generated columns on this DB. Send this message to the developer.';
  end if;
  if to_regprocedure('public.is_director()') is null
  or to_regprocedure('public.is_accountant()') is null
  or to_regprocedure('public.my_hostels()') is null then
    raise exception '014 aborted: is_director()/is_accountant()/my_hostels() missing.';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.monthly_dues'::regclass
                    and pg_get_constraintdef(oid) = 'UNIQUE (student_id, month)') then
    raise exception '014 aborted: UNIQUE(student_id, month) on monthly_dues not found.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- B. COLUMNS
-- ---------------------------------------------------------------------
alter table public.students
  add column if not exists fee_plan    text          default 'monthly',
  add column if not exists plan_months int           default 1,
  add column if not exists plan_amount numeric(10,2),
  add column if not exists paid_till   date;

alter table public.fee_payments
  add column if not exists discount_amount  numeric(10,2) default 0,
  add column if not exists advance_group_id uuid;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'students_fee_plan_chk') then
    alter table public.students add constraint students_fee_plan_chk
      check (fee_plan in ('monthly','quarterly','half_yearly','yearly','two_year','custom'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'students_plan_months_chk') then
    alter table public.students add constraint students_plan_months_chk
      check (plan_months between 1 and 36);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'students_plan_amount_chk') then
    alter table public.students add constraint students_plan_amount_chk
      check (plan_amount is null or plan_amount >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'fee_payments_discount_chk') then
    alter table public.fee_payments add constraint fee_payments_discount_chk
      check (discount_amount >= 0);
  end if;
end $$;

create index if not exists idx_fee_payments_group   on public.fee_payments(advance_group_id) where advance_group_id is not null;
create index if not exists idx_fee_payments_student on public.fee_payments(student_id);

-- ---------------------------------------------------------------------
-- helper: is the current caller an end-user API role (not SQL editor / definer fn)?
-- ---------------------------------------------------------------------
create or replace function public.ddd_is_api_caller() returns boolean
language sql stable as $$
  select current_user in ('authenticated', 'anon');
$$;

-- ---------------------------------------------------------------------
-- C. DIRECTOR-ONLY DISCOUNT (DB enforced)
-- ---------------------------------------------------------------------
create or replace function public.ddd_guard_due_discount() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() and not public.is_director() then
    if tg_op = 'INSERT' then
      if coalesce(new.discount, 0) <> 0 then
        raise exception 'Only the Director can give a discount' using errcode = '42501';
      end if;
      -- a lower fee_amount than the student''s fee is a hidden discount
      if new.fee_amount < coalesce((select monthly_fee from public.students where id = new.student_id), 0) then
        raise exception 'Only the Director can reduce a due amount' using errcode = '42501';
      end if;
    else
      if new.discount is distinct from old.discount then
        raise exception 'Only the Director can give a discount' using errcode = '42501';
      end if;
      if new.fee_amount is distinct from old.fee_amount then
        raise exception 'Only the Director can change a due amount' using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_monthly_dues_discount_guard on public.monthly_dues;
create trigger trg_monthly_dues_discount_guard
  before insert or update on public.monthly_dues
  for each row execute function public.ddd_guard_due_discount();

create or replace function public.ddd_guard_payment_discount() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() and not public.is_director() then
    if (tg_op = 'INSERT' and coalesce(new.discount_amount, 0) <> 0)
    or (tg_op = 'UPDATE' and new.discount_amount is distinct from old.discount_amount) then
      raise exception 'Only the Director can give a discount' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_fee_payments_discount_guard on public.fee_payments;
create trigger trg_fee_payments_discount_guard
  before insert or update on public.fee_payments
  for each row execute function public.ddd_guard_payment_discount();

-- ---------------------------------------------------------------------
-- D. STUDENTS: plan normalisation + plan_amount lock + paid_till protection
-- ---------------------------------------------------------------------
create or replace function public.ddd_students_fee_plan() returns trigger
language plpgsql as $$
declare
  v_trusted boolean := not public.ddd_is_api_caller() or public.is_director();
  v_auto    numeric;
begin
  new.fee_plan := coalesce(new.fee_plan, 'monthly');
  new.plan_months := case new.fee_plan
                       when 'monthly'     then 1
                       when 'quarterly'   then 3
                       when 'half_yearly' then 6
                       when 'yearly'      then 12
                       when 'two_year'    then 24
                       else coalesce(new.plan_months, 1)
                     end;
  v_auto := round(coalesce(new.monthly_fee, 0) * new.plan_months, 2);

  if tg_op = 'INSERT' then
    if new.plan_amount is null or not v_trusted then
      new.plan_amount := v_auto;
    end if;
    if public.ddd_is_api_caller() then
      new.paid_till := null;                 -- system-computed only (set by AFTER trigger)
    end if;
  else
    if new.plan_amount is null then
      new.plan_amount := v_auto;
    elsif new.plan_amount is distinct from old.plan_amount then
      -- someone typed a plan amount: only Director may set a non-standard one
      if not v_trusted then new.plan_amount := v_auto; end if;
    elsif new.monthly_fee is distinct from old.monthly_fee
       or new.plan_months is distinct from old.plan_months then
      -- fee or plan changed but amount untouched -> recalc standard amount
      new.plan_amount := v_auto;
    end if;
    if public.ddd_is_api_caller() then
      new.paid_till := old.paid_till;        -- system-computed only
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_students_fee_plan on public.students;
create trigger trg_students_fee_plan
  before insert or update on public.students
  for each row execute function public.ddd_students_fee_plan();

-- ---------------------------------------------------------------------
-- E. PAID TILL
--   paid_till = day before the student's FIRST not-fully-paid due;
--               if every due is paid -> last day of the latest due;
--               no dues at all -> day before the JOINING month
--               (so a never-billed student shows due from joining month);
--               no joining date or zero fee -> NULL.
--   (Earlier unpaid months are never hidden by later advance months.)
-- ---------------------------------------------------------------------
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
      then (date_trunc('month', p_joining)::date - 1)
    else null
  end;
$$;

create or replace function public.compute_paid_till(p_student uuid) returns date
language sql stable security definer set search_path = public as $$
  select public.compute_paid_till(s.id, s.joining_date, s.monthly_fee) from students s where s.id = p_student;
$$;

create or replace function public.recompute_paid_till(p_student uuid) returns date
language plpgsql security definer set search_path = public as $$
declare v date;
begin
  v := public.compute_paid_till(p_student);
  update public.students set paid_till = v
   where id = p_student and paid_till is distinct from v;
  return v;
end $$;

create or replace function public.ddd_dues_recompute_paid_till() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.recompute_paid_till(old.student_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.student_id is distinct from
     (case when tg_op = 'UPDATE' then old.student_id end) then
    perform public.recompute_paid_till(new.student_id);
  end if;
  return null;
end $$;

drop trigger if exists trg_monthly_dues_paid_till on public.monthly_dues;
create trigger trg_monthly_dues_paid_till
  after insert or update or delete on public.monthly_dues
  for each row execute function public.ddd_dues_recompute_paid_till();

-- new student / joining date or fee changed -> recompute (never-billed students
-- are due from their joining month)
create or replace function public.ddd_students_recompute_paid_till() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.recompute_paid_till(new.id);
  return null;
end $$;

drop trigger if exists trg_students_paid_till on public.students;
create trigger trg_students_paid_till
  after insert or update of joining_date, monthly_fee on public.students
  for each row execute function public.ddd_students_recompute_paid_till();

-- ---------------------------------------------------------------------
-- F. record_fee_payment(): one atomic call for 1..36 months (calendar mode)
--   * covers the next N not-fully-paid calendar months, starting from the
--     first unpaid one (overdue first, then advance). Already-paid months are
--     skipped, so paid periods can never overlap.
--   * upserts each month's monthly_dues row and marks it fully paid
--   * one fee_payments row per month, same receipt_number + advance_group_id
--   * discount: p_discount (Director only) + pre-approved plan discount
--     (Director-set plan_amount < monthly_fee x plan_months, only when
--     paying exactly plan_months)
--   * p_amount must equal gross - discount (no partial months here)
--   * idempotent: same p_group_id twice -> returns the first result
-- ---------------------------------------------------------------------
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
      values (s.id, s.hostel_id, m, s.monthly_fee, m, (m + interval '1 month - 1 day')::date, auth.uid())
      returning * into d;
    end if;
    if coalesce(d.pending, 0) > 0 then
      v_months  := v_months  || m;
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
           period_to   = coalesce(period_to, (v_months[i] + interval '1 month - 1 day')::date)
     where id = v_due_ids[i];

    insert into fee_payments(id, due_id, student_id, hostel_id, amount, discount_amount, payment_date,
                             mode, transaction_id, receipt_number, remarks, period_from, period_to,
                             advance_group_id, collected_by, created_by)
    values (gen_random_uuid(), v_due_ids[i], s.id, s.hostel_id, v_owed[i] - v_disc_i, v_disc_i, v_pdate,
            v_mode, p_transaction_id, v_receipt, p_remarks, v_months[i],
            (v_months[i] + interval '1 month - 1 day')::date,
            v_group, auth.uid(), auth.uid());
  end loop;

  v_paid_till := public.recompute_paid_till(s.id);

  return jsonb_build_object(
    'group_id', v_group, 'duplicate', false, 'receipt_number', v_receipt,
    'period_from', v_months[1],
    'period_to', (v_months[array_length(v_months, 1)] + interval '1 month - 1 day')::date,
    'months', array_length(v_months, 1),
    'gross', v_gross, 'discount', v_disc, 'net', v_gross - v_disc,
    'paid_till', v_paid_till);
end $$;

-- ---------------------------------------------------------------------
-- G. generate_anniversary_dues: FIX (it inserted into generated columns
--    payable/pending -> every insert failed). Now sets fee_amount instead.
--    Logic otherwise unchanged; still skips if a row for that cycle exists.
-- ---------------------------------------------------------------------
create or replace function public.generate_anniversary_dues(p_today date default current_date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  s            record;
  anchor       int;
  c_start      date;
  c_end        date;
  cand         date;
  next_anchor  date;
  made         int := 0;
begin
  for s in
    select id, hostel_id, monthly_fee, joining_date
    from public.students
    where coalesce(status, 'active') = 'active'
      and joining_date is not null
      and coalesce(monthly_fee, 0) > 0
  loop
    anchor := extract(day from s.joining_date)::int;
    cand := make_date(
      extract(year  from p_today)::int,
      extract(month from p_today)::int,
      least(anchor, extract(day from (date_trunc('month', p_today) + interval '1 month - 1 day'))::int));
    if cand > p_today then
      c_start := make_date(
        extract(year  from (p_today - interval '1 month'))::int,
        extract(month from (p_today - interval '1 month'))::int,
        least(anchor, extract(day from (date_trunc('month', (p_today - interval '1 month')) + interval '1 month - 1 day'))::int));
    else
      c_start := cand;
    end if;
    next_anchor := make_date(
      extract(year  from (c_start + interval '1 month'))::int,
      extract(month from (c_start + interval '1 month'))::int,
      least(anchor, extract(day from (date_trunc('month', (c_start + interval '1 month')) + interval '1 month - 1 day'))::int));
    c_end := next_anchor - 1;

    if not exists (select 1 from public.monthly_dues d
                    where d.student_id = s.id and d.month = c_start) then
      insert into public.monthly_dues
        (student_id, hostel_id, month, fee_amount, paid_amount, status, period_from, period_to)
      values
        (s.id, s.hostel_id, c_start, s.monthly_fee, 0, 'pending', c_start, c_end);
      made := made + 1;
    end if;
  end loop;
  return made;
end;
$function$;
-- generate_monthly_dues: NOT changed (already "on conflict (student_id, month) do nothing").

-- ---------------------------------------------------------------------
-- H. app_settings: read = logged-in, write = Director only
-- ---------------------------------------------------------------------
drop policy if exists app_settings_rw     on public.app_settings;
drop policy if exists app_settings_read   on public.app_settings;
drop policy if exists app_settings_insert on public.app_settings;
drop policy if exists app_settings_update on public.app_settings;
drop policy if exists app_settings_delete on public.app_settings;
create policy app_settings_read   on public.app_settings for select to authenticated using (true);
create policy app_settings_insert on public.app_settings for insert to authenticated with check (public.is_director());
create policy app_settings_update on public.app_settings for update to authenticated using (public.is_director()) with check (public.is_director());
create policy app_settings_delete on public.app_settings for delete to authenticated using (public.is_director());

-- ---------------------------------------------------------------------
-- J. PAYMENT DELETE — Director only, whole advance group at once
--   delete_fee_payment(payment_id):
--     * Director only (checked here AND by the guard triggers below)
--     * payment in an advance group -> the whole group is deleted;
--       legacy payment (no group) -> just that one payment
--     * each linked due gets back exactly what that payment added
--       (paid_amount and discount), then:
--         - month not yet started (after current IST month) and nothing
--           else paid on it -> due row removed (pre-created advance month)
--         - otherwise -> status pending / partial again
--     * paid_till recomputed
--   Guards: app users (API) cannot delete fee_payments directly at all;
--   non-Directors cannot delete a monthly_dues row or a student that has
--   payments (that would cascade-delete the payments).
-- ---------------------------------------------------------------------
create or replace function public.delete_fee_payment(p_payment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f          public.fee_payments%rowtype;
  v_ids      uuid[];
  v_dues     uuid[];
  v_student  uuid;
  v_cur      date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  r          record;
  v_removed  int := 0;
  v_reset    int := 0;
  v_rows     int;
  v_amount   numeric;
  v_paid_till date;
begin
  if not (auth.uid() is null or is_director()) then
    raise exception 'Only the Director can delete payments' using errcode = '42501';
  end if;

  select * into f from fee_payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  v_student := f.student_id;
  perform 1 from students where id = v_student for update;

  if f.advance_group_id is not null then
    select array_agg(id) into v_ids from fee_payments where advance_group_id = f.advance_group_id;
  else
    v_ids := array[f.id];
  end if;
  select count(*), coalesce(sum(amount), 0) into v_rows, v_amount from fee_payments where id = any(v_ids);
  select coalesce(array_agg(distinct due_id), '{}') into v_dues
    from fee_payments where id = any(v_ids) and due_id is not null;

  -- give back to each linked due exactly what these payments added
  for r in
    select due_id, sum(amount) amt, sum(coalesce(discount_amount, 0)) disc
      from fee_payments where id = any(v_ids) and due_id is not null
     group by due_id
  loop
    update monthly_dues
       set paid_amount = greatest(coalesce(paid_amount, 0) - r.amt, 0),
           discount    = greatest(coalesce(discount, 0) - r.disc, 0)
     where id = r.due_id;
  end loop;

  delete from fee_payments where id = any(v_ids);

  -- future month with nothing else paid -> remove; otherwise pending/partial
  for r in select id, month, paid_amount from monthly_dues where id = any(v_dues) loop
    if date_trunc('month', r.month)::date > v_cur
       and coalesce(r.paid_amount, 0) = 0
       and not exists (select 1 from fee_payments where due_id = r.id) then
      delete from monthly_dues where id = r.id;
      v_removed := v_removed + 1;
    else
      update monthly_dues
         set status = case when coalesce(paid_amount, 0) <= 0 then 'pending'
                           when coalesce(pending, 0) > 0     then 'partial'
                           else 'paid' end
       where id = r.id;
      v_reset := v_reset + 1;
    end if;
  end loop;

  v_paid_till := public.recompute_paid_till(v_student);
  return jsonb_build_object('deleted_payments', v_rows, 'amount', v_amount,
                            'dues_removed', v_removed, 'dues_reset', v_reset,
                            'paid_till', v_paid_till);
end $$;

create or replace function public.ddd_guard_payment_delete() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() then
    raise exception 'Payments can only be deleted by the Director (Delete Payment button)'
      using errcode = '42501';
  end if;
  return old;
end $$;

drop trigger if exists trg_fee_payments_delete_guard on public.fee_payments;
create trigger trg_fee_payments_delete_guard
  before delete on public.fee_payments
  for each row execute function public.ddd_guard_payment_delete();

create or replace function public.ddd_guard_due_delete() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() and not public.is_director()
     and exists (select 1 from public.fee_payments where due_id = old.id) then
    raise exception 'This due has payments — only the Director can remove it' using errcode = '42501';
  end if;
  return old;
end $$;

drop trigger if exists trg_monthly_dues_delete_guard on public.monthly_dues;
create trigger trg_monthly_dues_delete_guard
  before delete on public.monthly_dues
  for each row execute function public.ddd_guard_due_delete();

-- deleting a student cascades to its payments -> Director only if payments exist
create or replace function public.ddd_guard_student_delete() returns trigger
language plpgsql as $$
begin
  if public.ddd_is_api_caller() and not public.is_director()
     and exists (select 1 from public.fee_payments where student_id = old.id) then
    raise exception 'Student has fee payments — only the Director can delete. Set Status = Left instead.'
      using errcode = '42501';
  end if;
  return old;
end $$;

drop trigger if exists trg_students_delete_guard on public.students;
create trigger trg_students_delete_guard
  before delete on public.students
  for each row execute function public.ddd_guard_student_delete();

-- ---------------------------------------------------------------------
-- Function permissions
-- ---------------------------------------------------------------------
revoke all on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) to authenticated;
revoke all on function public.recompute_paid_till(uuid) from public, anon, authenticated;
revoke all on function public.compute_paid_till(uuid)   from public, anon, authenticated;
revoke all on function public.compute_paid_till(uuid, date, numeric) from public, anon, authenticated;
revoke all on function public.ddd_dues_recompute_paid_till() from public, anon, authenticated;
revoke all on function public.ddd_students_recompute_paid_till() from public, anon, authenticated;
revoke all on function public.delete_fee_payment(uuid) from public, anon;
grant execute on function public.delete_fee_payment(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- I. BACKFILL (idempotent)
-- ---------------------------------------------------------------------
-- legacy payments: period = their due's cycle where missing; discount 0
update public.fee_payments f
   set period_from = coalesce(f.period_from, d.period_from, date_trunc('month', d.month)::date),
       period_to   = coalesce(f.period_to,   d.period_to,   (date_trunc('month', d.month) + interval '1 month - 1 day')::date)
  from public.monthly_dues d
 where d.id = f.due_id and (f.period_from is null or f.period_to is null);
update public.fee_payments set discount_amount = 0 where discount_amount is null;

-- students: plan defaults (only where not set yet) + paid_till for everyone
update public.students s
   set fee_plan    = coalesce(s.fee_plan, 'monthly'),
       plan_months = coalesce(s.plan_months, 1),
       plan_amount = coalesce(s.plan_amount, round(coalesce(s.monthly_fee, 0) * coalesce(s.plan_months, 1), 2)),
       paid_till   = public.compute_paid_till(s.id)
 where s.plan_amount is null
    or s.fee_plan is null
    or s.paid_till is distinct from public.compute_paid_till(s.id);

commit;

-- ---------------------------------------------------------------------
-- AFTER RUNNING: quick check (read-only)
-- ---------------------------------------------------------------------
-- select count(*) filter (where paid_till is not null) with_paid_till,
--        count(*) filter (where paid_till is null)     never_billed,
--        count(*) filter (where paid_till < (now() at time zone 'Asia/Kolkata')::date) overdue_now
--   from students where status = 'active';
