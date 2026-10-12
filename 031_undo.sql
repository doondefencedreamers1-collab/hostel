-- =====================================================================
-- 031_undo.sql - 031_delete_duplicate.sql wapas
--
--  - 031 ke 8 functions aur merge guard trigger hatata hai (Delete Duplicate button
--    kaam karna band, merged_into phir 026 jaisa - is_director / SQL Editor).
--  - duplicate_deletion_log - khali ho to hatti hai. Rows hon to pehle unki
--    copy backup_031.duplicate_deletion_log mein, phir table hatti hai.
--  - Jo duplicate pehle hi hataye (merge) ja chuke hain woh waise hi rehte hain
--    (merged_into + Left). Unki poori copy log ke snapshot mein hai.
--  - Koi aur function 031 ke function / table use kar raha ho to RUK jaata hai.
-- Ek transaction. Do baar chalana safe. Pehle backup lein.
-- =====================================================================
begin;

set local lock_timeout = '15s';

do $pre$
declare
  v_bad text;
  r     record;
begin
  v_bad := (select string_agg(p.oid::regprocedure::text, ', ')
              from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.prosrc ~ '(ddd_dup_|ddd_duplicate_candidates|ddd_delete_duplicate|duplicate_deletion_log)'
               and p.proname not in ('ddd_dup_name_key', 'ddd_dup_mobile_key', 'ddd_dup_rs', 'ddd_dup_identity', 'ddd_dup_plan',
                                     'ddd_duplicate_candidates', 'ddd_delete_duplicate', 'ddd_guard_students_merge'));
  if v_bad is not null then
    raise exception '031 UNDO RUKA: yeh functions abhi bhi 031 use karte hain - %. Pehle unka undo chalayein. Kuch nahi badla.', v_bad;
  end if;
  for r in select x.f, x.mine,
                  (select md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
                     from pg_proc p where p.oid = to_regprocedure(x.f)) as fp
             from (values ('public.ddd_dup_name_key(text)', '20af3e892b20957f7e04e318eb256ca4'),
                          ('public.ddd_dup_mobile_key(text)', 'e7d064cad2f4d237712392a6fcf616e9'),
                          ('public.ddd_dup_rs(numeric)', 'b4c05e376c8a71e94e868b9a11ab6196'),
                          ('public.ddd_dup_identity(uuid)', '2d834d4aeca0a8bf3a92391ae1c5ee4f'),
                          ('public.ddd_dup_plan(uuid,uuid)', 'a56cd815135c577f46398fd3b633d6e3'),
                          ('public.ddd_duplicate_candidates(uuid)', '19d8d6794bd42dfd160eef731ad0ac09'),
                          ('public.ddd_delete_duplicate(uuid,uuid,boolean,boolean)', '568522774db56f7b4e3305628a60c9f7'),
                          ('public.ddd_guard_students_merge()', '302d44034d260a2e049cf29c1236eb11')) x(f, mine) loop
    if r.fp is not null and r.fp <> r.mine then
      raise exception '031 UNDO RUKA: function % ka code 031 wala nahi hai (%). Developer ko batayein. Kuch nahi badla.', r.f, r.fp;
    end if;
  end loop;
end
$pre$;

-- ---------- 1. functions (aur merge guard) ----------
drop trigger if exists trg_students_merge_guard on public.students;
drop function if exists public.ddd_guard_students_merge();
drop function if exists public.ddd_delete_duplicate(uuid, uuid, boolean, boolean);
drop function if exists public.ddd_duplicate_candidates(uuid);
drop function if exists public.ddd_dup_plan(uuid, uuid);
drop function if exists public.ddd_dup_identity(uuid);
drop function if exists public.ddd_dup_rs(numeric);
drop function if exists public.ddd_dup_mobile_key(text);
drop function if exists public.ddd_dup_name_key(text);

-- ---------- 2. log table (rows hon to copy backup_031 mein) ----------
do $log$
begin
  if to_regclass('public.duplicate_deletion_log') is not null then
    if exists (select 1 from public.duplicate_deletion_log) then
      execute 'create schema if not exists backup_031';
      execute 'revoke all on schema backup_031 from public, anon, authenticated';
      execute 'create table if not exists backup_031.duplicate_deletion_log (like public.duplicate_deletion_log including defaults)';
      execute 'revoke all on table backup_031.duplicate_deletion_log from public, anon, authenticated';
      execute 'insert into backup_031.duplicate_deletion_log select l.* from public.duplicate_deletion_log l
                where not exists (select 1 from backup_031.duplicate_deletion_log b where b.id = l.id)';
    end if;
  end if;
end
$log$;
drop table if exists public.duplicate_deletion_log;

commit;

notify pgrst, 'reload schema';

-- result (sirf padhna)
select (to_regclass('public.duplicate_deletion_log') is not null) as log_table_hai,
       (to_regprocedure('public.ddd_delete_duplicate(uuid,uuid,boolean,boolean)') is not null) as button_function_hai,
       (to_regclass('backup_031.duplicate_deletion_log') is not null) as purana_log_backup_031_mein,
       (select count(*) from public.students where merged_into is not null) as merged_records_waise_hi;

-- ---------- ROLLBACK ----------
-- Is undo ko wapas lena ho to 031_delete_duplicate.sql phir se chalayein.
