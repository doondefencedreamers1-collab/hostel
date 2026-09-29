-- =====================================================================
-- 019_staff_absent.sql     (needs 018)
-- Staff attendance = "Mark Absent" only. Every day is PRESENT by default;
-- a staff_attendance row with present = false means ABSENT that day.
--   * salary_runs.absent_days (new) + attendance_days = period days - absent
--   * generate_salary counts absent days; salary_pay freezes them on the slip
--   * pending rows of already generated months are recalculated now
--   * NO automatic salary cut for absence (Director can add Other deduction)
-- One transaction, idempotent.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.generate_salary(date)') is null then
    raise exception '019 aborted: run 018 first.';
  end if;
end $$;

alter table public.salary_runs add column if not exists absent_days int not null default 0;

create or replace function public.generate_salary(p_month date) returns integer
language plpgsql security definer set search_path = public as $$
declare
  m_start date := date_trunc('month', p_month)::date;
  m_end   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  dim     int  := extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::int;
  r record; v_from date; v_to date; v_days int; v_gross numeric; v_pfw numeric; v_pf jsonb;
  v_emp numeric; v_empr numeric; v_att int; v_abs int; v_adv numeric; n int := 0;
begin
  perform public.ddd_require_director();
  if p_month is null then raise exception 'Month required'; end if;
  -- 023: only a month that has ENDED (IST) — current month from the 1st of next month
  if m_start >= date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date then
    raise exception 'Is mahine ki salary mahina khatam hone ke baad (agle mahine ki 1 tareekh se) hi generate hogi';
  end if;
  for r in
    select e.id, e.hostel_id, e.joining_date, e.exit_date, coalesce(e.status, 'active') status,
           p.monthly_salary, p.pf_applicable, p.pf_wage
      from employees e join staff_salary_profile p on p.employee_id = e.id
     where p.monthly_salary > 0
  loop
    if r.status = 'left' and r.exit_date is null then continue; end if;
    v_from := greatest(m_start, coalesce(r.joining_date, m_start));
    v_to   := least(m_end, coalesce(r.exit_date, m_end));
    if v_from > v_to then continue; end if;
    if exists (select 1 from salary_runs where employee_id = r.id and month = m_start) then continue; end if;
    v_days  := v_to - v_from + 1;
    v_gross := round(r.monthly_salary * v_days / dim, 0);
    v_pfw   := round(coalesce(r.pf_wage, r.monthly_salary) * v_days / dim, 0);
    if r.pf_applicable then
      v_pf := public.ddd_pf(v_pfw); v_emp := (v_pf->>'emp')::numeric; v_empr := (v_pf->>'empr')::numeric;
    else
      v_emp := 0; v_empr := 0;
    end if;
    -- default = present; only "Mark Absent" days are stored (present = false)
    v_abs := (select count(*) from staff_attendance
               where employee_id = r.id and not present and date between v_from and v_to);
    v_att := v_days - v_abs;
    v_adv := greatest(0, least(public.ddd_advance_available(r.id, null), v_gross - v_emp));
    insert into salary_runs(employee_id, hostel_id, month, period_from, period_to, days_in_month, base_salary,
                            gross, attendance_days, absent_days, pf_on, pf_wage, employee_pf, employer_pf, advance_deduction, generated_by)
    values (r.id, r.hostel_id, m_start, v_from, v_to, dim, r.monthly_salary,
            v_gross, v_att, v_abs, r.pf_applicable, v_pfw, v_emp, v_empr, v_adv, auth.uid())
    on conflict (employee_id, month) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function public.salary_pay(p_run uuid, p_date date, p_mode text, p_txn text default null, p_remarks text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r salary_runs%rowtype; v_today date := (now() at time zone 'Asia/Kolkata')::date; v_mode text := lower(trim(coalesce(p_mode, '')));
        v_out numeric; v_abs int;
begin
  perform public.ddd_require_director();
  r := (select s from salary_runs s where s.id = p_run for update);
  if r.id is null then raise exception 'Salary row not found'; end if;
  if r.status <> 'pending' then raise exception 'Ye salary pehle hi paid hai'; end if;
  if p_date is null or p_date > v_today then raise exception 'Paid date aaj ya pehle ki honi chahiye'; end if;
  if v_mode not in ('cash', 'upi', 'bank') then raise exception 'Mode Cash / UPI / Bank hona chahiye'; end if;
  v_out := coalesce((select sum(amount) from salary_advances where employee_id = r.employee_id), 0)
         - coalesce((select sum(advance_deduction) from salary_runs where employee_id = r.employee_id and status = 'paid'), 0);
  if r.advance_deduction > greatest(v_out, 0) then
    raise exception 'Advance cut (%) outstanding advance (%) se zyada hai — pehle Edit karein', r.advance_deduction, greatest(v_out, 0);
  end if;
  -- freeze absent / present days at payment time (slip never changes later)
  v_abs := (select count(*) from staff_attendance
             where employee_id = r.employee_id and not present and date between r.period_from and r.period_to);
  update salary_runs
     set absent_days = v_abs, attendance_days = (r.period_to - r.period_from + 1) - v_abs,
         status = 'paid', paid_date = p_date, mode = v_mode, txn_ref = nullif(trim(p_txn), ''),
         remarks = coalesce(nullif(trim(p_remarks), ''), remarks), paid_by = auth.uid(),
         slip_no = coalesce(slip_no, 'SAL-' || to_char(month, 'YYMM') || '-' || lpad(nextval('public.salary_slip_seq')::text, 4, '0'))
   where id = r.id;
  r := (select s from salary_runs s where s.id = p_run);
  insert into salary_edits(run_id, field, old_value, new_value, reason, edited_by)
  values (r.id, 'status', 'pending', 'paid', 'Payment Done (' || v_mode || ')', auth.uid());
  return to_jsonb(r);
end $$;

-- recalc pending rows (paid rows keep their frozen numbers)
update public.salary_runs r
   set absent_days = x.a, attendance_days = (r.period_to - r.period_from + 1) - x.a
  from (select r2.id, (select count(*) from public.staff_attendance a
                        where a.employee_id = r2.employee_id and not a.present
                          and a.date between r2.period_from and r2.period_to)::int a
          from public.salary_runs r2 where r2.status = 'pending') x
 where x.id = r.id and r.status = 'pending'
   and (r.absent_days is distinct from x.a or r.attendance_days is distinct from (r.period_to - r.period_from + 1) - x.a);

revoke all on function public.generate_salary(date) from public, anon;
grant execute on function public.generate_salary(date) to authenticated;
revoke all on function public.salary_pay(uuid,date,text,text,text) from public, anon;
grant execute on function public.salary_pay(uuid,date,text,text,text) to authenticated;

commit;

-- VERIFY (expect 3 rows, all true):
-- select 'absent_days column' c, exists (select 1 from information_schema.columns where table_name='salary_runs' and column_name='absent_days') ok
-- union all select 'generate counts absent', pg_get_functiondef('public.generate_salary(date)'::regprocedure) like '%not present%'
-- union all select 'pay freezes absent', pg_get_functiondef('public.salary_pay(uuid,date,text,text,text)'::regprocedure) like '%absent_days = v_abs%';
