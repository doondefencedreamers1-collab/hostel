-- =====================================================================
--  DDD HOSTEL · READ-ONLY FEE-GENERATION DRY-RUN DIAGNOSTIC
--  Purpose: explain why July (2026-07) dues did/didn't generate per student.
--  SAFETY: This file contains ONLY SELECTs. It performs ZERO writes —
--          no INSERT / UPDATE / DELETE / RPC that mutates. It does NOT call
--          generate_monthly_dues / generate_anniversary_dues. Safe to run in
--          Supabase → SQL Editor (which runs as owner, bypassing RLS, so you
--          see ALL hostels — matching a director-level generation run).
--  It reuses the REAL selection rule of generate_monthly_dues (calendar mode)
--  and retrieves the REAL source of generate_anniversary_dues (if it exists).
--  Change :target_month if needed.
-- =====================================================================
\set target_month '2026-07-01'

-- ---------------------------------------------------------------------
-- 0. WHICH BILLING MODE IS LIVE?  (decides which code path actually runs)
--    If app_settings is missing or has no row, the app defaults to 'calendar'.
-- ---------------------------------------------------------------------
select 'billing_mode' as check,
       coalesce((select value from app_settings where key='billing_mode'),
                '(no app_settings row → app default = calendar)') as value;

-- ---------------------------------------------------------------------
-- 1. THE REAL ANNIVERSARY LOGIC (not in the repo — lives only in the DB).
--    If billing_mode='anniversary', THIS function is the generator. Read its
--    exact body here so its July date-math can be audited. Empty result =
--    the function does not exist in the DB at all (auto-gen would silently
--    no-op, because the client ignores the RPC error).
-- ---------------------------------------------------------------------
select p.proname,
       pg_get_functiondef(p.oid) as source_definition
from pg_proc p
where p.proname in ('generate_anniversary_dues','generate_monthly_dues');

-- ---------------------------------------------------------------------
-- 2. CALENDAR-MODE DRY-RUN (faithful to generate_monthly_dues):
--    RPC rule = FOR each student WHERE status='active' → INSERT (student, month)
--               ON CONFLICT (student_id, month) DO NOTHING.
--    So a student's July due is created iff: status='active' AND no July row yet.
--    (Plus latent aborts — see the flags column.)
-- ---------------------------------------------------------------------
select
  h.name                                   as hostel,
  s.full_name                              as student,
  s.id                                     as student_id,
  s.status                                 as student_status,
  s.monthly_fee,
  s.joining_date,
  s.exit_date,
  (md.id is not null)                       as july_due_already_exists,
  case
    when s.status <> 'active'
      then 'EXCLUDED: status=' || coalesce(s.status,'(null)') || ' (RPC only picks active)'
    when md.id is not null
      then 'SKIPPED: July due already exists → ON CONFLICT DO NOTHING'
    when s.monthly_fee is null
      then 'WOULD-ABORT RUN: monthly_fee IS NULL → NOT NULL violation aborts the ENTIRE generate call'
    else 'WOULD-GENERATE'
  end                                       as would_generate_reason
from students s
left join hostels h on h.id = s.hostel_id
left join monthly_dues md
       on md.student_id = s.id
      and md.month = date_trunc('month', :'target_month'::date)::date
order by h.name, (s.status='active') desc, s.full_name;

-- ---------------------------------------------------------------------
-- 3. PER-HOSTEL SUMMARY: active students vs July dues actually present.
--    A gap here (active > have_july_due and none would-abort) points at
--    status data or the anniversary path, NOT the calendar RPC.
-- ---------------------------------------------------------------------
select
  h.name as hostel,
  count(*) filter (where s.status='active')                       as active_students,
  count(*) filter (where s.status='active' and s.monthly_fee is null) as active_null_fee,
  count(distinct md.student_id)                                   as students_with_july_due,
  count(*) filter (where s.status='active')
    - count(distinct md.student_id)                               as missing_july
from hostels h
left join students s on s.hostel_id = h.id
left join monthly_dues md
       on md.student_id = s.id
      and md.month = date_trunc('month', :'target_month'::date)::date
group by h.name
order by h.name;

-- ---------------------------------------------------------------------
-- 4. JUNE vs JULY, side by side (why June worked, July didn't) per student.
-- ---------------------------------------------------------------------
select
  h.name as hostel, s.full_name as student, s.status,
  max(case when md.month = date '2026-06-01' then 1 else 0 end) as had_june_due,
  max(case when md.month = date '2026-07-01' then 1 else 0 end) as had_july_due
from students s
left join hostels h on h.id = s.hostel_id
left join monthly_dues md on md.student_id = s.id
group by h.name, s.full_name, s.status
having max(case when md.month = date '2026-06-01' then 1 else 0 end) = 1
   and max(case when md.month = date '2026-07-01' then 1 else 0 end) = 0
order by h.name, s.full_name;   -- students who HAD June but are MISSING July

-- ---------------------------------------------------------------------
-- 5. TASK 4 — controlled compare (fill in the ids/names from the app).
--    Example for Drona Vatika: 3 that don't generate vs 3 that do.
-- ---------------------------------------------------------------------
-- select h.name as hostel, s.full_name, s.id, s.status, s.monthly_fee,
--        s.joining_date, s.exit_date,
--        exists(select 1 from monthly_dues md where md.student_id=s.id
--               and md.month = date '2026-07-01') as has_july_due
-- from students s left join hostels h on h.id=s.hostel_id
-- where s.full_name in ('<NON-GEN 1>','<NON-GEN 2>','<NON-GEN 3>',
--                       '<GEN 1>','<GEN 2>','<GEN 3>')
-- order by has_july_due, s.full_name;
