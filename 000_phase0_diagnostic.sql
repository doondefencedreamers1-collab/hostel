-- PHASE 0 DIAGNOSTIC — read-only. Paste whole file in Supabase SQL Editor → Run.
-- Returns ONE result grid (section | object | detail). Copy all rows back (Export CSV / copy).
with t(tbl) as (values ('students'),('fee_payments'),('monthly_dues'),('payments'),('app_settings'),('users'),('roles'),('user_hostel_assignments'))
select * from (
  -- 0. Which of these tables exist on live
  select '0_tables' sec, t.tbl obj,
         case when to_regclass('public.'||t.tbl) is null then 'MISSING' else 'exists' end det, 0 ord
  from t
  union all
  -- 1. Columns
  select '1_columns', c.table_name||'.'||c.column_name,
         c.data_type||coalesce('('||c.numeric_precision||','||c.numeric_scale||')','')
         ||' null='||c.is_nullable||' default='||coalesce(c.column_default,'-'), c.ordinal_position
  from information_schema.columns c
  where c.table_schema='public' and c.table_name in ('students','fee_payments','monthly_dues','payments','app_settings')
  union all
  -- 2. Constraints (PK / FK / CHECK / UNIQUE)
  select '2_constraints', conrelid::regclass||'.'||conname, pg_get_constraintdef(oid), 0
  from pg_constraint
  where conrelid in (select to_regclass('public.'||tbl) from t where to_regclass('public.'||tbl) is not null)
  union all
  -- 3. Indexes
  select '3_indexes', tablename||'.'||indexname, indexdef, 0
  from pg_indexes where schemaname='public' and tablename in ('students','fee_payments','monthly_dues','payments')
  union all
  -- 4. Triggers
  select '4_triggers', event_object_table||'.'||trigger_name,
         action_timing||' '||event_manipulation||' '||action_orientation||' → '||action_statement, 0
  from information_schema.triggers
  where event_object_schema='public' and event_object_table in ('students','fee_payments','monthly_dues','payments')
  union all
  -- 5. RLS enabled?
  select '5_rls_enabled', relname, 'rls='||relrowsecurity||' force='||relforcerowsecurity, 0
  from pg_class where relnamespace='public'::regnamespace
   and relname in ('students','fee_payments','monthly_dues','payments','app_settings')
  union all
  -- 6. RLS policies
  select '6_policies', tablename||'.'||policyname,
         cmd||' roles='||array_to_string(roles,',')||' USING('||coalesce(qual,'-')||') CHECK('||coalesce(with_check,'-')||')', 0
  from pg_policies
  where schemaname='public' and tablename in ('students','fee_payments','monthly_dues','payments','app_settings','users')
  union all
  -- 7. Role-resolution + billing functions (full source)
  select '7_functions', p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
         'secdef='||p.prosecdef||E'\n'||pg_get_functiondef(p.oid), 0
  from pg_proc p
  where p.pronamespace='public'::regnamespace
    and (p.proname in ('auth_role','is_director','is_accountant','is_manager','is_warden','my_hostels',
                       'generate_monthly_dues','generate_anniversary_dues','audit_trigger','handle_new_user',
                       'approve_warden','reject_warden','remove_warden')
         or p.proname ilike '%role%' or p.proname ilike '%due%' or p.proname ilike '%fee%' or p.proname ilike '%pay%')
  union all
  -- 8. Roles present + user counts
  select '8_roles', r.name, count(u.id)::text||' users', 0
  from roles r left join users u on u.role_id=r.id group by r.name
  union all
  -- 9. Data shape (for backfill planning)
  select '9_data', 'students', count(*)||' rows, '||count(*) filter (where status='active')||' active, '
         ||count(*) filter (where joining_date is null)||' null joining_date, '
         ||count(*) filter (where coalesce(monthly_fee,0)=0)||' zero fee', 0 from students
  union all
  select '9_data', 'fee_payments', count(*)||' rows, '||count(*) filter (where due_id is null)||' without due_id, '
         ||count(distinct student_id)||' students', 0 from fee_payments
  union all
  select '9_data', 'monthly_dues', count(*)||' rows, statuses='||coalesce(string_agg(distinct status,','),'-'), 0 from monthly_dues
) x
order by sec, obj, ord;

-- If this errors on a missing column (e.g. monthly_dues.status), send me the error — that itself is the answer.

-- ---- OPTIONAL extra queries: run each one separately (they may fail if the table doesn't exist; that's fine) ----
-- A) billing mode
select key, value from app_settings;
-- B) applied migration history (only if migrations were run via CLI)
select version, name from supabase_migrations.schema_migrations order by version;
-- C) 5 sample recent payments (to see real period_from/period_to usage)
select id, student_id, due_id, amount, payment_date, period_from, period_to, created_at
from fee_payments order by created_at desc limit 5;
