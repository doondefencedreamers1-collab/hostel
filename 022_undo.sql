-- =====================================================================
-- 022_undo.sql — 022 ko wapas (backup_022.meta se). Data rows nahi badalte.
-- Note: undo ke baad audit wale sab khatre wapas khul jaate hain.
-- =====================================================================
begin;

do $$
begin
  if to_regclass('backup_022.meta') is null then raise exception 'undo aborted: backup_022.meta not found'; end if;
end $$;

-- functions (generate_monthly_dues, delete guards, handle_new_user) back to saved text
do $$
declare r record;
begin
  for r in select k, v from backup_022.meta where k like 'fn:%' loop
    execute (r.v #>> '{}');
  end loop;
end $$;

-- search_path config
do $$
declare r record; f text;
begin
  for r in select k, v from backup_022.meta where k like 'cfg:%' loop
    f := substr(r.k, 5);
    if to_regprocedure(f) is null then continue; end if;
    execute format('alter function %s reset all', f);
    if jsonb_typeof(r.v) = 'array' and exists (select 1 from jsonb_array_elements_text(r.v) x where x like 'search_path=%') then
      execute format('alter function %s set search_path = %s', f,
                     (select substr(x, 13) from jsonb_array_elements_text(r.v) x where x like 'search_path=%' limit 1));
    end if;
  end loop;
exception when others then
  raise notice 'search_path restore: %', sqlerrm;
end $$;

-- function execute rights
do $$
declare r record; f text;
begin
  for r in select k, v from backup_022.meta where k like 'acl:%' loop
    f := substr(r.k, 5);
    if to_regprocedure(f) is null then continue; end if;
    if (r.v->>'public')::boolean then execute format('grant execute on function %s to public', f); end if;
    if (r.v->>'anon')::boolean then execute format('grant execute on function %s to anon', f); end if;
    if (r.v->>'authenticated')::boolean then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;

-- fee_payments FKs back to saved definition
do $$
declare r record;
begin
  for r in select substr(k, 4) as conname, v from backup_022.meta where k like 'fk:%' loop
    execute format('alter table public.fee_payments drop constraint if exists %I', r.conname);
    execute format('alter table public.fee_payments add constraint %I %s', r.conname, r.v->>'def');
  end loop;
end $$;

-- policies: drop the 022 versions, recreate the saved ones
drop policy if exists docs_director on public.documents;
do $$
declare p jsonb;
begin
  for p in select * from jsonb_array_elements((select v from backup_022.meta where k = 'policies')) loop
    execute format('drop policy if exists %I on public.%I', p->>'name', p->>'table');
    execute format('create policy %I on public.%I as %s for %s to %s%s%s', p->>'name', p->>'table', p->>'permissive', p->>'cmd',
      (select string_agg(case when x = 'public' then 'public' else quote_ident(x) end, ', ') from jsonb_array_elements_text(p->'roles') x),
      case when p->>'qual' is not null then ' using (' || (p->>'qual') || ')' else '' end,
      case when p->>'check' is not null then ' with check (' || (p->>'check') || ')' else '' end);
  end loop;
end $$;

-- anon table / sequence rights
do $$
declare g jsonb;
begin
  for g in select * from jsonb_array_elements((select v from backup_022.meta where k = 'anon_grants')) loop
    if to_regclass(g->>'t') is not null then execute format('grant %s on %s to anon', g->>'p', g->>'t'); end if;
  end loop;
  for g in select * from jsonb_array_elements(coalesce((select v from backup_022.meta where k = 'anon_seq_grants'), '[]')) loop
    if to_regclass(g->>'s') is null then continue; end if;
    if (g->>'usage')::boolean then execute format('grant usage on sequence %s to anon', g->>'s'); end if;
    if (g->>'select')::boolean then execute format('grant select on sequence %s to anon', g->>'s'); end if;
    if (g->>'update')::boolean then execute format('grant update on sequence %s to anon', g->>'s'); end if;
  end loop;
end $$;

commit;
notify pgrst, 'reload schema';

-- check (true): select has_function_privilege('anon', 'public.generate_monthly_dues(date)', 'execute') as undone;
