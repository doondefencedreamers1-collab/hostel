-- =====================================================================
-- 024_run_checks.sql — Receive Fee date range. Supabase SQL Editor mein
-- STEP by STEP (har STEP alag query tab mein). 022 pehle live hona chahiye.
-- =====================================================================

-- ---------- STEP 1: CONFIRM (read-only) — pehli 4 rows true ----------
select '022 live (anon cannot generate dues)' chk, (not has_function_privilege('anon', 'public.generate_monthly_dues(date)', 'execute'))::text ok
union all select 'record_fee_payment = repo 017',
  ((select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)')) = '35422694e51971f79ef6aa415f67af65')::text
union all select 'record_partial_payment = repo 017',
  ((select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)')) = 'c778c5ffd054b7b62d2ed3524e0318f3')::text
union all select 'compute_paid_till = repo 017',
  ((select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.compute_paid_till(uuid,date,numeric)')) = '3a7fe7e6126470441ebb723142fa4ce7')::text
union all select 'info: dues rows', (select count(*) from public.monthly_dues)::text
union all select 'info: partly paid dues (paid > 0, pending > 0)',
  (select count(*) from public.monthly_dues where coalesce(pending, 0) > 0 and coalesce(paid_amount, 0) + coalesce(discount, 0) > 0)::text
union all select 'info: 024 already run?', (to_regprocedure('public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)') is not null)::text;

-- ---------- STEP 2: BACKUP (undo isi se chalega) ----------
create schema if not exists backup_024;
revoke all on schema backup_024 from public, anon, authenticated;
create table if not exists backup_024.meta (k text primary key, v jsonb not null, saved_at timestamptz not null default now());
create table if not exists backup_024.students_paid_till (id uuid primary key, paid_till date);
insert into backup_024.meta(k, v)
select 'fn:record_fee_payment', to_jsonb(pg_get_functiondef('public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)'::regprocedure))
on conflict (k) do nothing;
insert into backup_024.meta(k, v)
select 'fn:record_partial_payment', to_jsonb(pg_get_functiondef('public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)'::regprocedure))
on conflict (k) do nothing;
insert into backup_024.meta(k, v)
select 'fn:compute_paid_till', to_jsonb(pg_get_functiondef('public.compute_paid_till(uuid,date,numeric)'::regprocedure))
on conflict (k) do nothing;
insert into backup_024.students_paid_till(id, paid_till)
select id, paid_till from public.students
on conflict (id) do nothing;
select k, saved_at::text from backup_024.meta
union all select 'students saved: ' || count(*), max(now())::text from backup_024.students_paid_till
order by 1;

-- ---------- STEP 3: DRY RUN (read-only) — partly paid dues: naya "paid_to" ----------
-- first_unpaid = true wale student ka Paid Till badal kar new_paid_to ho jayega
with d as (
  select d.id, s.full_name, h.code as hostel, d.student_id, d.month, d.fee_amount, d.discount, d.paid_amount, d.pending, s.paid_till,
         date_trunc('month', d.month)::date as ms,
         extract(day from (date_trunc('month', d.month) + interval '1 month - 1 day'))::int as dim,
         coalesce(d.period_from, date_trunc('month', d.month)::date) as pf,
         coalesce(d.period_to, (date_trunc('month', d.month) + interval '1 month - 1 day')::date) as pt,
         coalesce(d.paid_amount, 0) + coalesce(d.discount, 0) as got,
         case when coalesce(d.period_from, date_trunc('month', d.month)::date) <= date_trunc('month', d.month)::date
              then d.fee_amount else s.monthly_fee end as f
  from public.monthly_dues d join public.students s on s.id = d.student_id left join public.hostels h on h.id = s.hostel_id
  where coalesce(d.pending, 0) > 0 and coalesce(d.paid_amount, 0) + coalesce(d.discount, 0) > 0
)
select d.full_name, d.hostel, to_char(d.month, 'YYYY-MM') as month, d.fee_amount, d.paid_amount, d.pending,
       d.paid_till as paid_till_now,
       d.pf - 1 + (select max(j) from generate_series(0, d.pt - d.pf) j
                    where round(d.f * (extract(day from d.pf)::int - 1 + j) / d.dim, 0) - round(d.f * (extract(day from d.pf)::int - 1) / d.dim, 0) <= d.got) as new_paid_to,
       (d.id = (select x.id from public.monthly_dues x where x.student_id = d.student_id and coalesce(x.pending, 0) > 0
                 order by coalesce(x.period_from, x.month), x.month limit 1)) as first_unpaid
from d
order by d.hostel, d.full_name, d.month;

-- ---------- STEP 4: 024_fee_date_range.sql poori file chalayein ----------

-- ---------- STEP 5: VERIFY — sab ok = true ----------
drop table if exists pg_temp.v024;
create temp table v024 (chk text, ok boolean, detail text);
do $$
declare sid uuid; v_from date; msg text;
begin
  sid := (select s.id from public.students s
           where s.status = 'active' and s.joining_date is not null and coalesce(s.monthly_fee, 0) > 0 and s.exit_date is null
             and s.paid_till is not null
           order by s.created_at limit 1);
  if sid is not null then
    v_from := public.compute_paid_till(sid) + 1;
    begin
      perform public.record_fee_payment_range(sid, v_from, v_from + 9, 0.001);
      msg := 'RAN';
    exception when others then msg := sqlerrm;
    end;
    insert into v024 values ('range payment calculates (test, nothing saved)', msg like 'Amount mismatch: expected%', msg);
  end if;
end $$;
insert into v024
select 'paid_to column', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'monthly_dues' and column_name = 'paid_to'), ''
union all select 'paid_to trigger', exists (select 1 from pg_trigger where tgname = 'trg_monthly_dues_paid_to'), ''
union all select 'no dues without paid_to', not exists (select 1 from public.monthly_dues where paid_to is null), (select count(*) from public.monthly_dues where paid_to is null)::text || ' missing'
union all select 'paid_till matches for every student', not exists (select 1 from public.students s where s.paid_till is distinct from public.compute_paid_till(s.id)),
  (select count(*) from public.students s where s.paid_till is distinct from public.compute_paid_till(s.id))::text || ' different'
union all select 'app can call range + edit',
  has_function_privilege('authenticated', 'public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)', 'execute')
  and has_function_privilege('authenticated', 'public.edit_fee_payment_dates(uuid,date,date,text)', 'execute'), ''
union all select 'anon cannot call range / edit / months / partial',
  not has_function_privilege('anon', 'public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)', 'execute')
  and not has_function_privilege('anon', 'public.edit_fee_payment_dates(uuid,date,date,text)', 'execute')
  and not has_function_privilege('anon', 'public.record_fee_payment(uuid,int,numeric,numeric,text,date,text,text,uuid)', 'execute')
  and not has_function_privilege('anon', 'public.record_partial_payment(uuid,numeric,text,date,text,text,uuid)', 'execute'), ''
union all select 'helpers internal only',
  not has_function_privilege('authenticated', 'public.ddd_fee_range_plan(uuid,date,date)', 'execute')
  and not has_function_privilege('authenticated', 'public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)', 'execute'), ''
union all select 'fee_payment_edits: RLS on, Director read only',
  (select relrowsecurity from pg_class where oid = 'public.fee_payment_edits'::regclass)
  and not has_table_privilege('anon', 'public.fee_payment_edits', 'select')
  and not has_table_privilege('authenticated', 'public.fee_payment_edits', 'insert'), ''
union all select 'dues triggers enabled again',
  not exists (select 1 from pg_trigger where tgrelid = 'public.monthly_dues'::regclass and not tgisinternal and tgenabled = 'D'), '';
select * from v024 order by ok, chk;
