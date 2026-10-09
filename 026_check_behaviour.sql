-- =====================================================================
-- 026_check_behaviour.sql — 026 ke rules ka TEST (026 chalane ke baad).
-- Supabase - SQL Editor - New query - yeh POORI file paste - Run.
-- Sab rollback: KUCH SAVE NAHI HOTA (test students bhi nahi).
-- Ek manager (warden) aur Director "ban kar" 16 TEST students par sab rules chalata hai
-- (fix3: Exit Date ki seema, Left = Exit Date zaroori, wapas aaya student.
--  fix3b: warden Joining Date / bill ki tareekh nahi badal sakta, do baar wapsi).
-- Result ek ERROR jaisa dikhega: 026 STEP 4 RESULT ... — yahi result hai (jaan-bujh kar
-- error, taaki sab rollback ho). Pehli line mein SAB OK hona chahiye. FAIL ho to screenshot bhejein.
-- =====================================================================
do $$
declare
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  c   date := date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date;
  ce  date;
  p1  date;
  p2  date;
  nx  date;
  dim int;
  u_dir uuid;
  u_mgr uuid;
  h     uuid;
  sa uuid := gen_random_uuid();
  sb uuid := gen_random_uuid();
  sc uuid := gen_random_uuid();
  sd uuid := gen_random_uuid();
  se uuid := gen_random_uuid();
  sf uuid := gen_random_uuid();
  sg uuid := gen_random_uuid();
  sh uuid := gen_random_uuid();
  si uuid := gen_random_uuid();
  sk uuid := gen_random_uuid();
  sl uuid := gen_random_uuid();
  sm uuid := gen_random_uuid();
  sn uuid := gen_random_uuid();
  so uuid := gen_random_uuid();
  sp uuid := gen_random_uuid();
  sq uuid := gen_random_uuid();
  e1 date;
  rj date;
  pay_id uuid;
  msg2 text;
  n2   int;
  res  text[] := '{}';
  nok  int := 0;
  nall int := 0;
  msg  text;
  n0   int;
  n1   int;
  x    text;
  y    text;
  v_exp numeric;
begin
  ce := (c + interval '1 month - 1 day')::date;
  p1 := (c - interval '1 month')::date;
  p2 := (c - interval '2 month')::date;
  nx := (c + interval '1 month')::date;
  dim := extract(day from ce)::int;
  u_dir := (select u.id from public.users u join public.roles r on r.id = u.role_id where r.name = 'director' order by u.created_at, u.id limit 1);
  u_mgr := (select u.id from public.users u join public.roles r on r.id = u.role_id
             where r.name = 'manager' and coalesce(u.status, 'active') = 'active'
               and exists (select 1 from public.user_hostel_assignments a where a.user_id = u.id)
             order by u.created_at, u.id limit 1);
  h := (select a.hostel_id from public.user_hostel_assignments a where a.user_id = u_mgr order by a.hostel_id limit 1);
  if u_dir is null or u_mgr is null or h is null then
    raise exception '026 STEP 4 RESULT: test nahi chala — Director ya hostel wala Manager nahi mila';
  end if;
  if to_regclass('public.ddd_dues_void_log') is null then
    raise exception '026 STEP 4 RESULT: 026 abhi chali nahi — pehle 026_billing_exit_rules.sql chalayein';
  end if;

  -- test students + bills (SQL Editor, rollback at the end)
  begin
    insert into public.students(id, full_name, hostel_id, joining_date, monthly_fee, status) values
      (sa, 'ZZ 026 TEST A', h, p2, 9000, 'active'),
      (sb, 'ZZ 026 TEST B', h, p2, 9000, 'active'),
      (sc, 'ZZ 026 TEST C', h, c, 9000, 'active'),
      (sd, 'ZZ 026 TEST D', h, p1, 12000, 'active'),
      (se, 'ZZ 026 TEST E', h, p1, 9000, 'active'),
      (sf, 'ZZ 026 TEST F', h, p2, 9000, 'active'),
      (sg, 'ZZ 026 TEST G', h, p2, 9000, 'active'),
      (sh, 'ZZ 026 TEST H', h, p2, 9000, 'active'),
      (si, 'ZZ 026 TEST I', h, p2, 9000, 'active'),
      (sk, 'ZZ 026 TEST K', h, p2, 9000, 'active'),
      (sl, 'ZZ 026 TEST L', h, p2, 9000, 'active'),
      (sm, 'ZZ 026 TEST M', h, p2, 9000, 'active'),
      (sn, 'ZZ 026 TEST N', h, p2, 9000, 'active'),
      (so, 'ZZ 026 TEST O', h, p2, 9000, 'active'),
      (sp, 'ZZ 026 TEST P', h, p2, 9000, 'active'),
      (sq, 'ZZ 026 TEST Q', h, p2, 9000, 'active');
    update public.students set exit_date = c + 19 where id = se;
    update public.students set exit_date = p1 + 5 where id = sf;
    insert into public.monthly_dues(student_id, hostel_id, month, fee_amount, period_from, period_to)
    select s.id, h, m.m, s.monthly_fee, m.m, (m.m + interval '1 month - 1 day')::date
      from public.students s cross join (values (p2), (p1), (c)) m(m)
     where s.id in (sa, sb, sn, sp, sq) or (s.id = sd and m.m >= p1) or (s.id = sc and m.m = c) or (s.id = sm and m.m = c) or (s.id = so and m.m = p2)
        or (s.id in (sg, sh, si, sl) and m.m = c) or (s.id = sk and m.m >= p1);
    update public.monthly_dues set discount = 1000 where student_id in (sh, si) and month = c;   -- Director wala discount
  exception when others then
    raise exception '026 STEP 4 RESULT: test setup nahi bana (%). Kuch save nahi hua.', sqlerrm;
  end;

  -- 1. warden: A Left, exit = 10th of this month (ya aaj - 5, jo baad mein ho: warden pichhle 10 din tak hi) -> this month = utne din
  e1 := greatest(c + 9, v_today - 5);
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = e1 where id = sa;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  v_exp := round(9000 * (e1 - c + 1) / dim::numeric, 0);
  x := (select fee_amount || ' ' || status || ' ' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = sa and month = c);
  nall := nall + 1;
  if msg = 'ok' and x = v_exp || '.00 pending ' || to_char(e1, 'DD-MM')
     and (select fee_amount from public.monthly_dues where student_id = sa and month = p1) = 9000 then nok := nok + 1;
    res := res || ('OK   | 1 warden Left (exit ' || to_char(e1, 'DD-MM') || '): is mahine sirf ' || (e1 - c + 1) || ' din | ' || x);
  else res := res || ('FAIL | 1 warden Left (exit ' || to_char(e1, 'DD-MM') || '): is mahine sirf ' || (e1 - c + 1) || ' din | ' || coalesce(x, 'null') || ' ' || msg); end if;

  -- 2. same save again -> nothing new
  n0 := (select count(*) from public.ddd_dues_void_log where student_id = sa);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = e1 where id = sa;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  n1 := (select count(*) from public.ddd_dues_void_log where student_id = sa);
  nall := nall + 1;
  if msg = 'ok' and n0 = 1 and n1 = 1 then nok := nok + 1; res := res || ('OK   | 2 dobara save: kuch double nahi | log ' || n0 || '->' || n1);
  else res := res || ('FAIL | 2 dobara save: kuch double nahi | log ' || n0 || '->' || n1 || ' ' || msg); end if;

  -- 3. warden: A Active again -> bill back exactly
  begin
    execute 'set local role authenticated';
    update public.students set status = 'active', exit_date = null where id = sa;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  x := (select fee_amount || ' ' || status || ' ' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = sa and month = c);
  nall := nall + 1;
  if msg = 'ok' and x = '9000.00 pending ' || to_char(ce, 'DD-MM') then nok := nok + 1; res := res || ('OK   | 3 wapas Active: pura bill wapas | ' || x);
  else res := res || ('FAIL | 3 wapas Active: pura bill wapas | ' || coalesce(x, 'null') || ' ' || msg); end if;

  -- 4. director: B Left, exit = 15th of last month -> this month void, last month 15 days
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = p1 + 14 where id = sb;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  v_exp := round(9000 * 15 / extract(day from (p1 + interval '1 month - 1 day'))::numeric, 0);
  x := (select fee_amount || ' ' || status from public.monthly_dues where student_id = sb and month = c);
  y := (select fee_amount || ' ' || status || ' ' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = sb and month = p1);
  nall := nall + 1;
  if msg = 'ok' and x = '0.00 void' and y = v_exp || '.00 pending ' || to_char(p1 + 14, 'DD-MM') then nok := nok + 1;
    res := res || ('OK   | 4 Director Left (exit pichhle mahine 15): is mahina void, pichhla 15 din | ' || x || ' / ' || y);
  else res := res || ('FAIL | 4 Director Left (exit pichhle mahine 15): is mahina void, pichhla 15 din | ' || coalesce(x, 'null') || ' / ' || coalesce(y, 'null') || ' ' || msg); end if;

  -- 5. warden: pay more than owed for left B -> clean error, nothing saved
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  x := (select count(*) || '/' || coalesce(sum(paid_amount), 0) || '/' || count(*) filter (where month = nx) from public.monthly_dues where student_id = sb);
  begin
    execute 'set local role authenticated';
    perform public.record_partial_payment(sb, 9000 + v_exp + 100);
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  y := (select count(*) || '/' || coalesce(sum(paid_amount), 0) || '/' || count(*) filter (where month = nx) from public.monthly_dues where student_id = sb);
  nall := nall + 1;
  if msg like '%ko hostel chhoda%' and x = y and not exists (select 1 from public.fee_payments where student_id = sb) then nok := nok + 1;
    res := res || ('OK   | 5 Left student se zyada paise: saaf error, kuch save nahi | ' || msg);
  else res := res || ('FAIL | 5 Left student se zyada paise: saaf error, kuch save nahi | ' || msg || ' ' || x || '->' || y); end if;

  -- 6. warden: pay exactly what is owed -> works, Paid Till = exit date
  begin
    execute 'set local role authenticated';
    perform public.record_fee_payment(sb, 2, 9000 + v_exp);
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  x := (select paid_till::text from public.students where id = sb);
  nall := nall + 1;
  if msg = 'ok' and x = (p1 + 14)::text then nok := nok + 1; res := res || ('OK   | 6 Left student ka sahi baaki: jama hua, Paid Till = exit date | ' || x);
  else res := res || ('FAIL | 6 Left student ka sahi baaki: jama hua, Paid Till = exit date | ' || coalesce(x, 'null') || ' ' || msg); end if;

  -- 7. exit ke baad ka bill seedha banana (SQL Editor) -> blocked
  begin
    insert into public.monthly_dues(student_id, hostel_id, month, fee_amount) values (sb, h, nx, 9000);
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  nall := nall + 1;
  if msg like '%ko hostel chhoda — uske baad ka bill nahi ban sakta' then nok := nok + 1; res := res || ('OK   | 7 exit ke baad ka bill: block | ' || msg);
  else res := res || ('FAIL | 7 exit ke baad ka bill: block | ' || msg); end if;

  -- 8. app (warden) se Left bina Exit Date -> mana (Exit Date zaroori). SQL Editor se Left bina exit = aaj (IST)
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left' where id = sd;
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  msg2 := (select status || ' ' || coalesce(exit_date::text, '-') from public.students where id = sd);
  update public.students set status = 'left' where id = sd;
  v_exp := round(12000 * extract(day from v_today) / dim::numeric, 0);
  x := (select exit_date::text from public.students where id = sd);
  y := (select fee_amount || ' ' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = sd and month = c);
  nall := nall + 1;
  if msg = 'Left ke liye Exit Date zaroori hai' and msg2 = 'active -' and x = v_today::text and y = v_exp || '.00 ' || to_char(v_today, 'DD-MM') then nok := nok + 1;
    res := res || ('OK   | 8 app se Left bina Exit Date: mana; SQL Editor se exit = aaj, bill aaj tak | ' || x || ' / ' || y);
  else res := res || ('FAIL | 8 app se Left bina Exit Date: mana; SQL Editor se exit = aaj | ' || msg || ' / ' || coalesce(msg2, 'null') || ' / ' || coalesce(x, 'null') || ' / ' || coalesce(y, 'null')); end if;

  -- 9. credit review: C paid this month fully, then Left on the 5th -> bill same, listed for Director
  begin
    execute 'set local role authenticated';
    perform public.record_fee_payment(sc, 1, 9000);
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = c + 4 where id = sc;
  exception when others then msg := msg || ' / ' || sqlerrm;
  end;
  execute 'reset role';
  v_exp := 9000 - round(9000 * 5 / dim::numeric, 0);
  x := (select fee_amount || ' ' || paid_amount || ' ' || status from public.monthly_dues where student_id = sc and month = c);
  y := (select string_agg(action || ' ' || amount_note, ', ') from public.ddd_dues_void_log where student_id = sc);
  nall := nall + 1;
  if msg = 'ok' and x = '9000.00 9000.00 paid' and y = 'credit_review ' || v_exp || '.00' then nok := nok + 1;
    res := res || ('OK   | 9 jama paise zyada: bill nahi badla, credit review list | ' || y);
  else res := res || ('FAIL | 9 jama paise zyada: bill nahi badla, credit review list | ' || coalesce(x, 'null') || ' / ' || coalesce(y, 'null') || ' ' || msg); end if;

  -- 10. generator (warden, this month): E (exit 20th planned) = 20 days, F (exit last month) = no bill
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.generate_monthly_dues(c);
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  v_exp := round(9000 * 20 / dim::numeric, 0);
  x := (select fee_amount || ' ' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = se and month = c);
  y := (select count(*)::text from public.monthly_dues where student_id = sf and month = c);
  nall := nall + 1;
  if msg = 'ok' and x = v_exp || '.00 ' || to_char(c + 19, 'DD-MM') and y = '0' then nok := nok + 1;
    res := res || ('OK   | 10 Generate: exit wala mahina sirf rahe din, pehle gaya = bill nahi | ' || x);
  else res := res || ('FAIL | 10 Generate: exit wala mahina sirf rahe din, pehle gaya = bill nahi | ' || coalesce(x, 'null') || ' / F bills ' || coalesce(y, 'null') || ' ' || msg); end if;

  -- 11. log: warden sees nothing, director sees it
  begin
    execute 'set local role authenticated';
    n0 := (select count(*) from public.ddd_dues_void_log where student_id in (sa, sb, sc, sd, se));
  exception when others then n0 := -1;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    n1 := (select count(*) from public.ddd_dues_void_log where student_id in (sa, sb, sc, sd, se));
  exception when others then n1 := -1;
  end;
  execute 'reset role';
  nall := nall + 1;
  if n0 = 0 and n1 > 0 then nok := nok + 1; res := res || ('OK   | 11 log: Manager ko nahi dikhta, Director ko dikhta | ' || n0 || ' / ' || n1);
  else res := res || ('FAIL | 11 log: Manager ko nahi dikhta, Director ko dikhta | ' || n0 || ' / ' || n1); end if;

  -- 12. old guard: warden still cannot change a bill amount directly
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.monthly_dues set fee_amount = 1 where student_id = sa and month = p1;
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  nall := nall + 1;
  if msg like 'Only the Director%' then nok := nok + 1; res := res || ('OK   | 12 Manager bill amount seedha nahi badal sakta (015) | ' || msg);
  else res := res || ('FAIL | 12 Manager bill amount seedha nahi badal sakta (015) | ' || msg); end if;

  -- 13. warden cannot set merged_into (hidden way to stop bills)
  begin
    execute 'set local role authenticated';
    update public.students set merged_into = sb where id = sa;
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  nall := nall + 1;
  if msg = 'Merge sirf Director kar sakta hai' then nok := nok + 1; res := res || ('OK   | 13 Manager merge (merged_into) nahi kar sakta | ' || msg);
  else res := res || ('FAIL | 13 Manager merge (merged_into) nahi kar sakta | ' || msg); end if;

  -- 14. warden: G ne is mahine ka kuch hissa diya, phir Left (exit 5 tareekh, Director) -> baaki hata, jama paise wahi, credit review
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.record_partial_payment(sg, 5000);
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', u_dir::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = c + 4 where id = sg;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.record_partial_payment(sg, 100);
    msg2 := 'RAN';
  exception when others then msg2 := sqlerrm;
  end;
  execute 'reset role';
  v_exp := round(9000 * 5 / dim::numeric, 0);
  x := (select fee_amount || ' ' || paid_amount || ' ' || pending || ' ' || status from public.monthly_dues where student_id = sg and month = c);
  y := (select string_agg(action || ' ' || amount_note, ', ' order by id) from public.ddd_dues_void_log where student_id = sg);
  nall := nall + 1;
  if msg = 'ok' and x = '5000.00 5000.00 0.00 paid' and y = 'credit_review ' || (5000 - v_exp) || '.00, prorate 4000.00' and msg2 like '%ko hostel chhoda%' then
    nok := nok + 1; res := res || ('OK   | 14 kuch jama, phir Left: baaki hata (exit ke baad bill nahi), jama paise wahi, credit review | ' || x || ' / ' || y);
  else res := res || ('FAIL | 14 kuch jama, phir Left: baaki hata, jama paise wahi, credit review | ' || coalesce(x, 'null') || ' / ' || coalesce(y, 'null') || ' ' || msg || ' / ' || coalesce(msg2, '')); end if;

  -- 15. Director G ki payment delete (refund) -> bill sirf rahe din ka, exit ke baad ka kuch nahi
  pay_id := (select id from public.fee_payments where student_id = sg order by created_at limit 1);
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.delete_fee_payment(pay_id);
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  x := (select fee_amount || ' ' || pending || ' ' || status || ' ' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = sg and month = c);
  n2 := (select count(*) from public.monthly_dues where student_id = sg and month > c);
  nall := nall + 1;
  if msg = 'ok' and x = v_exp || '.00 ' || v_exp || '.00 pending ' || to_char(c + 4, 'DD-MM') and n2 = 0 then
    nok := nok + 1; res := res || ('OK   | 15 Director refund (payment delete): bill sirf rahe din ka | ' || x);
  else res := res || ('FAIL | 15 Director refund (payment delete): bill sirf rahe din ka | ' || coalesce(x, 'null') || ' ' || msg); end if;

  -- 16. discount: H (discount 1000, 2000 jama) aur I (discount 1000, kuch nahi jama) dono Left 5 tareekh -> ek hi sahi fee
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.record_partial_payment(sh, 2000);
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', u_dir::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = c + 4 where id in (sh, si);
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  x := (select amount_note::text from public.ddd_dues_void_log where student_id = sh and action = 'credit_review');
  y := (select fee_amount || ' ' || discount || ' ' || pending from public.monthly_dues where student_id = si and month = c);
  nall := nall + 1;
  if msg = 'ok' and x = (2000 - (v_exp - 1000)) || '.00' and y = v_exp || '.00 1000.00 ' || (v_exp - 1000) || '.00' then
    nok := nok + 1; res := res || ('OK   | 16 discount rahe din ki fee par: jama wale ka credit = jama - (fee - discount) | credit ' || x || ' / bina jama ' || y);
  else res := res || ('FAIL | 16 discount rahe din ki fee par | credit ' || coalesce(x, 'null') || ' / bina jama ' || coalesce(y, 'null') || ' ' || msg); end if;

  -- 17. Director B ko A mein merge karta hai -> Dashboard Left ginti se hata, B Active nahi ho sakta, B ka naya bill nahi
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    n0 := (public.dashboard_summary(p1, (c - 1)::date, h) -> 'cur' ->> 'left')::int;
    update public.students set merged_into = sa where id = sb;
    n1 := (public.dashboard_summary(p1, (c - 1)::date, h) -> 'cur' ->> 'left')::int;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  begin
    execute 'set local role authenticated';
    update public.students set status = 'active', exit_date = null where id = sb;
    msg2 := 'RAN';
  exception when others then msg2 := sqlerrm;
  end;
  execute 'reset role';
  begin
    insert into public.monthly_dues(student_id, hostel_id, month, fee_amount) values (sb, h, (c - interval '3 month')::date, 9000);
    x := 'RAN';
  exception when others then x := sqlerrm;
  end;
  nall := nall + 1;
  if msg = 'ok' and n0 - n1 = 1 and msg2 like 'Ye merged purana record hai%' and x like '%merged purana record hai%' then
    nok := nok + 1; res := res || ('OK   | 17 merged record: Dashboard Left mein nahi, Active nahi, naya bill nahi | left ' || n0 || '->' || n1);
  else res := res || ('FAIL | 17 merged record: Dashboard Left mein nahi, Active nahi, naya bill nahi | left ' || coalesce(n0::text, 'null') || '->' || coalesce(n1::text, 'null') || ' ' || msg || ' / ' || coalesce(msg2, '') || ' / ' || coalesce(x, '')); end if;

  -- 18. Cancelled (void) bill par fee nahi: K ka is mahine ka bill void (Director), warden pichhla + yeh mahina dates se le -> mana
  update public.monthly_dues set fee_amount = 0, discount = 0, status = 'void' where student_id = sk and month = c;
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    perform public.record_fee_payment_range(sk, p1, ce, 9000);
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  x := (select status from public.monthly_dues where student_id = sk and month = c);
  nall := nall + 1;
  if msg like '%Cancelled (void)%' and x = 'void' and not exists (select 1 from public.fee_payments where student_id = sk) then
    nok := nok + 1; res := res || ('OK   | 18 Cancelled (void) bill par fee nahi | ' || msg);
  else res := res || ('FAIL | 18 Cancelled (void) bill par fee nahi | ' || msg || ' / ' || coalesce(x, 'null')); end if;

  -- 19. exit wale mahine ke kuch din (Dates chuno) = poore mahine ka rate: L Left 5 tareekh (Director), warden 1-3 tareekh ki fee
  begin
    perform set_config('request.jwt.claim.sub', u_dir::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = c + 4 where id = sl;
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', u_mgr::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.record_fee_payment_range(sl, c, c + 2, round(9000 * 3 / dim::numeric, 0));
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  x := (select fee_amount || ' ' || pending || ' ' || to_char(paid_to, 'DD-MM') from public.monthly_dues where student_id = sl and month = c);
  nall := nall + 1;
  if msg = 'ok' and x = v_exp || '.00 ' || (v_exp - round(9000 * 3 / dim::numeric, 0)) || '.00 ' || to_char(c + 2, 'DD-MM') then
    nok := nok + 1; res := res || ('OK   | 19 exit mahine ke 3 din = ' || round(9000 * 3 / dim::numeric, 0) || ' (poore mahine ka rate), paid till 3 tareekh | ' || x);
  else res := res || ('FAIL | 19 exit mahine ke 3 din = poore mahine ka rate | ' || coalesce(x, 'null') || ' ' || msg); end if;

  -- 20. Paid Till consistent for the test students
  nall := nall + 1;
  if not exists (select 1 from public.students s where s.id in (sa, sb, sc, sd, se, sf, sg, sh, si, sk, sl) and s.paid_till is distinct from public.compute_paid_till(s.id)) then
    nok := nok + 1; res := array_append(res, 'OK   | 20 Paid Till sab test students ka sahi | ');
  else res := array_append(res, 'FAIL | 20 Paid Till sab test students ka sahi | '); end if;

  -- 21. fix3: warden purani Exit Date (aaj - 20) aur Active student par Exit Date nahi laga sakta
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  x := (select fee_amount || ' ' || status from public.monthly_dues where student_id = sm and month = c);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = v_today - 20 where id = sm;
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  begin
    execute 'set local role authenticated';
    update public.students set exit_date = v_today + 5 where id = sm;
    msg2 := 'RAN';
  exception when others then msg2 := sqlerrm;
  end;
  execute 'reset role';
  y := (select fee_amount || ' ' || status from public.monthly_dues where student_id = sm and month = c);
  nall := nall + 1;
  if msg = 'Itni purani Exit Date sirf Director laga sakte hain (warden: pichhle 10 din tak)' and msg2 = 'Active / Temp Leave student ki Exit Date sirf Director laga sakte hain'
     and x = y and (select status = 'active' and exit_date is null from public.students where id = sm) then
    nok := nok + 1; res := res || ('OK   | 21 warden: purani Exit Date (aaj - 20) mana, Active par Exit Date mana, bill same | ' || msg);
  else res := res || ('FAIL | 21 warden: purani Exit Date mana, Active par Exit Date mana | ' || msg || ' / ' || msg2 || ' / ' || coalesce(x, 'null') || ' -> ' || coalesce(y, 'null')); end if;

  -- 22. fix3: wapas aaya. N Left (Director, exit 2 mahine pehle ki 10 tareekh), warden: wapsi 5 tareekh is mahine
  --     -> pehle wala mahina kata, pichhla void (rejoin_keep), is mahine sirf wapsi se. Aaj + 40 wali wapsi mana.
  rj := c + 4;
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = p2 + 9 where id = sn;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'active', exit_date = null, rejoined_on = v_today + 40 where id = sn;
    msg2 := 'RAN';
  exception when others then msg2 := sqlerrm;
  end;
  execute 'reset role';
  begin
    execute 'set local role authenticated';
    update public.students set status = 'active', exit_date = null, rejoined_on = rj where id = sn;
  exception when others then msg := msg || ' / ' || sqlerrm;
  end;
  execute 'reset role';
  v_exp := round(9000 * (dim - 4) / dim::numeric, 0);
  x := (select string_agg(fee_amount || ' ' || status, ', ' order by month) from public.monthly_dues where student_id = sn);
  y := (select fee_amount || ' ' || to_char(period_from, 'DD-MM') || '..' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = sn and month = c);
  n0 := (select count(*) from public.ddd_dues_void_log where student_id = sn and action = 'rejoin_keep');
  nall := nall + 1;
  if msg = 'ok' and msg2 = 'Wapsi ki tareekh aaj se 31 din se zyada aage nahi ho sakti'
     and x = round(9000 * 10 / extract(day from (p2 + interval '1 month - 1 day'))::numeric, 0) || '.00 pending, 0.00 void, ' || v_exp || '.00 pending'
     and y = v_exp || '.00 ' || to_char(rj, 'DD-MM') || '..' || to_char(ce, 'DD-MM') and n0 = 2 then
    nok := nok + 1; res := res || ('OK   | 22 wapas aaya (wapsi ' || to_char(rj, 'DD-MM') || '): purane mahine kate / void hi, is mahina sirf wapsi se | ' || x);
  else res := res || ('FAIL | 22 wapas aaya: purane mahine kate / void hi, is mahina sirf wapsi se | ' || msg || ' / ' || coalesce(msg2, '') || ' / ' || coalesce(x, 'null') || ' / ' || coalesce(y, 'null') || ' keep ' || n0); end if;

  -- 23. fix3: wahi save dobara -> kuch double nahi
  n0 := (select count(*) from public.ddd_dues_void_log where student_id = sn);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'active', exit_date = null, rejoined_on = rj where id = sn;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  n1 := (select count(*) from public.ddd_dues_void_log where student_id = sn);
  nall := nall + 1;
  if msg = 'ok' and n0 = n1 then nok := nok + 1; res := res || ('OK   | 23 wapsi wala save dobara: kuch double nahi | log ' || n0 || '->' || n1);
  else res := res || ('FAIL | 23 wapsi wala save dobara: kuch double nahi | log ' || n0 || '->' || n1 || ' ' || msg); end if;

  -- 24. fix3: O (sirf 2 mahine pehle ka bill) Left, wapsi 7 tareekh is mahine: Generate (warden) is mahine ka bill wapsi se banata hai
  delete from public.monthly_dues where student_id = so and month > p2;   -- check 10 ka generate O ka is mahine ka bill bana chuka hai
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = p2 + 9 where id = so;
    execute 'reset role';
    perform set_config('request.jwt.claim.sub', u_mgr::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    update public.students set status = 'active', exit_date = null, rejoined_on = c + 6 where id = so;
    perform public.generate_monthly_dues(c);
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  v_exp := round(9000 * (dim - 6) / dim::numeric, 0);
  x := (select fee_amount || ' ' || to_char(period_from, 'DD-MM') from public.monthly_dues where student_id = so and month = c);
  n2 := (select count(*) from public.monthly_dues where student_id = so and month = p1);
  nall := nall + 1;
  if msg = 'ok' and x = v_exp || '.00 ' || to_char(c + 6, 'DD-MM') and n2 = 0 then
    nok := nok + 1; res := res || ('OK   | 24 Generate: wapas aaye student ka is mahine ka bill wapsi ki tareekh se, beech ka mahina nahi | ' || x);
  else res := res || ('FAIL | 24 Generate: wapas aaye student ka bill wapsi ki tareekh se | ' || coalesce(x, 'null') || ' / beech ' || n2 || ' ' || msg); end if;

  -- 25. fix3: Paid Till sahi naye test students ka bhi
  nall := nall + 1;
  if not exists (select 1 from public.students s where s.id in (sm, sn, so) and s.paid_till is distinct from public.compute_paid_till(s.id)) then
    nok := nok + 1; res := array_append(res, 'OK   | 25 Paid Till naye test students ka sahi | ');
  else res := array_append(res, 'FAIL | 25 Paid Till naye test students ka sahi | '); end if;

  -- 26. fix3b: warden bill ban chuke student ki Joining Date aage nahi kar sakta, bill ki tareekh bhi nahi badal sakta
  perform set_config('request.jwt.claim.sub', u_mgr::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_mgr, 'role', 'authenticated')::text, true);
  x := (select string_agg(fee_amount || ' ' || status || ' ' || to_char(period_from, 'DD-MM') || '..' || to_char(period_to, 'DD-MM'), ', ' order by month)
          from public.monthly_dues where student_id = sp);
  begin
    execute 'set local role authenticated';
    update public.students set joining_date = c + 1 where id = sp;
    msg := 'RAN';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  begin
    execute 'set local role authenticated';
    update public.monthly_dues set period_from = ce, period_to = ce where student_id = sp and month = c;
    msg2 := 'RAN';
  exception when others then msg2 := sqlerrm;
  end;
  execute 'reset role';
  y := (select string_agg(fee_amount || ' ' || status || ' ' || to_char(period_from, 'DD-MM') || '..' || to_char(period_to, 'DD-MM'), ', ' order by month)
          from public.monthly_dues where student_id = sp);
  nall := nall + 1;
  if msg = 'Bill ban chuka hai - Joining Date aage sirf Director kar sakte hain' and msg2 = 'Bill ka student / mahina / tareekh sirf Director badal sakta hai'
     and x = y and (select joining_date = p2 from public.students where id = sp) then
    nok := nok + 1; res := res || ('OK   | 26 warden: Joining Date aage mana (bill ban chuka), bill ki tareekh badalna mana, bill same | ' || msg);
  else res := res || ('FAIL | 26 warden: Joining Date aage mana, bill ki tareekh badalna mana | ' || msg || ' / ' || coalesce(msg2, '') || ' / ' || coalesce(x, 'null') || ' -> ' || coalesce(y, 'null')); end if;

  -- 27. fix3b: do baar wapsi isi mahine (Director): Left pichhle mahine ke aakhri din, wapas 3 tareekh, Left 6, wapas 8
  --     -> is mahine ka bill 3-6 aur 8 se mahine ke end tak (pehli chhutti ke din dobara bill nahi)
  perform set_config('request.jwt.claim.sub', u_dir::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_dir, 'role', 'authenticated')::text, true);
  begin
    execute 'set local role authenticated';
    update public.students set status = 'left', exit_date = c - 1 where id = sq;
    update public.students set status = 'active', exit_date = null, rejoined_on = c + 2 where id = sq;
    update public.students set status = 'left', exit_date = c + 5 where id = sq;
    update public.students set status = 'active', exit_date = null, rejoined_on = c + 7 where id = sq;
    msg := 'ok';
  exception when others then msg := sqlerrm;
  end;
  execute 'reset role';
  v_exp := least(9000, round(9000 * 4 / dim::numeric, 0) + round(9000 * (dim - 7) / dim::numeric, 0));
  x := (select fee_amount || ' ' || to_char(period_from, 'DD-MM') || '..' || to_char(period_to, 'DD-MM') from public.monthly_dues where student_id = sq and month = c);
  y := (select fee_amount || ' ' || status from public.monthly_dues where student_id = sq and month = p1);
  nall := nall + 1;
  if msg = 'ok' and x = v_exp || '.00 ' || to_char(c + 2, 'DD-MM') || '..' || to_char(ce, 'DD-MM') and y = '9000.00 pending'
     and not exists (select 1 from public.students s where s.id in (sp, sq) and s.paid_till is distinct from public.compute_paid_till(s.id)) then
    nok := nok + 1; res := res || ('OK   | 27 do baar wapsi isi mahine: bill sirf ' || to_char(c + 2, 'DD') || '-' || to_char(c + 5, 'DD') || ' aur ' || to_char(c + 7, 'DD') || ' se | ' || x);
  else res := res || ('FAIL | 27 do baar wapsi isi mahine: bill sirf rahe din ka | ' || msg || ' / ' || coalesce(x, 'null') || ' / ' || coalesce(y, 'null') || ' (expected ' || v_exp || ')'); end if;

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  raise exception '%', '026 STEP 4 RESULT: ' || case when nok = nall then 'SAB OK' else 'FAIL ' || (nall - nok) end
    || ' (' || nok || '/' || nall || ') — kuch save nahi hua, sab rollback.' || chr(10) || array_to_string(res, chr(10));
end $$;
