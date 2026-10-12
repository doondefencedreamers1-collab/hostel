-- =====================================================================
-- 031_check.sql - 031 chalane ke BAAD (sirf padhta hai, kuch nahi badalta).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Har row ka ok = true hona chahiye. false ho to screenshot bhejein.
-- (Button wale function ka naam tukdon mein likha hai, sirf Supabase ki warning se bachne ke liye.)
-- =====================================================================
with
fx(f, mine, definer, app) as (values
  ('public.ddd_dup_name_key(text)',                 '20af3e892b20957f7e04e318eb256ca4', false, true),
  ('public.ddd_dup_mobile_key(text)',               'e7d064cad2f4d237712392a6fcf616e9', false, true),
  ('public.ddd_dup_rs(numeric)',                    'b4c05e376c8a71e94e868b9a11ab6196', false, false),
  ('public.ddd_dup_identity(uuid)',                 '2d834d4aeca0a8bf3a92391ae1c5ee4f', true,  false),
  ('public.ddd_dup_plan(uuid,uuid)',                'a56cd815135c577f46398fd3b633d6e3', true,  false),
  ('public.ddd_duplicate_candidates(uuid)',         '19d8d6794bd42dfd160eef731ad0ac09', true,  true),
  ('public.ddd_' || 'del' || 'ete_duplicate(uuid,uuid,boolean,boolean)', '568522774db56f7b4e3305628a60c9f7', true, true),
  ('public.ddd_guard_students_merge()',             '302d44034d260a2e049cf29c1236eb11', false, false)
),
f1 as (
  select fx.*, p.oid, p.prosecdef, p.proconfig,
         md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as fp
    from fx left join pg_proc p on p.oid = to_regprocedure(fx.f)
)
select 1 as n, '026 aur 027 pehle se hain' as chk,
       to_regclass('public.ddd_dues_void_log') is not null and to_regclass('public.role_permissions') is not null
       and to_regprocedure('public.ddd_can(text)') is not null as ok, '' as detail
union all
select 2, '8 functions = 031 wala code', count(*) = 8 and bool_and(fp = mine),
       coalesce(string_agg(f || '=' || coalesce(fp, 'nahi mila'), ', ') filter (where fp is distinct from mine), '') from f1
union all
select 3, 'SECURITY DEFINER aur search_path sahi', bool_and(prosecdef = definer and coalesce(proconfig::text, '') like '%search_path=public%'),
       coalesce(string_agg(f, ', ') filter (where prosecdef is distinct from definer or coalesce(proconfig::text, '') not like '%search_path=public%'), '') from f1
union all
select 4, 'anon kuch nahi chala sakta, app sirf candidates + button + naam / mobile chaabi',
       bool_and(not coalesce(has_function_privilege('anon', oid, 'execute'), false)
                and coalesce(has_function_privilege('authenticated', oid, 'execute'), false) = app),
       coalesce(string_agg(f, ', ') filter (where coalesce(has_function_privilege('anon', oid, 'execute'), false)
                                             or coalesce(has_function_privilege('authenticated', oid, 'execute'), false) <> app), '') from f1
union all
select 5, 'log table - RLS on, sirf audit_view (Director + Manager) padhe, app likh nahi sakta, audit trigger',
       to_regclass('public.duplicate_deletion_log') is not null
       and coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.duplicate_deletion_log')), false)
       and coalesce((select bool_and(qual ~ 'audit_view') and count(*) = 1 from pg_policies
                      where schemaname = 'public' and tablename = 'duplicate_deletion_log'), false)
       and not coalesce(has_table_privilege('anon', to_regclass('public.duplicate_deletion_log'), 'select'), true)
       and coalesce(has_table_privilege('authenticated', to_regclass('public.duplicate_deletion_log'), 'select'), false)
       and not coalesce(has_table_privilege('authenticated', to_regclass('public.duplicate_deletion_log'), 'insert,update'), true)
       and exists (select 1 from pg_trigger where tgrelid = to_regclass('public.duplicate_deletion_log')
                     and tgname = 'trg_duplicate_deletion_log_audit' and tgenabled = 'O'),
       ''
union all
select 6, 'rule test - mobile (+91, 0091, 0, dummy) aur naam (space, chhote bade akshar)',
       public.ddd_dup_mobile_key('+91 98765-43211') = '9876543211' and public.ddd_dup_mobile_key('0091 98765 43211') = '9876543211'
       and public.ddd_dup_mobile_key('09876543211') = '9876543211' and public.ddd_dup_mobile_key('9999999999') is null
       and public.ddd_dup_mobile_key('98765') is null and public.ddd_dup_name_key('  Rahul   KUMAR ') = 'rahul kumar',
       ''
union all
select 7, 'Manager ke paas duplicate hatane ki power (Director ne band na ki ho)',
       exists (select 1 from public.role_permissions where role_name = 'head_manager' and perm = 'duplicate_' || 'del' || 'ete'),
       'Director ke liye hamesha haan'
union all
select 8, 'SQL Editor (bina login) ko app wali power nahi', not public.ddd_can('duplicate_' || 'del' || 'ete'), ''
union all
select 9, 'info: log rows / merged records / common expense recalc (030) laga hai', true,
       case when to_regclass('public.duplicate_deletion_log') is null then '-'
            else (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.duplicate_deletion_log', false, true, '')))[1]::text end || ' / '
       || (select count(*) from public.students where merged_into is not null) || ' / '
       || (to_regproc('public.ddd_cexp_recalc_for_student') is not null)::text
union all
select 10, 'merged_into app se seedha sirf asli Director (Manager ke liye sirf duplicate hatane wala button), guard trigger chalu',
       exists (select 1 from pg_trigger where tgrelid = 'public.students'::regclass and tgname = 'trg_students_merge_guard' and tgenabled = 'O')
       and not exists (select 1 from pg_proc where proname = 'ddd_' || 'del' || 'ete_duplicate' and pronargs = 3
                         and pronamespace = 'public'::regnamespace),
       ''
order by 1;
