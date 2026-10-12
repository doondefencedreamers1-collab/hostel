-- =====================================================================
-- 029_staff_on_bed.sql   (026 ke BAAD, 028 ke baad chalayein. 027 / 028 ke bina bhi chalta hai)
-- DDD Hostel - STAFF bhi bed par (Phase 5, owner decisions D-staff, R8, R9)
--
--  1. students table mein naya column occupant_type:
--       student = aam student (saare purane records student hi rahenge)
--       staff   = staff jo hostel ke bed par rehta hai (cook, guard ...)
--     Staff bhi students table ki ek row hai, isliye bed, Left, profile, fee, payment,
--     026 exit rules sab bina badle chalte hain. Staff module ke employee (bina bed) nahi gine jaate.
--  2. Staff ki fee kuch bhi ho sakti hai, 0 bhi. Fee 0 = kabhi bill nahi banta
--     (Generate fee 0 ko chhod deta hai, koi error nahi), kabhi due nahi dikhta.
--  3. Rok (R8, M5): Staff ki fee 0 sirf Director / Manager rakh sakte hain (warden nahi).
--     Jis student ka bill ya payment ho chuka hai, use Staff sirf Director / Manager bana sakte hain.
--     Jis record par purane bill ka baaki hai use fee 0 wala Staff koi nahi bana sakta (pehle baaki
--     clear karein), kyunki fee 0 wala Staff kabhi due nahi dikhta.
--  4. Dashboard (R9): Students (active) ab sirf students. Staff alag gine jaate hain
--     (staff, staff_nofee, hostel-wise staff). New Admissions / Students Left mein staff nahi.
--     Missing data mein fee 0 wala staff nahi. Pending, billed, collected bilkul pehle jaise.
--
-- Is file se KOI data row nahi badalti. Saare purane records Student rehte hain.
-- Ek transaction, 2 baar chalana safe. Pehle backup lein. Class time ke bahar chalayein
-- (students table par 1 second ka lock).   Phir 029_check.sql.   Undo: 029_undo.sql
-- Dhyan dein: 026_check_after.sql ki row 7 ab false dikhayegi kyunki dashboard_summary aur
-- ddd_period_numbers ab 029 wale hain (026 ke rules andar wahi). Yeh normal hai.
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------------------------------------------------------------------
-- 0. pre-check (kuch bhi alag = yahin ruk jaata hai, kuch nahi badalta)
-- ---------------------------------------------------------------------
do $pre$
declare
  h text;
  v_type text;
  v_null text;
  v_dflt text;
  t text;
begin
  foreach t in array array['public.ddd_is_api_caller()', 'public.is_director()', 'public.audit_trigger()',
                           'public.dashboard_summary(date,date,uuid)', 'public.ddd_period_numbers(date,date,boolean,uuid[],boolean)'] loop
    if to_regprocedure(t) is null then
      raise exception '029 RUKA: function % nahi mila. Mujhe batayein. Kuch nahi badla.', t;
    end if;
  end loop;
  if to_regclass('public.ddd_dues_void_log') is null then
    raise exception '029 RUKA: 026 (billing exit rules) live par nahi mila. Pehle 026 chalayein. Kuch nahi badla.';
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.dashboard_summary(date,date,uuid)'));
  if h is null or h not in ('19909a440bf16429d20185c3e2965432', 'e0e0f03021b3c96eff920a04025f194f') then
    raise exception '029 RUKA: live dashboard_summary 026 wala nahi hai (%). Kisi aur ne badla hai - mujhe batayein. Kuch nahi badla.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.ddd_period_numbers(date,date,boolean,uuid[],boolean)'));
  if h is null or h not in ('e6b351cd6db37302dd0c77598569569e', '681e7819277c005b01035753cdc5c50a') then
    raise exception '029 RUKA: live ddd_period_numbers 026 wala nahi hai (%). Kisi aur ne badla hai - mujhe batayein. Kuch nahi badla.', h;
  end if;
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'students'
        and column_name in ('id', 'full_name', 'status', 'monthly_fee', 'joining_date', 'exit_date', 'hostel_id', 'merged_into')) <> 8 then
    raise exception '029 RUKA: students ke columns expected jaise nahi. Mujhe batayein. Kuch nahi badla.';
  end if;
  -- column pehle se ho (dobara chalana) to wahi tarah ka
  v_type := (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'students' and column_name = 'occupant_type');
  v_null := (select is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'students' and column_name = 'occupant_type');
  v_dflt := (select column_default from information_schema.columns where table_schema = 'public' and table_name = 'students' and column_name = 'occupant_type');
  if v_type is not null and (v_type <> 'text' or v_null <> 'NO' or coalesce(v_dflt, '') not like '%student%') then
    raise exception '029 RUKA: students.occupant_type pehle se hai par alag tarah ka (% / nullable % / default %). Mujhe batayein. Kuch nahi badla.',
      v_type, v_null, v_dflt;
  end if;
end
$pre$;

-- ---------------------------------------------------------------------
-- 1. column + rule (metadata only: koi row rewrite nahi, koi audit row nahi)
-- ---------------------------------------------------------------------
alter table public.students add column if not exists occupant_type text not null default 'student';
do $con$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.students'::regclass and conname = 'students_occupant_type_chk') then
    alter table public.students add constraint students_occupant_type_chk check (occupant_type in ('student', 'staff'));
  end if;
end
$con$;
comment on column public.students.occupant_type is
  '029: student = aam student, staff = hostel ke bed par rehne wala staff. Staff ki fee koi bhi (0 bhi, 0 = kabhi bill nahi). Staff fee 0 sirf Director / Manager.';

-- ---------------------------------------------------------------------
-- 2. guard (SECURITY INVOKER jaan-bujh kar: ddd_is_api_caller asli caller dekhta hai, 026 jaisa)
-- ---------------------------------------------------------------------
create or replace function public.ddd_students_occupant_guard() returns trigger
language plpgsql set search_path = public as $$
declare
  v_due numeric;
begin
  new.occupant_type := coalesce(nullif(lower(btrim(new.occupant_type)), ''), 'student');
  if public.ddd_is_api_caller() and not coalesce(public.is_director(), false) then
    -- bill / payment wala student -> Staff = sirf Director / Manager
    if tg_op = 'UPDATE' and old.occupant_type = 'student' and new.occupant_type = 'staff'
       and (exists (select 1 from public.monthly_dues d
                     where d.student_id = old.id and coalesce(d.fee_amount, 0) > 0 and d.status is distinct from 'void')
            or exists (select 1 from public.fee_payments f where f.student_id = old.id)) then
      raise exception 'Is student ka bill ya payment pehle se hai. Student ko Staff sirf Director ya Manager bana sakte hain.'
        using errcode = '42501';
    end if;
    -- R8 / M5: Staff fee 0 = sirf Director / Manager
    if new.occupant_type = 'staff' and coalesce(new.monthly_fee, 0) <= 0
       and (tg_op = 'INSERT' or old.occupant_type is distinct from 'staff' or new.monthly_fee is distinct from old.monthly_fee) then
      raise exception 'Staff ki fee 0 sirf Director ya Manager rakh sakte hain. Fee likhein, ya Director / Manager se karwayein.'
        using errcode = '42501';
    end if;
  end if;
  -- fee 0 wala Staff kabhi due nahi dikhta: purane bill ka baaki ho to pehle woh clear (Director / Manager bhi)
  if public.ddd_is_api_caller() and tg_op = 'UPDATE' and new.occupant_type = 'staff' and coalesce(new.monthly_fee, 0) <= 0
     and (old.occupant_type is distinct from 'staff' or coalesce(old.monthly_fee, 0) > 0) then
    v_due := (select coalesce(sum(d.fee_amount - coalesce(d.discount, 0) - coalesce(d.paid_amount, 0)), 0)
                from public.monthly_dues d
               where d.student_id = old.id and d.status is distinct from 'void'
                 and d.fee_amount - coalesce(d.discount, 0) - coalesce(d.paid_amount, 0) > 0);
    if v_due > 0 then
      raise exception 'Is record par purane bill ka Rs % baaki hai. Fee 0 wala Staff kabhi due nahi dikhta, isliye pehle purana baaki clear karein (fee lein ya bill theek karein), phir Staff fee 0 karein.',
        regexp_replace(v_due::text, '[.]00$', '') using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

revoke all on function public.ddd_students_occupant_guard() from public, anon, authenticated;

drop trigger if exists trg_students_occupant_guard on public.students;
create trigger trg_students_occupant_guard
  before insert or update of occupant_type, monthly_fee on public.students
  for each row execute function public.ddd_students_occupant_guard();

-- ---------------------------------------------------------------------
-- 3. dashboard (R9): 026 text + staff alag. Rights / owner / SECURITY DEFINER wahi.
-- ---------------------------------------------------------------------
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

  -- 026: merged purana duplicate record admission / left mein nahi gina jaata (Students list jaisa)
  -- 029: staff (bed par) admission / left mein nahi gine jaate (Students list jaisa)
  v_adm := (select count(*) from students
            where joining_date between p_from and p_to and (p_all or hostel_id = any(p_hs)) and merged_into is null
              and occupant_type is distinct from 'staff');
  v_left := (select count(*) from students
             where exit_date between p_from and p_to and (p_all or hostel_id = any(p_hs)) and merged_into is null
               and occupant_type is distinct from 'staff');

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
  v_snap := (with st as (   -- 026: merged purana record nahi (naya record already gina hai)
    select s.* from students s
    where (v_all or s.hostel_id = any(v_hs)) and s.merged_into is null
      and (s.joining_date is null or s.joining_date <= v_asof)
      and (s.exit_date is null or s.exit_date > v_asof)
      and (coalesce(s.status, 'active') <> 'left' or s.exit_date > v_asof)
  ),
  bill as (   -- billable: today = exactly the app rule (not left, joining date, fee), past = active on that date
    select s.* from students s
    where (v_all or s.hostel_id = any(v_hs)) and s.merged_into is null
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
    where d.status is distinct from 'void'   -- 026: Cancelled bill kuch nahi ginta
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
    -- 029 (R9): students = sirf students, staff (bed par) alag. Fee 0 wala staff missing data nahi.
    'students', (select count(*) from st where st.occupant_type is distinct from 'staff'),
    'staff', (select count(*) from st where st.occupant_type = 'staff'),
    'staff_nofee', (select count(*) from st where st.occupant_type = 'staff' and coalesce(st.monthly_fee, 0) <= 0),
    'staff_by_hostel', (select coalesce(jsonb_object_agg(q.hostel_id, q.n), '{}'::jsonb)
                          from (select st.hostel_id, count(*) as n from st
                                 where st.occupant_type = 'staff' and st.hostel_id is not null group by st.hostel_id) q),
    'missing', (select count(*) from st where joining_date is null
                                       or (coalesce(monthly_fee, 0) <= 0 and occupant_type is distinct from 'staff')),
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
             'staff', coalesce((v_snap -> 'staff_by_hostel' ->> h.id::text)::int, 0),
             'students', (select count(*) from students s where s.hostel_id = h.id and s.merged_into is null
                            and s.occupant_type is distinct from 'staff'
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

-- ---------------------------------------------------------------------
-- 4. verify (kuch bhi galat = poora rollback)
-- ---------------------------------------------------------------------
do $verify$
declare
  h text;
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'students'
                    and column_name = 'occupant_type' and data_type = 'text' and is_nullable = 'NO') then
    raise exception '029 VERIFY FAIL: occupant_type column nahi bana.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.students'::regclass and conname = 'students_occupant_type_chk') then
    raise exception '029 VERIFY FAIL: occupant_type check nahi bana.';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.students'::regclass and tgname = 'trg_students_occupant_guard' and tgenabled = 'O') then
    raise exception '029 VERIFY FAIL: guard trigger nahi bana.';
  end if;
  if exists (select 1 from public.students where occupant_type not in ('student', 'staff')) then
    raise exception '029 VERIFY FAIL: occupant_type mein galat value.';
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.dashboard_summary(date,date,uuid)'));
  if h is distinct from 'e0e0f03021b3c96eff920a04025f194f' then raise exception '029 VERIFY FAIL: dashboard_summary 029 text nahi (%).', h; end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.ddd_period_numbers(date,date,boolean,uuid[],boolean)'));
  if h is distinct from '681e7819277c005b01035753cdc5c50a' then raise exception '029 VERIFY FAIL: ddd_period_numbers 029 text nahi (%).', h; end if;
  if has_function_privilege('anon', 'public.dashboard_summary(date,date,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.dashboard_summary(date,date,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.ddd_period_numbers(date,date,boolean,uuid[],boolean)', 'execute') then
    raise exception '029 VERIFY FAIL: dashboard rights badal gaye.';
  end if;
end
$verify$;

commit;

notify pgrst, 'reload schema';

-- verify: 029_check.sql (ek grid, har row ok = true)

-- ---------- ROLLBACK ----------
-- Wapas lena ho to pehle naya app hata kar purana app lagayein, phir 029_undo.sql poori file chalayein.
-- Undo staff records ki list backup_029.staff_rows mein rakhta hai (agar koi staff hai), dashboard_summary
-- aur ddd_period_numbers ko bilkul 026 text par wapas lagata hai, guard trigger / function / check hatata hai
-- aur occupant_type column hatata hai. Koi bill ya payment nahi badalta.
