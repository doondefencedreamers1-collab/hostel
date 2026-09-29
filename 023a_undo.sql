-- =====================================================================
-- 023a_undo.sql — 023a wapas: generate_salary purana code + September rows wapas
-- (jo employee ka September row dobara ban chuka hai, uska purana row nahi aayega)
-- =====================================================================
begin;

do $$
declare cols text; v_def text;
begin
  if to_regclass('backup_023.salary_runs') is null then
    raise exception '023a undo aborted: backup_023 nahi mila.';
  end if;
  v_def := (select v #>> '{}' from backup_023.meta where k = 'fn:generate_salary(date)');
  if v_def is not null then
    execute v_def;
  end if;

  cols := (select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
             from information_schema.columns c
            where c.table_schema = 'public' and c.table_name = 'salary_runs' and c.is_generated = 'NEVER'
              and exists (select 1 from information_schema.columns b
                          where b.table_schema = 'backup_023' and b.table_name = 'salary_runs' and b.column_name = c.column_name));
  execute format('insert into public.salary_runs (%1$s) select %1$s from backup_023.salary_runs b
                  where not exists (select 1 from public.salary_runs s where s.id = b.id or (s.employee_id = b.employee_id and s.month = b.month))', cols);

  cols := (select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
             from information_schema.columns c
            where c.table_schema = 'public' and c.table_name = 'salary_edits' and c.is_generated = 'NEVER');
  execute format('insert into public.salary_edits (%1$s) select %1$s from backup_023.salary_edits b
                  where exists (select 1 from public.salary_runs s where s.id = b.run_id)
                    and not exists (select 1 from public.salary_edits x where x.id = b.id)', cols);
end $$;

revoke all on function public.generate_salary(date) from public, anon;
grant execute on function public.generate_salary(date) to authenticated;

notify pgrst, 'reload schema';

commit;
