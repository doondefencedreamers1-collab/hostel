-- =====================================================================
-- 030_undo.sql - 030_common_expense.sql ko wapas leta hai
--
--  PEHLE naya app hata kar purana app lagayein (ya naya app khud Common Expense chhupa dega).
--  Pehle backup lein. 031 laga ho to pehle 031_undo.sql (ulta kram) - warna ye RUK jaata hai.
--
--  KYA KARTA HAI
--   - Koi common expense kabhi nahi bana = sab kuch BILKUL pehle jaisa: dono tables,
--     expenses ke 5 columns, functions, triggers, policies hat jaate hain. Koi data row nahi badalti.
--   - Common expense ban chuke hon = yeh RUK jaata hai (kuch nahi badla). Phir bhi hatana ho to
--     neeche force_undo := true karein. Tab
--       1. copy backup_030 schema mein (common_expenses, common_expense_hostels, expense_shares)
--       2. hisse wali expense rows RAKHI jaati hain - normal approved expense ban jaati hain
--          (amount, date, remarks wahi), isliye kisi hostel ka kharcha ya dashboard total nahi badalta.
--  Ek transaction. Do baar chalana safe. Aakhir mein ek line ka result dikhega.
-- =====================================================================
begin;

set local lock_timeout = '15s';

do $pre$
declare
  force_undo boolean := false;
  v_bad text;
  n_ce  bigint := 0;
  n_sh  bigint := 0;
begin
  -- koi bahar ka function 030 ki cheezein use to nahi karta (031 jaisa)
  v_bad := (select string_agg(p.oid::regprocedure::text, ', ')
              from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname not in ('ddd_ce_can_manage', 'ddd_ce_inr', 'ddd_ce_is_present', 'ddd_ce_prev_exit', 'ddd_ce_occupants', 'ddd_ce_plan',
                                     'ddd_ce_apply', 'ddd_occupants_on', 'ddd_common_expense_preview', 'ddd_common_expense_save',
                                     'ddd_common_expense_delete', 'ddd_common_expense_recalc', 'ddd_common_expense_report',
                                     'ddd_cexp_recalc_for_student', 'ddd_guard_common_expense_share', 'ddd_guard_hostel_common_expense')
               and p.prosrc ~ '(ddd_common_expense_|ddd_occupants_on|ddd_cexp_recalc_for_student|ddd_ce_(can_manage|inr|is_present|prev_exit|occupants|plan|apply)|common_expense_hostels|common_expenses|common_expense_id)');
  if v_bad is not null then
    raise exception '030 UNDO RUKA: yeh functions abhi bhi 030 use karte hain - %. Pehle 031_undo.sql chalayein. Kuch nahi badla.', v_bad;
  end if;
  v_bad := (select string_agg(distinct c.oid::regclass::text, ', ')
              from pg_class c join pg_depend d on d.objid = c.oid or d.objid in (select r.oid from pg_rewrite r where r.ev_class = c.oid)
             where c.relkind in ('v', 'm')
               and d.refobjid in (select x.oid from pg_class x
                                   where x.relnamespace = 'public'::regnamespace and x.relname in ('common_expenses', 'common_expense_hostels')));
  if v_bad is not null then
    raise exception '030 UNDO RUKA: view % common expense table use karta hai. Pehle use hatayein. Kuch nahi badla.', v_bad;
  end if;

  -- (plpgsql query tabhi padhta hai jab woh line chalti hai, isliye table / column na ho to bhi theek)
  if to_regclass('public.common_expenses') is not null then
    n_ce := (select count(*) from public.common_expenses);
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'expenses' and column_name = 'common_expense_id') then
    n_sh := (select count(*) from public.expenses e where e.common_expense_id is not null);
  end if;
  if (n_ce > 0 or n_sh > 0) and not force_undo then
    raise exception '030 UNDO RUKA: % common expense aur % hisse wali expense rows bani hui hain. Phir bhi hatana hai to is file mein force_undo := true karke chalayein (hisse normal approved expense ban kar rahenge, copy backup_030 mein). Kuch nahi badla.', n_ce, n_sh;
  end if;
end
$pre$;

-- ---------- 1. backup (sirf jab data hai - force_undo) ----------
do $bk$
declare
  n_ce bigint := 0;
  n_sh bigint := 0;
begin
  if to_regclass('public.common_expenses') is not null then
    n_ce := (select count(*) from public.common_expenses);
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'expenses' and column_name = 'common_expense_id') then
    n_sh := (select count(*) from public.expenses e where e.common_expense_id is not null);
  end if;
  if n_ce = 0 and n_sh = 0 then
    return;
  end if;
  execute 'create schema if not exists backup_030';
  execute 'revoke all on schema backup_030 from public, anon, authenticated';
  if to_regclass('public.common_expenses') is not null then
    execute 'create table if not exists backup_030.common_expenses as select c.*, now() as saved_at from public.common_expenses c where false';
    execute 'insert into backup_030.common_expenses select c.*, now() from public.common_expenses c
              where not exists (select 1 from backup_030.common_expenses b where b.id = c.id)';
  end if;
  if to_regclass('public.common_expense_hostels') is not null then
    execute 'create table if not exists backup_030.common_expense_hostels as select c.*, now() as saved_at from public.common_expense_hostels c where false';
    execute 'insert into backup_030.common_expense_hostels select c.*, now() from public.common_expense_hostels c
              where not exists (select 1 from backup_030.common_expense_hostels b where b.id = c.id)';
  end if;
  if n_sh > 0 then
    execute 'create table if not exists backup_030.expense_shares as
               select e.id, e.hostel_id, e.expense_date, e.amount, e.common_expense_id, e.common_total, e.common_hostels,
                      e.common_occupants, e.common_occupants_total, now() as saved_at
                 from public.expenses e where false';
    execute 'insert into backup_030.expense_shares
               select e.id, e.hostel_id, e.expense_date, e.amount, e.common_expense_id, e.common_total, e.common_hostels,
                      e.common_occupants, e.common_occupants_total, now()
                 from public.expenses e
                where e.common_expense_id is not null
                  and not exists (select 1 from backup_030.expense_shares b where b.id = e.id)';
  end if;
  execute 'revoke all on all tables in schema backup_030 from public, anon, authenticated';
end
$bk$;

-- ---------- 2. triggers aur functions ----------
drop trigger if exists trg_expenses_common_guard on public.expenses;
drop trigger if exists trg_hostels_common_expense_guard on public.hostels;
drop function if exists public.ddd_guard_common_expense_share();
drop function if exists public.ddd_guard_hostel_common_expense();

drop function if exists public.ddd_common_expense_report(date, date);
drop function if exists public.ddd_common_expense_recalc(uuid);
drop function if exists public.ddd_cexp_recalc_for_student(uuid);
drop function if exists public.ddd_common_expense_delete(uuid);
drop function if exists public.ddd_common_expense_save(uuid, date, text, text, numeric, text, text, text, uuid[]);
drop function if exists public.ddd_common_expense_preview(date, numeric, uuid[], uuid);
drop function if exists public.ddd_occupants_on(uuid, date);
drop function if exists public.ddd_ce_apply(uuid, date, text, text, numeric, text, text, text, uuid[], boolean, text);
drop function if exists public.ddd_ce_plan(uuid, date, numeric, uuid[], boolean);
drop function if exists public.ddd_ce_occupants(date, uuid[]);
drop function if exists public.ddd_ce_is_present(date, timestamptz, date, text, uuid, date, date, date);
drop function if exists public.ddd_ce_prev_exit(uuid, date);
drop function if exists public.ddd_ce_inr(numeric);
drop function if exists public.ddd_ce_can_manage();

-- ---------- 3. expenses ke 5 columns (hisse wali rows rehti hain, bas link hatta hai) ----------
drop index if exists public.ux_expenses_common_share;
alter table public.expenses drop constraint if exists expenses_common_fields_chk;
alter table public.expenses drop constraint if exists expenses_common_expense_id_fkey;
alter table public.expenses drop column if exists common_expense_id;
alter table public.expenses drop column if exists common_total;
alter table public.expenses drop column if exists common_hostels;
alter table public.expenses drop column if exists common_occupants;
alter table public.expenses drop column if exists common_occupants_total;

-- ---------- 4. dono tables (policy pehle - common_expenses ki policy doosri table padhti hai) ----------
do $pol$
begin
  if to_regclass('public.common_expenses') is not null then
    execute 'drop policy if exists common_expenses_read on public.common_expenses';
  end if;
  if to_regclass('public.common_expense_hostels') is not null then
    execute 'drop policy if exists common_expense_hostels_read on public.common_expense_hostels';
  end if;
end
$pol$;
drop table if exists public.common_expense_hostels;
drop table if exists public.common_expenses;

-- ---------- 5. VERIFY ----------
do $verify$
declare
  n int;
begin
  if to_regclass('public.common_expenses') is not null or to_regclass('public.common_expense_hostels') is not null then
    raise exception '030 UNDO VERIFY FAIL: tables abhi bhi hain';
  end if;
  n := (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'expenses' and column_name like 'common\_%');
  if n > 0 then raise exception '030 UNDO VERIFY FAIL: expenses mein % common columns bache', n; end if;
  n := (select count(*) from pg_proc
         where pronamespace = 'public'::regnamespace
           and (proname like 'ddd\_common\_expense\_%' or proname like 'ddd\_ce\_%'
                or proname in ('ddd_occupants_on', 'ddd_cexp_recalc_for_student', 'ddd_guard_common_expense_share',
                               'ddd_guard_hostel_common_expense')));
  if n > 0 then raise exception '030 UNDO VERIFY FAIL: % functions bache', n; end if;
  if exists (select 1 from pg_trigger where tgname in ('trg_expenses_common_guard', 'trg_hostels_common_expense_guard')) then
    raise exception '030 UNDO VERIFY FAIL: trigger bacha';
  end if;
end
$verify$;

commit;

notify pgrst, 'reload schema';

-- result (sirf padhna) - pehle teen false / 0 hone chahiye
select (to_regclass('public.common_expenses') is not null) as common_expenses_table_hai,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'expenses' and column_name like 'common\_%') as expenses_common_columns,
       (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
           and (proname like 'ddd\_common\_expense\_%' or proname like 'ddd\_ce\_%' or proname = 'ddd_occupants_on')) as functions_bache,
       (to_regclass('backup_030.common_expenses') is not null) as purani_copy_backup_030_mein,
       (select count(*) from public.expenses where remarks like 'Common Expense (Split)%') as split_wali_rows_ab_normal_expense;

-- ---------- ROLLBACK ----------
-- Is undo ko wapas lena ho (030 dobara lagani ho) to 030_common_expense.sql phir se chalayein.
-- force_undo ke baad purane common expense backup_030 mein hain - unhe wapas jodna ho to developer se baat karein.
