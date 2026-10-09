-- DDD Hostel - Phase 0 diagnostic - file Q4 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q4.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q4] =================================================================
-- Q4  FEE BANANE WALA CODE: FUNCTIONS (POORA SOURCE) + TRIGGERS + CRON / WEBHOOKS
--     - generate_monthly_dues aur HAR woh function jo monthly_dues ya
--       students mein insert / update / delete karta hai (poora source),
--     - RLS helpers (auth_role, is_director, is_accountant, my_hostels),
--     - students / monthly_dues / fee_payments / beds / auth.users ke
--       triggers aur unke functions,
--     - pg_cron jobs, database webhooks (supabase_functions.hooks), pg_net,
--     - migrations se pehle save kiya gaya purana live source (backup_0XX).
--     "source" column lamba hai - CSV mein poora aata hai.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
obj(nsp, rel) as (values ('cron', 'job'), ('cron', 'job_run_details'), ('supabase_functions', 'hooks'), ('auth', 'users'),
                         ('backup_020', 'fn_defs'), ('backup_022', 'meta'), ('backup_023', 'meta'), ('backup_024', 'meta')),
oo as (   -- optional objects, looked up in the catalog (needs no rights); readable = schema USAGE + table SELECT
  select obj.nsp, obj.rel, n.oid is not null as ns_exists, c.oid as rid,
         coalesce(has_schema_privilege(n.oid, 'USAGE'), false) as ns_usage,
         c.oid is not null and coalesce(has_schema_privilege(n.oid, 'USAGE'), false) and coalesce(has_table_privilege(c.oid, 'SELECT'), false) as readable
  from obj
  left join pg_namespace n on n.nspname = obj.nsp
  left join pg_class c on c.relnamespace = n.oid and c.relname = obj.rel and c.relkind in ('r', 'p', 'v', 'f')
),
trg as (   -- triggers on the tables that matter
  select t.oid, t.tgrelid, t.tgname, t.tgfoid, t.tgenabled,
         t.tgrelid::regclass::text as tbl
  from pg_trigger t
  where not t.tgisinternal
    and t.tgrelid in (select x from (values (to_regclass('public.students')), (to_regclass('public.monthly_dues')),
                                            (to_regclass('public.fee_payments')), (to_regclass('public.beds')),
                                            (to_regclass('public.bed_allocations')), (to_regclass('public.users')),
                                            (to_regclass('public.user_hostel_assignments')),
                                            ((select oo.rid::regclass from oo where oo.nsp = 'auth' and oo.rel = 'users'))) v(x)
                      where x is not null)
),
fn as (
  select p.oid, n.nspname, p.proname, p.prosrc, p.prosecdef, p.proconfig, p.provolatile, l.lanname,
         n.nspname || '.' || p.proname || '(' || replace(oidvectortypes(p.proargtypes), ' ', '') || ')' as sig,
         concat_ws(', ',
           case when p.proname in ('generate_monthly_dues', 'generate_anniversary_dues') then 'dues generator' end,
           case when p.proname in ('auth_role', 'is_director', 'is_accountant', 'my_hostels', 'is_manager', 'is_warden') then 'RLS helper' end,
           case when p.prosrc ~* 'insert\s+into\s+(public\.)?"?monthly_dues' then 'INSERTS monthly_dues' end,
           case when p.prosrc ~* 'update\s+(public\.)?"?monthly_dues' then 'UPDATES monthly_dues' end,
           case when p.prosrc ~* 'delete\s+from\s+(public\.)?"?monthly_dues' then 'DELETES monthly_dues' end,
           case when p.prosrc ~* 'insert\s+into\s+(public\.)?"?students\M' then 'INSERTS students' end,
           case when p.prosrc ~* 'update\s+(public\.)?"?students\M' then 'UPDATES students' end,
           case when p.prosrc ~* 'delete\s+from\s+(public\.)?"?students\M' then 'DELETES students' end,
           case when p.prosrc ~* '\mexecute\M' and p.prosrc ~* '(monthly_dues|students)' and p.prosrc !~* 'execute\s+function' then 'dynamic SQL near students/dues' end,
           case when p.oid in (select tgfoid from trg) then 'trigger fn on ' || (select string_agg(distinct trg.tbl, ',') from trg where trg.tgfoid = p.oid) end
         ) as why
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where p.prokind in ('f', 'p')
    and (n.nspname = 'public' or p.oid in (select tgfoid from trg))
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
),
cronq as (   -- pg_cron jobs (only read when pg_cron exists and is readable)
  select r
  from unnest(case
         when (select readable from oo where nsp = 'cron' and rel = 'job')
         then xpath('/table/row', query_to_xml(
                case when (select readable from oo where nsp = 'cron' and rel = 'job_run_details')
                     then 'select j.jobid, encode(convert_to(coalesce(to_jsonb(j)->>''jobname'', ''''), ''UTF8''), ''hex'') as nm, j.schedule, j.active,
                                  encode(convert_to(j.command, ''UTF8''), ''hex'') as cmd,
                                  (select max(d.start_time) from cron.job_run_details d where d.jobid = j.jobid)::text as last_run,
                                  (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.start_time > now() - interval ''45 days'')::text as runs_45d
                           from cron.job j'
                     else 'select j.jobid, encode(convert_to(coalesce(to_jsonb(j)->>''jobname'', ''''), ''UTF8''), ''hex'') as nm, j.schedule, j.active,
                                  encode(convert_to(j.command, ''UTF8''), ''hex'') as cmd from cron.job j' end,
                false, false, ''))
         else array[]::xml[] end) as r
),
hookq as (   -- Supabase "database webhooks"
  select r
  from unnest(case
         when (select readable from oo where nsp = 'supabase_functions' and rel = 'hooks')
         then xpath('/table/row', query_to_xml(
                'select encode(convert_to(coalesce(case when (to_jsonb(h)->>''hook_table_id'') ~ ''^[0-9]+$'' then (to_jsonb(h)->>''hook_table_id'')::oid::regclass::text end, to_jsonb(h)->>''hook_table_id'', ''?'') || '' '' || coalesce(to_jsonb(h)->>''hook_name'', ''?'') || '' created '' || coalesce(to_jsonb(h)->>''created_at'', ''?''), ''UTF8''), ''hex'') as v from supabase_functions.hooks h',
                false, false, ''))
         else array[]::xml[] end) as r
),
bkq as (   -- function sources saved by the run_checks backups BEFORE a migration replaced them
  select 'backup_022.meta' as src, r from unnest(case when (select readable from oo where nsp = 'backup_022' and rel = 'meta')
         then xpath('/table/row', query_to_xml('select encode(convert_to(k, ''UTF8''), ''hex'') as k, saved_at::text as t, encode(convert_to(v #>> ''{}'', ''UTF8''), ''hex'') as v from backup_022.meta where k like ''fn:%''', false, false, ''))
         else array[]::xml[] end) r
  union all
  select 'backup_023.meta', r from unnest(case when (select readable from oo where nsp = 'backup_023' and rel = 'meta')
         then xpath('/table/row', query_to_xml('select encode(convert_to(k, ''UTF8''), ''hex'') as k, saved_at::text as t, encode(convert_to(v #>> ''{}'', ''UTF8''), ''hex'') as v from backup_023.meta where k like ''fn:%''', false, false, ''))
         else array[]::xml[] end) r
  union all
  select 'backup_024.meta', r from unnest(case when (select readable from oo where nsp = 'backup_024' and rel = 'meta')
         then xpath('/table/row', query_to_xml('select encode(convert_to(k, ''UTF8''), ''hex'') as k, saved_at::text as t, encode(convert_to(v #>> ''{}'', ''UTF8''), ''hex'') as v from backup_024.meta where k like ''fn:%''', false, false, ''))
         else array[]::xml[] end) r
  union all
  select 'backup_020.fn_defs', r from unnest(case when (select readable from oo where nsp = 'backup_020' and rel = 'fn_defs')
         then xpath('/table/row', query_to_xml('select encode(convert_to(fn, ''UTF8''), ''hex'') as k, saved_at::text as t, encode(convert_to(def, ''UTF8''), ''hex'') as v from backup_020.fn_defs', false, false, ''))
         else array[]::xml[] end) r
)
select kind, name, why,
       regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(attrs,
       '(\mbearer\s+)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
       'eyJ[A-Za-z0-9._-]{16,}', 'eyJ***MASKED***', 'g'),
       '\m(sb_secret_|sk_live_|rk_live_|EAA)[A-Za-z0-9_-]{8,}', '\1***MASKED***', 'g'),
       '(\m(api_?key|x-api-key|service_?role(_?key)?|secret|secret_?key|password|passwd|pwd|token|access_?token|auth_?token)\M["'']?\s*(:=|=>|:|=|,)\s*["'']?)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
       '(://[^:/@\s''"]+:)[^@\s''"]+@', '\1***MASKED***@', 'g'),
       '(\m(apikey|authorization)["'']?\s*(:|=|,)\s*["'']?)[^"''\s,}]{12,}', '\1***MASKED***', 'gi') as attrs,   -- secrets masked
       flags,
       regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(source,
       '(\mbearer\s+)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
       'eyJ[A-Za-z0-9._-]{16,}', 'eyJ***MASKED***', 'g'),
       '\m(sb_secret_|sk_live_|rk_live_|EAA)[A-Za-z0-9_-]{8,}', '\1***MASKED***', 'g'),
       '(\m(api_?key|x-api-key|service_?role(_?key)?|secret|secret_?key|password|passwd|pwd|token|access_?token|auth_?token)\M["'']?\s*(:=|=>|:|=|,)\s*["'']?)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
       '(://[^:/@\s''"]+:)[^@\s''"]+@', '\1***MASKED***@', 'g'),
       '(\m(apikey|authorization)["'']?\s*(:|=|,)\s*["'']?)[^"''\s,}]{12,}', '\1***MASKED***', 'gi') as source   -- secrets masked
from (
  -- 1. functions (full source)
  select 1 as ord, 'function' as kind, fn.sig as name, fn.why,
         case when fn.prosecdef then 'SECURITY DEFINER' else 'invoker' end
           || ' ' || fn.lanname || ' ' || case fn.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end
           || ' cfg=' || coalesce(array_to_string(fn.proconfig, ','), '-')
           || ' | EXECUTE anon=' || has_function_privilege('anon', fn.oid, 'execute') || ' authenticated=' || has_function_privilege('authenticated', fn.oid, 'execute')
           || ' | fp=' || md5(regexp_replace(regexp_replace(fn.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as attrs,
         concat_ws(', ',
           case when fn.prosrc ~* '(insert\s+into|update|delete\s+from)\s+(public\.)?"?monthly_dues' or fn.proname like 'generate%dues' then
                  'filters students.status=''active'': ' || (fn.prosrc ~* 'status\s*=\s*''active''')
                  || ' | mentions ''left'': ' || (fn.prosrc ~* '''left''')
                  || ' | uses exit_date: ' || (fn.prosrc ~* 'exit_date') end,
           case when fn.prosrc ~* 'on\s+conflict' then 'has ON CONFLICT' end
         ) as flags,
         pg_get_functiondef(fn.oid) as source
  from fn
  where fn.why <> ''
  -- 2. triggers
  union all
  select 2, 'trigger', trg.tbl || ' . ' || trg.tgname,
         'enabled=' || case trg.tgenabled when 'O' then 'yes' when 'D' then 'DISABLED' when 'R' then 'replica-only' when 'A' then 'always' else trg.tgenabled::text end,
         pg_get_triggerdef(trg.oid),
         'function=' || trg.tgfoid::regprocedure::text || case when (select nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = trg.tgfoid) = 'supabase_functions' then ' (DATABASE WEBHOOK!)' else '' end,
         null
  from trg
  -- 3. pg_cron jobs
  union all
  select 3, 'cron job', 'jobid ' || (xpath('/row/jobid/text()', r))[1]::text || ' ' || coalesce(convert_from(decode((xpath('/row/nm/text()', r))[1]::text, 'hex'), 'UTF8'), ''),
         'schedule ' || coalesce((xpath('/row/schedule/text()', r))[1]::text, '?') || ' active=' || coalesce((xpath('/row/active/text()', r))[1]::text, '?'),
         'last run (UTC): ' || coalesce((xpath('/row/last_run/text()', r))[1]::text, '-') || ' | runs in 45 days: ' || coalesce((xpath('/row/runs_45d/text()', r))[1]::text, '-'),
         case when convert_from(decode((xpath('/row/cmd/text()', r))[1]::text, 'hex'), 'UTF8') ~* '(monthly_dues|generate_|students)' then 'TOUCHES DUES/STUDENTS' end,
         convert_from(decode((xpath('/row/cmd/text()', r))[1]::text, 'hex'), 'UTF8')
  from cronq
  union all
  select 3, 'cron', 'pg_cron',
         (select case when o.rid is null then 'not installed'
                      when not o.ns_usage then 'installed but NO USAGE on schema cron: jobs cannot be read by this user'
                      when not o.readable then 'installed but cron.job not readable by this user'
                      else 'installed, ' || (select count(*) from cronq) || ' job(s) listed' end
          from oo o where o.nsp = 'cron' and o.rel = 'job'), null, null, null
  -- 4. database webhooks / pg_net
  union all
  select 4, 'webhook', 'supabase_functions.hooks row', convert_from(decode((xpath('/row/v/text()', r))[1]::text, 'hex'), 'UTF8'), null, null, null
  from hookq
  union all
  select 4, 'webhook', 'summary',
         'supabase_functions.hooks: ' || (select case when o.rid is null then 'absent'
                                                      when not o.ns_usage then 'NO USAGE on schema supabase_functions (cannot read)'
                                                      when not o.readable then 'not readable by this user'
                                                      else (select count(*) from hookq) || ' row(s)' end
                                           from oo o where o.nsp = 'supabase_functions' and o.rel = 'hooks')
         || ' | pg_net: ' || case when exists (select 1 from pg_extension where extname = 'pg_net') then 'installed' else 'not installed' end
         || ' | triggers calling supabase_functions on these tables: ' || (select count(*) from trg join pg_proc p on p.oid = trg.tgfoid join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'supabase_functions'),
         null, null, null
  -- 5. old live source saved by backups (what ran BEFORE 020/022/023a/024 replaced it)
  union all
  select 5, 'saved old source', bkq.src || ' : ' || convert_from(decode((xpath('/row/k/text()', r))[1]::text, 'hex'), 'UTF8'),
         'saved_at (UTC): ' || coalesce((xpath('/row/t/text()', r))[1]::text, '?'), null, null,
         convert_from(decode((xpath('/row/v/text()', r))[1]::text, 'hex'), 'UTF8')
  from bkq
  union all
  select 5, 'saved old source', o.nsp || '.' || o.rel || ' : NOT READ', case when not o.ns_usage then 'no USAGE on schema ' || o.nsp else 'no SELECT right' end, null, null, null
  from oo o where o.nsp like 'backup%' and o.rid is not null and not o.readable
) z
order by ord,
         case when name like '%generate_monthly_dues%' then 0 when why like '%INSERTS monthly_dues%' then 1 when why like '%students%' then 2 else 3 end,
         name;
