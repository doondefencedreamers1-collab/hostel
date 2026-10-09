-- =====================================================================
-- 025_find_similar_students.sql   (needs 002 RLS helpers: auth_role, my_hostels)
-- DDD Hostel — duplicate student warning across hostels (Phase 1)
--
--  Warden (Manager) ko RLS se sirf apne hostel ke students dikhte hain. Isliye
--  "+ Add" par doosre hostel mein pehle se maujood student pakda nahi jaata tha
--  (1 Oct: 4 cross-hostel re-adds). Ye function sirf CHHOTA info deta hai:
--  hostel code, status, naam, joining month (YYYY-MM), matching phone ke last 4
--  digit, aur kaunsi cheez match hui. Koi id / poora phone / father nahi.
--
--  public.ddd_find_similar_students(p_name, p_father, p_phones, p_admission)
--   - sirf un hostels ke rows jo caller ko pehle se NAHI dikhte (my_hostels ke bahar)
--   - Director / Accountant: kuch nahi (unhe sab pehle se dikhta hai)
--   - login nahi / role nahi / koi hostel assign nahi: kuch nahi
--   - match = same naam (lower-case, sirf a-z0-9) AUR kam se kam ek:
--       same father (dono khali nahi; Mr./Shri/Late/S/O jaise title hata ke),
--       phone overlap (mobile / parent_mobile / whatsapp, last 10 digit,
--       9999999999 / 1234567890 / 0123456789 / 9876543210 ignore),
--       same admission no. (na / nil / 0 / - jaise placeholder ignore)
--   - naam (normalised) kam se kam 3 akshar; max 5 rows
--   - phone list mein 10 se zyada number (2-D array bhi gine jaate hain) = kuch nahi;
--     baaki mein sirf pehle 5 phone padhe jaate hain (app 3 hi bhejti hai)
--  Same rules app (index.html findDuplicates) mein bhi hain — dono saath badlein.
--
-- No data rows are changed. One transaction, safe to run twice.
-- Checks: 025_run_checks.sql   Undo: 025_undo.sql
-- =====================================================================
begin;

-- ---------- pre-checks ----------
do $$
begin
  if to_regprocedure('public.auth_role()') is null then raise exception '025 aborted: public.auth_role() missing'; end if;
  if to_regprocedure('public.my_hostels()') is null then raise exception '025 aborted: public.my_hostels() missing'; end if;
  if to_regprocedure('auth.uid()') is null then raise exception '025 aborted: auth.uid() missing'; end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'students'
         and column_name in ('full_name', 'father_name', 'mobile', 'parent_mobile', 'whatsapp',
                             'admission_number', 'hostel_id', 'status', 'joining_date')) <> 9 then
    raise exception '025 aborted: students table mein expected columns nahi mile';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'hostels' and column_name in ('id', 'code')) <> 2 then
    raise exception '025 aborted: hostels.id / hostels.code nahi mile';
  end if;
end $$;

-- ---------- function ----------
create or replace function public.ddd_find_similar_students(
  p_name text,
  p_father text default null,
  p_phones text[] default null,
  p_admission text default null)
returns table (hostel_code text, status text, full_name text, joining_month text, phone_last4 text, match text)
language sql
stable
security definer
set search_path = public
as $fn$
  with gate as (
    -- sirf hostel wala warden (Manager). Director / Accountant / bina role / bina login = kuch nahi
    select 1 as ok
    where auth.uid() is not null
      and public.auth_role() is not null
      and public.auth_role() not in ('director', 'accountant')
      and exists (select 1 from public.my_hostels())
  ),
  mine as (
    select m.hid from public.my_hostels() as m(hid)
  ),
  inp as (
    select
      regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]', '', 'g') as nm,
      regexp_replace(
        regexp_replace(
          regexp_replace(lower(coalesce(p_father, '')), '^\s+', ''),
          '^((mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''),
        '[^a-z0-9]', '', 'g') as fa0,
      regexp_replace(lower(coalesce(p_admission, '')), '[^a-z0-9]', '', 'g') as adm0
  ),
  q as (
    select nm,
           case when fa0 = '' or fa0 in ('na', 'nil', 'none', 'null', 'unknown', 'father') or fa0 ~ '^(.)\1*$'
                then '' else fa0 end as fa,
           case when adm0 = '' or adm0 in ('na', 'nil', 'none', 'null') or adm0 ~ '^(.)\1*$'
                then '' else adm0 end as adm
    from inp
    where length(nm) >= 3
      and coalesce(cardinality(p_phones), 0) <= 10   -- bahut lambi phone list (ya 2-D array) = kuch nahi
  ),
  q_ph as (
    -- form ke phone: last 10 digit, placeholder hata ke (sirf pehle 5; unnest 2-D array ko bhi flat ginta hai)
    select distinct right(d, 10) as ph
    from (select regexp_replace(coalesce(t.x, ''), '[^0-9]', '', 'g') as d
            from unnest(coalesce(p_phones, '{}'::text[])) with ordinality as t(x, n)
           where t.n <= 5) a
    where length(d) >= 10
      and right(d, 10) !~ '^(\d)\1{9}$'
      and right(d, 10) not in ('1234567890', '0123456789', '9876543210')
  ),
  cand as (
    -- same naam, aur hostel caller ka NAHI (apne hostel ke students app khud check karti hai)
    select s.hostel_id, s.status, s.full_name, s.joining_date, s.mobile, s.parent_mobile, s.whatsapp,
           regexp_replace(
             regexp_replace(
               regexp_replace(lower(coalesce(s.father_name, '')), '^\s+', ''),
               '^((mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''),
             '[^a-z0-9]', '', 'g') as sfa0,
           regexp_replace(lower(coalesce(s.admission_number, '')), '[^a-z0-9]', '', 'g') as sadm0
    from public.students s
    cross join q
    cross join gate
    where regexp_replace(lower(coalesce(s.full_name, '')), '[^a-z0-9]', '', 'g') = q.nm
      and not exists (select 1 from mine where mine.hid = s.hostel_id)
  ),
  scored as (
    select c.*,
           (q.fa <> '' and c.sfa0 = q.fa) as fa_hit,      -- q.fa khali / placeholder nahi, to match bhi asli
           (q.adm <> '' and c.sadm0 = q.adm) as adm_hit,
           (select min(right(z.d, 10))
              from (select regexp_replace(coalesce(y, ''), '[^0-9]', '', 'g') as d
                      from unnest(array[c.mobile, c.parent_mobile, c.whatsapp]) as y) z
             where length(z.d) >= 10
               and right(z.d, 10) in (select ph from q_ph)) as ph_hit
    from cand c
    cross join q
  )
  select coalesce(h.code, '?')::text as hostel_code,
         coalesce(sc.status, 'active')::text as status,
         sc.full_name::text as full_name,
         to_char(sc.joining_date, 'YYYY-MM') as joining_month,
         right(sc.ph_hit, 4) as phone_last4,
         concat_ws(', ',
           case when sc.fa_hit then 'same name + father' end,
           case when sc.ph_hit is not null then 'same name + phone' end,
           case when sc.adm_hit then 'same name + admission no.' end) as match
  from scored sc
  left join public.hostels h on h.id = sc.hostel_id
  where sc.fa_hit or sc.adm_hit or sc.ph_hit is not null
  order by (coalesce(sc.status, 'active') = 'left'), sc.joining_date desc nulls last, h.code
  limit 5;
$fn$;

comment on function public.ddd_find_similar_students(text, text, text[], text) is
  '025: Add Student par doosre hostel ka same student (sirf hostel code / status / naam / joining month / phone last 4). Manager only; Director/Accountant = 0 rows.';

revoke all on function public.ddd_find_similar_students(text, text, text[], text) from public, anon;
grant execute on function public.ddd_find_similar_students(text, text, text[], text) to authenticated;

commit;

notify pgrst, 'reload schema';

-- verify: 025_run_checks.sql STEP 3 + STEP 4 (sab ok = true)

-- ---------- ROLLBACK ----------
-- Wapas lena ho to 025_undo.sql chalayein (sirf ye function drop hota hai;
-- koi data row nahi badalti). App bina is function ke bhi chalti hai
-- (doosre hostel ka check chup-chaap skip, apne hostel ka check chalta rehta hai).
--   begin;
--   drop function if exists public.ddd_find_similar_students(text, text, text[], text);
--   commit;
--   notify pgrst, 'reload schema';
