-- =====================================================================
-- 026_undo.sql — 026 wapas (billing exit rules).
--
--  * generate_monthly_dues = 022 text bilkul wapas (exact copy).
--  * compute_paid_till(uuid,date,numeric) + ddd_dues_set_paid_to +
--    ddd_due_paid_to + ddd_fee_range_plan = 024 text wapas.
--  * delete_fee_payment = 014 text, dashboard_summary + ddd_period_numbers
--    = 020 text wapas.
--  * 026 ke triggers aur functions hat jaate hain.
--  * ddd_dues_void_log table sirf KHALI ho to hatti hai (history kabhi nahi mitti).
--  * students.merged_into column sirf tab hatta hai jab kisi student mein bhara na ho.
--  * students.rejoined_on column (wapsi ki tareekh) bhi sirf tab hatta hai jab khali ho.
--
-- ZAROORI: pehle cleanup (void / merge) ka undo karein, phir ye file.
-- Agar abhi bhi koi bill 026 ki wajah se void / kam kiya hua hai ya koi
-- student merged hai, ya kisi student ki wapsi ki tareekh (rejoined_on) bhari hai,
-- to ye file RUK jaati hai aur kuch nahi badalta.
-- Ek transaction, 2 baar chalana safe.
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------- safety check ----------
do $$
declare
  -- SIRF developer ke kehne par true karein: void / kam kiye bill waise hi rahenge
  force_undo boolean := false;
  n_open   int := 0;
  n_merged int := 0;
  n_rejoin int := 0;
begin
  if to_regclass('public.ddd_dues_void_log') is not null then
    n_open := (select count(*) from (
                 select distinct on (l.due_id) l.due_id, l.action
                   from public.ddd_dues_void_log l
                  where l.action in ('void', 'prorate', 'restore', 'rejoin') and l.due_id is not null
                  order by l.due_id, l.id desc) x
               join public.monthly_dues d on d.id = x.due_id
               where x.action in ('void', 'prorate', 'rejoin'));
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'students' and column_name = 'merged_into') then
    n_merged := (select count(*) from public.students where merged_into is not null);
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'students' and column_name = 'rejoined_on') then
    n_rejoin := (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.students where rejoined_on is not null', false, true, '')))[1]::text::int;
  end if;
  if (n_open > 0 or n_merged > 0 or n_rejoin > 0) and not force_undo then
    raise exception '026 undo ruka: % bill abhi 026 se void / kam kiye hue hain, % student merged hain, % student wapas aaye (rejoined_on). Pehle cleanup ka undo chalayein (ya developer se baat karein). Kuch nahi badla.', n_open, n_merged, n_rejoin;
  end if;
  if n_open > 0 or n_merged > 0 or n_rejoin > 0 then
    raise notice '026 undo FORCE: % bill void / kam hi rahenge, % merged student waise hi rahenge, % wapsi ki tareekh rahegi', n_open, n_merged, n_rejoin;
  end if;
end $$;

-- ---------- 026 triggers ----------
drop trigger if exists trg_students_exit_bills on public.students;
drop trigger if exists trg_students_exit_default on public.students;
drop trigger if exists trg_monthly_dues_exit_month on public.monthly_dues;
drop trigger if exists trg_monthly_dues_exit_guard on public.monthly_dues;
drop trigger if exists trg_monthly_dues_period_guard on public.monthly_dues;

-- ---------- generate_monthly_dues = 022 (exact) ----------
create or replace function public.generate_monthly_dues(p_month date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  cnt int := 0; r record;
  m_start date := date_trunc('month', p_month)::date;
  m_end   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_cur   date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  -- called through the API (app / anyone with the key)? SQL Editor = no.
  v_api   boolean := auth.uid() is not null or session_user = 'authenticator';
begin
  if p_month is null then raise exception 'Month required'; end if;
  if v_api then
    if auth.uid() is null then
      raise exception 'Login required' using errcode = '42501';
    end if;
    if not (public.is_director() or public.is_accountant() or exists (select 1 from public.my_hostels())) then
      raise exception 'Sirf Director / Manager dues generate kar sakte hain' using errcode = '42501';
    end if;
    if not (m_start = v_cur or (m_start = (v_cur - interval '1 month')::date and extract(day from v_today) <= 5)) then
      raise exception 'Sirf is mahine (%) ki dues generate ho sakti hain', to_char(v_cur, 'Mon YYYY') using errcode = '42501';
    end if;
  end if;
  for r in
    select id, hostel_id, monthly_fee, joining_date from public.students
    where status = 'active'
      and joining_date is not null
      and date_trunc('month', joining_date)::date <= m_start
      and coalesce(monthly_fee, 0) > 0
  loop
    insert into public.monthly_dues(student_id, hostel_id, month, fee_amount, period_from, period_to)
    values (r.id, r.hostel_id, m_start, public.ddd_month_fee(r.monthly_fee, r.joining_date, m_start),
            greatest(m_start, r.joining_date), m_end)
    on conflict (student_id, month) do nothing;
    cnt := cnt + 1;
  end loop;
  return cnt;
end; $function$;
revoke all on function public.generate_monthly_dues(date) from public, anon;
grant execute on function public.generate_monthly_dues(date) to authenticated;

-- ---------- ddd_dues_set_paid_to + compute_paid_till = 024 (exact) ----------
create or replace function public.ddd_dues_set_paid_to() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.paid_to := public.ddd_due_paid_to(new.month, new.period_from, new.period_to, new.fee_amount,
                                        new.discount, new.paid_amount,
                                        (select monthly_fee from public.students where id = new.student_id));
  return new;
end $$;

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

revoke all on function public.ddd_dues_set_paid_to() from public, anon, authenticated;
revoke all on function public.compute_paid_till(uuid, date, numeric) from public, anon, authenticated;

-- ---------- ddd_due_paid_to + ddd_fee_range_plan = 024 (exact) ----------
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
  v_out jsonb := '[]';
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
    v_out := v_out || jsonb_build_object('due_id', d.id, 'month', m, 'from', a, 'to', b, 'owed', owed,
                                     'whole', (a = coalesce(d.period_from, m) and b = coalesce(d.period_to, me)));
    m := (m + interval '1 month')::date;
  end loop;
  return v_out;
end $$;

-- ---------- delete_fee_payment = 014 (exact) ----------
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

  -- future month with nothing else paid -> remove, otherwise pending/partial
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

-- ---------- dashboard = 020 (exact) ----------
-- ---------- period numbers (internal: only dashboard_summary calls it) ----------
create or replace function public.ddd_period_numbers(p_from date, p_to date, p_all boolean, p_hs uuid[], p_dir boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_gross numeric; v_refund numeric; v_cnt int; v_billed numeric; v_exp numeric; v_sal numeric;
  v_adm int; v_left int; v_copen int; v_cclose int;
begin
  -- (plain := assignments: Supabase SQL Editor misreads "select ... into" as a new table)
  v_gross := (select coalesce(sum(amount), 0) from fee_payments
              where amount > 0 and payment_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  v_refund := (select coalesce(-sum(amount), 0) from fee_payments
               where amount < 0 and payment_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  v_cnt := (select count(*) from fee_payments
            where payment_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));

  v_billed := (select coalesce(sum(payable), 0) from monthly_dues
               where month between p_from and p_to and (p_all or hostel_id = any(p_hs)));

  v_adm := (select count(*) from students
            where joining_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  v_left := (select count(*) from students
             where exit_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));

  v_copen := (select count(*) from complaints
              where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  v_cclose := (select count(*) from complaints
               where status = 'resolved'
                 and coalesce(resolution_date, (updated_at at time zone 'Asia/Kolkata')::date) between p_from and p_to
                 and (p_all or hostel_id = any(p_hs)));

  if p_dir then
    v_exp := (select coalesce(sum(amount), 0) from expenses
              where status = 'approved' and expense_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
    v_sal := (select coalesce(sum(net), 0) from salary_runs
              where status = 'paid' and paid_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  end if;

  return jsonb_build_object(
    'collected', v_gross - v_refund, 'refunds', v_refund, 'payments', v_cnt,
    'billed', v_billed,
    'collection_pct', case when v_billed > 0 then round((v_gross - v_refund) * 100 / v_billed, 1) end,
    'expense', v_exp, 'salary_paid', v_sal,
    'net_profit', case when p_dir then v_gross - v_refund - v_exp - v_sal end,
    'admissions', v_adm, 'left', v_left,
    'complaints_opened', v_copen, 'complaints_closed', v_cclose);
end $$;

-- ---------- the RPC ----------
create or replace function public.dashboard_summary(p_from date, p_to date, p_hostel uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_uid   uuid := auth.uid();
  v_dir   boolean := coalesce(public.is_director(), false);
  v_wide  boolean := v_dir or coalesce(public.is_accountant(), false);   -- = read policies
  v_all   boolean;       -- no hostel filter at all (incl. rows without hostel)
  v_hs    uuid[];        -- hostels this call may sum
  v_asof  date;
  v_grace int;
  v_pfrom date; v_pto date;
  v_snap  jsonb;
  v_modes jsonb; v_hostels jsonb; v_monthly jsonb; v_day jsonb;
  v_m_from date; v_m_to date;
begin
  if p_from is null or p_to is null then raise exception 'dashboard_summary: from/to required'; end if;
  if p_from > p_to then raise exception 'dashboard_summary: from date is after to date'; end if;
  if p_to - p_from > 366 * 30 then raise exception 'dashboard_summary: period too long'; end if;
  if v_uid is null then raise exception 'dashboard_summary: not signed in'; end if;
  v_all := v_wide and p_hostel is null;
  if v_wide then
    v_hs := case when p_hostel is null then array(select id from hostels) else array[p_hostel] end;
  else
    v_hs := array(select h from public.my_hostels() h where p_hostel is null or h = p_hostel);
  end if;
  v_hs := coalesce(v_hs, '{}');
  v_asof := least(p_to, v_today);
  v_grace := (select coalesce(nullif(value, '')::int, 0) from app_settings where key = 'fee_grace_days');
  v_grace := greatest(coalesce(v_grace, 0), 0);
  v_pfrom := (select prev_from from public.ddd_prev_period(p_from, p_to));
  v_pto := p_from - 1;

  -- snapshot as of v_asof
  v_snap := (with st as (
    select s.* from students s
    where (v_all or s.hostel_id = any(v_hs))
      and (s.joining_date is null or s.joining_date <= v_asof)
      and (s.exit_date is null or s.exit_date > v_asof)
      and (coalesce(s.status, 'active') <> 'left' or s.exit_date > v_asof)
  ),
  bill as (   -- billable: today = exactly the app rule (not left, joining date, fee), past = active on that date
    select s.* from students s
    where (v_all or s.hostel_id = any(v_hs))
      and s.joining_date is not null and coalesce(s.monthly_fee, 0) > 0
      and case when v_asof >= v_today then coalesce(s.status, 'active') <> 'left'
               else s.joining_date <= v_asof and (s.exit_date is null or s.exit_date > v_asof)
                    and (coalesce(s.status, 'active') <> 'left' or s.exit_date > v_asof) end
  ),
  later as (   -- payments made after the as-of date are added back
    select due_id, sum(amount) amt from fee_payments
    where payment_date > v_asof and due_id is not null and (v_all or hostel_id = any(v_hs))
    group by due_id
  ),
  dd as (
    select d.student_id, coalesce(d.period_from, d.month) as start,
           coalesce(d.period_to, (d.month + interval '1 month - 1 day')::date) as stop,
           least(d.payable, d.pending + coalesce(l.amt, 0)) as pend
    from monthly_dues d join bill b on b.id = d.student_id
    left join later l on l.due_id = d.id
  ),
  agg as (
    select student_id, min(start) filter (where pend > 0) as first_unpaid, max(stop) as last_stop,
           coalesce(sum(pend) filter (where pend > 0 and start <= v_asof), 0) as pend
    from dd group by student_id
  ),
  per as (   -- first unpaid day of each billable student (today: paid_till, same as the app)
    select b.id, b.hostel_id,
           case when v_asof >= v_today then b.paid_till + 1
                else coalesce(a.first_unpaid, a.last_stop + 1, b.joining_date) end as nextdue,
           coalesce(a.pend, 0) as pend,
           (v_asof < v_today or b.paid_till is not null) as has_state   -- app: no paid_till = "NOT BILLED"
    from bill b left join agg a on a.student_id = b.id
  ),
  bd as (select * from beds where (v_all or hostel_id = any(v_hs)))
  select jsonb_build_object(
    'asof', v_asof,
    'students', (select count(*) from st),
    'missing', (select count(*) from st where joining_date is null or coalesce(monthly_fee, 0) <= 0),
    'beds', (select count(*) from bd),
    'occupied', (select count(*) from bd where bed_status = 'occupied'),
    'vacant', (select count(*) from bd where bed_status = 'vacant'),
    'pending', (select coalesce(sum(pend), 0) from per),
    'pending_students', (select count(*) from per where pend > 0),
    'pending_by_hostel', (select coalesce(jsonb_object_agg(hostel_id, amt), '{}'::jsonb)
                          from (select hostel_id, sum(pend) amt from per where hostel_id is not null group by hostel_id) q),
    'overdue', (select count(*) from per where has_state and v_asof - nextdue > v_grace),
    'due', (select count(*) from per where has_state and v_asof - nextdue between 0 and v_grace),
    'soon', (select count(*) from per where has_state and nextdue - v_asof between 1 and 7),
    'complaints_open', (select count(*) from complaints c
                        where (v_all or c.hostel_id = any(v_hs))
                          and (c.created_at at time zone 'Asia/Kolkata')::date <= v_asof
                          and (c.status is distinct from 'resolved'
                               or coalesce(c.resolution_date, (c.updated_at at time zone 'Asia/Kolkata')::date) > v_asof)),
    'salary_month', (date_trunc('month', v_asof) - interval '1 month')::date,
    'salary_payable', case when v_dir then (
        select coalesce(sum(net), 0) from salary_runs r
        where r.month = (date_trunc('month', v_asof) - interval '1 month')::date
          and (r.status = 'pending' or r.paid_date > v_asof)
          and (v_all or r.hostel_id = any(v_hs))) end,
    'salary_pending_staff', case when v_dir then (
        select count(*) from salary_runs r
        where r.month = (date_trunc('month', v_asof) - interval '1 month')::date
          and (r.status = 'pending' or r.paid_date > v_asof)
          and (v_all or r.hostel_id = any(v_hs))) end
  ));

  -- day list (single-day periods): "aaj kitna aaya, kisne jama kiya"
  if p_from = p_to then
    v_day := (select coalesce(jsonb_agg(x order by x.created_at), '[]'::jsonb) from (
      select f.id, f.amount, f.mode, f.receipt_number, f.student_id, s.full_name as student, s.admission_number,
             f.hostel_id, coalesce(f.collected_by, f.created_by) as by_id, case when v_dir or u.id = v_uid then u.full_name end as by_name, f.created_at
      from fee_payments f
      left join students s on s.id = f.student_id
      left join users u on u.id = coalesce(f.collected_by, f.created_by)
      where f.payment_date = p_from and (v_all or f.hostel_id = any(v_hs))
      limit 2000) x);
  end if;

  if v_dir then
    v_modes := (select coalesce(jsonb_agg(jsonb_build_object('mode', m, 'amount', amt, 'count', n) order by amt desc), '[]'::jsonb)
    from (select coalesce(nullif(lower(trim(mode)), ''), 'other') m, sum(amount) amt, count(*) n
          from fee_payments where payment_date between p_from and p_to and (v_all or hostel_id = any(v_hs))
          group by 1) z);

    v_hostels := (select coalesce(jsonb_agg(jsonb_build_object(
             'id', h.id, 'name', h.name, 'code', h.code,
             'students', (select count(*) from students s where s.hostel_id = h.id
                            and (s.joining_date is null or s.joining_date <= v_asof)
                            and (s.exit_date is null or s.exit_date > v_asof)
                            and (coalesce(s.status, 'active') <> 'left' or s.exit_date > v_asof)),
             'beds', (select count(*) from beds b where b.hostel_id = h.id),
             'occupied', (select count(*) from beds b where b.hostel_id = h.id and b.bed_status = 'occupied'),
             'billed', (select coalesce(sum(payable), 0) from monthly_dues d where d.hostel_id = h.id and d.month between p_from and p_to),
             'collected', (select coalesce(sum(amount), 0) from fee_payments f where f.hostel_id = h.id and f.payment_date between p_from and p_to),
             'expense', (select coalesce(sum(amount), 0) from expenses e where e.hostel_id = h.id and e.status = 'approved' and e.expense_date between p_from and p_to),
             'pending', coalesce((v_snap -> 'pending_by_hostel' ->> h.id::text)::numeric, 0)
           ) order by h.name), '[]'::jsonb)
    from hostels h where (v_all or h.id = any(v_hs)));

    -- month-wise chart: the period months if it spans 2+ months (max 24), else the FY of p_to
    if date_trunc('month', p_from) < date_trunc('month', p_to) then
      v_m_to := date_trunc('month', p_to)::date;
      v_m_from := greatest(date_trunc('month', p_from)::date, (v_m_to - interval '23 months')::date);
    else
      v_m_from := make_date(extract(year from p_to)::int - case when extract(month from p_to) < 4 then 1 else 0 end, 4, 1);
      v_m_to := (v_m_from + interval '11 months')::date;
    end if;
    v_monthly := (select coalesce(jsonb_agg(jsonb_build_object(
             'month', gm::date,
             'income', (select coalesce(sum(amount), 0) from fee_payments f
                        where f.payment_date >= gm and f.payment_date < gm + interval '1 month' and (v_all or f.hostel_id = any(v_hs))),
             'expense', (select coalesce(sum(amount), 0) from expenses e
                         where e.status = 'approved' and e.expense_date >= gm and e.expense_date < gm + interval '1 month' and (v_all or e.hostel_id = any(v_hs))),
             'salary', (select coalesce(sum(net), 0) from salary_runs r
                        where r.status = 'paid' and r.paid_date >= gm and r.paid_date < gm + interval '1 month' and (v_all or r.hostel_id = any(v_hs)))
           ) order by gm), '[]'::jsonb)
    from generate_series(v_m_from, v_m_to, interval '1 month') gm);
  end if;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', v_today, 'hostel', p_hostel, 'is_director', v_dir, 'grace', v_grace,
    'prev_from', v_pfrom, 'prev_to', v_pto,
    'cur',  public.ddd_period_numbers(p_from, p_to, v_all, v_hs, v_dir),
    'prev', public.ddd_period_numbers(v_pfrom, v_pto, v_all, v_hs, v_dir),
    'snap', v_snap, 'day', v_day, 'modes', v_modes, 'hostels', v_hostels, 'monthly', v_monthly);
end $$;


-- ---------- 026 functions ----------
drop function if exists public.ddd_students_exit_bills();
drop function if exists public.ddd_students_exit_default();
drop function if exists public.ddd_dues_exit_after_insert();
drop function if exists public.ddd_guard_due_after_exit();
drop function if exists public.ddd_guard_due_period();
drop function if exists public.ddd_exit_bills_sync(uuid, text);
drop function if exists public.ddd_exit_review_once(public.monthly_dues, numeric, date, text, text);
drop function if exists public.ddd_stay_fee(numeric, date, date, date);

-- ---------- log table (only if empty) + merged_into (only if unused) ----------
do $$
begin
  if to_regclass('public.ddd_dues_void_log') is not null then
    if not exists (select 1 from public.ddd_dues_void_log) then
      drop table public.ddd_dues_void_log;
    else
      raise notice '026 undo: ddd_dues_void_log mein rows hain, table rakhi gayi (history)';
    end if;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'students' and column_name = 'merged_into') then
    if not exists (select 1 from public.students where merged_into is not null) then
      alter table public.students drop constraint if exists students_merged_into_not_self;
      alter table public.students drop constraint if exists students_merged_into_fkey;
      drop index if exists public.idx_students_merged_into;
      alter table public.students drop column merged_into;
    else
      raise notice '026 undo: kuch students mein merged_into bhara hai, column rakha gaya';
    end if;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'students' and column_name = 'rejoined_on') then
    if (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.students where rejoined_on is not null', false, true, '')))[1]::text::int = 0 then
      alter table public.students drop column rejoined_on;
    else
      raise notice '026 undo: kuch students mein rejoined_on bhara hai, column rakha gaya';
    end if;
  end if;
end $$;

-- ---------- only after a FORCE undo: void / kata bills get 024 paid_to, Paid Till recalculated ----------
update public.monthly_dues set paid_to = paid_to where status = 'void';
update public.monthly_dues d set paid_to = d.paid_to
 where coalesce(d.period_from, d.month) <= date_trunc('month', d.month)::date
   and d.period_to < (date_trunc('month', d.month) + interval '1 month - 1 day')::date
   and d.paid_to is distinct from public.ddd_due_paid_to(d.month, d.period_from, d.period_to, d.fee_amount, d.discount, d.paid_amount,
                                                         (select monthly_fee from public.students where id = d.student_id));
update public.students s set paid_till = public.compute_paid_till(s.id)
 where exists (select 1 from public.monthly_dues d where d.student_id = s.id
                  and (d.status = 'void' or (coalesce(d.period_from, d.month) <= date_trunc('month', d.month)::date
                                             and d.period_to < (date_trunc('month', d.month) + interval '1 month - 1 day')::date)))
   and s.paid_till is distinct from public.compute_paid_till(s.id);

-- ---------- check: old texts are back ----------
do $$
declare h text;
begin
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.generate_monthly_dues(date)'));
  if h is distinct from '6ea13bd087be181629f4f770132473a6' then raise exception '026 undo: generate_monthly_dues 022 jaisa nahi bana (%)', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.compute_paid_till(uuid,date,numeric)'));
  if h is distinct from '6e684ed7aad00f5128de11cb0c32f58b' then raise exception '026 undo: compute_paid_till 024 jaisa nahi bana (%)', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_dues_set_paid_to()'));
  if h is distinct from '4540a28a7b993d35e0d73b93944bfe31' then raise exception '026 undo: ddd_dues_set_paid_to 024 jaisa nahi bana (%)', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)'));
  if h is distinct from '00aad42d12d7d5491f7982a117dedb54' then raise exception '026 undo: ddd_due_paid_to 024 jaisa nahi bana (%)', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_fee_range_plan(uuid,date,date)'));
  if h is distinct from 'fef2cbbe57a653a64682250c53e7d35b' then raise exception '026 undo: ddd_fee_range_plan 024 jaisa nahi bana (%)', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.delete_fee_payment(uuid)'));
  if h is distinct from '9f4b70c5afe489837501a4c704beb944' then raise exception '026 undo: delete_fee_payment 014 jaisa nahi bana (%)', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_period_numbers(date,date,boolean,uuid[],boolean)'));
  if h is distinct from '73ccf7156242b084c78e8846e83dba97' then raise exception '026 undo: ddd_period_numbers 020 jaisa nahi bana (%)', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.dashboard_summary(date,date,uuid)'));
  if h is distinct from 'ca1a205f641a06e99b6aab41d2293fd3' then raise exception '026 undo: dashboard_summary 020 jaisa nahi bana (%)', h; end if;
end $$;

commit;

notify pgrst, 'reload schema';

-- check: 026_check_before.sql (row 026 pehle chal chuki = false)
