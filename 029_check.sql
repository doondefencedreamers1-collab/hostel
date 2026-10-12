-- =====================================================================
-- 029_check.sql - 029 chalane ke BAAD (sirf padhta hai, ek hi grid).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Har row ka ok = true hona chahiye. false ho to screenshot bhejein.
-- (026_check_after.sql ki row 7 ab false aayegi - dashboard ab 029 wala hai, yeh normal hai.)
-- =====================================================================
with
fx as (
  select v.f, v.want_definer, v.want_fp, v.app, p.oid, p.prosecdef, p.proconfig,
         md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as fp
  from (values ('public.dashboard_summary(date,date,uuid)', true, 'e0e0f03021b3c96eff920a04025f194f', true),
               ('public.ddd_period_numbers(date,date,boolean,uuid[],boolean)', true, '681e7819277c005b01035753cdc5c50a', false),
               ('public.ddd_students_occupant_guard()', false, '8380cc22294411bdb9e5ab5faebe24f5', false)) v(f, want_definer, want_fp, app)
  left join pg_proc p on p.oid = to_regprocedure(v.f)
)
select 1 as n, 'students.occupant_type (text, khali nahi, default student)' as chk,
       exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'students' and column_name = 'occupant_type'
                 and data_type = 'text' and is_nullable = 'NO' and column_default like '%student%') as ok, '' as detail
union all
select 2, 'check: sirf student / staff, koi galat value nahi',
       exists (select 1 from pg_constraint where conrelid = 'public.students'::regclass and conname = 'students_occupant_type_chk'
                 and pg_get_constraintdef(oid) like '%student%' and pg_get_constraintdef(oid) like '%staff%')
       and (select count(*) from public.students where occupant_type not in ('student', 'staff')) = 0, ''
union all
select 3, 'guard trigger (staff fee 0 / billed student -> staff sirf Director / Manager) maujood + chalu',
       exists (select 1 from pg_trigger where tgrelid = 'public.students'::regclass and tgname = 'trg_students_occupant_guard' and tgenabled = 'O'
                 and pg_get_triggerdef(oid) like '%BEFORE INSERT OR UPDATE OF occupant_type, monthly_fee ON%'), ''
union all
select 4, '029 functions: text, SECURITY DEFINER / INVOKER, search_path', bool_and(fp = want_fp and prosecdef = want_definer and proconfig::text like '%search_path=public%'),
       coalesce(string_agg(f || '=' || coalesce(fp, '-'), ', ') filter (where fp is distinct from want_fp or prosecdef is distinct from want_definer
                                                                          or coalesce(proconfig::text, '') not like '%search_path=public%'), '') from fx
union all
select 5, 'rights: anon kuch nahi, app sirf dashboard_summary',
       bool_and(not coalesce(has_function_privilege('anon', oid, 'execute'), false)
                and coalesce(has_function_privilege('authenticated', oid, 'execute'), false) = app),
       coalesce(string_agg(f, ', ') filter (where has_function_privilege('anon', oid, 'execute')
                                            or coalesce(has_function_privilege('authenticated', oid, 'execute'), false) <> app), '') from fx
union all
select 6, 'Generate fee 0 ko chhodta hai (fee 0 = kabhi bill nahi)',
       coalesce((select prosrc ~ 'coalesce\(monthly_fee, 0\) > 0' from pg_proc where oid = to_regprocedure('public.generate_monthly_dues(date)')), false), ''
union all
select 7, 'info: staff (bed par, Left nahi) / unme fee 0', true,
       (select count(*) from public.students where occupant_type = 'staff' and coalesce(status, 'active') <> 'left' and merged_into is null)::text || ' / '
       || (select count(*) from public.students where occupant_type = 'staff' and coalesce(status, 'active') <> 'left' and merged_into is null
             and coalesce(monthly_fee, 0) <= 0)
union all
select 8, 'info: hostel-wise staff', true,
       coalesce((select string_agg(h.code || ' ' || x.n, ', ' order by h.code)
                   from (select hostel_id, count(*) as n from public.students
                          where occupant_type = 'staff' and coalesce(status, 'active') <> 'left' and merged_into is null group by hostel_id) x
                   join public.hostels h on h.id = x.hostel_id), '-')
order by 1;
