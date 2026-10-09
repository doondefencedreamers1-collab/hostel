-- DDD Hostel - Phase 0 diagnostic - file Q2 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q2.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q2] =================================================================
-- Q2  STUDENTS / FEES TABLES KA LIVE STRUCTURE
--     students, monthly_dues, fee_payments, beds, bed_allocations, users,
--     user_hostel_assignments, hostels, audit_logs, app_settings:
--     columns (repo se compare: MISSING / EXTRA), constraints, unique keys,
--     foreign keys (delete rule), indexes, triggers (+ function), RLS on/forced,
--     policies (USING / WITH CHECK), anon/authenticated table rights.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
t(tbl, ord) as (values ('students', 1), ('monthly_dues', 2), ('fee_payments', 3), ('beds', 4), ('bed_allocations', 5),
                       ('users', 6), ('user_hostel_assignments', 7), ('hostels', 8), ('roles', 9), ('audit_logs', 10), ('app_settings', 11)),
tt as (select t.tbl, t.ord, to_regclass('public.' || t.tbl)::oid as rid from t),
ec(tbl, col, origin) as (values   -- columns the repo expects (001 = base schema, 014/024 = migrations, NIR = live-only from 004-013)
  ('students','id','001'),('students','admission_number','001'),('students','full_name','001'),('students','father_name','001'),
  ('students','mother_name','001'),('students','mobile','001'),('students','parent_mobile','001'),('students','whatsapp','001'),
  ('students','email','001'),('students','course','001'),('students','batch','001'),('students','hostel_id','001'),
  ('students','current_bed_id','001'),('students','joining_date','001'),('students','exit_date','001'),('students','monthly_fee','001'),
  ('students','security_deposit','001'),('students','id_proof_type','001'),('students','id_proof_number','001'),('students','photo_url','001'),
  ('students','address','001'),('students','state','001'),('students','emergency_contact','001'),('students','medical_note','001'),
  ('students','created_at','001'),('students','updated_at','001'),('students','created_by','001'),('students','status','001'),
  ('students','fee_plan','014'),('students','plan_months','014'),('students','plan_amount','014'),('students','paid_till','014'),
  ('monthly_dues','id','001'),('monthly_dues','student_id','001'),('monthly_dues','hostel_id','001'),('monthly_dues','month','001'),
  ('monthly_dues','fee_amount','001'),('monthly_dues','discount','001'),('monthly_dues','paid_amount','001'),('monthly_dues','payable','001'),
  ('monthly_dues','pending','001'),('monthly_dues','created_at','001'),('monthly_dues','updated_at','001'),('monthly_dues','created_by','001'),
  ('monthly_dues','status','001'),('monthly_dues','period_from','NIR'),('monthly_dues','period_to','NIR'),('monthly_dues','paid_to','024'),
  ('fee_payments','id','001'),('fee_payments','due_id','001'),('fee_payments','student_id','001'),('fee_payments','hostel_id','001'),
  ('fee_payments','amount','001'),('fee_payments','payment_date','001'),('fee_payments','mode','001'),('fee_payments','transaction_id','001'),
  ('fee_payments','receipt_number','001'),('fee_payments','proof_url','001'),('fee_payments','collected_by','001'),('fee_payments','remarks','001'),
  ('fee_payments','created_at','001'),('fee_payments','created_by','001'),('fee_payments','status','001'),('fee_payments','period_from','NIR'),
  ('fee_payments','period_to','NIR'),('fee_payments','discount_amount','014'),('fee_payments','advance_group_id','014'),
  ('beds','id','001'),('beds','hostel_id','001'),('beds','room_id','001'),('beds','bed_number','001'),('beds','bed_status','001'),
  ('beds','student_id','001'),('beds','joining_date','001'),('beds','monthly_fee','001'),('beds','created_at','001'),('beds','updated_at','001'),
  ('beds','created_by','001'),('beds','status','001'),
  ('users','id','001'),('users','full_name','001'),('users','email','001'),('users','phone','001'),('users','role_id','001'),
  ('users','is_active','001'),('users','created_at','001'),('users','updated_at','001'),('users','created_by','001'),('users','status','001'),
  ('users','requested_hostel_id','NIR'),
  ('audit_logs','id','001'),('audit_logs','user_id','001'),('audit_logs','action','001'),('audit_logs','entity_type','001'),
  ('audit_logs','entity_id','001'),('audit_logs','before','001'),('audit_logs','after','001'),('audit_logs','created_at','001')
),
lc as (   -- live columns
  select tt.tbl, tt.ord, a.attnum, a.attname as col,
         format_type(a.atttypid, a.atttypmod) || case when a.attnotnull then ' NOT NULL' else '' end as typ,
         case when a.attgenerated = 's' then 'GENERATED ' || pg_get_expr(d.adbin, d.adrelid)
              when d.adbin is not null then 'default ' || pg_get_expr(d.adbin, d.adrelid) else '' end
         || case when a.attidentity <> '' then ' identity' else '' end as dflt
  from tt join pg_attribute a on a.attrelid = tt.rid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
)
select tbl, kind, name,
       regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(detail,
       '(\mbearer\s+)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
       'eyJ[A-Za-z0-9._-]{16,}', 'eyJ***MASKED***', 'g'),
       '\m(sb_secret_|sk_live_|rk_live_|EAA)[A-Za-z0-9_-]{8,}', '\1***MASKED***', 'g'),
       '(\m(api_?key|x-api-key|service_?role(_?key)?|secret|secret_?key|password|passwd|pwd|token|access_?token|auth_?token)\M["'']?\s*(:=|=>|:|=|,)\s*["'']?)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
       '(://[^:/@\s''"]+:)[^@\s''"]+@', '\1***MASKED***@', 'g'),
       '(\m(apikey|authorization)["'']?\s*(:|=|,)\s*["'']?)[^"''\s,}]{12,}', '\1***MASKED***', 'gi') as detail,   -- secrets (webhook / http headers) masked
       note from (
  -- table: exists, RLS flags, rights of the API roles
  select tt.ord, 0 as k, 0 as sub, tt.tbl, '0 table' as kind, tt.tbl as name,
         case when tt.rid is null then 'MISSING'
              else 'rls_enabled=' || c.relrowsecurity || ' rls_forced=' || c.relforcerowsecurity || ' est_rows=' || greatest(c.reltuples, 0)::bigint end as detail,
         case when tt.rid is null then null else
           'anon: ' || coalesce(nullif(concat_ws('', case when has_table_privilege('anon', tt.rid, 'SELECT') then 'S' end,
                                              case when has_table_privilege('anon', tt.rid, 'INSERT') then 'I' end,
                                              case when has_table_privilege('anon', tt.rid, 'UPDATE') then 'U' end,
                                              case when has_table_privilege('anon', tt.rid, 'DELETE') then 'D' end,
                                              case when has_table_privilege('anon', tt.rid, 'TRUNCATE') then 'T' end), ''), '-')
           || ' | authenticated: ' || coalesce(nullif(concat_ws('', case when has_table_privilege('authenticated', tt.rid, 'SELECT') then 'S' end,
                                              case when has_table_privilege('authenticated', tt.rid, 'INSERT') then 'I' end,
                                              case when has_table_privilege('authenticated', tt.rid, 'UPDATE') then 'U' end,
                                              case when has_table_privilege('authenticated', tt.rid, 'DELETE') then 'D' end,
                                              case when has_table_privilege('authenticated', tt.rid, 'TRUNCATE') then 'T' end), ''), '-')
           || ' (S=select I=insert U=update D=delete T=truncate)' end as note
  from tt left join pg_class c on c.oid = tt.rid
  -- columns, compared with the repo
  union all
  select coalesce(lc.ord, (select ord from t where t.tbl = ec.tbl)), 1, coalesce(lc.attnum, 999), coalesce(lc.tbl, ec.tbl), '1 column', coalesce(lc.col, ec.col),
         coalesce(lc.typ || case when lc.dflt <> '' then ' | ' || lc.dflt else '' end, '(absent)'),
         case when lc.col is null and ec.origin = 'NIR' then 'MISSING on live (app uses it; expected from 004-013)'
              when lc.col is null then 'MISSING on live (repo ' || ec.origin || ')'
              when ec.col is null and lc.tbl in (select distinct tbl from ec) then 'EXTRA: live-only column'
              when ec.origin = 'NIR' then 'present (from 004-013, not in repo)'
              when ec.col is null then '(not compared)'
              else 'repo ' || ec.origin end
  from lc full join ec on ec.tbl = lc.tbl and ec.col = lc.col
  where coalesce(lc.tbl, ec.tbl) in (select tbl from tt where rid is not null)
  -- constraints (PK / UNIQUE / CHECK / FK going OUT of the table)
  union all
  select tt.ord, 2, 0, tt.tbl, '2 constraint ' || case co.contype when 'p' then 'PK' when 'u' then 'UNIQUE' when 'c' then 'CHECK' when 'f' then 'FK' when 'x' then 'EXCLUDE' else co.contype::text end,
         co.conname, pg_get_constraintdef(co.oid),
         case when co.contype = 'f' then 'on delete ' || case co.confdeltype when 'c' then 'CASCADE' when 'n' then 'SET NULL' when 'r' then 'RESTRICT' when 'd' then 'SET DEFAULT' else 'NO ACTION' end end
  from tt join pg_constraint co on co.conrelid = tt.rid
  -- FKs from OTHER tables pointing INTO this table (what a delete does)
  union all
  select tt.ord, 3, 0, tt.tbl, '3 fk_into', co.conrelid::regclass::text || ' -> ' || co.conname, pg_get_constraintdef(co.oid),
         'on delete ' || case co.confdeltype when 'c' then 'CASCADE' when 'n' then 'SET NULL' when 'r' then 'RESTRICT' when 'd' then 'SET DEFAULT' else 'NO ACTION' end
  from tt join pg_constraint co on co.confrelid = tt.rid and co.contype = 'f' and co.conrelid <> tt.rid
  where tt.tbl in ('students', 'monthly_dues', 'users', 'hostels', 'beds')
  -- indexes
  union all
  select tt.ord, 4, 0, tt.tbl, '4 index', i.indexrelid::regclass::text, pg_get_indexdef(i.indexrelid),
         case when i.indisunique then 'UNIQUE' else '' end
  from tt join pg_index i on i.indrelid = tt.rid
  -- triggers
  union all
  select tt.ord, 5, 0, tt.tbl, '5 trigger', tg.tgname, pg_get_triggerdef(tg.oid),
         'enabled=' || case tg.tgenabled when 'O' then 'yes' when 'D' then 'DISABLED' when 'R' then 'replica-only' when 'A' then 'always' else tg.tgenabled::text end
         || ' fn=' || tg.tgfoid::regprocedure::text
         || ' fp=' || coalesce((select md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc p where p.oid = tg.tgfoid), '?')
  from tt join pg_trigger tg on tg.tgrelid = tt.rid and not tg.tgisinternal
  -- RLS policies
  union all
  select tt.ord, 6, 0, tt.tbl, '6 policy', po.policyname,
         po.cmd || ' ' || po.permissive || ' to ' || array_to_string(po.roles, ',') || ' USING (' || coalesce(po.qual, '-') || ')',
         'WITH CHECK (' || coalesce(po.with_check, case when po.cmd in ('ALL', 'UPDATE') then 'none -> same as USING' else '-' end) || ')'
  from tt join pg_policies po on po.schemaname = 'public' and po.tablename = tt.tbl
  -- column-level rights that matter for privilege escalation
  union all
  select tt.ord, 7, 0, tt.tbl, '7 column right', 'authenticated UPDATE ' || x.col,
         case when exists (select 1 from pg_attribute a where a.attrelid = tt.rid and a.attname = x.col and not a.attisdropped)
              then has_column_privilege('authenticated', tt.rid, x.col, 'UPDATE')::text else '(no such column)' end,
         'true + a users self-update policy = a user can change own ' || x.col
  from tt cross join (values ('role_id'), ('status'), ('is_active')) x(col)
  where tt.tbl = 'users' and tt.rid is not null
) z
order by ord, k, sub, kind, name;
