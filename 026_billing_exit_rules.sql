-- =====================================================================
-- 026_billing_exit_rules.sql   (needs 014, 015, 017, 022, 024, 025 live)
-- DDD Hostel — billing rules jab student hostel CHHODTA hai (Phase 2)
--
--  Owner rules: fee 1 tareekh ko due. Joining month = baaki din (017).
--  Chhodne wala mahina = sirf rahe hue din. Chhodne ke BAAD koi bill nahi.
--  Galat bill DELETE nahi hota, VOID hota hai (fee 0, status void) aur
--  har badlav ka reason log mein likha jaata hai. Jama paise kabhi apne
--  aap nahi badalte (zyada jama ho to Director ke liye credit review).
--
--  1. Naya table ddd_dues_void_log = har void / prorate / restore /
--     credit_review (aur cleanup ke move / payment_move / merge_void /
--     payment_remove / fee_fix) ka record.
--     Sirf Director padh sakta hai. App se koi likh nahi sakta.
--  2. Naya column students.merged_into (duplicate cleanup ke liye, khali).
--     Sirf Director / SQL Editor bhar sakta hai (Manager nahi).
--  3. ddd_stay_fee(fee, joining, exit, month) = us mahine ke rahe hue din ki fee.
--  4. generate_monthly_dues: 022 wale security checks bilkul same. Naya:
--     jo student mahine se pehle chala gaya ya merge hua = bill nahi.
--     Chhodne wala mahina = sirf rahe hue din (period_to = exit date).
--  5. Guard: exit date ke baad wale mahine ka bill koi nahi bana sakta
--     (generate, Receive Fee, SQL sab). Exit wale mahine ka naya bill
--     apne aap rahe hue din tak kat jaata hai.
--  6. Student Left aur exit date khali = exit date aaj (IST), sirf SQL Editor.
--     App (API) se Left = Exit Date zaroori (warna saaf error).
--     Exit date lagte hi: exit ke baad ke UNPAID bill void, exit wala
--     mahina rahe hue din tak, zyada jama paise = credit review list
--     (jama paise wahi rehte hain, sirf unka baaki hissa hat jaata hai).
--     Discount rahe hue din ki fee par hi lagta hai (paid ho ya na ho).
--     Wapas Active (exit date khali) = wahi bill bilkul pehle jaise.
--     Dobara save karne se kuch double nahi hota.
--  7. Paid Till: void bill ko paid nahi gina jaata. Exit par kata bill
--     poore mahine ke rate se din ginta hai (Dates chuno bhi).
--  8. Merged purana record: naya bill nahi, Active nahi ho sakta.
--     Void (Cancelled) bill par fee nahi li ja sakti.
--  9. Director payment delete kare (refund) to Left / wapas aaye student ke
--     bill dobara exit date / wapsi ke hisaab se (exit ke baad phir koi bill nahi).
-- 10. Dashboard ginti mein merged purane record nahi gine jaate.
-- 11. Exit Date ki seema (app se, Director ke alawa sab): nayi / badli Exit
--     Date sirf Left student par, aaj se 10 din pehle tak aur aaj + 31 tak.
--     Director aur SQL Editor par koi rok nahi.
-- 12. Wapas aaya student: naya column students.rejoined_on (wapsi ki tareekh).
--     Galti se Left (sirf exit date khali) = saare bill wapas, pehle jaisa.
--     Wapas aaya (exit date khali + rejoined_on) = wapsi wale mahine se pehle
--     ke void / kate bill waise hi rehte hain (log mein rejoin_keep), wapsi
--     wala mahina sirf wapsi ki tareekh se, aage ke mahine poore. Generate
--     bhi wapsi ki tareekh se. Baad mein dobara Left = normal rules.
--     Do baar wapsi (Left, wapas, Left, wapas): pehli wapsi se pehle ke din
--     dobara bill nahi hote (bill pehli wapsi ki tareekh se hi rehta hai).
-- 13. App se Director ke alawa: bill ban chuka ho to Joining Date aage nahi
--     (ya khali nahi) kar sakte. Bill ka student / mahina / tareekh (period)
--     bhi sirf Director badal sakta hai (warna exit par bill galat kat jaata).
--
-- Is file ke chalne se KOI data row nahi badalti. Ek transaction, 2 baar
-- chalana safe. Pehle 026_check_before.sql, baad mein 026_check_after.sql
-- aur 026_check_behaviour.sql.   Undo: 026_undo.sql
-- Cleanup ke liye: transaction mein set_config(ddd.batch, naam, true) aur
-- set_config(ddd.reason, text, true) lagao to log mein wahi likha jaayega.
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------- pre-checks ----------
do $$
declare h text;
begin
  if to_regprocedure('public.generate_monthly_dues(date)') is null then raise exception '026 aborted: generate_monthly_dues(date) nahi mila'; end if;
  if to_regprocedure('public.ddd_month_fee(numeric,date,date)') is null then raise exception '026 aborted: 017 (ddd_month_fee) nahi mila'; end if;
  if to_regprocedure('public.ddd_is_api_caller()') is null then raise exception '026 aborted: 014 (ddd_is_api_caller) nahi mila'; end if;
  if to_regprocedure('public.compute_paid_till(uuid)') is null or to_regprocedure('public.recompute_paid_till(uuid)') is null then
    raise exception '026 aborted: 014 paid_till functions nahi mile';
  end if;
  if to_regprocedure('public.ddd_guard_due_discount()') is null
     or not exists (select 1 from pg_trigger where tgrelid = 'public.monthly_dues'::regclass and tgname = 'trg_monthly_dues_discount_guard') then
    raise exception '026 aborted: 015 due guard nahi mila';
  end if;
  if has_function_privilege('anon', 'public.generate_monthly_dues(date)', 'execute') then
    raise exception '026 aborted: 022 (security hotfix) pehle live hona chahiye';
  end if;
  if to_regprocedure('public.record_fee_payment_range(uuid,date,date,numeric,numeric,text,date,text,text,uuid,boolean)') is null
     or to_regprocedure('public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)') is null
     or not exists (select 1 from pg_trigger where tgrelid = 'public.monthly_dues'::regclass and tgname = 'trg_monthly_dues_paid_to') then
    raise exception '026 aborted: 024 (fee date range) pehle live hona chahiye';
  end if;
  if to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)') is null then
    raise exception '026 aborted: 025 (find similar students) pehle live hona chahiye';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'monthly_dues'
         and column_name in ('student_id', 'month', 'fee_amount', 'discount', 'paid_amount', 'pending', 'status', 'period_from', 'period_to', 'paid_to')) <> 10 then
    raise exception '026 aborted: monthly_dues columns expected jaise nahi hain';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'students'
         and column_name in ('status', 'exit_date', 'joining_date', 'monthly_fee', 'full_name', 'paid_till')) <> 6 then
    raise exception '026 aborted: students columns expected jaise nahi hain';
  end if;
  -- functions this file replaces must be the repo text (022 / 024) or already 026
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.generate_monthly_dues(date)'));
  -- 9a3861be = pichhli 026 (fix2), uske upar nayi 026 chalana theek
  if h is null or (h not in ('6ea13bd087be181629f4f770132473a6', 'dc1b915e9229ae9b6952968878104450') and h <> '9a3861bed71e727d7ed578fe54f8ad21') then
    raise exception '026 aborted: live generate_monthly_dues repo 022 se alag hai (%). Mujhe batayein.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.compute_paid_till(uuid,date,numeric)'));
  if h is null or h not in ('6e684ed7aad00f5128de11cb0c32f58b', 'd271416d96c5b317f390ee258737523a') then
    raise exception '026 aborted: live compute_paid_till repo 024 se alag hai (%). Mujhe batayein.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_dues_set_paid_to()'));
  if h is null or h not in ('4540a28a7b993d35e0d73b93944bfe31', '327e508d4ad8389c3c8a10232dbebe77') then
    raise exception '026 aborted: live ddd_dues_set_paid_to repo 024 se alag hai (%). Mujhe batayein.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_due_paid_to(date,date,date,numeric,numeric,numeric,numeric)'));
  if h is null or h not in ('00aad42d12d7d5491f7982a117dedb54', 'b6fb862ab3e8c55358d38605008dc1f7') then
    raise exception '026 aborted: live ddd_due_paid_to repo 024 se alag hai (%). Mujhe batayein.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_fee_range_plan(uuid,date,date)'));
  if h is null or h not in ('fef2cbbe57a653a64682250c53e7d35b', '6eb7654c1d987cc866106350fb505bc9') then
    raise exception '026 aborted: live ddd_fee_range_plan repo 024 se alag hai (%). Mujhe batayein.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.delete_fee_payment(uuid)'));
  -- e1b1fc2f = pichhli 026 (fix2), uske upar nayi 026 chalana theek
  if h is null or (h not in ('9f4b70c5afe489837501a4c704beb944', 'f323d01062d3076fdc28aad35a99698f') and h <> 'e1b1fc2fa5b01097e5412a911f83cd0f') then
    raise exception '026 aborted: live delete_fee_payment repo 014 se alag hai (%). Mujhe batayein.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.ddd_period_numbers(date,date,boolean,uuid[],boolean)'));
  if h is null or h not in ('73ccf7156242b084c78e8846e83dba97', 'e6b351cd6db37302dd0c77598569569e') then
    raise exception '026 aborted: live ddd_period_numbers repo 020 se alag hai (%). Mujhe batayein.', h;
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.dashboard_summary(date,date,uuid)'));
  if h is null or h not in ('ca1a205f641a06e99b6aab41d2293fd3', '19909a440bf16429d20185c3e2965432') then
    raise exception '026 aborted: live dashboard_summary repo 020 se alag hai (%). Mujhe batayein.', h;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. log table (old_* = bill jaisa exit rule se PEHLE tha, isliye restore exact)
-- ---------------------------------------------------------------------
create table if not exists public.ddd_dues_void_log (
  id              bigint generated by default as identity primary key,
  due_id          uuid,
  student_id      uuid,
  month           date,
  action          text not null check (action in ('void', 'prorate', 'restore', 'move', 'payment_move', 'credit_review', 'merge_void', 'payment_remove', 'fee_fix', 'rejoin', 'rejoin_keep')),
  old_fee_amount  numeric(10,2),
  old_discount    numeric(10,2),
  old_status      text,
  old_period_to   date,
  new_fee_amount  numeric(10,2),
  new_period_to   date,
  amount_note     numeric(10,2),
  reason          text not null,
  batch           text,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid()
);
-- table pehle se bani ho (purani 026) to action list nayi karo
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.ddd_dues_void_log'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%rejoin_keep%') then
    alter table public.ddd_dues_void_log drop constraint if exists ddd_dues_void_log_action_check;
    alter table public.ddd_dues_void_log add constraint ddd_dues_void_log_action_check
      check (action in ('void', 'prorate', 'restore', 'move', 'payment_move', 'credit_review', 'merge_void', 'payment_remove', 'fee_fix', 'rejoin', 'rejoin_keep'));
  end if;
end $$;
-- 026 wapsi: bill ki period_from bhi badal sakti hai (wapsi wala mahina), restore exact rahe isliye
alter table public.ddd_dues_void_log add column if not exists old_period_from date;
alter table public.ddd_dues_void_log add column if not exists new_period_from date;
create index if not exists idx_ddd_dues_void_log_due on public.ddd_dues_void_log(due_id);
create index if not exists idx_ddd_dues_void_log_student on public.ddd_dues_void_log(student_id);
alter table public.ddd_dues_void_log enable row level security;
drop policy if exists ddd_dues_void_log_read on public.ddd_dues_void_log;
create policy ddd_dues_void_log_read on public.ddd_dues_void_log for select to authenticated using (public.is_director());
revoke all on public.ddd_dues_void_log from public, anon, authenticated;
grant select on public.ddd_dues_void_log to authenticated;
do $$
begin
  execute format('revoke all on sequence %s from public, anon, authenticated', pg_get_serial_sequence('public.ddd_dues_void_log', 'id'));
end $$;
comment on table public.ddd_dues_void_log is
  '026: exit rules aur cleanup ka log. old_* = bill rule se pehle. amount_note = bill kitna kam hua (void/prorate/rejoin), kitna wapas (restore), kitna zyada jama (credit_review). rejoin row (due_id khali) = student wapas aaya: old_period_to = pichhli exit date, new_period_from = wapsi ki tareekh. rejoin_keep = wapsi se pehle ka bill void / kata hi raha (new_period_from = wapsi ki tareekh).';

-- ---------------------------------------------------------------------
-- 2. students.merged_into (duplicate cleanup baad mein bharega)
-- ---------------------------------------------------------------------
alter table public.students add column if not exists merged_into uuid;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.students'::regclass and conname = 'students_merged_into_fkey') then
    alter table public.students add constraint students_merged_into_fkey
      foreign key (merged_into) references public.students(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.students'::regclass and conname = 'students_merged_into_not_self') then
    alter table public.students add constraint students_merged_into_not_self check (merged_into is null or merged_into <> id);
  end if;
end $$;
create index if not exists idx_students_merged_into on public.students(merged_into) where merged_into is not null;

-- 2b. students.rejoined_on = Left student wapas aaya to wapsi ki tareekh (khali = kabhi wapas nahi aaya)
alter table public.students add column if not exists rejoined_on date;
comment on column public.students.rejoined_on is
  '026: Left student wapas aaya - wapsi ki tareekh. Isse pehle ke mahine (jab student nahi tha) ke void / kate bill waise hi, wapsi wala mahina isi tareekh se.';

-- ---------------------------------------------------------------------
-- 3. fee for the days stayed in one calendar month
--    exit khali = bilkul ddd_month_fee (017). Overlap nahi = 0.
-- ---------------------------------------------------------------------
create or replace function public.ddd_stay_fee(p_fee numeric, p_joining date, p_exit date, p_month date)
returns numeric language sql immutable set search_path = public as $$
  select case
    when p_exit is null or p_month is null or coalesce(p_fee, 0) <= 0
      then public.ddd_month_fee(p_fee, p_joining, p_month)
    else (select case when x.b < x.a then 0::numeric
                      when x.a = x.ms and x.b = x.me then p_fee
                      else round(p_fee * (x.b - x.a + 1) / extract(day from x.me)::numeric, 0) end
            from (select greatest(m.ms, coalesce(p_joining, m.ms)) as a, least(m.me, p_exit) as b, m.ms, m.me
                    from (select date_trunc('month', p_month)::date as ms,
                                 (date_trunc('month', p_month) + interval '1 month - 1 day')::date as me) m) x)
  end;
$$;

-- ---------------------------------------------------------------------
-- 4. generate_monthly_dues: 022 checks same + exit / merge rules
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 6a. credit review: list once, never change money
-- ---------------------------------------------------------------------
create or replace function public.ddd_exit_review_once(p_due public.monthly_dues, p_fair numeric, p_exit date, p_reason text, p_batch text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_note numeric := case when p_fair is null then null else coalesce(p_due.paid_amount, 0) - p_fair end;
begin
  if exists (select 1 from public.ddd_dues_void_log l
              where l.due_id = p_due.id and l.action = 'credit_review'
                and l.new_fee_amount is not distinct from p_fair
                and l.amount_note is not distinct from v_note
                and l.new_period_to is not distinct from p_exit) then
    return false;
  end if;
  insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to,
                                       new_fee_amount, new_period_to, amount_note, reason, batch)
  values (p_due.id, p_due.student_id, p_due.month, 'credit_review', p_due.fee_amount, coalesce(p_due.discount, 0), p_due.status, p_due.period_to,
          p_fair, p_exit, v_note, p_reason, p_batch);
  return true;
end $$;

-- ---------------------------------------------------------------------
-- 6b. bring every bill of one student in line with its exit date
--     exit date hai = rules lagao. Exit khali (aur Left nahi, merge nahi)
--     = is function ke badle hue bill wapas. Bina badlav = kuch nahi.
--     Wapas aaya student (rejoined_on): wapsi wale mahine se pehle ki chhutti
--     ke bill = pichhli exit date ke rules, usse pehle ke mahine jaise hain,
--     wapsi wala mahina = wapsi ki tareekh se, aage = normal.
-- ---------------------------------------------------------------------
create or replace function public.ddd_exit_bills_sync(p_student uuid, p_batch text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  s         record;
  d         public.monthly_dues%rowtype;
  dr        public.monthly_dues%rowtype;
  lg        record;
  v_e       date;
  v_ee      date;
  v_restore boolean := false;
  v_r       date;
  v_rm      date;
  v_e1      date;
  v_ev      bigint;
  v_before  boolean;
  v_do      boolean;
  v_batch   text := coalesce(nullif(p_batch, ''), nullif(current_setting('ddd.batch', true), ''), 'trigger');
  v_why     text := nullif(current_setting('ddd.reason', true), '');
  v_pre     text;
  v_lbl     text;
  m         date;
  me        date;
  v_open    boolean;
  o_fee     numeric;
  o_disc    numeric;
  o_status  text;
  o_to      date;
  o_pf      date;
  o_from    date;
  v_s2      date;
  v_w1      date;
  v_flo     date;
  v_end     date;
  v_basis   numeric;
  v_fair    numeric;
  v_fpay    numeric;
  v_paid    numeric;
  n_fee     numeric;
  n_disc    numeric;
  n_to      date;
  n_from    date;
  n_status  text;
  v_act     text;
  v_txt     text;
  v_cnt     int := 0;
begin
  select st.id, st.status, st.exit_date, st.monthly_fee, st.merged_into, st.joining_date, st.rejoined_on into s
    from public.students st where st.id = p_student;
  if s.id is null then return 0; end if;
  if s.exit_date is not null then
    v_e := s.exit_date;
  elsif coalesce(s.status, '') <> 'left' and s.merged_into is null then
    v_restore := true;
  else
    return 0;   -- purana Left bina exit date, ya merged record = haath nahi lagate
  end if;
  -- wapas aaya: wapsi ki tareekh, uska mahina, aur wapsi se pehle wali exit date (rejoin log row se)
  v_r := s.rejoined_on;
  if v_r is not null then
    v_rm := date_trunc('month', v_r)::date;
    v_ev := (select max(l.id) from public.ddd_dues_void_log l
              where l.student_id = p_student and l.due_id is null and l.action = 'rejoin' and l.new_period_from = v_r);
    v_e1 := (select l.old_period_to from public.ddd_dues_void_log l where l.id = v_ev);
  end if;

  for d in select x.* from public.monthly_dues x where x.student_id = p_student order by x.month, x.id for update loop
    m := date_trunc('month', d.month)::date;
    me := (m + interval '1 month - 1 day')::date;
    v_paid := coalesce(d.paid_amount, 0);

    -- last exit rule on this bill (void / prorate / rejoin = abhi badla hua hai)
    select l.* into lg from public.ddd_dues_void_log l
     where l.due_id = d.id and l.action in ('void', 'prorate', 'restore', 'rejoin')
     order by l.id desc limit 1;
    v_open := found and lg.action in ('void', 'prorate', 'rejoin');

    if v_open and (d.fee_amount is distinct from lg.new_fee_amount or d.period_to is distinct from lg.new_period_to
                   or (lg.new_period_from is not null and d.period_from is distinct from lg.new_period_from)) then
      perform public.ddd_exit_review_once(d, null, v_e, 'Bill exit rule ke baad haath se badla gaya - khud check karein', v_batch);
      continue;
    end if;

    -- wapsi wale mahine se PEHLE ka bill: chhutti ke mahine (pichhli exit ke baad) = pichhli exit date ke rules,
    -- usse pehle ke mahine = jaise hain (kabhi nahi chhuye jaate)
    v_before := v_r is not null and me < v_r;
    v_ee := v_e;
    v_pre := '';
    v_do := true;
    if v_before then
      v_pre := 'Wapas aaya ' || to_char(v_r, 'DD-MM-YYYY') || ', usse pehle: ';
      if v_e1 is not null and me > v_e1 then
        v_ee := least(v_e, v_e1);
      else
        v_do := false;
      end if;
    end if;

    if v_do then
      if v_open then
        o_fee := lg.old_fee_amount; o_disc := coalesce(lg.old_discount, 0); o_status := lg.old_status; o_to := lg.old_period_to;
        o_pf := coalesce(lg.old_period_from, d.period_from);
      elsif v_ee is null and (v_r is null or m <> v_rm) then
        continue;
      else
        o_fee := d.fee_amount; o_disc := coalesce(d.discount, 0); o_status := d.status; o_to := d.period_to; o_pf := d.period_from;
      end if;
      -- bill kab se: period_from, purane (017 se pehle ke) bill mein khali ho to joining date
      o_from := greatest(coalesce(o_pf, m), coalesce(s.joining_date, m));
      v_basis := case when o_from <= m then o_fee else coalesce(s.monthly_fee, o_fee) end;
      -- pehle bhi wapas aaya tha: bill abhi us pehli wapsi ki tareekh se chal raha hai (pichhli exit se pehle)
      -- = wahi start rakho, warna pehli chhutti ke din dobara bill ho jaate
      v_flo := null;
      if v_open and lg.new_period_from is not null and v_e1 is not null
         and lg.new_period_from > o_from and lg.new_period_from <= least(v_e1, me)
         and (v_before or (m = v_rm and date_trunc('month', v_e1)::date = m)) then
        v_flo := lg.new_period_from;
        if v_before then o_from := v_flo; end if;
      end if;

      -- wapsi wala mahina: bill wapsi ki tareekh se (exit bhi isi mahine thi to pehle ke rahe din bhi)
      v_s2 := o_from;
      v_w1 := null;
      if v_r is not null and m = v_rm then
        if v_e1 is not null and date_trunc('month', v_e1)::date = m and v_e1 >= o_from then
          if v_r > v_e1 + 1 then v_w1 := v_e1; v_s2 := v_r;
          elsif v_flo is not null then v_s2 := v_flo;
          end if;
        elsif v_r > o_from then
          v_s2 := v_r;
        end if;
      end if;
      v_lbl := case when v_ee is not null then 'Exit ' || to_char(v_ee, 'DD-MM-YYYY')
                    else 'Wapas aaya ' || coalesce(to_char(v_r, 'DD-MM-YYYY'), '') end;

      -- fair fee for this bill
      if v_w1 is null and v_s2 = o_from then
        if v_ee is null or coalesce(o_to, me) <= v_ee then
          v_fair := o_fee;
        elsif m > v_ee then
          v_fair := 0;
        elsif d.month <> m or coalesce(o_to, me) > me or o_from > me then
          perform public.ddd_exit_review_once(d, null, v_ee, 'Purana cycle bill - exit ke baad ke din khud check karein', v_batch);
          continue;
        else
          v_fair := least(o_fee, public.ddd_stay_fee(v_basis, o_from, v_ee, m));
        end if;
        n_from := coalesce(v_flo, o_pf);
      else
        if d.month <> m or coalesce(o_to, me) > me or o_from > me then
          perform public.ddd_exit_review_once(d, null, v_ee, 'Purana cycle bill - wapsi ke din khud check karein', v_batch);
          continue;
        end if;
        v_end := least(coalesce(v_ee, me), coalesce(o_to, me));
        v_fair := least(o_fee, case when v_w1 is null then 0 else public.ddd_stay_fee(v_basis, coalesce(v_flo, o_from), least(v_w1, v_end), m) end
                               + public.ddd_stay_fee(v_basis, v_s2, v_end, m));
        n_from := case when v_w1 is null then v_s2 else coalesce(v_flo, o_pf) end;
      end if;

      if v_fair >= o_fee then
        if not v_open then continue; end if;
        v_act := 'restore'; n_fee := o_fee; n_disc := o_disc; n_to := o_to; n_from := o_pf;
        n_status := case when n_fee - n_disc - v_paid > 0 then case when v_paid > 0 then 'partial' else 'pending' end
                         when v_paid > 0 then 'paid' else coalesce(o_status, 'paid') end;
        v_txt := case when v_ee is null and v_r is not null and m = v_rm then 'Wapas aaya ' || to_char(v_r, 'DD-MM-YYYY') || ' - pura bill wapas'
                      when v_ee is null then 'Student wapas (exit date khali) - pura bill wapas'
                      else 'Exit ' || to_char(v_ee, 'DD-MM-YYYY') || ' is bill ke baad - pura bill wapas' end;
      elsif v_paid > v_fair - least(o_disc, v_fair) then
        -- jama paise rahe din ki fee (discount ke baad) se zyada: paise kabhi nahi badalte, Director ke liye credit review
        v_fpay := v_fair - least(o_disc, v_fair);
        dr := d;
        dr.fee_amount := o_fee; dr.discount := o_disc; dr.status := o_status; dr.period_to := o_to;
        perform public.ddd_exit_review_once(dr, v_fpay, v_ee,
          v_lbl || ' - jama paise sahi fee (discount ke baad) se zyada, Director dekhein (credit review)', v_batch);
        if o_fee - o_disc - v_paid <= 0 then continue; end if;   -- poora jama bill waisa hi rehta hai
        -- bill ka UNPAID hissa student ke na rehne ke din ka hai: woh hatao (fee = jama + discount), jama paise wahi
        v_act := case when v_ee is null then 'rejoin' else 'prorate' end;
        n_fee := v_paid + o_disc; n_disc := o_disc;
        n_to := case when v_ee is null then o_to else greatest(v_ee, coalesce(d.paid_to, v_ee), o_from) end;
        n_status := 'paid';
        v_txt := v_lbl || ' - jama paise se aage ka baaki hataya (credit review list mein)';
      elsif v_fair = 0 then
        v_act := 'void'; n_fee := 0; n_disc := 0; n_to := o_to; n_status := 'void'; n_from := o_pf;
        v_txt := v_lbl || ' - is mahine ka koi din nahi raha, bill void';
      else
        v_act := case when v_ee is not null and v_ee < coalesce(o_to, me) then 'prorate' else 'rejoin' end;
        n_fee := v_fair; n_disc := least(o_disc, v_fair);
        n_to := case when v_act = 'prorate' then v_ee else o_to end;
        n_status := case when n_fee - n_disc - v_paid > 0 then case when v_paid > 0 then 'partial' else 'pending' end
                         else 'paid' end;
        v_txt := case when v_w1 is null and v_s2 = o_from
                      then 'Exit ' || to_char(v_ee, 'DD-MM-YYYY') || ' - sirf ' || (v_ee - greatest(o_from, m) + 1) || ' din ka bill'
                      else 'Wapas aaya ' || to_char(v_r, 'DD-MM-YYYY') || ' - is mahine ka bill sirf wapsi se'
                           || case when v_w1 is not null then ' (aur ' || to_char(v_w1, 'DD-MM') || ' tak ke din)' else '' end
                           || case when v_act = 'prorate' then ', exit ' || to_char(v_ee, 'DD-MM-YYYY') || ' tak' else '' end end;
      end if;

      if d.fee_amount = n_fee and coalesce(d.discount, 0) = n_disc and d.period_to is not distinct from n_to
         and d.status is not distinct from n_status and d.period_from is not distinct from n_from then
        v_do := false;   -- already right
      end if;
    end if;

    if not v_do then
      -- wapsi se pehle ka void / kata bill waisa hi raha: Director ke liye ek baar log (rejoin_keep)
      if v_before and v_open and (v_ev is null or lg.id < v_ev)
         and not exists (select 1 from public.ddd_dues_void_log k where k.due_id = d.id and k.action = 'rejoin_keep' and k.new_period_from = v_r) then
        insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to, old_period_from,
                                             new_fee_amount, new_period_to, new_period_from, amount_note, reason, batch)
        values (d.id, d.student_id, d.month, 'rejoin_keep', lg.old_fee_amount, coalesce(lg.old_discount, 0), lg.old_status, lg.old_period_to,
                coalesce(lg.old_period_from, d.period_from), d.fee_amount, d.period_to, v_r,
                (lg.old_fee_amount - coalesce(lg.old_discount, 0)) - (d.fee_amount - coalesce(d.discount, 0)),
                coalesce(v_why || ': ', '') || 'Wapas aaya ' || to_char(v_r, 'DD-MM-YYYY') || ': is mahine student hostel mein nahi tha (ya kuch din) - bill '
                || case when d.status = 'void' then 'void' else 'kata hua' end || ' hi rahega', v_batch);
      end if;
      continue;
    end if;

    update public.monthly_dues
       set fee_amount = n_fee, discount = n_disc, period_to = n_to, status = n_status, period_from = n_from
     where id = d.id;

    insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to, old_period_from,
                                         new_fee_amount, new_period_to, new_period_from, amount_note, reason, batch)
    values (d.id, d.student_id, d.month, v_act,
            case when v_act = 'restore' then d.fee_amount else o_fee end,
            case when v_act = 'restore' then coalesce(d.discount, 0) else o_disc end,
            case when v_act = 'restore' then d.status else o_status end,
            case when v_act = 'restore' then d.period_to else o_to end,
            case when v_act = 'restore' then d.period_from else o_pf end,
            n_fee, n_to, n_from,
            case when v_act = 'restore' then (n_fee - n_disc) - (d.fee_amount - coalesce(d.discount, 0))
                 else (o_fee - o_disc) - (n_fee - n_disc) end,
            coalesce(v_why || ': ', '') || v_pre || v_txt, v_batch);
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end $$;

-- ---------------------------------------------------------------------
-- 5. monthly_dues guards
-- ---------------------------------------------------------------------
-- 5a. no bill for a month that starts after the exit date, no new bill at all
--     for a merged old record (every caller)
create or replace function public.ddd_guard_due_after_exit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_name   text;
  v_exit   date;
  v_merged uuid;
begin
  if new.student_id is null or new.month is null then return new; end if;
  select st.full_name, st.exit_date, st.merged_into into v_name, v_exit, v_merged from public.students st where st.id = new.student_id;
  if v_merged is not null then
    raise exception '% merged purana record hai — iska naya bill nahi ban sakta. Naya record kholen.',
      coalesce(nullif(trim(v_name), ''), 'Student');
  end if;
  if v_exit is not null and date_trunc('month', new.month)::date > v_exit then
    raise exception '% ne % ko hostel chhoda — uske baad ka bill nahi ban sakta',
      coalesce(nullif(trim(v_name), ''), 'Student'), to_char(v_exit, 'DD-MM-YYYY');
  end if;
  return new;
end $$;

drop trigger if exists trg_monthly_dues_exit_guard on public.monthly_dues;
create trigger trg_monthly_dues_exit_guard
  before insert on public.monthly_dues
  for each row execute function public.ddd_guard_due_after_exit();

-- 5b. new bill of the exit month (Receive Fee etc.) -> cut to the days stayed.
--     Wapas aaya student: wapsi wale mahine tak ka naya bill -> wapsi ke rules
--     (wapsi se pehle ki chhutti ka naya bill = void, wapsi wala mahina = wapsi se)
create or replace function public.ddd_dues_exit_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.student_id is not null and exists (
       select 1 from public.students st
        where st.id = new.student_id
          and ((st.exit_date is not null
                and st.exit_date >= date_trunc('month', new.month)::date
                and st.exit_date < coalesce(new.period_to, (date_trunc('month', new.month) + interval '1 month - 1 day')::date))
               or (st.rejoined_on is not null and date_trunc('month', new.month)::date <= st.rejoined_on))) then
    perform public.ddd_exit_bills_sync(new.student_id, null);
  end if;
  return null;
end $$;

drop trigger if exists trg_monthly_dues_exit_month on public.monthly_dues;
create trigger trg_monthly_dues_exit_month
  after insert on public.monthly_dues
  for each row execute function public.ddd_dues_exit_after_insert();

-- 5c. bill ka student / mahina / tareekh / hostel app se sirf Director badal sakta hai.
--     Exit rule bill ki tareekh par chalta hai, isliye warden tareekh badal kar bill void na kar sake.
--     App in columns ko kabhi nahi likhta. Fee functions (owner rights) par asar nahi.
create or replace function public.ddd_guard_due_period() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.ddd_is_api_caller() and not public.is_director()
     and (new.student_id, new.month, new.period_from, new.period_to, new.hostel_id)
         is distinct from (old.student_id, old.month, old.period_from, old.period_to, old.hostel_id) then
    raise exception 'Bill ka student / mahina / tareekh sirf Director badal sakta hai' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists trg_monthly_dues_period_guard on public.monthly_dues;
create trigger trg_monthly_dues_period_guard
  before update on public.monthly_dues
  for each row execute function public.ddd_guard_due_period();

-- ---------------------------------------------------------------------
-- 6c. students triggers
-- ---------------------------------------------------------------------
-- merged_into sirf Director / SQL Editor badal sakta hai (warna bill band karne ka chhupa rasta).
-- Merged record ka status sirf Left (koi bhi caller).
-- Left se wapas aur exit date nahi chhui = exit date khali.
-- SQL Editor: Left + exit date khali = aaj (IST). App (API) se Left = Exit Date zaroori.
-- App se Director ke alawa: nayi / badli Exit Date sirf Left par, aaj - 10 se aaj + 31 tak.
-- App se Director ke alawa: bill ban chuka ho to Joining Date aage / khali nahi.
-- Wapsi ki tareekh (rejoined_on): app se sirf Left se wapas Active / Temp Leave karte waqt,
-- pichhli Exit Date se pehle nahi, aaj + 31 se aage nahi (Director: sirf Exit Date / joining wali rok).
create or replace function public.ddd_students_exit_default() returns trigger
language plpgsql set search_path = public as $$
declare
  v_api    boolean := public.ddd_is_api_caller();
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  o_status text;
  o_exit   date;
  o_rj     date;
  v_prev   date;
begin
  if tg_op = 'UPDATE' then
    o_status := old.status; o_exit := old.exit_date; o_rj := old.rejoined_on;
  end if;
  if v_api and not public.is_director()
     and new.merged_into is distinct from (case when tg_op = 'UPDATE' then old.merged_into end) then
    raise exception 'Merge sirf Director kar sakta hai' using errcode = '42501';
  end if;
  -- merged purana record hamesha Left (warna dobara bill aur fee usi par aane lagti)
  if new.merged_into is not null and new.status is distinct from 'left' then
    raise exception 'Ye merged purana record hai — ise Active nahi kar sakte. Naya record kholen.';
  end if;
  if tg_op = 'UPDATE' then
    if new.status = 'left' and old.status is distinct from 'left' and new.exit_date is null and not v_api then
      new.exit_date := v_today;
    elsif old.status = 'left' and new.status is distinct from 'left'
          and new.exit_date is not null and new.exit_date is not distinct from old.exit_date then
      new.exit_date := null;
    end if;
  end if;
  if v_api then
    -- Left = Exit Date zaroori (purana Left bina exit date: baaki fields ka save pehle jaisa chalta hai)
    if new.status = 'left' and new.exit_date is null
       and (o_status is distinct from 'left' or o_exit is not null) then
      raise exception 'Left ke liye Exit Date zaroori hai';
    end if;
    if not public.is_director() then
      -- bill ban chuka ho to Joining Date aage (ya khali) sirf Director: exit par bill joining se ginta hai
      if tg_op = 'UPDATE' and new.joining_date is distinct from old.joining_date
         and (new.joining_date is null or old.joining_date is null or new.joining_date > old.joining_date)
         and exists (select 1 from public.monthly_dues x where x.student_id = new.id) then
        raise exception 'Bill ban chuka hai - Joining Date aage sirf Director kar sakte hain' using errcode = '42501';
      end if;
      if new.exit_date is not null and new.exit_date is distinct from o_exit then
        if new.status is distinct from 'left' then
          raise exception 'Active / Temp Leave student ki Exit Date sirf Director laga sakte hain' using errcode = '42501';
        end if;
        if new.exit_date < v_today - 10 then
          raise exception 'Itni purani Exit Date sirf Director laga sakte hain (warden: pichhle 10 din tak)' using errcode = '42501';
        end if;
        if new.exit_date > v_today + 31 then
          raise exception 'Exit Date aaj se 31 din se zyada aage nahi ho sakti';
        end if;
      end if;
      if new.rejoined_on is distinct from o_rj then
        if new.rejoined_on is null or o_status is distinct from 'left' or new.status = 'left' then
          raise exception 'Wapsi ki tareekh sirf Left student ko wapas Active karte waqt lagti hai (baaki sirf Director)' using errcode = '42501';
        end if;
        if new.rejoined_on > v_today + 31 then
          raise exception 'Wapsi ki tareekh aaj se 31 din se zyada aage nahi ho sakti';
        end if;
      end if;
    end if;
    if new.rejoined_on is not null and new.rejoined_on is distinct from o_rj then
      -- pichhli exit date: abhi wali, warna pichhli wapsi ki log row wali (Director active student ki wapsi badle)
      v_prev := coalesce(o_exit, (select l.old_period_to from public.ddd_dues_void_log l
                                   where tg_op = 'UPDATE' and l.student_id = new.id and l.due_id is null and l.action = 'rejoin'
                                   order by l.id desc limit 1));
      if v_prev is not null and new.rejoined_on < v_prev then
        raise exception 'Wapsi ki tareekh Exit Date (%) se pehle nahi ho sakti', to_char(v_prev, 'DD-MM-YYYY');
      end if;
      if new.joining_date is not null and new.rejoined_on < new.joining_date then
        raise exception 'Wapsi ki tareekh joining date se pehle nahi ho sakti';
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_students_exit_default on public.students;
create trigger trg_students_exit_default
  before insert or update on public.students
  for each row execute function public.ddd_students_exit_default();

-- status / exit date / wapsi ki tareekh badle = bills sync (warden ka save bhi, isliye SECURITY DEFINER).
-- Wapsi ki tareekh lagi / badli = log mein ek rejoin row (pichhli exit date ke saath), sync isi se chalta hai.
create or replace function public.ddd_students_exit_bills() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_e1 date;
begin
  if new.rejoined_on is distinct from old.rejoined_on then
    v_e1 := coalesce(old.exit_date,
                     (select l.old_period_to from public.ddd_dues_void_log l
                       where l.student_id = new.id and l.due_id is null and l.action = 'rejoin'
                       order by l.id desc limit 1));
    insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_status, old_period_to, new_period_from, reason, batch)
    values (null, new.id, date_trunc('month', coalesce(new.rejoined_on, old.rejoined_on))::date, 'rejoin', old.status, v_e1, new.rejoined_on,
            coalesce(nullif(current_setting('ddd.reason', true), '') || ': ', '')
            || case when new.rejoined_on is null then 'Wapsi ki tareekh hatai (thi ' || to_char(old.rejoined_on, 'DD-MM-YYYY') || ')'
                    else 'Wapas aaya ' || to_char(new.rejoined_on, 'DD-MM-YYYY') || coalesce(' (pehle exit ' || to_char(v_e1, 'DD-MM-YYYY') || ')', '') end,
            coalesce(nullif(current_setting('ddd.batch', true), ''), 'trigger'));
  end if;
  if new.status is distinct from old.status or new.exit_date is distinct from old.exit_date
     or new.rejoined_on is distinct from old.rejoined_on then
    perform public.ddd_exit_bills_sync(new.id, null);
  end if;
  return null;
end $$;

drop trigger if exists trg_students_exit_bills on public.students;
create trigger trg_students_exit_bills
  after update of status, exit_date, rejoined_on on public.students
  for each row execute function public.ddd_students_exit_bills();

-- ---------------------------------------------------------------------
-- 7. paid_to / paid_till: void bill = kuch paid nahi, Paid Till nahi badhata
--    (only the void lines are new, rest = 024 text)
-- ---------------------------------------------------------------------
create or replace function public.ddd_dues_set_paid_to() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'void' then
    new.paid_to := coalesce(new.period_from, date_trunc('month', new.month)::date) - 1;
    return new;
  end if;
  new.paid_to := public.ddd_due_paid_to(new.month, new.period_from, new.period_to, new.fee_amount,
                                        new.discount, new.paid_amount,
                                        (select monthly_fee from public.students where id = new.student_id));
  return new;
end $$;

create or replace function public.compute_paid_till(p_student uuid, p_joining date, p_fee numeric)
returns date language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from monthly_dues where student_id = p_student and coalesce(pending, 0) > 0)
      then (select coalesce(d.paid_to, coalesce(d.period_from, d.month) - 1)
              from monthly_dues d where d.student_id = p_student and coalesce(d.pending, 0) > 0
             order by coalesce(d.period_from, d.month), d.month limit 1)
    when exists (select 1 from monthly_dues where student_id = p_student and status is distinct from 'void')
      then (select max(coalesce(period_to, (date_trunc('month', month) + interval '1 month - 1 day')::date))
              from monthly_dues where student_id = p_student and status is distinct from 'void')
    when p_joining is not null and coalesce(p_fee, 0) > 0
      then p_joining - 1
    else null
  end;
$$;

-- ---------------------------------------------------------------------
-- 7b. day shares (Paid Till, Dates chuno): exit par kata bill (1 tareekh se,
--     mahine ke end se pehle) = poore mahine ka rate = student ki monthly fee,
--     jaise joining month (017). Baaki sab bilkul 024 text.
-- ---------------------------------------------------------------------
create or replace function public.ddd_due_paid_to(p_month date, p_from date, p_to date, p_fee_amount numeric,
                                                  p_discount numeric, p_paid numeric, p_student_fee numeric)
returns date language plpgsql immutable set search_path = public as $$
declare
  ms  date := date_trunc('month', p_month)::date;
  pf  date := coalesce(p_from, date_trunc('month', p_month)::date);
  pt  date := coalesce(p_to, (date_trunc('month', p_month) + interval '1 month - 1 day')::date);
  dim int  := extract(day from (date_trunc('month', p_month) + interval '1 month - 1 day'))::int;
  got numeric := coalesce(p_paid, 0) + coalesce(p_discount, 0);
  f   numeric;
  k0  int;
  k   int;
begin
  if coalesce(p_fee_amount, 0) - got <= 0 then return pt; end if;   -- nothing pending
  if got <= 0 then return pf - 1; end if;                          -- nothing paid
  f := public.ddd_due_full_fee(ms, pf, p_fee_amount, p_student_fee);
  -- 026: exit par kata bill = poore mahine ka rate
  if pf <= ms and pt < ms + dim - 1 and coalesce(p_student_fee, 0) > 0 then f := p_student_fee; end if;
  if f <= 0 then return pf - 1; end if;
  k0 := extract(day from pf)::int - 1;
  k := k0;
  -- still pending -> never beyond the day before period end
  while ms + k <= pt - 1
        and public.ddd_cum_fee(f, dim, k + 1) - public.ddd_cum_fee(f, dim, k0) <= got loop
    k := k + 1;
  end loop;
  return ms + k - 1;
end $$;

-- 7c. plan a date range: 024 text + void (Cancelled) bill par fee nahi + kata bill = poore mahine ka rate
create or replace function public.ddd_fee_range_plan(p_sid uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s    public.students%rowtype;
  d    public.monthly_dues%rowtype;
  m    date;
  me   date;
  a    date;
  b    date;
  v_id uuid;
  f    numeric;
  dim  int;
  owed numeric;
  ptd  date;
  v_out jsonb := '[]';
begin
  s := (select x from public.students x where x.id = p_sid);
  if s.id is null then raise exception 'Student not found'; end if;
  if p_from is null or p_to is null then raise exception 'From aur To date dono chahiye'; end if;
  if p_to < p_from then raise exception 'To date From date se pehle nahi ho sakti'; end if;
  if s.joining_date is not null and p_from < s.joining_date then
    raise exception 'From date joining date (%) se pehle nahi ho sakti', to_char(s.joining_date, 'DD-MM-YYYY');
  end if;
  if s.exit_date is not null and p_to > s.exit_date then
    raise exception 'To date exit date (%) ke baad nahi ho sakti', to_char(s.exit_date, 'DD-MM-YYYY');
  end if;
  if (extract(year from p_to) * 12 + extract(month from p_to)) - (extract(year from p_from) * 12 + extract(month from p_from)) + 1 > 36 then
    raise exception 'Ek baar mein zyada se zyada 36 months';
  end if;

  m := date_trunc('month', p_from)::date;
  while m <= p_to loop
    me := (m + interval '1 month - 1 day')::date;
    a := greatest(p_from, m);
    b := least(p_to, me);
    d := (select x from public.monthly_dues x
           where x.student_id = s.id and date_trunc('month', x.month) = m
           order by x.month limit 1 for update);
    if d.id is null then
      v_id := gen_random_uuid();
      insert into public.monthly_dues(id, student_id, hostel_id, month, fee_amount, period_from, period_to, created_by)
      values (v_id, s.id, s.hostel_id, m, public.ddd_month_fee(s.monthly_fee, s.joining_date, m),
              greatest(m, coalesce(s.joining_date, m)), me, auth.uid());
      d := (select x from public.monthly_dues x where x.id = v_id);
    end if;
    -- 026: Cancelled (void) bill par fee nahi (warna void bill paid ban jaata)
    if d.status = 'void' then
      raise exception '% ka bill Cancelled (void) hai — is mahine ki fee nahi li ja sakti. Dates badlein.', to_char(m, 'Mon YYYY');
    end if;
    if a < coalesce(d.period_from, m) or b > coalesce(d.period_to, me) then
      raise exception '% ki due % se % tak hai — dates iske andar honi chahiye', to_char(m, 'Mon YYYY'),
        to_char(coalesce(d.period_from, m), 'DD-MM-YYYY'), to_char(coalesce(d.period_to, me), 'DD-MM-YYYY');
    end if;
    ptd := coalesce(d.paid_to, coalesce(d.period_from, m) - 1);
    if a <= ptd then
      raise exception 'Yeh dates pehle se paid hain (% mein % tak paid)', to_char(m, 'Mon YYYY'), to_char(ptd, 'DD-MM-YYYY');
    end if;
    if a > ptd + 1 then
      raise exception 'Beech ke din khali nahi chhod sakte — % mein % se shuru karein', to_char(m, 'Mon YYYY'), to_char(ptd + 1, 'DD-MM-YYYY');
    end if;
    if b = coalesce(d.period_to, me) then
      owed := coalesce(d.pending, 0);
    else
      dim := extract(day from me)::int;
      f := public.ddd_due_full_fee(m, d.period_from, d.fee_amount, s.monthly_fee);
      -- 026: exit par kata bill = poore mahine ka rate (ddd_due_paid_to jaisa)
      if coalesce(d.period_from, m) <= m and coalesce(d.period_to, me) < me and coalesce(s.monthly_fee, 0) > 0 then f := s.monthly_fee; end if;
      owed := least(coalesce(d.pending, 0),
                    public.ddd_cum_fee(f, dim, extract(day from b)::int) - public.ddd_cum_fee(f, dim, extract(day from a)::int - 1));
    end if;
    v_out := v_out || jsonb_build_object('due_id', d.id, 'month', m, 'from', a, 'to', b, 'owed', owed,
                                     'whole', (a = coalesce(d.period_from, m) and b = coalesce(d.period_to, me)));
    m := (m + interval '1 month')::date;
  end loop;
  return v_out;
end $$;

-- 7d. Director payment delete (refund): 014 text + Left / wapas aaye student ke bill
--     aakhir mein dobara exit date / wapsi ke hisaab se (exit ke baad koi bill nahi)
create or replace function public.delete_fee_payment(p_payment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f          public.fee_payments%rowtype;
  v_ids      uuid[];
  v_dues     uuid[];
  v_student  uuid;
  v_cur      date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  r          record;
  v_removed  int := 0;
  v_reset    int := 0;
  v_rows     int;
  v_amount   numeric;
  v_paid_till date;
begin
  if not (auth.uid() is null or is_director()) then
    raise exception 'Only the Director can delete payments' using errcode = '42501';
  end if;

  select * into f from fee_payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  v_student := f.student_id;
  perform 1 from students where id = v_student for update;

  if f.advance_group_id is not null then
    select array_agg(id) into v_ids from fee_payments where advance_group_id = f.advance_group_id;
  else
    v_ids := array[f.id];
  end if;
  select count(*), coalesce(sum(amount), 0) into v_rows, v_amount from fee_payments where id = any(v_ids);
  select coalesce(array_agg(distinct due_id), '{}') into v_dues
    from fee_payments where id = any(v_ids) and due_id is not null;

  -- give back to each linked due exactly what these payments added
  for r in
    select due_id, sum(amount) amt, sum(coalesce(discount_amount, 0)) disc
      from fee_payments where id = any(v_ids) and due_id is not null
     group by due_id
  loop
    update monthly_dues
       set paid_amount = greatest(coalesce(paid_amount, 0) - r.amt, 0),
           discount    = greatest(coalesce(discount, 0) - r.disc, 0)
     where id = r.due_id;
  end loop;

  delete from fee_payments where id = any(v_ids);

  -- future month with nothing else paid -> remove, otherwise pending/partial
  for r in select id, month, paid_amount from monthly_dues where id = any(v_dues) loop
    if date_trunc('month', r.month)::date > v_cur
       and coalesce(r.paid_amount, 0) = 0
       and not exists (select 1 from fee_payments where due_id = r.id) then
      delete from monthly_dues where id = r.id;
      v_removed := v_removed + 1;
    else
      update monthly_dues
         set status = case when coalesce(paid_amount, 0) <= 0 then 'pending'
                           when coalesce(pending, 0) > 0     then 'partial'
                           else 'paid' end
       where id = r.id;
      v_reset := v_reset + 1;
    end if;
  end loop;

  -- 026: Left student (exit date) ya wapas aaya student = bills dobara exit / wapsi ke hisaab se (refund ke baad bhi)
  if exists (select 1 from students where id = v_student and (exit_date is not null or rejoined_on is not null)) then
    perform public.ddd_exit_bills_sync(v_student, 'delete_fee_payment');
  end if;

  v_paid_till := public.recompute_paid_till(v_student);
  return jsonb_build_object('deleted_payments', v_rows, 'amount', v_amount,
                            'dues_removed', v_removed, 'dues_reset', v_reset,
                            'paid_till', v_paid_till);
end $$;


-- ---------------------------------------------------------------------
-- 7e. Dashboard (020): merged purane duplicate record nahi gine jaate
--     (admissions, left, students snapshot, hostel table). Baaki 020 text.
-- ---------------------------------------------------------------------
create or replace function public.ddd_period_numbers(p_from date, p_to date, p_all boolean, p_hs uuid[], p_dir boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_gross numeric; v_refund numeric; v_cnt int; v_billed numeric; v_exp numeric; v_sal numeric;
  v_adm int; v_left int; v_copen int; v_cclose int;
begin
  -- (plain := assignments: Supabase SQL Editor misreads "select ... into" as a new table)
  v_gross := (select coalesce(sum(amount), 0) from fee_payments
              where amount > 0 and payment_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  v_refund := (select coalesce(-sum(amount), 0) from fee_payments
               where amount < 0 and payment_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  v_cnt := (select count(*) from fee_payments
            where payment_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));

  v_billed := (select coalesce(sum(payable), 0) from monthly_dues
               where month between p_from and p_to and (p_all or hostel_id = any(p_hs)));

  -- 026: merged purana duplicate record admission / left mein nahi gina jaata (Students list jaisa)
  v_adm := (select count(*) from students
            where joining_date between p_from and p_to and (p_all or hostel_id = any(p_hs)) and merged_into is null);
  v_left := (select count(*) from students
             where exit_date between p_from and p_to and (p_all or hostel_id = any(p_hs)) and merged_into is null);

  v_copen := (select count(*) from complaints
              where (created_at at time zone 'Asia/Kolkata')::date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  v_cclose := (select count(*) from complaints
               where status = 'resolved'
                 and coalesce(resolution_date, (updated_at at time zone 'Asia/Kolkata')::date) between p_from and p_to
                 and (p_all or hostel_id = any(p_hs)));

  if p_dir then
    v_exp := (select coalesce(sum(amount), 0) from expenses
              where status = 'approved' and expense_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
    v_sal := (select coalesce(sum(net), 0) from salary_runs
              where status = 'paid' and paid_date between p_from and p_to and (p_all or hostel_id = any(p_hs)));
  end if;

  return jsonb_build_object(
    'collected', v_gross - v_refund, 'refunds', v_refund, 'payments', v_cnt,
    'billed', v_billed,
    'collection_pct', case when v_billed > 0 then round((v_gross - v_refund) * 100 / v_billed, 1) end,
    'expense', v_exp, 'salary_paid', v_sal,
    'net_profit', case when p_dir then v_gross - v_refund - v_exp - v_sal end,
    'admissions', v_adm, 'left', v_left,
    'complaints_opened', v_copen, 'complaints_closed', v_cclose);
end $$;

create or replace function public.dashboard_summary(p_from date, p_to date, p_hostel uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_uid   uuid := auth.uid();
  v_dir   boolean := coalesce(public.is_director(), false);
  v_wide  boolean := v_dir or coalesce(public.is_accountant(), false);   -- = read policies
  v_all   boolean;       -- no hostel filter at all (incl. rows without hostel)
  v_hs    uuid[];        -- hostels this call may sum
  v_asof  date;
  v_grace int;
  v_pfrom date; v_pto date;
  v_snap  jsonb;
  v_modes jsonb; v_hostels jsonb; v_monthly jsonb; v_day jsonb;
  v_m_from date; v_m_to date;
begin
  if p_from is null or p_to is null then raise exception 'dashboard_summary: from/to required'; end if;
  if p_from > p_to then raise exception 'dashboard_summary: from date is after to date'; end if;
  if p_to - p_from > 366 * 30 then raise exception 'dashboard_summary: period too long'; end if;
  if v_uid is null then raise exception 'dashboard_summary: not signed in'; end if;
  v_all := v_wide and p_hostel is null;
  if v_wide then
    v_hs := case when p_hostel is null then array(select id from hostels) else array[p_hostel] end;
  else
    v_hs := array(select h from public.my_hostels() h where p_hostel is null or h = p_hostel);
  end if;
  v_hs := coalesce(v_hs, '{}');
  v_asof := least(p_to, v_today);
  v_grace := (select coalesce(nullif(value, '')::int, 0) from app_settings where key = 'fee_grace_days');
  v_grace := greatest(coalesce(v_grace, 0), 0);
  v_pfrom := (select prev_from from public.ddd_prev_period(p_from, p_to));
  v_pto := p_from - 1;

  -- snapshot as of v_asof
  v_snap := (with st as (   -- 026: merged purana record nahi (naya record already gina hai)
    select s.* from students s
    where (v_all or s.hostel_id = any(v_hs)) and s.merged_into is null
      and (s.joining_date is null or s.joining_date <= v_asof)
      and (s.exit_date is null or s.exit_date > v_asof)
      and (coalesce(s.status, 'active') <> 'left' or s.exit_date > v_asof)
  ),
  bill as (   -- billable: today = exactly the app rule (not left, joining date, fee), past = active on that date
    select s.* from students s
    where (v_all or s.hostel_id = any(v_hs)) and s.merged_into is null
      and s.joining_date is not null and coalesce(s.monthly_fee, 0) > 0
      and case when v_asof >= v_today then coalesce(s.status, 'active') <> 'left'
               else s.joining_date <= v_asof and (s.exit_date is null or s.exit_date > v_asof)
                    and (coalesce(s.status, 'active') <> 'left' or s.exit_date > v_asof) end
  ),
  later as (   -- payments made after the as-of date are added back
    select due_id, sum(amount) amt from fee_payments
    where payment_date > v_asof and due_id is not null and (v_all or hostel_id = any(v_hs))
    group by due_id
  ),
  dd as (
    select d.student_id, coalesce(d.period_from, d.month) as start,
           coalesce(d.period_to, (d.month + interval '1 month - 1 day')::date) as stop,
           least(d.payable, d.pending + coalesce(l.amt, 0)) as pend
    from monthly_dues d join bill b on b.id = d.student_id
    left join later l on l.due_id = d.id
    where d.status is distinct from 'void'   -- 026: Cancelled bill kuch nahi ginta
  ),
  agg as (
    select student_id, min(start) filter (where pend > 0) as first_unpaid, max(stop) as last_stop,
           coalesce(sum(pend) filter (where pend > 0 and start <= v_asof), 0) as pend
    from dd group by student_id
  ),
  per as (   -- first unpaid day of each billable student (today: paid_till, same as the app)
    select b.id, b.hostel_id,
           case when v_asof >= v_today then b.paid_till + 1
                else coalesce(a.first_unpaid, a.last_stop + 1, b.joining_date) end as nextdue,
           coalesce(a.pend, 0) as pend,
           (v_asof < v_today or b.paid_till is not null) as has_state   -- app: no paid_till = "NOT BILLED"
    from bill b left join agg a on a.student_id = b.id
  ),
  bd as (select * from beds where (v_all or hostel_id = any(v_hs)))
  select jsonb_build_object(
    'asof', v_asof,
    'students', (select count(*) from st),
    'missing', (select count(*) from st where joining_date is null or coalesce(monthly_fee, 0) <= 0),
    'beds', (select count(*) from bd),
    'occupied', (select count(*) from bd where bed_status = 'occupied'),
    'vacant', (select count(*) from bd where bed_status = 'vacant'),
    'pending', (select coalesce(sum(pend), 0) from per),
    'pending_students', (select count(*) from per where pend > 0),
    'pending_by_hostel', (select coalesce(jsonb_object_agg(hostel_id, amt), '{}'::jsonb)
                          from (select hostel_id, sum(pend) amt from per where hostel_id is not null group by hostel_id) q),
    'overdue', (select count(*) from per where has_state and v_asof - nextdue > v_grace),
    'due', (select count(*) from per where has_state and v_asof - nextdue between 0 and v_grace),
    'soon', (select count(*) from per where has_state and nextdue - v_asof between 1 and 7),
    'complaints_open', (select count(*) from complaints c
                        where (v_all or c.hostel_id = any(v_hs))
                          and (c.created_at at time zone 'Asia/Kolkata')::date <= v_asof
                          and (c.status is distinct from 'resolved'
                               or coalesce(c.resolution_date, (c.updated_at at time zone 'Asia/Kolkata')::date) > v_asof)),
    'salary_month', (date_trunc('month', v_asof) - interval '1 month')::date,
    'salary_payable', case when v_dir then (
        select coalesce(sum(net), 0) from salary_runs r
        where r.month = (date_trunc('month', v_asof) - interval '1 month')::date
          and (r.status = 'pending' or r.paid_date > v_asof)
          and (v_all or r.hostel_id = any(v_hs))) end,
    'salary_pending_staff', case when v_dir then (
        select count(*) from salary_runs r
        where r.month = (date_trunc('month', v_asof) - interval '1 month')::date
          and (r.status = 'pending' or r.paid_date > v_asof)
          and (v_all or r.hostel_id = any(v_hs))) end
  ));

  -- day list (single-day periods): "aaj kitna aaya, kisne jama kiya"
  if p_from = p_to then
    v_day := (select coalesce(jsonb_agg(x order by x.created_at), '[]'::jsonb) from (
      select f.id, f.amount, f.mode, f.receipt_number, f.student_id, s.full_name as student, s.admission_number,
             f.hostel_id, coalesce(f.collected_by, f.created_by) as by_id, case when v_dir or u.id = v_uid then u.full_name end as by_name, f.created_at
      from fee_payments f
      left join students s on s.id = f.student_id
      left join users u on u.id = coalesce(f.collected_by, f.created_by)
      where f.payment_date = p_from and (v_all or f.hostel_id = any(v_hs))
      limit 2000) x);
  end if;

  if v_dir then
    v_modes := (select coalesce(jsonb_agg(jsonb_build_object('mode', m, 'amount', amt, 'count', n) order by amt desc), '[]'::jsonb)
    from (select coalesce(nullif(lower(trim(mode)), ''), 'other') m, sum(amount) amt, count(*) n
          from fee_payments where payment_date between p_from and p_to and (v_all or hostel_id = any(v_hs))
          group by 1) z);

    v_hostels := (select coalesce(jsonb_agg(jsonb_build_object(
             'id', h.id, 'name', h.name, 'code', h.code,
             'students', (select count(*) from students s where s.hostel_id = h.id and s.merged_into is null
                            and (s.joining_date is null or s.joining_date <= v_asof)
                            and (s.exit_date is null or s.exit_date > v_asof)
                            and (coalesce(s.status, 'active') <> 'left' or s.exit_date > v_asof)),
             'beds', (select count(*) from beds b where b.hostel_id = h.id),
             'occupied', (select count(*) from beds b where b.hostel_id = h.id and b.bed_status = 'occupied'),
             'billed', (select coalesce(sum(payable), 0) from monthly_dues d where d.hostel_id = h.id and d.month between p_from and p_to),
             'collected', (select coalesce(sum(amount), 0) from fee_payments f where f.hostel_id = h.id and f.payment_date between p_from and p_to),
             'expense', (select coalesce(sum(amount), 0) from expenses e where e.hostel_id = h.id and e.status = 'approved' and e.expense_date between p_from and p_to),
             'pending', coalesce((v_snap -> 'pending_by_hostel' ->> h.id::text)::numeric, 0)
           ) order by h.name), '[]'::jsonb)
    from hostels h where (v_all or h.id = any(v_hs)));

    -- month-wise chart: the period months if it spans 2+ months (max 24), else the FY of p_to
    if date_trunc('month', p_from) < date_trunc('month', p_to) then
      v_m_to := date_trunc('month', p_to)::date;
      v_m_from := greatest(date_trunc('month', p_from)::date, (v_m_to - interval '23 months')::date);
    else
      v_m_from := make_date(extract(year from p_to)::int - case when extract(month from p_to) < 4 then 1 else 0 end, 4, 1);
      v_m_to := (v_m_from + interval '11 months')::date;
    end if;
    v_monthly := (select coalesce(jsonb_agg(jsonb_build_object(
             'month', gm::date,
             'income', (select coalesce(sum(amount), 0) from fee_payments f
                        where f.payment_date >= gm and f.payment_date < gm + interval '1 month' and (v_all or f.hostel_id = any(v_hs))),
             'expense', (select coalesce(sum(amount), 0) from expenses e
                         where e.status = 'approved' and e.expense_date >= gm and e.expense_date < gm + interval '1 month' and (v_all or e.hostel_id = any(v_hs))),
             'salary', (select coalesce(sum(net), 0) from salary_runs r
                        where r.status = 'paid' and r.paid_date >= gm and r.paid_date < gm + interval '1 month' and (v_all or r.hostel_id = any(v_hs)))
           ) order by gm), '[]'::jsonb)
    from generate_series(v_m_from, v_m_to, interval '1 month') gm);
  end if;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', v_today, 'hostel', p_hostel, 'is_director', v_dir, 'grace', v_grace,
    'prev_from', v_pfrom, 'prev_to', v_pto,
    'cur',  public.ddd_period_numbers(p_from, p_to, v_all, v_hs, v_dir),
    'prev', public.ddd_period_numbers(v_pfrom, v_pto, v_all, v_hs, v_dir),
    'snap', v_snap, 'day', v_day, 'modes', v_modes, 'hostels', v_hostels, 'monthly', v_monthly);
end $$;

-- void / kata bills from an earlier 026 (only after undo + run again, pehli baar 0 rows)
update public.monthly_dues set paid_to = paid_to
 where status = 'void' and paid_to is distinct from coalesce(period_from, date_trunc('month', month)::date) - 1;
update public.monthly_dues d set paid_to = d.paid_to
 where d.status is distinct from 'void'
   and coalesce(d.period_from, d.month) <= date_trunc('month', d.month)::date
   and d.period_to < (date_trunc('month', d.month) + interval '1 month - 1 day')::date
   and d.paid_to is distinct from public.ddd_due_paid_to(d.month, d.period_from, d.period_to, d.fee_amount, d.discount, d.paid_amount,
                                                         (select monthly_fee from public.students where id = d.student_id));
update public.students s set paid_till = public.compute_paid_till(s.id)
 where exists (select 1 from public.monthly_dues d where d.student_id = s.id
                  and (d.status = 'void' or (coalesce(d.period_from, d.month) <= date_trunc('month', d.month)::date
                                             and d.period_to < (date_trunc('month', d.month) + interval '1 month - 1 day')::date)))
   and s.paid_till is distinct from public.compute_paid_till(s.id);

-- ---------------------------------------------------------------------
-- 8. grants: app ko kuch naya call nahi karna
-- ---------------------------------------------------------------------
revoke all on function public.generate_monthly_dues(date) from public, anon;
grant execute on function public.generate_monthly_dues(date) to authenticated;
revoke all on function public.ddd_stay_fee(numeric, date, date, date) from public, anon, authenticated;
revoke all on function public.ddd_exit_review_once(public.monthly_dues, numeric, date, text, text) from public, anon, authenticated;
revoke all on function public.ddd_exit_bills_sync(uuid, text) from public, anon, authenticated;
revoke all on function public.ddd_guard_due_after_exit() from public, anon, authenticated;
revoke all on function public.ddd_dues_exit_after_insert() from public, anon, authenticated;
revoke all on function public.ddd_students_exit_default() from public, anon, authenticated;
revoke all on function public.ddd_students_exit_bills() from public, anon, authenticated;
revoke all on function public.ddd_guard_due_period() from public, anon, authenticated;
revoke all on function public.ddd_dues_set_paid_to() from public, anon, authenticated;
revoke all on function public.compute_paid_till(uuid, date, numeric) from public, anon, authenticated;

comment on function public.ddd_exit_bills_sync(uuid, text) is
  '026: ek student ke bills uski exit date aur wapsi ki tareekh (rejoined_on) ke hisaab se (void / prorate / rejoin / credit review), exit khali = wapas. Sirf triggers aur SQL Editor.';

commit;

notify pgrst, 'reload schema';

-- verify: 026_check_after.sql (ek grid) aur 026_check_behaviour.sql (test, sab rollback)

-- ---------- ROLLBACK ----------
-- Wapas lena ho to 026_undo.sql poori file chalayein.
-- Pehle cleanup (void / merge) undo karein, warna void bill void hi rahenge.
-- Undo 022 wala generate_monthly_dues, 024 wale compute_paid_till /
-- ddd_dues_set_paid_to / ddd_due_paid_to / ddd_fee_range_plan, 014 wala
-- delete_fee_payment aur 020 wala dashboard bilkul wapas lagata hai, 026 ke
-- triggers / functions hatata hai. Log table, merged_into aur rejoined_on
-- column sirf khali hon to hatte hain.
