-- =====================================================================
-- 030_common_expense.sql   (026, 027, 028, 029 ke baad chalegi)
-- DDD Hostel - COMMON EXPENSE (ek kharcha kai hostels mein occupants ke hisaab se bata hua)
--
-- KYA KARTA HAI (owner ke liye)
--  1. Nayi table common_expenses = ek common kharcha (date, category, description,
--     total, mode, paid to, remarks, kisne banaya / badla / recalculate kiya / hataya).
--  2. Nayi table common_expense_hostels = us kharche ka hostel wise hissa
--     (us date ke occupants, unme staff kitne, kaun kaun gina gaya, hissa Rs).
--  3. expenses table mein 5 naye KHALI columns (common_expense_id, common_total,
--     common_hostels, common_occupants, common_occupants_total). Har hostel ka hissa
--     expenses mein ek alag row banta hai (status approved, label Common Expense (Split)).
--     Isliye har expense list, report, CSV aur dashboard total mein hissa EK hi baar
--     judta hai. Asli (parent) kharcha expenses mein nahi hota, isliye double nahi hota.
--  4. Occupant kaun (owner rule R6) - date D par gina jaata hai agar
--       - joining date D ya usse pehle (joining khali = entry ki date)
--       - exit date khali ho ya D ke BAAD ho (jis din nikla us din NAHI gina, M3)
--       - Left hai aur exit date khali = nahi gina
--       - Wapas aaya (rejoined_on) to beech ki chhutti (pichhli exit se wapsi tak) nahi gina
--       - merge hua duplicate (merged_into bhara) = nahi gina
--       - Active aur Temp Leave dono gine jaate hain
--       - students table ke staff (bed wale, occupant_type staff, 029) bhi gine jaate hain.
--         Staff module ke employees NAHI gine jaate. 029 na ho to sab student maane jaate hain.
--  5. Hissa = total x hostel ke occupants / sab chune hostels ke occupants, PAISE tak.
--     Bache hue paise sabse bade remainder wale hostel ko (largest remainder), isliye
--     hisson ka jod hamesha total ke barabar. 0 occupant wale hostel ka hissa 0.
--     Sab chune hostels 0 hon to error. Aage ki date ka common expense nahi banta.
--  6. Sirf Director aur Manager bana, badal, hata, recalculate kar sakte hain
--     (027 laga ho to ddd_can common_expense, warna sirf Director). Ye kharcha apne aap
--     APPROVED hota hai. Warden apne hostel ka hissa sirf dekh sakta hai.
--     Hisse wali expense row ko app se koi seedha badal ya hata nahi sakta (guard trigger).
--  7. Edit: sirf amount / description / category / mode badle to wahi saved occupants
--     se naya hissa. Date ya hostels badle to us date ke occupants dobara gine jaate hain.
--     Hatane par saare hisse expenses se hat jaate hain (parent row history ke liye rehti hai).
--  8. Recalculate button (ddd_common_expense_recalc) = aaj ke data se dobara ginti.
--     Duplicate delete (031) apne aap ddd_cexp_recalc_for_student chalata hai, jo
--     purane split bhi theek karta hai (R7, M8).
--  9. Jis hostel ka hissa kisi chalu common expense mein hai woh hostel delete nahi hota.
-- 10. Dono nayi tables par audit trigger (Activity Log mein kisne kab kya kiya).
--
-- APP KE LIYE FUNCTIONS
--   ddd_common_expense_preview(p_date, p_total, p_hostels, p_id default null)  split dikhana, kuch save nahi
--   ddd_common_expense_save(p_id, p_date, p_category, p_description, p_total, p_mode, p_paid_to, p_remarks, p_hostels)
--        returns uuid. p_id = app form khulte hi crypto.randomUUID(), retry / double tap se do kharche nahi bante
--   ddd_common_expense_delete(p_id)        hisse hatao, returns kitni rows hati (doosri baar 0)
--   ddd_common_expense_recalc(p_id)        returns jsonb id, changed, before, after
--   ddd_common_expense_report(p_from, p_to) har kharche ki har hostel ki line (warden = sirf apna hostel)
--   ddd_occupants_on(p_hostel, p_date)     ek hostel ke us din ke occupants
--   ddd_cexp_recalc_for_student(p_student)  sirf andar se (031 aur SQL Editor), app se nahi
--
-- KAISE CHALAYEIN
--  - Pehle Supabase backup lein. Class time ke bahar chalayein.
--  - Poori file SQL Editor mein paste karke ek baar Run. Do baar chalana safe hai.
--  - Pre-check fail ho to kuch nahi badalta, Hinglish message aata hai.
--  - Baad mein 030_check.sql chalayein (har row ok = true).
--  - Koi purani data row nahi badalti (sirf naye khali columns, nayi tables, functions).
--  - Wapas lena ho to 030_undo.sql.
-- =====================================================================
begin;

set local lock_timeout = '15s';

-- ---------------------------------------------------------------------
-- STEP 1. PRE-CHECK (kuch bhi anjaana = yahin ruk jao, kuch nahi badla)
-- ---------------------------------------------------------------------
do $pre$
declare
  v_miss text;
  v_bad  text;
  v_fp   text;
begin
  -- 026 pehle chahiye (merged_into, rejoined_on, rejoin log)
  if to_regclass('public.ddd_dues_void_log') is null
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'students' and column_name in ('merged_into', 'rejoined_on')) <> 2
     or to_regprocedure('public.ddd_exit_bills_sync(uuid,text)') is null then
    raise exception '030 RUKA: 026 (billing exit rules) is database mein nahi mili. Pehle 026 chalayein. Kuch nahi badla.';
  end if;

  v_miss := (select string_agg(t, ', ') from unnest(array['expenses', 'students', 'hostels', 'users', 'roles', 'audit_logs',
                                                          'user_hostel_assignments']) t
              where to_regclass('public.' || t) is null);
  if v_miss is not null then
    raise exception '030 RUKA: table nahi mili - %. Sahi Supabase project khula hai? Kuch nahi badla.', v_miss;
  end if;
  v_miss := (select string_agg(x.tbl || '.' || x.col, ', ')
               from (values ('expenses', 'id'), ('expenses', 'hostel_id'), ('expenses', 'expense_date'), ('expenses', 'category'),
                            ('expenses', 'amount'), ('expenses', 'paid_to'), ('expenses', 'mode'), ('expenses', 'remarks'),
                            ('expenses', 'status'), ('expenses', 'added_by'), ('expenses', 'approved_by'), ('expenses', 'created_by'),
                            ('students', 'id'), ('students', 'hostel_id'), ('students', 'joining_date'), ('students', 'exit_date'),
                            ('students', 'status'), ('students', 'created_at'), ('students', 'full_name'),
                            ('hostels', 'id'), ('hostels', 'code'), ('hostels', 'name'), ('users', 'full_name'),
                            ('ddd_dues_void_log', 'student_id'), ('ddd_dues_void_log', 'due_id'), ('ddd_dues_void_log', 'action'),
                            ('ddd_dues_void_log', 'old_period_to'), ('ddd_dues_void_log', 'new_period_from')) x(tbl, col)
              where not exists (select 1 from information_schema.columns c
                                 where c.table_schema = 'public' and c.table_name = x.tbl and c.column_name = x.col));
  if v_miss is not null then
    raise exception '030 RUKA: columns nahi mile - %. Developer ko batayein. Kuch nahi badla.', v_miss;
  end if;
  if (select data_type from information_schema.columns
       where table_schema = 'public' and table_name = 'expenses' and column_name = 'amount') <> 'numeric' then
    raise exception '030 RUKA: expenses.amount numeric nahi hai. Developer ko batayein. Kuch nahi badla.';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'students' and column_name = 'occupant_type' and data_type <> 'text') then
    raise exception '030 RUKA: students.occupant_type text nahi hai. Developer ko batayein. Kuch nahi badla.';
  end if;

  v_miss := (select string_agg(f, ', ') from unnest(array['public.audit_trigger()', 'public.is_director()', 'public.is_accountant()',
                                                          'public.my_hostels()', 'public.ddd_is_api_caller()']) f
              where to_regprocedure(f) is null);
  if v_miss is not null then
    raise exception '030 RUKA: function nahi mila - %. Kuch nahi badla.', v_miss;
  end if;
  -- guard isi par tika hai - app ka role (authenticated / anon) pehchanna
  v_fp := (select md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g'))
             from pg_proc p where p.oid = 'public.ddd_is_api_caller()'::regprocedure);
  if v_fp is distinct from '7fb724d0032326ff73359c2861c3bef3' then
    raise exception '030 RUKA: ddd_is_api_caller ka live code anjaana hai (fingerprint %). Developer ko batayein. Kuch nahi badla.', v_fp;
  end if;

  -- doosri baar chal rahi ho: jo pehle se hai woh isi file ka hona chahiye
  if to_regclass('public.common_expenses') is not null
     and (select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'common_expenses'
             and column_name in ('id', 'expense_date', 'category', 'description', 'total_amount', 'mode', 'paid_to', 'remarks',
                                 'created_by', 'created_at', 'updated_by', 'updated_at', 'recalc_by', 'recalc_at', 'recalc_reason',
                                 'removed_by', 'removed_at')) <> 17 then
    raise exception '030 RUKA: public.common_expenses pehle se hai par uska structure alag hai. Developer ko batayein. Kuch nahi badla.';
  end if;
  if to_regclass('public.common_expense_hostels') is not null
     and (select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'common_expense_hostels'
             and column_name in ('id', 'common_expense_id', 'hostel_id', 'occupants', 'staff_occupants', 'share', 'counted_ids',
                                 'created_at', 'updated_at')) <> 9 then
    raise exception '030 RUKA: public.common_expense_hostels pehle se hai par uska structure alag hai. Developer ko batayein. Kuch nahi badla.';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'expenses' and column_name = 'common_expense_id' and data_type <> 'uuid') then
    raise exception '030 RUKA: expenses.common_expense_id pehle se hai par uuid nahi hai. Kuch nahi badla.';
  end if;

  -- isi naam ke functions pehle se hon to sirf 030 wale (fingerprint) hi chalenge
  v_bad := (select string_agg(p.proname || '(' || oidvectortypes(p.proargtypes) || ') ' || md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')), ', ')
              from pg_proc p
             where p.pronamespace = 'public'::regnamespace
               and p.proname in ('ddd_ce_can_manage', 'ddd_ce_inr', 'ddd_ce_is_present', 'ddd_ce_prev_exit', 'ddd_ce_occupants', 'ddd_ce_plan', 'ddd_ce_apply',
                                 'ddd_occupants_on', 'ddd_common_expense_preview', 'ddd_common_expense_save', 'ddd_common_expense_delete',
                                 'ddd_common_expense_recalc', 'ddd_common_expense_report', 'ddd_cexp_recalc_for_student',
                                 'ddd_guard_common_expense_share', 'ddd_guard_hostel_common_expense', 'ddd_ce_split')
               and (p.proname || '(' || oidvectortypes(p.proargtypes) || ')', md5(regexp_replace(regexp_replace(p.prosrc, '--[^\n]*', '', 'g'), '\s+', '', 'g')))
                   not in (select x.sig, x.fp from (values
                     --FP-BEGIN
                     ('ddd_ce_apply(uuid, date, text, text, numeric, text, text, text, uuid[], boolean, text)', 'ff19888072f9bb3cee80131c545e19bd'),
                     ('ddd_ce_can_manage()', '8850321c7723fe92695a980d16c30f59'),
                     ('ddd_ce_inr(numeric)', '9a479bd6a953613ec96ad47414d6e3ba'),
                     ('ddd_ce_is_present(date, timestamp with time zone, date, text, uuid, date, date, date)', 'aec2b359202e2670ce0612382299a5cd'),
                     ('ddd_ce_occupants(date, uuid[])', 'd4ea5e6bc198ca4c8f3c73c66ff0a341'),
                     ('ddd_ce_plan(uuid, date, numeric, uuid[], boolean)', '455e5010e6240f030660d92f7c74fadf'),
                     ('ddd_ce_prev_exit(uuid, date)', '18cd6f5049981cb106f6ec2e02ca29d2'),
                     ('ddd_cexp_recalc_for_student(uuid)', '2adacca3138c316db21a221b25a63f69'),
                     ('ddd_common_expense_delete(uuid)', 'dff7f8c49672c65b4957cc63934fb6c2'),
                     ('ddd_common_expense_preview(date, numeric, uuid[], uuid)', '7d10fc45dbaa87f9b1db95a48c8ded28'),
                     ('ddd_common_expense_recalc(uuid)', '8f6b96817441c2baf9249d96ba881652'),
                     ('ddd_common_expense_report(date, date)', '4190bbd431a780cfcb1648d517dc1263'),
                     ('ddd_common_expense_save(uuid, date, text, text, numeric, text, text, text, uuid[])', 'd4c24448b3dee1cdd9969e8702302139'),
                     ('ddd_guard_common_expense_share()', '83a6f404208f0a895c17b37ee1e87fc3'),
                     ('ddd_guard_hostel_common_expense()', 'beda2593f472636a30ae811716de3cf7'),
                     ('ddd_occupants_on(uuid, date)', '146595e6e49951b05963f8b8e316af99')
                     --FP-END
                   ) x(sig, fp)));
  if v_bad is not null then
    raise exception '030 RUKA: in naamon ke functions pehle se hain par 030 wale nahi - %. Developer ko batayein. Kuch nahi badla.', v_bad;
  end if;
end
$pre$;

-- ---------------------------------------------------------------------
-- STEP 2. nayi tables
-- ---------------------------------------------------------------------
create table if not exists public.common_expenses (
  id            uuid primary key default gen_random_uuid(),
  expense_date  date not null,
  category      text not null,
  description   text,
  total_amount  numeric(12,2) not null,
  mode          text,
  paid_to       text,
  remarks       text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_by    uuid,
  updated_at    timestamptz,
  recalc_by     uuid,
  recalc_at     timestamptz,
  recalc_reason text,
  removed_by    uuid,
  removed_at    timestamptz,
  constraint common_expenses_total_chk check (total_amount > 0)
);
comment on table public.common_expenses is
  '030: common expense (kai hostels mein occupants ke hisaab se bata hua). Sirf ddd_common_expense_save / _delete / _recalc se likha jaata hai. removed_at bhara = hata diya (hisse expenses se hat gaye, breakup history ke liye rehta hai).';

create table if not exists public.common_expense_hostels (
  id                uuid not null default gen_random_uuid(),
  common_expense_id uuid not null references public.common_expenses(id) on delete cascade,
  hostel_id         uuid not null references public.hostels(id) on delete cascade,
  occupants         int not null default 0,
  staff_occupants   int not null default 0,
  share             numeric(12,2) not null default 0,
  counted_ids       uuid[] not null default '{}'::uuid[],
  created_at        timestamptz not null default now(),
  updated_at        timestamptz,
  constraint common_expense_hostels_pkey primary key (common_expense_id, hostel_id),
  constraint common_expense_hostels_id_key unique (id),
  constraint common_expense_hostels_chk check (occupants >= 0 and staff_occupants >= 0 and staff_occupants <= occupants
                                               and share >= 0 and cardinality(counted_ids) = occupants)
);
comment on table public.common_expense_hostels is
  '030: common expense ka hostel wise breakup - us date ke occupants, unme staff, counted_ids = kaun kaun gina gaya, share = hissa. Hissa khud expenses mein ek row hai (share 0 = koi row nahi).';

create index if not exists idx_common_expenses_date on public.common_expenses (expense_date) where removed_at is null;
create index if not exists idx_common_expense_hostels_hostel on public.common_expense_hostels (hostel_id);

-- ---------------------------------------------------------------------
-- STEP 3. expenses - 5 naye khali columns (purani rows par sab NULL rehta hai)
-- ---------------------------------------------------------------------
alter table public.expenses add column if not exists common_expense_id      uuid;
alter table public.expenses add column if not exists common_total           numeric(12,2);
alter table public.expenses add column if not exists common_hostels         int;
alter table public.expenses add column if not exists common_occupants       int;
alter table public.expenses add column if not exists common_occupants_total int;

do $cols$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.expenses'::regclass and conname = 'expenses_common_expense_id_fkey') then
    alter table public.expenses add constraint expenses_common_expense_id_fkey
      foreign key (common_expense_id) references public.common_expenses(id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.expenses'::regclass and conname = 'expenses_common_fields_chk') then
    alter table public.expenses add constraint expenses_common_fields_chk
      check (common_expense_id is null
             or (common_total is not null and common_hostels is not null
                 and common_occupants is not null and common_occupants_total is not null));
  end if;
end
$cols$;

-- ek common expense ka ek hostel mein sirf ek hissa
create unique index if not exists ux_expenses_common_share
  on public.expenses (common_expense_id, hostel_id) where common_expense_id is not null;

comment on column public.expenses.common_expense_id is
  '030: bhara = ye row ek Common Expense (Split) ka hissa hai. Sirf Common Expense screen (ddd_common_expense_save) se badalta hai.';
comment on column public.expenses.common_total is '030: common expense ka poora total.';
comment on column public.expenses.common_hostels is '030: kitne hostels mein bata (0 occupant wale chune hostel bhi gine).';
comment on column public.expenses.common_occupants is '030: is hostel ke occupants us date par.';
comment on column public.expenses.common_occupants_total is '030: sab chune hostels ke occupants us date par.';

-- ---------------------------------------------------------------------
-- STEP 4. RLS + rights. App sirf PADH sakta hai, likhna sirf functions se.
-- ---------------------------------------------------------------------
alter table public.common_expenses enable row level security;
alter table public.common_expense_hostels enable row level security;

drop policy if exists common_expense_hostels_read on public.common_expense_hostels;
create policy common_expense_hostels_read on public.common_expense_hostels for select to authenticated
  using (public.is_director() or public.is_accountant() or hostel_id in (select public.my_hostels()));

drop policy if exists common_expenses_read on public.common_expenses;
create policy common_expenses_read on public.common_expenses for select to authenticated
  using (public.is_director() or public.is_accountant()
         or exists (select 1 from public.common_expense_hostels ch
                     where ch.common_expense_id = common_expenses.id
                       and ch.hostel_id in (select public.my_hostels())));

revoke all on table public.common_expenses, public.common_expense_hostels from public, anon, authenticated;
grant select on table public.common_expenses, public.common_expense_hostels to authenticated;

-- audit (kisne, kab) - wahi generic trigger jo baaki tables par hai
drop trigger if exists trg_common_expenses_audit on public.common_expenses;
create trigger trg_common_expenses_audit after insert or update or delete on public.common_expenses
  for each row execute function public.audit_trigger();
drop trigger if exists trg_common_expense_hostels_audit on public.common_expense_hostels;
create trigger trg_common_expense_hostels_audit after insert or update or delete on public.common_expense_hostels
  for each row execute function public.audit_trigger();

-- ---------------------------------------------------------------------
-- STEP 5. andar ke helper functions (app inhe seedha call nahi kar sakta)
-- ---------------------------------------------------------------------

-- kaun common expense bana / badal / hata / recalculate kar sakta hai
-- SQL Editor (login nahi, PostgREST nahi) = haan. 027 laga = ddd_can(common_expense). Warna is_director.
create or replace function public.ddd_ce_can_manage() returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then
    return session_user not in ('authenticator', 'anon', 'authenticated', 'supabase_auth_admin');
  end if;
  if to_regprocedure('public.ddd_can(text)') is not null then
    return coalesce(public.ddd_can('common_expense'), false);
  end if;
  return coalesce(public.is_director(), false);
end $$;

-- Rs Indian style mein, jaise 68,13,367 ya 333.34
create or replace function public.ddd_ce_inr(p numeric) returns text
language sql stable set search_path = public as $$
  select case when p = trunc(p) then to_char(p, 'FM99,99,99,99,990')
              else to_char(p, 'FM99,99,99,99,990.00') end;
$$;

-- EK student us DATE ko hostel mein gina jaayega? (owner rule R6 - sirf yahin likha hai)
-- p_prev_exit = wapas aaye student ki pichhli exit date (ddd_ce_prev_exit), baaki ke liye khali.
-- Sirf ek expression hai (koi query nahi), isliye Postgres ise query mein hi jod deta hai (tez).
create or replace function public.ddd_ce_is_present(p_joining date, p_created timestamptz, p_exit date, p_status text,
                                                    p_merged uuid, p_rejoined date, p_prev_exit date, p_date date)
returns boolean
language sql stable as $$
  select coalesce(
           p_merged is null
           and coalesce(p_joining, (p_created at time zone 'Asia/Kolkata')::date) <= p_date
           and (p_exit is null or p_exit > p_date)
           and not (lower(btrim(coalesce(p_status, ''))) = 'left' and p_exit is null)
           and not (p_rejoined is not null and p_date < p_rejoined and p_date >= coalesce(p_prev_exit, 'infinity'::date)),
           false);
$$;

-- wapas aaye student (rejoined_on) ki pichhli exit date - 026 ki rejoin log row se
create or replace function public.ddd_ce_prev_exit(p_student uuid, p_rejoined date) returns date
language sql stable as $$
  select l.old_period_to from public.ddd_dues_void_log l
   where l.student_id = p_student and l.due_id is null and l.action = 'rejoin' and l.new_period_from = p_rejoined
   order by l.id desc limit 1;
$$;

-- us DATE ko har hostel ke occupants, unme staff kitne, aur kaun kaun (ids)
create or replace function public.ddd_ce_occupants(p_date date, p_hostels uuid[])
returns table (hostel_id uuid, occupants int, staff_occupants int, counted_ids uuid[])
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if exists (select 1 from pg_attribute a where a.attrelid = 'public.students'::regclass
              and a.attname = 'occupant_type' and a.attnum > 0 and not a.attisdropped) then
    return query
    select h.hid, count(s.id)::int, (count(s.id) filter (where s.occupant_type = 'staff'))::int,
           coalesce(array_agg(s.id order by s.id) filter (where s.id is not null), '{}'::uuid[])
      from unnest(p_hostels) as h(hid)
      left join public.students s
        on s.hostel_id = h.hid
       and public.ddd_ce_is_present(s.joining_date, s.created_at, s.exit_date, s.status, s.merged_into, s.rejoined_on,
                                    case when s.rejoined_on is not null then public.ddd_ce_prev_exit(s.id, s.rejoined_on) end, p_date)
     group by h.hid;
  else
    -- 029 nahi laga = sab student
    return query
    select h.hid, count(s.id)::int, 0,
           coalesce(array_agg(s.id order by s.id) filter (where s.id is not null), '{}'::uuid[])
      from unnest(p_hostels) as h(hid)
      left join public.students s
        on s.hostel_id = h.hid
       and public.ddd_ce_is_present(s.joining_date, s.created_at, s.exit_date, s.status, s.merged_into, s.rejoined_on,
                                    case when s.rejoined_on is not null then public.ddd_ce_prev_exit(s.id, s.rejoined_on) end, p_date)
     group by h.hid;
  end if;
end $$;

-- split plan (preview, save, recalc sab yahi). Saare checks yahin.
--   p_id diya, p_recount false, date aur hostels wahi = saved occupants hi (sirf amount ka naya hissa)
--   warna us date ke occupants dobara gine jaate hain
create or replace function public.ddd_ce_plan(p_id uuid, p_date date, p_total numeric, p_hostels uuid[], p_recount boolean)
returns table (hostel_id uuid, hostel_code text, hostel_name text, occupants int, staff_occupants int,
               occupants_total int, share numeric, counted_now boolean, counted_ids uuid[])
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_today   date := (now() at time zone 'Asia/Kolkata')::date;
  v_total   numeric(12,2);
  v_paise   bigint;
  v_hostels uuid[];
  v_missing uuid;
  v_old_dt  date;
  v_old_hs  uuid[];
  v_stored  boolean := false;
  v_counts  jsonb;
  v_occ     bigint;
begin
  if p_date is null then
    raise exception 'Expense ki date daalein.' using errcode = '22023';
  end if;
  if p_date > v_today then
    raise exception 'Aage ki date (%) ka common expense nahi ban sakta. Aaj ya pehle ki date daalein.',
      to_char(p_date, 'DD-MM-YYYY') using errcode = '22023';
  end if;
  if p_total is null or round(p_total, 2) <= 0 then
    raise exception 'Total amount 0 se zyada hona chahiye.' using errcode = '22023';
  end if;
  if round(p_total, 2) >= 10000000000 then
    raise exception 'Total amount bahut bada hai.' using errcode = '22023';
  end if;
  v_total := round(p_total, 2);
  v_paise := (v_total * 100)::bigint;

  v_hostels := (select coalesce(array_agg(distinct u.x order by u.x), '{}'::uuid[])
                  from unnest(coalesce(p_hostels, '{}'::uuid[])) as u(x) where u.x is not null);
  if cardinality(v_hostels) = 0 then
    raise exception 'Kam se kam ek hostel chunein.' using errcode = '22023';
  end if;
  v_missing := (select u.x from unnest(v_hostels) as u(x)
                 where not exists (select 1 from public.hostels h where h.id = u.x) limit 1);
  if v_missing is not null then
    raise exception 'Chuna gaya hostel nahi mila (%). Page refresh karke dobara chunein.', v_missing using errcode = '22023';
  end if;

  if p_id is not null and not coalesce(p_recount, false) then
    v_old_dt := (select c.expense_date from public.common_expenses c where c.id = p_id and c.removed_at is null);
    v_old_hs := (select array_agg(ch.hostel_id order by ch.hostel_id)
                   from public.common_expense_hostels ch where ch.common_expense_id = p_id);
    v_stored := v_old_dt is not null and v_old_dt = p_date and v_old_hs = v_hostels;
  end if;

  if v_stored then
    v_counts := (select jsonb_agg(jsonb_build_object('h', ch.hostel_id, 'o', ch.occupants, 's', ch.staff_occupants,
                                                     'ids', to_jsonb(ch.counted_ids)))
                   from public.common_expense_hostels ch where ch.common_expense_id = p_id);
  else
    v_counts := (select jsonb_agg(jsonb_build_object('h', o.hostel_id, 'o', o.occupants, 's', o.staff_occupants,
                                                     'ids', to_jsonb(o.counted_ids)))
                   from public.ddd_ce_occupants(p_date, v_hostels) o);
  end if;
  v_occ := (select coalesce(sum((e ->> 'o')::bigint), 0) from jsonb_array_elements(coalesce(v_counts, '[]'::jsonb)) e);
  if v_occ = 0 then
    raise exception 'Chune gaye hostels mein % ko koi occupant nahi tha, isliye split nahi ho sakta.',
      to_char(p_date, 'DD-MM-YYYY') using errcode = '22023';
  end if;

  -- largest remainder, paise mein: sabko neeche round, bache paise sabse bade remainder wale ko
  -- (barabar remainder = zyada occupants, phir hostel code)
  return query
  with o as (
    select x.h, x.o, x.s, x.ids from jsonb_to_recordset(v_counts) as x(h uuid, o int, s int, ids uuid[])
  ), t as (
    select sum(o.o)::bigint as tot from o
  ), b as (
    select o.h, o.o, o.s, o.ids, t.tot, (v_paise * o.o) / t.tot as base, (v_paise * o.o) % t.tot as rem
      from o cross join t
  ), r as (
    select b.h, b.o, b.s, b.ids, b.tot, b.base, hh.code, hh.name,
           row_number() over (order by b.rem desc, b.o desc, hh.code, b.h) as rn,
           v_paise - sum(b.base) over () as leftover
      from b join public.hostels hh on hh.id = b.h
  )
  select r.h, r.code, r.name, r.o, r.s, r.tot::int,
         ((r.base + case when r.rn <= r.leftover then 1 else 0 end)::numeric / 100)::numeric(12,2),
         not v_stored, coalesce(r.ids, '{}'::uuid[])
    from r
   order by r.code, r.h;
end $$;

-- likhna (naya / edit / recalc). Permission check bahar wale function karte hain.
create or replace function public.ddd_ce_apply(
  p_id uuid, p_date date, p_category text, p_description text, p_total numeric,
  p_mode text, p_paid_to text, p_remarks text, p_hostels uuid[], p_recount boolean, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_id     uuid := coalesce(p_id, gen_random_uuid());
  v_old    public.common_expenses;
  v_new    boolean := true;
  v_total  numeric(12,2);
  v_cat    text := nullif(btrim(coalesce(p_category, '')), '');
  v_desc   text := nullif(btrim(coalesce(p_description, '')), '');
  v_mode   text := nullif(btrim(coalesce(p_mode, '')), '');
  v_paid   text := nullif(btrim(coalesce(p_paid_to, '')), '');
  v_rem    text := nullif(btrim(coalesce(p_remarks, '')), '');
  v_split  jsonb;
  v_n      int;
  v_tot    int;
  v_now    boolean;
  v_before jsonb := '{}'::jsonb;
  v_after  jsonb;
  v_pchg   boolean := false;
  v_chg    boolean;
  v_note   text;
  v_eid    uuid;
  v_keep   uuid[] := '{}'::uuid[];
  v_all    uuid[] := '{}'::uuid[];
  r        record;
begin
  if v_cat is null then
    raise exception 'Category chunein.' using errcode = '22023';
  end if;

  -- pehle se hai? row lock, taaki do log ek saath badlein to gadbad na ho
  perform 1 from public.common_expenses c where c.id = v_id for update;
  if found then
    v_old := (select c from public.common_expenses c where c.id = v_id);
    if v_old.removed_at is not null then
      raise exception 'Ye common expense hata diya gaya hai, ab badla nahi ja sakta.' using errcode = '22023';
    end if;
    v_new := false;
  end if;

  -- split (date, amount, hostels, occupants ke saare checks iske andar)
  v_split := (select jsonb_agg(to_jsonb(s) order by s.hostel_code, s.hostel_id)
                from public.ddd_ce_plan(case when v_new then null else v_id end, p_date, p_total, p_hostels, p_recount) s);
  v_total := round(p_total, 2);

  if v_new then
    insert into public.common_expenses (id, expense_date, category, description, total_amount, mode, paid_to, remarks,
                                        created_by, created_at)
    values (v_id, p_date, v_cat, v_desc, v_total, v_mode, v_paid, v_rem, v_uid, now())
    on conflict (id) do nothing;
    if not found then
      -- isi id se abhi abhi doosri request ne bana diya (double tap) - ab ye edit hai
      perform 1 from public.common_expenses c where c.id = v_id for update;
      v_old := (select c from public.common_expenses c where c.id = v_id);
      if v_old.removed_at is not null then
        raise exception 'Ye common expense hata diya gaya hai, ab badla nahi ja sakta.' using errcode = '22023';
      end if;
      v_new := false;
      v_split := (select jsonb_agg(to_jsonb(s) order by s.hostel_code, s.hostel_id)
                    from public.ddd_ce_plan(v_id, p_date, p_total, p_hostels, p_recount) s);
    end if;
  end if;

  v_n   := jsonb_array_length(v_split);
  v_tot := (v_split -> 0 ->> 'occupants_total')::int;
  v_now := (v_split -> 0 ->> 'counted_now')::boolean;

  if not v_new then
    v_before := (select coalesce(jsonb_object_agg(h.code, jsonb_build_object('occupants', ch.occupants, 'share', ch.share)), '{}'::jsonb)
                   from public.common_expense_hostels ch join public.hostels h on h.id = ch.hostel_id
                  where ch.common_expense_id = v_id);
    v_pchg := (v_old.expense_date, v_old.category, v_old.description, v_old.total_amount, v_old.mode, v_old.paid_to, v_old.remarks)
              is distinct from (p_date, v_cat, v_desc, v_total, v_mode, v_paid, v_rem);
  end if;

  for r in
    select x.hostel_id, x.occupants, x.staff_occupants, x.share, x.counted_ids
      from jsonb_to_recordset(v_split) as x(hostel_id uuid, occupants int, staff_occupants int, share numeric, counted_ids uuid[])
  loop
    v_all := v_all || r.hostel_id;

    insert into public.common_expense_hostels as ch (common_expense_id, hostel_id, occupants, staff_occupants, share, counted_ids)
    values (v_id, r.hostel_id, r.occupants, r.staff_occupants, r.share, coalesce(r.counted_ids, '{}'::uuid[]))
    on conflict (common_expense_id, hostel_id) do update
      set occupants = excluded.occupants, staff_occupants = excluded.staff_occupants, share = excluded.share,
          counted_ids = excluded.counted_ids, updated_at = now()
      where (ch.occupants, ch.staff_occupants, ch.share, ch.counted_ids)
            is distinct from (excluded.occupants, excluded.staff_occupants, excluded.share, excluded.counted_ids);

    if r.share > 0 then
      v_keep := v_keep || r.hostel_id;
      v_note := 'Common Expense (Split)' || coalesce(': ' || v_desc, '')
             || ' | Total Rs ' || public.ddd_ce_inr(v_total) || ' / ' || v_n
             || case when v_n = 1 then ' hostel' else ' hostels' end
             || ' | Occupants ' || r.occupants || ' of ' || v_tot
             || coalesce(' | ' || v_rem, '');
      v_eid := (select e.id from public.expenses e where e.common_expense_id = v_id and e.hostel_id = r.hostel_id);
      if v_eid is null then
        insert into public.expenses (hostel_id, expense_date, category, amount, paid_to, mode, remarks, status,
                                     added_by, approved_by, created_by,
                                     common_expense_id, common_total, common_hostels, common_occupants, common_occupants_total)
        values (r.hostel_id, p_date, v_cat, r.share, v_paid, v_mode, v_note, 'approved',
                v_uid, v_uid, v_uid,
                v_id, v_total, v_n, r.occupants, v_tot);
      else
        update public.expenses e
           set expense_date = p_date, category = v_cat, amount = r.share, paid_to = v_paid, mode = v_mode,
               remarks = v_note, status = 'approved', approved_by = coalesce(v_uid, e.approved_by),
               common_total = v_total, common_hostels = v_n, common_occupants = r.occupants,
               common_occupants_total = v_tot
         where e.id = v_eid
           and (e.expense_date, e.category, e.amount, e.paid_to, e.mode, e.remarks, e.status,
                e.common_total, e.common_hostels, e.common_occupants, e.common_occupants_total)
               is distinct from
               (p_date, v_cat, r.share, v_paid, v_mode, v_note, 'approved'::text,
                v_total, v_n, r.occupants, v_tot);
      end if;
    end if;
  end loop;

  -- jo hostel hata diye ya jinka hissa 0 hua, unki expense row aur breakup hatao
  delete from public.expenses e where e.common_expense_id = v_id and not (e.hostel_id = any (v_keep));
  delete from public.common_expense_hostels ch where ch.common_expense_id = v_id and not (ch.hostel_id = any (v_all));

  v_after := (select coalesce(jsonb_object_agg(h.code, jsonb_build_object('occupants', ch.occupants, 'share', ch.share)), '{}'::jsonb)
                from public.common_expense_hostels ch join public.hostels h on h.id = ch.hostel_id
               where ch.common_expense_id = v_id);
  v_chg := v_new or v_before is distinct from v_after;

  if not v_new and (v_pchg or (p_reason is null and v_chg)) then
    update public.common_expenses
       set expense_date = p_date, category = v_cat, description = v_desc, total_amount = v_total,
           mode = v_mode, paid_to = v_paid, remarks = v_rem, updated_by = v_uid, updated_at = now()
     where id = v_id;
  end if;
  if not v_new and p_reason is not null and v_chg then
    update public.common_expenses
       set recalc_by = v_uid, recalc_at = now(), recalc_reason = left(p_reason, 300)
     where id = v_id;
  end if;

  return jsonb_build_object('id', v_id, 'created', v_new, 'changed', v_chg or v_pchg, 'split_changed', v_chg,
                            'counted_now', v_now, 'before', v_before, 'after', v_after);
end $$;

-- ---------------------------------------------------------------------
-- STEP 6. app wale functions
-- ---------------------------------------------------------------------

-- ek hostel ke us date ke occupants (Director, Manager, Accountant = koi bhi hostel, Warden = sirf apna)
create or replace function public.ddd_occupants_on(p_hostel uuid, p_date date) returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if p_hostel is null or p_date is null then
    raise exception 'Hostel aur date dono chahiye.' using errcode = '22023';
  end if;
  if not (public.ddd_ce_can_manage()
          or (auth.uid() is not null
              and (public.is_director() or public.is_accountant() or p_hostel in (select public.my_hostels())))) then
    raise exception 'Is hostel ka data dekhne ki permission nahi hai.' using errcode = '42501';
  end if;
  return coalesce((select o.occupants from public.ddd_ce_occupants(p_date, array[p_hostel]) o), 0);
end $$;

-- save se pehle split dikhana (kuch save nahi hota). Edit form p_id bheje to wahi rule jo save mein.
create or replace function public.ddd_common_expense_preview(p_date date, p_total numeric, p_hostels uuid[], p_id uuid default null)
returns table (hostel_id uuid, hostel_code text, hostel_name text, occupants int, staff_occupants int,
               occupants_total int, share numeric, counted_now boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if not public.ddd_ce_can_manage() then
    raise exception 'Common Expense sirf Director ya Manager bana sakte hain.' using errcode = '42501';
  end if;
  return query
  select s.hostel_id, s.hostel_code, s.hostel_name, s.occupants, s.staff_occupants, s.occupants_total, s.share, s.counted_now
    from public.ddd_ce_plan(p_id, p_date, p_total, p_hostels, false) s;
end $$;

-- naya banana (p_id khali ya naya uuid) ya badalna (p_id = purana common expense). Hamesha approved.
create or replace function public.ddd_common_expense_save(
  p_id          uuid,
  p_date        date,
  p_category    text,
  p_description text,
  p_total       numeric,
  p_mode        text,
  p_paid_to     text,
  p_remarks     text,
  p_hostels     uuid[]
) returns uuid
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.ddd_ce_can_manage() then
    raise exception 'Common Expense sirf Director ya Manager bana / badal sakte hain.' using errcode = '42501';
  end if;
  return (public.ddd_ce_apply(p_id, p_date, p_category, p_description, p_total, p_mode, p_paid_to, p_remarks,
                              p_hostels, false, null) ->> 'id')::uuid;
end $$;

-- hatana = saare hisse expenses se hat jaate hain, parent par removed_at / removed_by
-- (breakup history ke liye rehta hai, report mein nahi aata). Doosri baar = 0.
create or replace function public.ddd_common_expense_delete(p_id uuid) returns int
language plpgsql volatile security definer set search_path = public as $$
declare
  v_n int;
begin
  if not public.ddd_ce_can_manage() then
    raise exception 'Common Expense sirf Director ya Manager hata sakte hain.' using errcode = '42501';
  end if;
  perform 1 from public.common_expenses c where c.id = p_id for update;
  if not found then
    raise exception 'Common expense nahi mila. Page refresh karein.' using errcode = '22023';
  end if;
  if (select c.removed_at from public.common_expenses c where c.id = p_id) is not null then
    return 0;
  end if;
  delete from public.expenses e where e.common_expense_id = p_id;
  get diagnostics v_n = row_count;
  update public.common_expenses
     set removed_at = now(), removed_by = auth.uid(), updated_at = now(), updated_by = auth.uid()
   where id = p_id;
  return v_n;
end $$;

-- Recalculate button: usi date aur hostels ke occupants aaj ke data se dobara (jaise late joiner)
create or replace function public.ddd_common_expense_recalc(p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_old public.common_expenses;
begin
  if not public.ddd_ce_can_manage() then
    raise exception 'Common Expense sirf Director ya Manager recalculate kar sakte hain.' using errcode = '42501';
  end if;
  perform 1 from public.common_expenses c where c.id = p_id for update;
  v_old := (select c from public.common_expenses c where c.id = p_id);
  if v_old.id is null or v_old.removed_at is not null then
    raise exception 'Common expense nahi mila ya hata diya gaya hai.' using errcode = '22023';
  end if;
  return public.ddd_ce_apply(v_old.id, v_old.expense_date, v_old.category, v_old.description, v_old.total_amount,
                             v_old.mode, v_old.paid_to, v_old.remarks,
                             array(select ch.hostel_id from public.common_expense_hostels ch where ch.common_expense_id = p_id),
                             true, 'Recalculate');
end $$;

-- ek student badla / duplicate hataya (031) = jin chalu common expenses mein woh gina gaya tha,
-- ya ab gina jaana chahiye, unka split dobara (purane bhi, R7 M8). Returns kitne split badle.
-- Sirf andar se (031 ka function, SQL Editor). Sab 0 occupant ho jaayein to error (031 tab kuch nahi badalta).
create or replace function public.ddd_cexp_recalc_for_student(p_student uuid) returns int
language plpgsql volatile security definer set search_path = public as $$
declare
  r       record;
  v_res   jsonb;
  v_n     int := 0;
  v_why   text;
begin
  if p_student is null then
    return 0;
  end if;
  v_why := (select case when s.merged_into is not null then 'Duplicate hataya: ' else 'Student badla: ' end
                   || coalesce(nullif(btrim(s.full_name), ''), s.id::text)
              from public.students s where s.id = p_student);
  for r in
    select ce.id, ce.expense_date, ce.category, ce.description, ce.total_amount, ce.mode, ce.paid_to, ce.remarks
      from public.common_expenses ce
     where ce.removed_at is null
       and exists (select 1
                     from public.common_expense_hostels ch
                     left join public.students s on s.id = p_student
                    where ch.common_expense_id = ce.id
                      and (p_student = any (ch.counted_ids))
                          is distinct from
                          coalesce(s.hostel_id = ch.hostel_id
                                   and public.ddd_ce_is_present(s.joining_date, s.created_at, s.exit_date, s.status, s.merged_into,
                                                                s.rejoined_on,
                                                                case when s.rejoined_on is not null then public.ddd_ce_prev_exit(s.id, s.rejoined_on) end,
                                                                ce.expense_date), false))
     order by ce.expense_date, ce.created_at, ce.id
     for update of ce
  loop
    v_res := public.ddd_ce_apply(r.id, r.expense_date, r.category, r.description, r.total_amount, r.mode, r.paid_to, r.remarks,
                                 array(select ch.hostel_id from public.common_expense_hostels ch where ch.common_expense_id = r.id),
                                 true, coalesce(v_why, 'Student hataya: ' || p_student::text));
    if coalesce((v_res ->> 'split_changed')::boolean, false) then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- report: har chalu common expense ki har hostel ki ek line.
-- Director, Manager, Accountant = sab hostels. Warden = sirf apne hostel ki line.
-- occupants_now = aaj ke data se us date ke occupants. is_stale = kisi hostel mein alag (Recalculate dikhayein).
create or replace function public.ddd_common_expense_report(p_from date default null, p_to date default null)
returns table (
  common_expense_id uuid, expense_date date, category text, description text, total_amount numeric,
  hostels_count int, hostel_id uuid, hostel_code text, hostel_name text,
  occupants int, staff_occupants int, occupants_total int, share numeric, expense_id uuid,
  occupants_now int, is_stale boolean,
  mode text, paid_to text, remarks text,
  created_by_name text, created_at timestamptz, updated_by_name text, updated_at timestamptz,
  recalc_by_name text, recalc_at timestamptz, recalc_reason text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_all boolean;
begin
  if auth.uid() is null and not public.ddd_ce_can_manage() then
    raise exception 'Login zaroori hai.' using errcode = '42501';
  end if;
  v_all := public.ddd_ce_can_manage() or public.is_director() or public.is_accountant();
  return query
  with ce as (
    select c.id, c.expense_date, c.category, c.description, c.total_amount, c.mode, c.paid_to, c.remarks,
           c.created_by, c.created_at, c.updated_by, c.updated_at, c.recalc_by, c.recalc_at, c.recalc_reason,
           array(select x.hostel_id from public.common_expense_hostels x where x.common_expense_id = c.id) as hs
      from public.common_expenses c
     where c.removed_at is null
       and (p_from is null or c.expense_date >= p_from)
       and (p_to is null or c.expense_date <= p_to)
       and (v_all or exists (select 1 from public.common_expense_hostels x
                              where x.common_expense_id = c.id and x.hostel_id in (select public.my_hostels())))
  ), nw as (
    select ce.id as cid, o.hostel_id as hid, o.occupants as occ_now
      from ce cross join lateral public.ddd_ce_occupants(ce.expense_date, ce.hs) o
  ), agg as (
    select ch.common_expense_id as cid, count(*)::int as n, sum(ch.occupants)::int as occ,
           bool_or(ch.occupants is distinct from nw.occ_now) as stale
      from public.common_expense_hostels ch
      join ce on ce.id = ch.common_expense_id
      left join nw on nw.cid = ch.common_expense_id and nw.hid = ch.hostel_id
     group by ch.common_expense_id
  )
  select ce.id, ce.expense_date, ce.category, ce.description, ce.total_amount,
         agg.n, ch.hostel_id, h.code, h.name,
         ch.occupants, ch.staff_occupants, agg.occ, ch.share, e.id,
         nw.occ_now, agg.stale,
         ce.mode, ce.paid_to, ce.remarks,
         coalesce(cu.full_name, case when ce.created_by is null then 'SQL Editor' end), ce.created_at,
         coalesce(uu.full_name, case when ce.updated_at is not null and ce.updated_by is null then 'SQL Editor' end), ce.updated_at,
         coalesce(ru.full_name, case when ce.recalc_at is not null and ce.recalc_by is null then 'SQL Editor' end), ce.recalc_at,
         ce.recalc_reason
    from ce
    join public.common_expense_hostels ch on ch.common_expense_id = ce.id
    join public.hostels h on h.id = ch.hostel_id
    join agg on agg.cid = ce.id
    left join nw on nw.cid = ce.id and nw.hid = ch.hostel_id
    left join public.expenses e on e.common_expense_id = ce.id and e.hostel_id = ch.hostel_id
    left join public.users cu on cu.id = ce.created_by
    left join public.users uu on uu.id = ce.updated_by
    left join public.users ru on ru.id = ce.recalc_by
   where v_all or ch.hostel_id in (select public.my_hostels())
   order by ce.expense_date, ce.created_at, ce.id, h.code;
end $$;

-- ---------------------------------------------------------------------
-- STEP 7. guards
-- ---------------------------------------------------------------------
-- hisse wali expense row app se seedha nahi badal / hat sakti, aur app common columns nahi bhar sakta.
-- SECURITY DEFINER nahi (ddd_is_api_caller ko app ka role dikhna chahiye). Upar ke functions
-- owner ke roop mein chalte hain aur hostel delete ka cascade bhi, isliye unhe nahi rokta.
create or replace function public.ddd_guard_common_expense_share() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.ddd_is_api_caller() then
    if tg_op in ('UPDATE', 'DELETE') and old.common_expense_id is not null then
      raise exception 'Ye Common Expense (Split) ka hissa hai. Ise sirf Common Expense screen se badlein ya hatayein.'
        using errcode = '42501';
    end if;
    if tg_op in ('INSERT', 'UPDATE')
       and (new.common_expense_id is not null or new.common_total is not null or new.common_hostels is not null
            or new.common_occupants is not null or new.common_occupants_total is not null) then
      raise exception 'Common Expense ka hissa sirf Common Expense screen se banta hai.' using errcode = '42501';
    end if;
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end $$;

drop trigger if exists trg_expenses_common_guard on public.expenses;
create trigger trg_expenses_common_guard before insert or update or delete on public.expenses
  for each row execute function public.ddd_guard_common_expense_share();

-- hostel delete - kisi chalu common expense mein hai to nahi (L1). Sab ke liye, SQL Editor bhi.
create or replace function public.ddd_guard_hostel_common_expense() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n bigint;
begin
  n := (select count(distinct ch.common_expense_id)
          from public.common_expense_hostels ch
          join public.common_expenses c on c.id = ch.common_expense_id
         where ch.hostel_id = old.id and c.removed_at is null);
  if n > 0 then
    raise exception 'Hostel % hataya nahi ja sakta - yeh % Common Expense ke split mein hai. Pehle Common Expense edit karke is hostel ko usme se hatayein.',
      coalesce(nullif(old.code, ''), old.name), n using errcode = '42501';
  end if;
  return old;
end $$;

drop trigger if exists trg_hostels_common_expense_guard on public.hostels;
create trigger trg_hostels_common_expense_guard before delete on public.hostels
  for each row execute function public.ddd_guard_hostel_common_expense();

-- ---------------------------------------------------------------------
-- STEP 8. rights (Supabase naye functions anon ko bhi deta hai, isliye wapas lo)
-- ---------------------------------------------------------------------
revoke all on function public.ddd_ce_can_manage() from public, anon, authenticated;
revoke all on function public.ddd_ce_inr(numeric) from public, anon, authenticated;
revoke all on function public.ddd_ce_is_present(date, timestamptz, date, text, uuid, date, date, date) from public, anon, authenticated;
revoke all on function public.ddd_ce_prev_exit(uuid, date) from public, anon, authenticated;
revoke all on function public.ddd_ce_occupants(date, uuid[]) from public, anon, authenticated;
revoke all on function public.ddd_ce_plan(uuid, date, numeric, uuid[], boolean) from public, anon, authenticated;
revoke all on function public.ddd_ce_apply(uuid, date, text, text, numeric, text, text, text, uuid[], boolean, text) from public, anon, authenticated;
revoke all on function public.ddd_cexp_recalc_for_student(uuid) from public, anon, authenticated;
revoke all on function public.ddd_guard_common_expense_share() from public, anon, authenticated;
revoke all on function public.ddd_guard_hostel_common_expense() from public, anon, authenticated;

revoke all on function public.ddd_occupants_on(uuid, date) from public, anon;
revoke all on function public.ddd_common_expense_preview(date, numeric, uuid[], uuid) from public, anon;
revoke all on function public.ddd_common_expense_save(uuid, date, text, text, numeric, text, text, text, uuid[]) from public, anon;
revoke all on function public.ddd_common_expense_delete(uuid) from public, anon;
revoke all on function public.ddd_common_expense_recalc(uuid) from public, anon;
revoke all on function public.ddd_common_expense_report(date, date) from public, anon;
grant execute on function public.ddd_occupants_on(uuid, date) to authenticated;
grant execute on function public.ddd_common_expense_preview(date, numeric, uuid[], uuid) to authenticated;
grant execute on function public.ddd_common_expense_save(uuid, date, text, text, numeric, text, text, text, uuid[]) to authenticated;
grant execute on function public.ddd_common_expense_delete(uuid) to authenticated;
grant execute on function public.ddd_common_expense_recalc(uuid) to authenticated;
grant execute on function public.ddd_common_expense_report(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- STEP 9. VERIFY (kuch bhi missing ho to sab rollback, kuch nahi badlega)
-- ---------------------------------------------------------------------
do $verify$
declare
  n int;
  t text;
begin
  n := (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'expenses'
           and column_name in ('common_expense_id', 'common_total', 'common_hostels', 'common_occupants', 'common_occupants_total'));
  if n <> 5 then raise exception '030 VERIFY FAIL: expenses ke naye columns % of 5', n; end if;

  n := (select count(*) from pg_trigger
         where not tgisinternal
           and (tgrelid, tgname) in (('public.expenses'::regclass, 'trg_expenses_common_guard'),
                                     ('public.hostels'::regclass, 'trg_hostels_common_expense_guard'),
                                     ('public.common_expenses'::regclass, 'trg_common_expenses_audit'),
                                     ('public.common_expense_hostels'::regclass, 'trg_common_expense_hostels_audit')));
  if n <> 4 then raise exception '030 VERIFY FAIL: triggers % of 4', n; end if;

  if not (select relrowsecurity from pg_class where oid = 'public.common_expenses'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.common_expense_hostels'::regclass) then
    raise exception '030 VERIFY FAIL: RLS off';
  end if;
  foreach t in array array['insert', 'update', 'delete'] loop
    if has_table_privilege('authenticated', 'public.common_expenses', t)
       or has_table_privilege('authenticated', 'public.common_expense_hostels', t) then
      raise exception '030 VERIFY FAIL: app (authenticated) can % common tables directly', t;
    end if;
  end loop;
  if has_table_privilege('anon', 'public.common_expenses', 'select') or has_table_privilege('anon', 'public.common_expense_hostels', 'select') then
    raise exception '030 VERIFY FAIL: anon can read common tables';
  end if;
  foreach t in array array['public.ddd_occupants_on(uuid,date)', 'public.ddd_common_expense_preview(date,numeric,uuid[],uuid)',
                           'public.ddd_common_expense_save(uuid,date,text,text,numeric,text,text,text,uuid[])',
                           'public.ddd_common_expense_delete(uuid)', 'public.ddd_common_expense_recalc(uuid)',
                           'public.ddd_common_expense_report(date,date)'] loop
    if has_function_privilege('anon', t, 'execute') then
      raise exception '030 VERIFY FAIL: anon can execute %', t;
    end if;
    if not has_function_privilege('authenticated', t, 'execute') then
      raise exception '030 VERIFY FAIL: app cannot execute %', t;
    end if;
  end loop;
  foreach t in array array['public.ddd_ce_can_manage()', 'public.ddd_ce_occupants(date,uuid[])',
                           'public.ddd_ce_is_present(date,timestamptz,date,text,uuid,date,date,date)', 'public.ddd_ce_prev_exit(uuid,date)',
                           'public.ddd_ce_plan(uuid,date,numeric,uuid[],boolean)',
                           'public.ddd_ce_apply(uuid,date,text,text,numeric,text,text,text,uuid[],boolean,text)',
                           'public.ddd_cexp_recalc_for_student(uuid)',
                           'public.ddd_guard_common_expense_share()', 'public.ddd_guard_hostel_common_expense()'] loop
    if has_function_privilege('authenticated', t, 'execute') or has_function_privilege('anon', t, 'execute') then
      raise exception '030 VERIFY FAIL: internal function % is callable from the app', t;
    end if;
  end loop;
  -- purani expense rows bilkul waisi (koi common column bhara nahi gaya)
  n := (select count(*) from public.expenses e
         where e.common_expense_id is null
           and (e.common_total is not null or e.common_hostels is not null or e.common_occupants is not null
                or e.common_occupants_total is not null));
  if n > 0 then raise exception '030 VERIFY FAIL: % normal expense rows have common columns', n; end if;
end
$verify$;

commit;

notify pgrst, 'reload schema';

-- result (sirf padhna) - owner yahi dekhe
select '030 common expense laga' as kya,
       (select count(*) from public.common_expenses where removed_at is null) as chalu_common_expenses,
       (select count(*) from public.expenses where common_expense_id is not null) as hisse_wali_expense_rows,
       case when to_regprocedure('public.ddd_can(text)') is not null then 'Director + Manager'
            else 'sirf Director (027 nahi laga)' end as kaun_bana_sakta,
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'students' and column_name = 'occupant_type')
            then 'haan (students + bed wale staff)' else 'nahi (029 nahi laga, sab student gine jaate hain)' end as staff_alag_gina;

-- ---------- ROLLBACK ----------
-- Is migration ko wapas lena ho to 030_undo.sql chalayein (ek transaction, do baar safe).
--  - Koi common expense nahi bana ho to sab kuch bilkul pehle jaisa (tables, columns, functions, triggers).
--  - Common expense ban chuke hon to undo RUK jaata hai. Tab undo file mein force_undo true karein -
--    tab copy backup_030 mein jaati hai aur hisse normal approved expense ban kar rehte hain
--    (kisi hostel ka kharcha ya dashboard total nahi badalta).
--  - 031 laga ho to pehle 031_undo.sql (ulta kram).
