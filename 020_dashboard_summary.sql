-- =====================================================================
-- 020_dashboard_summary.sql      (needs 014 + 017 + 018)
-- DDD Hostel — Dashboard period filter: all card numbers from ONE RPC
--   dashboard_summary(p_from date, p_to date, p_hostel uuid default null)
--
--  * Same scope as RLS, applied ONCE (fast): the function checks the
--    caller with the same helpers the read policies use —
--    is_director() / is_accountant() -> all hostels, everyone else ->
--    only my_hostels(). p_hostel outside that scope returns zeros.
--    (SECURITY DEFINER only to skip the per-row policy cost; it returns
--    totals only, never rows of other hostels. run_checks STEP 4 proves
--    the numbers equal the RLS sums for every user.)
--  * Director-only numbers (Expense, Salary Paid, Net Profit, Salary
--    Payable, month-wise Income vs Expense, mode split, hostel table)
--    come back as NULL for everyone else.
--  * Period cards  : payments / dues / expenses / salary / admissions /
--                    left / complaints INSIDE p_from..p_to (IST dates).
--  * Snapshot cards: "as of" = least(p_to, today IST) — students, beds,
--                    pending, overdue / due / due-in-7, salary payable.
--  * Previous period for ▲/▼: whole calendar months -> same number of
--    months before; otherwise the same number of days before.
--  * Adds 3 plain indexes (payment_date, expense_date, dues month).
--  * No table / data / policy changes. One transaction, idempotent.
-- =====================================================================
begin;

-- ---------- pre-checks (abort with a clear message) ----------
do $$
declare miss text := '';
begin
  if to_regclass('public.salary_runs') is null then raise exception '020 aborted: run 018 first (salary_runs missing)'; end if;
  if to_regprocedure('public.ddd_month_fee(numeric,date,date)') is null then raise exception '020 aborted: run 017 first'; end if;
  if to_regprocedure('public.is_director()') is null then raise exception '020 aborted: is_director() missing'; end if;
  miss := (select string_agg(t || '.' || c, ', ')
  from (values ('fee_payments','payment_date'), ('fee_payments','amount'), ('fee_payments','mode'), ('fee_payments','due_id'),
               ('fee_payments','collected_by'), ('fee_payments','receipt_number'),
               ('monthly_dues','month'), ('monthly_dues','payable'), ('monthly_dues','pending'), ('monthly_dues','period_from'), ('monthly_dues','period_to'),
               ('expenses','expense_date'), ('expenses','status'), ('expenses','amount'),
               ('students','joining_date'), ('students','exit_date'), ('students','paid_till'), ('students','monthly_fee'),
               ('complaints','created_at'), ('complaints','status'), ('complaints','resolution_date'),
               ('beds','bed_status'), ('salary_runs','paid_date'), ('salary_runs','net'), ('app_settings','value')) x(t, c)
  where not exists (select 1 from information_schema.columns ic
                    where ic.table_schema = 'public' and ic.table_name = x.t and ic.column_name = x.c));
  if miss is not null then raise exception '020 aborted: columns missing: %', miss; end if;
end $$;

-- ---------- indexes for period sums ----------
create index if not exists ddd_020_fee_payments_date on public.fee_payments (payment_date);
create index if not exists ddd_020_expenses_date     on public.expenses (expense_date);
create index if not exists ddd_020_monthly_dues_month on public.monthly_dues (month);

-- ---------- previous period (mirror of the app's prevPeriod) ----------
create or replace function public.ddd_prev_period(p_from date, p_to date, out prev_from date, out prev_to date)
language sql immutable as $$
  select case when p_from = date_trunc('month', p_from)::date
               and p_to = (date_trunc('month', p_to) + interval '1 month - 1 day')::date
              then (p_from - ((extract(year from age(p_to + 1, p_from)) * 12 + extract(month from age(p_to + 1, p_from)))::int
                              * interval '1 month'))::date
              else p_from - (p_to - p_from + 1) end,
         p_from - 1
$$;

-- ---------- period numbers (internal: only dashboard_summary calls it) ----------
drop function if exists public.ddd_period_numbers(date, date, uuid, boolean);
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
  bill as (   -- billable: today = exactly the app rule (not left, joining date, fee); past = active on that date
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

    -- month-wise chart: the period's months if it spans 2+ months (max 24), else the FY of p_to
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

revoke all on function public.ddd_prev_period(date, date) from public, anon;
revoke all on function public.ddd_period_numbers(date, date, boolean, uuid[], boolean) from public, anon, authenticated;   -- internal only
revoke all on function public.dashboard_summary(date, date, uuid) from public, anon;
grant execute on function public.ddd_prev_period(date, date) to authenticated;
grant execute on function public.dashboard_summary(date, date, uuid) to authenticated;

commit;

notify pgrst, 'reload schema';

-- verify (all true):
-- select 'rpc exists' chk, to_regprocedure('public.dashboard_summary(date,date,uuid)') is not null ok
-- union all select 'helper not callable by app', not has_function_privilege('authenticated', 'public.ddd_period_numbers(date,date,boolean,uuid[],boolean)', 'execute')
-- union all select 'indexes', (select count(*) from pg_indexes where indexname like 'ddd_020_%') = 3;
