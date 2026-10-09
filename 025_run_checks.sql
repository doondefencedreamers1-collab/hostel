-- =====================================================================
-- 025_run_checks.sql — Supabase SQL Editor mein STEP by STEP
-- (har STEP ka block alag select karke Run). Ye file koi data row nahi badalti.
-- 025 bhi koi data row nahi badalta (sirf ek naya read-only function).
-- =====================================================================

-- ---------- STEP 1: CONFIRM (read-only) — pehli 3 rows ok = true ----------
select 'helper auth_role() exists' chk, (to_regprocedure('public.auth_role()') is not null)::text ok
union all select 'helper my_hostels() exists', (to_regprocedure('public.my_hostels()') is not null)::text
union all select 'students columns present', ((select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'students'
      and column_name in ('full_name', 'father_name', 'mobile', 'parent_mobile', 'whatsapp',
                          'admission_number', 'hostel_id', 'status', 'joining_date')) = 9)::text
union all select 'info: 025 already run?', (to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)') is not null)::text
union all select 'info: active managers with a hostel', (select count(distinct u.id) from public.users u join public.roles r on r.id = u.role_id
    where r.name = 'manager' and coalesce(u.status, 'active') = 'active'
      and exists (select 1 from public.user_hostel_assignments a where a.user_id = u.id))::text;

-- 1b (info, read-only): kitne naam ek se zyada hostel mein hain (warden inhe ab tak nahi dekh pata tha)
select count(*) as names_in_more_than_one_hostel
from (select t.nm
        from (select regexp_replace(lower(coalesce(full_name, '')), '[^a-z0-9]', '', 'g') as nm, hostel_id
                from public.students) t
       where length(t.nm) >= 3
       group by t.nm
      having count(distinct t.hostel_id) > 1) x;

-- ---------- STEP 2: 025_find_similar_students.sql poori file chalayein ----------

-- ---------- STEP 3: VERIFY (read-only) — sab ok = true ----------
select 'function exists' chk, (to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)') is not null) ok
union all select 'security definer + stable', exists (select 1 from pg_proc p where p.oid = to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)')
                                                      and p.prosecdef and p.provolatile = 's')
union all select 'search_path = public', exists (select 1 from pg_proc p, unnest(coalesce(p.proconfig, '{}')) c
                                                 where p.oid = to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)')
                                                   and c = 'search_path=public')
union all select 'anon cannot run it', not has_function_privilege('anon', 'public.ddd_find_similar_students(text,text,text[],text)', 'execute')
union all select 'PUBLIC cannot run it', not coalesce((select p.proacl::text like '%,=X/%' or p.proacl::text like '{=X/%' or p.proacl is null
                                                      from pg_proc p where p.oid = to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)')), true)
union all select 'app (authenticated) can run it', has_function_privilege('authenticated', 'public.ddd_find_similar_students(text,text,text[],text)', 'execute')
union all select 'output = 6 small columns (no id / full phone)',
  (select array_agg(a order by n) from unnest((select p.proargnames from pg_proc p
     where p.oid = to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)'))) with ordinality as t(a, n))
  = array['p_name', 'p_father', 'p_phones', 'p_admission', 'hostel_code', 'status', 'full_name', 'joining_month', 'phone_last4', 'match']::text[];

-- ---------- STEP 4: VERIFY as real users — EK HI QUERY (read-only, kuch save nahi hota) ----------
-- Ek manager, director, accountant aur bina-role user "ban kar" function chalata hai
-- (set_config sirf is query ke liye; koi table / BEGIN / ROLLBACK nahi). Saari rows ok = true.
-- Users / students apne aap chune jaate hain (koi id / email hard-coded nahi).
-- Accountant login na ho to uski row nahi aati (theek hai).
-- Pehle wala temp-table STEP 4 Supabase SQL Editor mein 'relation v025 does not exist' deta tha.
with
mgr as (
  select u.id from public.users u join public.roles r on r.id = u.role_id
  where r.name = 'manager' and coalesce(u.status, 'active') = 'active'
    and exists (select 1 from public.user_hostel_assignments a where a.user_id = u.id)
  order by u.created_at, u.id limit 1
),
dir as (select u.id from public.users u join public.roles r on r.id = u.role_id where r.name = 'director' order by u.created_at, u.id limit 1),
acc as (select u.id from public.users u join public.roles r on r.id = u.role_id where r.name = 'accountant' order by u.created_at, u.id limit 1),
realph as (   -- asli phone wale students (placeholder number nahi)
  select st.id, st.full_name, st.father_name, st.admission_number, st.hostel_id,
         array[st.mobile, st.parent_mobile, st.whatsapp] as phones
  from public.students st
  where length(regexp_replace(lower(coalesce(st.full_name, '')), '[^a-z0-9]', '', 'g')) >= 3
    and exists (select 1 from unnest(array[st.mobile, st.parent_mobile, st.whatsapp]) x
                where length(regexp_replace(coalesce(x, ''), '[^0-9]', '', 'g')) >= 10
                  and right(regexp_replace(coalesce(x, ''), '[^0-9]', '', 'g'), 10) !~ '^(\d)\1{9}$'
                  and right(regexp_replace(coalesce(x, ''), '[^0-9]', '', 'g'), 10) not in ('1234567890', '0123456789', '9876543210'))
),
other as (    -- manager ke hostel ke BAHAR ka ek student
  select p.*, h.code from realph p join public.hostels h on h.id = p.hostel_id cross join mgr
  where p.hostel_id not in (select a.hostel_id from public.user_hostel_assignments a where a.user_id = mgr.id)
  order by p.id limit 1
),
own as (      -- manager ke APNE hostel ka ek student
  select p.* from realph p cross join mgr
  where p.hostel_id in (select a.hostel_id from public.user_hostel_assignments a where a.user_id = mgr.id)
  order by p.id limit 1
),
cases (ord, chk, uid, p_name, p_father, p_phones, p_adm, expect, want_code) as (
  select 1, 'manager sees other-hostel student (' || o.code || ')', m.id, o.full_name, o.father_name, o.phones, o.admission_number, 'some', o.code from mgr m, other o
  union all select 2, 'name only (no father/phone) = 0 rows', m.id, o.full_name, null, null, null, 'zero', null from mgr m, other o
  union all select 3, 'name < 3 letters = 0 rows', m.id, left(regexp_replace(o.full_name, '[^A-Za-z0-9]', '', 'g'), 2), o.father_name, o.phones, o.admission_number, 'zero', null from mgr m, other o
  union all select 4, 'manager never gets own-hostel rows', m.id, w.full_name, w.father_name, w.phones, w.admission_number, 'noown', null from mgr m, own w
  union all select 5, 'director gets 0 rows', d.id, o.full_name, o.father_name, o.phones, o.admission_number, 'zero', null from dir d, other o
  union all select 6, 'accountant gets 0 rows', a.id, o.full_name, o.father_name, o.phones, o.admission_number, 'zero', null from acc a, other o
  union all select 7, 'user without role gets 0 rows', gen_random_uuid(), o.full_name, o.father_name, o.phones, o.admission_number, 'zero', null from other o
),
res as (
  select c.ord, c.chk, c.expect, c.want_code, r.n, r.codes, r.own_n
  from cases c
  cross join lateral (select set_config('request.jwt.claim.sub', c.uid::text, true) as s) cfg   -- is query ke liye "us user ki tarah login"
  cross join lateral (
    select count(*) as n, string_agg(distinct f.hostel_code, ',') as codes,
           count(*) filter (where f.hostel_code in (select h.code from public.hostels h
                                                    join public.user_hostel_assignments a on a.hostel_id = h.id
                                                    where a.user_id = c.uid)) as own_n
    from public.ddd_find_similar_students(case when cfg.s is not null then c.p_name end, c.p_father, c.p_phones, c.p_adm) f
  ) r
)
select 0 as ord, 'function 025 installed' as chk,
       (to_regprocedure('public.ddd_find_similar_students(text,text,text[],text)') is not null) as ok, '' as detail
union all
select 0, 'active manager with a hostel found', exists (select 1 from mgr), ''
union all
select 0, 'anon cannot run it', not has_function_privilege('anon', 'public.ddd_find_similar_students(text,text,text[],text)', 'execute'), ''
union all
select ord, chk,
       case expect when 'some' then n >= 1 and coalesce(codes, '') like '%' || want_code || '%'
                   when 'zero' then n = 0
                   when 'noown' then own_n = 0 end,
       n || ' rows' || coalesce(' (' || codes || ')', '')
from res
order by 1, 2;
