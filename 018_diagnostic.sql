-- =====================================================================
-- 018 DIAGNOSTIC — READ-ONLY. Run each QUERY separately, send all results.
-- =====================================================================

-- ---------------------------------------------------------------------
-- QUERY 1 — staff / salary / advance / attendance tables: columns, constraints, RLS
-- ---------------------------------------------------------------------
with t as (
  select c.oid, c.relname from pg_class c
  where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
    and (c.relname in ('employees','staff','salary_payments','staff_attendance')
         or c.relname ilike '%salary%' or c.relname ilike '%advance%' or c.relname ilike '%attend%' or c.relname ilike '%staff%' or c.relname ilike '%payroll%')
)
select * from (
  select '0_table' sec, relname obj, 'rls=' || (select relrowsecurity from pg_class where oid = t.oid) det, 0 ord from t
  union all
  select '1_column', t.relname || '.' || a.attname,
         format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' not null' else '' end
         || coalesce(' default ' || pg_get_expr(d.adbin, d.adrelid), '') || case when a.attgenerated = 's' then ' GENERATED' else '' end, a.attnum
  from t join pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = t.oid and d.adnum = a.attnum
  union all
  select '2_constraint', t.relname || '.' || c.conname, pg_get_constraintdef(c.oid), 0
  from t join pg_constraint c on c.conrelid = t.oid
  union all
  select '3_policy', p.tablename || '.' || p.policyname,
         p.cmd || ' roles=' || array_to_string(p.roles, ',') || ' USING(' || coalesce(p.qual, '-') || ') CHECK(' || coalesce(p.with_check, '-') || ')', 0
  from pg_policies p where p.schemaname = 'public' and p.tablename in (select relname from t)
  union all
  select '4_trigger', tg.tgrelid::regclass::text || '.' || tg.tgname, pg_get_triggerdef(tg.oid), 0
  from pg_trigger tg where not tg.tgisinternal and tg.tgrelid in (select oid from t)
  union all
  select '5_function', p.proname, pg_get_function_identity_arguments(p.oid), 0
  from pg_proc p where p.pronamespace = 'public'::regnamespace
    and (p.proname ilike '%salary%' or p.proname ilike '%staff%' or p.proname ilike '%payroll%' or p.proname ilike '%advance%')
) x order by sec, obj, ord;

-- ---------------------------------------------------------------------
-- QUERY 2 — staff data: how "Salary payable" is made (= sum of monthly_salary)
-- ---------------------------------------------------------------------
select count(*)                                                   as staff_total,
       count(*) filter (where coalesce(status,'active') = 'active') as active,
       count(*) filter (where coalesce(monthly_salary,0) = 0)     as salary_zero,
       count(*) filter (where coalesce(monthly_salary,0) > 0)     as salary_set,
       coalesce(sum(monthly_salary), 0)                           as salary_payable_app,
       count(*) filter (where coalesce(advance,0) > 0)            as with_advance,
       coalesce(sum(advance), 0)                                  as advance_total,
       count(*) filter (where joining_date is null)               as no_joining_date,
       count(*) filter (where user_id is not null)                as linked_to_login,
       string_agg(distinct coalesce(role,'-'), ', ')              as roles
from employees;

-- ---------------------------------------------------------------------
-- QUERY 3 — staff with salary > 0 (who makes up the payable amount)
-- ---------------------------------------------------------------------
select e.full_name, e.role, h.code hostel, e.monthly_salary, e.advance, e.joining_date, e.status
from employees e left join hostels h on h.id = e.hostel_id
where coalesce(e.monthly_salary,0) > 0 or coalesce(e.advance,0) > 0
order by e.monthly_salary desc;

-- ---------------------------------------------------------------------
-- QUERY 4 — old salary_payments + attendance data (run; error = table missing, that's fine)
-- ---------------------------------------------------------------------
select 'salary_payments' t, count(*)::text n, min(month)::text first_, max(month)::text last_ from salary_payments
union all
select 'staff_attendance', count(*)::text, min(date)::text, max(date)::text from staff_attendance;
