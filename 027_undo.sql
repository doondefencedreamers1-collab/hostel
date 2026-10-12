-- =====================================================================
-- 027_undo.sql - 027_roles_permissions.sql ko bilkul pehle jaisa karta hai
--
--  - is_director, approve_warden, reject_warden, remove_warden, pending_wardens
--    backup_027 se EXACT pehle wala live text (fingerprint check ke saath).
--  - audit_logs ki policy audit_dir wapas is_director().
--  - 027 ke triggers (users, user_hostel_assignments, role_permissions,
--    user_admin_log, expenses, students, hostels) aur naye functions hatata hai.
--  - role_permissions table hatata hai. user_admin_log mein rows hon to pehle
--    unki copy backup_027.user_admin_log mein, phir table hatata hai.
--  - expenses.needs_reapproval column hatata hai. Jo expense abhi dobara approval
--    mein the unki id backup_027.expense_reapproval mein (woh pending hi rehte hain).
--  - head_manager role tabhi hatta hai jab koi user us par na ho. Manager users
--    bache hon to unki saari power apne aap band (unka role kisi rule mein nahi).
--  - 028, 029, 030 ya 031 abhi lagi ho (027 use karti ho) to yeh RUK jaata hai.
--    Pehle unka undo ulte order mein chalayein.
-- Ek transaction. Do baar chalana safe. Pehle backup lein.
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------- PRE-CHECK ----------
do $pre$
declare
  v_bad text;
  r     record;
begin
  v_bad := (select string_agg(p.oid::regprocedure::text, ', ')
              from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.prosrc ~ '(ddd_can|is_real_director|ddd_my_role|ddd_my_perms|role_permissions|user_admin_log|ddd_is_trusted_session|ddd_user_perm_needed)'
               and p.proname not in ('is_director', 'ddd_can', 'is_real_director', 'ddd_my_role', 'ddd_my_perms', 'ddd_is_trusted_session',
                                     'ddd_user_perm_needed', 'ddd_can_manage_user', 'ddd_guard_users_role', 'ddd_guard_uha_role',
                                     'ddd_guard_role_permissions', 'ddd_guard_expense_approve', 'ddd_guard_student_del_role',
                                     'ddd_guard_hostel_keep_data', 'approve_warden', 'reject_warden', 'remove_warden', 'pending_wardens'));
  if v_bad is not null then
    raise exception '027 UNDO RUKA: yeh functions abhi bhi 027 use karte hain - %. Pehle 031, 030, 029, 028 ka undo (ulte order) chalayein. Kuch nahi badla.', v_bad;
  end if;
  v_bad := (select string_agg(p.tablename || '.' || p.policyname, ', ')
              from pg_policies p
             where p.schemaname = 'public'
               and (coalesce(p.qual, '') || coalesce(p.with_check, '')) ~ '(ddd_can|is_real_director|ddd_my_role|ddd_my_perms)'
               and not (p.tablename = 'audit_logs' and p.policyname = 'audit_dir')
               and p.tablename not in ('role_permissions', 'user_admin_log'));
  if v_bad is not null then
    raise exception '027 UNDO RUKA: yeh policies abhi bhi 027 use karti hain - %. Pehle us migration ka undo chalayein. Kuch nahi badla.', v_bad;
  end if;
  for r in select x.f, x.live, x.mine,
                  (select md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                     from pg_proc p where p.oid = to_regprocedure(x.f)) as fp
             from (values ('public.is_director()',             '986cb4bc7b7f3c5303dcb80a5cfefaf5', '6d0293244393278d7db735b56a181be4'),
                          ('public.approve_warden(uuid,uuid)', 'c0419c5eb797c864e451adb5c8450fdb', '85353bfe7d1f0bb8a8cd666b2fd6741b'),
                          ('public.reject_warden(uuid)',       'db5e58a2a91f362885dc9559e1c6477e', '72262d1ff502edf2416ae8e27fd4e402'),
                          ('public.remove_warden(uuid)',       '709680703f8317f562db6d651ad22864', '0afce424766f9bb07e71957f074e137c'),
                          ('public.pending_wardens()',         '589ca3be6a1cac8492f1422711cce051', '6ee7806c7a9c501fb77c9e7a1df2f5cc')) x(f, live, mine) loop
    if r.fp is null or r.fp not in (r.live, r.mine) then
      raise exception '027 UNDO RUKA: function % ka code anjaana hai (fingerprint %). Developer ko batayein. Kuch nahi badla.', r.f, coalesce(r.fp, 'nahi mila');
    end if;
    if r.fp = r.mine then
      if to_regclass('backup_027.fn_defs') is null then
        raise exception '027 UNDO RUKA: backup_027.fn_defs nahi mila (% ka pehle wala text). Developer ko batayein. Kuch nahi badla.', r.f;
      end if;
      if not exists (select 1 from backup_027.fn_defs b where b.fn = r.f and b.fp = r.live) then
        raise exception '027 UNDO RUKA: % ka pehle wala text backup_027 mein nahi mila. Developer ko batayein. Kuch nahi badla.', r.f;
      end if;
    end if;
  end loop;
end
$pre$;

-- ---------- 1. functions wapas (backup_027 ka exact live text) ----------
do $restore$
declare
  r record;
begin
  if to_regclass('backup_027.fn_defs') is not null then
    for r in select b.fn, b.def
               from backup_027.fn_defs b
              where (select md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                       from pg_proc p where p.oid = to_regprocedure(b.fn)) is distinct from b.fp
              order by b.fn loop
      execute r.def;
    end loop;
  end if;
  for r in select x.f, x.live,
                  (select md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                     from pg_proc p where p.oid = to_regprocedure(x.f)) as fp
             from (values ('public.is_director()', '986cb4bc7b7f3c5303dcb80a5cfefaf5'),
                          ('public.approve_warden(uuid,uuid)', 'c0419c5eb797c864e451adb5c8450fdb'),
                          ('public.reject_warden(uuid)', 'db5e58a2a91f362885dc9559e1c6477e'),
                          ('public.remove_warden(uuid)', '709680703f8317f562db6d651ad22864'),
                          ('public.pending_wardens()', '589ca3be6a1cac8492f1422711cce051')) x(f, live) loop
    if r.fp is distinct from r.live then
      raise exception '027 UNDO RUKA: % wapas pehle jaisa nahi bana (%). Kuch nahi badla.', r.f, r.fp;
    end if;
  end loop;
end
$restore$;

-- ---------- 2. Activity Log policy wapas ----------
alter policy audit_dir on public.audit_logs using (is_director());

-- ---------- 3. 027 ke triggers ----------
drop trigger if exists trg_users_role_guard on public.users;
drop trigger if exists trg_users_audit on public.users;
drop trigger if exists trg_uha_role_guard on public.user_hostel_assignments;
drop trigger if exists trg_user_hostel_assignments_audit on public.user_hostel_assignments;
drop trigger if exists trg_expenses_approve_guard on public.expenses;
drop trigger if exists trg_students_del_role_guard on public.students;
drop trigger if exists trg_students_created_by_guard on public.students;
drop trigger if exists trg_hostels_keep_data_guard on public.hostels;

-- ---------- 4. user_admin_log ki history bachao, phir tables ----------
do $log$
begin
  if to_regclass('public.user_admin_log') is not null then
    if exists (select 1 from public.user_admin_log) then
      execute 'create table if not exists backup_027.user_admin_log (like public.user_admin_log including defaults)';
      execute 'revoke all on table backup_027.user_admin_log from public, anon, authenticated';
      execute 'insert into backup_027.user_admin_log select l.* from public.user_admin_log l
                where not exists (select 1 from backup_027.user_admin_log b where b.id = l.id)';
    end if;
  end if;
end
$log$;
drop table if exists public.user_admin_log;
drop table if exists public.role_permissions;

-- dobara approval wale expenses ki list bachao, phir column
do $exp$
declare
  r record;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'expenses' and column_name = 'needs_reapproval') then
    for r in execute 'select 1 as x from public.expenses where needs_reapproval limit 1' loop
      execute 'create table if not exists backup_027.expense_reapproval (id uuid primary key, saved_at timestamptz not null default now())';
      execute 'revoke all on table backup_027.expense_reapproval from public, anon, authenticated';
      execute 'insert into backup_027.expense_reapproval (id) select e.id from public.expenses e where e.needs_reapproval on conflict (id) do nothing';
    end loop;
  end if;
end
$exp$;
alter table public.expenses drop column if exists needs_reapproval;

-- ---------- 5. 027 ke functions ----------
drop function if exists public.ddd_guard_users_role();
drop function if exists public.ddd_guard_uha_role();
drop function if exists public.ddd_guard_role_permissions();
drop function if exists public.ddd_guard_expense_approve();
drop function if exists public.ddd_guard_student_del_role();
drop function if exists public.ddd_guard_student_created_by();
drop function if exists public.ddd_guard_hostel_keep_data();
drop function if exists public.ddd_can_manage_user(uuid);
drop function if exists public.ddd_user_perm_needed(text, uuid);
drop function if exists public.ddd_my_perms();
drop function if exists public.ddd_my_role();
drop function if exists public.is_real_director();
drop function if exists public.ddd_can(text);
drop function if exists public.ddd_is_trusted_session();

-- ---------- 6. head_manager role (sirf jab koi user us par nahi) ----------
delete from public.roles r
 where r.name = 'head_manager'
   and not exists (select 1 from public.users u where u.role_id = r.id);

-- ---------- 7. backup_027 - log copy na ho to poora hatao ----------
drop table if exists backup_027.fn_defs;
do $bk$
begin
  if exists (select 1 from pg_namespace where nspname = 'backup_027')
     and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'backup_027') then
    execute 'drop schema backup_027';
  end if;
end
$bk$;

commit;

notify pgrst, 'reload schema';

-- result (sirf padhna) - sab false / 0 hona chahiye, Manager users ho to unki ginti
select (to_regclass('public.role_permissions') is not null) as role_permissions_table_hai,
       (to_regclass('public.user_admin_log') is not null) as user_admin_log_table_hai,
       (select count(*) from public.roles where name = 'head_manager') as head_manager_role_rows,
       (select count(*) from public.users u join public.roles r on r.id = u.role_id where r.name = 'head_manager') as manager_users_bina_power,
       (to_regclass('backup_027.user_admin_log') is not null) as purana_log_backup_027_mein,
       (select prosrc ~ 'all_hostels' from pg_proc where oid = 'public.is_director()'::regprocedure) as is_director_abhi_bhi_027;

-- ---------- ROLLBACK ----------
-- Is undo ko wapas lena ho (027 dobara lagani ho) to 027_roles_permissions.sql phir se chalayein.
