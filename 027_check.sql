-- =====================================================================
-- 027_check.sql - 027 chalane ke BAAD (sirf padhta hai, kuch nahi badalta).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Har row ka ok = true hona chahiye. false ho to screenshot bhejein.
-- =====================================================================
with
fx(f, mine, definer, app) as (values
  ('public.is_director()',               '6d0293244393278d7db735b56a181be4', true, true),
  ('public.approve_warden(uuid,uuid)',   '85353bfe7d1f0bb8a8cd666b2fd6741b', true, true),
  ('public.reject_warden(uuid)',         '72262d1ff502edf2416ae8e27fd4e402', true, true),
  ('public.remove_warden(uuid)',         '0afce424766f9bb07e71957f074e137c', true, true),
  ('public.pending_wardens()',           '6ee7806c7a9c501fb77c9e7a1df2f5cc', true, true)
),
f1 as (
  select fx.*, p.oid, md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as fp
    from fx left join pg_proc p on p.oid = to_regprocedure(fx.f)
),
nf(f, definer, app) as (values
  ('public.ddd_can(text)', true, true),
  ('public.is_real_director()', true, true),
  ('public.ddd_my_role()', true, true),
  ('public.ddd_my_perms()', true, true),
  ('public.ddd_is_trusted_session()', false, false),
  ('public.ddd_user_perm_needed(text,uuid)', true, false),
  ('public.ddd_can_manage_user(uuid)', true, false),
  ('public.ddd_guard_users_role()', true, false),
  ('public.ddd_guard_uha_role()', true, false),
  ('public.ddd_guard_role_permissions()', true, false),
  ('public.ddd_guard_expense_approve()', false, false),
  ('public.ddd_guard_student_del_role()', false, false),
  ('public.ddd_guard_student_created_by()', false, false),
  ('public.ddd_guard_hostel_keep_data()', true, false)
),
f2 as (
  select nf.*, p.oid, p.prosecdef, p.proconfig from nf left join pg_proc p on p.oid = to_regprocedure(nf.f)
),
tg(t, tbl) as (values
  ('trg_users_role_guard', 'public.users'), ('trg_users_audit', 'public.users'),
  ('trg_uha_role_guard', 'public.user_hostel_assignments'), ('trg_user_hostel_assignments_audit', 'public.user_hostel_assignments'),
  ('trg_role_permissions_guard', 'public.role_permissions'), ('trg_role_permissions_audit', 'public.role_permissions'),
  ('trg_user_admin_log_audit', 'public.user_admin_log'), ('trg_expenses_approve_guard', 'public.expenses'),
  ('trg_students_del_role_guard', 'public.students'), ('trg_hostels_keep_data_guard', 'public.hostels'),
  ('trg_students_created_by_guard', 'public.students')
),
rp as (
  select (xpath('/row/r/text()', x))[1]::text as role_name, (xpath('/row/p/text()', x))[1]::text as perm
    from unnest(case when to_regclass('public.role_permissions') is null then array[]::xml[]
                     else xpath('/table/row', query_to_xml('select role_name as r, perm as p from public.role_permissions', false, false, '')) end) x
)
select 1 as n, '026 pehle se hai (log table, merged_into, rejoined_on)' as chk,
       to_regclass('public.ddd_dues_void_log') is not null
       and (select count(*) from information_schema.columns
             where table_schema = 'public' and table_name = 'students' and column_name in ('merged_into', 'rejoined_on')) = 2 as ok,
       '' as detail
union all
select 2, 'naya role head_manager (Manager) bana', exists (select 1 from public.roles where name = 'head_manager'), ''
union all
select 3, 'role_permissions table, RLS on, director-only CHECK',
       to_regclass('public.role_permissions') is not null
       and coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.role_permissions')), false)
       and exists (select 1 from pg_constraint where conrelid = to_regclass('public.role_permissions') and conname = 'role_permissions_director_only'),
       ''
union all
select 4, 'manage_managers, manage_directors, edit_director_login sirf Director ke paas',
       (select count(*) from rp where role_name = 'director' and perm in ('manage_managers', 'manage_directors', 'edit_director_login')) = 3
       and not exists (select 1 from rp where role_name <> 'director' and perm in ('manage_managers', 'manage_directors', 'edit_director_login')),
       coalesce((select string_agg(role_name || ':' || perm, ', ') from rp where perm in ('manage_managers', 'manage_directors', 'edit_director_login')), '')
union all
select 5, 'Manager ki powers (head_manager rows)', exists (select 1 from rp where role_name = 'head_manager' and perm = 'all_hostels'),
       coalesce((select string_agg(perm, ', ' order by perm) from rp where role_name = 'head_manager'), 'koi nahi')
union all
select 6, 'is_director + 4 warden functions = 027 wala code', count(*) = 5 and bool_and(fp = mine),
       coalesce(string_agg(f || '=' || coalesce(fp, 'nahi mila'), ', ') filter (where fp is distinct from mine), '') from f1
union all
select 7, 'naye 027 functions bane (SECURITY DEFINER aur search_path sahi)',
       bool_and(oid is not null and prosecdef = definer and coalesce(proconfig::text, '') like '%search_path=public%'),
       coalesce(string_agg(f, ', ') filter (where oid is null or prosecdef is distinct from definer
                                             or coalesce(proconfig::text, '') not like '%search_path=public%'), '') from f2
union all
select 8, 'anon koi 027 function nahi chala sakta, app sirf apne wale',
       bool_and(not coalesce(has_function_privilege('anon', oid, 'execute'), false)
                and coalesce(has_function_privilege('authenticated', oid, 'execute'), false) = app),
       coalesce(string_agg(f, ', ') filter (where coalesce(has_function_privilege('anon', oid, 'execute'), false)
                                             or coalesce(has_function_privilege('authenticated', oid, 'execute'), false) <> app), '') from f2
union all
select 9, '11 triggers lage aur chalu', count(t.oid) = 11 and coalesce(bool_and(t.tgenabled = 'O'), false),
       coalesce(string_agg(tg.t, ', ') filter (where t.oid is null or t.tgenabled <> 'O'), '')
  from tg left join pg_trigger t on t.tgname = tg.t and t.tgrelid = to_regclass(tg.tbl)
union all
select 10, 'Activity Log (audit_logs) - Director + Manager, user_admin_log rows sirf Director',
       coalesce((select qual ~ 'audit_view' and qual ~ 'user_admin_log' and qual ~ 'manage_managers'
                   from pg_policies where schemaname = 'public' and tablename = 'audit_logs' and policyname = 'audit_dir'), false)
       and (select count(*) from pg_policies where schemaname = 'public' and tablename = 'audit_logs') = 1,
       coalesce((select qual from pg_policies where schemaname = 'public' and tablename = 'audit_logs' and policyname = 'audit_dir'), '')
union all
select 11, 'user_admin_log - RLS on, sirf Director padhe, app likh nahi sakta, Edge Function sirf naya row',
       to_regclass('public.user_admin_log') is not null
       and coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.user_admin_log')), false)
       and coalesce((select bool_and(qual ~ 'manage_managers') and count(*) = 1 from pg_policies
                      where schemaname = 'public' and tablename = 'user_admin_log'), false)
       and not coalesce(has_table_privilege('anon', to_regclass('public.user_admin_log'), 'select'), true)
       and coalesce(has_table_privilege('authenticated', to_regclass('public.user_admin_log'), 'select'), false)
       and not coalesce(has_table_privilege('authenticated', to_regclass('public.user_admin_log'), 'insert,update'), true)
       and coalesce(has_table_privilege('service_role', to_regclass('public.user_admin_log'), 'select,insert'), false)
       and not coalesce(has_table_privilege('service_role', to_regclass('public.user_admin_log'), 'update'), true),
       ''
union all
select 12, 'kam se kam ek active Director', exists (select 1 from public.users u join public.roles r on r.id = u.role_id
                                                    where r.name = 'director' and u.status = 'active' and u.is_active is true),
       (select count(*) from public.users u join public.roles r on r.id = u.role_id
         where r.name = 'director' and u.status = 'active' and u.is_active is true)::text || ' active Director'
union all
select 13, 'undo ke liye backup_027 mein 5 purane functions',
       to_regclass('backup_027.fn_defs') is not null
       and (xpath('/row/n/text()', query_to_xml('select count(*) as n from backup_027.fn_defs where fp in (''986cb4bc7b7f3c5303dcb80a5cfefaf5'', ''c0419c5eb797c864e451adb5c8450fdb'', ''db5e58a2a91f362885dc9559e1c6477e'', ''709680703f8317f562db6d651ad22864'', ''589ca3be6a1cac8492f1422711cce051'')', false, true, '')))[1]::text = '5',
       ''
union all
select 14, 'SQL Editor (bina login) ko app wali power nahi', not public.ddd_can('all_hostels') and not public.is_director() and not public.is_real_director(), ''
union all
select 15, '026 ka log abhi bhi Director-level (is_director) se padha jaata hai',
       exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ddd_dues_void_log' and qual like '%is_director()%'), ''
union all
select 16, 'info: users har role mein (Manager = head_manager)', true,
       (select string_agg(coalesce(r.name, 'role nahi') || ' ' || x.c, ', ' order by r.name)
          from (select u.role_id, count(*) as c from public.users u group by u.role_id) x left join public.roles r on r.id = x.role_id)
union all
select 17, 'expenses.needs_reapproval (warden ka badla approved expense dobara approval tak warden hata nahi sakta)',
       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses'
                and column_name = 'needs_reapproval' and data_type = 'boolean' and is_nullable = 'NO'),
       coalesce((xpath('/row/n/text()', query_to_xml(case when exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'expenses' and column_name = 'needs_reapproval')
                  then 'select count(*) as n from public.expenses where needs_reapproval' else 'select 0 as n' end, false, true, '')))[1]::text, '0')
         || ' expense abhi dobara approval mein'
order by 1;
