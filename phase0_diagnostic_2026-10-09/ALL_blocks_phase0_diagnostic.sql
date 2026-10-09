-- =====================================================================
-- PHASE 0 DIAGNOSTIC  —  DDD Hostel (LIVE Supabase)   — 100% READ-ONLY
-- ---------------------------------------------------------------------
-- Yeh file sirf PADHTI hai (SELECT). Kuch bhi change / delete / insert
-- nahi hota. Koi app function (rpc) call nahi hota.
--
-- KAISE CHALAYEIN (Supabase -> SQL Editor):
--   SABSE AASAAN: alag files Q1.sql ... Q11.sql milengi. Har file ke liye:
--     "New query" (naya snippet) kholein -> POORI file paste karein -> "Run"
--     -> result ke upar "Export -> CSV" (ya Download CSV) -> naam Q1.csv,
--     Q2.csv ... rakhein. Saari 11 CSV files bhej dein.
--   (Agar yeh poori file use karni ho: ek block ko mouse se SELECT karein —
--    "-- [Q1]" wali line se agle "-- [Q2]" se pehle tak — phir Run.
--    Poori file ek saath Run karenge to sirf AAKHRI block ka result dikhega.)
--   Agar SQL Editor mein "Limit results" / row-limit ka option dikhe to
--   "No limit" chunein (Q2 ~300 rows, Q4 aur Q7 lambe ho sakte hain),
--   warna CSV adhoori aayegi.
--   Agar koi block error de, to error ka screenshot / text bhej dein —
--   baaki blocks phir bhi chalayein (har block alag hai).
--
-- SECRETS: Q1 / Q2 / Q4 mein code aur trigger dikhte hain. Usme koi key
--   (service_role key, "Bearer ...", "eyJ...", "sb_secret_...", password)
--   ho to woh apne-aap ***MASKED*** ho jaati hai. Phir bhi CSV bhejne se
--   pehle Ctrl+F se "eyJ", "Bearer", "sb_secret", "apikey" dhoondh lein —
--   agar ***MASKED*** ke bina koi lamba random code dikhe to pehle bata dein.
--
-- EK CHHOTA EXTRA TEST (optional, 1 minute, laptop par):
--   Live app ka link (jo wardens phone par kholte hain) laptop ke browser mein
--   kholein -> Ctrl+U (page source) -> Ctrl+F -> likhein:
--       Koi naya record NAHI bana
--   Batayein: MILA ya NAHI MILA, aur woh link (URL) kya hai.
--   (NAHI MILA = live par 29-Sep se purana app chal raha hai.)
--
-- BLOCKS:
--   Q1  Environment, kaun si migration chali (backup_0XX), function fingerprints, agla migration number
--   Q2  students / monthly_dues / fee_payments / beds / users ... ka live structure, triggers, policies
--   Q3  Saari tables: RLS on/off + har policy + anon/app rights (security picture)
--   Q4  Bill banane wala code (poora source), triggers, cron jobs, webhooks, purana saved source
--   Q5  Duplicate students (groups), same hostel aur cross-hostel
--   Q6  Audit log se saboot: Edit ke time naya student bana? (29-Sep hotfix se pehle / baad)
--   Q7  Chhode hue students ke galat bill (Oct-2026 upar), har bill ki wajah
--   Q8  Status ki safai: alag-alag status values, left bina exit_date, exit beet gayi par active, bed nahi chhuta
--   Q9  October 2026 ke bill kab / kaise / kiske login se bane
--   Q10 Dashboard / ledger par galat asar (hostel-wise rupaye)
--   Q11 App users: role, hostel, students add/edit ki ginti, access ke khatre
--
-- Saare dates IST (Asia/Kolkata) mein hain. "today" = aaj ki IST date.
-- Q5 (poore groups), Q6 detail aur Q8 ke har section max ~300 rows dete hain;
-- Q7 mein SAARE galat bill aate hain (lambi list ho sakti hai).
-- =====================================================================

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


-- [Q5] =================================================================
-- Q5  DUPLICATE STUDENTS (ek hi bachcha 2+ baar)
--     Naam milaya jaata hai chhote/bade akshar, space, dot, hyphen hata kar.
--     Saath mein: father name, ya koi phone (mobile / parent mobile /
--     whatsapp, aakhri 10 digit), ya admission no. bhi milna chahiye.
--     Alag naam par bhi: same mobile / same admission no. (naam badla?),
--     aur "created_at copy hua" (Edit form se naya record bana).
--     "weak" = sirf naam + same hostel (father khali ya alag, aur phone /
--     admission no. aapas mein takraate nahi) - haath se jaanchein.
--     Placeholder / sabka ek hi phone ya admission no. (9999999999, NA,
--     0 ...) matching mein NAHI liya jaata - upar "NOTE" rows mein dikhta hai.
--     Har group ke saare members ek-ek row mein: kisne / kab banaya, status,
--     dues / payments, bed. scope = SAME HOSTEL ya CROSS-HOSTEL (transfer?).
--     Sabse naya group sabse upar, max ~300 rows (poore groups).
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
ins as (   -- the real INSERT moment from the audit log (row created_at can be copied from another row)
  select distinct on (l.entity_id) l.entity_id as sid, l.created_at as at, l.user_id
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'insert'
  order by l.entity_id, l.created_at
),
s0 as (
  select x.id, x.full_name, x.father_name, x.mobile, x.parent_mobile, x.admission_number, x.hostel_id, x.status::text as status,
         x.joining_date, x.exit_date, x.monthly_fee, x.created_at, x.created_by, x.updated_at, x.current_bed_id,
         coalesce(nullif(regexp_replace(lower(coalesce(x.full_name, '')), '[^[:alnum:]]+', '', 'g'), ''), lower(trim(coalesce(x.full_name, '')))) as nk,
         regexp_replace(regexp_replace(lower(coalesce(x.father_name, '')), '^(\s*(mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''), '[^[:alnum:]]+', '', 'g') as fk0,
         right(regexp_replace(coalesce(x.mobile, ''), '[^0-9]', '', 'g'), 10) as mk0,
         right(regexp_replace(coalesce(x.parent_mobile, ''), '[^0-9]', '', 'g'), 10) as pk0,
         right(regexp_replace(coalesce(x.whatsapp, ''), '[^0-9]', '', 'g'), 10) as wk0,
         regexp_replace(lower(coalesce(x.admission_number, '')), '[^[:alnum:]]+', '', 'g') as ak0,
         i.at as ins_at, i.user_id as ins_user,
         case when i.user_id is not null and abs(extract(epoch from (i.at - x.created_at))) > 120
              then date_trunc('second', x.created_at) end as copied_ts   -- app insert with an older created_at = saved from an Edit form
  from students x left join ins i on i.sid = x.id
),
kv as (   -- every phone / admission no. with how many different names use it
  select 'phone' as kt, k.v, count(distinct s0.id) as n_students, count(distinct s0.nk) as n_names
  from s0 cross join lateral (select distinct v from unnest(array[s0.mk0, s0.pk0, s0.wk0]) u(v)) k
  where length(k.v) = 10 group by k.v
  union all
  select 'adm no', s0.ak0, count(*), count(distinct s0.nk) from s0 where s0.ak0 <> '' group by s0.ak0
),
bad as (   -- placeholder or shared keys: NOT used for matching
  select kv.kt, kv.v, kv.n_students, kv.n_names,
         case when kv.n_names > 3 then 'shared by ' || kv.n_names || ' different names' else 'placeholder value' end as why
  from kv
  where kv.n_names > 3
     or (kv.kt = 'phone' and (kv.v ~ '^(\d)\1{9}$' or kv.v in ('1234567890', '0123456789', '9876543210')))
     or (kv.kt = 'adm no' and (kv.v ~ '^(.)\1*$' or kv.v in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'test', 'pending', 'new', 'notknown', 'unknown', 'nodata', 'notavailable')))
),
s as (
  select s0.*,
         case when s0.fk0 ~ '^(.)\1*$' or s0.fk0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'notknown', 'unknown', 'nodata', 'notavailable', 'father') then '' else s0.fk0 end as fk,
         case when length(s0.mk0) = 10 and s0.mk0 not in (select v from bad where kt = 'phone') then s0.mk0 else '' end as mk,
         case when s0.ak0 <> '' and s0.ak0 not in (select v from bad where kt = 'adm no') then s0.ak0 else '' end as ak,
         coalesce((select array_agg(distinct v) from unnest(array[s0.mk0, s0.pk0, s0.wk0]) u(v)
                   where length(v) = 10 and v not in (select b.v from bad b where b.kt = 'phone')), '{}'::text[]) as ph
  from s0
),
cand as (   -- candidate pairs from equality joins (fast hash joins); all columns needed later are carried along (no re-join)
  select a.id as a_id, b.id as b_id, a.nk as a_nk, b.nk as b_nk, a.fk as a_fk, b.fk as b_fk, a.mk as a_mk, b.mk as b_mk, a.ak as a_ak, b.ak as b_ak,
         a.ph as a_ph, b.ph as b_ph, a.hostel_id as a_h, b.hostel_id as b_h,
         coalesce(a.copied_ts = date_trunc('second', b.created_at) or b.copied_ts = date_trunc('second', a.created_at), false) as copied
  from s a join s b on b.nk = a.nk and a.nk <> '' and a.id < b.id
  union all
  select a.id, b.id, a.nk, b.nk, a.fk, b.fk, a.mk, b.mk, a.ak, b.ak, a.ph, b.ph, a.hostel_id, b.hostel_id,
         coalesce(a.copied_ts = date_trunc('second', b.created_at) or b.copied_ts = date_trunc('second', a.created_at), false)
  from s a join s b on b.mk = a.mk and a.mk <> '' and a.id < b.id
  where not (a.nk <> '' and a.nk = b.nk)
  union all
  select a.id, b.id, a.nk, b.nk, a.fk, b.fk, a.mk, b.mk, a.ak, b.ak, a.ph, b.ph, a.hostel_id, b.hostel_id,
         coalesce(a.copied_ts = date_trunc('second', b.created_at) or b.copied_ts = date_trunc('second', a.created_at), false)
  from s a join s b on b.ak = a.ak and a.ak <> '' and a.id < b.id
  where not (a.nk <> '' and a.nk = b.nk) and not (a.mk <> '' and a.mk = b.mk)
  union all   -- a = app insert with a copied created_at, b = a row with exactly that created_at (any name)
  select a.id, b.id, a.nk, b.nk, a.fk, b.fk, a.mk, b.mk, a.ak, b.ak, a.ph, b.ph, a.hostel_id, b.hostel_id, true
  from s a join s b on date_trunc('second', b.created_at) = a.copied_ts and b.id <> a.id
  where not (a.nk <> '' and a.nk = b.nk) and not (a.mk <> '' and a.mk = b.mk) and not (a.ak <> '' and a.ak = b.ak)
),
pr as (
  select least(c.a_id, c.b_id) as a_id, greatest(c.a_id, c.b_id) as b_id,
         concat_ws(' + ',
           case when x.nm and c.a_fk <> '' and c.a_fk = c.b_fk then 'name+father' end,
           case when x.nm and c.a_mk <> '' and c.a_mk = c.b_mk then 'name+mobile' end,
           case when x.nm and x.ph_overlap and not (c.a_mk <> '' and c.a_mk = c.b_mk) then 'name+parent/whatsapp phone' end,
           case when x.nm and c.a_ak <> '' and c.a_ak = c.b_ak then 'name+admission no' end,
           case when not x.nm and c.a_mk <> '' and c.a_mk = c.b_mk then 'mobile only (name differs)' end,
           case when not x.nm and c.a_ak <> '' and c.a_ak = c.b_ak then 'admission no only (name differs)' end,
           case when c.copied and (x.nm or (c.a_fk <> '' and c.a_fk = c.b_fk) or x.ph_overlap or (c.a_ak <> '' and c.a_ak = c.b_ak))
                then 'created_at copied from the other row (edit->insert)' end,
           case when x.nm and c.a_h is not distinct from c.b_h and not x.conflict
                     and not ((c.a_fk <> '' and c.a_fk = c.b_fk) or x.ph_overlap or (c.a_ak <> '' and c.a_ak = c.b_ak))
                then case when c.a_fk = '' or c.b_fk = '' then 'name only, father blank (weak)'
                          else 'same name+hostel, father differs, no phone/adm no to compare (weak, check by hand)' end end
         ) as why
  from cand c
  cross join lateral (
    select c.a_nk <> '' and c.a_nk = c.b_nk as nm,
           c.a_ph && c.b_ph as ph_overlap,
           (cardinality(c.a_ph) > 0 and cardinality(c.b_ph) > 0 and not (c.a_ph && c.b_ph)) or (c.a_ak <> '' and c.b_ak <> '' and c.a_ak <> c.b_ak) as conflict
  ) x
),
e as (select a_id, b_id, string_agg(distinct why, ' + ') as why from pr where why <> '' group by a_id, b_id),
ed as (select a_id as x, b_id as y from e union all select b_id, a_id from e),
g1 as (select ed.x as id, least(ed.x::text, min(ed.y::text)) as m from ed group by ed.x),
g2 as (select a.id, least(a.m, min(n.m)) as m from g1 a join ed on ed.x = a.id join g1 n on n.id = ed.y group by a.id, a.m),
grp as (   -- group id = smallest id within 3 steps (A~B, B~C, C~D => one group)
  select a.id::uuid as id, least(a.m, min(n.m)) as gid from g2 a join ed on ed.x = a.id join g2 n on n.id = ed.y group by a.id, a.m
),
gstat as (
  select g.gid, count(*) as n, count(distinct s.hostel_id) as n_hostels, max(greatest(s.created_at, s.ins_at)) as newest,
         count(*) filter (where lower(regexp_replace(coalesce(s.status, ''), '[^a-zA-Z]', '', 'g')) = 'active') as n_active   -- 'Active' / 'ACTIVE' count too
  from grp g join s on s.id = g.id group by g.gid
),
greasons as (select g.gid, string_agg(distinct e.why, ' / ') as reasons from e join grp g on g.id = e.a_id group by g.gid),
outp as (
  select dense_rank() over (order by (gs.n_hostels > 1), gs.newest desc, gs.gid) as grp_no,
         case when gs.n_hostels > 1 then 'CROSS-HOSTEL (transfer / invisible copy?)' else 'SAME HOSTEL' end as scope,
         gs.n as members, gs.n_active as active_members, gr.reasons as match_reasons,
         row_number() over (partition by gs.gid order by coalesce(s.ins_at, s.created_at), s.id) as nth_created,
         h.code as hostel, s.full_name, s.father_name, s.mobile, s.parent_mobile, s.admission_number, s.status, s.joining_date, s.exit_date, s.monthly_fee,
         (s.created_at at time zone 'Asia/Kolkata')::timestamp(0) as created_ist,
         coalesce(u.full_name, u.email, case when s.created_by is null then '(none / SQL)' else s.created_by::text end) as created_by_user,
         r.name as creator_role,
         (s.ins_at at time zone 'Asia/Kolkata')::timestamp(0) as audit_insert_ist,
         case when s.ins_at is null then 'no insert row in audit_logs'
              when abs(extract(epoch from (s.ins_at - s.created_at))) > 120 and s.ins_user is not null
                then 'created_at differs from real insert time: copied from an existing row (Edit form saved as NEW = edit->insert)?'
              when abs(extract(epoch from (s.ins_at - s.created_at))) > 120
                then 'SQL insert with explicit created_at (import?)'
              when r.name = 'director' and s.hostel_id = (select h1.id from hostels h1 order by h1.id limit 1)
                then 'added by Director into the form''s DEFAULT hostel (first by id): wrong hostel?'
         end as insert_note,
         (s.updated_at at time zone 'Asia/Kolkata')::timestamp(0) as updated_ist,
         coalesce(dues.n, 0) as n_dues, coalesce(dues.pend, 0) as dues_pending, dues.oct as oct_2026_due,
         coalesce(pays.n, 0) as n_payments, coalesce(pays.amt, 0) as paid_total, pays.last_pay as last_payment,
         beds_.bed as bed_now, s.id as student_id
  from grp g
  join gstat gs on gs.gid = g.gid
  left join greasons gr on gr.gid = g.gid
  join s on s.id = g.id
  left join hostels h on h.id = s.hostel_id
  left join users u on u.id = s.created_by
  left join roles r on r.id = u.role_id
  left join (   -- per-student totals as plain subqueries (not CTEs) so the planner keeps small row estimates
    select d.student_id, count(*) as n, coalesce(sum(d.pending), 0) as pend,
           max(case when d.month >= date '2026-10-01' and d.month < date '2026-11-01' then d.fee_amount::text || ' (pending ' || d.pending::text || ')' end) as oct
    from monthly_dues d group by d.student_id) dues on dues.student_id = s.id
  left join (
    select f.student_id, count(*) as n, coalesce(sum(f.amount), 0) as amt, max(f.payment_date) as last_pay
    from fee_payments f group by f.student_id) pays on pays.student_id = s.id
  left join (
    select b.student_id, string_agg(coalesce(r.room_number, '?') || '/' || b.bed_number, ' ') as bed
    from beds b left join rooms r on r.id = b.room_id where b.student_id is not null group by b.student_id) beds_ on beds_.student_id = s.id
),
capped as (select o.*, count(*) over (order by o.grp_no) as rows_upto from outp o),   -- whole groups, about 300 rows
notes as (
  select 1 as nord, 'NOTE: ' || b.kt || ' ' || b.v || ' = ' || b.n_students || ' students (' || b.why || ') -> NOT used for matching' as txt
  from (select * from bad order by n_students desc, v limit 20) b
  union all
  select 2, 'NOTE: only the newest ' || count(distinct grp_no) filter (where rows_upto <= 300 or grp_no = 1) || ' of ' || count(distinct grp_no)
            || ' duplicate groups are shown (300-row cap)'
  from capped having count(*) filter (where rows_upto > 300 and grp_no > 1) > 0
)
select grp_no, scope, members, active_members, match_reasons, nth_created, hostel, full_name, father_name, mobile, parent_mobile, admission_number,
       status, joining_date, exit_date, monthly_fee, created_ist, created_by_user, creator_role, audit_insert_ist, insert_note, updated_ist,
       n_dues, dues_pending, oct_2026_due, n_payments, paid_total, last_payment, bed_now, student_id
from (
  select 1 as part, 0 as nord, c.grp_no, c.scope, c.members, c.active_members, c.match_reasons, c.nth_created, c.hostel, c.full_name, c.father_name,
         c.mobile, c.parent_mobile, c.admission_number, c.status, c.joining_date, c.exit_date, c.monthly_fee, c.created_ist, c.created_by_user,
         c.creator_role, c.audit_insert_ist, c.insert_note, c.updated_ist, c.n_dues, c.dues_pending, c.oct_2026_due, c.n_payments, c.paid_total,
         c.last_payment, c.bed_now, c.student_id
  from capped c where c.rows_upto <= 300 or c.grp_no = 1
  union all
  select 0, n.nord, 0, n.txt, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null,
         null, null, null, null, null, null, null, null, null, null
  from notes n
) z
order by part, nord, grp_no, nth_created;


-- [Q6] =================================================================
-- Q6  "EDIT KARNE PAR NAYA STUDENT BAN GAYA" — AUDIT LOG SE SABOOT
--     audit_logs mein har student INSERT (app user ne kiya) jiske waqt
--     usi naam (+ father / phone / admission no.) ka student PEHLE se tha,
--     YA jiska created_at kisi purane record se copy hua tha (= Edit form
--     se insert hua = asli app bug, chahe naam / father badla ho).
--     Har insert ke liye: kab (IST), kisne, role, purana record kaunsa,
--     kya usi user ne purane record ko +-30 min mein EDIT kiya tha,
--     aur 29-Sep hotfix se PEHLE ya BAAD.
--     Upar "A summary" rows, neeche "B detail" rows (max 300, hotfix ke
--     BAAD wale pehle, sabse naye upar).
--     Agar 29-Sep ke BAAD bhi "EDIT->INSERT" dikhe to live par purana app hai.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
ins as (   -- every student INSERT done by a logged-in app user
  select l.id as log_id, l.entity_id as sid, l.user_id, l.created_at as at, l."after" as a
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'insert' and l.user_id is not null
),
known as (   -- every student identity: rows that exist now + inserted rows that were deleted later
  select s.id, s.full_name, s.father_name, s.mobile, s.parent_mobile, s.whatsapp, s.admission_number, s.hostel_id,
         s.created_at, s.created_at as row_created, s.created_by, true as exists_now, s.status::text as status
  from students s
  union all
  select l.entity_id, l."after" ->> 'full_name', l."after" ->> 'father_name', l."after" ->> 'mobile', l."after" ->> 'parent_mobile',
         l."after" ->> 'whatsapp', l."after" ->> 'admission_number',
         case when (l."after" ->> 'hostel_id') ~* '^[0-9a-f-]{36}$' then (l."after" ->> 'hostel_id')::uuid end,
         l.created_at, coalesce((l."after" ->> 'created_at')::timestamptz, l.created_at), l.user_id, false, '(deleted)'
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'insert' and l.entity_id is not null
    and not exists (select 1 from students s where s.id = l.entity_id)
),
k0 as (
  select k.*,
         coalesce(nullif(regexp_replace(lower(coalesce(k.full_name, '')), '[^[:alnum:]]+', '', 'g'), ''), lower(trim(coalesce(k.full_name, '')))) as nk,
         regexp_replace(regexp_replace(lower(coalesce(k.father_name, '')), '^(\s*(mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''), '[^[:alnum:]]+', '', 'g') as fk0,
         right(regexp_replace(coalesce(k.mobile, ''), '[^0-9]', '', 'g'), 10) as mk0,
         right(regexp_replace(coalesce(k.parent_mobile, ''), '[^0-9]', '', 'g'), 10) as pk0,
         right(regexp_replace(coalesce(k.whatsapp, ''), '[^0-9]', '', 'g'), 10) as wk0,
         regexp_replace(lower(coalesce(k.admission_number, '')), '[^[:alnum:]]+', '', 'g') as ak0
  from known k
),
bad as (   -- placeholder / shared phones and admission numbers (same rule as Q5): not used for matching
  select 'phone' as kt, v from (
    select u.v, count(distinct k0.nk) as n_names from k0 cross join lateral unnest(array[k0.mk0, k0.pk0, k0.wk0]) u(v)
    where length(u.v) = 10 group by u.v) p
  where n_names > 3 or v ~ '^(\d)\1{9}$' or v in ('1234567890', '0123456789', '9876543210')
  union all
  select 'adm no', ak0 from k0 where ak0 <> '' group by ak0
  having count(distinct nk) > 3 or ak0 ~ '^(.)\1*$' or ak0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'test', 'pending', 'new', 'notknown', 'unknown', 'nodata', 'notavailable')
),
kn as (
  select k0.*,
         case when k0.fk0 ~ '^(.)\1*$' or k0.fk0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'notknown', 'unknown', 'nodata', 'notavailable', 'father') then '' else k0.fk0 end as fk,
         case when length(k0.mk0) = 10 and k0.mk0 not in (select v from bad where kt = 'phone') then k0.mk0 else '' end as mk,
         case when k0.ak0 <> '' and k0.ak0 not in (select v from bad where kt = 'adm no') then k0.ak0 else '' end as ak,
         coalesce((select array_agg(distinct v) from unnest(array[k0.mk0, k0.pk0, k0.wk0]) u(v)
                   where length(v) = 10 and v not in (select b.v from bad b where b.kt = 'phone')), '{}'::text[]) as ph
  from k0
),
inn as (
  select i.*, k.nk, k.fk, k.mk, k.ak, k.ph, k.hostel_id, k.full_name, k.exists_now, k.status as status_now,
         coalesce((i.a ->> 'created_at') is not null and abs(extract(epoch from ((i.a ->> 'created_at')::timestamptz - i.at))) > 120, false) as copied_created_at,
         date_trunc('second', (i.a ->> 'created_at')::timestamptz) as copied_ts
  from ins i join kn k on k.id = i.sid
),
pairs as (   -- older records that look like the same student: same name, or (copied created_at = old row's created_at)
  select i.log_id, o.id as old_id from inn i join kn o on o.nk = i.nk and o.nk <> '' and o.id <> i.sid and o.created_at < i.at
  union
  select i.log_id, o.id from inn i join kn o on date_trunc('second', o.row_created) = i.copied_ts and i.copied_created_at and o.id <> i.sid and o.created_at < i.at
),
mm as (
  select p.log_id, o.id as old_id, o.full_name as old_name, o.hostel_id as old_hostel, o.created_at as old_created,
         o.created_by as old_by, o.exists_now as old_exists, o.status as old_status_now,
         (o.nk <> '' and o.nk = i.nk) as nm,
         (i.copied_created_at and date_trunc('second', o.row_created) = i.copied_ts) as ts_match,
         (i.fk <> '' and i.fk = o.fk) as f_match, (i.ph && o.ph) as p_match, (i.ak <> '' and i.ak = o.ak) as a_match,
         (i.hostel_id is not distinct from o.hostel_id) as same_hostel,
         ((cardinality(i.ph) > 0 and cardinality(o.ph) > 0 and not (i.ph && o.ph)) or (i.ak <> '' and o.ak <> '' and i.ak <> o.ak)) as conflict
  from pairs p join inn i on i.log_id = p.log_id join kn o on o.id = p.old_id
),
mq as (   -- keep only real matches
  select mm.* from mm
  where (mm.nm and (mm.f_match or mm.p_match or mm.a_match))                                  -- name + father / phone / adm no
     or (mm.ts_match and (mm.nm or mm.f_match or mm.p_match or mm.a_match))                   -- copied created_at + any key
     or (mm.nm and mm.same_hostel and not mm.conflict)                                       -- weak: name only, same hostel, nothing contradicts
),
m as (   -- best older match per insert; inserts with a copied created_at are kept even without any match
  select distinct on (i.log_id) i.*, q.old_id, q.old_name, q.old_hostel, q.old_created, q.old_by, q.old_exists, q.old_status_now, q.ts_match,
         concat_ws('+', case when q.nm then 'name' end, case when q.f_match then 'father' end, case when q.p_match then 'phone' end,
                        case when q.a_match then 'adm no' end, case when q.ts_match then 'copied created_at' end) as why,
         (q.old_id is not null and not (q.f_match or q.p_match or q.a_match or q.ts_match)) as weak
  from inn i left join mq q on q.log_id = i.log_id
  where q.old_id is not null or i.copied_created_at
  order by i.log_id, q.ts_match desc nulls last, q.same_hostel desc nulls last,
           (q.nm::int + q.f_match::int + q.p_match::int + q.a_match::int) desc nulls last, q.old_created desc nulls last
),
upd as (   -- real edits of the OLD rows (system-only paid_till / plan_amount recalcs are ignored)
  select l.entity_id, l.user_id, l.created_at,
         coalesce((select string_agg(e.k, ',' order by e.k) from jsonb_each(l."after"::jsonb) e(k, v)
                   where (l."before"::jsonb -> e.k) is distinct from e.v and e.k not in ('updated_at', 'paid_till', 'plan_amount')), '') as keys
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'update'
    and l.entity_id in (select old_id from m)
    and (l."before" ->> 'paid_till') is not distinct from (l."after" ->> 'paid_till')
),
x as (
  select m.*, se.mins as same_user_edit_min, se.keys as same_user_edit_keys,
         exists (select 1 from upd u where u.entity_id = m.old_id and u.created_at between m.at - interval '30 minutes' and m.at + interval '30 minutes') as any_edit_30m,
         case when m.at < timestamptz '2026-09-29 14:11:35+05:30' then '1 BEFORE 29-Sep hotfix' else '2 AFTER 29-Sep hotfix' end as win
  from m
  left join lateral (
    select round((extract(epoch from (u.created_at - m.at)) / 60.0)::numeric, 1) as mins, coalesce(nullif(u.keys, ''), '(saved, nothing changed)') as keys
    from upd u
    where u.entity_id = m.old_id and u.user_id = m.user_id
      and u.created_at between m.at - interval '30 minutes' and m.at + interval '30 minutes'
    order by abs(extract(epoch from (u.created_at - m.at))) limit 1
  ) se on true
),
v as (
  select x.*,
         case
           when x.copied_created_at and x.old_id is not null then 'EDIT->INSERT (strong: form of an existing row was saved as new)'
           when x.copied_created_at then 'EDIT->INSERT (strong: created_at copied; original not found - deleted / merged, or name+father+phone+adm all changed)'
           when x.old_by = x.user_id and x.at - x.old_created < interval '15 minutes' and x.same_user_edit_min is null then 'DOUBLE SAVE / RETRY (same user, minutes apart)'
           when x.same_user_edit_min is not null then 'EDIT then NEW row by same user within 30 min (edit->insert or re-add after failed edit)'
           when x.old_hostel is distinct from x.hostel_id then 'CROSS-HOSTEL re-add (old copy in another hostel)'
           else 'RE-ADDED later (manual Add, no edit nearby)'
         end || case when x.weak then ' [weak match: name only]' else '' end as verdict
  from x
)
select * from (
  select 'A summary' as sec, v.win, v.verdict, coalesce(r.name, '(no role)') as role, count(*)::int as n_inserts,
         min((v.at at time zone 'Asia/Kolkata')::timestamp(0))::text as first_ist, max((v.at at time zone 'Asia/Kolkata')::timestamp(0))::text as last_ist,
         string_agg(distinct coalesce(u.full_name, u.email), ', ') as by_users,
         null::text as new_student, null::text as new_hostel, null::text as new_now, null::text as old_student, null::text as old_hostel,
         null::text as old_created_ist, null::text as old_now, null::text as match_on, null::text as same_user_edit_min, null::text as same_user_edit_keys, null::text as anyone_edit_30m,
         null::text as created_at_copied, null::text as new_id, null::text as old_id
  from v left join users u on u.id = v.user_id left join roles r on r.id = u.role_id
  group by v.win, v.verdict, coalesce(r.name, '(no role)')
  union all
  select * from (
    select 'B detail', v.win, v.verdict, coalesce(r.name, '(no role)'), null::int,
           ((v.at at time zone 'Asia/Kolkata')::timestamp(0))::text, null, coalesce(u.full_name, u.email, v.user_id::text),
           v.full_name, hn.code, case when v.exists_now then v.status_now else '(deleted)' end,
           v.old_name, ho.code, ((v.old_created at time zone 'Asia/Kolkata')::timestamp(0))::text,
           case when v.old_id is null then null when v.old_exists then v.old_status_now else '(deleted)' end,
           case when v.old_id is null then '(no older record found)' when v.weak then 'name only (weak)' else v.why end,
           v.same_user_edit_min::text, v.same_user_edit_keys, v.any_edit_30m::text, v.copied_created_at::text, v.sid::text, v.old_id::text
    from v left join users u on u.id = v.user_id left join roles r on r.id = u.role_id
    left join hostels hn on hn.id = v.hostel_id left join hostels ho on ho.id = v.old_hostel
    order by v.win desc, v.at desc
    limit 300
  ) d
) z
order by sec, win desc, first_ist desc nulls last;


-- [Q7] =================================================================
-- Q7  CHHODE HUE (LEFT / INACTIVE) STUDENTS KE GALAT BILL
--     Har woh monthly_dues row jo:
--       AFTER_LEAVE     : chhodne ki tareekh ke BAAD shuru hone wale mahine ka bill
--       LEAVE_MONTH_FULL: jis mahine chhoda us mahine ka bill rehne ke dinon se zyada
--       NOT_ACTIVE_NO_DATE: Oct-2026+ bill, status left-jaisa, chhodne ki date pata nahi
--       STATUS_UNCLEAR  : Oct-2026+ bill, status NULL ya ajeeb value (haath se jaanchein)
--       TEMP_LEAVE_BILLED: temporary_leave ke baad shuru hone wala bill
--     'Active' / 'ACTIVE' / 'active ' = active (sirf exit_date se leave maana jaata hai).
--     Chhodne ki tareekh = exit_date, warna audit_logs mein status left-jaisa
--     hone ka din. Saari list aati hai (300 ki seema nahi).
--     Oct-2026 wale bills sabse upar. "likely_cause" batata hai bill kaise bana.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
st as (
  select s.id, s.full_name, s.father_name, s.hostel_id, s.status::text as status, s.joining_date, s.exit_date, s.monthly_fee,
         case when s.status::text is null then 'NULL' when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
              when lower(s.status::text) like '%temp%' then 'temp' else 'other' end as k,   -- coarse class: active / left / temp / NULL / other
         case when s.status::text = 'active' then 'active'
              when s.status::text = 'left' then 'left'
              when s.status is null then 'NULL'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active-odd-spelling'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout')
                   then 'left-like (odd spelling)'
              when lower(s.status::text) like '%temp%' then 'temporary_leave'
              else 'other: ' || s.status::text end as cls
  from students s
),
chg as (   -- latest change INTO the student's current class (pure re-casing like 'left' -> 'Left ' is not a change)
  select distinct on (c.sid) c.sid, c.at, c.user_id
  from (select l.entity_id as sid, l.created_at as at, l.user_id,
                case when l."before" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."before" ->> 'status') like '%temp%' then 'temp' else 'other' end as kb,
                case when l."after" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."after" ->> 'status') like '%temp%' then 'temp' else 'other' end as ka
        from audit_logs l where l.entity_type = 'students' and l.action = 'update'
          and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) c
  join st on st.id = c.sid
  where st.k <> 'active' and c.kb is distinct from c.ka and c.ka = st.k
  order by c.sid, c.at desc
),
lv as (
  select st.*, c.at as changed_at, c.user_id as changed_by,
         coalesce(st.exit_date, case when st.k = 'left' then (c.at at time zone 'Asia/Kolkata')::date end) as leave_date,   -- only left-like statuses get a date from the audit log
         case when st.exit_date is not null then 'exit_date'
              when st.k = 'left' and c.at is not null then 'status change (audit)'
              else null end as leave_src
  from st left join chg c on c.sid = st.id
  where st.k <> 'active' or st.exit_date is not null
),
dd as (
  select d.id, d.student_id, d.hostel_id, d.month, d.fee_amount, coalesce(d.discount, 0) as discount, d.payable, d.paid_amount, d.pending,
         d.status::text as status, d.created_at, d.created_by,
         coalesce(nullif(to_jsonb(d) ->> 'period_from', '')::date, d.month) as p_from,
         coalesce(nullif(to_jsonb(d) ->> 'period_to', '')::date, (d.month + interval '1 month - 1 day')::date) as p_to
  from monthly_dues d
  where d.student_id in (select id from lv)
),
calc as (
  select lv.*, dd.id as due_id, dd.month, dd.p_from, dd.p_to, dd.fee_amount, dd.discount, dd.payable, dd.paid_amount, dd.pending,
         dd.status as due_status, dd.created_at as due_created, dd.created_by as due_created_by,
         ((dd.month + interval '1 month')::date - dd.month) as cycle_days,
         case when lv.leave_date >= dd.p_from and lv.leave_date < dd.p_to   -- days stayed = max(bill start, joining_date) .. leave date
              then round(lv.monthly_fee * greatest(lv.leave_date - greatest(dd.p_from, coalesce(lv.joining_date, dd.p_from)) + 1, 0)
                         / ((dd.month + interval '1 month')::date - dd.month), 0) end as fair_fee
  from lv join dd on dd.student_id = lv.id
),
fl as (
  select c.*,
         concat_ws(' + ',
           case when c.leave_date is not null and c.p_from > c.leave_date then 'AFTER_LEAVE' end,
           case when c.fair_fee is not null and c.payable > c.fair_fee + 1 then 'LEAVE_MONTH_FULL' end,
           case when c.leave_date is null and c.k = 'left' and c.month >= date '2026-10-01' then 'NOT_ACTIVE_NO_DATE' end,
           case when c.leave_date is null and c.k in ('NULL', 'other') and c.month >= date '2026-10-01' then 'STATUS_UNCLEAR' end,
           case when c.k = 'temp' and c.changed_at is not null and c.p_from > (c.changed_at at time zone 'Asia/Kolkata')::date then 'TEMP_LEAVE_BILLED' end
         ) as flags
  from calc c
),
pay as (
  select f.due_id, count(*) as n, coalesce(sum(f.amount), 0) as amt
  from fee_payments f where f.due_id in (select due_id from fl where flags <> '') group by f.due_id
),
dins as (   -- who made the due (audit insert row = the app user whose session called the generator/RPC)
  select distinct on (l.entity_id) l.entity_id, l.user_id
  from audit_logs l
  where l.entity_type = 'monthly_dues' and l.action = 'insert' and l.entity_id in (select due_id from fl where flags <> '')
  order by l.entity_id, l.created_at
)
select case when fl.month >= date '2026-10-01' and fl.month < date '2026-11-01' then 'OCT-2026' else to_char(fl.month, 'YYYY-MM') end as bill_month,
       fl.flags, h.code as hostel, fl.full_name, fl.father_name, fl.status as status_raw, fl.cls as status_class,
       fl.joining_date, fl.exit_date, (fl.changed_at at time zone 'Asia/Kolkata')::timestamp(0) as status_changed_ist,
       coalesce(cu.full_name, cu.email) as status_changed_by, fl.leave_date as leave_date_used, fl.leave_src,
       fl.p_from as bill_from, fl.p_to as bill_to, fl.monthly_fee, fl.fee_amount, fl.discount, fl.payable,
       fl.fair_fee as fair_fee_for_days_stayed,
       case when fl.flags like '%AFTER_LEAVE%' or fl.flags like '%NOT_ACTIVE_NO_DATE%' or fl.flags like '%TEMP_LEAVE%' then fl.payable
            when fl.flags like '%LEAVE_MONTH_FULL%' then fl.payable - fl.fair_fee end as overbilled_by,   -- STATUS_UNCLEAR: unknown
       fl.paid_amount, fl.pending, fl.due_status, coalesce(pay.n, 0) as n_payments_on_bill, coalesce(pay.amt, 0) as paid_via_payments,
       (fl.due_created at time zone 'Asia/Kolkata')::timestamp(0) as bill_made_ist,
       case when fl.due_created_by is null then 'generator / SQL' else 'payment RPC (record_*)' end as bill_origin,
       coalesce(du.full_name, du.email, case when di.user_id is null and di.entity_id is not null then 'SQL editor / cron' end, '(no audit row)') as bill_made_in_session_of,
       case
         when fl.due_created_by is not null then 'bill created by a fee payment RPC (no status / exit check)'
         when fl.k = 'active' and fl.exit_date is not null then 'status still ACTIVE: generator ignores exit_date'
         when fl.k in ('NULL', 'other') then 'status NULL / unknown value (repo generator bills only exact ''active''): check who made this bill'
         when fl.changed_at is not null and fl.changed_at > fl.due_created then 'marked left AFTER the bill was made (nothing cancels / prorates it)'
         when fl.changed_at is not null and fl.changed_at <= fl.due_created then 'bill made while ALREADY not active: CHECK live generator / manual insert'
         when fl.exit_date is not null and (fl.due_created at time zone 'Asia/Kolkata')::date > fl.exit_date then 'bill made after exit_date (status change not in audit log)'
         else 'no status change in audit log (changed via SQL / before audit?)'
       end as likely_cause,
       fl.id as student_id, fl.due_id
from fl
left join hostels h on h.id = fl.hostel_id
left join users cu on cu.id = fl.changed_by
left join pay on pay.due_id = fl.due_id
left join dins di on di.entity_id = fl.due_id
left join users du on du.id = coalesce(fl.due_created_by, di.user_id)
where fl.flags <> ''
order by (fl.month >= date '2026-10-01' and fl.month < date '2026-11-01') desc, fl.month desc, h.code, fl.full_name;


-- [Q8] =================================================================
-- Q8  STUDENT STATUS KI SAFAI-JAANCH
--     1_status_value : har alag status value (exact, space/case ke saath) aur ginti
--                      - generator sirf exact 'active' ko bill karta hai,
--                        app sirf exact 'left' ko "left" maanta hai.
--     2_left_no_exit : left/inactive hain par exit_date khaali
--     3_exit_passed_still_active : exit_date beet gayi (aaj se pehle) par status abhi bhi active/temp
--     4_left_bed_not_freed : left-jaise status par bed abhi bhi unke naam
--     5_active_maybe_gone : status active, bed nahi, 45 din se payment nahi, Oct bill
--                      pending (shayad chale gaye par status nahi badla - jaanch karein)
--     (har section max 300 rows). Is block ko select karke Run karein,
--     result ka CSV bhejein.
-- =====================================================================
with
td as (select (now() at time zone 'Asia/Kolkata')::date as today),
st as (
  select s.id, s.full_name, s.father_name, s.hostel_id, s.status::text as status, s.joining_date, s.exit_date, s.current_bed_id, s.monthly_fee,
         case when s.status::text is null then 'NULL' when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
              when lower(s.status::text) like '%temp%' then 'temp' else 'other' end as k,   -- coarse class (same as Q7/Q9)
         case when s.status::text = 'active' then 'active'
              when s.status::text = 'left' then 'left'
              when s.status is null then 'NULL'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active-odd-spelling'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout')
                   then 'left-like (odd spelling)'
              when s.status::text = 'temporary_leave' then 'temporary_leave'
              when lower(s.status::text) like '%temp%' then 'temp-leave-odd-spelling'
              else 'other' end as cls
  from students s
),
chg as (   -- latest change INTO the student's current class (pure re-casing like 'left' -> 'Left ' is not a change)
  select distinct on (c.sid) c.sid, c.at, c.user_id
  from (select l.entity_id as sid, l.created_at as at, l.user_id,
                case when l."before" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."before" ->> 'status') like '%temp%' then 'temp' else 'other' end as kb,
                case when l."after" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."after" ->> 'status') like '%temp%' then 'temp' else 'other' end as ka
        from audit_logs l where l.entity_type = 'students' and l.action = 'update'
          and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) c
  join st on st.id = c.sid
  where c.kb is distinct from c.ka and c.ka = st.k
  order by c.sid, c.at desc
),
oct as (
  select d.student_id, sum(d.fee_amount) as fee, sum(d.pending) as pend
  from monthly_dues d where d.month >= date '2026-10-01' and d.month < date '2026-11-01' group by d.student_id
),
lastpay as (select f.student_id, max(f.payment_date) as last_pay from fee_payments f group by f.student_id),
bedq as (
  select b.student_id, string_agg(coalesce(r.room_number, '?') || '/' || b.bed_number || ' (' || coalesce(b.bed_status::text, '?') || ')', ' ') as bed
  from beds b left join rooms r on r.id = b.room_id where b.student_id is not null group by b.student_id
),
det as (
  select st.*, h.code, (c.at at time zone 'Asia/Kolkata')::timestamp(0) as changed_ist, coalesce(u.full_name, u.email) as changed_by,
         oct.fee as oct_fee, oct.pend as oct_pending, bedq.bed,
         (st.current_bed_id is not null) as has_current_bed, lp.last_pay
  from st
  left join lastpay lp on lp.student_id = st.id
  left join hostels h on h.id = st.hostel_id
  left join chg c on c.sid = st.id
  left join users u on u.id = c.user_id
  left join oct on oct.student_id = st.id
  left join bedq on bedq.student_id = st.id
)
select * from (
  select '1_status_value' as sec, '[' || coalesce(st.status, 'NULL') || ']' as status_raw, st.cls as status_class, count(*)::int as n_students,
         count(*) filter (where st.exit_date is not null)::int as n_with_exit_date,
         count(*) filter (where st.current_bed_id is not null)::int as n_with_bed,
         count(*) filter (where exists (select 1 from oct where oct.student_id = st.id))::int as n_with_oct_2026_bill,
         case when st.status = 'active' then 'yes' else 'no' end as generator_bills_it,
         case when coalesce(st.status, 'active') <> 'left' then 'yes' else 'no' end as dashboard_and_bell_treat_as_billable,
         null::text as hostel, null::text as full_name, null::text as father_name, null::date as joining_date, null::date as exit_date,
         null::text as status_changed_ist, null::text as status_changed_by, null::text as bed_now, null::numeric as oct_fee, null::numeric as oct_pending,
         null::text as student_id
  from st group by st.status, st.cls
  union all
  select * from (
    select '2_left_no_exit', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by, d.bed, d.oct_fee, d.oct_pending, d.id::text
    from det d where d.cls in ('left', 'left-like (odd spelling)') and d.exit_date is null
    order by d.changed_ist desc nulls last limit 300) a
  union all
  select * from (
    select '3_exit_passed_still_active', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by, d.bed, d.oct_fee, d.oct_pending, d.id::text
    from det d, td where d.exit_date < td.today and d.cls not in ('left', 'left-like (odd spelling)')   -- exit_date = last day stayed
    order by d.exit_date desc limit 300) b
  union all
  select * from (
    select '4_left_bed_not_freed', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by,
           coalesce(d.bed, '') || case when d.has_current_bed then ' | students.current_bed_id still set' else '' end, d.oct_fee, d.oct_pending, d.id::text
    from det d where d.cls in ('left', 'left-like (odd spelling)') and (d.bed is not null or d.has_current_bed)
    order by d.code, d.full_name limit 300) c
  union all
  select * from (
    select '5_active_maybe_gone', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by,
           'NO BED | last payment ' || coalesce(d.last_pay::text, 'never'), d.oct_fee, d.oct_pending, d.id::text
    from det d, td
    where d.cls in ('active', 'active-odd-spelling') and d.joining_date <= td.today - 30
      and d.bed is null and not d.has_current_bed
      and coalesce(d.last_pay, date '2000-01-01') < td.today - 45
      and coalesce(d.oct_pending, 0) > 0
    order by d.code, d.full_name limit 300) e
) z
order by sec, n_students desc nulls last, hostel, full_name;


-- [Q9] =================================================================
-- Q9  OCTOBER 2026 KE BILL KAB, KAISE, KISKE LOGIN SE BANE
--     Har group = (banne ka din IST, generator ya payment, kiske app-session se).
--     Saath mein: kitne bill, kitne hostels cover hue, pehla/aakhri time,
--     unme se kitne students ab active nahi ('Active'/'ACTIVE' = active) / exit_date 1-Oct se pehle /
--     bill banne ke BAAD left hue / duplicate record / bed nahi.
--     Aakhri row = TOTAL. Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
oct as (
  select d.id, d.student_id, d.hostel_id, d.fee_amount, d.payable, d.pending, d.created_at, d.created_by
  from monthly_dues d
  where d.month >= date '2026-10-01' and d.month < date '2026-11-01'
),
dins as (
  select distinct on (l.entity_id) l.entity_id, l.user_id, true as logged
  from audit_logs l
  where l.entity_type = 'monthly_dues' and l.action = 'insert' and l.entity_id in (select id from oct)
  order by l.entity_id, l.created_at
),
st as (
  select s.id, s.full_name, s.father_name, s.mobile, s.parent_mobile, s.whatsapp, s.admission_number,
         case when s.status::text is null then 'NULL' when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
              when lower(s.status::text) like '%temp%' then 'temp' else 'other' end as k   -- coarse class: 'Active' / 'ACTIVE' count as active
  from students s
),
chg as (   -- latest change INTO the student's current class (pure re-casing like 'left' -> 'Left ' is not a change)
  select distinct on (c.sid) c.sid, c.at, c.user_id
  from (select l.entity_id as sid, l.created_at as at, l.user_id,
                case when l."before" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."before" ->> 'status') like '%temp%' then 'temp' else 'other' end as kb,
                case when l."after" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."after" ->> 'status') like '%temp%' then 'temp' else 'other' end as ka
        from audit_logs l where l.entity_type = 'students' and l.action = 'update'
          and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) c
  join st on st.id = c.sid
  where st.k <> 'active' and c.kb is distinct from c.ka and c.ka = st.k
  order by c.sid, c.at desc
),
sk0 as (   -- same name keys as Q5
  select st.id,
         coalesce(nullif(regexp_replace(lower(coalesce(st.full_name, '')), '[^[:alnum:]]+', '', 'g'), ''), lower(trim(coalesce(st.full_name, '')))) as nk,
         regexp_replace(regexp_replace(lower(coalesce(st.father_name, '')), '^(\s*(mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''), '[^[:alnum:]]+', '', 'g') as fk0,
         array[right(regexp_replace(coalesce(st.mobile, ''), '[^0-9]', '', 'g'), 10), right(regexp_replace(coalesce(st.parent_mobile, ''), '[^0-9]', '', 'g'), 10),
               right(regexp_replace(coalesce(st.whatsapp, ''), '[^0-9]', '', 'g'), 10)] as ph0,
         regexp_replace(lower(coalesce(st.admission_number, '')), '[^[:alnum:]]+', '', 'g') as ak0
  from st
),
bad as (   -- placeholder / shared phones and admission numbers (same rule as Q5)
  select 'phone' as kt, v from (
    select u.v, count(distinct sk0.nk) as n_names from sk0 cross join lateral unnest(sk0.ph0) u(v) where length(u.v) = 10 group by u.v) p
  where n_names > 3 or v ~ '^(\d)\1{9}$' or v in ('1234567890', '0123456789', '9876543210')
  union all
  select 'adm no', ak0 from sk0 where ak0 <> '' group by ak0
  having count(distinct nk) > 3 or ak0 ~ '^(.)\1*$' or ak0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'test', 'pending', 'new', 'notknown', 'unknown', 'nodata', 'notavailable')
),
sk as (
  select sk0.id, sk0.nk,
         case when sk0.fk0 ~ '^(.)\1*$' or sk0.fk0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'notknown', 'unknown', 'nodata', 'notavailable', 'father') then '' else sk0.fk0 end as fk,
         case when sk0.ak0 <> '' and sk0.ak0 not in (select v from bad where kt = 'adm no') then sk0.ak0 else '' end as ak,
         coalesce((select array_agg(distinct v) from unnest(sk0.ph0) u(v) where length(v) = 10 and v not in (select b.v from bad b where b.kt = 'phone')), '{}'::text[]) as ph
  from sk0
),
dup as (   -- students that have a twin record (same name + father, phone or admission no.)
  select distinct a.id
  from sk a join sk b on a.id <> b.id and a.nk <> '' and a.nk = b.nk
   and ((a.fk <> '' and a.fk = b.fk) or a.ph && b.ph or (a.ak <> '' and a.ak = b.ak))
),
x as (
  select o.*, s.status::text as status, st.k, s.exit_date, s.current_bed_id, c.at as left_at,
         (o.created_at at time zone 'Asia/Kolkata')::date as made_on,
         case when o.created_by is not null then 'payment RPC' else 'generator / SQL' end as origin,
         case when o.created_by is not null then coalesce(cu.full_name, cu.email, o.created_by::text)
              when di.logged is null then '(no audit row)'
              when di.user_id is null then 'SQL editor / cron (no login)'
              else coalesce(au.full_name, au.email, di.user_id::text) end as session_of,
         case when o.created_by is not null then cr.name when di.user_id is not null then ar.name end as role,
         (o.student_id in (select id from dup)) as is_dup,
         h.code as hcode
  from oct o
  left join students s on s.id = o.student_id
  left join st on st.id = o.student_id
  left join chg c on c.sid = o.student_id
  left join dins di on di.entity_id = o.id
  left join users au on au.id = di.user_id left join roles ar on ar.id = au.role_id
  left join users cu on cu.id = o.created_by left join roles cr on cr.id = cu.role_id
  left join hostels h on h.id = o.hostel_id
)
select case when grouping(made_on) = 1 then 'TOTAL' else made_on::text end as made_on_ist,
       case when grouping(origin) = 1 then '' else origin end as origin,
       case when grouping(session_of) = 1 then '' else session_of end as made_in_session_of,
       case when grouping(role) = 1 then '' else coalesce(role, '-') end as role,
       count(*) as n_bills, sum(fee_amount) as fee_total, sum(pending) as pending_total,
       count(distinct hostel_id) as n_hostels, string_agg(distinct hcode, ',') as hostels,
       min((created_at at time zone 'Asia/Kolkata')::timestamp(0)) as first_made_ist,
       max((created_at at time zone 'Asia/Kolkata')::timestamp(0)) as last_made_ist,
       count(*) filter (where coalesce(k, '?') <> 'active') as n_student_not_active_now,
       count(*) filter (where exit_date < date '2026-10-01') as n_exit_before_oct,
       count(*) filter (where exit_date >= date '2026-10-01' and exit_date <= date '2026-10-31') as n_exit_in_oct,
       count(*) filter (where coalesce(k, '?') <> 'active' and left_at > created_at) as n_left_after_bill_made,
       count(*) filter (where coalesce(k, '?') <> 'active' and left_at <= created_at) as n_already_not_active_when_made,
       count(*) filter (where is_dup) as n_duplicate_record,
       count(*) filter (where current_bed_id is null) as n_no_bed_now,
       count(*) filter (where status is null and student_id is not null) as n_status_null
from x
group by grouping sets ((made_on, origin, session_of, role), ())
order by grouping(made_on), made_on, origin, session_of;


-- [Q10] ================================================================
-- Q10 DASHBOARD / LEDGER PAR GALAT ASAR (hostel-wise + TOTAL)
--     a) Oct-2026 "Fee Billed" mein chhode hue students ka bill (dashboard Billed / Collection %)
--     b) jis mahine chhoda us mahine ka extra (rehne ke dinon se zyada) bill
--     c) Monthly ledger / profile mein left students ka pending (Receive button dikhta hai)
--     d) Dashboard "Pending" + Bell "Overdue" mein galti se gine gaye: exit_date beet chuki
--        ya 'Left '/'inactive' jaisa status (app sirf exact 'left' ko left maanta hai)
--     e) temporary_leave / NULL status wale jo app mein "billable" (OVERDUE dikh sakte) hain
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
td as (select (now() at time zone 'Asia/Kolkata')::date as today),
st as (
  select s.id, s.hostel_id, s.status::text as status, s.exit_date, s.joining_date, s.monthly_fee,
         coalesce(lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g'))
              in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout'), false) as is_leftish,
         (coalesce(s.status::text, 'active') <> 'left' and s.joining_date is not null and coalesce(s.monthly_fee, 0) > 0) as app_billable
  from students s
),
chg as (   -- latest change INTO a left-like status from a non-left status (same leave date as Q7)
  select distinct on (c.sid) c.sid, (c.at at time zone 'Asia/Kolkata')::date as on_date
  from (select l.entity_id as sid, l.created_at as at,
               coalesce(lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g'))
                        in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout'), false) as was_left,
               coalesce(lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g'))
                        in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout'), false) as is_left
        from audit_logs l where l.entity_type = 'students' and l.action = 'update'
          and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) c
  where c.is_left and not c.was_left
  order by c.sid, c.at desc
),
lv as (
  select st.*, coalesce(st.exit_date, case when st.is_leftish then c.on_date end) as leave_date
  from st left join chg c on c.sid = st.id
),
dd as (
  select d.id, d.student_id, d.hostel_id, d.month, d.payable, d.pending,
         coalesce(nullif(to_jsonb(d) ->> 'period_from', '')::date, d.month) as p_from,
         coalesce(nullif(to_jsonb(d) ->> 'period_to', '')::date, (d.month + interval '1 month - 1 day')::date) as p_to
  from monthly_dues d
),
j as (
  select dd.*, lv.status, lv.is_leftish, lv.app_billable, lv.exit_date, lv.leave_date, lv.monthly_fee,
         (dd.month >= date '2026-10-01' and dd.month < date '2026-11-01') as is_oct,
         ((lv.leave_date is not null and dd.p_from > lv.leave_date) or (lv.leave_date is null and lv.is_leftish)) as full_wrong,
         case when lv.leave_date >= dd.p_from and lv.leave_date < dd.p_to   -- same fair fee and +1 tolerance as Q7 LEAVE_MONTH_FULL
              then case when dd.payable > fr.fair + 1 then dd.payable - fr.fair else 0 end end as leave_month_extra
  from dd join lv on lv.id = dd.student_id
  cross join lateral (select round(lv.monthly_fee * greatest(lv.leave_date - greatest(dd.p_from, coalesce(lv.joining_date, dd.p_from)) + 1, 0)
                                   / ((dd.month + interval '1 month')::date - dd.month), 0) as fair) fr
),
per as (
  select j.hostel_id,
         count(*) filter (where is_oct) as oct_bills,
         sum(payable) filter (where is_oct) as oct_billed,
         count(*) filter (where is_oct and (full_wrong or leave_month_extra > 0)) as a_oct_bills_of_left,
         coalesce(sum(case when full_wrong then payable else coalesce(leave_month_extra, 0) end) filter (where is_oct), 0) as a_oct_billed_wrongly,
         coalesce(sum(leave_month_extra), 0) as b_leave_month_extra_all_months,
         coalesce(sum(pending) filter (where is_leftish and p_from <= (select today from td) and pending > 0), 0) as c_ledger_pending_of_left,
         count(distinct student_id) filter (where is_leftish and p_from <= (select today from td) and pending > 0) as c_left_students_with_pending,
         coalesce(sum(pending) filter (where app_billable and (is_leftish or exit_date < (select today from td)) and p_from <= (select today from td) and pending > 0), 0) as d_dashboard_pending_wrong
  from j group by j.hostel_id
),
stu as (
  select st.hostel_id,
         count(*) filter (where st.app_billable and (st.is_leftish or st.exit_date < (select today from td))) as d_students_counted_but_gone,
         count(*) filter (where st.app_billable and not st.is_leftish and coalesce(st.status, '') <> 'active'
                            and (st.exit_date is null or st.exit_date >= (select today from td))) as e_templeave_null_odd_billable
  from st group by st.hostel_id
),
hs as (select hostel_id from per union select hostel_id from stu)
select case when grouping(h.code) = 1 then 'TOTAL' else coalesce(h.code, '(no hostel)') end as hostel,
       sum(coalesce(per.oct_bills, 0)) as oct_bills, sum(coalesce(per.oct_billed, 0)) as oct_billed_total,
       sum(coalesce(per.a_oct_bills_of_left, 0)) as a_oct_bills_of_left_students,
       sum(coalesce(per.a_oct_billed_wrongly, 0)) as a_oct_billed_wrongly,
       sum(coalesce(per.b_leave_month_extra_all_months, 0)) as b_leave_month_extra_all_months,
       sum(coalesce(per.c_ledger_pending_of_left, 0)) as c_ledger_pending_of_left_students,
       sum(coalesce(per.c_left_students_with_pending, 0)) as c_left_students_with_pending,
       sum(coalesce(per.d_dashboard_pending_wrong, 0)) as d_dashboard_pending_wrong,
       sum(coalesce(stu.d_students_counted_but_gone, 0)) as d_students_counted_billable_but_gone,
       sum(coalesce(stu.e_templeave_null_odd_billable, 0)) as e_templeave_null_or_odd_status_billable
from hs
left join per on per.hostel_id is not distinct from hs.hostel_id
left join stu on stu.hostel_id is not distinct from hs.hostel_id
left join hostels h on h.id = hs.hostel_id
group by rollup (h.code)
order by grouping(h.code), h.code;


-- [Q11] ================================================================
-- Q11 APP USERS: ROLE, STATUS, KAUN SA HOSTEL, AUR STUDENTS PAR KYA KIYA
--     Har login user: role, status, assigned hostels, aakhri activity,
--     students add / edit / delete ki ginti (29-Sep hotfix ke pehle/baad),
--     aur khatre: removed/pending user ke paas abhi bhi hostel access (RLS
--     status nahi dekhta), manager bina hostel, role khaali par active.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
act as (
  select l.user_id,
         max(l.created_at) as last_any,
         count(*) filter (where l.entity_type = 'students' and l.action = 'insert') as stu_ins,
         count(*) filter (where l.entity_type = 'students' and l.action = 'insert' and l.created_at >= timestamptz '2026-09-29 14:11:35+05:30') as stu_ins_after_fix,
         count(*) filter (where l.entity_type = 'students' and l.action = 'update'
                            and (l."before" ->> 'paid_till') is not distinct from (l."after" ->> 'paid_till')) as stu_upd,
         count(*) filter (where l.entity_type = 'students' and l.action = 'update'
                            and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) as stu_status_changes,
         count(*) filter (where l.entity_type = 'students' and l.action = 'delete') as stu_del,
         count(*) filter (where l.entity_type = 'fee_payments' and l.action = 'insert') as payments,
         max(l.created_at) filter (where l.entity_type = 'students' and l.action = 'insert') as last_stu_ins
  from audit_logs l
  where l.user_id is not null
  group by l.user_id
),
uha as (
  select a.user_id, string_agg(coalesce(h.code, '?'), ',' order by h.code) as hostels, count(*) as n
  from user_hostel_assignments a left join hostels h on h.id = a.hostel_id
  group by a.user_id
)
select coalesce(r.name, '(no role)') as role, u.full_name, u.email, u.status, u.is_active,
       uha.hostels as assigned_hostels,
       (select h.code from hostels h where h.id::text = to_jsonb(u) ->> 'requested_hostel_id') as requested_hostel,
       (u.created_at at time zone 'Asia/Kolkata')::timestamp(0) as created_ist,
       (act.last_any at time zone 'Asia/Kolkata')::timestamp(0) as last_activity_ist,
       coalesce(act.stu_ins, 0) as students_added, coalesce(act.stu_ins_after_fix, 0) as students_added_after_29sep_fix,
       (act.last_stu_ins at time zone 'Asia/Kolkata')::timestamp(0) as last_student_add_ist,
       coalesce(act.stu_upd, 0) as student_edits, coalesce(act.stu_status_changes, 0) as student_status_changes,
       coalesce(act.stu_del, 0) as students_deleted, coalesce(act.payments, 0) as fee_payment_rows,
       concat_ws(' | ',
         case when coalesce(u.status::text, 'active') <> 'active' and uha.n > 0 then 'NOT ACTIVE but still has hostel rows -> RLS still gives access' end,
         case when coalesce(u.is_active, true) = false and uha.n > 0 then 'is_active=false but still has hostel rows' end,
         case when r.name = 'manager' and uha.n is null then 'manager without any hostel' end,
         case when r.name is null and coalesce(u.status::text, 'active') = 'active' then 'active user without role' end,
         case when r.name in ('director', 'accountant') and uha.n > 0 then 'also has hostel rows (harmless)' end
       ) as flags,
       u.id as user_id
from users u
left join roles r on r.id = u.role_id
left join uha on uha.user_id = u.id
left join act on act.user_id = u.id
order by case r.name when 'director' then 1 when 'accountant' then 2 when 'manager' then 3 else 4 end, u.full_name;
