-- =====================================================================
-- 023a_salary_guard.sql   (needs 019 + 023a_run_checks STEP 2 backup)
--   1. generate_salary: sirf KHATAM ho chuka mahina (IST). Chalu mahina
--      agle mahine ki 1 tareekh se. (pehle sirf future month block tha)
--   2. September 2026 ke salary rows (29 Sep ko bane, sab pending) delete —
--      1 October ke baad Salary page se dobara Generate karein.
-- One transaction. Undo: 023a_undo.sql
-- =====================================================================
begin;

do $$
declare
  n_now int; n_bak int; v_def text; v_new text;
begin
  if to_regclass('backup_023.salary_runs') is null or to_regclass('backup_023.meta') is null then
    raise exception '023a aborted: pehle 023a_run_checks.sql STEP 2 (backup) chalayein.';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'salary_runs' and column_name = 'absent_days') then
    raise exception '023a aborted: pehle 019_staff_absent.sql chalayein.';
  end if;
  if not exists (select 1 from backup_023.meta where k = 'fn:generate_salary(date)') then
    raise exception '023a aborted: generate_salary backup nahi mila (STEP 2 dobara chalayein).';
  end if;
  if exists (select 1 from public.salary_runs where month = date '2026-09-01' and status <> 'pending') then
    raise exception '023a aborted: September ka koi row PAID hai — kuch nahi badla. Mujhe batayein.';
  end if;
  n_now := (select count(*) from public.salary_runs where month = date '2026-09-01');
  n_bak := (select count(*) from public.salary_runs r where r.month = date '2026-09-01'
              and exists (select 1 from backup_023.salary_runs b where b.id = r.id));
  if n_now <> n_bak then
    raise exception '023a aborted: % September rows mein se sirf % backup mein hain — STEP 2 dobara chalayein.', n_now, n_bak;
  end if;

  -- 1. guard (same text in 018 and 019 versions)
  v_def := pg_get_functiondef('public.generate_salary(date)'::regprocedure);
  if v_def not like '%m_start >= date_trunc(''month'', (now() at time zone ''Asia/Kolkata''))::date%' then
    if v_def not like '%if m_start > date_trunc(''month'', (now() at time zone ''Asia/Kolkata''))::date then%' then
      raise exception '023a aborted: generate_salary ka code expected jaisa nahi hai — kuch nahi badla.';
    end if;
    v_new := replace(v_def, 'if m_start > date_trunc(''month'', (now() at time zone ''Asia/Kolkata''))::date then',
                            'if m_start >= date_trunc(''month'', (now() at time zone ''Asia/Kolkata''))::date then');
    v_new := replace(v_new, 'Future month ki salary generate nahi ho sakti',
                            'Is mahine ki salary mahina khatam hone ke baad (agle mahine ki 1 tareekh se) hi generate hogi');
    execute v_new;
  end if;

  -- 2. September 2026 rows (only the backed-up, pending ones)
  delete from public.salary_runs r
   where r.month = date '2026-09-01' and r.status = 'pending'
     and exists (select 1 from backup_023.salary_runs b where b.id = r.id);
end $$;

revoke all on function public.generate_salary(date) from public, anon;
grant execute on function public.generate_salary(date) to authenticated;

notify pgrst, 'reload schema';

commit;
