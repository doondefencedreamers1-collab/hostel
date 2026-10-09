-- DDD Hostel - Phase 0 diagnostic - file Q1 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q1.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q1] =================================================================
-- Q1  ENVIRONMENT + KAUN SI MIGRATIONS LIVE PAR CHALI + FUNCTION FINGERPRINTS
--     Dikhata hai: Postgres version, IST time, kitni rows dikh rahi hain,
--     backup_0XX schemas (= kaun si migration ka backup step chala, kab),
--     har migration 014..024 ka "probe" (object hai ya nahi), har public
--     function ka fingerprint vs repo, aur agla free migration number.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
ex(fn, mig, efp, esd, eanon, eauth) as (values   -- repo LATEST version of every function (001..024) + expected rights
  ('audit_trigger()', '002 (+022 revoke)', '5c2dcf9dc53d8551643b21eb30b4a19f', true, false, false),
  ('auth_role()', '002 (+022 search_path)', '888ba05f2c16c94fa8024390d28a459c', true, true, true),
  ('compute_paid_till(uuid)', '014', '48e0dacf0cd2016a6843d1429542a8cc', true, false, false),
  ('compute_paid_till(uuid,date,numeric)', '024', '6e684ed7aad00f5128de11cb0c32f58b', true, false, false),
  ('dashboard_summary(date,date,uuid)', '020', 'ca1a205f641a06e99b6aab41d2293fd3', true, false, true),
  ('ddd_advance_available(uuid,uuid)', '018', '1270b20d21a37021ac424d082f74a411', true, false, false),
  ('ddd_cum_fee(numeric,integer,integer)', '024', '1a3c57fdef372f9c7a155711e0bba14b', false, false, false),
  ('ddd_due_full_fee(date,date,numeric,numeric)', '024', '7d3f9f757b573feefa20744e919675ba', false, false, false),
  ('ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)', '024', '00aad42d12d7d5491f7982a117dedb54', false, false, false),
  ('ddd_dues_recompute_paid_till()', '014', 'cc5ac232cfe2373449912c080f159013', true, false, false),
  ('ddd_dues_set_paid_to()', '024', '4540a28a7b993d35e0d73b93944bfe31', true, false, false),
  ('ddd_employee_has_salary(uuid)', '018', '0c969c550394b8a42c15a751a4249e14', true, false, true),
  ('ddd_employee_profile()', '018', '55564eba8ef2d7f16c03e42fb1e47d08', true, false, false),
  ('ddd_fee_range_plan(uuid,date,date)', '024 (0bb3a05)', 'fef2cbbe57a653a64682250c53e7d35b', true, false, false),
  ('ddd_guard_due_delete()', '022', '7c31fc7b7ecd0b32cfbaa76901497eba', false, true, true),
  ('ddd_guard_due_discount()', '015', '42f3c19c974925c0f1ded42f2e6e41a1', false, true, true),
  ('ddd_guard_employee_delete()', '018', 'b227d0f857393eef3b7109781d65b045', false, true, true),
  ('ddd_guard_payment_delete()', '014', '004ffe8bbef9c2f0a89e73380adf48b4', false, true, true),
  ('ddd_guard_payment_discount()', '014', '9c0ec17331e51b3f5a20ab4ba7ddc470', false, true, true),
  ('ddd_guard_payment_write()', '015', 'd32b543d0e24e403c4722b5d91feaeea', false, true, true),
  ('ddd_guard_salary_write()', '018', 'dc9ab043b96f41b28c2b765b55d03419', false, true, true),
  ('ddd_guard_student_delete()', '022', 'c94fe44ed5915c14ed997046fe4e0f02', false, true, true),
  ('ddd_is_api_caller()', '014', '7fb724d0032326ff73359c2861c3bef3', false, true, true),
  ('ddd_m21_cols(regclass,text[])', '021', '126c5cf3637f5832657b9a36d1ba8707', false, false, false),
  ('ddd_m21_del(uuid,integer,regclass,jsonb)', '021', '33adbf016a12bc2a18a97215bc14a664', false, false, false),
  ('ddd_m21_log(uuid,integer,text,text,jsonb,text,uuid,jsonb)', '021', 'c86f6640532b9bfcac75398ed2ac5a1d', false, false, false),
  ('ddd_m21_merge_one(uuid,integer,text,uuid,uuid)', '021', '464eddbe9aceca275ac4a8de171eb020', false, false, false),
  ('ddd_m21_pk(regclass)', '021', '0c591cf9891d8dd1d94dfe8899ee4105', false, false, false),
  ('ddd_m21_where(jsonb)', '021', '98c030660536c7ff1f73c375c9ba7dde', false, false, false),
  ('ddd_merge_duplicates(jsonb,boolean)', '021', '78f8e784079f80354958295e42695599', false, false, false),
  ('ddd_merge_undo(uuid)', '021', '8e7b5e8b7c6fa2f47b8523cf87057717', false, false, false),
  ('ddd_month_fee(numeric,date,date)', '017', 'ce0718798846b2d7741d076f715b7886', false, true, true),
  ('ddd_period_numbers(date,date,boolean,uuid[],boolean)', '020', '73ccf7156242b084c78e8846e83dba97', true, false, false),
  ('ddd_pf(numeric)', '018', '63e13aa42be50ff1f2f4214d8911317a', true, false, false),
  ('ddd_prev_period(date,date)', '020', 'c247b5afa37b4c42f020572c85e2ae87', false, false, true),
  ('ddd_require_director()', '018 (+022)', 'b83839c75c1b58fe87608fadcaa344f5', true, false, true),
  ('ddd_setting_num(text,numeric)', '018', 'c97b079d4d9edb6f402f7c461636b22e', true, false, false),
  ('ddd_students_fee_plan()', '014', '4d4f6320528b525a510a25d67a702282', false, true, true),
  ('ddd_students_recompute_paid_till()', '014', '0bfdec6e929a054388b08e2789270206', true, false, false),
  ('delete_fee_payment(uuid)', '014', '9f4b70c5afe489837501a4c704beb944', true, false, true),
  ('edit_fee_payment_dates(uuid,date,date,text)', '024', 'd2a8b81b277329635f8d198d20743c1e', true, false, true),
  ('generate_anniversary_dues(date)', '014 (+017 revoke)', '02293c687df8f4ada79b074ab4621c47', true, false, false),
  ('generate_monthly_dues(date)', '022', '6ea13bd087be181629f4f770132473a6', true, false, true),
  ('generate_salary(date)', '019 (+023a)', '37c43f0dad716617e3d3cb53825df9bd', true, false, true),
  ('is_accountant()', '002 (+022 search_path)', 'df0b56feb01e46630397f19b3448b26e', true, true, true),
  ('is_director()', '002 (+022 search_path)', '986cb4bc7b7f3c5303dcb80a5cfefaf5', true, true, true),
  ('my_hostels()', '002 (+022 search_path)', '14801268f54668aa8e4857a0cf4ee983', true, true, true),
  ('on_student_left()', '001', '85c94bbe86f06cc1c86b9e5f8ee3d528', false, true, true),
  ('recompute_paid_till(uuid)', '014', 'b4504045a44ea6b3b0e644b33985b5c0', true, false, false),
  ('record_fee_payment(uuid,integer,numeric,numeric,text,date,text,text,uuid)', '024', '604cea18ee3961a8352594843fd1d453', true, false, true),
  ('record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)', '024', '27fe0313dea077cb0145f361fc191965', true, false, true),
  ('record_partial_payment(uuid,numeric,text,date,text,text,uuid)', '024', '0f5448386686707469fa96c4b2e5e645', true, false, true),
  ('salary_edit(uuid,numeric,numeric,numeric,numeric,boolean,text,text)', '018', '8985ea481182d5e72bec9e3fc288b44a', true, false, true),
  ('salary_pay(uuid,date,text,text,text)', '019', 'e31f01b6e1ceeced4718f914747019d3', true, false, true),
  ('salary_pay_all(date,date,text,uuid)', '018', '427811b2c1d523d1df978ac42b845180', true, false, true),
  ('salary_undo_payment(uuid,text)', '018', 'fc7eeeed49f03e8764edba603910991b', true, false, true),
  ('set_updated_at()', '001', 'd258fba5feeb9ce8126471bef81c3228', false, true, true),
  ('handle_new_user()', '022 drops it', null, null, null, null),
  ('approve_warden(uuid,uuid)', 'not in repo (004-013)', null, null, null, null),
  ('reject_warden(uuid)', 'not in repo (004-013)', null, null, null, null),
  ('remove_warden(uuid)', 'not in repo (004-013)', null, null, null, null),
  ('pending_wardens()', 'not in repo (004-013)', null, null, null, null),
  ('hostels_for_signup()', 'not in repo (004-013)', null, null, null, null),
  ('handle_new_signup()', 'not in repo (004-013)', null, null, null, null)
),
kv(fn, fp, label) as (values   -- OLDER repo versions (and equivalent texts) of the same functions
  ('generate_monthly_dues(date)', 'f1549528a62bae05bdcfd73d64935c55', 'OLD = 017 version (022 not on live?)'),
  ('generate_monthly_dues(date)', '2b53a53b5d498de2eac100dfe6b9178f', 'OLD = pre-017 live version'),
  ('generate_monthly_dues(date)', '44a1c95f9a3ab80b41b8aec90043f0fb', 'OLD = 001 version'),
  ('record_fee_payment(uuid,integer,numeric,numeric,text,date,text,text,uuid)', '35422694e51971f79ef6aa415f67af65', 'OLD = 017 version (024 not on live?)'),
  ('record_fee_payment(uuid,integer,numeric,numeric,text,date,text,text,uuid)', '5c6b60b5d264f03dccd5d2744b9a9b75', 'OLD = 014 version'),
  ('record_partial_payment(uuid,numeric,text,date,text,text,uuid)', 'c778c5ffd054b7b62d2ed3524e0318f3', 'OLD = 017 version (024 not on live?)'),
  ('record_partial_payment(uuid,numeric,text,date,text,text,uuid)', 'c77aa13aff53fcd2f079171ae2edaf8d', 'OLD = 016 version'),
  ('ddd_fee_range_plan(uuid,date,date)', 'd83a3c99c3344a66547dcdf897ee304d', 'OLD = 6271314 text (before 0bb3a05 rename) - same logic'),
  ('compute_paid_till(uuid,date,numeric)', '3a7fe7e6126470441ebb723142fa4ce7', 'OLD = 017 version (024 not on live?)'),
  ('compute_paid_till(uuid,date,numeric)', 'fb710a2eb5ea7f8959bf252fc46c8211', 'OLD = 014 version'),
  ('ddd_guard_student_delete()', '2b0b5e45b061c3c9cb4afbd7c8ce3365', 'OLD = 014 version (022 not on live?)'),
  ('ddd_guard_due_delete()', '5d220ee83ff28f8710fdd5741110a3b3', 'OLD = 014 version (022 not on live?)'),
  ('ddd_guard_due_discount()', 'e915f1784874a1091e56dc5473f4c186', 'OLD = 014 version (015 NOT applied)'),
  ('generate_salary(date)', 'a4fee1df00d191ee7b3c32e06b95f0fa', 'OK-equivalent = 019 (acd1033) + 023a patch (expected live text)'),
  ('generate_salary(date)', '4c747584c84a1c468513af9623b43d3e', 'OLD = 019 (acd1033) WITHOUT 023a patch'),
  ('generate_salary(date)', '2c2086a862b41d253993276a55748b94', 'OLD = 018 version'),
  ('salary_pay(uuid,date,text,text,text)', '3a239532c2c80eeeb14c9c7ba3323d67', 'OK-equivalent = 019 (acd1033) text'),
  ('salary_pay(uuid,date,text,text,text)', 'b5520ee876b4d982efa0a34c54543dcf', 'OLD = 018 version'),
  ('handle_new_user()', '47db4c0bf84028a8671917110cba1756', '= 002 version')
),
live as (
  select p.oid, p.proname || '(' || replace(oidvectortypes(p.proargtypes), ' ', '') || ')' as fn,
         p.prosecdef as sd, p.prorettype = 'trigger'::regtype as is_trg,
         has_function_privilege('anon', p.oid, 'execute') as anon_x,
         has_function_privilege('authenticated', p.oid, 'execute') as auth_x,
         md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as fp,
         count(*) over (partition by p.proname) as n_over
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace and p.prokind in ('f', 'p')
    and not exists (select 1 from pg_depend d where d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e')
),
fx as (
  select coalesce(e.fn, l.fn) as fn, e.mig, e.efp, e.esd, e.eanon, e.eauth,
         l.oid, l.fp, l.sd, l.anon_x, l.auth_x, l.is_trg, l.n_over
  from ex e full join live l on l.fn = e.fn
),
mig(m, probe, ok) as (values
  ('014', 'students.paid_till column', exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.students') and a.attname = 'paid_till' and not a.attisdropped)),
  ('014', 'delete_fee_payment(uuid)', to_regprocedure('public.delete_fee_payment(uuid)') is not null),
  ('014', 'trigger trg_students_fee_plan', exists (select 1 from pg_trigger t where t.tgrelid = to_regclass('public.students') and t.tgname = 'trg_students_fee_plan')),
  ('015', 'trigger trg_fee_payments_write_guard', exists (select 1 from pg_trigger t where t.tgrelid = to_regclass('public.fee_payments') and t.tgname = 'trg_fee_payments_write_guard')),
  ('015', 'ddd_guard_due_discount() = 015 text', exists (select 1 from live where fn = 'ddd_guard_due_discount()' and fp = '42f3c19c974925c0f1ded42f2e6e41a1')),
  ('016', 'record_partial_payment(...)', to_regprocedure('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)') is not null),
  ('017', 'ddd_month_fee(numeric,date,date)', to_regprocedure('public.ddd_month_fee(numeric,date,date)') is not null),
  ('017', 'generate_anniversary_dues NOT callable by app', case when to_regprocedure('public.generate_anniversary_dues(date)') is not null
                                                                    then not has_function_privilege('authenticated', to_regprocedure('public.generate_anniversary_dues(date)'), 'execute') end),
  ('017a', 'schema backup_017a', to_regnamespace('backup_017a') is not null),
  ('017b', '(no artifact - cannot be detected)', null::boolean),
  ('018', 'table salary_runs', to_regclass('public.salary_runs') is not null),
  ('019', 'salary_runs.absent_days column', exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.salary_runs') and a.attname = 'absent_days' and not a.attisdropped)),
  ('020', 'dashboard_summary(date,date,uuid)', to_regprocedure('public.dashboard_summary(date,date,uuid)') is not null),
  ('020', 'index ddd_020_monthly_dues_month', to_regclass('public.ddd_020_monthly_dues_month') is not null),
  ('021', 'ddd_merge_duplicates(jsonb,boolean)', to_regprocedure('public.ddd_merge_duplicates(jsonb,boolean)') is not null),
  ('021', 'table backup_021.merge_log', exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'backup_021' and c.relname = 'merge_log')),
  ('022', 'generate_monthly_dues NOT callable by anon', not has_function_privilege('anon', to_regprocedure('public.generate_monthly_dues(date)'), 'execute')),
  ('022', 'generate_monthly_dues = 022 text', exists (select 1 from live where fn = 'generate_monthly_dues(date)' and fp = '6ea13bd087be181629f4f770132473a6')),
  ('022', 'handle_new_user() dropped', to_regprocedure('public.handle_new_user()') is null),
  ('022', 'fee_payments.student_id FK = NO ACTION', exists (select 1 from pg_constraint c where c.conrelid = to_regclass('public.fee_payments') and c.contype = 'f' and c.confrelid = to_regclass('public.students') and c.confdeltype = 'a')),
  ('023a', 'generate_salary has month-end guard', coalesce(pg_get_functiondef(to_regprocedure('public.generate_salary(date)')), '') like '%m_start >= date_trunc%'),
  ('024', 'record_fee_payment_range(...)', to_regprocedure('public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)') is not null),
  ('024', 'monthly_dues.paid_to column', exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.monthly_dues') and a.attname = 'paid_to' and not a.attisdropped)),
  ('024', 'table fee_payment_edits', to_regclass('public.fee_payment_edits') is not null),
  ('024', 'trigger trg_monthly_dues_paid_to', exists (select 1 from pg_trigger t where t.tgrelid = to_regclass('public.monthly_dues') and t.tgname = 'trg_monthly_dues_paid_to')),
  ('024', 'record_fee_payment = 024 text', exists (select 1 from live where fn = 'record_fee_payment(uuid,integer,numeric,numeric,text,date,text,text,uuid)' and fp = '604cea18ee3961a8352594843fd1d453'))
),
bk as (   -- every table inside a backup* schema (catalog only: works even without USAGE on the schema)
  select n.nspname, c.oid, c.relname,
         has_schema_privilege(n.oid, 'USAGE') as ns_usage,
         has_schema_privilege(n.oid, 'USAGE') and has_table_privilege(c.oid, 'SELECT') as can_read,
         (select a.attname from pg_attribute a where a.attrelid = c.oid and a.attname in ('saved_at', 'applied_at') and not a.attisdropped order by a.attname desc limit 1) as tcol,
         (select string_agg(format('max(%I)', a.attname), ', ' order by a.attname) from pg_attribute a
           where a.attrelid = c.oid and a.attname in ('created_at', 'updated_at') and a.atttypid = 'timestamptz'::regtype and not a.attisdropped) as scols,
         exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'k' and not a.attisdropped) as has_k
  from pg_namespace n join pg_class c on c.relnamespace = n.oid and c.relkind in ('r', 'p')
  where n.nspname like 'backup%'
),
nums as (   -- migration numbers already used on live (backup schemas + object names)
  select substring(n.nspname from 'backup_0*([0-9]+)')::int as num, 'schema ' || n.nspname as obj
  from pg_namespace n where n.nspname ~ '^backup_[0-9]+'
  union all
  select substring(c.relname from '(?:^|_)0([0-9]{2})(?:_|$)')::int, 'object ' || c.relname
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname ~ '(^|_)0[0-9]{2}(_|$)'
  union all
  select substring(p.proname from '(?:^|_)0([0-9]{2})(?:_|$)')::int, 'function ' || p.proname
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '(^|_)0[0-9]{2}(_|$)'
)
select sec, item, live_value, expected, verdict from (
  -- ---------- 0. environment ----------
  select '0 env' as sec, 1 as ord, 'postgres version' as item, version() as live_value, null::text as expected, null::text as verdict
  union all select '0 env', 2, 'now (IST)', ((now() at time zone 'Asia/Kolkata')::timestamp(0))::text, null, null
  union all select '0 env', 3, 'today (IST)', ((now() at time zone 'Asia/Kolkata')::date)::text, '2026-10-09 (approx)', null
  union all select '0 env', 4, 'session_user / current_user / db', session_user || ' / ' || current_user || ' / ' || current_database(), 'postgres (SQL Editor)', null
  union all select '0 env', 5, 'TimeZone / statement_timeout', current_setting('TimeZone') || ' / ' || current_setting('statement_timeout'), null, null
  union all select '0 env', 6, 'rows visible to this query',
         'students=' || (select count(*) from students) || ' monthly_dues=' || (select count(*) from monthly_dues)
         || ' fee_payments=' || (select count(*) from fee_payments) || ' audit_logs=' || (select count(*) from audit_logs)
         || ' users=' || (select count(*) from users) || ' hostels=' || (select count(*) from hostels),
         'students ~1000', case when (select count(*) from students) = 0 then 'ZERO students visible - RLS FORCED? results below are useless' else 'ok' end
  union all select '0 env', 7, 'tables with FORCE RLS (owner also filtered)',
         coalesce((select string_agg(c.relname, ', ') from pg_class c where c.relnamespace = 'public'::regnamespace and c.relforcerowsecurity), '(none)'), '(none)', null
  union all select '0 env', 8, 'audit_logs coverage (IST)',
         coalesce((select min((l.created_at at time zone 'Asia/Kolkata')::timestamp(0))::text || ' .. ' || max((l.created_at at time zone 'Asia/Kolkata')::timestamp(0))::text from audit_logs l), '(empty)'),
         'should start ~June 2026', null
  union all select '0 env', 9, 'audit_logs rows by table/action',
         (select string_agg(x, ', ' order by x) from (select coalesce(l.entity_type, '?') || '.' || coalesce(l.action, '?') || '=' || count(*) as x from audit_logs l group by l.entity_type, l.action) a), null, null
  union all select '0 env', 10, 'extensions', (select string_agg(e.extname || ' ' || e.extversion || ' @' || n.nspname, ', ' order by e.extname) from pg_extension e join pg_namespace n on n.oid = e.extnamespace), null,
         case when exists (select 1 from pg_extension where extname = 'pg_cron') then 'pg_cron INSTALLED - see Q4 cron rows' else 'no pg_cron' end
  union all select '0 env', 11, 'app_settings (key=value)',
         case when to_regclass('public.app_settings') is null then 'TABLE MISSING'
              when not has_table_privilege(to_regclass('public.app_settings'), 'SELECT') then 'no permission'
              else regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(convert_from(decode((xpath('/row/v/text()', query_to_xml(
           'select encode(convert_to(string_agg(coalesce(to_jsonb(a)->>''key'', ''?'') || ''='' || coalesce(to_jsonb(a)->>''value'', ''NULL''), ''; '' order by to_jsonb(a)->>''key''), ''UTF8''), ''hex'') as v from public.app_settings a',
           false, true, '')))[1]::text, 'hex'), 'UTF8'),
           '(\mbearer\s+)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
           'eyJ[A-Za-z0-9._-]{16,}', 'eyJ***MASKED***', 'g'),
           '\m(sb_secret_|sk_live_|rk_live_|EAA)[A-Za-z0-9_-]{8,}', '\1***MASKED***', 'g'),
           '(\m(api_?key|x-api-key|service_?role(_?key)?|secret|secret_?key|password|passwd|pwd|token|access_?token|auth_?token)\M["'']?\s*(:=|=>|:|=|,)\s*["'']?)[A-Za-z0-9._~+/=-]{12,}', '\1***MASKED***', 'gi'),
           '(://[^:/@\s''"]+:)[^@\s''"]+@', '\1***MASKED***@', 'g'),
           '(\m(apikey|authorization)["'']?\s*(:|=|,)\s*["'']?)[^"''\s,}]{12,}', '\1***MASKED***', 'gi') end,
         'billing_mode=calendar; fee_grace_days=0; pf_*', null
  union all select '0 env', 12, 'hostels (code: students active/total)',
         (select string_agg(h.code || ': ' || (select count(*) filter (where s.status = 'active') || '/' || count(*) from students s where s.hostel_id = h.id), ', ' order by h.code) from hostels h), null, null
  -- ---------- 1. migration probes ----------
  union all
  select '1 migration', 100 + row_number() over (), m || ': ' || probe,
         case when ok is null then '?' when ok then 'yes' else 'NO' end, 'yes',
         case when ok is null then 'cannot tell' when ok then 'applied' else 'NOT applied / changed on live' end
  from mig
  -- ---------- 2. backup schemas (created by the *_run_checks STEP 2 / migrations) ----------
  union all
  select '2 backup', 200, bk.nspname || '.' || bk.relname,
         case when not bk.ns_usage then 'no USAGE on schema ' || bk.nspname || ' (cannot read)'
              when not bk.can_read then 'no permission'
              else 'rows=' || (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from %I.%I', bk.nspname, bk.relname), false, true, '')))[1]::text end,
         case when bk.can_read and bk.tcol is not null then
                bk.tcol || ' (IST): ' || coalesce((xpath('/row/t/text()', query_to_xml(format(
                  'select (min(%1$I) at time zone ''Asia/Kolkata'')::timestamp(0)::text || '' .. '' || (max(%1$I) at time zone ''Asia/Kolkata'')::timestamp(0)::text as t from %2$I.%3$I',
                  bk.tcol, bk.nspname, bk.relname), false, true, '')))[1]::text, '-')
              when bk.can_read and bk.scols is not null then   -- CREATE TABLE AS copies (014/017/018/021 *_before) have no saved_at
                'snapshot taken AFTER (IST): ' || coalesce((xpath('/row/t/text()', query_to_xml(format(
                  'select (greatest(%s) at time zone ''Asia/Kolkata'')::timestamp(0)::text as t from %I.%I',
                  bk.scols, bk.nspname, bk.relname), false, true, '')))[1]::text, '- (empty copy)') || ' = newest created_at/updated_at inside the copy' end,
         case when bk.can_read and bk.has_k then
                'keys: ' || coalesce(convert_from(decode((xpath('/row/v/text()', query_to_xml(format(
                  'select encode(convert_to(left(string_agg(k::text, '', '' order by k::text), 900), ''UTF8''), ''hex'') as v from %I.%I', bk.nspname, bk.relname), false, true, '')))[1]::text, 'hex'), 'UTF8'), '-') end
  from bk
  union all
  select '2 backup', 201, '(no backup* schema at all)', 'none', 'backup_014 ... backup_024', 'run_checks backups never ran?'
  where not exists (select 1 from pg_namespace where nspname like 'backup%')
  -- ---------- 3. function fingerprints (md5 of body without -- comments and whitespace, same as 024) ----------
  union all
  select '3 function', 300, fx.fn,
         case when fx.oid is null then '(absent)'
              else fx.fp || case when fx.is_trg then ' trigger-fn' else ' ' || case when fx.sd then 'DEFINER' else 'invoker' end || ' anon=' || fx.anon_x || ' auth=' || fx.auth_x end end,
         case when fx.mig is null then '(not in repo)'
              when fx.efp is null then fx.mig
              else fx.efp || case when fx.is_trg then '' else ' ' || case when fx.esd then 'DEFINER' else 'invoker' end || ' anon=' || fx.eanon || ' auth=' || fx.eauth end || ' [' || fx.mig || ']' end,
         case
           when fx.mig is null then 'EXTRA: live-only function (not in repo 001-024)'
           when fx.mig = '022 drops it' then case when fx.oid is null then 'OK (dropped)' else 'STILL PRESENT (022 drops it only if no trigger uses it)' end
           when fx.efp is null then case when fx.oid is null then 'MISSING (app calls it?)' else 'present (not in repo, cannot compare)' end
           when fx.oid is null then 'MISSING on live'
           when fx.fp = fx.efp then 'OK = repo latest'
           else coalesce((select kv.label from kv where kv.fn = fx.fn and kv.fp = fx.fp), 'DIFFERENT from every repo version (edited on live?)')
         end
         || case when fx.oid is not null and fx.efp is not null and not fx.is_trg
                      and (fx.sd is distinct from fx.esd or fx.anon_x is distinct from fx.eanon or fx.auth_x is distinct from fx.eauth)
                 then ' | RIGHTS/DEFINER DIFFER from repo' else '' end
         || case when fx.n_over > (select count(*) from ex e2 where split_part(e2.fn, '(', 1) = split_part(fx.fn, '(', 1) and e2.efp is not null)
                      and fx.n_over > 1
                 then ' | EXTRA OVERLOAD: ' || fx.n_over || ' live functions share this name' else '' end
  from fx
  -- ---------- 4. next free migration number ----------
  union all select '4 next migration', 400, 'highest number in repo files', '024', null, null
  union all select '4 next migration', 401, 'numbers used on live (backup schemas / object names)',
         coalesce((select string_agg(distinct lpad(num::text, 3, '0'), ', ') from nums where num is not null), '(none)'), null, null
  union all select '4 next migration', 402, 'objects numbered 025 or higher',
         coalesce((select string_agg(obj, ', ') from nums where num >= 25), '(none)'), '(none)', null
  union all select '4 next migration', 403, 'supabase_migrations.schema_migrations',
         case when not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'supabase_migrations' and c.relname = 'schema_migrations')
                then '(table absent - migrations were run by hand)'
              when not coalesce((select has_schema_privilege(n.oid, 'USAGE') from pg_namespace n where n.nspname = 'supabase_migrations'), false)
                then 'no USAGE on schema supabase_migrations (cannot read)'
              when not has_table_privilege((select c.oid from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'supabase_migrations' and c.relname = 'schema_migrations'), 'SELECT')
                then 'no permission'
              else convert_from(decode((xpath('/row/v/text()', query_to_xml(
                'select encode(convert_to(count(*)::text || '' rows, last='' || coalesce(max(to_jsonb(m)->>''version''), ''-''), ''UTF8''), ''hex'') as v from supabase_migrations.schema_migrations m',
                false, true, '')))[1]::text, 'hex'), 'UTF8') end, null, null
  union all select '4 next migration', 404, 'SUGGESTED next free number',
         lpad((greatest(24, coalesce((select max(num) from nums where num < 900), 0)) + 1)::text, 3, '0'), '025', null
) z
order by sec, ord, item;
