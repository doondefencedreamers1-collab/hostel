-- DDD Hostel - Phase 0 diagnostic - file Q3 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q3.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q3] =================================================================
-- Q3  SAARI public TABLES / VIEWS: RLS ON/OFF + HAR POLICY + anon/app RIGHTS
--     (ek hi baar mein poora security picture, "note" column mein khatre
--     wali cheezein likhi aati hain, jaise RLS OFF, policy bina WITH CHECK,
--     users table par apna role khud badalne ka rasta).
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
rel as (
  select c.oid, c.relname, c.relkind, c.relrowsecurity as rls, c.relforcerowsecurity as forced,
         coalesce((select lower(o.option_value) from pg_options_to_table(c.reloptions) o where o.option_name = 'security_invoker'), 'false') in ('true', 'on', '1', 'yes') as sec_invoker,
         coalesce(nullif(concat_ws('', case when has_table_privilege('anon', c.oid, 'SELECT') then 'S' end,
                                       case when has_table_privilege('anon', c.oid, 'INSERT') then 'I' end,
                                       case when has_table_privilege('anon', c.oid, 'UPDATE') then 'U' end,
                                       case when has_table_privilege('anon', c.oid, 'DELETE') then 'D' end), ''), '-') as anon_r,
         coalesce(nullif(concat_ws('', case when has_table_privilege('authenticated', c.oid, 'SELECT') then 'S' end,
                                       case when has_table_privilege('authenticated', c.oid, 'INSERT') then 'I' end,
                                       case when has_table_privilege('authenticated', c.oid, 'UPDATE') then 'U' end,
                                       case when has_table_privilege('authenticated', c.oid, 'DELETE') then 'D' end), ''), '-') as auth_r
  from pg_class c
  where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'f')
)
select r.relname as tbl,
       case r.relkind when 'r' then 'table' when 'p' then 'table' when 'v' then 'VIEW' when 'm' then 'MAT.VIEW' else 'foreign' end as kind,
       case when r.relkind in ('r', 'p') then r.rls::text else '-' end as rls_on,
       case when r.relkind in ('r', 'p') then r.forced::text else '-' end as rls_forced,
       r.anon_r as anon_rights, r.auth_r as app_rights,
       coalesce(po.policyname, '(no policy)') as policy,
       po.cmd, po.permissive, array_to_string(po.roles, ',') as roles,
       po.qual as using_expr, po.with_check as with_check_expr,
       concat_ws(' | ',
         case when r.relkind in ('r', 'p') and not r.rls and (r.anon_r <> '-' or r.auth_r <> '-') then 'RLS OFF: any logged-in (or anon) API call can use it as per rights' end,
         case when r.relkind in ('r', 'p') and r.rls and po.policyname is null then 'RLS on, no policy: app sees nothing (only SQL / definer functions)' end,
         case when r.relkind in ('v', 'm') and not r.sec_invoker and (r.anon_r <> '-' or r.auth_r <> '-') then 'VIEW runs with owner rights: bypasses RLS of base tables' end,
         case when po.policyname is not null and coalesce(po.qual, 'true') = 'true' and po.cmd in ('SELECT', 'ALL')
                   and (po.roles && array['public', 'anon']::name[]) then 'OPEN: USING (true) for public/anon' end,
         case when po.policyname is not null and po.cmd in ('ALL', 'INSERT', 'UPDATE') and coalesce(po.with_check, po.qual, 'true') = 'true'
                   and r.relname not in ('notifications', 'documents') then 'WRITE allowed for every row (true)' end,
         case when r.relname = 'users' and po.cmd in ('UPDATE', 'ALL') and po.permissive = 'PERMISSIVE'
                   and (coalesce(po.qual, '') like '%auth.uid()%' or coalesce(po.with_check, '') like '%auth.uid()%')
                   and coalesce(po.with_check, po.qual, '') not like '%role_id%'
              then 'SELF-UPDATE: a user may update own row and WITH CHECK does not pin role_id/status -> can set own role_id (escalation to director) unless column right blocks it; users.role_id UPDATE right for authenticated = '
                   || coalesce(has_column_privilege('authenticated', r.oid, 'role_id', 'UPDATE')::text, '?')
                   || case when po.with_check is null then ' (no WITH CHECK)' else ' (WITH CHECK only checks the row, not the role)' end end,
         case when po.policyname is not null and po.cmd in ('ALL', 'UPDATE') and po.with_check is null and r.relname <> 'users'
              then 'no WITH CHECK (USING is reused)' end,
         case when po.policyname is not null and po.roles && array['anon']::name[] then 'policy applies to anon' end
       ) as note
from rel r
left join pg_policies po on po.schemaname = 'public' and po.tablename = r.relname
order by (r.relname in ('students', 'monthly_dues', 'fee_payments', 'beds', 'bed_allocations', 'users', 'user_hostel_assignments', 'hostels')) desc,
         r.relname, po.cmd, po.policyname;
