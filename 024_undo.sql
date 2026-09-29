-- =====================================================================
-- 024_undo.sql — 024 wapas. Purane record_fee_payment / record_partial_payment /
-- compute_paid_till wapas; date-range RPC, Director date edit, paid_to hat jayenge.
-- Jo payments 024 ke baad jama hui wo rehti hain (amount sahi hain).
-- fee_payment_edits table sirf tab hategi jab khali ho.
-- =====================================================================
begin;

do $$
declare v_k text;
begin
  if to_regclass('backup_024.meta') is null then
    raise exception '024 undo aborted: backup_024 nahi mila.';
  end if;
  foreach v_k in array array['fn:record_fee_payment', 'fn:record_partial_payment', 'fn:compute_paid_till'] loop
    if not exists (select 1 from backup_024.meta where backup_024.meta.k = v_k) then
      raise exception '024 undo aborted: backup mein % nahi hai.', v_k;
    end if;
    execute (select v #>> '{}' from backup_024.meta where backup_024.meta.k = v_k);
  end loop;
end $$;

drop function if exists public.edit_fee_payment_dates(uuid, date, date, text);
drop function if exists public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean);
drop function if exists public.ddd_fee_range_plan(uuid, date, date);
drop trigger if exists trg_monthly_dues_paid_to on public.monthly_dues;
drop function if exists public.ddd_dues_set_paid_to();
drop function if exists public.ddd_due_paid_to(date, date, date, numeric, numeric, numeric, numeric);
drop function if exists public.ddd_due_full_fee(date, date, numeric, numeric);
drop function if exists public.ddd_cum_fee(numeric, int, int);
alter table public.monthly_dues drop column if exists paid_to;

do $$
begin
  if to_regclass('public.fee_payment_edits') is not null
     and not exists (select 1 from public.fee_payment_edits) then
    drop table public.fee_payment_edits;
  end if;
end $$;

revoke all on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid) to authenticated;
revoke all on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) from public, anon;
grant execute on function public.record_partial_payment(uuid,numeric,text,date,text,text,uuid) to authenticated;
revoke all on function public.compute_paid_till(uuid, date, numeric) from public, anon, authenticated;

update public.students s set paid_till = public.compute_paid_till(s.id)
 where s.paid_till is distinct from public.compute_paid_till(s.id);

notify pgrst, 'reload schema';

commit;
