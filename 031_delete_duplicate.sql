-- =====================================================================
-- 031_delete_duplicate.sql   (026 aur 027 ke baad, Phase 5 ki aakhri file)
-- DDD Hostel - "Delete Duplicate" student (owner rules R7, R10, D-dup)
--
-- KYA KARTA HAI (owner ke liye)
--  1. Duplicate ka rule (sirf yahi) - koi DOOSRA record ACTIVE ho (merge nahi hua)
--       NAAM same    (chhote / bade akshar aur extra space ignore)
--       MOBILE same  (sirf student ka apna mobile, parent ka nahi. Sirf digits,
--                     aakhri 10 digit, +91 / 0091 / shuru ka 0 ignore. 9999999999,
--                     1234567890 jaise dummy number = mobile nahi)
--     Rule poora na ho to - This record is not a duplicate, deletion not allowed.
--  2. ddd_duplicate_candidates(student) = side by side screen ke liye.
--     Pehli line = jo record hatana hai, baaki = uske ACTIVE original
--     (naam, father, mobile, hostel, room / bed, joining, fee, bills, payments,
--     aur hatane par har mahine ke bill ka kya hoga). 0 line = duplicate nahi.
--  3. ddd_delete_duplicate(duplicate, original, payment_shift)
--     - Sirf Director aur Manager (power duplicate_delete). Warden ke liye nahi.
--     - Rule server par dobara check hota hai.
--     - Duplicate par paise jama hon aur payment_shift false = error DDP01
--       (app poochhe "payments original par shift karke delete karein?").
--     - Phase 2 cleanup (026 D2) ke same mahine wale rule
--         sirf duplicate par us mahine ka bill    = bill payments ke saath original par
--         dono par bill, paise sirf duplicate par = duplicate ka bill void, payment
--                                                   original ke bill par (fit ho to)
--         dono par bill, duplicate par paise nahi = duplicate ka bill void
--         dono par paise (double payment)         = RUKTA hai, kuch nahi badalta
--     - Record DELETE nahi hota (soft delete) - merged_into = original, status Left.
--       Fee generation, dues, gintiyan, common expense split sab se hat jaata hai.
--       Common expense (030 lagi ho) ka split apne aap dobara banta hai (R7).
--     - Complaint, purani bed history, attendance original par.
--     - Log table duplicate_deletion_log - kisne, kab, kaunsa original, kya shift
--       hua, aur hataye record ki poori copy.
--     - Rukta hai (kuch nahi badalta) jab - duplicate bed par hai, alag hostel
--       mein paise / bill shift karne hon, hostel transfer lagta hai, ya kisi
--       record ka naam / mobile pichhle 30 din mein Director ke alawa kisi ne
--       badla hai (galat record ko duplicate bana kar hatane se bachav, M6).
--     - Original ki Monthly Fee duplicate se kam ho, ya duplicate ka bada bill void
--       ho kar original ka chhota bill rahe (fee kam ho rahi hai) = laal warning,
--       Director / Manager ko alag se haan karna padta hai (error DDF01 warna).
--  4. merged_into app se seedha sirf asli Director badal sakta hai (026 jaisa).
--     Manager / Warden ke liye merge sirf Delete Duplicate se (wahan saare check,
--     log, paise ka hisaab hota hai).
--
-- KAISE CHALAYEIN
--  - Pehle Supabase backup lein. Class time ke bahar. 026 aur 027 pehle.
--  - Poori file SQL Editor mein ek baar Run. Do baar chalana safe hai.
--  - Pre-check fail = kuch nahi badla. Baad mein 031_check.sql (har row ok = true).
--  - Wapas lena ho to 031_undo.sql.
--  - Is file se koi purani data row nahi badalti (sirf naye functions aur log table).
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------------------------------------------------------------------
-- STEP 1. PRE-CHECK
-- ---------------------------------------------------------------------
do $pre$
declare
  v_miss text;
  r      record;
begin
  if to_regclass('public.ddd_dues_void_log') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'students' and column_name = 'merged_into') then
    raise exception '031 RUKA: 026 (billing exit rules) is database mein nahi mili. Pehle 026 chalayein. Kuch nahi badla.';
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.ddd_dues_void_log'::regclass and contype = 'c'
                    and pg_get_constraintdef(oid) like '%merge_void%' and pg_get_constraintdef(oid) like '%payment_move%'
                    and pg_get_constraintdef(oid) like '%''move''%') then
    raise exception '031 RUKA: 026 ka log (ddd_dues_void_log) move / payment_move / merge_void nahi maanta. Developer ko batayein. Kuch nahi badla.';
  end if;
  if to_regprocedure('public.ddd_can(text)') is null or to_regprocedure('public.is_real_director()') is null
     or to_regprocedure('public.ddd_is_trusted_session()') is null or to_regclass('public.role_permissions') is null then
    raise exception '031 RUKA: 027 (roles permissions) is database mein nahi mili. Pehle 027 chalayein. Kuch nahi badla.';
  end if;
  v_miss := (select string_agg(t, ', ') from unnest(array['students', 'monthly_dues', 'fee_payments', 'beds', 'rooms', 'hostels', 'users',
                                                          'roles', 'audit_logs', 'complaints', 'bed_allocations', 'student_attendance']) t
              where to_regclass('public.' || t) is null);
  if v_miss is not null then
    raise exception '031 RUKA: table nahi mili - %. Kuch nahi badla.', v_miss;
  end if;
  v_miss := (select string_agg(x.tbl || '.' || x.col, ', ')
               from (values ('students', 'id'), ('students', 'full_name'), ('students', 'father_name'), ('students', 'mobile'),
                            ('students', 'status'), ('students', 'hostel_id'), ('students', 'joining_date'), ('students', 'exit_date'),
                            ('students', 'monthly_fee'), ('students', 'created_at'), ('students', 'created_by'),
                            ('students', 'current_bed_id'), ('students', 'merged_into'),
                            ('monthly_dues', 'id'), ('monthly_dues', 'student_id'), ('monthly_dues', 'month'), ('monthly_dues', 'fee_amount'),
                            ('monthly_dues', 'discount'), ('monthly_dues', 'paid_amount'), ('monthly_dues', 'status'),
                            ('monthly_dues', 'hostel_id'), ('monthly_dues', 'period_to'),
                            ('fee_payments', 'id'), ('fee_payments', 'due_id'), ('fee_payments', 'student_id'), ('fee_payments', 'amount'),
                            ('fee_payments', 'discount_amount'), ('fee_payments', 'payment_date'), ('fee_payments', 'receipt_number'),
                            ('fee_payments', 'advance_group_id'), ('fee_payments', 'mode'), ('fee_payments', 'created_at'),
                            ('beds', 'student_id'), ('beds', 'bed_number'), ('beds', 'room_id'), ('rooms', 'room_number'),
                            ('complaints', 'student_id'), ('bed_allocations', 'student_id'),
                            ('student_attendance', 'student_id'), ('student_attendance', 'date'),
                            ('audit_logs', 'entity_type'), ('audit_logs', 'entity_id'), ('audit_logs', 'before'), ('audit_logs', 'after'),
                            ('users', 'full_name'), ('hostels', 'code'), ('hostels', 'name')) x(tbl, col)
              where not exists (select 1 from information_schema.columns c
                                 where c.table_schema = 'public' and c.table_name = x.tbl and c.column_name = x.col));
  if v_miss is not null then
    raise exception '031 RUKA: columns nahi mile - %. Developer ko batayein. Kuch nahi badla.', v_miss;
  end if;
  v_miss := (select string_agg(f, ', ') from unnest(array['public.audit_trigger()', 'public.recompute_paid_till(uuid)']) f
              where to_regprocedure(f) is null);
  if v_miss is not null then
    raise exception '031 RUKA: function nahi mila - %. Kuch nahi badla.', v_miss;
  end if;
  -- is file ke naam ke functions pehle se hon to sirf 031 wale hi
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
      raise exception '031 RUKA: function % pehle se hai par uska code anjaana hai (%). Developer ko batayein. Kuch nahi badla.', r.f, r.fp;
    end if;
  end loop;
  if to_regprocedure('public.ddd_delete_duplicate(uuid,uuid,boolean)') is not null then
    raise exception '031 RUKA: purana (draft) Delete Duplicate function mila. Developer ko batayein. Kuch nahi badla.';
  end if;
  if to_regclass('public.duplicate_deletion_log') is not null
     and (select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'duplicate_deletion_log'
             and column_name in ('id', 'deleted_student_id', 'original_student_id', 'deleted_by', 'deleted_at', 'snapshot',
                                 'moved_dues', 'moved_payments', 'moved_amount', 'dropped_dues', 'dropped_pending', 'cexp_recalculated')) <> 12 then
    raise exception '031 RUKA: duplicate_deletion_log pehle se hai par columns alag hain. Developer ko batayein. Kuch nahi badla.';
  end if;
end
$pre$;

-- ---------------------------------------------------------------------
-- STEP 2. log table (har Delete Duplicate ka record)
-- ---------------------------------------------------------------------
create table if not exists public.duplicate_deletion_log (
  id                  uuid primary key default gen_random_uuid(),
  deleted_student_id  uuid not null,
  original_student_id uuid not null,
  deleted_name        text,
  original_name       text,
  mobile_key          text,
  hostel_id           uuid,
  original_hostel_id  uuid,
  deleted_by          uuid default auth.uid(),
  deleted_by_name     text,
  deleted_at          timestamptz not null default now(),
  moved_dues          int not null default 0,
  moved_payments      int not null default 0,
  moved_amount        numeric(12,2) not null default 0,
  dropped_dues        int not null default 0,
  dropped_pending     numeric(12,2) not null default 0,
  cexp_recalculated   int,
  snapshot            jsonb not null
);
create index if not exists idx_duplicate_deletion_log_dup on public.duplicate_deletion_log(deleted_student_id);
create index if not exists idx_duplicate_deletion_log_orig on public.duplicate_deletion_log(original_student_id);
create index if not exists idx_duplicate_deletion_log_at on public.duplicate_deletion_log(deleted_at desc);
comment on table public.duplicate_deletion_log is
  '031: har Delete Duplicate ka record (soft delete - record merged_into = original, status left). deleted_by = kisne, dropped_dues = duplicate ke kitne bill void hue, cexp_recalculated = kitne common expense dobara bane. snapshot = record, bills, payments ki pehle wali copy.';

drop trigger if exists trg_duplicate_deletion_log_audit on public.duplicate_deletion_log;
create trigger trg_duplicate_deletion_log_audit
  after insert or update or delete on public.duplicate_deletion_log
  for each row execute function public.audit_trigger();

alter table public.duplicate_deletion_log enable row level security;
drop policy if exists duplicate_deletion_log_read on public.duplicate_deletion_log;
create policy duplicate_deletion_log_read on public.duplicate_deletion_log
  for select to authenticated using ((select public.ddd_can('audit_view')));

-- ---------------------------------------------------------------------
-- STEP 3. chhote helper functions
-- ---------------------------------------------------------------------
-- naam ki chaabi - chhote akshar, saari space (tab, non breaking space bhi) ek space, aage peeche nahi
create or replace function public.ddd_dup_name_key(p text) returns text
language sql immutable set search_path = public as $$
  select nullif(btrim(lower(regexp_replace(coalesce(p, ''), '[[:space:]' || chr(160) || ']+', ' ', 'g'))), '');
$$;

-- mobile ki chaabi - sirf digits, aakhri 10. Aage sirf 0 / 91 / 0091 / 910 jaisa hi ho sakta hai.
-- 10 se kam digit, aage kuch aur, ya dummy number = null (null kabhi match nahi karta)
create or replace function public.ddd_dup_mobile_key(p text) returns text
language plpgsql immutable set search_path = public as $$
declare
  d text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
  k text;
begin
  if length(d) < 10 then
    return null;
  end if;
  k := right(d, 10);
  if left(d, length(d) - 10) !~ '^0*(91)?0*$' then
    return null;
  end if;
  if k ~ '^(.)\1{9}$' or k in ('1234567890', '0123456789', '9876543210') then
    return null;
  end if;
  return k;
end $$;

create or replace function public.ddd_dup_rs(p numeric) returns text
language sql immutable set search_path = public as $$
  select 'Rs ' || case when p is null then '0'
                       when p = trunc(p) then trunc(p)::text
                       else to_char(p, 'FM999999999990.00') end;
$$;

-- naam / mobile kab kisne badla (audit_logs se). blocks = pichhle 30 din mein, asli Director ya SQL Editor ke alawa kisi ne (M6)
create or replace function public.ddd_dup_identity(p_student uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', l.created_at, 'by', l.user_id,
           'by_name', case when l.user_id is null then 'SQL Editor / system' else coalesce(u.full_name, l.user_id::text) end,
           'by_role', r.name,
           'old_name', l.before ->> 'full_name', 'new_name', l.after ->> 'full_name',
           'old_mobile', l.before ->> 'mobile', 'new_mobile', l.after ->> 'mobile',
           'blocks', l.created_at > now() - interval '30 days' and l.user_id is not null and coalesce(r.name, '-') <> 'director')
         order by l.created_at), '[]'::jsonb)
  from public.audit_logs l
  left join public.users u on u.id = l.user_id
  left join public.roles r on r.id = u.role_id
  where l.entity_type = 'students' and l.entity_id = p_student and l.action = 'update'
    and (public.ddd_dup_name_key(l.before ->> 'full_name') is distinct from public.ddd_dup_name_key(l.after ->> 'full_name')
         or public.ddd_dup_mobile_key(l.before ->> 'mobile') is distinct from public.ddd_dup_mobile_key(l.after ->> 'mobile'));
$$;

-- ---------------------------------------------------------------------
-- STEP 4. plan = duplicate hatane par har bill / payment ka kya hoga (kuch nahi badalta).
--   code DDN01 = duplicate nahi, DDB01 = bed par hai, DDC01 = apne aap nahi ho sakta,
--   DDX01 = record nahi mila, DONE = pehle hi isi original mein merge ho chuka
-- ---------------------------------------------------------------------
create or replace function public.ddd_dup_plan(p_dup uuid, p_original uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  d          public.students%rowtype;
  o          public.students%rowtype;
  r          record;
  v_detail   text;
  v_probs    text[] := '{}';
  v_months   jsonb := '[]'::jsonb;
  v_act      text;
  v_note     text;
  v_lbl      text;
  v_same_h   boolean;
  v_open     boolean;
  v_bed      text;
  v_o_money  boolean;
  v_n_money  boolean;
  v_money    boolean := false;
  v_id_d     jsonb;
  v_id_o     jsonb;
  v_blk      text;
  n_move_due int := 0;
  a_move_due numeric := 0;
  a_move_dpd numeric := 0;
  n_move_pay int := 0;
  a_move_pay numeric := 0;
  n_void     int := 0;
  a_void     numeric := 0;
  n_pay      int;
  a_pay      numeric;
  n_nodue    int;
  a_nodue    numeric;
  n_x        int;
  v_fee_low  text[] := '{}';
begin
  d := (select s from public.students s where s.id = p_dup);
  o := (select s from public.students s where s.id = p_original);
  if d.id is null or o.id is null then
    return jsonb_build_object('ok', false, 'rule_ok', false, 'code', 'DDX01',
                              'reason', 'Record nahi mila. Page refresh karein.', 'dup_id', p_dup, 'original_id', p_original);
  end if;

  -- pehle hi isi original mein merge ho chuka (dobara bheja gaya)
  if d.merged_into is not null then
    return jsonb_build_object('ok', false, 'rule_ok', true,
      'code', case when d.merged_into = o.id then 'DONE' else 'DDC01' end,
      'reason', case when d.merged_into = o.id then 'Yeh duplicate pehle hi is original mein merge ho chuka hai.'
                     else 'Yeh record pehle hi kisi aur record mein merge ho chuka hai. Fee, dues aur ginti par iska koi asar nahi.' end,
      'problems', jsonb_build_array('merged record'), 'dup_id', d.id, 'original_id', o.id);
  end if;

  -- 1. duplicate ka rule
  if d.id = o.id then
    v_detail := 'Duplicate aur original ek hi record hain';
  elsif lower(btrim(coalesce(o.status, ''))) <> 'active' then
    v_detail := 'Original record Active nahi hai (' || coalesce(o.status, 'khali') || ')';
  elsif o.merged_into is not null then
    v_detail := 'Original record khud kisi aur mein merge ho chuka hai';
  elsif public.ddd_dup_name_key(d.full_name) is null
        or public.ddd_dup_name_key(d.full_name) is distinct from public.ddd_dup_name_key(o.full_name) then
    v_detail := 'Naam alag hai';
  elsif public.ddd_dup_mobile_key(d.mobile) is null or public.ddd_dup_mobile_key(o.mobile) is null then
    v_detail := 'Student ka mobile khali hai, 10 digit ka nahi hai ya dummy number hai';
  elsif public.ddd_dup_mobile_key(d.mobile) <> public.ddd_dup_mobile_key(o.mobile) then
    v_detail := 'Mobile number alag hai';
  end if;
  if v_detail is not null then
    return jsonb_build_object('ok', false, 'rule_ok', false, 'code', 'DDN01',
                              'reason', 'This record is not a duplicate, deletion not allowed.',
                              'detail', v_detail, 'dup_id', d.id, 'original_id', o.id);
  end if;
  v_same_h := d.hostel_id is not distinct from o.hostel_id;

  -- 2. alag hostel aur duplicate Active nahi = hostel transfer (purane hostel ki history)
  if not v_same_h and lower(btrim(coalesce(d.status, ''))) <> 'active' then
    return jsonb_build_object('ok', false, 'rule_ok', true, 'code', 'DDC01',
      'reason', 'Dono record alag hostel mein hain aur yeh record Active nahi hai. Yeh hostel transfer lagta hai (purane hostel ka record history hai), isliye delete nahi hoga.',
      'problems', jsonb_build_array('transfer: alag hostel + Left'), 'dup_id', d.id, 'original_id', o.id, 'same_hostel', v_same_h);
  end if;

  -- 3. naam / mobile haal hi mein badla (Director ke alawa) = galat record ko duplicate banane ka shak (M6)
  v_id_d := public.ddd_dup_identity(d.id);
  v_id_o := public.ddd_dup_identity(o.id);
  v_blk := (select string_agg(coalesce(x.who, '') || ' - ' || to_char((x.e ->> 'at')::timestamptz at time zone 'Asia/Kolkata', 'DD-MM-YYYY')
                              || ' (' || coalesce(x.e ->> 'by_name', '?') || ': ' || coalesce(x.e ->> 'old_name', '-') || ' / '
                              || coalesce(x.e ->> 'old_mobile', '-') || ' se ' || coalesce(x.e ->> 'new_name', '-') || ' / '
                              || coalesce(x.e ->> 'new_mobile', '-') || ')', ' | ')
              from (select 'hatane wala record' as who, e from jsonb_array_elements(v_id_d) e
                    union all
                    select 'original record', e from jsonb_array_elements(v_id_o) e) x
             where (x.e ->> 'blocks')::boolean);
  if v_blk is not null then
    return jsonb_build_object('ok', false, 'rule_ok', true, 'code', 'DDC01',
      'reason', 'Naam / mobile pichhle 30 din mein badla gaya hai, isliye Delete Duplicate abhi band hai (galat record na hat jaye). Director khud dekhein: ' || v_blk,
      'problems', jsonb_build_array('identity changed: ' || v_blk), 'dup_id', d.id, 'original_id', o.id, 'same_hostel', v_same_h,
      'identity_dup', v_id_d, 'identity_original', v_id_o);
  end if;

  -- 4. duplicate abhi bed par = pehle bed khali karein / original ko dein
  v_bed := (select coalesce('Room ' || rm.room_number, 'Room ?') || ' Bed ' || coalesce(b.bed_number::text, '?')
              from public.beds b left join public.rooms rm on rm.id = b.room_id
             where b.student_id = d.id order by b.id limit 1);
  if v_bed is not null then
    return jsonb_build_object('ok', false, 'rule_ok', true, 'code', 'DDB01',
      'reason', 'Duplicate record abhi ' || v_bed || ' par hai. Pehle Bed Allocation mein yeh bed khali karein (ya original ko dein), phir delete karein.',
      'problems', jsonb_build_array('bed: ' || v_bed), 'dup_id', d.id, 'original_id', o.id, 'same_hostel', v_same_h);
  end if;

  -- 5. har bill (mahina) ka faisla - 026 cleanup D2 ke rule
  for r in
    select dd.id, dd.month, date_trunc('month', dd.month)::date as m,
           dd.fee_amount, coalesce(dd.discount, 0) as disc, coalesce(dd.paid_amount, 0) as paid,
           dd.fee_amount - coalesce(dd.discount, 0) as payable,
           dd.fee_amount - coalesce(dd.discount, 0) - coalesce(dd.paid_amount, 0) as pend,
           coalesce(dd.status, 'pending') as status,
           (select count(*) from public.fee_payments f where f.due_id = dd.id)::int as npay,
           (select coalesce(sum(f.amount), 0) from public.fee_payments f where f.due_id = dd.id) as payamt,
           (select coalesce(sum(f.discount_amount), 0) from public.fee_payments f where f.due_id = dd.id) as paydisc,
           (select count(*) from public.fee_payments f where f.due_id = dd.id and f.student_id is distinct from d.id)::int as nforeign,
           (select count(*) from public.monthly_dues x where x.student_id = o.id
                and date_trunc('month', x.month) = date_trunc('month', dd.month))::int as n_cnt,
           (select l.action from public.ddd_dues_void_log l
             where l.due_id = dd.id and l.action in ('void', 'prorate', 'restore') order by l.id desc limit 1) as last_exit,
           nd.id as n_id, nd.month as n_month, coalesce(nd.status, 'pending') as n_status,
           case when nd.id is not null then coalesce(nd.paid_amount, 0) end as n_paid,
           nd.fee_amount - coalesce(nd.discount, 0) as n_payable,
           nd.fee_amount - coalesce(nd.discount, 0) - coalesce(nd.paid_amount, 0) as n_pend,
           (select count(*) from public.fee_payments f where f.due_id = nd.id)::int as n_npay
    from public.monthly_dues dd
    left join lateral (select x.* from public.monthly_dues x
                        where x.student_id = o.id and date_trunc('month', x.month) = date_trunc('month', dd.month)
                        order by x.month, x.id limit 1) nd on true
    where dd.student_id = d.id
    order by dd.month, dd.id
  loop
    v_lbl := to_char(r.m, 'Mon YYYY');
    v_o_money := r.paid <> 0 or r.npay > 0;
    v_n_money := r.n_id is not null and (r.n_paid <> 0 or r.n_npay > 0);
    v_open := coalesce(r.last_exit in ('void', 'prorate'), false);
    if v_o_money then v_money := true; end if;

    if r.month <> r.m then
      v_act := 'CONFLICT'; v_note := 'duplicate ka bill mahine ki 1 tareekh ka nahi';
    elsif r.n_cnt > 1 or (r.n_id is not null and r.n_month <> r.m) then
      v_act := 'CONFLICT'; v_note := 'original par is mahine ke bill theek nahi (1 tareekh ka nahi ya ek se zyada)';
    elsif r.nforeign > 0 then
      v_act := 'CONFLICT'; v_note := 'is bill par kisi aur student ki payment judi hai';
    elsif r.status = 'void' then
      if v_o_money then
        v_act := 'CONFLICT'; v_note := 'void bill par paise jama hain';
      else
        v_act := 'LEAVE_VOID'; v_note := 'pehle se void bill, waisa hi rahega';
      end if;
    elsif r.n_id is null then
      if not v_o_money and r.payable <= 0 then
        v_act := 'VOID_OLD'; v_note := 'Rs 0 ka bill, void hoga';
      elsif not v_same_h then
        v_act := 'CONFLICT'; v_note := 'dono record alag hostel mein hain, bill shift nahi ho sakta';
      elsif o.exit_date is not null and r.m > o.exit_date then
        v_act := 'CONFLICT'; v_note := 'original ki exit date ke baad ka mahina';
      elsif v_open then
        v_act := 'CONFLICT'; v_note := 'bill exit rule (026) se kata / void hua hai, apne aap shift nahi hoga';
      else
        v_act := 'MOVE_DUE';
        v_note := 'original par is mahine ka bill nahi, poora bill' ||
                  case when r.npay > 0 then ' ' || r.npay || ' payment ke saath' else ' (bina payment)' end || ' original par jayega';
        if o.joining_date is not null and r.m < date_trunc('month', o.joining_date)::date then
          v_note := v_note || ' | original ki joining ' || to_char(o.joining_date, 'DD-MM-YYYY') || ' se pehle ka mahina';
        end if;
      end if;
    elsif v_o_money and v_n_money then
      v_act := 'CONFLICT'; v_note := 'dono record par is mahine ke paise jama hain (double payment?), pehle Director ek payment theek karein';
    elsif not v_o_money then
      v_act := 'VOID_OLD'; v_note := 'original par is mahine ka apna bill hai, duplicate ka bill void hoga';
      if r.payable > r.n_payable then
        v_note := v_note || ' | original ka bill ' || public.ddd_dup_rs(r.payable - r.n_payable) || ' kam hai';
        v_fee_low := v_fee_low || (v_lbl || ': duplicate ka bill ' || public.ddd_dup_rs(r.payable) || ' void hoga, original ka bill sirf '
                                   || public.ddd_dup_rs(r.n_payable));
      end if;
    elsif r.n_status = 'void' then
      v_act := 'CONFLICT'; v_note := 'original ka is mahine ka bill void hai';
    elsif not v_same_h then
      v_act := 'CONFLICT'; v_note := 'dono record alag hostel mein hain, payment shift nahi ho sakti';
    elsif r.disc <> 0 or r.paydisc <> 0 then
      v_act := 'CONFLICT'; v_note := 'duplicate ke bill par discount hai, apne aap shift nahi hoga';
    elsif r.paid <> r.payamt then
      v_act := 'CONFLICT'; v_note := 'duplicate ke bill ka jama aur payments ka jod alag hai';
    elsif r.n_pend < r.paid then
      v_act := 'CONFLICT'; v_note := 'original ke bill mein sirf ' || public.ddd_dup_rs(r.n_pend) || ' baaki hai, duplicate par ' || public.ddd_dup_rs(r.paid) || ' jama hai';
    else
      v_act := 'MOVE_PAY';
      v_note := r.npay || ' payment (' || public.ddd_dup_rs(r.paid) || ') original ke isi mahine ke bill par judegi, duplicate ka bill void';
    end if;

    if v_act = 'CONFLICT' then
      v_probs := v_probs || (v_lbl || ': ' || v_note);
    elsif v_act = 'MOVE_DUE' then
      n_move_due := n_move_due + 1; a_move_due := a_move_due + r.payable; a_move_dpd := a_move_dpd + r.pend;
    elsif v_act = 'MOVE_PAY' then
      n_move_pay := n_move_pay + 1; a_move_pay := a_move_pay + r.paid; n_void := n_void + 1;
    elsif v_act = 'VOID_OLD' then
      n_void := n_void + 1; a_void := a_void + greatest(r.pend, 0);
    end if;

    v_months := v_months || jsonb_build_object(
      'month', r.m, 'label', v_lbl, 'act', v_act, 'note', v_note,
      'dup_due_id', r.id, 'dup_bill', r.payable, 'dup_discount', r.disc, 'dup_paid', r.paid, 'dup_pending', r.pend,
      'dup_status', r.status, 'dup_payments', r.npay,
      'orig_due_id', r.n_id, 'orig_bill', r.n_payable, 'orig_paid', r.n_paid, 'orig_pending', r.n_pend,
      'orig_status', case when r.n_id is not null then r.n_status end);
  end loop;

  -- 6. payments (duplicate ki saari payment rows)
  n_pay := (select count(*) from public.fee_payments f
             where f.student_id = d.id or f.due_id in (select x.id from public.monthly_dues x where x.student_id = d.id));
  a_pay := (select coalesce(sum(f.amount), 0) from public.fee_payments f
             where f.student_id = d.id or f.due_id in (select x.id from public.monthly_dues x where x.student_id = d.id));
  if n_pay > 0 then v_money := true; end if;
  n_nodue := (select count(*) from public.fee_payments f where f.student_id = d.id and f.due_id is null);
  a_nodue := (select coalesce(sum(f.amount), 0) from public.fee_payments f where f.student_id = d.id and f.due_id is null);
  if n_nodue > 0 and not v_same_h then
    v_probs := v_probs || ('bina bill ki ' || n_nodue || ' payment: dono record alag hostel mein hain');
  end if;
  n_x := (select count(*) from public.fee_payments f
           where f.student_id = d.id and f.due_id is not null
             and not exists (select 1 from public.monthly_dues x where x.id = f.due_id and x.student_id = d.id));
  if n_x > 0 then
    v_probs := v_probs || (n_x || ' payment duplicate ki hai par kisi aur ke bill par judi hai');
  end if;
  n_x := (select count(*) from public.fee_payments g
           where g.advance_group_id in (select f.advance_group_id from public.fee_payments f
                                         where f.advance_group_id is not null
                                           and (f.student_id = d.id or f.due_id in (select x.id from public.monthly_dues x where x.student_id = d.id)))
             and g.student_id is distinct from d.id);
  if n_x > 0 then
    v_probs := v_probs || ('advance payment ka group kisi aur student ke saath bhi hai (' || n_x || ' row)');
  end if;

  -- 7. fee kam ho rahi hai? (warden ne kam fee wala naya record banaya ho to) = alag se haan chahiye (DDF01)
  if coalesce(d.monthly_fee, 0) > coalesce(o.monthly_fee, 0) then
    v_fee_low := array['Duplicate ki Monthly Fee ' || public.ddd_dup_rs(d.monthly_fee) || ', original ki sirf ' || public.ddd_dup_rs(o.monthly_fee)
                       || ' - delete ke baad original wali (kam) fee hi lagegi'] || v_fee_low;
  end if;

  return jsonb_build_object(
    'ok', cardinality(v_probs) = 0, 'rule_ok', true,
    'fee_drop', cardinality(v_fee_low) > 0, 'fee_drop_note', array_to_string(v_fee_low, ' | '),
    'code', case when cardinality(v_probs) > 0 then 'DDC01' end,
    'reason', case when cardinality(v_probs) > 0
                   then 'Duplicate apne aap delete nahi ho sakta, kuch nahi badla: ' || array_to_string(v_probs, ' | ') end,
    'problems', to_jsonb(v_probs),
    'dup_id', d.id, 'original_id', o.id, 'same_hostel', v_same_h,
    'father_differs', (nullif(btrim(coalesce(d.father_name, '')), '') is not null and nullif(btrim(coalesce(o.father_name, '')), '') is not null
                       and public.ddd_dup_name_key(d.father_name) is distinct from public.ddd_dup_name_key(o.father_name)),
    'identity_dup', v_id_d, 'identity_original', v_id_o,
    'needs_move', v_money,
    'payments', n_pay, 'payments_amount', a_pay,
    'move_bills', n_move_due, 'move_bills_amount', a_move_due, 'move_bills_pending', a_move_dpd,
    'move_payment_months', n_move_pay, 'move_payment_amount', a_move_pay,
    'nodue_payments', n_nodue, 'nodue_amount', a_nodue,
    'void_bills', n_void, 'void_pending', a_void,
    'months', v_months);
end
$fn$;

-- ---------------------------------------------------------------------
-- STEP 5. side by side screen
--   pehli line side = duplicate (jo record hatana hai), baaki side = original
--   0 line = koi ACTIVE original nahi = duplicate nahi
-- ---------------------------------------------------------------------
create or replace function public.ddd_duplicate_candidates(p_student uuid)
returns table (
  side text, id uuid, full_name text, father_name text, mobile text,
  hostel_id uuid, hostel_code text, hostel_name text, status text, occupant_type text,
  joining_date date, exit_date date, monthly_fee numeric, bed text,
  created_at timestamptz, created_by_name text,
  dues_count int, dues_billed numeric, dues_paid numeric, dues_pending numeric, dues jsonb,
  payments_count int, payments_amount numeric, last_payment_date date, payments jsonb,
  can_delete boolean, needs_move boolean, block_code text, block_reason text, plan jsonb)
language plpgsql stable security definer set search_path = public as $fn$
#variable_conflict use_column
declare
  d      public.students%rowtype;
  v_name text;
  v_mob  text;
begin
  if not (public.ddd_can('duplicate_delete') or public.ddd_is_trusted_session()) then
    raise exception 'Duplicate delete sirf Director ya Manager kar sakte hain.' using errcode = '42501';
  end if;
  if p_student is null then
    raise exception 'Student chunein.' using errcode = '22023';
  end if;
  d := (select s from public.students s where s.id = p_student);
  if d.id is null then
    raise exception 'Student nahi mila. Page refresh karein.' using errcode = 'P0002';
  end if;
  v_name := public.ddd_dup_name_key(d.full_name);
  v_mob  := public.ddd_dup_mobile_key(d.mobile);
  if v_name is null or v_mob is null or d.merged_into is not null then
    return;
  end if;

  return query
  with orig as (
    select s.id
    from public.students s
    where s.id <> d.id
      and lower(btrim(coalesce(s.status, ''))) = 'active'
      and s.merged_into is null
      and public.ddd_dup_name_key(s.full_name) = v_name
      and public.ddd_dup_mobile_key(s.mobile) = v_mob
  ), rows_ as (
    select 0 as ord, 'duplicate'::text as side, d.id as sid, null::jsonb as plan
    where exists (select 1 from orig)
    union all
    select 1, 'original', orig.id, public.ddd_dup_plan(d.id, orig.id) from orig
  )
  select x.side, s.id, s.full_name, s.father_name, s.mobile,
         s.hostel_id, h.code, h.name, s.status, coalesce(to_jsonb(s) ->> 'occupant_type', 'student'),
         s.joining_date, s.exit_date, s.monthly_fee, bd.bed,
         s.created_at, cu.full_name,
         coalesce(du.n, 0), coalesce(du.billed, 0), coalesce(du.paid, 0), coalesce(du.pend, 0), coalesce(du.list, '[]'::jsonb),
         coalesce(py.n, 0), coalesce(py.amt, 0), py.last_date, coalesce(py.list, '[]'::jsonb),
         case when x.side = 'original' then coalesce((x.plan ->> 'ok')::boolean, false) end,
         case when x.side = 'original' then coalesce((x.plan ->> 'needs_move')::boolean, false) end,
         case when x.side = 'original' then x.plan ->> 'code' end,
         case when x.side = 'original' then x.plan ->> 'reason' end,
         case when x.side = 'original' then x.plan else jsonb_build_object('identity', public.ddd_dup_identity(s.id)) end
  from rows_ x
  join public.students s on s.id = x.sid
  left join public.hostels h on h.id = s.hostel_id
  left join public.users cu on cu.id = s.created_by
  left join lateral (
    select coalesce('Room ' || rm.room_number, 'Room ?') || ' Bed ' || coalesce(b.bed_number::text, '?') as bed
    from public.beds b left join public.rooms rm on rm.id = b.room_id
    where b.student_id = s.id order by b.id limit 1) bd on true
  left join lateral (
    select count(*)::int as n,
           sum(case when coalesce(m.status, '') <> 'void' then m.fee_amount - coalesce(m.discount, 0) else 0 end) as billed,
           sum(coalesce(m.paid_amount, 0)) as paid,
           sum(case when coalesce(m.status, '') <> 'void' then greatest(m.fee_amount - coalesce(m.discount, 0) - coalesce(m.paid_amount, 0), 0) else 0 end) as pend,
           jsonb_agg(jsonb_build_object('month', m.month, 'label', to_char(m.month, 'Mon YYYY'),
                                        'bill', m.fee_amount - coalesce(m.discount, 0), 'paid', coalesce(m.paid_amount, 0),
                                        'pending', m.fee_amount - coalesce(m.discount, 0) - coalesce(m.paid_amount, 0),
                                        'status', m.status) order by m.month) as list
    from public.monthly_dues m where m.student_id = s.id) du on true
  left join lateral (
    select count(*)::int as n, sum(f.amount) as amt, max(f.payment_date) as last_date,
           jsonb_agg(jsonb_build_object('date', f.payment_date, 'amount', f.amount, 'receipt', f.receipt_number,
                                        'mode', f.mode, 'month', (select m2.month from public.monthly_dues m2 where m2.id = f.due_id))
                     order by f.payment_date, f.created_at) as list
    from public.fee_payments f where f.student_id = s.id) py on true
  order by x.ord, s.created_at, s.id;
end
$fn$;

-- ---------------------------------------------------------------------
-- STEP 6. Delete Duplicate (soft delete)
--   error codes (app inhe pakde) - 42501 permission nahi, DDN01 duplicate nahi (owner wala message),
--   DDP01 paise hain (payment_shift true ke saath dobara), DDC01 apne aap nahi ho sakta (detail mein wajah),
--   DDB01 duplicate bed par, P0002 record nahi mila. Kuch bhi fail = poora rollback.
-- ---------------------------------------------------------------------
create or replace function public.ddd_delete_duplicate(p_dup uuid, p_original uuid, p_move_payments boolean default false,
                                                       p_confirm_fee boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = public as $fn$
declare
  v_uid       uuid := auth.uid();
  v_today     date := (now() at time zone 'Asia/Kolkata')::date;
  v_plan      jsonb;
  d           public.students%rowtype;
  o           public.students%rowtype;
  m           jsonb;
  p           record;
  v_n         int;
  v_cnt       int;
  v_amt       numeric;
  v_rows      jsonb;
  v_moved_pay jsonb := '[]'::jsonb;
  v_moved_due jsonb := '[]'::jsonb;
  v_orig_bef  jsonb := '[]'::jsonb;
  v_voided    jsonb := '[]'::jsonb;
  n_moved_due int := 0;
  n_moved_pay int := 0;
  a_moved     numeric := 0;
  n_void      int := 0;
  a_void      numeric := 0;
  v_cmp       jsonb;
  v_bal       jsonb;
  v_att       jsonb;
  v_att_left  int;
  v_mrg       jsonb;
  v_ce        int;
  v_by_name   text;
  v_log_id    uuid;
  v_pay_tot_b numeric;
  v_pay_tot_a numeric;
  v_dues_bef  jsonb;
  v_pays_bef  jsonb;
  v_batch     text := 'delete_duplicate';
begin
  if not (public.ddd_can('duplicate_delete') or public.ddd_is_trusted_session()) then
    raise exception 'Duplicate delete sirf Director ya Manager kar sakte hain.' using errcode = '42501';
  end if;
  if p_dup is null or p_original is null then
    raise exception 'Duplicate aur original dono record chunein.' using errcode = '22023';
  end if;

  -- dono record lock (id order = deadlock nahi)
  perform 1 from public.students s where s.id in (p_dup, p_original) order by s.id for update;
  d := (select s from public.students s where s.id = p_dup);
  if d.id is null then
    raise exception 'Duplicate record nahi mila. Page refresh karein.' using errcode = 'P0002';
  end if;
  -- phone ne dobara bheja (pehli baar ho chuka) = wahi result
  if d.merged_into = p_original then
    v_log_id := (select l.id from public.duplicate_deletion_log l
                  where l.deleted_student_id = p_dup and l.original_student_id = p_original
                  order by l.deleted_at desc limit 1);
    if v_log_id is not null then
      return jsonb_build_object('ok', true, 'already_deleted', true, 'log_id', v_log_id,
                                'deleted_student_id', p_dup, 'original_student_id', p_original,
                                'message', 'Yeh duplicate pehle hi hata diya gaya hai.');
    end if;
  end if;
  o := (select s from public.students s where s.id = p_original);
  if o.id is null then
    raise exception 'This record is not a duplicate, deletion not allowed.' using errcode = 'DDN01', detail = 'Original record nahi mila';
  end if;

  -- bills aur payments lock (beech mein koi fee receive na kare)
  perform 1 from public.monthly_dues x where x.student_id in (p_dup, p_original) order by x.id for update;
  perform 1 from public.fee_payments f
   where f.student_id = p_dup or f.due_id in (select x.id from public.monthly_dues x where x.student_id = p_dup)
   order by f.id for update;

  v_plan := public.ddd_dup_plan(p_dup, p_original);
  if v_plan ->> 'code' = 'DDN01' then
    raise exception 'This record is not a duplicate, deletion not allowed.' using errcode = 'DDN01',
      detail = coalesce(v_plan ->> 'detail', '');
  end if;
  if not coalesce((v_plan ->> 'ok')::boolean, false) then
    raise exception '%', coalesce(v_plan ->> 'reason', 'Duplicate delete nahi ho sakta.')
      using errcode = case when v_plan ->> 'code' in ('DDB01', 'DDC01', 'DDX01') then v_plan ->> 'code' else 'DDC01' end,
            detail = coalesce((v_plan -> 'problems')::text, '');
  end if;
  if coalesce((v_plan ->> 'needs_move')::boolean, false) and not coalesce(p_move_payments, false) then
    raise exception '%',
      case when coalesce((v_plan ->> 'payments')::int, 0) > 0
           then 'Is duplicate record par ' || (v_plan ->> 'payments') || ' payment ('
                || public.ddd_dup_rs((v_plan ->> 'payments_amount')::numeric)
                || ') jama hain. Delete se pehle inhe original record par shift karna hoga.'
           else 'Is duplicate record ke bills par jama paise dikh rahe hain. Delete se pehle unhe original record par shift karna hoga.' end
      using errcode = 'DDP01',
            detail = jsonb_build_object('payments', v_plan -> 'payments', 'payments_amount', v_plan -> 'payments_amount',
                                        'move_bills', v_plan -> 'move_bills', 'move_payment_months', v_plan -> 'move_payment_months')::text,
            hint = 'Shift karke delete: ddd_delete_duplicate(duplicate, original, true)';
  end if;
  if coalesce((v_plan ->> 'fee_drop')::boolean, false) and not coalesce(p_confirm_fee, false) then
    raise exception '%', 'Dhyan dein, fee kam ho rahi hai: ' || coalesce(v_plan ->> 'fee_drop_note', '')
                         || '. Pakka ho to fee wali warning par haan karke dobara delete karein.'
      using errcode = 'DDF01',
            detail = coalesce(v_plan ->> 'fee_drop_note', ''),
            hint = 'Haan ke saath: ddd_delete_duplicate(duplicate, original, payment_shift, true)';
  end if;

  -- pehle wali copy (log ke liye)
  v_dues_bef := (select coalesce(jsonb_agg(to_jsonb(x) order by x.month, x.id), '[]'::jsonb)
                   from public.monthly_dues x where x.student_id = p_dup);
  v_pays_bef := (select coalesce(jsonb_agg(to_jsonb(f) order by f.payment_date, f.id), '[]'::jsonb)
                   from public.fee_payments f
                  where f.student_id = p_dup or f.due_id in (select x.id from public.monthly_dues x where x.student_id = p_dup));
  v_pay_tot_b := (select coalesce(sum(f.amount), 0) from public.fee_payments f
                   where f.student_id in (p_dup, p_original)
                      or f.due_id in (select x.id from public.monthly_dues x where x.student_id in (p_dup, p_original)));

  perform set_config('ddd.batch', v_batch, true);
  perform set_config('ddd.reason', 'Delete Duplicate (' || coalesce(btrim(d.full_name), '') || ')', true);

  -- 1. bills / payments (plan ke hisaab se, har step ki row count check)
  for m in select e from jsonb_array_elements(v_plan -> 'months') e loop
    if m ->> 'act' = 'MOVE_DUE' then
      update public.monthly_dues set student_id = p_original
       where id = (m ->> 'dup_due_id')::uuid and student_id = p_dup;
      get diagnostics v_n = row_count;
      if v_n <> 1 then
        raise exception 'Duplicate delete ruka: % ka bill shift nahi hua (record badal gaya). Kuch nahi badla, dobara try karein.', m ->> 'label'
          using errcode = 'DDC01';
      end if;
      v_rows := (select coalesce(jsonb_agg(jsonb_build_object('payment_id', f.id, 'amount', f.amount, 'receipt', f.receipt_number,
                                                             'date', f.payment_date, 'how', 'with_bill',
                                                             'old_due_id', f.due_id, 'new_due_id', f.due_id)), '[]'::jsonb)
                   from public.fee_payments f where f.due_id = (m ->> 'dup_due_id')::uuid);
      v_amt := (select coalesce(sum(f.amount), 0) from public.fee_payments f where f.due_id = (m ->> 'dup_due_id')::uuid);
      update public.fee_payments set student_id = p_original where due_id = (m ->> 'dup_due_id')::uuid;
      get diagnostics v_cnt = row_count;
      insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to,
                                           new_fee_amount, new_period_to, amount_note, reason, batch)
      values ((m ->> 'dup_due_id')::uuid, p_original, (m ->> 'month')::date, 'move', (m ->> 'dup_bill')::numeric + (m ->> 'dup_discount')::numeric,
              (m ->> 'dup_discount')::numeric, m ->> 'dup_status', null, (m ->> 'dup_bill')::numeric + (m ->> 'dup_discount')::numeric, null,
              (m ->> 'dup_bill')::numeric,
              'Delete Duplicate: bill duplicate record ' || coalesce(btrim(d.full_name), '') || ' (' || p_dup || ') se original par, '
              || v_cnt || ' payment saath mein', v_batch);
      n_moved_due := n_moved_due + 1;
      n_moved_pay := n_moved_pay + v_cnt;
      a_moved := a_moved + v_amt;
      v_moved_pay := v_moved_pay || v_rows;
      v_moved_due := v_moved_due || jsonb_build_object('due_id', m ->> 'dup_due_id', 'month', m ->> 'month',
                                                       'bill', m -> 'dup_bill', 'paid', m -> 'dup_paid', 'payments', v_cnt);

    elsif m ->> 'act' = 'MOVE_PAY' then
      v_orig_bef := v_orig_bef || (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb)
                                     from public.monthly_dues x where x.id = (m ->> 'orig_due_id')::uuid);
      v_rows := (select coalesce(jsonb_agg(jsonb_build_object('payment_id', f.id, 'amount', f.amount, 'receipt', f.receipt_number,
                                                             'date', f.payment_date, 'how', 'to_original_bill',
                                                             'old_due_id', f.due_id, 'new_due_id', (m ->> 'orig_due_id')::uuid)), '[]'::jsonb)
                   from public.fee_payments f where f.due_id = (m ->> 'dup_due_id')::uuid);
      v_amt := (select coalesce(sum(f.amount), 0) from public.fee_payments f where f.due_id = (m ->> 'dup_due_id')::uuid);
      update public.fee_payments set due_id = (m ->> 'orig_due_id')::uuid, student_id = p_original
       where due_id = (m ->> 'dup_due_id')::uuid;
      get diagnostics v_cnt = row_count;
      if v_cnt <> (m ->> 'dup_payments')::int or v_amt <> (m ->> 'dup_paid')::numeric then
        raise exception 'Duplicate delete ruka: % ki payments badal gayi. Kuch nahi badla, dobara try karein.', m ->> 'label'
          using errcode = 'DDC01';
      end if;
      update public.monthly_dues
         set paid_amount = coalesce(paid_amount, 0) + v_amt,
             status = case when fee_amount - coalesce(discount, 0) - (coalesce(paid_amount, 0) + v_amt) <= 0 then 'paid' else 'partial' end
       where id = (m ->> 'orig_due_id')::uuid and student_id = p_original
         and coalesce(paid_amount, 0) = (m ->> 'orig_paid')::numeric;
      get diagnostics v_n = row_count;
      if v_n <> 1 then
        raise exception 'Duplicate delete ruka: original ka % ka bill badal gaya. Kuch nahi badla, dobara try karein.', m ->> 'label'
          using errcode = 'DDC01';
      end if;
      update public.monthly_dues set paid_amount = coalesce(paid_amount, 0) - v_amt, fee_amount = 0, discount = 0, status = 'void'
       where id = (m ->> 'dup_due_id')::uuid and student_id = p_dup and coalesce(paid_amount, 0) = v_amt;
      get diagnostics v_n = row_count;
      if v_n <> 1 then
        raise exception 'Duplicate delete ruka: duplicate ka % ka bill badal gaya. Kuch nahi badla, dobara try karein.', m ->> 'label'
          using errcode = 'DDC01';
      end if;
      insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to,
                                           new_fee_amount, new_period_to, amount_note, reason, batch)
      values ((m ->> 'orig_due_id')::uuid, p_original, (m ->> 'month')::date, 'payment_move', null, null, m ->> 'orig_status', null, null, null, v_amt,
              'Delete Duplicate: duplicate record ' || coalesce(btrim(d.full_name), '') || ' ki ' || v_cnt || ' payment ('
              || public.ddd_dup_rs(v_amt) || ') is bill par shift (bill ' || (m ->> 'dup_due_id') || ' se)', v_batch),
             ((m ->> 'dup_due_id')::uuid, p_dup, (m ->> 'month')::date, 'merge_void', (m ->> 'dup_bill')::numeric + (m ->> 'dup_discount')::numeric,
              (m ->> 'dup_discount')::numeric, m ->> 'dup_status', null, 0, null, (m ->> 'dup_bill')::numeric,
              'Delete Duplicate: duplicate record ka bill void, uski payment ' || public.ddd_dup_rs(v_amt) || ' original ke same mahine ke bill par', v_batch);
      n_moved_pay := n_moved_pay + v_cnt;
      a_moved := a_moved + v_amt;
      n_void := n_void + 1;
      v_moved_pay := v_moved_pay || v_rows;
      v_voided := v_voided || to_jsonb(m ->> 'dup_due_id');

    elsif m ->> 'act' = 'VOID_OLD' then
      update public.monthly_dues set fee_amount = 0, discount = 0, status = 'void'
       where id = (m ->> 'dup_due_id')::uuid and student_id = p_dup and coalesce(paid_amount, 0) = 0
         and not exists (select 1 from public.fee_payments f where f.due_id = (m ->> 'dup_due_id')::uuid);
      get diagnostics v_n = row_count;
      if v_n <> 1 then
        raise exception 'Duplicate delete ruka: duplicate ka % ka bill badal gaya / paise aa gaye. Kuch nahi badla, dobara try karein.', m ->> 'label'
          using errcode = 'DDC01';
      end if;
      insert into public.ddd_dues_void_log(due_id, student_id, month, action, old_fee_amount, old_discount, old_status, old_period_to,
                                           new_fee_amount, new_period_to, amount_note, reason, batch)
      values ((m ->> 'dup_due_id')::uuid, p_dup, (m ->> 'month')::date, 'merge_void', (m ->> 'dup_bill')::numeric + (m ->> 'dup_discount')::numeric,
              (m ->> 'dup_discount')::numeric, m ->> 'dup_status', null, 0, null, (m ->> 'dup_bill')::numeric,
              'Delete Duplicate: duplicate record ka bill void (' || coalesce(m ->> 'note', '') || ')', v_batch);
      n_void := n_void + 1;
      a_void := a_void + greatest((m ->> 'dup_pending')::numeric, 0);
      v_voided := v_voided || to_jsonb(m ->> 'dup_due_id');
    end if;
  end loop;

  -- bina bill ki payments original par
  for p in select f.id, f.amount, f.receipt_number, f.payment_date from public.fee_payments f
            where f.student_id = p_dup and f.due_id is null order by f.payment_date, f.id loop
    update public.fee_payments set student_id = p_original where id = p.id and student_id = p_dup and due_id is null;
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'Duplicate delete ruka: bina bill ki payment badal gayi. Kuch nahi badla, dobara try karein.' using errcode = 'DDC01';
    end if;
    insert into public.ddd_dues_void_log(due_id, student_id, month, action, amount_note, reason, batch)
    values (null, p_original, null, 'payment_move', p.amount,
            'Delete Duplicate: bina bill ki payment ' || coalesce(p.receipt_number, '-') || ' (' || to_char(p.payment_date, 'DD-MM-YYYY')
            || ') duplicate record ' || coalesce(btrim(d.full_name), '') || ' se original par', v_batch);
    n_moved_pay := n_moved_pay + 1;
    a_moved := a_moved + p.amount;
    v_moved_pay := v_moved_pay || jsonb_build_object('payment_id', p.id, 'amount', p.amount, 'receipt', p.receipt_number,
                                                     'date', p.payment_date, 'how', 'no_bill', 'old_due_id', null, 'new_due_id', null);
  end loop;

  -- ab duplicate ya uske bills par koi payment nahi, aur koi chalu (void ke alawa) bill nahi
  if exists (select 1 from public.fee_payments f
              where f.student_id = p_dup or f.due_id in (select x.id from public.monthly_dues x where x.student_id = p_dup)) then
    raise exception 'Duplicate delete ruka: kuch payment shift nahi hui. Kuch nahi badla, developer ko batayein.' using errcode = 'DDC01';
  end if;
  if exists (select 1 from public.monthly_dues x where x.student_id = p_dup and x.status is distinct from 'void') then
    raise exception 'Duplicate delete ruka: duplicate ka koi bill void / shift nahi hua. Kuch nahi badla, developer ko batayein.' using errcode = 'DDC01';
  end if;

  -- 2. baaki judi cheezein original par (wahi insaan hai)
  v_cmp := (select coalesce(jsonb_agg(c.id), '[]'::jsonb) from public.complaints c where c.student_id = p_dup);
  update public.complaints set student_id = p_original where student_id = p_dup;
  v_bal := (select coalesce(jsonb_agg(b.id), '[]'::jsonb) from public.bed_allocations b where b.student_id = p_dup);
  update public.bed_allocations set student_id = p_original where student_id = p_dup;
  v_att := (select coalesce(jsonb_agg(a.id), '[]'::jsonb) from public.student_attendance a
             where a.student_id = p_dup
               and not exists (select 1 from public.student_attendance a2 where a2.student_id = p_original and a2.date is not distinct from a.date));
  update public.student_attendance a set student_id = p_original
   where a.student_id = p_dup
     and not exists (select 1 from public.student_attendance a2 where a2.student_id = p_original and a2.date is not distinct from a.date);
  v_att_left := (select count(*) from public.student_attendance a where a.student_id = p_dup);
  v_mrg := (select coalesce(jsonb_agg(s.id), '[]'::jsonb) from public.students s where s.merged_into = p_dup);
  update public.students set merged_into = p_original where merged_into = p_dup;

  -- 3. soft delete - merged_into = original, Left (exit date khali ho to aaj), bed link khali
  update public.students
     set merged_into = p_original, status = 'left', exit_date = coalesce(exit_date, v_today), current_bed_id = null
   where id = p_dup and merged_into is null;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'Duplicate delete ruka: record badal gaya. Kuch nahi badla, dobara try karein.' using errcode = 'DDC01';
  end if;

  perform public.recompute_paid_till(p_original);
  perform public.recompute_paid_till(p_dup);

  -- total jama same raha?
  v_pay_tot_a := (select coalesce(sum(f.amount), 0) from public.fee_payments f
                   where f.student_id = p_original
                      or f.due_id in (select x.id from public.monthly_dues x where x.student_id = p_original));
  if v_pay_tot_a <> v_pay_tot_b then
    raise exception 'Duplicate delete ruka: jama paise ka jod badal raha tha (% se %). Kuch nahi badla, developer ko batayein.',
      v_pay_tot_b, v_pay_tot_a using errcode = 'DDC01';
  end if;

  -- 4. common expense split dobara (030 lagi ho to) - duplicate ab merged hai isliye nahi gina jayega (R7, M8)
  if to_regproc('public.ddd_cexp_recalc_for_student') is not null then
    begin
      v_ce := public.ddd_cexp_recalc_for_student(p_dup);
    exception when others then
      raise exception 'Duplicate delete ruka: common expense split dobara nahi ban paya (%). Kuch nahi badla.', sqlerrm using errcode = 'DDC01';
    end;
  end if;

  -- 5. log
  v_by_name := case when v_uid is null then 'SQL Editor'
                    else (select coalesce(u.full_name, u.email, v_uid::text) || coalesce(' (' || r.name || ')', '')
                            from public.users u left join public.roles r on r.id = u.role_id where u.id = v_uid) end;
  insert into public.duplicate_deletion_log (
    deleted_student_id, original_student_id, deleted_name, original_name, mobile_key, hostel_id, original_hostel_id,
    deleted_by, deleted_by_name, moved_dues, moved_payments, moved_amount, dropped_dues, dropped_pending, cexp_recalculated, snapshot)
  values (
    d.id, o.id, d.full_name, o.full_name, public.ddd_dup_mobile_key(d.mobile), d.hostel_id, o.hostel_id,
    v_uid, coalesce(v_by_name, v_uid::text), n_moved_due, n_moved_pay, a_moved, n_void, a_void, v_ce,
    jsonb_build_object(
      'version', '031-2',
      'student', to_jsonb(d) - 'photo_url',
      'original', jsonb_build_object('id', o.id, 'full_name', o.full_name, 'father_name', o.father_name, 'mobile', o.mobile,
                                     'hostel_id', o.hostel_id, 'status', o.status, 'joining_date', o.joining_date, 'monthly_fee', o.monthly_fee),
      'plan', v_plan,
      'dues_before', v_dues_bef,
      'payments_before', v_pays_bef,
      'voided_due_ids', v_voided,
      'moved_dues', v_moved_due,
      'moved_payments', v_moved_pay,
      'original_dues_before', v_orig_bef,
      'repointed', jsonb_build_object('complaints', v_cmp, 'bed_allocations', v_bal, 'attendance', v_att,
                                      'attendance_left_on_duplicate', v_att_left, 'merged_children', v_mrg),
      'move_payments_flag', coalesce(p_move_payments, false),
      'fee_drop_confirmed', coalesce((v_plan ->> 'fee_drop')::boolean, false) and coalesce(p_confirm_fee, false)))
  returning id into v_log_id;

  return jsonb_build_object(
    'ok', true, 'log_id', v_log_id,
    'deleted_student_id', d.id, 'deleted_name', d.full_name,
    'original_student_id', o.id, 'original_name', o.full_name,
    'moved_dues', n_moved_due, 'moved_payments', n_moved_pay, 'moved_amount', a_moved,
    'dropped_dues', n_void, 'dropped_pending', a_void,
    'cexp_recalculated', v_ce,
    'repointed', jsonb_build_object('complaints', jsonb_array_length(v_cmp), 'bed_allocations', jsonb_array_length(v_bal),
                                    'attendance', jsonb_array_length(v_att), 'merged_children', jsonb_array_length(v_mrg)),
    'message', 'Duplicate ' || coalesce(btrim(regexp_replace(d.full_name, '\s+', ' ', 'g')), '') || ' hata diya gaya (original mein merge). ' ||
               n_moved_due || ' bill aur ' || n_moved_pay || ' payment (' || public.ddd_dup_rs(a_moved) || ') original par shift. ' ||
               n_void || ' duplicate bill void.' ||
               case when v_ce is not null then ' ' || v_ce || ' common expense dobara bane.' else '' end);
end
$fn$;

-- ---------------------------------------------------------------------
-- STEP 6b. merged_into app (API) se seedha - sirf asli Director (026 jaisa, live par aaj bhi).
--   Manager ke liye nahi (027 ke baad is_director Manager ko bhi haan kehta hai), warna
--   bina check, bina log, bina paise ke hisaab ke record chhup jaata. Manager ke liye merge
--   sirf Delete Duplicate (upar) se. SQL Editor aur owner functions par asar nahi.
--   Warden ke liye 026 ka purana message pehle aata hai (Merge sirf Director kar sakta hai).
-- ---------------------------------------------------------------------
create or replace function public.ddd_guard_students_merge() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.ddd_is_api_caller()
     and new.merged_into is distinct from (case when tg_op = 'UPDATE' then old.merged_into end)
     and not public.is_real_director() then
    raise exception 'Merge app se seedha nahi hota. Duplicate record ho to Profile mein Delete Duplicate use karein.'
      using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists trg_students_merge_guard on public.students;
create trigger trg_students_merge_guard before insert or update of merged_into on public.students
  for each row execute function public.ddd_guard_students_merge();

-- ---------------------------------------------------------------------
-- STEP 7. rights
-- ---------------------------------------------------------------------
revoke all on public.duplicate_deletion_log from public, anon, authenticated, service_role;
grant select on public.duplicate_deletion_log to authenticated, service_role;

revoke all on function public.ddd_dup_name_key(text) from public, anon, authenticated;
revoke all on function public.ddd_dup_mobile_key(text) from public, anon, authenticated;
revoke all on function public.ddd_dup_rs(numeric) from public, anon, authenticated;
revoke all on function public.ddd_dup_identity(uuid) from public, anon, authenticated;
revoke all on function public.ddd_dup_plan(uuid, uuid) from public, anon, authenticated;
revoke all on function public.ddd_duplicate_candidates(uuid) from public, anon, authenticated;
revoke all on function public.ddd_delete_duplicate(uuid, uuid, boolean, boolean) from public, anon, authenticated;
revoke all on function public.ddd_guard_students_merge() from public, anon, authenticated;
-- app sirf yeh do bulata hai (andar Director / Manager check hota hai)
grant execute on function public.ddd_duplicate_candidates(uuid) to authenticated;
grant execute on function public.ddd_delete_duplicate(uuid, uuid, boolean, boolean) to authenticated;
-- app ki duplicate warning bhi same chaabi use kar sake
grant execute on function public.ddd_dup_name_key(text) to authenticated;
grant execute on function public.ddd_dup_mobile_key(text) to authenticated;

comment on function public.ddd_duplicate_candidates(uuid) is
  '031: side by side screen. Pehli line duplicate, baaki ACTIVE original (same naam + same student mobile) aur plan. 0 line = duplicate nahi.';
comment on function public.ddd_delete_duplicate(uuid, uuid, boolean, boolean) is
  '031: Delete Duplicate (soft - merged_into + Left). Errors 42501 / DDN01 / DDP01 (payment_shift true chahiye) / DDF01 (fee kam, confirm_fee true chahiye) / DDC01 / DDB01 / P0002. Log duplicate_deletion_log.';

-- ---------------------------------------------------------------------
-- STEP 8. VERIFY (kuch bhi galat = poora rollback)
-- ---------------------------------------------------------------------
do $verify$
declare
  r     record;
  v_bad text := '';
begin
  for r in select f from unnest(array['public.ddd_dup_identity(uuid)', 'public.ddd_dup_plan(uuid,uuid)',
                                      'public.ddd_duplicate_candidates(uuid)', 'public.ddd_delete_duplicate(uuid,uuid,boolean,boolean)']) f loop
    if not exists (select 1 from pg_proc p where p.oid = to_regprocedure(r.f) and p.prosecdef
                     and exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%public%')) then
      v_bad := v_bad || r.f || ' (security definer / search_path) ';
    end if;
    if has_function_privilege('anon', r.f, 'execute') then
      v_bad := v_bad || r.f || ' (anon) ';
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.ddd_dup_plan(uuid,uuid)', 'execute') then
    v_bad := v_bad || 'ddd_dup_plan (app) ';
  end if;
  if not has_function_privilege('authenticated', 'public.ddd_delete_duplicate(uuid,uuid,boolean,boolean)', 'execute')
     or not has_function_privilege('authenticated', 'public.ddd_duplicate_candidates(uuid)', 'execute') then
    v_bad := v_bad || 'app execute missing ';
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.students'::regclass and tgname = 'trg_students_merge_guard' and tgenabled = 'O')
     or has_function_privilege('authenticated', 'public.ddd_guard_students_merge()', 'execute') then
    v_bad := v_bad || 'merge guard ';
  end if;
  if has_table_privilege('authenticated', 'public.duplicate_deletion_log', 'insert')
     or has_table_privilege('authenticated', 'public.duplicate_deletion_log', 'update')
     or has_table_privilege('authenticated', 'public.duplicate_deletion_log', 'delete')
     or has_table_privilege('anon', 'public.duplicate_deletion_log', 'select') then
    v_bad := v_bad || 'log table rights ';
  end if;
  if public.ddd_dup_mobile_key('+91 98765-43211') is distinct from '9876543211'
     or public.ddd_dup_mobile_key('09876543211') is distinct from '9876543211'
     or public.ddd_dup_mobile_key('0091 98765 43211') is distinct from '9876543211'
     or public.ddd_dup_mobile_key('+91 0 98765 43211') is distinct from '9876543211'
     or public.ddd_dup_mobile_key('98765432112') is not null
     or public.ddd_dup_mobile_key('987654321') is not null
     or public.ddd_dup_mobile_key('9999999999') is not null
     or public.ddd_dup_mobile_key(null) is not null
     or public.ddd_dup_name_key('  Rahul   KUMAR ') is distinct from 'rahul kumar'
     or public.ddd_dup_name_key('   ') is not null then
    v_bad := v_bad || 'rule self test ';
  end if;
  if v_bad <> '' then
    raise exception '031 VERIFY FAIL: %. Sab rollback, kuch nahi badla. Developer ko batayein.', v_bad;
  end if;
end
$verify$;

commit;

notify pgrst, 'reload schema';

-- ---------- ROLLBACK ----------
-- Wapas lena ho to 031_undo.sql poori file chalayein. Woh 031 ke functions hatata hai.
-- Log table khali ho to hatti hai, rows hon to unki copy backup_031 mein.
-- Jo duplicate pehle hi hataye (merge) ja chuke hain woh waise hi rehte hain - unki poori copy log ke snapshot mein hai.
