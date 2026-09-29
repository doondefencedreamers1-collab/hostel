-- =====================================================================
-- 021_merge_duplicates.sql     (needs 014 + 018)
-- DDD Hostel — SAFE merge of duplicate students / staff (Director only,
-- run from the SQL Editor). This file only INSTALLS the tools; nothing
-- is merged until you call them with the pairs you approved:
--
--   dry run (changes nothing, shows every step):
--     select * from public.ddd_merge_duplicates('[{"kind":"students","keep":"<old id>","dup":"<new id>"}]', false);
--   apply (after you OK the dry run):
--     select * from public.ddd_merge_duplicates('[ ...same list... ]', true);
--   undo one applied merge:
--     select * from public.ddd_merge_undo('<merge_id from the apply result>');
--
-- Rules per pair (keep = ORIGINAL record, dup = the extra copy):
--  * keep's id stays. dup's filled values are copied onto keep (empty
--    values never overwrite).
--  * EVERY row pointing at dup (found from the live foreign keys, not
--    from the repo) moves to keep: payments, dues, attendance, beds,
--    complaints, salary rows, advances, ... Payments are NEVER deleted.
--  * Same month due on both: the one with no payment is removed (backed
--    up); payments on both for the same month -> pair BLOCKED (manual).
--  * Same attendance date on both: dup's row removed (backed up).
--  * Staff salary: same month salary row on both -> BLOCKED; salary
--    profile: dup's filled values copied onto keep's.
--  * Beds: keep has no bed -> dup's bed goes to keep; both have beds ->
--    dup's bed is freed (vacant).
--  * Then dup is deleted; paid_till of keep is recomputed.
--  * Check: number and total of fee_payments must be the same before and
--    after, else everything rolls back.
--  * Every change is written to backup_021.rows so ddd_merge_undo() can
--    put it all back.
-- Functions are NOT callable from the app (no grant to authenticated).
-- One transaction, idempotent.
-- =====================================================================
begin;

do $$
begin
  if to_regprocedure('public.recompute_paid_till(uuid)') is null then raise exception '021 aborted: run 014 first'; end if;
  if to_regclass('public.salary_runs') is null then raise exception '021 aborted: run 018 first'; end if;
end $$;

create schema if not exists backup_021;
create table if not exists backup_021.merge_log (
  merge_id  uuid primary key,
  pairs     jsonb not null,
  applied_at timestamptz not null default now(),
  applied_by text not null default current_user,
  undone_at timestamptz
);
create table if not exists backup_021.rows (
  merge_id  uuid not null,
  seq       bigserial,
  pair_no   int,
  action    text not null check (action in ('deleted','moved','updated')),
  tbl       text not null,
  key       jsonb not null,          -- primary key of the row (after a move)
  fk_col    text,
  old_value uuid,
  row_data  jsonb,
  primary key (merge_id, seq)
);
revoke all on schema backup_021 from public, anon, authenticated;

-- ---------- helpers ----------
create or replace function public.ddd_m21_pk(p_tbl regclass) returns text[]
language sql stable as $$
  select array_agg(a.attname::text order by k.ord)
  from pg_index i
  cross join lateral unnest(i.indkey) with ordinality k(attnum, ord)
  join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
  where i.indrelid = p_tbl and i.indisprimary
$$;

create or replace function public.ddd_m21_where(p_key jsonb) returns text
language sql immutable as $$
  select string_agg(format('%I::text = %L', k, v), ' and ') from jsonb_each_text(p_key) e(k, v)
$$;

-- plain (non-generated) columns, optionally without some
create or replace function public.ddd_m21_cols(p_tbl regclass, p_skip text[] default '{}') returns text[]
language sql stable as $$
  select array_agg(a.attname::text order by a.attnum)
  from pg_attribute a
  where a.attrelid = p_tbl and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
    and not (a.attname::text = any(p_skip))
$$;

create or replace function public.ddd_m21_log(p_merge uuid, p_pair int, p_action text, p_tbl text, p_key jsonb,
                                              p_fk text, p_old uuid, p_row jsonb) returns void
language sql as $$
  insert into backup_021.rows(merge_id, pair_no, action, tbl, key, fk_col, old_value, row_data)
  values (p_merge, p_pair, p_action, p_tbl, p_key, p_fk, p_old, p_row)
$$;

-- delete one row (backed up)
create or replace function public.ddd_m21_del(p_merge uuid, p_pair int, p_tbl regclass, p_key jsonb) returns void
language plpgsql as $$
declare r jsonb;
begin
  execute format('select to_jsonb(t) from %s t where %s', p_tbl, public.ddd_m21_where(p_key)) into r;
  if r is null then return; end if;
  perform public.ddd_m21_log(p_merge, p_pair, 'deleted', p_tbl::text, p_key, null, null, r);
  execute format('delete from %s where %s', p_tbl, public.ddd_m21_where(p_key));
end $$;

-- ---------- merge ONE pair ----------
create or replace function public.ddd_m21_merge_one(p_merge uuid, p_pair int, p_kind text, p_keep uuid, p_dup uuid)
returns jsonb language plpgsql as $$
declare
  ent regclass := ('public.' || p_kind)::regclass;
  rep jsonb := '[]';
  fk record; r record; pk text[]; n int; k jsonb; kbefore jsonb; drow jsonb; krow jsonb;
  cols text[]; c text; diffs text := '';
  skip text[];
begin
  if p_kind not in ('students', 'employees') then raise exception 'kind must be students or employees'; end if;
  if p_keep = p_dup then raise exception 'keep and dup are the same id'; end if;
  execute format('select to_jsonb(t) from %s t where id = $1 for update', ent) into krow using p_keep;
  execute format('select to_jsonb(t) from %s t where id = $1 for update', ent) into drow using p_dup;
  if krow is null then raise exception 'keep % not found in %', p_keep, p_kind; end if;
  if drow is null then raise exception 'dup % not found in %', p_dup, p_kind; end if;

  -- 1) special tables (unique per student / staff)
  if p_kind = 'students' then
    for r in select d.id did, d.month, k2.id kid,
                    (d.paid_amount > 0 or exists (select 1 from fee_payments f where f.due_id = d.id)) dpaid,
                    (k2.paid_amount > 0 or exists (select 1 from fee_payments f where f.due_id = k2.id)) kpaid
             from monthly_dues d join monthly_dues k2 on k2.student_id = p_keep and k2.month = d.month
             where d.student_id = p_dup loop
      if not r.dpaid then
        perform public.ddd_m21_del(p_merge, p_pair, 'public.monthly_dues', jsonb_build_object('id', r.did));
        rep := rep || jsonb_build_array('monthly_dues ' || to_char(r.month, 'Mon YY') || ': duplicate unpaid due of dup removed');
      elsif not r.kpaid then
        perform public.ddd_m21_del(p_merge, p_pair, 'public.monthly_dues', jsonb_build_object('id', r.kid));
        rep := rep || jsonb_build_array('monthly_dues ' || to_char(r.month, 'Mon YY') || ': keep''s unpaid due removed, dup''s paid due moved');
      else
        raise exception 'BLOCKED: % par dono records ki payment hai — manual check chahiye', to_char(r.month, 'Mon YYYY');
      end if;
    end loop;
    if to_regclass('public.student_attendance') is not null then
      for r in select d.id from student_attendance d where d.student_id = p_dup
               and exists (select 1 from student_attendance k2 where k2.student_id = p_keep and k2.date = d.date) loop
        perform public.ddd_m21_del(p_merge, p_pair, 'public.student_attendance', jsonb_build_object('id', r.id));
      end loop;
    end if;
    -- beds: keep already has a bed -> free dup's bed
    if exists (select 1 from beds where student_id = p_keep) or (krow->>'current_bed_id') is not null then
      for r in select * from beds where student_id = p_dup loop
        perform public.ddd_m21_log(p_merge, p_pair, 'updated', 'public.beds', jsonb_build_object('id', r.id), null, null, to_jsonb(r));
        update beds set student_id = null, bed_status = 'vacant' where id = r.id;
        rep := rep || jsonb_build_array('bed ' || r.bed_number || ': dup ka bed khaali kiya (keep ke paas pehle se bed hai)');
      end loop;
    elsif (drow->>'current_bed_id') is not null then
      perform public.ddd_m21_log(p_merge, p_pair, 'updated', 'public.students', jsonb_build_object('id', p_keep), null, null, krow);
      perform public.ddd_m21_log(p_merge, p_pair, 'updated', 'public.students', jsonb_build_object('id', p_dup), null, null, drow);
      update students set current_bed_id = null where id = p_dup;
      update students set current_bed_id = (drow->>'current_bed_id')::uuid where id = p_keep;
      rep := rep || jsonb_build_array('bed: dup ka bed keep ko diya');
    end if;
  else
    for r in select d.month from salary_runs d join salary_runs k2 on k2.employee_id = p_keep and k2.month = d.month
             where d.employee_id = p_dup loop
      raise exception 'BLOCKED: % ki salary dono staff records par bani hai — manual check chahiye', to_char(r.month, 'Mon YYYY');
    end loop;
    for r in select d.id from staff_attendance d where d.employee_id = p_dup
             and exists (select 1 from staff_attendance k2 where k2.employee_id = p_keep and k2.date = d.date) loop
      perform public.ddd_m21_del(p_merge, p_pair, 'public.staff_attendance', jsonb_build_object('id', r.id));
    end loop;
    if exists (select 1 from staff_salary_profile where employee_id = p_keep)
       and exists (select 1 from staff_salary_profile where employee_id = p_dup) then
      select to_jsonb(s) into kbefore from staff_salary_profile s where employee_id = p_keep;
      perform public.ddd_m21_log(p_merge, p_pair, 'updated', 'public.staff_salary_profile', jsonb_build_object('employee_id', p_keep), null, null, kbefore);
      update staff_salary_profile k2 set
        monthly_salary = case when d.monthly_salary > 0 then d.monthly_salary else k2.monthly_salary end,
        pf_applicable = d.pf_applicable or k2.pf_applicable,
        uan = coalesce(nullif(d.uan, ''), k2.uan), pf_number = coalesce(nullif(d.pf_number, ''), k2.pf_number),
        pf_wage = coalesce(d.pf_wage, k2.pf_wage), bank_account = coalesce(nullif(d.bank_account, ''), k2.bank_account),
        ifsc = coalesce(nullif(d.ifsc, ''), k2.ifsc), upi_id = coalesce(nullif(d.upi_id, ''), k2.upi_id)
      from staff_salary_profile d where d.employee_id = p_dup and k2.employee_id = p_keep;
      perform public.ddd_m21_del(p_merge, p_pair, 'public.staff_salary_profile', jsonb_build_object('employee_id', p_dup));
      rep := rep || jsonb_build_array('salary profile: dup ki bhari values keep par copy');
    end if;
  end if;

  -- 2) move every remaining row that points at dup (live foreign keys)
  for fk in
    select c.conrelid::regclass as tbl, a.attname::text as col
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f' and c.confrelid = ent and array_length(c.conkey, 1) = 1
  loop
    if fk.tbl = ent then continue; end if;   -- no self references expected
    pk := public.ddd_m21_pk(fk.tbl);
    if pk is null then raise exception 'BLOCKED: % has no primary key — manual', fk.tbl; end if;
    -- a unique index on this column (other than the handled ones) would clash -> stop
    if exists (select 1 from pg_index i join pg_attribute a2 on a2.attrelid = i.indrelid and a2.attnum = any(i.indkey)
               where i.indrelid = fk.tbl and i.indisunique and not i.indisprimary and a2.attname = fk.col)
       and fk.tbl::text not in ('monthly_dues', 'student_attendance', 'staff_attendance', 'salary_runs') then
      execute format('select count(*) from %s where %I = $1', fk.tbl, fk.col) into n using p_dup;
      if n > 0 then raise exception 'BLOCKED: unique index on %.% — manual', fk.tbl, fk.col; end if;
    end if;
    n := 0;
    for k in execute format('select jsonb_build_object(%s) from %s t where %I = $1',
                            (select string_agg(format('%L, t.%I', x, x), ', ') from unnest(pk) x), fk.tbl, fk.col) using p_dup loop
      -- key after the move (the FK column may be part of the primary key)
      perform public.ddd_m21_log(p_merge, p_pair, 'moved', fk.tbl::text,
        case when k ? fk.col then jsonb_set(k, array[fk.col], to_jsonb(p_keep::text)) else k end, fk.col, p_dup, null);
      n := n + 1;
    end loop;
    if n > 0 then
      execute format('update %s set %I = $1 where %I = $2', fk.tbl, fk.col, fk.col) using p_keep, p_dup;
      rep := rep || jsonb_build_array(fk.tbl::text || '.' || fk.col || ': ' || n || ' row(s) moved to keep');
    end if;
  end loop;

  -- 3) copy dup's filled values onto keep (never blank out keep)
  skip := case when p_kind = 'students' then array['id','created_at','created_by','updated_at','paid_till','current_bed_id']
               else array['id','created_at','created_by','updated_at'] end;
  cols := public.ddd_m21_cols(ent, skip);
  execute format('select to_jsonb(t) from %s t where id = $1', ent) into kbefore using p_keep;
  foreach c in array cols loop
    if nullif(drow->>c, '') is not null and (drow->>c) is distinct from (kbefore->>c) then
      diffs := diffs || c || ': ' || coalesce(kbefore->>c, '∅') || ' → ' || (drow->>c) || '; ';
    end if;
  end loop;
  if diffs <> '' then
    perform public.ddd_m21_log(p_merge, p_pair, 'updated', ent::text, jsonb_build_object('id', p_keep), null, null, kbefore);
    execute format('update %s k set %s from %s d where k.id = $1 and d.id = $2', ent,
      (select string_agg(format('%I = coalesce(nullif(d.%I::text, %L)::%s, k.%I)', x, x, '',
               format_type(a.atttypid, a.atttypmod), x), ', ')
         from unnest(cols) x join pg_attribute a on a.attrelid = ent and a.attname = x), ent)
      using p_keep, p_dup;
    rep := rep || jsonb_build_array('keep updated with dup values: ' || diffs);
  else
    rep := rep || jsonb_build_array('keep ki details already same (kuch copy nahi hua)');
  end if;

  -- 4) nothing may still point at dup, then delete dup
  for fk in
    select c.conrelid::regclass as tbl, a.attname::text as col
    from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
    where c.contype = 'f' and c.confrelid = ent and array_length(c.conkey, 1) = 1 and c.conrelid <> ent
  loop
    execute format('select count(*) from %s where %I = $1', fk.tbl, fk.col) into n using p_dup;
    if n > 0 then raise exception 'BLOCKED: %.% still has % row(s) of dup', fk.tbl, fk.col, n; end if;
  end loop;
  perform public.ddd_m21_del(p_merge, p_pair, ent, jsonb_build_object('id', p_dup));
  rep := rep || jsonb_build_array('dup record deleted (backup mein hai)');
  if p_kind = 'students' then perform public.recompute_paid_till(p_keep); end if;
  return rep;
end $$;

-- ---------- merge a list of pairs (dry run or apply) ----------
create or replace function public.ddd_merge_duplicates(p_pairs jsonb, p_apply boolean default false)
returns table(merge_id uuid, pair_no int, kind text, keep_id uuid, dup_id uuid, step text)
language plpgsql as $$
declare
  v_merge uuid := gen_random_uuid();
  v_out jsonb := '[]';
  v_n0 bigint; v_s0 numeric; v_n1 bigint; v_s1 numeric;
  p jsonb; i int := 0; rep jsonb; v_blocked int := 0; seen uuid[] := '{}';
begin
  if jsonb_typeof(p_pairs) <> 'array' or jsonb_array_length(p_pairs) = 0 then raise exception 'pairs list khaali hai'; end if;
  for p in select * from jsonb_array_elements(p_pairs) loop
    if (p->>'dup')::uuid = any(seen) or (p->>'keep')::uuid = any(seen) then
      raise exception 'id % list mein do baar hai — ek record ek hi pair mein rakhein', coalesce((p->>'dup'), (p->>'keep'));
    end if;
    seen := seen || (p->>'dup')::uuid || (p->>'keep')::uuid;
  end loop;
  v_n0 := (select count(*) from fee_payments);
  v_s0 := (select coalesce(sum(amount), 0) from fee_payments);
  begin
    if p_apply then insert into backup_021.merge_log(merge_id, pairs) values (v_merge, p_pairs); end if;
    for p in select * from jsonb_array_elements(p_pairs) loop
      i := i + 1;
      begin
        rep := public.ddd_m21_merge_one(v_merge, i, p->>'kind', (p->>'keep')::uuid, (p->>'dup')::uuid);
        v_out := v_out || (select coalesce(jsonb_agg(jsonb_build_object('pair', i, 'kind', p->>'kind', 'keep', p->>'keep', 'dup', p->>'dup', 'step', x)), '[]')
                           from jsonb_array_elements_text(rep) x);
      exception when others then
        if p_apply then raise; end if;
        v_blocked := v_blocked + 1;
        v_out := v_out || jsonb_build_array(jsonb_build_object('pair', i, 'kind', p->>'kind', 'keep', p->>'keep', 'dup', p->>'dup', 'step', '⛔ ' || sqlerrm));
      end;
    end loop;
    v_n1 := (select count(*) from fee_payments);
    v_s1 := (select coalesce(sum(amount), 0) from fee_payments);
    if v_n1 <> v_n0 or v_s1 <> v_s0 then
      raise exception 'SAFETY STOP: fee_payments badal gaye (% / % -> % / %) — kuch apply nahi hua', v_n0, v_s0, v_n1, v_s1;
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('pair', 0, 'kind', 'check', 'step',
      'fee_payments same: ' || v_n1 || ' rows, total ' || v_s1 || case when p_apply then ' — APPLIED' else ' — DRY RUN (kuch save nahi hua)' end
      || case when v_blocked > 0 then ' — ' || v_blocked || ' pair BLOCKED' else '' end));
    if not p_apply then raise exception 'DDD_DRY_RUN'; end if;
  exception when others then
    if sqlerrm <> 'DDD_DRY_RUN' then raise; end if;
  end;
  return query
    select case when p_apply then v_merge end, (x->>'pair')::int, x->>'kind',
           nullif(x->>'keep', '')::uuid, nullif(x->>'dup', '')::uuid, x->>'step'
    from jsonb_array_elements(v_out) x;
end $$;

-- ---------- undo one applied merge ----------
create or replace function public.ddd_merge_undo(p_merge uuid)
returns table(step text) language plpgsql as $$
declare
  r record; cols text[]; pk text[]; n int := 0; stu uuid;
begin
  if not exists (select 1 from backup_021.merge_log where merge_id = p_merge) then raise exception 'merge % not found', p_merge; end if;
  if exists (select 1 from backup_021.merge_log where merge_id = p_merge and undone_at is not null) then raise exception 'merge % already undone', p_merge; end if;
  for r in select * from backup_021.rows where merge_id = p_merge order by seq desc loop
    if r.action = 'deleted' then
      -- re-insert; if a trigger already re-created the row (e.g. empty salary profile), overwrite it with the backup
      cols := public.ddd_m21_cols(r.tbl::regclass);
      pk := public.ddd_m21_pk(r.tbl::regclass);
      execute format('insert into %s (%s) select %s from jsonb_populate_record(null::%s, $1) on conflict (%s) do update set %s', r.tbl,
        (select string_agg(format('%I', x), ', ') from unnest(cols) x),
        (select string_agg(format('%I', x), ', ') from unnest(cols) x), r.tbl,
        (select string_agg(format('%I', x), ', ') from unnest(pk) x),
        coalesce((select string_agg(format('%I = excluded.%I', x, x), ', ') from unnest(cols) x where not (x = any(pk))),
                 format('%I = excluded.%I', pk[1], pk[1]))) using r.row_data;
    elsif r.action = 'moved' then
      execute format('update %s set %I = $1 where %s', r.tbl, r.fk_col, public.ddd_m21_where(r.key)) using r.old_value;
    else
      cols := public.ddd_m21_cols(r.tbl::regclass, array(select jsonb_object_keys(r.key)));
      execute format('update %s t set (%s) = (select %s from jsonb_populate_record(null::%s, $1) x) where %s', r.tbl,
        (select string_agg(format('%I', x), ', ') from unnest(cols) x),
        (select string_agg(format('x.%I', x), ', ') from unnest(cols) x), r.tbl, public.ddd_m21_where(r.key)) using r.row_data;
    end if;
    n := n + 1;
  end loop;
  update backup_021.merge_log set undone_at = now() where merge_id = p_merge;
  for stu in select (x->>'keep')::uuid from backup_021.merge_log m, jsonb_array_elements(m.pairs) x
             where m.merge_id = p_merge and x->>'kind' = 'students'
             union select (x->>'dup')::uuid from backup_021.merge_log m, jsonb_array_elements(m.pairs) x
             where m.merge_id = p_merge and x->>'kind' = 'students' loop
    perform public.recompute_paid_till(stu);
  end loop;
  return query select 'undo done: ' || n || ' change(s) reversed';
end $$;

-- only the SQL Editor (postgres) may run these — never the app
revoke all on function public.ddd_m21_pk(regclass) from public, anon, authenticated;
revoke all on function public.ddd_m21_where(jsonb) from public, anon, authenticated;
revoke all on function public.ddd_m21_cols(regclass, text[]) from public, anon, authenticated;
revoke all on function public.ddd_m21_log(uuid, int, text, text, jsonb, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.ddd_m21_del(uuid, int, regclass, jsonb) from public, anon, authenticated;
revoke all on function public.ddd_m21_merge_one(uuid, int, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.ddd_merge_duplicates(jsonb, boolean) from public, anon, authenticated;
revoke all on function public.ddd_merge_undo(uuid) from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- verify (all true):
-- select 'merge tool installed' chk, to_regprocedure('public.ddd_merge_duplicates(jsonb,boolean)') is not null ok
-- union all select 'app cannot call it', not has_function_privilege('authenticated', 'public.ddd_merge_duplicates(jsonb,boolean)', 'execute')
-- union all select 'backup tables', to_regclass('backup_021.rows') is not null and to_regclass('backup_021.merge_log') is not null;
