-- =====================================================================
-- 021_undo.sql
-- A) Ek merge wapas karna (data):   select * from public.ddd_merge_undo('<merge_id>');
--    (merge_id: select * from backup_021.merge_log;)
-- B) Tool hatana (sab merges undo karne ke BAAD, ya jab kaam khatam ho):
--    niche wala block. backup_021 schema record ke liye rehta hai.
-- =====================================================================
begin;
do $$
begin
  if to_regclass('backup_021.merge_log') is not null
     and exists (select 1 from backup_021.merge_log where undone_at is null) then
    raise notice 'Note: kuch applied merges undo nahi hue — unhe undo karna ho to pehle ddd_merge_undo() chalayein.';
  end if;
end $$;
drop function if exists public.ddd_merge_undo(uuid);
drop function if exists public.ddd_merge_duplicates(jsonb, boolean);
drop function if exists public.ddd_m21_merge_one(uuid, int, text, uuid, uuid);
drop function if exists public.ddd_m21_del(uuid, int, regclass, jsonb);
drop function if exists public.ddd_m21_log(uuid, int, text, text, jsonb, text, uuid, jsonb);
drop function if exists public.ddd_m21_cols(regclass, text[]);
drop function if exists public.ddd_m21_where(jsonb);
drop function if exists public.ddd_m21_pk(regclass);
commit;
notify pgrst, 'reload schema';
-- check (false): select to_regprocedure('public.ddd_merge_duplicates(jsonb,boolean)') is not null as tool_left;
-- poora record hatana ho (sirf jab koi undo nahi chahiye): drop schema backup_021 cascade;
