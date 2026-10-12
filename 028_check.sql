-- =====================================================================
-- 028_check.sql - 028 chalane ke BAAD (sirf padhta hai, ek hi grid).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Har row ka ok = true hona chahiye. false ho to screenshot bhejein.
-- (026_check_after.sql ki row 4 ab false aayegi - generate_monthly_dues ab 028 wala hai, yeh normal hai.)
-- =====================================================================
with
fn(f, want_definer, want_fp, app) as (values
  ('public.generate_monthly_dues(date)', true, '387a1c4bbf3befd90af6d1d67e2f745e', true),
  ('public.ddd_fee_change(uuid,numeric,date,boolean)', true, 'bb67e08096db5536d8acbf9f098c058e', true),
  ('public.ddd_student_has_dues(uuid)', true, '6e0f2f218de50ee50cfcd54286b45888', true),
  ('public.ddd_fee_change_run(uuid,numeric,date)', true, 'd2e40b37657872548d875e0b9aab1dbe', false),
  ('public.ddd_fee_reprice_due(uuid,numeric,text,text)', true, '3edf70e8a93d733c0031aa554bcdd183', false),
  ('public.ddd_dues_regen_month(date)', true, '8d5cb08e82c50636a96630f55851cf6a', false),
  ('public.ddd_students_fee_guard()', false, '43fb97e9281b5ecc5f162da564464373', false),
  ('public.ddd_dues_auto_price()', false, '5bd3ec2ab407de70ba29e58acd6599cf', false)
),
fx as (
  select fn.f, fn.want_definer, fn.want_fp, fn.app, p.oid, p.prosecdef, p.proconfig,
         md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as fp
  from fn left join pg_proc p on p.oid = to_regprocedure(fn.f)
),
dep(f, want_fp) as (values
  ('public.ddd_exit_bills_sync(uuid,text)', '36d917ff10af21abd6095df97d1ddba8'),
  ('public.ddd_exit_review_once(public.monthly_dues,numeric,date,text,text)', '9cbcabf64a9e0200808c55998af07296'),
  ('public.ddd_stay_fee(numeric,date,date,date)', '852926fef2d3b83bb1c4d07a0f22573b'),
  ('public.ddd_month_fee(numeric,date,date)', 'ce0718798846b2d7741d076f715b7886')
),
trg(t, tbl, want) as (values
  ('trg_students_fee_guard', 'public.students', 'BEFORE UPDATE OF monthly_fee ON'),
  ('trg_monthly_dues_auto_price', 'public.monthly_dues', 'BEFORE INSERT OR UPDATE OF auto_fee, auto_amount ON'),
  ('trg_ddd_fee_change_log_audit', 'public.ddd_fee_change_log', 'audit_trigger()'),
  ('trg_monthly_dues_exit_guard', 'public.monthly_dues', 'BEFORE INSERT'), ('trg_monthly_dues_exit_month', 'public.monthly_dues', 'AFTER INSERT'),
  ('trg_monthly_dues_period_guard', 'public.monthly_dues', 'BEFORE UPDATE'), ('trg_monthly_dues_paid_to', 'public.monthly_dues', 'BEFORE INSERT OR UPDATE'),
  ('trg_monthly_dues_paid_till', 'public.monthly_dues', 'AFTER INSERT OR'), ('trg_monthly_dues_discount_guard', 'public.monthly_dues', 'BEFORE INSERT OR UPDATE'),
  ('trg_students_exit_default', 'public.students', 'BEFORE INSERT OR UPDATE'), ('trg_students_exit_bills', 'public.students', 'AFTER UPDATE OF status, exit_date, rejoined_on')
),
cm as (select date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date as c)
select 1 as n, 'monthly_dues.auto_fee + auto_amount (numeric) bane' as chk,
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'monthly_dues'
          and column_name in ('auto_fee', 'auto_amount') and data_type = 'numeric') = 2 as ok, '' as detail
union all
select 2, '028 ke 8 functions maujood (generate + ddd_fee_change + helpers)', bool_and(oid is not null),
       coalesce(string_agg(f, ', ') filter (where oid is null), '') from fx
union all
select 3, 'SECURITY DEFINER / INVOKER sahi, search_path = public', bool_and(prosecdef = want_definer and proconfig::text like '%search_path=public%'),
       coalesce(string_agg(f, ', ') filter (where prosecdef is distinct from want_definer or coalesce(proconfig::text, '') not like '%search_path=public%'), '') from fx
union all
select 4, 'sab 028 text (generate_monthly_dues = 026 rules + dobara Generate)', bool_and(fp = want_fp),
       coalesce(string_agg(f || '=' || coalesce(fp, '-'), ', ') filter (where fp is distinct from want_fp), '') from fx
union all
select 5, 'anon koi function nahi chala sakta', bool_and(not coalesce(has_function_privilege('anon', oid, 'execute'), false)),
       coalesce(string_agg(f, ', ') filter (where has_function_privilege('anon', oid, 'execute')), '') from fx
union all
select 6, 'app sirf generate_monthly_dues, ddd_fee_change, ddd_student_has_dues chala sakta hai',
       bool_and(coalesce(has_function_privilege('authenticated', oid, 'execute'), false) = app),
       coalesce(string_agg(f, ', ') filter (where coalesce(has_function_privilege('authenticated', oid, 'execute'), false) <> app), '') from fx
union all
select 7, 'triggers maujood + chalu (028 ke 3 + 026 wale)', count(tg.oid) = 11 and coalesce(bool_and(tg.tgenabled = 'O' and pg_get_triggerdef(tg.oid) like '%' || trg.want || '%'), false),
       coalesce(string_agg(trg.t, ', ') filter (where tg.oid is null or tg.tgenabled <> 'O' or pg_get_triggerdef(tg.oid) not like '%' || trg.want || '%'), '')
  from trg left join pg_trigger tg on tg.tgname = trg.t and tg.tgrelid = to_regclass(trg.tbl)
union all
select 8, 'ddd_fee_change_log: RLS on, sirf Director / Manager padh sakte hain, app likh nahi sakta',
       coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.ddd_fee_change_log')), false)
       and (select count(*) from pg_policies where schemaname = 'public' and tablename = 'ddd_fee_change_log') = 1
       and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ddd_fee_change_log' and cmd = 'SELECT' and qual like '%is_director()%')
       and not exists (select 1 from pg_class c, aclexplode(c.relacl) a
                        where c.oid = to_regclass('public.ddd_fee_change_log')
                          and ((a.grantee = (select oid from pg_roles where rolname = 'anon'))
                               or (a.grantee = (select oid from pg_roles where rolname = 'authenticated') and a.privilege_type <> 'SELECT'))),
       ''
union all
select 9, '026 ke functions jin par 028 chalta hai = 026 text', bool_and(md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) = dep.want_fp),
       coalesce(string_agg(dep.f, ', ') filter (where p.oid is null or md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) <> dep.want_fp), '')
  from dep left join pg_proc p on p.oid = to_regprocedure(dep.f)
union all
select 10, 'ek student ka ek mahine ka ek hi bill (UNIQUE + koi duplicate nahi)',
       exists (select 1 from pg_constraint where conrelid = 'public.monthly_dues'::regclass and contype = 'u' and pg_get_constraintdef(oid) = 'UNIQUE (student_id, month)')
       and not exists (select 1 from public.monthly_dues group by student_id, month having count(*) > 1), ''
union all
select 11, 'Paid Till sahi hai har student ka', not exists (select 1 from public.students s where s.paid_till is distinct from public.compute_paid_till(s.id)),
       (select count(*) from public.students s where s.paid_till is distinct from public.compute_paid_till(s.id))::text || ' alag'
union all
select 12, 'info: auto bills / fee badlav / dobara-Generate badlav / regen_error', true,
       (select count(*) from public.monthly_dues where auto_fee is not null)::text || ' / '
       || (select count(*) from public.ddd_fee_change_log where kind = 'fee_change') || ' / '
       || (select count(*) from public.ddd_fee_change_log where kind = 'regen') || ' / '
       || (select count(*) from public.ddd_fee_change_log where kind = 'regen_error')
union all
select 13, 'info: is mahine ke bill jinka amount Monthly Fee se alag hai (fixed bills, Director chahe to fee prompt se badle)', true,
       (select count(*) from public.monthly_dues d join public.students s on s.id = d.student_id, cm
         where d.month = cm.c and d.status is distinct from 'void' and coalesce(d.period_from, d.month) = d.month
           and coalesce(d.period_to, (d.month + interval '1 month - 1 day')::date) = (d.month + interval '1 month - 1 day')::date
           and d.fee_amount <> coalesce(s.monthly_fee, 0) and s.merged_into is null)::text
order by 1;
