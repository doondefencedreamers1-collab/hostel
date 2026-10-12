-- =====================================================================
-- 027_roles_permissions.sql   (026 ke baad chalegi, Phase 5 ki pehli file)
-- DDD Hostel - naya MANAGER role + permissions (owner rules R1 se R5)
--
-- KYA KARTA HAI (owner ke liye)
--  1. Naya role head_manager. App mein iska naam "Manager" hoga.
--     Purana role manager = Warden hi rehta hai (sirf app ka label badlega).
--  2. Nayi table role_permissions = kis role ke paas kaun si power.
--     Director = sab. Manager = Director ki saari power, sirf yeh 3 NAHI
--       manage_managers      (Manager banana, badalna, band karna, hatana, password)
--       manage_directors     (Director ka account)
--       edit_director_login  (Director ka login)
--     Yeh 3 power database ke CHECK se sirf director role ko hi mil sakti hai.
--  3. is_director() ab Director AUR active Manager dono ke liye haan kehta hai.
--     Isse Manager ko Salary, Activity Log, sab hostels, fees waghera turant
--     milte hain (R3). Band (inactive / removed) Manager ki power turant khatam.
--     Naye functions - is_real_director() sirf asli Director, ddd_can(power),
--     ddd_my_role(), ddd_my_perms().
--  4. Warden approve / reject / remove / pending list - Director aur Manager (R2).
--     Director ya Manager ke account par yeh kabhi nahi chalte (M1).
--  5. users table (R1, R4)
--     - Manager aur Warden apna naam, mobile, email, role, status nahi badal sakte.
--     - Kisi ka bhi naam, mobile, email sirf Director badalta hai.
--     - Director, Manager aur Accountant ke account sirf Director (ya Edge
--       Function admin-users) badal sakta hai. Manager ko yeh role koi nahi de sakta
--       sivaay Director ke.
--  6. Nayi table user_admin_log = Edge Function admin-users ka log (kisne, kab, kya).
--     Sirf Director padh sakta hai. Activity Log (audit_logs) mein bhi Manager
--     ko yeh rows nahi dikhti (M2).
--  7. Expenses (R5) - approve / reject sirf Director ya Manager. Warden approved
--     expense badle to woh apne aap wapas pending ho jaata hai (aur naya column
--     needs_reapproval = haan, jab tak Director / Manager dobara approve / reject
--     na kare, warden use hata bhi nahi sakta). approved_by, added_by, created_by,
--     created_at database khud bharta hai (L3). Approved expense
--     warden hata nahi sakta.
--  8. Student ka seedha delete sirf Director / Manager. Warden = Mark as Left.
--     Student ka created_by (Banaya) app se database khud bharta hai, badalta nahi.
--  9. Hostel tab tak delete nahi hota jab tak usme students, bills,
--     payments, expenses, staff ya salary record hain (DATA-1) - kisi ke liye bhi,
--     SQL Editor ke liye bhi.
-- 10. users, user_hostel_assignments, role_permissions, user_admin_log par
--     audit trigger (kisne kab kya badla, Activity Log mein dikhega).
--
-- KAISE CHALAYEIN
--  - Pehle Supabase backup lein. Class time ke bahar chalayein.
--  - Poori file SQL Editor mein paste karke ek baar Run. Do baar chalana safe hai.
--  - Pre-check fail ho to kuch nahi badalta, Hinglish message aata hai.
--  - Baad mein 027_check.sql chalayein (har row ok = true).
--  - Wapas lena ho to 027_undo.sql (exact purana).
--  - Is file se koi purani data row nahi badalti (sirf roles mein ek nayi row).
--  - Manager user naya app live hone ke BAAD hi banayein (Edge Function se).
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------------------------------------------------------------------
-- STEP 1. PRE-CHECK (kuch bhi anjaana = yahin ruk jao, kuch nahi badla)
-- ---------------------------------------------------------------------
do $pre$
declare
  v_def  text;
  v_miss text;
  n      int;
  r      record;
begin
  -- 026 pehle chahiye (log table, merged_into, rejoined_on, exit trigger)
  if to_regclass('public.ddd_dues_void_log') is null
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'students' and column_name in ('merged_into', 'rejoined_on')) <> 2
     or to_regprocedure('public.ddd_exit_bills_sync(uuid,text)') is null then
    raise exception '027 RUKA: 026 (billing exit rules) is database mein nahi mili. Pehle 026 chalayein. Kuch nahi badla.';
  end if;

  -- tables
  v_miss := (select string_agg(t, ', ') from unnest(array['users', 'roles', 'user_hostel_assignments', 'audit_logs', 'hostels',
                                                          'students', 'monthly_dues', 'fee_payments', 'expenses',
                                                          'employees', 'salary_payments', 'salary_runs']) t
              where to_regclass('public.' || t) is null);
  if v_miss is not null then
    raise exception '027 RUKA: table nahi mili - %. Sahi Supabase project khula hai? Kuch nahi badla.', v_miss;
  end if;
  v_miss := (select string_agg(x.tbl || '.' || x.col, ', ')
               from (values ('users', 'id'), ('users', 'full_name'), ('users', 'email'), ('users', 'phone'), ('users', 'role_id'),
                            ('users', 'status'), ('users', 'is_active'), ('users', 'requested_hostel_id'), ('users', 'created_by'),
                            ('roles', 'name'), ('roles', 'description'),
                            ('user_hostel_assignments', 'user_id'), ('user_hostel_assignments', 'hostel_id'),
                            ('audit_logs', 'entity_type'), ('audit_logs', 'user_id'),
                            ('expenses', 'status'), ('expenses', 'approved_by'), ('expenses', 'added_by'), ('expenses', 'created_by'),
                            ('hostels', 'code'), ('monthly_dues', 'hostel_id'), ('fee_payments', 'hostel_id'),
                            ('expenses', 'hostel_id'), ('expenses', 'created_at'), ('students', 'created_by'),
                            ('employees', 'hostel_id'), ('salary_payments', 'hostel_id'), ('salary_runs', 'hostel_id')) x(tbl, col)
              where not exists (select 1 from information_schema.columns c
                                 where c.table_schema = 'public' and c.table_name = x.tbl and c.column_name = x.col));
  if v_miss is not null then
    raise exception '027 RUKA: columns nahi mile - %. Developer ko batayein. Kuch nahi badla.', v_miss;
  end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.users'::regclass and attname = 'role_id' and attnotnull) then
    raise exception '027 RUKA: users.role_id NOT NULL hai (remove ka tareeka alag chahiye). Developer ko batayein. Kuch nahi badla.';
  end if;
  for r in select pg_get_constraintdef(c.oid) as d from pg_constraint c
            where c.conrelid = 'public.users'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%status%' loop
    if r.d not ilike '%inactive%' or r.d not ilike '%removed%' then
      raise exception '027 RUKA: users.status par CHECK (%) inactive / removed nahi maanta. Developer ko batayein. Kuch nahi badla.', r.d;
    end if;
  end loop;
  if not exists (select 1 from pg_constraint c
                  where c.conrelid = 'public.roles'::regclass and c.contype in ('u', 'p')
                    and c.conkey = array[(select attnum from pg_attribute where attrelid = 'public.roles'::regclass and attname = 'name')]) then
    raise exception '027 RUKA: roles.name par unique nahi hai. Kuch nahi badla.';
  end if;
  if not exists (select 1 from public.roles where name = 'director') or not exists (select 1 from public.roles where name = 'manager') then
    raise exception '027 RUKA: roles mein director / manager nahi mila. Kuch nahi badla.';
  end if;
  v_miss := (select string_agg(f, ', ') from unnest(array['public.audit_trigger()', 'public.ddd_is_api_caller()', 'public.auth_role()',
                                                          'public.my_hostels()', 'public.is_accountant()', 'public.is_director()']) f
              where to_regprocedure(f) is null);
  if v_miss is not null then
    raise exception '027 RUKA: function nahi mila - %. Kuch nahi badla.', v_miss;
  end if;

  -- kam se kam ek ACTIVE Director (is_director ab status aur is_active bhi dekhega)
  n := (select count(*) from public.users u join public.roles ro on ro.id = u.role_id
         where ro.name = 'director' and u.status = 'active' and u.is_active is true);
  if n = 0 then
    raise exception '027 RUKA: koi Director status active aur is_active true nahi hai. Pehle Director ka users row theek karein. Kuch nahi badla.';
  end if;

  -- functions jo yeh file badalti hai - live (026 ke baad) wale hi hon, ya pehle se 027 wale
  for r in select x.f, x.live, x.mine,
                  (select md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                     from pg_proc p where p.oid = to_regprocedure(x.f)) as fp
             from (values ('public.is_director()',               '986cb4bc7b7f3c5303dcb80a5cfefaf5', '6d0293244393278d7db735b56a181be4'),
                          ('public.approve_warden(uuid,uuid)',   'c0419c5eb797c864e451adb5c8450fdb', '85353bfe7d1f0bb8a8cd666b2fd6741b'),
                          ('public.reject_warden(uuid)',         'db5e58a2a91f362885dc9559e1c6477e', '72262d1ff502edf2416ae8e27fd4e402'),
                          ('public.remove_warden(uuid)',         '709680703f8317f562db6d651ad22864', '0afce424766f9bb07e71957f074e137c'),
                          ('public.pending_wardens()',           '589ca3be6a1cac8492f1422711cce051', '6ee7806c7a9c501fb77c9e7a1df2f5cc')) x(f, live, mine) loop
    if r.fp is null then
      raise exception '027 RUKA: function % nahi mila. Live database alag hai, developer ko batayein. Kuch nahi badla.', r.f;
    end if;
    if r.fp not in (r.live, r.mine) then
      raise exception '027 RUKA: function % ka live code anjaana hai (fingerprint %). Developer ko batayein. Kuch nahi badla.', r.f, r.fp;
    end if;
    if r.fp = r.mine and not exists (select 1 from pg_namespace where nspname = 'backup_027') then
      raise exception '027 RUKA: % pehle se 027 wala hai par backup_027 nahi mila (undo ke liye zaroori). Developer ko batayein. Kuch nahi badla.', r.f;
    end if;
  end loop;
  if (select pg_get_function_result(to_regprocedure('public.pending_wardens()'))) is distinct from 'jsonb' then
    raise exception '027 RUKA: pending_wardens jsonb nahi deta. Developer ko batayein. Kuch nahi badla.';
  end if;

  -- Activity Log ki read policy - sirf audit_dir hi ho aur live jaisi (ya pehle se 027 wali)
  v_def := (select qual from pg_policies where schemaname = 'public' and tablename = 'audit_logs' and policyname = 'audit_dir');
  if v_def is null or (v_def <> 'is_director()' and v_def !~ 'audit_view') then
    raise exception '027 RUKA: audit_logs ki policy audit_dir anjaani hai (%). Developer ko batayein. Kuch nahi badla.', coalesce(v_def, 'nahi mili');
  end if;
  if (select count(*) from pg_policies where schemaname = 'public' and tablename = 'audit_logs') <> 1 then
    raise exception '027 RUKA: audit_logs par ek se zyada policy hai. Developer ko batayein. Kuch nahi badla.';
  end if;

  -- pehle se bani tables (doosri baar chal rahi ho) ka shape
  if to_regclass('public.role_permissions') is not null
     and (select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'role_permissions' and column_name in ('id', 'role_name', 'perm')) <> 3 then
    raise exception '027 RUKA: public.role_permissions pehle se hai par columns alag hain. Developer ko batayein. Kuch nahi badla.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses'
                and column_name = 'needs_reapproval' and (data_type <> 'boolean' or is_nullable <> 'NO')) then
    raise exception '027 RUKA: expenses.needs_reapproval pehle se hai par alag tarah ka. Developer ko batayein. Kuch nahi badla.';
  end if;
  if to_regclass('public.user_admin_log') is not null
     and (select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'user_admin_log'
             and column_name in ('id', 'created_at', 'actor_id', 'actor_name', 'actor_role', 'action', 'target_user_id', 'target_name',
                                 'target_login', 'ok', 'http_status', 'error', 'details', 'ip', 'user_agent')) <> 15 then
    raise exception '027 RUKA: public.user_admin_log pehle se hai par columns alag hain. Developer ko batayein. Kuch nahi badla.';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------
-- STEP 2. backup - jo functions badlenge unka live text (sirf pehli baar, undo isi se)
-- ---------------------------------------------------------------------
create schema if not exists backup_027;
revoke all on schema backup_027 from public, anon, authenticated;
create table if not exists backup_027.fn_defs (
  fn       text primary key,
  def      text not null,
  fp       text not null,
  saved_at timestamptz not null default now()
);
revoke all on table backup_027.fn_defs from public, anon, authenticated;
insert into backup_027.fn_defs (fn, def, fp)
select x.f, pg_get_functiondef(to_regprocedure(x.f)),
       md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
  from (values ('public.is_director()', '986cb4bc7b7f3c5303dcb80a5cfefaf5'),
               ('public.approve_warden(uuid,uuid)', 'c0419c5eb797c864e451adb5c8450fdb'),
               ('public.reject_warden(uuid)', 'db5e58a2a91f362885dc9559e1c6477e'),
               ('public.remove_warden(uuid)', '709680703f8317f562db6d651ad22864'),
               ('public.pending_wardens()', '589ca3be6a1cac8492f1422711cce051')) x(f, live)
  join pg_proc p on p.oid = to_regprocedure(x.f)
 where md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) = x.live
on conflict (fn) do nothing;
do $bk$
begin
  if (select count(*) from backup_027.fn_defs) <> 5 then
    raise exception '027 RUKA: 5 functions ka backup nahi bana. Developer ko batayein. Kuch nahi badla.';
  end if;
end
$bk$;

-- ---------------------------------------------------------------------
-- STEP 3. naya role + role_permissions + user_admin_log
-- ---------------------------------------------------------------------
insert into public.roles (name, description)
values ('head_manager', 'Manager (app label). Director jaisi saari powers, sirf Manager / Director accounts nahi.')
on conflict (name) do nothing;

-- role_permissions - pehli baar hi bani to Manager ke rows (doosri baar chalane par
-- Director ki band ki hui power wapas nahi aati)
do $tbl$
begin
  if to_regclass('public.role_permissions') is null then
    create table public.role_permissions (
      role_name  text not null references public.roles(name) on update cascade on delete cascade,
      perm       text not null,
      id         uuid not null default gen_random_uuid() unique,
      note       text,
      created_at timestamptz not null default now(),
      created_by uuid default auth.uid(),
      constraint role_permissions_pkey primary key (role_name, perm),
      constraint role_permissions_perm_format check (perm ~ '^[a-z][a-z_]{1,40}$'),
      constraint role_permissions_director_only
        check (perm not in ('manage_managers', 'manage_directors', 'edit_director_login') or role_name = 'director')
    );
    insert into public.role_permissions (role_name, perm, note)
    select 'head_manager', p, '027 seed'
      from unnest(array['all_hostels', 'audit_view', 'expense_approve', 'student_delete', 'warden_manage', 'duplicate_delete']) p;
  end if;
end
$tbl$;
insert into public.role_permissions (role_name, perm, note)
select 'director', p, '027 seed'
  from unnest(array['all_hostels', 'audit_view', 'expense_approve', 'student_delete', 'warden_manage', 'duplicate_delete',
                    'manage_managers', 'manage_directors', 'edit_director_login']) p
on conflict (role_name, perm) do nothing;
comment on table public.role_permissions is
  '027: kis role ke paas kaun si power. ddd_can(perm) isi se. Director ke liye ddd_can hamesha true. head_manager ka row hatao = Manager se woh power band. Jo perm is table mein kahin nahi hai woh Director-level maani jaati hai (Director + all_hostels wala role).';

create table if not exists public.user_admin_log (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  actor_id       uuid,
  actor_name     text,
  actor_role     text,
  action         text not null check (length(action) between 1 and 40),
  target_user_id uuid,
  target_name    text,
  target_login   text,
  ok             boolean not null default true,
  http_status    int check (http_status is null or http_status between 100 and 599),
  error          text,
  details        jsonb not null default '{}'::jsonb,
  ip             text,
  user_agent     text
);
create index if not exists user_admin_log_created_idx on public.user_admin_log (created_at desc);
create index if not exists user_admin_log_target_idx on public.user_admin_log (target_user_id, created_at desc);
comment on table public.user_admin_log is
  '027: Manager accounts ka log (Edge Function admin-users). Sirf Director padh sakta hai. Password kabhi save nahi hota.';

-- R5: warden ne approved expense badla = pending + needs_reapproval (Director / Manager ke approve / reject tak warden hata nahi sakta)
alter table public.expenses add column if not exists needs_reapproval boolean not null default false;
comment on column public.expenses.needs_reapproval is
  '027: haan = approved expense warden ne badla, ab dobara approval chahiye. Tab tak sirf Director / Manager hata sakte hain. Approve / reject par khud khali.';

-- ---------------------------------------------------------------------
-- STEP 4. permission functions
-- ---------------------------------------------------------------------
-- trusted = SQL Editor / migration / service key (Edge Function). App ka phone kabhi nahi.
create or replace function public.ddd_is_trusted_session() returns boolean
language sql stable set search_path = public as $$
  select (auth.uid() is null and session_user not in ('authenticator', 'supabase_auth_admin', 'anon', 'authenticated'))
      or coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                  (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'), '') = 'service_role';
$$;

-- login user active hai aur uske role ke paas yeh power hai?
-- Director = hamesha haan. Jo power table mein kahin nahi likhi = Director-level (all_hostels wala role).
create or replace function public.ddd_can(p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.users u
    join public.roles r on r.id = u.role_id
    where u.id = auth.uid()
      and u.status = 'active'
      and u.is_active is true
      and (r.name = 'director'
           or exists (select 1 from public.role_permissions rp where rp.role_name = r.name and rp.perm = p_perm)
           or (not exists (select 1 from public.role_permissions k where k.perm = p_perm)
               and exists (select 1 from public.role_permissions a where a.role_name = r.name and a.perm = 'all_hostels')))
  );
$$;

create or replace function public.is_real_director() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.users u
    join public.roles r on r.id = u.role_id
    where u.id = auth.uid()
      and u.status = 'active'
      and u.is_active is true
      and r.name = 'director'
  );
$$;

-- login user ka role (sirf active user ka, band / removed / pending = khali)
create or replace function public.ddd_my_role() returns text
language sql stable security definer set search_path = public as $$
  select r.name from public.users u join public.roles r on r.id = u.role_id
   where u.id = auth.uid() and u.status = 'active' and u.is_active is true;
$$;

create or replace function public.ddd_my_perms() returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct rp.perm order by rp.perm), '{}'::text[])
  from public.users u
  join public.roles r on r.id = u.role_id
  join public.role_permissions rp on rp.role_name = r.name or r.name = 'director'
  where u.id = auth.uid()
    and u.status = 'active'
    and u.is_active is true;
$$;

-- kisi user row ko badalne ke liye kaun si power chahiye
--   director = manage_directors, head_manager / accountant = manage_managers (L2),
--   Director ne jise Manager se hataya tha = manage_managers, baaki (warden, pending) = warden_manage
create or replace function public.ddd_user_perm_needed(p_role text, p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when p_role = 'director' then 'manage_directors'
    when p_role in ('head_manager', 'accountant') then 'manage_managers'
    when p_user is not null and exists (select 1 from public.user_admin_log l
                                         where l.target_user_id = p_user and l.action = 'remove_manager' and l.ok) then 'manage_managers'
    else 'warden_manage'
  end;
$$;

create or replace function public.ddd_can_manage_user(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.ddd_can(public.ddd_user_perm_needed(
           (select r.name from public.users u left join public.roles r on r.id = u.role_id where u.id = p_user), p_user));
$$;

-- ---------------------------------------------------------------------
-- STEP 5. is_director() = Director + active Manager (all_hostels)
--         ek hi query mein likha hai (RLS mein har row par chalta hai, tez rehna chahiye)
-- ---------------------------------------------------------------------
create or replace function public.is_director() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1
    from public.users u
    join public.roles r on r.id = u.role_id
    where u.id = auth.uid()
      and u.status = 'active'
      and u.is_active is true
      and (r.name = 'director'
           or exists (select 1 from public.role_permissions rp where rp.role_name = r.name and rp.perm = 'all_hostels'))
  );
$$;

-- ---------------------------------------------------------------------
-- STEP 6. guard triggers (har raste par, SECURITY DEFINER functions ke andar bhi)
-- ---------------------------------------------------------------------
create or replace function public.ddd_guard_users_role() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_old  text;
  v_new  text;
  v_real boolean;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_old := (select r.name from public.roles r where r.id = old.role_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    v_new := (select r.name from public.roles r where r.id = new.role_id);
  end if;
  if public.ddd_is_trusted_session() then
    return coalesce(new, old);
  end if;

  if v_uid is null then
    -- bina login - Supabase Auth (sign-up trigger, user hatana) ya anon key
    if session_user = 'supabase_auth_admin' then
      if tg_op = 'DELETE' then
        return old;
      end if;
      if tg_op = 'UPDATE' and new.role_id is not distinct from old.role_id
         and new.status is not distinct from old.status and new.is_active is not distinct from old.is_active then
        return new;
      end if;
    end if;
    if coalesce(v_old, '-') in ('director', 'head_manager', 'accountant')
       or coalesce(v_new, '-') in ('director', 'head_manager', 'accountant') then
      raise exception 'Director / Manager / Accountant role sirf Director de sakta hai (sign-up se nahi milta)' using errcode = '42501';
    end if;
    return coalesce(new, old);
  end if;

  v_real := public.is_real_director();

  -- apna khud ka row
  if tg_op = 'UPDATE' and old.id = v_uid then
    if new.id is distinct from old.id or new.role_id is distinct from old.role_id
       or new.status is distinct from old.status or new.is_active is distinct from old.is_active then
      raise exception 'Apna khud ka role / status / active nahi badal sakte' using errcode = '42501';
    end if;
    if not v_real and (new.full_name, new.phone, new.email, new.requested_hostel_id, new.created_by)
                      is distinct from (old.full_name, old.phone, old.email, old.requested_hostel_id, old.created_by) then
      raise exception 'Apna naam / mobile / email sirf Director badal sakta hai' using errcode = '42501';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' and old.id = v_uid then
    raise exception 'Apna khud ka account delete nahi kar sakte' using errcode = '42501';
  end if;

  -- doosre ka row - purane aur naye role dono ki power chahiye
  if tg_op in ('UPDATE', 'DELETE') and not public.ddd_can(public.ddd_user_perm_needed(v_old, old.id)) then
    raise exception '%', case coalesce(v_old, '-')
        when 'director'     then 'Director ka account sirf Director badal sakta hai'
        when 'head_manager' then 'Manager ka account sirf Director badal / hata sakta hai'
        when 'accountant'   then 'Accountant ka account sirf Director badal sakta hai'
        else 'Aapko is user ko badalne ki permission nahi hai' end
      using errcode = '42501';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and not public.ddd_can(public.ddd_user_perm_needed(v_new, null)) then
    raise exception '%', case coalesce(v_new, '-')
        when 'director'     then 'Director role sirf Director de sakta hai'
        when 'head_manager' then 'Manager role sirf Director de sakta hai'
        when 'accountant'   then 'Accountant role sirf Director de sakta hai'
        else 'Aapko users manage karne ki permission nahi hai' end
      using errcode = '42501';
  end if;
  -- naam / mobile / email kisi ka bhi - sirf asli Director (R4)
  if tg_op = 'UPDATE' and not v_real
     and (new.full_name, new.phone, new.email) is distinct from (old.full_name, old.phone, old.email) then
    raise exception 'Kisi ka naam / mobile / email sirf Director badal sakta hai' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and v_old = 'director' and new.email is distinct from old.email
     and not public.ddd_can('edit_director_login') then
    raise exception 'Director ka login sirf Director badal sakta hai' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

create or replace function public.ddd_guard_uha_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.ddd_is_trusted_session() then
    return coalesce(new, old);
  end if;
  if auth.uid() is null then
    if tg_op = 'DELETE' and session_user = 'supabase_auth_admin' then
      return old;
    end if;
    raise exception 'Login zaroori hai' using errcode = '42501';
  end if;
  if tg_op in ('UPDATE', 'DELETE') and not public.ddd_can_manage_user(old.user_id) then
    raise exception 'Is user ka hostel sirf Director badal sakta hai' using errcode = '42501';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and not public.ddd_can_manage_user(new.user_id) then
    raise exception 'Is user ka hostel sirf Director badal sakta hai' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

create or replace function public.ddd_guard_role_permissions() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.ddd_is_trusted_session() then
    return coalesce(new, old);
  end if;
  if auth.uid() is null or not public.ddd_can('manage_directors') then
    raise exception 'Permissions sirf Director badal sakta hai' using errcode = '42501';
  end if;
  if (tg_op in ('UPDATE', 'DELETE') and old.role_name = 'director')
     or (tg_op in ('INSERT', 'UPDATE') and new.role_name = 'director') then
    raise exception 'Director ki apni permissions app se nahi badalti. SQL Editor se badlein.' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

-- expenses (R5, M4, AUTH-2, L3). SECURITY DEFINER nahi - ddd_is_api_caller ko app ka role dikhna chahiye.
-- SQL Editor aur owner wale functions (jaise common expense) par asar nahi.
-- needs_reapproval - warden ka badla hua approved expense (pending), dobara approve / reject tak warden hata nahi sakta.
-- created_at app se kabhi nahi badalta (naya = abhi ka time).
create or replace function public.ddd_guard_expense_approve() returns trigger
language plpgsql set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_appr boolean;
begin
  if not public.ddd_is_api_caller() then
    return coalesce(new, old);
  end if;
  v_appr := public.ddd_can('expense_approve');
  if tg_op = 'DELETE' then
    if old.status = 'approved' and not v_appr then
      raise exception 'Approved expense sirf Director ya Manager hata sakte hain' using errcode = '42501';
    end if;
    if old.needs_reapproval and not v_appr then
      raise exception 'Yeh expense pehle approved tha aur ab dobara approval mein hai - ise sirf Director ya Manager hata sakte hain' using errcode = '42501';
    end if;
    return old;
  end if;
  if tg_op = 'INSERT' then
    new.added_by := coalesce(v_uid, new.added_by);
    new.created_by := coalesce(v_uid, new.created_by);
    new.created_at := now();
    new.needs_reapproval := false;
    if coalesce(new.status, 'pending') <> 'pending' and not v_appr then
      raise exception 'Expense approve / reject sirf Director ya Manager kar sakte hain' using errcode = '42501';
    end if;
    new.approved_by := case when new.status in ('approved', 'rejected') then v_uid end;
    return new;
  end if;
  -- UPDATE
  new.added_by := old.added_by;
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  new.needs_reapproval := old.needs_reapproval;
  if new.status is distinct from old.status then
    if not v_appr then
      raise exception 'Expense approve / reject sirf Director ya Manager kar sakte hain' using errcode = '42501';
    end if;
    new.approved_by := case when new.status in ('approved', 'rejected') then v_uid end;
    new.needs_reapproval := false;
  elsif not v_appr and old.status = 'approved'
        and (to_jsonb(new) - array['status', 'approved_by', 'added_by', 'created_by', 'created_at', 'updated_at', 'needs_reapproval'])
            is distinct from (to_jsonb(old) - array['status', 'approved_by', 'added_by', 'created_by', 'created_at', 'updated_at', 'needs_reapproval']) then
    -- warden ne approved expense badla = dobara Director / Manager ke approval ke liye
    new.status := 'pending';
    new.approved_by := null;
    new.needs_reapproval := true;
  else
    new.approved_by := old.approved_by;
  end if;
  return new;
end $$;

-- students.created_by (L3) - app se naya student = login user. Baad mein app se kabhi nahi badalta
-- (Delete Duplicate screen par Banaya sahi dikhe). SQL Editor aur owner functions par asar nahi.
create or replace function public.ddd_guard_student_created_by() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.ddd_is_api_caller() then
    if tg_op = 'INSERT' then
      new.created_by := coalesce(auth.uid(), new.created_by);
    else
      new.created_by := old.created_by;
    end if;
  end if;
  return new;
end $$;

-- student ka seedha delete sirf Director / Manager (Phase 3). SQL Editor aur owner functions par asar nahi.
create or replace function public.ddd_guard_student_del_role() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.ddd_is_api_caller() and not public.ddd_can('student_delete') then
    raise exception 'Student delete sirf Director ya Manager kar sakte hain. Student chala gaya ho to Status = Left (Mark as Left) karein.'
      using errcode = '42501';
  end if;
  return old;
end $$;

-- hostel delete (DATA-1) - students, bills, payments, expenses, staff ya salary record hon to kisi ke liye nahi
create or replace function public.ddd_guard_hostel_keep_data() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n_s bigint;
  n_d bigint;
  n_p bigint;
  n_e bigint;
  n_m bigint;
  n_sal bigint;
begin
  n_s := (select count(*) from public.students s where s.hostel_id = old.id);
  n_d := (select count(*) from public.monthly_dues d where d.hostel_id = old.id);
  n_p := (select count(*) from public.fee_payments f where f.hostel_id = old.id);
  n_e := (select count(*) from public.expenses e where e.hostel_id = old.id);
  n_m := (select count(*) from public.employees m where m.hostel_id = old.id);
  n_sal := (select count(*) from public.salary_payments x where x.hostel_id = old.id)
         + (select count(*) from public.salary_runs x where x.hostel_id = old.id);
  if n_s + n_d + n_p + n_e + n_m + n_sal > 0 then
    raise exception 'Hostel % hataya nahi ja sakta - isme % students, % bills, % payments, % expenses, % staff, % salary record hain. Hostel band karna ho to uska Status inactive karein, data safe rahega.',
      coalesce(nullif(old.code, ''), old.name), n_s, n_d, n_p, n_e, n_m, n_sal using errcode = '42501';
  end if;
  return old;
end $$;

drop trigger if exists trg_users_role_guard on public.users;
create trigger trg_users_role_guard before insert or update or delete on public.users
  for each row execute function public.ddd_guard_users_role();
drop trigger if exists trg_uha_role_guard on public.user_hostel_assignments;
create trigger trg_uha_role_guard before insert or update or delete on public.user_hostel_assignments
  for each row execute function public.ddd_guard_uha_role();
drop trigger if exists trg_role_permissions_guard on public.role_permissions;
create trigger trg_role_permissions_guard before insert or update or delete on public.role_permissions
  for each row execute function public.ddd_guard_role_permissions();
drop trigger if exists trg_expenses_approve_guard on public.expenses;
create trigger trg_expenses_approve_guard before insert or update or delete on public.expenses
  for each row execute function public.ddd_guard_expense_approve();
drop trigger if exists trg_students_del_role_guard on public.students;
create trigger trg_students_del_role_guard before delete on public.students
  for each row execute function public.ddd_guard_student_del_role();
drop trigger if exists trg_students_created_by_guard on public.students;
create trigger trg_students_created_by_guard before insert or update of created_by on public.students
  for each row execute function public.ddd_guard_student_created_by();
drop trigger if exists trg_hostels_keep_data_guard on public.hostels;
create trigger trg_hostels_keep_data_guard before delete on public.hostels
  for each row execute function public.ddd_guard_hostel_keep_data();

-- ---------------------------------------------------------------------
-- STEP 7. warden functions (live text + 2 badlav)
--         a) Director ki jagah ddd_can(warden_manage) = Director aur Manager (M1)
--         b) Director / Manager ke account par kabhi nahi
-- ---------------------------------------------------------------------
create or replace function public.approve_warden(p_user_id uuid, p_hostel_id uuid default null::uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_role uuid; v_hostel uuid; v_target text;
begin
  if not public.ddd_can('warden_manage') then
    raise exception 'Warden approve sirf Director ya Manager kar sakte hain' using errcode = '42501';
  end if;
  v_target := (select r.name from public.users u join public.roles r on r.id = u.role_id where u.id = p_user_id);
  if v_target in ('director', 'head_manager') then
    raise exception 'Director / Manager ka account yahan se nahi badla ja sakta' using errcode = '42501';
  end if;
  v_role := (select id from public.roles
              where name in ('warden','manager')
              order by case when name='warden' then 0 else 1 end limit 1);
  v_hostel := (select coalesce(p_hostel_id, requested_hostel_id) from public.users where id=p_user_id);
  update public.users set role_id=v_role, status='active' where id=p_user_id;
  if v_hostel is not null and not exists (
       select 1 from public.user_hostel_assignments
        where user_id=p_user_id and hostel_id=v_hostel) then
    insert into public.user_hostel_assignments(user_id,hostel_id) values (p_user_id, v_hostel);
  end if;
end; $function$;

create or replace function public.reject_warden(p_user_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_target text;
begin
  if not public.ddd_can('warden_manage') then
    raise exception 'Warden reject sirf Director ya Manager kar sakte hain' using errcode = '42501';
  end if;
  v_target := (select r.name from public.users u join public.roles r on r.id = u.role_id where u.id = p_user_id);
  if v_target in ('director', 'head_manager') then
    raise exception 'Director / Manager ka account yahan se nahi badla ja sakta' using errcode = '42501';
  end if;
  update public.users set status='rejected' where id=p_user_id;
end; $function$;

create or replace function public.remove_warden(p_user_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_target text;
begin
  if not public.ddd_can('warden_manage') then
    raise exception 'Warden remove sirf Director ya Manager kar sakte hain' using errcode = '42501';
  end if;
  v_target := (select r.name from public.users u join public.roles r on r.id = u.role_id where u.id = p_user_id);
  if v_target in ('director', 'head_manager') then
    raise exception 'Director / Manager ka account yahan se nahi hataya ja sakta' using errcode = '42501';
  end if;
  -- access band karo (user row rehti hai, uska data safe)
  update public.users
     set status  = 'removed',
         role_id = null
   where id = p_user_id;
  -- hostel access hatao, RLS se use kuch nahi milega
  delete from public.user_hostel_assignments
   where user_id = p_user_id;
end;
$function$;

create or replace function public.pending_wardens()
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
begin
  if not public.ddd_can('warden_manage') then
    raise exception 'Pending wardens sirf Director ya Manager dekh sakte hain' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(row_to_json(x)), '[]'::jsonb)
    from (
      select u.id, u.email, u.full_name,
             u.requested_hostel_id, h.name as hostel_name, u.created_at
      from public.users u
      left join public.hostels h on h.id = u.requested_hostel_id
      where u.status = 'pending'
      order by u.created_at desc
    ) x);
end;
$function$;

-- ---------------------------------------------------------------------
-- STEP 8. policies (RLS)
-- ---------------------------------------------------------------------
alter table public.role_permissions enable row level security;
drop policy if exists role_permissions_read on public.role_permissions;
create policy role_permissions_read on public.role_permissions for select to authenticated
  using ((select public.auth_role()) is not null);
drop policy if exists role_permissions_write on public.role_permissions;
create policy role_permissions_write on public.role_permissions for all to authenticated
  using ((select public.ddd_can('manage_directors'))) with check ((select public.ddd_can('manage_directors')));

alter table public.user_admin_log enable row level security;
drop policy if exists user_admin_log_dir_read on public.user_admin_log;
create policy user_admin_log_dir_read on public.user_admin_log for select to authenticated
  using ((select public.ddd_can('manage_managers')));

-- Activity Log - audit_view wale (Director + Manager), user_admin_log ki copy sirf Director (M2)
alter policy audit_dir on public.audit_logs
  using ((select public.ddd_can('audit_view'))
         and (entity_type is distinct from 'user_admin_log' or (select public.ddd_can('manage_managers'))));

-- ---------------------------------------------------------------------
-- STEP 9. rights (Supabase naye table / function anon ko bhi de deta hai, wapas lo)
-- ---------------------------------------------------------------------
revoke all on table public.role_permissions from public, anon, authenticated;
grant select, insert, update, delete on table public.role_permissions to authenticated;
revoke all on table public.user_admin_log from public, anon, authenticated, service_role;
grant select on table public.user_admin_log to authenticated;
grant select, insert on table public.user_admin_log to service_role;

revoke all on function public.ddd_can(text) from public, anon;
grant execute on function public.ddd_can(text) to authenticated, service_role;
revoke all on function public.is_real_director() from public, anon;
grant execute on function public.is_real_director() to authenticated, service_role;
revoke all on function public.ddd_my_role() from public, anon;
grant execute on function public.ddd_my_role() to authenticated, service_role;
revoke all on function public.ddd_my_perms() from public, anon;
grant execute on function public.ddd_my_perms() to authenticated, service_role;
revoke all on function public.ddd_is_trusted_session() from public, anon, authenticated;
revoke all on function public.ddd_user_perm_needed(text, uuid) from public, anon, authenticated;
revoke all on function public.ddd_can_manage_user(uuid) from public, anon, authenticated;
revoke all on function public.ddd_guard_users_role() from public, anon, authenticated;
revoke all on function public.ddd_guard_uha_role() from public, anon, authenticated;
revoke all on function public.ddd_guard_role_permissions() from public, anon, authenticated;
revoke all on function public.ddd_guard_expense_approve() from public, anon, authenticated;
revoke all on function public.ddd_guard_student_del_role() from public, anon, authenticated;
revoke all on function public.ddd_guard_student_created_by() from public, anon, authenticated;
revoke all on function public.ddd_guard_hostel_keep_data() from public, anon, authenticated;
-- is_director, approve_warden, reject_warden, remove_warden, pending_wardens - purane rights hi rehte hain

-- ---------------------------------------------------------------------
-- STEP 10. audit (kisne kab kya) - nayi tables aur users bhi
-- ---------------------------------------------------------------------
drop trigger if exists trg_users_audit on public.users;
create trigger trg_users_audit after insert or update or delete on public.users
  for each row execute function public.audit_trigger();
drop trigger if exists trg_user_hostel_assignments_audit on public.user_hostel_assignments;
create trigger trg_user_hostel_assignments_audit after insert or update or delete on public.user_hostel_assignments
  for each row execute function public.audit_trigger();
drop trigger if exists trg_role_permissions_audit on public.role_permissions;
create trigger trg_role_permissions_audit after insert or update or delete on public.role_permissions
  for each row execute function public.audit_trigger();
drop trigger if exists trg_user_admin_log_audit on public.user_admin_log;
create trigger trg_user_admin_log_audit after insert or update or delete on public.user_admin_log
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- STEP 11. VERIFY (kuch bhi galat = sab rollback, kuch nahi badla)
-- ---------------------------------------------------------------------
do $verify$
declare
  v_bad text := '';
  r     record;
begin
  if (select prosrc from pg_proc where oid = 'public.is_director()'::regprocedure) !~ 'all_hostels' then
    v_bad := v_bad || 'is_director ';
  end if;
  for r in select f from unnest(array['public.approve_warden(uuid,uuid)', 'public.reject_warden(uuid)',
                                      'public.remove_warden(uuid)', 'public.pending_wardens()']) f loop
    if (select prosrc from pg_proc where oid = to_regprocedure(r.f)) !~ 'ddd_can\(''warden_manage''\)' then
      v_bad := v_bad || r.f || ' ';
    end if;
  end loop;
  if (select count(*) from public.role_permissions
       where role_name = 'director' and perm in ('manage_managers', 'manage_directors', 'edit_director_login')) <> 3 then
    v_bad := v_bad || 'director perms ';
  end if;
  if exists (select 1 from public.role_permissions
              where role_name <> 'director' and perm in ('manage_managers', 'manage_directors', 'edit_director_login')) then
    v_bad := v_bad || 'director-only perm kisi aur ke paas ';
  end if;
  if (select count(*) from pg_trigger where not tgisinternal and tgenabled = 'O'
        and tgname in ('trg_users_role_guard', 'trg_uha_role_guard', 'trg_role_permissions_guard', 'trg_expenses_approve_guard',
                       'trg_students_del_role_guard', 'trg_hostels_keep_data_guard', 'trg_users_audit',
                       'trg_user_hostel_assignments_audit', 'trg_role_permissions_audit', 'trg_user_admin_log_audit',
                       'trg_students_created_by_guard')) <> 11 then
    v_bad := v_bad || 'triggers ';
  end if;
  if has_function_privilege('anon', 'public.ddd_can(text)', 'execute')
     or has_function_privilege('anon', 'public.is_real_director()', 'execute')
     or has_function_privilege('authenticated', 'public.ddd_user_perm_needed(text,uuid)', 'execute') then
    v_bad := v_bad || 'function rights ';
  end if;
  if has_table_privilege('anon', 'public.user_admin_log', 'select')
     or has_table_privilege('authenticated', 'public.user_admin_log', 'insert')
     or has_table_privilege('service_role', 'public.user_admin_log', 'update')
     or not has_table_privilege('service_role', 'public.user_admin_log', 'insert')
     or has_table_privilege('anon', 'public.role_permissions', 'select') then
    v_bad := v_bad || 'table rights ';
  end if;
  if (select qual from pg_policies where schemaname = 'public' and tablename = 'audit_logs' and policyname = 'audit_dir') !~ 'user_admin_log' then
    v_bad := v_bad || 'audit_dir ';
  end if;
  if public.ddd_can('all_hostels') or public.is_real_director() then
    v_bad := v_bad || 'SQL Editor ko app power mil rahi hai ';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'expenses'
                    and column_name = 'needs_reapproval' and data_type = 'boolean' and is_nullable = 'NO') then
    v_bad := v_bad || 'expenses.needs_reapproval ';
  end if;
  if v_bad <> '' then
    raise exception '027 VERIFY FAIL: %. Sab rollback, kuch nahi badla. Developer ko batayein.', v_bad;
  end if;
end
$verify$;

commit;

notify pgrst, 'reload schema';

-- result (sirf padhna) - kis role ke paas kitni power
select rp.role_name, count(*) as perms, string_agg(rp.perm, ', ' order by rp.perm) as list
  from public.role_permissions rp group by rp.role_name order by rp.role_name;

-- ---------- ROLLBACK ----------
-- Wapas lena ho to 027_undo.sql poori file chalayein.
-- Woh is_director aur 4 warden functions ko backup_027 se bilkul pehle jaisa karta hai,
-- audit_dir policy wapas is_director, 027 ke triggers, functions aur tables hatata hai.
-- user_admin_log mein rows hon to unki copy backup_027 mein rehti hai.
-- head_manager role tabhi hatta hai jab koi user us par na ho.
-- Agar 028, 029, 030 ya 031 chal chuki hain to pehle unka undo (ulte order mein).
