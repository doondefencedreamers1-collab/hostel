-- =====================================================================
--  DDD HOSTEL MANAGEMENT SYSTEM  ·  002_rls.sql
--  Run this SECOND. Enables role-based security in the database itself.
-- =====================================================================

-- ---------- helper functions (SECURITY DEFINER to avoid RLS recursion) ----------
create or replace function auth_role() returns text as $$
  select r.name from users u join roles r on r.id = u.role_id where u.id = auth.uid();
$$ language sql stable security definer;

create or replace function is_director() returns boolean as $$
  select coalesce(auth_role() = 'director', false);
$$ language sql stable security definer;

create or replace function is_accountant() returns boolean as $$
  select coalesce(auth_role() = 'accountant', false);
$$ language sql stable security definer;

create or replace function my_hostels() returns setof uuid as $$
  select hostel_id from user_hostel_assignments where user_id = auth.uid();
$$ language sql stable security definer;

-- ---------- auto-create a profile row when someone signs up ----------
create or replace function handle_new_user() returns trigger as $$
begin
  insert into public.users(id, full_name, email, role_id)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
          new.email,
          (select id from roles where name = coalesce(new.raw_user_meta_data->>'role','manager')))
  on conflict (id) do nothing;
  return new;
end; $$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- generic audit log trigger ----------
create or replace function audit_trigger() returns trigger as $$
begin
  insert into audit_logs(user_id, action, entity_type, entity_id, before, after)
  values (auth.uid(), lower(tg_op), tg_table_name,
          coalesce(new.id, old.id),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end; $$ language plpgsql security definer;

do $$ declare t text;
begin
  for t in select unnest(array['hostels','rooms','beds','students',
    'monthly_dues','fee_payments','expenses','employees','salary_payments','complaints','inventory']) loop
    execute format('create trigger trg_%s_audit after insert or update or delete on %I
      for each row execute function audit_trigger();', t, t);
  end loop;
end $$;

-- ---------- enable RLS everywhere ----------
do $$ declare t text;
begin
  for t in select tablename from pg_tables where schemaname='public' loop
    execute format('alter table %I enable row level security;', t);
  end loop;
end $$;

-- ---------- read-only reference tables: any signed-in user ----------
create policy ref_read on roles for select using (auth.uid() is not null);
create policy ref_read on expense_categories for select using (auth.uid() is not null);

-- ---------- users: see self + director sees all ----------
create policy users_self on users for select using (id = auth.uid() or is_director());
create policy users_dir_write on users for all using (is_director()) with check (is_director());
create policy users_self_update on users for update using (id = auth.uid());

create policy uha_read on user_hostel_assignments for select
  using (is_director() or user_id = auth.uid());
create policy uha_dir on user_hostel_assignments for all
  using (is_director()) with check (is_director());

-- =====================================================================
--  Pattern per data table:
--    SELECT  : director OR accountant OR row in my_hostels()
--    WRITE   : director OR (manager AND row in my_hostels())
--  Finance tables additionally allow accountant to write.
-- =====================================================================

-- hostels (only director may create/edit/delete; everyone scoped may read)
create policy hostels_read on hostels for select
  using (is_director() or is_accountant() or id in (select my_hostels()));
create policy hostels_write on hostels for all
  using (is_director()) with check (is_director());

-- generic scoped tables (manager can write within assigned hostel)
do $$ declare t text;
begin
  for t in select unnest(array['rooms','beds','students','bed_allocations',
    'staff_attendance','student_attendance','complaints','maintenance_tasks','inventory']) loop
    execute format($f$
      create policy %1$s_read on %1$I for select
        using (is_director() or is_accountant() or hostel_id in (select my_hostels()));
      create policy %1$s_write on %1$I for all
        using (is_director() or hostel_id in (select my_hostels()))
        with check (is_director() or hostel_id in (select my_hostels()));
    $f$, t);
  end loop;
end $$;

-- finance tables (accountant may also write)
do $$ declare t text;
begin
  for t in select unnest(array['monthly_dues','fee_payments','expenses',
    'employees','salary_payments']) loop
    execute format($f$
      create policy %1$s_read on %1$I for select
        using (is_director() or is_accountant() or hostel_id in (select my_hostels()));
      create policy %1$s_write on %1$I for all
        using (is_director() or is_accountant() or hostel_id in (select my_hostels()))
        with check (is_director() or is_accountant() or hostel_id in (select my_hostels()));
    $f$, t);
  end loop;
end $$;

-- vendors / documents: any signed-in user read; director write
create policy vendors_read on vendors for select using (auth.uid() is not null);
create policy vendors_write on vendors for all using (is_director()) with check (is_director());
create policy docs_read on documents for select using (auth.uid() is not null);
create policy docs_write on documents for all using (auth.uid() is not null) with check (auth.uid() is not null);

-- notifications: only the owner
create policy notif_self on notifications for all
  using (user_id = auth.uid() or is_director()) with check (true);

-- audit log: director only
create policy audit_dir on audit_logs for select using (is_director());
