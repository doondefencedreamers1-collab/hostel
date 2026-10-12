-- =====================================================================
-- 028_fee_regen.sql   (026 ke BAAD chalayein. 027 ho ya na ho, dono mein chalta hai)
-- DDD Hostel - Monthly Fee badalne par bills (Phase 5, owner decision D-fee + FEES-3)
--
--  1. Director / Manager kisi student ki Monthly Fee badle (jiska bill ban chuka hai)
--     to app poochhega: Nayi fee kis mahine se lagani hai? (default = is mahine se).
--     Naya RPC public.ddd_fee_change(student, nayi fee, mahina, apply):
--       apply = false  -> sirf PREVIEW (kaun sa bill kitna hoga), kuch save nahi hota
--       apply = true   -> fee badlo + us mahine se aage ke saare chalu (void nahi) bill
--                         nayi fee par, wahi rules jo Generate lagata hai
--                         (joining / exit / wapsi ke din, 026 rules dobara).
--     Jama paise aur payments KABHI nahi badalte, payment usi bill se judi rehti hai.
--     Pending / status dobara gine jaate hain. Jama paise nayi fee se zyada hon
--     to bill ka baaki hatta hai aur Director ke liye credit review (026 log).
--     Har badlav ddd_fee_change_log mein: kisne, kab, purani / nayi fee, kis mahine se.
--  2. Generate dobara chalane par: is mahine (ya aage) ka AUTO bill nayi Monthly Fee
--     par aa jaata hai, agar fee bill banne ke baad badli. Kabhi nahi badalta:
--     haath se badla amount, 026 ka kata / void / wapsi wala bill, cleanup ka
--     fee_fix (owner fix), merge se aaya bill, 028 se pehle bana bill, pichhla mahina.
--     Duplicate bill kabhi nahi (student + mahina ek hi rehta hai).
--  3. Naye columns monthly_dues.auto_fee aur auto_amount: bill apne aap Monthly Fee
--     se bana (auto). Purane bills mein khali = fixed (Generate se nahi badlenge).
--  4. FEES-3: bill ban jaane ke baad Monthly Fee sirf Director / Manager badal sakte
--     hain. Naya student add karte waqt fee warden daal sakta hai (tab bill nahi hota).
--  5. Chhode hue (exit date wale) ya wapas aaye student ki fee badle to 026 ke
--     exit / wapsi rule har bill par dobara lagte hain (Left ke baad ka bill kabhi due nahi).
--  6. Staff ki fee 0 tabhi jab us record par koi purana baaki na ho (warna baaki chhup jaata).
--  7. Zyada jama (credit review) wala bill bhi auto rehta hai: fee baad mein badhe to Generate use nayi fee par laata hai.
--
-- Is file ke chalne se KOI bill / payment / student row nahi badalti.
-- Ek transaction, 2 baar chalana safe. Pehle backup lein. Class time ke bahar chalayein.
-- Phir 028_check.sql (ek grid, har row ok = true).    Undo: 028_undo.sql
-- Dhyan dein: 026_check_after.sql ki row 4 ab false dikhayegi kyunki
-- generate_monthly_dues ab 028 wala hai (026 ke saare rules andar wahi hain).
-- Yeh normal hai. 026_check_behaviour.sql SAB OK hi aana chahiye.
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------------------------------------------------------------------
-- 0. pre-check (kuch bhi alag = yahin ruk jaata hai, kuch nahi badalta)
-- ---------------------------------------------------------------------
do $pre$
declare
  h text;
  r record;
begin
  if to_regclass('public.ddd_dues_void_log') is null or to_regprocedure('public.ddd_exit_bills_sync(uuid,text)') is null then
    raise exception '028 RUKA: 026 (billing exit rules) live par nahi mila. Pehle 026 chalayein. Kuch nahi badla.';
  end if;
  if to_regprocedure('public.audit_trigger()') is null or to_regprocedure('public.is_director()') is null
     or to_regprocedure('public.ddd_is_api_caller()') is null or to_regprocedure('public.recompute_paid_till(uuid)') is null then
    raise exception '028 RUKA: audit_trigger / is_director / ddd_is_api_caller / recompute_paid_till nahi mile. Mujhe batayein. Kuch nahi badla.';
  end if;
  -- jo function 028 badalta hai: 026 wala (ya pehle se 028 wala = dobara chalana)
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.generate_monthly_dues(date)'));
  if h is null or h not in ('dc1b915e9229ae9b6952968878104450', '387a1c4bbf3befd90af6d1d67e2f745e') then
    raise exception '028 RUKA: live generate_monthly_dues 026 wala nahi hai (%). Kisi aur ne badla hai - mujhe batayein. Kuch nahi badla.', h;
  end if;
  -- jin 026 functions par 028 chalta hai: bilkul 026 text
  for r in select * from (values
             ('public.ddd_exit_bills_sync(uuid,text)', '36d917ff10af21abd6095df97d1ddba8'),
             ('public.ddd_exit_review_once(public.monthly_dues,numeric,date,text,text)', '9cbcabf64a9e0200808c55998af07296'),
             ('public.ddd_stay_fee(numeric,date,date,date)', '852926fef2d3b83bb1c4d07a0f22573b'),
             ('public.ddd_month_fee(numeric,date,date)', 'ce0718798846b2d7741d076f715b7886')) v(fn, fp) loop
    h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure(r.fn));
    if h is distinct from r.fp then
      raise exception '028 RUKA: % 026 wala nahi hai (%). Mujhe batayein. Kuch nahi badla.', r.fn, coalesce(h, 'nahi mila');
    end if;
  end loop;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'monthly_dues'
         and column_name in ('student_id', 'month', 'fee_amount', 'discount', 'paid_amount', 'pending', 'status', 'period_from', 'period_to')) <> 9
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'students'
            and column_name in ('monthly_fee', 'joining_date', 'exit_date', 'rejoined_on', 'merged_into', 'status')) <> 6 then
    raise exception '028 RUKA: monthly_dues / students ke columns expected jaise nahi. Mujhe batayein. Kuch nahi badla.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.monthly_dues'::regclass and contype = 'u'
                    and pg_get_constraintdef(oid) = 'UNIQUE (student_id, month)') then
    raise exception '028 RUKA: monthly_dues par UNIQUE (student_id, month) nahi mila. Mujhe batayein. Kuch nahi badla.';
  end if;
  -- naye columns pehle se hon (dobara chalana) to wahi type
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'monthly_dues'
                and column_name in ('auto_fee', 'auto_amount') and data_type <> 'numeric') then
    raise exception '028 RUKA: monthly_dues.auto_fee / auto_amount pehle se hai par alag type. Mujhe batayein. Kuch nahi badla.';
  end if;
  if to_regclass('public.ddd_fee_change_log') is not null
     and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ddd_fee_change_log'
                        and column_name = 'id' and data_type = 'uuid') then
    raise exception '028 RUKA: ddd_fee_change_log pehle se hai par alag tarah ki. Mujhe batayein. Kuch nahi badla.';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------
-- 1. bill auto price columns (khali = fixed, Generate se kabhi nahi badalta)
-- ---------------------------------------------------------------------
alter table public.monthly_dues add column if not exists auto_fee numeric(10,2);
alter table public.monthly_dues add column if not exists auto_amount numeric(10,2);
comment on column public.monthly_dues.auto_fee is
  '028: bill apne aap Monthly Fee se bana tha - us waqt ki Monthly Fee. Khali = fixed (haath se / 028 se pehle / 026 rule). Generate dobara chalne par sirf auto bill (fee_amount = auto_amount) nayi fee par aata hai.';
comment on column public.monthly_dues.auto_amount is
  '028: auto bill ka amount jab bana / nayi fee par aaya. fee_amount isse alag = kisi ne haath se ya rule se badla = Generate nahi chhuyega.';

-- ---------------------------------------------------------------------
-- 2. fee change log (har fee badlav + har bill ka badlav). Director / Manager padh sakte hain.
-- ---------------------------------------------------------------------
create table if not exists public.ddd_fee_change_log (
  id          uuid primary key default gen_random_uuid(),
  change_id   uuid not null,
  student_id  uuid,
  due_id      uuid,
  month       date,
  kind        text not null check (kind in ('fee_change', 'reprice', 'credit_review', 'rule', 'pin', 'skip', 'regen', 'regen_error')),
  old_amount  numeric(10,2),
  new_amount  numeric(10,2),
  old_status  text,
  new_status  text,
  paid_amount numeric(10,2),
  from_month  date,
  note        text not null,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid()
);
create index if not exists idx_ddd_fee_change_log_student on public.ddd_fee_change_log(student_id, created_at);
create index if not exists idx_ddd_fee_change_log_change on public.ddd_fee_change_log(change_id);
alter table public.ddd_fee_change_log enable row level security;
drop policy if exists ddd_fee_change_log_read on public.ddd_fee_change_log;
create policy ddd_fee_change_log_read on public.ddd_fee_change_log for select to authenticated using (public.is_director());
revoke all on public.ddd_fee_change_log from public, anon, authenticated;
grant select on public.ddd_fee_change_log to authenticated;
drop trigger if exists trg_ddd_fee_change_log_audit on public.ddd_fee_change_log;
create trigger trg_ddd_fee_change_log_audit
  after insert or update or delete on public.ddd_fee_change_log
  for each row execute function public.audit_trigger();
comment on table public.ddd_fee_change_log is
  '028: Monthly Fee badlav ka record. fee_change = fee kisne kab kitne se kitni ki (old_amount / new_amount = Monthly Fee, from_month = kis mahine se). reprice / credit_review / rule / pin / skip = us badlav mein har bill ka haal (old_amount / new_amount = bill amount). regen = Generate dobara chalne par auto bill nayi fee par.';

-- ---------------------------------------------------------------------
-- 3. FEES-3: bill ban jaane ke baad Monthly Fee sirf Director / Manager (app se)
-- ---------------------------------------------------------------------
create or replace function public.ddd_student_has_dues(p_student uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.monthly_dues d where d.student_id = p_student);
$$;

create or replace function public.ddd_students_fee_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.monthly_fee is distinct from old.monthly_fee
     and public.ddd_is_api_caller() and not coalesce(public.is_director(), false)
     and public.ddd_student_has_dues(old.id) then
    raise exception 'Is student ka bill ban chuka hai - Monthly Fee ab sirf Director / Manager badal sakte hain.' using errcode = '42501';
  end if;
  return new;
end $$;

drop trigger if exists trg_students_fee_guard on public.students;
create trigger trg_students_fee_guard
  before update of monthly_fee on public.students
  for each row execute function public.ddd_students_fee_guard();

-- ---------------------------------------------------------------------
-- 4. naya bill: Monthly Fee se bana (auto) to auto_fee / auto_amount bhar do.
--    App (API) se aaye values kabhi nahi maane jaate. SQL Editor / fee functions = trusted.
-- ---------------------------------------------------------------------
create or replace function public.ddd_dues_auto_price() returns trigger
language plpgsql set search_path = public as $$
declare
  m     date;
  me    date;
  v_fee numeric;
begin
  if tg_op = 'UPDATE' then
    if (new.auto_fee, new.auto_amount) is distinct from (old.auto_fee, old.auto_amount) and public.ddd_is_api_caller() then
      raise exception 'Bill ka auto price app se nahi badalta (system khud rakhta hai)' using errcode = '42501';
    end if;
    return new;
  end if;
  if public.ddd_is_api_caller() then
    new.auto_fee := null;
    new.auto_amount := null;
    return new;
  end if;
  if new.auto_fee is null and new.auto_amount is null and new.student_id is not null and new.month is not null
     and new.status is distinct from 'void' then
    m := date_trunc('month', new.month)::date;
    me := (m + interval '1 month - 1 day')::date;
    if new.month = m and coalesce(new.period_to, me) = me and coalesce(new.period_from, m) between m and me then
      v_fee := (select st.monthly_fee from public.students st where st.id = new.student_id);
      if coalesce(v_fee, 0) > 0 and new.fee_amount = public.ddd_stay_fee(v_fee, coalesce(new.period_from, m), me, m) then
        new.auto_fee := v_fee;
        new.auto_amount := new.fee_amount;
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_monthly_dues_auto_price on public.monthly_dues;
create trigger trg_monthly_dues_auto_price
  before insert or update of auto_fee, auto_amount on public.monthly_dues
  for each row execute function public.ddd_dues_auto_price();

-- ---------------------------------------------------------------------
-- 5. ek bill nayi fee par (026 jaisa paisa rule). Exit / wapsi wala kata bill yahan nahi.
--    Bill ke apne din (period_from .. period_to) x nayi fee = Generate wala rule.
--    Jama paise kabhi nahi badalte. Zyada jama = credit review (026 log), bill ka baaki hatta hai.
-- ---------------------------------------------------------------------
create or replace function public.ddd_fee_reprice_due(p_due uuid, p_fee numeric, p_mode text, p_batch text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d        public.monthly_dues%rowtype;
  v_exit   date;
  m        date;
  me       date;
  pf       date;
  pt       date;
  v_lg     text;
  v_new    numeric;
  v_disc   numeric;
  v_paid   numeric;
  v_fpay   numeric;
  n_fee    numeric;
  n_disc   numeric;
  n_status text;
  n_af     numeric;
  n_aa     numeric;
  v_act    text;
  v_note   text;
begin
  d := (select x from public.monthly_dues x where x.id = p_due for update);
  if d.id is null then return null; end if;
  v_exit := (select st.exit_date from public.students st where st.id = d.student_id);
  m := date_trunc('month', d.month)::date;
  me := (m + interval '1 month - 1 day')::date;
  pf := coalesce(d.period_from, m);
  pt := coalesce(d.period_to, me);
  v_disc := coalesce(d.discount, 0);
  v_paid := coalesce(d.paid_amount, 0);
  if d.status = 'void' then
    v_act := 'skip'; v_note := 'Cancelled (void) bill - nahi badla';
  elsif d.month <> m or pf < m or pf > me or pt < pf or pt > me then
    v_act := 'skip'; v_note := 'Purana cycle bill (tareekh mahine se bahar) - khud check karein';
  else
    v_lg := (select l.action from public.ddd_dues_void_log l
              where l.due_id = d.id and l.action in ('void', 'prorate', 'restore', 'rejoin')
              order by l.id desc limit 1);
    if v_lg in ('void', 'prorate', 'rejoin') then
      v_act := 'skip'; v_note := '026 exit / wapsi rule wala bill - is raste se nahi badalta';
    elsif p_mode = 'regen' and exists (select 1 from public.ddd_dues_void_log l where l.due_id = d.id
                                         and l.action in ('fee_fix', 'move', 'payment_move', 'merge_void', 'payment_remove')) then
      v_act := 'skip'; v_note := 'Cleanup wala bill - Generate se nahi badalta';
    end if;
  end if;

  if v_act is null then
    v_new := public.ddd_stay_fee(p_fee, pf, pt, m);
    if v_new = d.fee_amount then
      v_act := 'same'; n_fee := d.fee_amount; n_disc := v_disc; n_status := d.status;
      v_note := 'Bill pehle se nayi fee par';
    elsif v_paid > v_new - least(v_disc, v_new) then
      -- jama paise nayi fee (discount ke baad) se zyada: paise wahi, Director ke liye credit review
      v_fpay := v_new - least(v_disc, v_new);
      perform public.ddd_exit_review_once(d, v_fpay, v_exit,
        'Monthly Fee ' || regexp_replace(p_fee::text, '[.]00$', '') || ' hui - jama paise nayi fee (discount ke baad) se zyada, Director dekhein (credit review)', p_batch);
      v_act := 'credit_review';
      if d.fee_amount - v_disc - v_paid <= 0 then
        n_fee := d.fee_amount; n_disc := v_disc; n_status := d.status;
        v_note := 'Poora jama bill waisa hi, zyada jama ' || (v_paid - v_fpay) || ' credit review mein';
      else
        n_fee := v_paid + v_disc; n_disc := v_disc; n_status := 'paid';
        v_note := 'Bill ka baaki hataya (jama paise nayi fee se zyada), zyada jama ' || (v_paid - v_fpay) || ' credit review mein';
      end if;
    else
      v_act := 'reprice'; n_fee := v_new; n_disc := least(v_disc, v_new);
      n_status := case when n_fee - n_disc - v_paid > 0 then case when v_paid > 0 then 'partial' else 'pending' end
                       else 'paid' end;
      v_note := 'Nayi fee par';
    end if;
    -- credit review wala bill bhi auto: fee baad mein badhi to Generate use nayi fee par la sake
    n_af := case when n_fee = v_new or v_act = 'credit_review' then p_fee end;
    n_aa := case when n_fee = v_new or v_act = 'credit_review' then n_fee end;
    if (d.fee_amount, coalesce(d.discount, 0), d.status, d.auto_fee, d.auto_amount)
       is distinct from (n_fee, n_disc, n_status, n_af, n_aa) then
      update public.monthly_dues
         set fee_amount = n_fee, discount = n_disc, status = n_status, auto_fee = n_af, auto_amount = n_aa
       where id = d.id;
    end if;
  end if;
  return jsonb_build_object('due_id', d.id, 'month', m, 'action', v_act, 'note', v_note,
                            'old_fee_amount', d.fee_amount, 'new_fee_amount', coalesce(n_fee, d.fee_amount),
                            'discount', coalesce(n_disc, v_disc), 'paid_amount', v_paid,
                            'old_status', d.status, 'new_status', coalesce(n_status, d.status));
end $$;

-- ---------------------------------------------------------------------
-- 6. Generate dobara: is mahine (ya aage) ke AUTO bill nayi Monthly Fee par
-- ---------------------------------------------------------------------
create or replace function public.ddd_dues_regen_month(p_month date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  m     date := date_trunc('month', p_month)::date;
  me    date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  r     record;
  v_fee numeric;
  v_res jsonb;
  v_run uuid := gen_random_uuid();
  v_n   int := 0;
begin
  for r in
    select d.id, d.student_id, d.auto_fee as basis
      from public.monthly_dues d
      join public.students s on s.id = d.student_id
     where d.month = m
       and d.status is distinct from 'void'
       and d.auto_fee is not null and d.auto_amount is not null and d.fee_amount = d.auto_amount
       and d.auto_fee is distinct from coalesce(s.monthly_fee, 0)
       and s.merged_into is null and coalesce(s.status, 'active') <> 'left'
       and (s.exit_date is null or s.exit_date >= me)
     order by d.student_id, d.id
  loop
    -- Receive Fee jaisa lock order: pehle student, phir bill
    v_fee := (select coalesce(x.monthly_fee, 0) from public.students x where x.id = r.student_id for update);
    if not exists (select 1 from public.monthly_dues d where d.id = r.id and d.status is distinct from 'void'
                      and d.auto_fee is not null and d.fee_amount = d.auto_amount and d.auto_fee is distinct from v_fee) then
      continue;
    end if;
    v_res := public.ddd_fee_reprice_due(r.id, v_fee, 'regen', 'generate_monthly_dues');
    if v_res ->> 'action' in ('reprice', 'credit_review') then
      insert into public.ddd_fee_change_log(change_id, student_id, due_id, month, kind, old_amount, new_amount,
                                            old_status, new_status, paid_amount, note)
      values (v_run, r.student_id, r.id, m, 'regen', (v_res ->> 'old_fee_amount')::numeric, (v_res ->> 'new_fee_amount')::numeric,
              v_res ->> 'old_status', v_res ->> 'new_status', (v_res ->> 'paid_amount')::numeric,
              'Generate dobara: Monthly Fee ' || r.basis || ' se ' || v_fee || ' hui - ' || (v_res ->> 'note'));
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------------
-- 7. generate_monthly_dues: 026 text bilkul wahi + aakhir mein 028 dobara-Generate hissa
-- ---------------------------------------------------------------------
create or replace function public.generate_monthly_dues(p_month date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
-- 028: 026 text bilkul wahi, sirf aakhir mein dobara-Generate hissa (auto bill nayi fee par)
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
  -- 028: dobara Generate = is mahine (ya aage) ka AUTO bill nayi Monthly Fee par.
  --      Pichhla mahina kabhi nahi. Is hisse mein gadbad ho to bhi naye bill bane rehte hain (log mein regen_error).
  if m_start >= v_cur then
    begin
      perform public.ddd_dues_regen_month(m_start);
    exception when others then
      insert into public.ddd_fee_change_log(change_id, month, kind, note)
      values (gen_random_uuid(), m_start, 'regen_error', left('Generate dobara: fee update nahi hua - ' || sqlerrm, 500));
    end;
  end if;
  return cnt;
end; $function$;

-- ---------------------------------------------------------------------
-- 8. fee change (andar ka kaam). Preview = yahi chala kar sab wapas (kuch save nahi).
-- ---------------------------------------------------------------------
create or replace function public.ddd_fee_change_run(p_student uuid, p_new_fee numeric, p_from_month date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s        public.students%rowtype;
  d        public.monthly_dues%rowtype;
  lg       public.ddd_dues_void_log%rowtype;
  r        record;
  v_cur    date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  v_from   date;
  v_old    numeric;
  v_change uuid := gen_random_uuid();
  v_batch  text := 'ddd_fee_change';
  v_before jsonb;
  v_after  jsonb;
  v_acts   jsonb := '{}';
  v_res    jsonb;
  v_list   jsonb := '[]';
  v_item   jsonb;
  v_sync   boolean := false;
  v_log0   bigint;
  m        date;
  me       date;
  pfo      date;
  pto      date;
  v_o2     numeric;
  v_act    text;
  v_note   text;
  n_rep    int := 0;
  n_cr     int := 0;
  n_skip   int := 0;
  n_pin    int := 0;
  n_rule   int := 0;
  v_ot     numeric := 0;
  v_nt     numeric := 0;
  v_name   text;
  v_due    numeric;
  v_oldt   text;
  v_newt   text;
begin
  s := (select x from public.students x where x.id = p_student for update);
  if s.id is null then raise exception 'Student nahi mila'; end if;
  v_name := coalesce(nullif(trim(s.full_name), ''), 'Student');
  if s.merged_into is not null then
    raise exception '% merged purana record hai - fee naye record par badlein.', v_name;
  end if;
  if p_new_fee is null or p_new_fee < 0 then raise exception 'Nayi Monthly Fee 0 ya usse zyada honi chahiye'; end if;
  if p_new_fee > 9999999 then raise exception 'Monthly Fee bahut zyada hai'; end if;
  if round(p_new_fee, 2) <> p_new_fee then raise exception 'Monthly Fee mein paise 2 decimal tak hi'; end if;
  v_from := date_trunc('month', coalesce(p_from_month, v_cur))::date;
  if s.joining_date is not null and v_from < date_trunc('month', s.joining_date)::date then
    raise exception 'Joining (%) se pehle ka mahina nahi chun sakte', to_char(s.joining_date, 'Mon YYYY');
  end if;
  if v_from > (v_cur + interval '12 months')::date then
    raise exception 'Itna aage ka mahina nahi chun sakte (zyada se zyada 12 mahine aage)';
  end if;
  v_old := s.monthly_fee;
  v_oldt := coalesce(regexp_replace(v_old::text, '[.]00$', ''), '-');
  v_newt := regexp_replace(p_new_fee::text, '[.]00$', '');
  v_log0 := coalesce((select max(l.id) from public.ddd_dues_void_log l), 0);
  v_before := (select coalesce(jsonb_object_agg(x.id::text, jsonb_build_object('month', x.month, 'fee', x.fee_amount,
                       'disc', coalesce(x.discount, 0), 'paid', coalesce(x.paid_amount, 0), 'status', x.status,
                       'pf', x.period_from, 'pt', x.period_to)), '{}'::jsonb)
                 from public.monthly_dues x where x.student_id = s.id);

  -- 1. student ki Monthly Fee (plan amount aur Paid Till purane triggers khud)
  if v_old is distinct from p_new_fee then
    update public.students set monthly_fee = p_new_fee where id = s.id;
  end if;

  -- 2. is mahine se chune mahine tak ke auto bills: purani fee par hi rahenge (Generate nahi badlega)
  for d in select x.* from public.monthly_dues x
            where x.student_id = s.id and x.month >= v_cur and x.month < v_from
              and x.auto_fee is not null and x.auto_fee is distinct from p_new_fee
            order by x.month for update loop
    update public.monthly_dues set auto_fee = null, auto_amount = null where id = d.id;
    v_acts := v_acts || jsonb_build_object(d.id::text, jsonb_build_object('action', 'pin',
                'note', 'Chune mahine se pehle ka bill - purani fee par hi rahega'));
  end loop;

  -- 3. chune mahine se aage ke bill
  for d in select x.* from public.monthly_dues x
            where x.student_id = s.id and x.month >= v_from
            order by x.month, x.id for update loop
    m := date_trunc('month', d.month)::date;
    me := (m + interval '1 month - 1 day')::date;
    lg := (select l from public.ddd_dues_void_log l
            where l.due_id = d.id and l.action in ('void', 'prorate', 'restore', 'rejoin')
            order by l.id desc limit 1);
    if d.status is distinct from 'void' and lg.id is not null and lg.action in ('prorate', 'rejoin') then
      -- 026 exit / wapsi se kata bill: rule se pehle ka amount nayi fee par, phir 026 rule dobara (neeche sync)
      pfo := coalesce(lg.old_period_from, d.period_from, m);
      pto := coalesce(lg.old_period_to, me);
      if d.month <> m or pfo < m or pfo > me or pto < pfo or pto > me then
        v_acts := v_acts || jsonb_build_object(d.id::text, jsonb_build_object('action', 'skip',
                    'note', 'Purana cycle bill (tareekh mahine se bahar) - khud check karein'));
        continue;
      end if;
      if d.fee_amount is distinct from lg.new_fee_amount or d.period_to is distinct from lg.new_period_to
         or (lg.new_period_from is not null and d.period_from is distinct from lg.new_period_from) then
        v_acts := v_acts || jsonb_build_object(d.id::text, jsonb_build_object('action', 'skip',
                    'note', 'Bill exit / wapsi rule ke baad haath se badla gaya - khud check karein'));
        continue;
      end if;
      v_o2 := public.ddd_stay_fee(p_new_fee, pfo, pto, m);
      if v_o2 is distinct from lg.old_fee_amount then
        insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to, old_period_from,
                                             new_fee_amount, new_period_to, new_period_from, amount_note, reason, batch)
        values (d.id, d.student_id, d.month, lg.action, v_o2, coalesce(lg.old_discount, 0), lg.old_status, lg.old_period_to, lg.old_period_from,
                d.fee_amount, d.period_to, lg.new_period_from,
                (v_o2 - coalesce(lg.old_discount, 0)) - (d.fee_amount - coalesce(d.discount, 0)),
                'Monthly Fee ' || v_oldt || ' se ' || v_newt || ' (' || to_char(v_from, 'Mon YYYY')
                || ' se): rule se pehle ka bill ab ' || v_o2 || ', 026 rule dobara', v_batch);
      end if;
      v_sync := true;
      v_acts := v_acts || jsonb_build_object(d.id::text, jsonb_build_object('action', 'rule',
                  'note', '026 exit / wapsi rule nayi fee se dobara laga'));
    else
      v_res := public.ddd_fee_reprice_due(d.id, p_new_fee, 'reprice', v_batch);
      v_acts := v_acts || jsonb_build_object(d.id::text, jsonb_build_object('action', v_res ->> 'action', 'note', v_res ->> 'note',
                                                                            'fee', v_res -> 'new_fee_amount'));
    end if;
  end loop;

  -- 4. 026 exit / wapsi wale bill nayi fee se (026 ka apna function, wahi rules).
  --    Exit date ya wapsi wala student = har bill par 026 rule dobara (poora jama bill bhi,
  --    warna exit ke baad ka bill nayi fee par due ban jaata)
  if s.exit_date is not null or s.rejoined_on is not null then
    v_sync := true;
  end if;
  if v_sync then
    perform public.ddd_exit_bills_sync(s.id, v_batch);
    -- 026 rule wale bill auto nahi (Generate inhe kabhi nahi chhuta)
    update public.monthly_dues x set auto_fee = null, auto_amount = null
     where x.student_id = s.id and (x.auto_fee is not null or x.auto_amount is not null)
       and v_acts -> (x.id::text) ->> 'action' = 'rule';
  end if;

  -- 4b. 029 Staff fee 0 = kabhi due nahi dikhta. Purana baaki ho to pehle woh clear (warna chhup jaata)
  if p_new_fee = 0 and coalesce(to_jsonb(s) ->> 'occupant_type', 'student') = 'staff' then
    v_due := (select coalesce(sum(x.fee_amount - coalesce(x.discount, 0) - coalesce(x.paid_amount, 0)), 0)
                from public.monthly_dues x
               where x.student_id = s.id and x.status is distinct from 'void'
                 and x.fee_amount - coalesce(x.discount, 0) - coalesce(x.paid_amount, 0) > 0);
    if v_due > 0 then
      raise exception '% Staff hai aur purane bill mein Rs % baaki hai. Fee 0 wala Staff kabhi due nahi dikhta, isliye pehle purana baaki clear karein (fee lein ya bill theek karein), phir fee 0 karein.',
        v_name, regexp_replace(v_due::text, '[.]00$', '') using errcode = '22023';
    end if;
  end if;

  -- 5. kya badla: pehle / baad ka farq, har bill ki line
  v_after := (select coalesce(jsonb_object_agg(x.id::text, jsonb_build_object('month', x.month, 'fee', x.fee_amount,
                      'disc', coalesce(x.discount, 0), 'paid', coalesce(x.paid_amount, 0), 'status', x.status,
                      'pf', x.period_from, 'pt', x.period_to)), '{}'::jsonb)
                from public.monthly_dues x where x.student_id = s.id);
  for r in select a.key as id, a.value as af, v_before -> a.key as bf, v_acts -> a.key as ac
             from jsonb_each(v_after) a
            order by (a.value ->> 'month')::date, a.key loop
    if r.ac is null and r.af = r.bf then continue; end if;
    v_act := coalesce(r.ac ->> 'action', 'rule');
    v_note := coalesce(r.ac ->> 'note', '026 exit / wapsi rule ne nayi fee se dobara hisaab kiya');
    if v_act = 'rule' and r.af = r.bf then
      v_act := 'same'; v_note := '026 rule ke baad bhi bill wahi';
    elsif v_act in ('reprice', 'credit_review') and v_sync and r.af = r.bf then
      v_act := 'same'; v_note := '026 exit / wapsi rule se bill wahi raha';
    elsif v_act = 'reprice' and v_sync and (r.af -> 'fee') is distinct from (r.ac -> 'fee') then
      v_act := 'rule'; v_note := '026 exit / wapsi rule ne nayi fee se dobara hisaab kiya';
    end if;
    v_item := jsonb_build_object('due_id', r.id, 'month', r.af ->> 'month', 'action', v_act, 'note', v_note,
                'old_fee_amount', (r.bf ->> 'fee')::numeric, 'new_fee_amount', (r.af ->> 'fee')::numeric,
                'discount', (r.af ->> 'disc')::numeric, 'paid_amount', (r.af ->> 'paid')::numeric,
                'old_pending', (r.bf ->> 'fee')::numeric - (r.bf ->> 'disc')::numeric - (r.bf ->> 'paid')::numeric,
                'new_pending', (r.af ->> 'fee')::numeric - (r.af ->> 'disc')::numeric - (r.af ->> 'paid')::numeric,
                'old_status', r.bf ->> 'status', 'new_status', r.af ->> 'status',
                'old_period_to', r.bf ->> 'pt', 'new_period_to', r.af ->> 'pt');
    v_list := v_list || jsonb_build_array(v_item);
    if r.af <> r.bf then
      v_ot := v_ot + (r.bf ->> 'fee')::numeric - (r.bf ->> 'disc')::numeric;
      v_nt := v_nt + (r.af ->> 'fee')::numeric - (r.af ->> 'disc')::numeric;
    end if;
    if v_act = 'reprice' then n_rep := n_rep + 1;
    elsif v_act = 'credit_review' then n_cr := n_cr + 1;
    elsif v_act = 'skip' then n_skip := n_skip + 1;
    elsif v_act = 'pin' then n_pin := n_pin + 1;
    elsif v_act = 'rule' then n_rule := n_rule + 1;
    end if;
  end loop;
  n_cr := greatest(n_cr, (select count(*) from public.ddd_dues_void_log l
                           where l.id > v_log0 and l.student_id = s.id and l.action = 'credit_review')::int);

  -- 6. log (kisne, kab, purani / nayi fee, kis mahine se, har bill)
  if v_old is distinct from p_new_fee or jsonb_array_length(v_list) > 0 then
    insert into public.ddd_fee_change_log(change_id, student_id, kind, old_amount, new_amount, from_month, note)
    values (v_change, s.id, 'fee_change', v_old, p_new_fee, v_from,
            v_name || ': Monthly Fee ' || v_oldt || ' se ' || v_newt || ', ' || to_char(v_from, 'Mon YYYY')
            || ' se. Bill badle ' || (n_rep + n_rule) || ', credit review ' || n_cr || ', chhode ' || n_skip || ', purani fee par ' || n_pin);
    insert into public.ddd_fee_change_log(change_id, student_id, due_id, month, kind, old_amount, new_amount, old_status, new_status,
                                          paid_amount, from_month, note)
    select v_change, s.id, (e ->> 'due_id')::uuid, (e ->> 'month')::date, e ->> 'action',
           (e ->> 'old_fee_amount')::numeric, (e ->> 'new_fee_amount')::numeric, e ->> 'old_status', e ->> 'new_status',
           (e ->> 'paid_amount')::numeric, v_from, e ->> 'note'
      from jsonb_array_elements(v_list) e
     where e ->> 'action' in ('reprice', 'credit_review', 'rule', 'pin', 'skip');
  end if;

  return jsonb_build_object(
    'ok', true, 'change_id', v_change, 'student_id', s.id, 'name', v_name,
    'old_fee', v_old, 'new_fee', p_new_fee, 'from_month', v_from,
    'repriced', n_rep, 'rule', n_rule, 'credit_review', n_cr, 'skipped', n_skip, 'pinned', n_pin,
    'old_total', v_ot, 'new_total', v_nt, 'delta', v_nt - v_ot,
    'paid_till', (select st.paid_till from public.students st where st.id = s.id),
    'bills', v_list,
    'message', v_name || ': Monthly Fee ' || v_oldt || ' se ' || v_newt || ' (' || to_char(v_from, 'Mon YYYY')
               || ' se). ' || (n_rep + n_rule) || ' bill nayi fee par'
               || case when n_cr > 0 then ', ' || n_cr || ' credit review (zyada jama, Director dekhein)' else '' end
               || case when n_skip > 0 then ', ' || n_skip || ' bill nahi badle (dekhein)' else '' end
               || '. Jama paise wahi.');
end $$;

-- ---------------------------------------------------------------------
-- 9. app RPC: Director / Manager. apply = false = sirf preview (sab wapas, kuch save nahi)
-- ---------------------------------------------------------------------
create or replace function public.ddd_fee_change(p_student uuid, p_new_fee numeric, p_from_month date default null, p_apply boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res jsonb;
begin
  if auth.uid() is not null or session_user = 'authenticator' then
    if auth.uid() is null then
      raise exception 'Login required' using errcode = '42501';
    end if;
    if not coalesce(public.is_director(), false) then
      raise exception 'Bill bane student ki Monthly Fee sirf Director / Manager badal sakte hain' using errcode = '42501';
    end if;
  end if;
  if coalesce(p_apply, false) then
    v_res := public.ddd_fee_change_run(p_student, p_new_fee, p_from_month);
    return v_res || jsonb_build_object('applied', true);
  end if;
  begin
    v_res := public.ddd_fee_change_run(p_student, p_new_fee, p_from_month);
    raise exception using errcode = 'DDDPV', message = 'ddd_fee_change preview';
  exception when sqlstate 'DDDPV' then
    null;
  end;
  return v_res || jsonb_build_object('applied', false, 'change_id', null);
end $$;

comment on function public.ddd_fee_change(uuid, numeric, date, boolean) is
  '028: Director / Manager. Monthly Fee badlo + p_from_month (khali = is IST mahine) se aage ke chalu bill nayi fee par (Generate wale rules, 026 exit / wapsi rules). p_apply false = sirf preview, kuch save nahi. Jama paise / payments kabhi nahi badalte. Log: ddd_fee_change_log.';

-- ---------------------------------------------------------------------
-- 10. rights: app sirf ddd_fee_change + generate (aur guard ka chhota helper) chala sakta hai
-- ---------------------------------------------------------------------
revoke all on function public.generate_monthly_dues(date) from public, anon;
grant execute on function public.generate_monthly_dues(date) to authenticated;
revoke all on function public.ddd_fee_change(uuid, numeric, date, boolean) from public, anon;
grant execute on function public.ddd_fee_change(uuid, numeric, date, boolean) to authenticated;
revoke all on function public.ddd_student_has_dues(uuid) from public, anon;
grant execute on function public.ddd_student_has_dues(uuid) to authenticated;
revoke all on function public.ddd_fee_change_run(uuid, numeric, date) from public, anon, authenticated;
revoke all on function public.ddd_fee_reprice_due(uuid, numeric, text, text) from public, anon, authenticated;
revoke all on function public.ddd_dues_regen_month(date) from public, anon, authenticated;
revoke all on function public.ddd_students_fee_guard() from public, anon, authenticated;
revoke all on function public.ddd_dues_auto_price() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 11. verify (kuch bhi galat = poora rollback)
-- ---------------------------------------------------------------------
do $verify$
declare
  h text;
begin
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'monthly_dues'
        and column_name in ('auto_fee', 'auto_amount') and data_type = 'numeric') <> 2 then
    raise exception '028 VERIFY FAIL: auto_fee / auto_amount columns nahi bane.';
  end if;
  if (select count(*) from pg_trigger where not tgisinternal and tgenabled = 'O' and (tgrelid, tgname) in
        (('public.students'::regclass, 'trg_students_fee_guard'), ('public.monthly_dues'::regclass, 'trg_monthly_dues_auto_price'),
         ('public.ddd_fee_change_log'::regclass, 'trg_ddd_fee_change_log_audit'))) <> 3 then
    raise exception '028 VERIFY FAIL: triggers nahi bane.';
  end if;
  h := (select md5(regexp_replace(regexp_replace(prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')) from pg_proc
         where oid = to_regprocedure('public.generate_monthly_dues(date)'));
  if h is distinct from '387a1c4bbf3befd90af6d1d67e2f745e' then
    raise exception '028 VERIFY FAIL: generate_monthly_dues 028 text nahi (%).', h;
  end if;
  if not (select prosecdef from pg_proc where oid = to_regprocedure('public.generate_monthly_dues(date)')) then
    raise exception '028 VERIFY FAIL: generate_monthly_dues SECURITY DEFINER nahi.';
  end if;
  if has_function_privilege('anon', 'public.generate_monthly_dues(date)', 'execute')
     or has_function_privilege('anon', 'public.ddd_fee_change(uuid,numeric,date,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.ddd_fee_change_run(uuid,numeric,date)', 'execute')
     or has_function_privilege('authenticated', 'public.ddd_fee_reprice_due(uuid,numeric,text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.ddd_dues_regen_month(date)', 'execute')
     or not has_function_privilege('authenticated', 'public.generate_monthly_dues(date)', 'execute')
     or not has_function_privilege('authenticated', 'public.ddd_fee_change(uuid,numeric,date,boolean)', 'execute') then
    raise exception '028 VERIFY FAIL: function rights galat.';
  end if;
  if not coalesce((select relrowsecurity from pg_class where oid = 'public.ddd_fee_change_log'::regclass), false)
     or has_table_privilege('anon', 'public.ddd_fee_change_log', 'select')
     or has_table_privilege('authenticated', 'public.ddd_fee_change_log', 'insert,update,delete') then
    raise exception '028 VERIFY FAIL: ddd_fee_change_log rights galat.';
  end if;
end
$verify$;

commit;

notify pgrst, 'reload schema';

-- verify: 028_check.sql (ek grid, har row ok = true)

-- ---------- ROLLBACK ----------
-- Wapas lena ho to pehle naya app hata kar purana app lagayein, phir 028_undo.sql poori file chalayein.
-- Undo generate_monthly_dues ko bilkul 026 text par wapas lagata hai, 028 ke triggers, functions
-- aur auto_fee / auto_amount columns hatata hai. ddd_fee_change_log sirf khali ho to hatti hai
-- (warna record ke liye rehti hai). Jo bill fee change se nayi fee par aa chuke hain woh waise hi
-- rehte hain (yeh Director ka faisla tha), jama paise kabhi nahi badalte.
