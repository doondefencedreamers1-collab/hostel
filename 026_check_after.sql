-- =====================================================================
-- 026_check_after.sql — 026 chalane ke BAAD (read-only, ek hi grid).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Har row ka ok = true hona chahiye. false ho to screenshot bhejein.
-- Phir 026_check_behaviour.sql chalayein.
-- =====================================================================

with
fn(f, want_definer) as (values
  ('public.ddd_stay_fee(numeric,date,date,date)', false),
  ('public.ddd_exit_review_once(monthly_dues,numeric,date,text,text)', true),
  ('public.ddd_exit_bills_sync(uuid,text)', true),
  ('public.ddd_guard_due_after_exit()', true),
  ('public.ddd_guard_due_period()', false),
  ('public.ddd_dues_exit_after_insert()', true),
  ('public.ddd_students_exit_default()', false),
  ('public.ddd_students_exit_bills()', true),
  ('public.ddd_dues_set_paid_to()', true),
  ('public.compute_paid_till(uuid,date,numeric)', true),
  ('public.generate_monthly_dues(date)', true),
  ('public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)', false),
  ('public.ddd_fee_range_plan(uuid,date,date)', true),
  ('public.delete_fee_payment(uuid)', true),
  ('public.ddd_period_numbers(date,date,boolean,uuid[],boolean)', true),
  ('public.dashboard_summary(date,date,uuid)', true)
),
app_fn(f) as (values ('public.generate_monthly_dues(date)'), ('public.delete_fee_payment(uuid)'), ('public.dashboard_summary(date,date,uuid)')),
fx as (
  select fn.f, fn.want_definer, p.oid, p.prosecdef, p.proconfig,
         md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as fp
  from fn left join pg_proc p on p.oid = to_regprocedure(fn.f)
),
trg(t, tbl) as (values
  ('trg_monthly_dues_exit_guard', 'public.monthly_dues'), ('trg_monthly_dues_exit_month', 'public.monthly_dues'),
  ('trg_students_exit_default', 'public.students'), ('trg_students_exit_bills', 'public.students'),
  ('trg_monthly_dues_paid_to', 'public.monthly_dues'), ('trg_monthly_dues_paid_till', 'public.monthly_dues'),
  ('trg_monthly_dues_discount_guard', 'public.monthly_dues'), ('trg_student_left', 'public.students'),
  ('trg_monthly_dues_period_guard', 'public.monthly_dues')
)
select 1 as ord, 'all 026 functions exist (naye + badle hue)' as chk, bool_and(oid is not null) as ok,
       coalesce(string_agg(f, ', ') filter (where oid is null), '') as detail from fx
union all
select 2, 'SECURITY DEFINER where needed (warden save works)', bool_and(prosecdef = want_definer),
       coalesce(string_agg(f, ', ') filter (where prosecdef is distinct from want_definer), '') from fx
union all
select 3, 'search_path = public on all of them', bool_and(proconfig::text like '%search_path=public%'),
       coalesce(string_agg(f, ', ') filter (where coalesce(proconfig::text, '') not like '%search_path=public%'), '') from fx
union all
select 4, 'generate_monthly_dues = 026 text', bool_and(fp = 'dc1b915e9229ae9b6952968878104450'), max(fp) from fx where f = 'public.generate_monthly_dues(date)'
union all
select 5, 'compute_paid_till = 026 text', bool_and(fp = 'd271416d96c5b317f390ee258737523a'), max(fp) from fx where f = 'public.compute_paid_till(uuid,date,numeric)'
union all
select 6, 'ddd_dues_set_paid_to = 026 text', bool_and(fp = '327e508d4ad8389c3c8a10232dbebe77'), max(fp) from fx where f = 'public.ddd_dues_set_paid_to()'
union all
select 7, 'ddd_due_paid_to + ddd_fee_range_plan + delete_fee_payment + dashboard = 026 text',
       count(*) = 5 and bool_and(fp = case f when 'public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)' then 'b6fb862ab3e8c55358d38605008dc1f7'
                                           when 'public.ddd_fee_range_plan(uuid,date,date)' then '6eb7654c1d987cc866106350fb505bc9'
                                           when 'public.delete_fee_payment(uuid)' then 'f323d01062d3076fdc28aad35a99698f'
                                           when 'public.ddd_period_numbers(date,date,boolean,uuid[],boolean)' then 'e6b351cd6db37302dd0c77598569569e'
                                           else '19909a440bf16429d20185c3e2965432' end),
       coalesce(string_agg(f || '=' || fp, ', ') filter (where fp not in ('b6fb862ab3e8c55358d38605008dc1f7', '6eb7654c1d987cc866106350fb505bc9', 'f323d01062d3076fdc28aad35a99698f', 'e6b351cd6db37302dd0c77598569569e', '19909a440bf16429d20185c3e2965432')), '')
  from fx where f in ('public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)', 'public.ddd_fee_range_plan(uuid,date,date)',
                      'public.delete_fee_payment(uuid)', 'public.ddd_period_numbers(date,date,boolean,uuid[],boolean)', 'public.dashboard_summary(date,date,uuid)')
union all
select 8, 'anon cannot run any of them', bool_and(not coalesce(has_function_privilege('anon', oid, 'execute'), false)),
       coalesce(string_agg(f, ', ') filter (where has_function_privilege('anon', oid, 'execute')), '') from fx
union all
select 9, 'app (authenticated) can run ONLY generate_monthly_dues, delete_fee_payment, dashboard_summary',
       bool_and(coalesce(has_function_privilege('authenticated', oid, 'execute'), false) = (f in (select f from app_fn))),
       coalesce(string_agg(f, ', ') filter (where coalesce(has_function_privilege('authenticated', oid, 'execute'), false) <> (f in (select f from app_fn))), '') from fx
union all
select 10, 'triggers present + enabled', count(tg.oid) = 9 and coalesce(bool_and(tg.tgenabled = 'O'), false),
       coalesce(string_agg(trg.t, ', ') filter (where tg.oid is null or tg.tgenabled <> 'O'), '')
  from trg left join pg_trigger tg on tg.tgname = trg.t and tg.tgrelid = to_regclass(trg.tbl)
union all
select 11, 'log table: RLS on, Director-only read policy',
       coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.ddd_dues_void_log')), false)
       and exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ddd_dues_void_log' and cmd = 'SELECT' and qual like '%is_director()%')
       and (select count(*) from pg_policies where schemaname = 'public' and tablename = 'ddd_dues_void_log') = 1, ''
union all
select 12, 'log table: anon nothing, app only SELECT',
       not coalesce(has_table_privilege('anon', to_regclass('public.ddd_dues_void_log'), 'select'), true)
       and not coalesce(has_table_privilege('anon', to_regclass('public.ddd_dues_void_log'), 'insert'), true)
       and coalesce(has_table_privilege('authenticated', to_regclass('public.ddd_dues_void_log'), 'select'), false)
       and not coalesce(has_table_privilege('authenticated', to_regclass('public.ddd_dues_void_log'), 'insert,update,delete,truncate'), true), ''
union all
select 13, 'log id sequence: anon / app no rights',
       case when to_regclass('public.ddd_dues_void_log') is null then false
            else not has_sequence_privilege('anon', pg_get_serial_sequence('public.ddd_dues_void_log', 'id'), 'usage,select,update')
             and not has_sequence_privilege('authenticated', pg_get_serial_sequence('public.ddd_dues_void_log', 'id'), 'usage,select,update') end, ''
union all
select 14, 'log action list has merge_void, payment_remove, fee_fix, rejoin, rejoin_keep',
       exists (select 1 from pg_constraint where conrelid = to_regclass('public.ddd_dues_void_log') and contype = 'c'
                 and pg_get_constraintdef(oid) like '%merge_void%' and pg_get_constraintdef(oid) like '%payment_remove%'
                 and pg_get_constraintdef(oid) like '%fee_fix%' and pg_get_constraintdef(oid) like '%''rejoin''%'
                 and pg_get_constraintdef(oid) like '%rejoin_keep%'), ''
union all
select 15, 'students.merged_into column + FK (on delete set null)',
       exists (select 1 from pg_constraint c where c.conrelid = 'public.students'::regclass and c.conname = 'students_merged_into_fkey'
                 and c.contype = 'f' and c.confdeltype = 'n'), ''
union all
select 16, 'app (authenticated) can still generate, anon cannot (022)',
       coalesce(has_function_privilege('authenticated', to_regprocedure('public.generate_monthly_dues(date)'), 'execute'), false)
       and not coalesce(has_function_privilege('anon', to_regprocedure('public.generate_monthly_dues(date)'), 'execute'), true), ''
union all
select 17, 'Paid Till sahi hai har student ka', not exists (select 1 from public.students s where s.paid_till is distinct from public.compute_paid_till(s.id)),
       (select count(*) from public.students s where s.paid_till is distinct from public.compute_paid_till(s.id))::text || ' different'
union all
select 19, 'wapsi (fix3): students.rejoined_on (date), log old/new_period_from, bills trigger rejoined_on bhi dekhta hai',
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'students' and column_name = 'rejoined_on' and data_type = 'date') = 1
       and (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'ddd_dues_void_log'
              and column_name in ('old_period_from', 'new_period_from') and data_type = 'date') = 2
       and coalesce((select pg_get_triggerdef(oid) like '%OF status, exit_date, rejoined_on%' from pg_trigger
                      where tgrelid = to_regclass('public.students') and tgname = 'trg_students_exit_bills'), false), ''
union all
select 18, 'info: log rows / void bills / merged students', true,
       case when to_regclass('public.ddd_dues_void_log') is null then '-'
            else (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.ddd_dues_void_log', false, true, '')))[1]::text end || ' / '
       || (select count(*) from public.monthly_dues where status = 'void') || ' / '
       || case when not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'students' and column_name = 'merged_into') then '-'
               else (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.students where merged_into is not null', false, true, '')))[1]::text end
order by 1;
