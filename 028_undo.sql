-- =====================================================================
-- 028_undo.sql - 028_fee_regen.sql ko wapas leta hai
--
--  PEHLE naya app hata kar purana app lagayein (naya app ddd_fee_change bulata hai).
--  Pehle backup lein. Agar 029 / 030 / 031 bhi lage hain aur woh 028 ki cheezein use
--  karte hain to yeh file ruk jaayegi: pehle unka undo (ulte kram mein).
--
--  KYA KARTA HAI
--   1. generate_monthly_dues ko bilkul 026 text par wapas (dobara Generate fee nahi badlega).
--   2. 028 ke triggers aur functions hatata hai (FEES-3 rok, auto price, ddd_fee_change).
--   3. monthly_dues.auto_fee aur auto_amount columns hatata hai (sirf hisaab ki madad, paise nahi).
--   4. ddd_fee_change_log: khali ho to hatti hai, record ho to RAKHI jaati hai.
--  Jo bill fee change se nayi fee par aa chuke hain woh waise hi rehte hain (Director ka faisla),
--  jama paise aur payments kabhi nahi badalte.
--  Ek transaction. Do baar chalana safe. Aakhir mein ek line ka result dikhega.
-- =====================================================================
begin;

set local lock_timeout = '15s';

do $pre$
declare
  h   text;
  v_x text;
begin
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.generate_monthly_dues(date)'));
  if h is null or h not in ('387a1c4bbf3befd90af6d1d67e2f745e', 'dc1b915e9229ae9b6952968878104450') then
    raise exception '028 UNDO RUKA: generate_monthly_dues na 028 wala hai na 026 wala (%). Mujhe batayein. Kuch nahi badla.', h;
  end if;
  -- koi aur (baad wali migration) 028 ki cheez use karta hai?
  v_x := (select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.proname not in ('generate_monthly_dues', 'ddd_fee_change', 'ddd_fee_change_run', 'ddd_fee_reprice_due',
                                   'ddd_dues_regen_month', 'ddd_student_has_dues', 'ddd_students_fee_guard', 'ddd_dues_auto_price')
             and p.prosrc ~ '(auto_amount|auto_fee|ddd_fee_change|ddd_dues_regen_month|ddd_fee_reprice_due|ddd_student_has_dues)');
  if v_x is not null then
    raise exception '028 UNDO RUKA: ye functions 028 ki cheezein use karte hain: %. Pehle unki migration ka undo karein. Kuch nahi badla.', v_x;
  end if;
end
$pre$;

-- 1. generate_monthly_dues = bilkul 026 text
create or replace function public.generate_monthly_dues(p_month date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  cnt int := 0; r record;
  m_start date := date_trunc('month', p_month)::date;
  m_end   date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_cur   date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  -- called through the API (app / anyone with the key)? SQL Editor = no.
  v_api   boolean := auth.uid() is not null or session_user = 'authenticator';
  v_fee   numeric;
  v_to    date;
  v_id    uuid;
begin
  if p_month is null then raise exception 'Month required'; end if;
  if v_api then
    if auth.uid() is null then
      raise exception 'Login required' using errcode = '42501';
    end if;
    if not (public.is_director() or public.is_accountant() or exists (select 1 from public.my_hostels())) then
      raise exception 'Sirf Director / Manager dues generate kar sakte hain' using errcode = '42501';
    end if;
    if not (m_start = v_cur or (m_start = (v_cur - interval '1 month')::date and extract(day from v_today) <= 5)) then
      raise exception 'Sirf is mahine (%) ki dues generate ho sakti hain', to_char(v_cur, 'Mon YYYY') using errcode = '42501';
    end if;
  end if;
  for r in
    -- 026: wapas aaya student = bill wapsi ki tareekh se (joining_date ki jagah wapsi, jo baad mein ho)
    select id, hostel_id, monthly_fee, exit_date, greatest(joining_date, coalesce(rejoined_on, joining_date)) as joining_date
      from public.students
    where status = 'active'
      and joining_date is not null
      and date_trunc('month', greatest(joining_date, coalesce(rejoined_on, joining_date)))::date <= m_start
      and coalesce(monthly_fee, 0) > 0
      and merged_into is null                                          -- 026: merged record = no bill
      and (exit_date is null or exit_date >= greatest(m_start, joining_date, coalesce(rejoined_on, joining_date)))   -- 026: left before this month = no bill
  loop
    v_fee := public.ddd_stay_fee(r.monthly_fee, r.joining_date, r.exit_date, m_start);
    v_to  := least(m_end, coalesce(r.exit_date, m_end));
    v_id  := null;
    insert into public.monthly_dues(student_id, hostel_id, month, fee_amount, period_from, period_to)
    values (r.id, r.hostel_id, m_start, v_fee, greatest(m_start, r.joining_date), v_to)
    on conflict (student_id, month) do nothing
    returning id into v_id;
    -- 026: leaving month made short -> log it, so Active again = full bill back
    if v_id is not null and v_to < m_end then
      insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to, old_period_from,
                                           new_fee_amount, new_period_to, new_period_from, amount_note, reason, batch)
      values (v_id, r.id, m_start, 'prorate', public.ddd_month_fee(r.monthly_fee, r.joining_date, m_start), 0, 'pending', m_end, greatest(m_start, r.joining_date),
              v_fee, v_to, greatest(m_start, r.joining_date), public.ddd_month_fee(r.monthly_fee, r.joining_date, m_start) - v_fee,
              'Naya bill: exit ' || to_char(r.exit_date, 'DD-MM-YYYY') || ' tak ke din',
              coalesce(nullif(current_setting('ddd.batch', true), ''), 'generate_monthly_dues'));
    end if;
    cnt := cnt + 1;
  end loop;
  return cnt;
end; $function$;

revoke all on function public.generate_monthly_dues(date) from public, anon;
grant execute on function public.generate_monthly_dues(date) to authenticated;

-- 2. triggers + functions
drop trigger if exists trg_monthly_dues_auto_price on public.monthly_dues;
drop trigger if exists trg_students_fee_guard on public.students;
drop function if exists public.ddd_fee_change(uuid, numeric, date, boolean);
drop function if exists public.ddd_fee_change_run(uuid, numeric, date);
drop function if exists public.ddd_dues_regen_month(date);
drop function if exists public.ddd_fee_reprice_due(uuid, numeric, text, text);
drop function if exists public.ddd_dues_auto_price();
drop function if exists public.ddd_students_fee_guard();
drop function if exists public.ddd_student_has_dues(uuid);

-- 3. columns
alter table public.monthly_dues drop column if exists auto_fee;
alter table public.monthly_dues drop column if exists auto_amount;

-- 4. log table: khali = hatao, record hai = rakho
do $log$
begin
  if to_regclass('public.ddd_fee_change_log') is not null then
    if exists (select 1 from public.ddd_fee_change_log) then
      perform set_config('ddd028.undo_note', 'ddd_fee_change_log mein record hai - rakhi gayi.', true);
    else
      drop table public.ddd_fee_change_log;
      perform set_config('ddd028.undo_note', 'ddd_fee_change_log khali thi - hata di.', true);
    end if;
  else
    perform set_config('ddd028.undo_note', 'ddd_fee_change_log pehle se nahi thi.', true);
  end if;
end
$log$;

do $verify$
declare
  h text;
begin
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.generate_monthly_dues(date)'));
  if h is distinct from 'dc1b915e9229ae9b6952968878104450' then
    raise exception '028 UNDO VERIFY FAIL: generate_monthly_dues 026 text nahi bana (%). Kuch nahi badla.', h;
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'monthly_dues' and column_name in ('auto_fee', 'auto_amount'))
     or to_regprocedure('public.ddd_fee_change(uuid,numeric,date,boolean)') is not null then
    raise exception '028 UNDO VERIFY FAIL: 028 ki cheezein abhi bhi hain. Kuch nahi badla.';
  end if;
  perform set_config('ddd028.undo_result', '028 UNDO HO GAYA: generate_monthly_dues wapas 026 wala, 028 triggers / functions / columns hate. '
                     || current_setting('ddd028.undo_note', true), false);
end
$verify$;

commit;

notify pgrst, 'reload schema';

select coalesce(nullif(current_setting('ddd028.undo_result', true), ''), '028 UNDO: result nahi mila - upar error dekhein') as result;

-- ---------- ROLLBACK ----------
-- Is undo ko wapas lena ho (028 dobara lagani ho) to 028_fee_regen.sql poori file phir se chalayein.
