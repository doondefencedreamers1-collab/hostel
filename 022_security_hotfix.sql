-- =====================================================================
-- 022_security_hotfix.sql      (needs 014 + 017; run 022_run_checks STEP 2 first)
-- DDD Hostel — security hotfix from the audit (AUDIT_REPORT.md Batch 1)
--
--  1. generate_monthly_dues: only a logged-in Director / Accountant /
--     Manager (with a hostel), only the current IST month (previous month
--     allowed on the 1st–5th). Not executable by anon. SQL Editor: any month.
--  2. search_path fixed on auth_role, is_director, is_accountant,
--     my_hostels, audit_trigger (SECURITY DEFINER helpers).
--  3. Old handle_new_user() dropped (only if no trigger uses it).
--  4. anon: no table / sequence rights in public; anon cannot run the
--     warden / generate functions. hostels_for_signup stays for sign-up.
--     ddd_pf / ddd_setting_num: not callable from the app (used only inside
--     salary functions).
--  5. Student delete: a student with ANY fee payment cannot be deleted
--     through the app — not even by the Director ("Status = Left" instead).
--     Due delete: Director only, and never a due that has a payment.
--     fee_payments.student_id / due_id: ON DELETE CASCADE -> NO ACTION, so
--     payments can never vanish together with a student or a due.
--  6. documents: Director only. notifications: users can only write their
--     own. app_settings / expense_categories / vendors: readable only by
--     approved users (with a role), not by fresh sign-ups.
-- No data rows are changed. One transaction, idempotent.
-- =====================================================================
begin;

-- ---------- pre-checks ----------
do $$
declare n int;
begin
  if to_regprocedure('public.generate_monthly_dues(date)') is null then raise exception '022 aborted: generate_monthly_dues(date) missing'; end if;
  if to_regprocedure('public.ddd_month_fee(numeric,date,date)') is null then raise exception '022 aborted: run 017 first'; end if;
  if to_regprocedure('public.ddd_is_api_caller()') is null then raise exception '022 aborted: run 014 first (ddd_is_api_caller missing)'; end if;
  if to_regprocedure('public.ddd_guard_student_delete()') is null or to_regprocedure('public.ddd_guard_due_delete()') is null then
    raise exception '022 aborted: 014 delete guards missing';
  end if;
  if to_regclass('backup_022.meta') is null then
    raise exception '022 aborted: run 022_run_checks.sql STEP 2 (backup) first';
  end if;
  n := (select count(*) from backup_022.meta);   -- separate statement: planned only if the table exists
  if n = 0 then raise exception '022 aborted: run 022_run_checks.sql STEP 2 (backup) first'; end if;
  if not exists (select 1 from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
                 where c.contype = 'f' and c.conrelid = 'public.fee_payments'::regclass
                   and c.confrelid = 'public.students'::regclass and a.attname = 'student_id') then
    raise exception '022 aborted: FK fee_payments.student_id -> students not found';
  end if;
end $$;

-- ---------- 1. generate_monthly_dues: role + month check ----------
create or replace function public.generate_monthly_dues(p_month date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  cnt int := 0; r record;
  m_start date := date_trunc('month', p_month)::date;
  m_end   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_cur   date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  -- called through the API (app / anyone with the key)? SQL Editor = no.
  v_api   boolean := auth.uid() is not null or session_user = 'authenticator';
begin
  if p_month is null then raise exception 'Month required'; end if;
  if v_api then
    if auth.uid() is null then
      raise exception 'Login required' using errcode = '42501';
    end if;
    if not (public.is_director() or public.is_accountant() or exists (select 1 from public.my_hostels())) then
      raise exception 'Sirf Director / Manager dues generate kar sakte hain' using errcode = '42501';
    end if;
    if not (m_start = v_cur or (m_start = (v_cur - interval '1 month')::date and extract(day from v_today) <= 5)) then
      raise exception 'Sirf is mahine (%) ki dues generate ho sakti hain', to_char(v_cur, 'Mon YYYY') using errcode = '42501';
    end if;
  end if;
  for r in
    select id, hostel_id, monthly_fee, joining_date from public.students
    where status = 'active'
      and joining_date is not null
      and date_trunc('month', joining_date)::date <= m_start
      and coalesce(monthly_fee, 0) > 0
  loop
    insert into public.monthly_dues(student_id, hostel_id, month, fee_amount, period_from, period_to)
    values (r.id, r.hostel_id, m_start, public.ddd_month_fee(r.monthly_fee, r.joining_date, m_start),
            greatest(m_start, r.joining_date), m_end)
    on conflict (student_id, month) do nothing;
    cnt := cnt + 1;
  end loop;
  return cnt;
end; $function$;
revoke all on function public.generate_monthly_dues(date) from public, anon;
grant execute on function public.generate_monthly_dues(date) to authenticated;

-- ---------- 2. search_path on the permission helpers ----------
do $$
declare f text;
begin
  foreach f in array array['public.auth_role()', 'public.is_director()', 'public.is_accountant()', 'public.my_hostels()', 'public.audit_trigger()'] loop
    if to_regprocedure(f) is not null then
      execute format('alter function %s set search_path = public', f);
    end if;
  end loop;
end $$;

-- ---------- 3. old handle_new_user(): drop if no trigger uses it ----------
do $$
begin
  if to_regprocedure('public.handle_new_user()') is not null then
    if exists (select 1 from pg_trigger where tgfoid = 'public.handle_new_user()'::regprocedure) then
      raise notice '022: handle_new_user() is still used by a trigger — NOT dropped, only locked';
      execute 'alter function public.handle_new_user() set search_path = public';
      execute 'revoke all on function public.handle_new_user() from public, anon, authenticated';
    else
      execute 'drop function public.handle_new_user()';
    end if;
  end if;
end $$;

-- ---------- 4. anon: nothing in public except the sign-up hostel list ----------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
do $$
declare f text;
begin
  -- app functions: logged-in users only
  foreach f in array array['public.approve_warden(uuid,uuid)', 'public.reject_warden(uuid)', 'public.remove_warden(uuid)',
                           'public.pending_wardens()', 'public.ddd_require_director()'] loop
    if to_regprocedure(f) is not null then
      execute format('revoke all on function %s from public, anon', f);
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
  -- trigger functions and internal salary helpers: never called from the app
  foreach f in array array['public.handle_new_signup()', 'public.audit_trigger()', 'public.ddd_pf(numeric)', 'public.ddd_setting_num(text,numeric)'] loop
    if to_regprocedure(f) is not null then
      execute format('revoke all on function %s from public, anon, authenticated', f);
    end if;
  end loop;
  -- sign-up page (before login) needs the hostel list
  if to_regprocedure('public.hostels_for_signup()') is not null then
    execute 'grant execute on function public.hostels_for_signup() to anon, authenticated';
  end if;
end $$;

-- ---------- 5. deletes can never take payments with them ----------
create or replace function public.ddd_guard_student_delete() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.ddd_is_api_caller() then
    if exists (select 1 from public.fee_payments where student_id = old.id) then
      raise exception 'Is student ki fee payments hain — delete nahi ho sakta (Director bhi nahi). Status = Left karein.'
        using errcode = '42501';
    end if;
  end if;
  return old;
end $$;

create or replace function public.ddd_guard_due_delete() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.ddd_is_api_caller() then
    if exists (select 1 from public.fee_payments where due_id = old.id) then
      raise exception 'Is due par payment hai — pehle Director "Delete Payment" karein' using errcode = '42501';
    end if;
    if not public.is_director() then
      raise exception 'Due sirf Director delete kar sakta hai' using errcode = '42501';
    end if;
  end if;
  return old;
end $$;

-- FKs: ON DELETE CASCADE -> NO ACTION (same name, same columns)
do $$
declare c record;
begin
  for c in
    select con.conname, a.attname as col, con.confrelid::regclass as ref, con.confdeltype
    from pg_constraint con join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
    where con.contype = 'f' and con.conrelid = 'public.fee_payments'::regclass and array_length(con.conkey, 1) = 1
      and ((a.attname = 'student_id' and con.confrelid = 'public.students'::regclass)
        or (a.attname = 'due_id' and con.confrelid = 'public.monthly_dues'::regclass))
  loop
    if c.confdeltype <> 'a' then
      execute format('alter table public.fee_payments drop constraint %I', c.conname);
      execute format('alter table public.fee_payments add constraint %I foreign key (%I) references %s(id) on delete no action',
                     c.conname, c.col, c.ref);
    end if;
  end loop;
end $$;

-- ---------- 6. policies ----------
do $$
begin
  if to_regclass('public.documents') is not null then
    execute 'drop policy if exists docs_read on public.documents';
    execute 'drop policy if exists docs_write on public.documents';
    execute 'drop policy if exists docs_director on public.documents';
    execute 'create policy docs_director on public.documents for all to authenticated using (public.is_director()) with check (public.is_director())';
  end if;
  if to_regclass('public.notifications') is not null then
    execute 'drop policy if exists notif_self on public.notifications';
    execute 'create policy notif_self on public.notifications for all to authenticated using (user_id = auth.uid() or public.is_director()) with check (user_id = auth.uid() or public.is_director())';
  end if;
  execute 'drop policy if exists app_settings_read on public.app_settings';
  execute 'create policy app_settings_read on public.app_settings for select to authenticated using (public.auth_role() is not null)';
  if to_regclass('public.expense_categories') is not null then
    execute 'drop policy if exists ref_read on public.expense_categories';
    execute 'create policy ref_read on public.expense_categories for select to authenticated using (public.auth_role() is not null)';
  end if;
  if to_regclass('public.vendors') is not null then
    execute 'drop policy if exists vendors_read on public.vendors';
    execute 'create policy vendors_read on public.vendors for select to authenticated using (public.auth_role() is not null)';
  end if;
end $$;

commit;

notify pgrst, 'reload schema';

-- verify: 022_run_checks.sql STEP 4 (all rows ok = true)
