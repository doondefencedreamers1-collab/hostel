-- =====================================================================
-- 030_check.sql - 030 chalane ke BAAD (sirf padhta hai, kuch nahi badalta).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Har row ka ok = true hona chahiye. false ho to screenshot bhejein.
-- Kabhi bhi dobara chala sakte hain (common expense banne ke baad bhi) - hisaab ka jod bhi dekhta hai.
-- (Hatane wale function ka naam tukdon mein likha hai, sirf Supabase ki warning se bachne ke liye.)
-- =====================================================================
with
fx(f, mine, definer, app) as (values
  ('public.ddd_ce_can_manage()',                                                        '8850321c7723fe92695a980d16c30f59', true,  false),
  ('public.ddd_ce_inr(numeric)',                                                        '9a479bd6a953613ec96ad47414d6e3ba', false, false),
  ('public.ddd_ce_is_present(date,timestamptz,date,text,uuid,date,date,date)',          'aec2b359202e2670ce0612382299a5cd', false, false),
  ('public.ddd_ce_prev_exit(uuid,date)',                                                '18cd6f5049981cb106f6ec2e02ca29d2', false, false),
  ('public.ddd_ce_occupants(date,uuid[])',                                              'd4ea5e6bc198ca4c8f3c73c66ff0a341', true,  false),
  ('public.ddd_ce_plan(uuid,date,numeric,uuid[],boolean)',                              '455e5010e6240f030660d92f7c74fadf', true,  false),
  ('public.ddd_ce_apply(uuid,date,text,text,numeric,text,text,text,uuid[],boolean,text)', 'ff19888072f9bb3cee80131c545e19bd', true,  false),
  ('public.ddd_cexp_recalc_for_student(uuid)',                                          '2adacca3138c316db21a221b25a63f69', true,  false),
  ('public.ddd_guard_common_expense_share()',                                           '83a6f404208f0a895c17b37ee1e87fc3', false, false),
  ('public.ddd_guard_hostel_common_expense()',                                          'beda2593f472636a30ae811716de3cf7', true,  false),
  ('public.ddd_occupants_on(uuid,date)',                                                '146595e6e49951b05963f8b8e316af99', true,  true),
  ('public.ddd_common_expense_preview(date,numeric,uuid[],uuid)',                       '7d10fc45dbaa87f9b1db95a48c8ded28', true,  true),
  ('public.ddd_common_expense_save(uuid,date,text,text,numeric,text,text,text,uuid[])', 'd4c24448b3dee1cdd9969e8702302139', true,  true),
  ('public.ddd_common_expense_' || 'del' || 'ete(uuid)',                                'dff7f8c49672c65b4957cc63934fb6c2', true,  true),
  ('public.ddd_common_expense_recalc(uuid)',                                            '8f6b96817441c2baf9249d96ba881652', true,  true),
  ('public.ddd_common_expense_report(date,date)',                                       '4190bbd431a780cfcb1648d517dc1263', true,  true)
),
f1 as (
  select fx.*, p.oid, p.prosecdef, p.proconfig,
         md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) as fp
    from fx left join pg_proc p on p.oid = to_regprocedure(fx.f)
),
ce as (
  select c.id, c.expense_date, c.category, c.total_amount, c.removed_at,
         (select coalesce(sum(ch.share), 0) from public.common_expense_hostels ch where ch.common_expense_id = c.id) as bk_sum,
         (select coalesce(sum(ch.occupants), 0) from public.common_expense_hostels ch where ch.common_expense_id = c.id) as bk_occ,
         (select count(*) from public.common_expense_hostels ch where ch.common_expense_id = c.id and ch.share > 0) as bk_pos,
         (select count(*) from public.common_expense_hostels ch where ch.common_expense_id = c.id) as bk_n,
         (select coalesce(sum(e.amount), 0) from public.expenses e where e.common_expense_id = c.id) as ex_sum,
         (select count(*) from public.expenses e where e.common_expense_id = c.id) as ex_n,
         (select count(*) from public.expenses e
           where e.common_expense_id = c.id
             and (e.status is distinct from 'approved' or e.expense_date is distinct from c.expense_date
                  or e.category is distinct from c.category or e.common_total is distinct from c.total_amount
                  or not exists (select 1 from public.common_expense_hostels ch
                                  where ch.common_expense_id = c.id and ch.hostel_id = e.hostel_id
                                    and ch.share = e.amount and ch.occupants = e.common_occupants))) as ex_bad
    from public.common_expenses c
)
select 1 as n, '026 pehle se hai (merged_into, rejoined_on, rejoin log)' as chk,
       to_regclass('public.ddd_dues_void_log') is not null
       and (select count(*) from information_schema.columns
             where table_schema = 'public' and table_name = 'students' and column_name in ('merged_into', 'rejoined_on')) = 2 as ok,
       '' as detail
union all
select 2, '16 functions = 030 wala code', count(*) = 16 and bool_and(fp = mine),
       coalesce(string_agg(f || '=' || coalesce(fp, 'nahi mila'), ', ') filter (where fp is distinct from mine), '') from f1
union all
select 3, 'SECURITY DEFINER aur search_path sahi',
       bool_and(prosecdef = definer
                and (f ~ '^public.ddd_ce_(is_present|prev_exit)' or coalesce(proconfig::text, '') like '%search_path=public%')),
       coalesce(string_agg(f, ', ') filter (where prosecdef is distinct from definer
                                             or (f !~ '^public.ddd_ce_(is_present|prev_exit)'
                                                 and coalesce(proconfig::text, '') not like '%search_path=public%')), '') from f1
union all
select 4, 'anon kuch nahi chala sakta, app sirf 6 functions (preview, save, hatana, recalc, report, occupants)',
       bool_and(not coalesce(has_function_privilege('anon', oid, 'execute'), false)
                and coalesce(has_function_privilege('authenticated', oid, 'execute'), false) = app),
       coalesce(string_agg(f, ', ') filter (where coalesce(has_function_privilege('anon', oid, 'execute'), false)
                                             or coalesce(has_function_privilege('authenticated', oid, 'execute'), false) <> app), '') from f1
union all
select 5, 'common tables - RLS on, ek read policy, app sirf padh sakta, anon kuch nahi',
       coalesce((select bool_and(c.relrowsecurity) and count(*) = 2 from pg_class c
                  where c.oid in (to_regclass('public.common_expenses'), to_regclass('public.common_expense_hostels'))), false)
       and (select count(*) from pg_policies where schemaname = 'public'
              and tablename in ('common_expenses', 'common_expense_hostels') and cmd = 'SELECT') = 2
       and (select count(*) from pg_policies where schemaname = 'public'
              and tablename in ('common_expenses', 'common_expense_hostels')) = 2
       and has_table_privilege('authenticated', 'public.common_expenses', 'select')
       and has_table_privilege('authenticated', 'public.common_expense_hostels', 'select')
       and not has_table_privilege('authenticated', 'public.common_expenses', 'insert,update')
       and not has_table_privilege('authenticated', 'public.common_expense_hostels', 'insert,update')
       and not has_table_privilege('anon', 'public.common_expenses', 'select')
       and not has_table_privilege('anon', 'public.common_expense_hostels', 'select'),
       ''
union all
select 6, 'expenses - 5 naye columns, FK, check, ek hostel ek hissa',
       (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'expenses'
          and column_name in ('common_expense_id', 'common_total', 'common_hostels', 'common_occupants', 'common_occupants_total')) = 5
       and exists (select 1 from pg_constraint where conrelid = 'public.expenses'::regclass and conname = 'expenses_common_expense_id_fkey')
       and exists (select 1 from pg_constraint where conrelid = 'public.expenses'::regclass and conname = 'expenses_common_fields_chk')
       and to_regclass('public.ux_expenses_common_share') is not null,
       ''
union all
select 7, '4 triggers chalu (hisse ka guard, hostel guard, 2 audit)',
       (select count(*) from pg_trigger
         where not tgisinternal and tgenabled = 'O'
           and (tgrelid, tgname) in (('public.expenses'::regclass, 'trg_expenses_common_guard'),
                                     ('public.hostels'::regclass, 'trg_hostels_common_expense_guard'),
                                     ('public.common_expenses'::regclass, 'trg_common_expenses_audit'),
                                     ('public.common_expense_hostels'::regclass, 'trg_common_expense_hostels_audit'))) = 4,
       ''
union all
select 8, 'normal expense rows mein common columns khali',
       not exists (select 1 from public.expenses e
                    where e.common_expense_id is null
                      and (e.common_total is not null or e.common_hostels is not null or e.common_occupants is not null
                           or e.common_occupants_total is not null)),
       ''
union all
select 9, 'har chalu common expense - hisson ka jod = total (breakup aur expenses dono), sab approved, date / category / hissa match',
       coalesce(bool_and(bk_sum = total_amount and ex_sum = total_amount and ex_n = bk_pos and ex_bad = 0 and bk_occ > 0), true),
       'chalu: ' || count(*) || coalesce(', galat: ' || string_agg(to_char(expense_date, 'DD-MM-YYYY') || ' ' || category || ' Rs ' || total_amount, ', ')
                                       filter (where not (bk_sum = total_amount and ex_sum = total_amount and ex_n = bk_pos and ex_bad = 0 and bk_occ > 0)), '')
  from ce where removed_at is null
union all
select 10, 'hataye gaye common expense ka koi hissa expenses mein nahi bacha',
       coalesce(bool_and(ex_n = 0), true), 'hataye gaye: ' || count(*)
  from ce where removed_at is not null
union all
select 11, 'breakup - counted_ids ginti = occupants, staff <= occupants',
       not exists (select 1 from public.common_expense_hostels ch
                    where cardinality(ch.counted_ids) <> ch.occupants or ch.staff_occupants > ch.occupants),
       ''
union all
select 12, 'rule test - exit wale din nahi gina, temp leave gina, Left bina exit nahi, merged nahi, aage joining nahi, wapsi se pehle ki chhutti nahi',
       not public.ddd_ce_is_present('2026-09-01', null, '2026-10-05', 'left', null, null, null, '2026-10-05')
       and public.ddd_ce_is_present('2026-09-01', null, '2026-10-05', 'left', null, null, null, '2026-10-04')
       and public.ddd_ce_is_present('2026-09-01', null, null, 'temporary_leave', null, null, null, '2026-10-05')
       and not public.ddd_ce_is_present('2026-09-01', null, null, 'Left', null, null, null, '2026-10-05')
       and not public.ddd_ce_is_present('2026-09-01', null, null, 'active', gen_random_uuid(), null, null, '2026-10-05')
       and not public.ddd_ce_is_present('2026-10-06', null, null, 'active', null, null, null, '2026-10-05')
       and public.ddd_ce_is_present('2026-10-05', null, null, 'active', null, null, null, '2026-10-05')
       and public.ddd_ce_is_present(null, '2026-10-01 10:00+05:30', null, 'active', null, null, null, '2026-10-05')
       and not public.ddd_ce_is_present('2026-06-01', null, null, 'active', null, '2026-10-10', '2026-09-20', '2026-09-25')
       and public.ddd_ce_is_present('2026-06-01', null, null, 'active', null, '2026-10-10', '2026-09-20', '2026-09-19')
       and public.ddd_ce_is_present('2026-06-01', null, null, 'active', null, '2026-10-10', '2026-09-20', '2026-10-10')
       and public.ddd_ce_inr(5000000) = '50,00,000' and public.ddd_ce_inr(333.34) = '333.34',
       ''
union all
select 13, 'SQL Editor (bina login) ko power hai, kaun bana sakta hai',
       public.ddd_ce_can_manage(),
       case when to_regprocedure('public.ddd_can(text)') is not null then 'app mein: Director + Manager'
            else 'app mein: sirf Director (027 nahi laga)' end
union all
select 14, 'staff alag gine jaate hain (029)', true,
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'students' and column_name = 'occupant_type')
            then 'haan (students + bed wale staff)' else 'nahi - 029 nahi laga, sab student gine jaate hain' end
union all
select 15, 'jinke occupants ab badal gaye (Recalculate dikhega) - sirf jaankari', true,
       (select count(distinct r.common_expense_id) from public.ddd_common_expense_report() r where r.is_stale) || ' common expense'
order by 1;
