-- =====================================================================
-- 026_check_before.sql — 026 chalane se PEHLE (read-only, ek hi grid).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Rows 1-12 ka ok = true hona chahiye (13-17 sirf info).
-- Koi false ho to 026 mat chalayein, screenshot bhejein.
-- =====================================================================

select 1 as ord, '022 live (anon generate nahi chala sakta)' as chk,
       not coalesce(has_function_privilege('anon', to_regprocedure('public.generate_monthly_dues(date)'), 'execute'), true) as ok, '' as detail
union all
select 2, 'generate_monthly_dues = repo 022 (ya 026 pehle chal chuki)',
       coalesce(x.fp in ('6ea13bd087be181629f4f770132473a6', '9a3861bed71e727d7ed578fe54f8ad21', 'dc1b915e9229ae9b6952968878104450'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.generate_monthly_dues(date)')) as fp) x
union all
select 3, 'compute_paid_till = repo 024 (ya 026)',
       coalesce(x.fp in ('6e684ed7aad00f5128de11cb0c32f58b', 'd271416d96c5b317f390ee258737523a'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.compute_paid_till(uuid,date,numeric)')) as fp) x
union all
select 4, 'ddd_dues_set_paid_to = repo 024 (ya 026)',
       coalesce(x.fp in ('4540a28a7b993d35e0d73b93944bfe31', '327e508d4ad8389c3c8a10232dbebe77'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.ddd_dues_set_paid_to()')) as fp) x
union all
select 5, '024 date-range payment installed',
       to_regprocedure('public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)') is not null, ''
union all
select 6, '025 find-similar installed',
       to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)') is not null, ''
union all
select 7, 'koi bill abhi void nahi (026 se pehle 0 hona chahiye)',
       (select count(*) from public.monthly_dues where status = 'void') = 0 or to_regclass('public.ddd_dues_void_log') is not null,
       (select count(*) from public.monthly_dues where status = 'void')::text || ' void'
union all
select 13, 'info: 026 pehle chal chuki?', to_regclass('public.ddd_dues_void_log') is not null, ''
union all
select 14, 'info: Left students (exit date ke saath / bina)', true,
       (select count(*) filter (where exit_date is not null) || ' / ' || count(*) filter (where exit_date is null)
          from public.students where status = 'left')
union all
select 15, 'info: Active students jinki exit date bhari hai (generator inhe exit tak hi bill karega)', true,
       (select count(*)::text from public.students where status = 'active' and exit_date is not null)
union all
select 16, 'info: student status values', true,
       (select string_agg(coalesce(status, 'NULL') || '=' || n, ', ' order by status)
          from (select status, count(*) n from public.students group by status) s)
union all
select 17, 'info: bill status values', true,
       (select string_agg(coalesce(status, 'NULL') || '=' || n, ', ' order by status)
          from (select status, count(*) n from public.monthly_dues group by status) s)
union all
select 8, 'ddd_due_paid_to = repo 024 (ya 026)',
       coalesce(x.fp in ('00aad42d12d7d5491f7982a117dedb54', 'b6fb862ab3e8c55358d38605008dc1f7'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)')) as fp) x
union all
select 9, 'ddd_fee_range_plan = repo 024 (ya 026)',
       coalesce(x.fp in ('fef2cbbe57a653a64682250c53e7d35b', '6eb7654c1d987cc866106350fb505bc9'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.ddd_fee_range_plan(uuid,date,date)')) as fp) x
union all
select 10, 'delete_fee_payment = repo 014 (ya 026)',
       coalesce(x.fp in ('9f4b70c5afe489837501a4c704beb944', 'f323d01062d3076fdc28aad35a99698f'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.delete_fee_payment(uuid)')) as fp) x
union all
select 11, 'ddd_period_numbers = repo 020 (ya 026)',
       coalesce(x.fp in ('73ccf7156242b084c78e8846e83dba97', 'e6b351cd6db37302dd0c77598569569e'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.ddd_period_numbers(date,date,boolean,uuid[],boolean)')) as fp) x
union all
select 12, 'dashboard_summary = repo 020 (ya 026)',
       coalesce(x.fp in ('ca1a205f641a06e99b6aab41d2293fd3', '19909a440bf16429d20185c3e2965432'), false), coalesce(x.fp, 'missing')
  from (select (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                  from pg_proc where oid = to_regprocedure('public.dashboard_summary(date,date,uuid)')) as fp) x
order by 1;
