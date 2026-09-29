-- =====================================================================
-- 022_run_checks.sql — Supabase SQL Editor mein STEP by STEP
-- (har STEP ka block alag select karke Run). 022 koi data row nahi badalta.
-- =====================================================================

-- ---------- STEP 1: CONFIRM (read-only) ----------
-- 1a: sab true (last row = abhi ki halat, info)
select 'has 014 guards' chk, (to_regprocedure('public.ddd_guard_student_delete()') is not null and to_regprocedure('public.ddd_guard_due_delete()') is not null)::text ok
union all select 'has 017 (ddd_month_fee)', (to_regprocedure('public.ddd_month_fee(numeric,date,date)') is not null)::text
union all select 'generate_monthly_dues exists', (to_regprocedure('public.generate_monthly_dues(date)') is not null)::text
union all select '022 not run yet (anon can still run generate)', has_function_privilege('anon', 'public.generate_monthly_dues(date)', 'execute')::text
union all select 'info: handle_new_user used by a trigger?', coalesce((select exists (select 1 from pg_trigger where tgfoid = p.oid))::text, 'function absent')
  from (select to_regprocedure('public.handle_new_user()') as oid) p
union all select 'info: fee_payments FK delete rules', (select string_agg(a.attname || '=' || case con.confdeltype when 'c' then 'CASCADE' when 'a' then 'NO ACTION' when 'r' then 'RESTRICT' else con.confdeltype::text end, ', ')
  from pg_constraint con join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
  where con.contype = 'f' and con.conrelid = 'public.fee_payments'::regclass and a.attname in ('student_id', 'due_id'));

-- ---------- STEP 2: BACKUP (undo isi se chalega) ----------
create schema if not exists backup_022;
revoke all on schema backup_022 from public, anon, authenticated;
create table if not exists backup_022.meta (k text primary key, v jsonb not null, saved_at timestamptz not null default now());
insert into backup_022.meta(k, v)
select 'fn:' || p.oid::regprocedure::text, to_jsonb(pg_get_functiondef(p.oid))
from pg_proc p where p.oid in (select to_regprocedure(x) from unnest(array['public.generate_monthly_dues(date)', 'public.ddd_guard_student_delete()',
                                                                           'public.ddd_guard_due_delete()', 'public.handle_new_user()']) x)
on conflict (k) do nothing;
insert into backup_022.meta(k, v)
select 'cfg:' || p.oid::regprocedure::text, coalesce(to_jsonb(p.proconfig), 'null'::jsonb)
from pg_proc p where p.oid in (select to_regprocedure(x) from unnest(array['public.auth_role()', 'public.is_director()', 'public.is_accountant()',
                                                                           'public.my_hostels()', 'public.audit_trigger()']) x)
on conflict (k) do nothing;
insert into backup_022.meta(k, v)
select 'acl:' || p.oid::regprocedure::text,
       jsonb_build_object('public', coalesce(p.proacl::text like '%,=X/%' or p.proacl::text like '{=X/%', true),
                          'anon', has_function_privilege('anon', p.oid, 'execute'),
                          'authenticated', has_function_privilege('authenticated', p.oid, 'execute'))
from pg_proc p where p.oid in (select to_regprocedure(x) from unnest(array['public.generate_monthly_dues(date)', 'public.approve_warden(uuid,uuid)',
  'public.reject_warden(uuid)', 'public.remove_warden(uuid)', 'public.pending_wardens()', 'public.ddd_require_director()', 'public.handle_new_signup()',
  'public.audit_trigger()', 'public.ddd_pf(numeric)', 'public.ddd_setting_num(text,numeric)', 'public.hostels_for_signup()']) x)
on conflict (k) do nothing;
insert into backup_022.meta(k, v)
select 'fk:' || con.conname, jsonb_build_object('col', a.attname, 'def', pg_get_constraintdef(con.oid))
from pg_constraint con join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
where con.contype = 'f' and con.conrelid = 'public.fee_payments'::regclass and a.attname in ('student_id', 'due_id')
on conflict (k) do nothing;
insert into backup_022.meta(k, v)
select 'policies', coalesce(jsonb_agg(jsonb_build_object('table', tablename, 'name', policyname, 'permissive', permissive, 'roles', roles,
                                                         'cmd', cmd, 'qual', qual, 'check', with_check)), '[]')
from pg_policies where schemaname = 'public'
  and ((tablename = 'documents') or (tablename = 'notifications') or (tablename = 'app_settings' and policyname = 'app_settings_read')
    or (tablename = 'expense_categories' and policyname = 'ref_read') or (tablename = 'vendors' and policyname = 'vendors_read'))
on conflict (k) do nothing;
insert into backup_022.meta(k, v)
select 'anon_grants', coalesce(jsonb_agg(jsonb_build_object('t', table_schema || '.' || table_name, 'p', privilege_type)), '[]')
from information_schema.role_table_grants where grantee = 'anon' and table_schema = 'public'
on conflict (k) do nothing;
insert into backup_022.meta(k, v)
select 'anon_seq_grants', coalesce(jsonb_agg(jsonb_build_object('s', n.nspname || '.' || c.relname,
         'usage', has_sequence_privilege('anon', c.oid, 'usage'), 'select', has_sequence_privilege('anon', c.oid, 'select'),
         'update', has_sequence_privilege('anon', c.oid, 'update'))), '[]')
from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'S'
on conflict (k) do nothing;
select k, saved_at from backup_022.meta order by k;

-- ---------- STEP 3: 022_security_hotfix.sql poori file chalayein ----------

-- ---------- STEP 4: VERIFY — sab ok = true ----------
drop table if exists pg_temp.v022;
create temp table v022 (chk text, ok boolean, detail text);
do $$
declare
  t date := (now() at time zone 'Asia/Kolkata')::date;
  cur date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  u_dir uuid; u_mgr uuid; s_paid uuid; d_unpaid uuid; msg text; res text[] := '{}';
begin
  u_dir := (select u.id from users u join roles r on r.id = u.role_id where r.name = 'director' order by u.created_at limit 1);
  u_mgr := (select u.id from users u join roles r on r.id = u.role_id
            where r.name = 'manager' and exists (select 1 from user_hostel_assignments a where a.user_id = u.id) order by u.created_at limit 1);

  -- anon cannot run generate
  begin
    execute 'set local role anon';
    perform public.generate_monthly_dues(cur);
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  res := res || ('anon cannot generate dues|' || (msg <> 'RAN')::text || '|' || msg);

  -- manager: next month blocked, current month allowed (rolled back)
  if u_mgr is not null then
    perform set_config('request.jwt.claim.sub', u_mgr::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
    begin
      execute 'set local role authenticated';
      perform public.generate_monthly_dues((cur + interval '1 month')::date);
      msg := 'RAN';
    exception when others then msg := sqlerrm;
    end;
    execute 'reset role';
    res := res || ('manager cannot generate next month|' || (msg <> 'RAN')::text || '|' || msg);
    begin
      execute 'set local role authenticated';
      perform public.generate_monthly_dues(cur);
      raise exception 'OK_ROLLBACK';
    exception when others then msg := sqlerrm;
    end;
    execute 'reset role';
    res := res || ('manager can generate this month (rolled back)|' || (msg = 'OK_ROLLBACK')::text || '|' || msg);

    -- manager cannot delete an unpaid due of his hostel
    d_unpaid := (select d.id from monthly_dues d
                 where d.hostel_id in (select hostel_id from user_hostel_assignments where user_id = u_mgr)
                   and not exists (select 1 from fee_payments f where f.due_id = d.id) limit 1);
    if d_unpaid is not null then
      begin
        execute 'set local role authenticated';
        delete from monthly_dues where id = d_unpaid;
        raise exception 'OK_ROLLBACK';
      exception when others then msg := sqlerrm;
      end;
      execute 'reset role';
      res := res || ('manager cannot delete an unpaid due|' || (msg <> 'OK_ROLLBACK')::text || '|' || msg);
    end if;
  end if;

  -- director cannot delete a student who has payments
  if u_dir is not null then
    perform set_config('request.jwt.claim.sub', u_dir::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
    s_paid := (select f.student_id from fee_payments f limit 1);
    if s_paid is not null then
      begin
        execute 'set local role authenticated';
        delete from students where id = s_paid;
        raise exception 'OK_ROLLBACK';
      exception when others then msg := sqlerrm;
      end;
      execute 'reset role';
      res := res || ('director cannot delete a student with payments|' || (msg <> 'OK_ROLLBACK')::text || '|' || msg);
    end if;
  end if;

  insert into v022 select split_part(x, '|', 1), split_part(x, '|', 2)::boolean, split_part(x, '|', 3) from unnest(res) x;
end $$;
insert into v022
select 'anon has no table rights in public', count(*) = 0, count(*)::text || ' grants left' from information_schema.role_table_grants where grantee = 'anon' and table_schema = 'public'
union all select 'sign-up list still works for anon', has_function_privilege('anon', 'public.hostels_for_signup()', 'execute'), ''
  where to_regprocedure('public.hostels_for_signup()') is not null
union all select 'app (authenticated) can generate dues', has_function_privilege('authenticated', 'public.generate_monthly_dues(date)', 'execute'), ''
union all select 'search_path set on permission helpers',
  bool_and(exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')), string_agg(p.proname, ', ')
  from pg_proc p where p.oid in (select to_regprocedure(x) from unnest(array['public.auth_role()', 'public.is_director()', 'public.is_accountant()', 'public.my_hostels()', 'public.audit_trigger()']) x)
union all select 'old handle_new_user gone (or locked)', to_regprocedure('public.handle_new_user()') is null
  or not has_function_privilege('authenticated', 'public.handle_new_user()', 'execute'), ''
union all select 'fee_payments FKs are NO ACTION', bool_and(con.confdeltype = 'a'), string_agg(a.attname, ', ')
  from pg_constraint con join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
  where con.contype = 'f' and con.conrelid = 'public.fee_payments'::regclass and a.attname in ('student_id', 'due_id')
union all select 'documents Director only', not exists (select 1 from pg_policies where tablename = 'documents' and qual ilike '%auth.uid() IS NOT NULL%'), ''
union all select 'notifications check fixed', not exists (select 1 from pg_policies where tablename = 'notifications' and coalesce(with_check, '') = 'true'), ''
union all select 'ddd_pf / ddd_setting_num not callable by app',
  not has_function_privilege('authenticated', 'public.ddd_pf(numeric)', 'execute') and not has_function_privilege('authenticated', 'public.ddd_setting_num(text,numeric)', 'execute'), ''
  where to_regprocedure('public.ddd_pf(numeric)') is not null;
-- saari rows ok = true honi chahiye (false wali sabse upar dikhegi)
select * from v022 order by ok, chk;
