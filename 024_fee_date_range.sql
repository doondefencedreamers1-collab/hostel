-- =====================================================================
-- 024_fee_date_range.sql   Receive Fee: "kab se kab tak" (custom date range)
-- needs: 014, 015, 016, 017, 022 live + 024_run_checks.sql STEP 2 (backup)
--
--  * monthly_dues.paid_to = last day of that due already paid (auto, trigger).
--    Partial month: pay 01-15 Sep -> Sep paid_to = 15-09, rest pending.
--  * paid_till = paid_to of the first unpaid due (so 15-09-2026, not 31-08).
--  * Day share of a month = round(fee x day / days-in-month) (cumulative, so
--    pieces always add up); a piece that reaches the end of a due = the rest
--    of that due (full months = full fee).
--  * record_fee_payment_range(student, from, to, amount, ...) — new RPC:
--    no overlap, no gap inside a month, from >= joining, to <= exit date,
--    old unpaid days first (only the Director may skip), discount Director
--    only, idempotent (p_group_id), one receipt / advance_group_id,
--    exact period_from / period_to on every fee_payments row.
--  * record_fee_payment (N months) + record_partial_payment: same rules as
--    before, now save exact dates too.
--  * edit_fee_payment_dates(payment, from, to, reason) — Director only;
--    same money, new dates; history in fee_payment_edits.
-- One transaction, safe to run twice. Undo: 024_undo.sql
-- =====================================================================
begin;

do $$
declare h text;
begin
  if to_regclass('backup_024.meta') is null then
    raise exception '024 aborted: pehle 024_run_checks.sql STEP 2 (backup) chalayein.';
  end if;
  if has_function_privilege('anon', 'public.generate_monthly_dues(date)', 'execute') then
    raise exception '024 aborted: 022 (security hotfix) pehle live hona chahiye.';
  end if;
  if to_regprocedure('public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)') is null then
    -- first run: live code must be exactly the repo 017 version we rewrite
    h := (select md5(prosrc) from pg_proc where oid = to_regprocedure('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)'));
    if h is distinct from 'f7b0b29c4d08c6dbf0c03bb7889cdcf1' then
      raise exception '024 aborted: live record_fee_payment repo (017) se alag hai (%). Mujhe batayein.', h;
    end if;
    h := (select md5(prosrc) from pg_proc where oid = to_regprocedure('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)'));
    if h is distinct from 'a03f7b49c697ae6adb99aad8daff0a00' then
      raise exception '024 aborted: live record_partial_payment repo (017) se alag hai (%). Mujhe batayein.', h;
    end if;
    h := (select md5(prosrc) from pg_proc where oid = to_regprocedure('public.compute_paid_till(uuid,date,numeric)'));
    if h is distinct from 'bd73404c4cea2c0f1568d84fdbb3728a' then
      raise exception '024 aborted: live compute_paid_till repo (017) se alag hai (%). Mujhe batayein.', h;
    end if;
  end if;
  if not exists (select 1 from backup_024.meta where k = 'fn:record_fee_payment') then
    raise exception '024 aborted: backup adhoora hai — STEP 2 dobara chalayein.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A. paid_to column + helpers
-- ---------------------------------------------------------------------
alter table public.monthly_dues add column if not exists paid_to date;

-- fee for the first p_k days of a month (cumulative, nearest rupee)
create or replace function public.ddd_cum_fee(p_full numeric, p_dim int, p_k int)
returns numeric language sql immutable set search_path = public as $$
  select round(coalesce(p_full, 0) * greatest(p_k, 0) / p_dim, 0);
$$;

-- full-month fee used for day shares of one due: the due's own fee when it
-- starts on the 1st, else (joining month) the student's monthly fee
create or replace function public.ddd_due_full_fee(p_month date, p_from date, p_fee_amount numeric, p_student_fee numeric)
returns numeric language sql immutable set search_path = public as $$
  select case when p_from is null or p_from <= date_trunc('month', p_month)::date then coalesce(p_fee_amount, 0)
              else coalesce(p_student_fee, 0) end;
$$;

-- last day of a due that its paid amount (+discount) covers
create or replace function public.ddd_due_paid_to(p_month date, p_from date, p_to date, p_fee_amount numeric,
                                                  p_discount numeric, p_paid numeric, p_student_fee numeric)
returns date language plpgsql immutable set search_path = public as $$
declare
  ms  date := date_trunc('month', p_month)::date;
  pf  date := coalesce(p_from, date_trunc('month', p_month)::date);
  pt  date := coalesce(p_to, (date_trunc('month', p_month) + interval '1 month - 1 day')::date);
  dim int  := extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::int;
  got numeric := coalesce(p_paid, 0) + coalesce(p_discount, 0);
  f   numeric;
  k0  int;
  k   int;
begin
  if coalesce(p_fee_amount, 0) - got <= 0 then return pt; end if;   -- nothing pending
  if got <= 0 then return pf - 1; end if;                          -- nothing paid
  f := public.ddd_due_full_fee(ms, pf, p_fee_amount, p_student_fee);
  if f <= 0 then return pf - 1; end if;
  k0 := extract(day from pf)::int - 1;
  k := k0;
  -- still pending -> never beyond the day before period end
  while ms + k <= pt - 1
        and public.ddd_cum_fee(f, dim, k + 1) - public.ddd_cum_fee(f, dim, k0) <= got loop
    k := k + 1;
  end loop;
  return ms + k - 1;
end $$;

create or replace function public.ddd_dues_set_paid_to() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.paid_to := public.ddd_due_paid_to(new.month, new.period_from, new.period_to, new.fee_amount,
                                        new.discount, new.paid_amount,
                                        (select monthly_fee from public.students where id = new.student_id));
  return new;
end $$;

drop trigger if exists trg_monthly_dues_paid_to on public.monthly_dues;
create trigger trg_monthly_dues_paid_to
  before insert or update on public.monthly_dues
  for each row execute function public.ddd_dues_set_paid_to();

-- ---------------------------------------------------------------------
-- B. paid_till = paid_to of the first unpaid due
-- ---------------------------------------------------------------------
create or replace function public.compute_paid_till(p_student uuid, p_joining date, p_fee numeric)
returns date language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from monthly_dues where student_id = p_student and coalesce(pending, 0) > 0)
      then (select coalesce(d.paid_to, coalesce(d.period_from, d.month) - 1)
              from monthly_dues d where d.student_id = p_student and coalesce(d.pending, 0) > 0
             order by coalesce(d.period_from, d.month), d.month limit 1)
    when exists (select 1 from monthly_dues where student_id = p_student)
      then (select max(coalesce(period_to, (date_trunc('month', month) + interval '1 month - 1 day')::date))
              from monthly_dues where student_id = p_student)
    when p_joining is not null and coalesce(p_fee, 0) > 0
      then p_joining - 1
    else null
  end;
$$;

-- ---------------------------------------------------------------------
-- C. plan a date range: one piece per calendar month (creates missing dues)
-- ---------------------------------------------------------------------
create or replace function public.ddd_fee_range_plan(p_sid uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s    public.students%rowtype;
  d    public.monthly_dues%rowtype;
  m    date;
  me   date;
  a    date;
  b    date;
  v_id uuid;
  f    numeric;
  dim  int;
  owed numeric;
  ptd  date;
  out  jsonb := '[]';
begin
  s := (select x from public.students x where x.id = p_sid);
  if s.id is null then raise exception 'Student not found'; end if;
  if p_from is null or p_to is null then raise exception 'From aur To date dono chahiye'; end if;
  if p_to < p_from then raise exception 'To date From date se pehle nahi ho sakti'; end if;
  if s.joining_date is not null and p_from < s.joining_date then
    raise exception 'From date joining date (%) se pehle nahi ho sakti', to_char(s.joining_date, 'DD-MM-YYYY');
  end if;
  if s.exit_date is not null and p_to > s.exit_date then
    raise exception 'To date exit date (%) ke baad nahi ho sakti', to_char(s.exit_date, 'DD-MM-YYYY');
  end if;
  if (extract(year from p_to) * 12 + extract(month from p_to)) - (extract(year from p_from) * 12 + extract(month from p_from)) + 1 > 36 then
    raise exception 'Ek baar mein zyada se zyada 36 months';
  end if;

  m := date_trunc('month', p_from)::date;
  while m <= p_to loop
    me := (m + interval '1 month - 1 day')::date;
    a := greatest(p_from, m);
    b := least(p_to, me);
    d := (select x from public.monthly_dues x
           where x.student_id = s.id and date_trunc('month', x.month) = m
           order by x.month limit 1 for update);
    if d.id is null then
      v_id := gen_random_uuid();
      insert into public.monthly_dues(id, student_id, hostel_id, month, fee_amount, period_from, period_to, created_by)
      values (v_id, s.id, s.hostel_id, m, public.ddd_month_fee(s.monthly_fee, s.joining_date, m),
              greatest(m, coalesce(s.joining_date, m)), me, auth.uid());
      d := (select x from public.monthly_dues x where x.id = v_id);
    end if;
    if a < coalesce(d.period_from, m) or b > coalesce(d.period_to, me) then
      raise exception '% ki due % se % tak hai — dates iske andar honi chahiye', to_char(m, 'Mon YYYY'),
        to_char(coalesce(d.period_from, m), 'DD-MM-YYYY'), to_char(coalesce(d.period_to, me), 'DD-MM-YYYY');
    end if;
    ptd := coalesce(d.paid_to, coalesce(d.period_from, m) - 1);
    if a <= ptd then
      raise exception 'Yeh dates pehle se paid hain (% mein % tak paid)', to_char(m, 'Mon YYYY'), to_char(ptd, 'DD-MM-YYYY');
    end if;
    if a > ptd + 1 then
      raise exception 'Beech ke din khali nahi chhod sakte — % mein % se shuru karein', to_char(m, 'Mon YYYY'), to_char(ptd + 1, 'DD-MM-YYYY');
    end if;
    if b = coalesce(d.period_to, me) then
      owed := coalesce(d.pending, 0);
    else
      dim := extract(day from me)::int;
      f := public.ddd_due_full_fee(m, d.period_from, d.fee_amount, s.monthly_fee);
      owed := least(coalesce(d.pending, 0),
                    public.ddd_cum_fee(f, dim, extract(day from b)::int) - public.ddd_cum_fee(f, dim, extract(day from a)::int - 1));
    end if;
    out := out || jsonb_build_object('due_id', d.id, 'month', m, 'from', a, 'to', b, 'owed', owed,
                                     'whole', (a = coalesce(d.period_from, m) and b = coalesce(d.period_to, me)));
    m := (m + interval '1 month')::date;
  end loop;
  return out;
end $$;

-- ---------------------------------------------------------------------
-- D. record_fee_payment_range — "Dates chuno"
-- ---------------------------------------------------------------------
create or replace function public.record_fee_payment_range(
  p_student_id     uuid,
  p_from           date,
  p_to             date,
  p_amount         numeric,
  p_discount       numeric default 0,
  p_mode           text    default 'cash',
  p_payment_date   date    default null,
  p_transaction_id text    default null,
  p_remarks        text    default null,
  p_group_id       uuid    default null,
  p_skip_overdue   boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s           public.students%rowtype;
  v_group     uuid := coalesce(p_group_id, gen_random_uuid());
  v_today     date := (now() at time zone 'Asia/Kolkata')::date;
  v_pdate     date := coalesce(p_payment_date, (now() at time zone 'Asia/Kolkata')::date);
  v_mode      text := coalesce(nullif(trim(p_mode), ''), 'cash');
  v_receipt   text;
  v_first     date;
  v_plan      jsonb;
  pc          jsonb;
  n           int;
  i           int;
  v_gross     numeric := 0;
  v_whole     boolean := true;
  v_plan_disc numeric := 0;
  v_disc      numeric;
  v_disc_i    numeric;
  v_disc_left numeric;
  v_owed      numeric;
  v_last_due  uuid;
  v_balance   numeric;
  v_paid_till date;
begin
  if p_group_id is not null and exists (select 1 from fee_payments where advance_group_id = p_group_id) then
    return (select jsonb_build_object(
              'group_id', p_group_id, 'duplicate', true,
              'receipt_number', min(receipt_number),
              'period_from', min(period_from), 'period_to', max(period_to),
              'months', count(*), 'net', sum(amount), 'discount', sum(discount_amount),
              'gross', sum(amount + discount_amount),
              'breakdown', jsonb_agg(jsonb_build_object('month', date_trunc('month', period_from)::date, 'from', period_from,
                                                        'to', period_to, 'owed', amount + discount_amount) order by period_from),
              'paid_till', (select paid_till from students where id = min(student_id::text)::uuid))
            from fee_payments where advance_group_id = p_group_id);
  end if;

  s := (select x from students x where x.id = p_student_id for update);   -- serialises payments per student
  if s.id is null then raise exception 'Student not found'; end if;
  if not (auth.uid() is null or is_director() or is_accountant()
          or s.hostel_id in (select my_hostels())) then
    raise exception 'Not allowed for this hostel' using errcode = '42501';
  end if;
  if coalesce((select value from app_settings where key = 'billing_mode'), 'calendar') <> 'calendar' then
    raise exception 'Date range payment sirf calendar billing mode mein chalta hai';
  end if;
  if s.joining_date is null then raise exception 'Student has no Joining Date — set it first'; end if;
  if coalesce(s.monthly_fee, 0) <= 0 then raise exception 'Student Monthly Fee is 0 — set it first'; end if;
  if coalesce(p_discount, 0) < 0 or p_amount is null or p_amount < 0 then
    raise exception 'Amount/discount cannot be negative';
  end if;
  if coalesce(p_discount, 0) > 0 and auth.uid() is not null and not is_director() then
    raise exception 'Only the Director can give a discount' using errcode = '42501';
  end if;
  if v_pdate > v_today then raise exception 'Payment date cannot be in the future'; end if;

  -- old unpaid days first (Director may untick "Pehle overdue clear")
  v_first := public.compute_paid_till(s.id) + 1;
  if v_first is not null and p_from > v_first then
    if not coalesce(p_skip_overdue, false) then
      raise exception 'Pehle overdue clear karein — From date % honi chahiye (paid till %)',
        to_char(v_first, 'DD-MM-YYYY'), to_char(v_first - 1, 'DD-MM-YYYY');
    end if;
    if auth.uid() is not null and not is_director() then
      raise exception 'Sirf Director overdue chhod kar aage ki dates le sakta hai' using errcode = '42501';
    end if;
  end if;

  v_plan := public.ddd_fee_range_plan(s.id, p_from, p_to);
  n := jsonb_array_length(v_plan);
  for i in 0 .. n - 1 loop
    pc := v_plan -> i;
    v_gross := v_gross + (pc ->> 'owed')::numeric;
    v_whole := v_whole and (pc ->> 'whole')::boolean;
  end loop;
  if v_gross <= 0 then raise exception 'In dates ka koi amount baaki nahi hai'; end if;

  -- pre-approved plan discount: only for exactly plan_months whole months
  if v_whole and n = s.plan_months and s.plan_amount is not null
     and s.plan_amount < round(s.monthly_fee * s.plan_months, 2) then
    v_plan_disc := round(s.monthly_fee * s.plan_months, 2) - s.plan_amount;
  end if;
  v_disc := least(v_gross, v_plan_disc + coalesce(p_discount, 0));

  if round(p_amount, 2) <> round(v_gross - v_disc, 2) then
    raise exception 'Amount mismatch: expected % (gross % - discount %), got %',
      round(v_gross - v_disc, 2), v_gross, v_disc, p_amount;
  end if;

  v_receipt := 'R-' || to_char(v_pdate, 'YYMMDD') || '-' || upper(substr(replace(v_group::text, '-', ''), 1, 6));

  v_disc_left := v_disc;
  for i in 0 .. n - 1 loop
    pc := v_plan -> i;
    v_owed := (pc ->> 'owed')::numeric;
    if i = n - 1 then
      v_disc_i := v_disc_left;
    else
      v_disc_i := least(round(v_disc * v_owed / nullif(v_gross, 0), 2), v_disc_left, v_owed);
    end if;
    v_disc_left := v_disc_left - v_disc_i;

    update monthly_dues
       set discount    = coalesce(discount, 0) + v_disc_i,
           paid_amount = coalesce(paid_amount, 0) + (v_owed - v_disc_i),
           status      = case when coalesce(pending, 0) - v_owed <= 0 then 'paid' else 'partial' end
     where id = (pc ->> 'due_id')::uuid;

    insert into fee_payments(id, due_id, student_id, hostel_id, amount, discount_amount, payment_date,
                             mode, transaction_id, receipt_number, remarks, period_from, period_to,
                             advance_group_id, collected_by, created_by)
    values (gen_random_uuid(), (pc ->> 'due_id')::uuid, s.id, s.hostel_id, v_owed - v_disc_i, v_disc_i, v_pdate,
            v_mode, p_transaction_id, v_receipt, p_remarks, (pc ->> 'from')::date, (pc ->> 'to')::date,
            v_group, auth.uid(), auth.uid());
    v_last_due := (pc ->> 'due_id')::uuid;
  end loop;

  v_balance := (select coalesce(pending, 0) from monthly_dues where id = v_last_due);
  v_paid_till := public.recompute_paid_till(s.id);

  return jsonb_build_object(
    'group_id', v_group, 'duplicate', false, 'receipt_number', v_receipt,
    'period_from', p_from, 'period_to', p_to, 'months', n,
    'gross', v_gross, 'discount', v_disc, 'net', v_gross - v_disc,
    'breakdown', v_plan, 'partial', v_balance > 0, 'balance', v_balance,
    'balance_month', date_trunc('month', p_to)::date, 'paid_till', v_paid_till);
end $$;

-- ---------------------------------------------------------------------
-- E. record_fee_payment (N months) — 017 logic, exact dates saved
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
  v_id         uuid;
  v_months     date[]    := '{}';
  v_tos        date[]    := '{}';
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

  s := (select x from students x where x.id = p_student_id for update);   -- serialises payments per student
  if s.id is null then raise exception 'Student not found'; end if;

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
  v_start := (select min(date_trunc('month', month))::date
                from monthly_dues where student_id = s.id and coalesce(pending, 0) > 0);
  if v_start is null then
    v_start := (select (max(date_trunc('month', month)) + interval '1 month')::date
                  from monthly_dues where student_id = s.id);
  end if;
  v_start := coalesce(v_start, date_trunc('month', s.joining_date)::date);

  -- collect the next p_months not-fully-paid calendar months
  m := v_start;
  while coalesce(array_length(v_months, 1), 0) < p_months loop
    v_guard := v_guard + 1;
    if v_guard > 240 then raise exception 'Could not find % unpaid months', p_months; end if;
    d := (select x from monthly_dues x
           where x.student_id = s.id and date_trunc('month', x.month) = m
           order by x.month limit 1);
    if d.id is null then
      v_id := gen_random_uuid();
      insert into monthly_dues(id, student_id, hostel_id, month, fee_amount, period_from, period_to, created_by)
      values (v_id, s.id, s.hostel_id, m, public.ddd_month_fee(s.monthly_fee, s.joining_date, m),
              greatest(m, s.joining_date), (m + interval '1 month - 1 day')::date, auth.uid());
      d := (select x from monthly_dues x where x.id = v_id);
    end if;
    if coalesce(d.pending, 0) > 0 then
      -- exact first unpaid day of this month (after a partial payment)
      v_months  := v_months  || greatest(coalesce(d.period_from, m), coalesce(d.paid_to, coalesce(d.period_from, m) - 1) + 1);
      v_tos     := v_tos     || coalesce(d.period_to, (m + interval '1 month - 1 day')::date);
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
           period_from = coalesce(period_from, greatest(date_trunc('month', v_months[i])::date, s.joining_date)),
           period_to   = coalesce(period_to, v_tos[i])
     where id = v_due_ids[i];

    insert into fee_payments(id, due_id, student_id, hostel_id, amount, discount_amount, payment_date,
                             mode, transaction_id, receipt_number, remarks, period_from, period_to,
                             advance_group_id, collected_by, created_by)
    values (gen_random_uuid(), v_due_ids[i], s.id, s.hostel_id, v_owed[i] - v_disc_i, v_disc_i, v_pdate,
            v_mode, p_transaction_id, v_receipt, p_remarks, v_months[i], v_tos[i],
            v_group, auth.uid(), auth.uid());
  end loop;

  v_paid_till := public.recompute_paid_till(s.id);

  return jsonb_build_object(
    'group_id', v_group, 'duplicate', false, 'receipt_number', v_receipt,
    'period_from', v_months[1],
    'period_to', v_tos[array_length(v_tos, 1)],
    'months', array_length(v_months, 1),
    'gross', v_gross, 'discount', v_disc, 'net', v_gross - v_disc,
    'paid_till', v_paid_till);
end $$;

-- ---------------------------------------------------------------------
-- F. record_partial_payment (amount) — 017 logic, exact dates saved
-- ---------------------------------------------------------------------
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
  v_id       uuid;
  v_pay_id   uuid;
  v_a        date;
  v_b        date;
  v_new_to   date;
  v_n        int := 0;
  v_guard    int := 0;
  v_first    date;
  v_last     date;
  v_last_to  date;
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

  s := (select x from students x where x.id = p_student_id for update);
  if s.id is null then raise exception 'Student not found'; end if;
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
  v_start := (select min(date_trunc('month', month))::date
                from monthly_dues where student_id = s.id and coalesce(pending, 0) > 0);
  if v_start is null then
    v_start := (select (max(date_trunc('month', month)) + interval '1 month')::date
                  from monthly_dues where student_id = s.id);
  end if;
  v_start := coalesce(v_start, date_trunc('month', s.joining_date)::date);

  v_receipt := 'R-' || to_char(v_pdate, 'YYMMDD') || '-' || upper(substr(replace(v_group::text, '-', ''), 1, 6));
  v_left := round(p_amount, 2);
  m := v_start;

  while v_left > 0 loop
    v_guard := v_guard + 1;
    if v_guard > 240 then raise exception 'Could not allocate amount'; end if;
    d := (select x from monthly_dues x
           where x.student_id = s.id and date_trunc('month', x.month) = m
           order by x.month limit 1);
    if d.id is null then
      v_id := gen_random_uuid();
      insert into monthly_dues(id, student_id, hostel_id, month, fee_amount, period_from, period_to, created_by)
      values (v_id, s.id, s.hostel_id, m, public.ddd_month_fee(s.monthly_fee, s.joining_date, m),
              greatest(m, s.joining_date), (m + interval '1 month - 1 day')::date, auth.uid());
      d := (select x from monthly_dues x where x.id = v_id);
    end if;
    if coalesce(d.pending, 0) > 0 then
      v_alloc := least(v_left, d.pending);
      v_a := greatest(coalesce(d.period_from, m), coalesce(d.paid_to, coalesce(d.period_from, m) - 1) + 1);
      update monthly_dues
         set paid_amount = coalesce(paid_amount, 0) + v_alloc,
             status      = case when coalesce(pending, 0) - v_alloc <= 0 then 'paid' else 'partial' end,
             period_from = coalesce(period_from, greatest(m, s.joining_date)),
             period_to   = coalesce(period_to, (m + interval '1 month - 1 day')::date)
       where id = d.id;
      -- last day this money covers (at least the first day)
      v_new_to := (select paid_to from monthly_dues where id = d.id);
      v_b := greatest(v_new_to, v_a);
      v_pay_id := gen_random_uuid();
      insert into fee_payments(id, due_id, student_id, hostel_id, amount, discount_amount, payment_date,
                               mode, transaction_id, receipt_number, remarks, period_from, period_to,
                               advance_group_id, collected_by, created_by)
      values (v_pay_id, d.id, s.id, s.hostel_id, v_alloc, 0, v_pdate,
              v_mode, p_transaction_id, v_receipt, coalesce(p_remarks, 'Partial payment'), v_a, v_b,
              v_group, auth.uid(), auth.uid());
      v_n := v_n + 1;
      v_first := coalesce(v_first, v_a);
      v_last := m;
      v_last_to := v_b;
      v_balance := d.pending - v_alloc;
      v_left := v_left - v_alloc;
    end if;
    m := (m + interval '1 month')::date;
  end loop;

  v_paid_till := public.recompute_paid_till(s.id);
  return jsonb_build_object(
    'group_id', v_group, 'duplicate', false, 'partial', true, 'receipt_number', v_receipt,
    'period_from', v_first, 'period_to', v_last_to,
    'months', v_n, 'gross', round(p_amount, 2), 'discount', 0, 'net', round(p_amount, 2),
    'balance_month', v_last, 'balance', v_balance, 'paid_till', v_paid_till);
end $$;

-- ---------------------------------------------------------------------
-- G. Director: change the dates of an existing payment (same money)
-- ---------------------------------------------------------------------
create table if not exists public.fee_payment_edits (
  id             uuid primary key default gen_random_uuid(),
  group_id       uuid,
  student_id     uuid,
  receipt_number text,
  old_from       date,
  old_to         date,
  new_from       date,
  new_to         date,
  reason         text not null,
  old_rows       jsonb,
  edited_by      uuid,
  edited_at      timestamptz not null default now()
);
alter table public.fee_payment_edits enable row level security;
drop policy if exists fee_payment_edits_read on public.fee_payment_edits;
create policy fee_payment_edits_read on public.fee_payment_edits for select to authenticated using (public.is_director());
revoke all on public.fee_payment_edits from public, anon, authenticated;
grant select on public.fee_payment_edits to authenticated;
create index if not exists idx_fee_payment_edits_student on public.fee_payment_edits(student_id);

create or replace function public.edit_fee_payment_dates(p_payment_id uuid, p_from date, p_to date, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f          public.fee_payments%rowtype;
  s          public.students%rowtype;
  v_ids      uuid[];
  v_old_dues uuid[];
  v_old      jsonb;
  v_old_from date;
  v_old_to   date;
  v_net      numeric;
  v_dsc      numeric;
  v_group    uuid;
  v_cur      date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  v_plan     jsonb;
  pc         jsonb;
  n          int;
  n_old      int;
  i          int;
  v_gross    numeric := 0;
  v_owed     numeric;
  v_disc_i   numeric;
  v_disc_left numeric;
  r          record;
  v_paid_till date;
begin
  if not (auth.uid() is null or is_director()) then
    raise exception 'Sirf Director payment ki dates badal sakta hai' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Reason likhna zaroori hai';
  end if;
  f := (select x from fee_payments x where x.id = p_payment_id);
  if f.id is null then raise exception 'Payment not found'; end if;
  s := (select x from students x where x.id = f.student_id for update);
  if s.id is null then raise exception 'Student not found'; end if;

  if f.advance_group_id is not null then
    v_ids := (select array_agg(id order by period_from, id) from fee_payments where advance_group_id = f.advance_group_id);
  else
    v_ids := array[f.id];
  end if;
  n_old := array_length(v_ids, 1);
  v_old := (select jsonb_agg(to_jsonb(x) order by x.period_from) from fee_payments x where x.id = any(v_ids));
  v_old_from := (select min(period_from) from fee_payments where id = any(v_ids));
  v_old_to   := (select max(period_to) from fee_payments where id = any(v_ids));
  v_net := (select coalesce(sum(amount), 0) from fee_payments where id = any(v_ids));
  v_dsc := (select coalesce(sum(discount_amount), 0) from fee_payments where id = any(v_ids));
  v_old_dues := (select coalesce(array_agg(distinct due_id), '{}') from fee_payments where id = any(v_ids) and due_id is not null);
  if v_old_from = p_from and v_old_to = p_to then
    raise exception 'Dates same hain — kuch nahi badla';
  end if;
  v_group := coalesce(f.advance_group_id, f.id);

  -- give back to each old due exactly what these payments added
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
  update monthly_dues
     set status = case when coalesce(paid_amount, 0) <= 0 then 'pending'
                       when coalesce(pending, 0) > 0     then 'partial'
                       else 'paid' end
   where id = any(v_old_dues);
  update fee_payments set due_id = null where id = any(v_ids);

  v_plan := public.ddd_fee_range_plan(s.id, p_from, p_to);
  n := jsonb_array_length(v_plan);
  for i in 0 .. n - 1 loop
    v_gross := v_gross + ((v_plan -> i) ->> 'owed')::numeric;
  end loop;
  if round(v_gross, 2) <> round(v_net + v_dsc, 2) then
    raise exception 'Nayi dates ka hisaab ₹% hai, is payment ka ₹% — amount same hona chahiye (warna payment delete karke dobara jama karein)',
      round(v_gross, 0)::bigint, round(v_net + v_dsc, 0)::bigint;
  end if;

  v_disc_left := v_dsc;
  for i in 0 .. n - 1 loop
    pc := v_plan -> i;
    v_owed := (pc ->> 'owed')::numeric;
    if i = n - 1 then
      v_disc_i := v_disc_left;
    else
      v_disc_i := least(round(v_dsc * v_owed / nullif(v_gross, 0), 2), v_disc_left, v_owed);
    end if;
    v_disc_left := v_disc_left - v_disc_i;

    update monthly_dues
       set discount    = coalesce(discount, 0) + v_disc_i,
           paid_amount = coalesce(paid_amount, 0) + (v_owed - v_disc_i),
           status      = case when coalesce(pending, 0) - v_owed <= 0 then 'paid' else 'partial' end
     where id = (pc ->> 'due_id')::uuid;

    if i < n_old then
      update fee_payments
         set due_id = (pc ->> 'due_id')::uuid, amount = v_owed - v_disc_i, discount_amount = v_disc_i,
             period_from = (pc ->> 'from')::date, period_to = (pc ->> 'to')::date, advance_group_id = v_group
       where id = v_ids[i + 1];
    else
      insert into fee_payments(id, due_id, student_id, hostel_id, amount, discount_amount, payment_date,
                               mode, transaction_id, receipt_number, remarks, period_from, period_to,
                               advance_group_id, collected_by, created_by, created_at, status)
      values (gen_random_uuid(), (pc ->> 'due_id')::uuid, f.student_id, f.hostel_id, v_owed - v_disc_i, v_disc_i, f.payment_date,
              f.mode, f.transaction_id, f.receipt_number, f.remarks, (pc ->> 'from')::date, (pc ->> 'to')::date,
              v_group, f.collected_by, f.created_by, f.created_at, f.status);
    end if;
  end loop;
  if n_old > n then
    delete from fee_payments where id = any(v_ids[n + 1 : n_old]);
  end if;

  -- old future months that now have nothing paid -> remove (same as delete)
  for r in select id, month, paid_amount from monthly_dues where id = any(v_old_dues) loop
    if date_trunc('month', r.month)::date > v_cur
       and coalesce(r.paid_amount, 0) = 0
       and not exists (select 1 from fee_payments where due_id = r.id) then
      delete from monthly_dues where id = r.id;
    end if;
  end loop;

  insert into fee_payment_edits(group_id, student_id, receipt_number, old_from, old_to, new_from, new_to, reason, old_rows, edited_by)
  values (v_group, s.id, f.receipt_number, v_old_from, v_old_to, p_from, p_to, trim(p_reason), v_old, auth.uid());

  v_paid_till := public.recompute_paid_till(s.id);
  return jsonb_build_object('group_id', v_group, 'receipt_number', f.receipt_number, 'period_from', p_from, 'period_to', p_to,
                            'months', n, 'breakdown', v_plan, 'paid_till', v_paid_till);
end $$;

-- ---------------------------------------------------------------------
-- H. grants
-- ---------------------------------------------------------------------
revoke all on function public.ddd_cum_fee(numeric, int, int) from public, anon, authenticated;
revoke all on function public.ddd_due_full_fee(date, date, numeric, numeric) from public, anon, authenticated;
revoke all on function public.ddd_due_paid_to(date, date, date, numeric, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.ddd_dues_set_paid_to() from public, anon, authenticated;
revoke all on function public.ddd_fee_range_plan(uuid, date, date) from public, anon, authenticated;
revoke all on function public.compute_paid_till(uuid, date, numeric) from public, anon, authenticated;
revoke all on function public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean) from public, anon;
grant execute on function public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean) to authenticated;
revoke all on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) to authenticated;
revoke all on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) to authenticated;
revoke all on function public.edit_fee_payment_dates(uuid, date, date, text) from public, anon;
grant execute on function public.edit_fee_payment_dates(uuid, date, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- I. fill paid_to for existing dues (no audit spam), then paid_till
-- ---------------------------------------------------------------------
alter table public.monthly_dues disable trigger trg_monthly_dues_audit;
alter table public.monthly_dues disable trigger trg_monthly_dues_paid_till;
alter table public.monthly_dues disable trigger trg_monthly_dues_upd;
update public.monthly_dues d
   set paid_to = public.ddd_due_paid_to(d.month, d.period_from, d.period_to, d.fee_amount, d.discount, d.paid_amount, s.monthly_fee)
  from public.students s
 where s.id = d.student_id
   and d.paid_to is distinct from public.ddd_due_paid_to(d.month, d.period_from, d.period_to, d.fee_amount, d.discount, d.paid_amount, s.monthly_fee);
update public.monthly_dues d
   set paid_to = public.ddd_due_paid_to(d.month, d.period_from, d.period_to, d.fee_amount, d.discount, d.paid_amount, null)
 where d.student_id is null and d.paid_to is null;
alter table public.monthly_dues enable trigger trg_monthly_dues_audit;
alter table public.monthly_dues enable trigger trg_monthly_dues_paid_till;
alter table public.monthly_dues enable trigger trg_monthly_dues_upd;

update public.students s set paid_till = public.compute_paid_till(s.id)
 where s.paid_till is distinct from public.compute_paid_till(s.id);

notify pgrst, 'reload schema';

commit;
