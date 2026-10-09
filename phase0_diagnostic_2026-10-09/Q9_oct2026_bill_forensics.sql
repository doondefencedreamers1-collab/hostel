-- DDD Hostel - Phase 0 diagnostic - file Q9 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q9.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q9] =================================================================
-- Q9  OCTOBER 2026 KE BILL KAB, KAISE, KISKE LOGIN SE BANE
--     Har group = (banne ka din IST, generator ya payment, kiske app-session se).
--     Saath mein: kitne bill, kitne hostels cover hue, pehla/aakhri time,
--     unme se kitne students ab active nahi ('Active'/'ACTIVE' = active) / exit_date 1-Oct se pehle /
--     bill banne ke BAAD left hue / duplicate record / bed nahi.
--     Aakhri row = TOTAL. Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
oct as (
  select d.id, d.student_id, d.hostel_id, d.fee_amount, d.payable, d.pending, d.created_at, d.created_by
  from monthly_dues d
  where d.month >= date '2026-10-01' and d.month < date '2026-11-01'
),
dins as (
  select distinct on (l.entity_id) l.entity_id, l.user_id, true as logged
  from audit_logs l
  where l.entity_type = 'monthly_dues' and l.action = 'insert' and l.entity_id in (select id from oct)
  order by l.entity_id, l.created_at
),
st as (
  select s.id, s.full_name, s.father_name, s.mobile, s.parent_mobile, s.whatsapp, s.admission_number,
         case when s.status::text is null then 'NULL' when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
              when lower(s.status::text) like '%temp%' then 'temp' else 'other' end as k   -- coarse class: 'Active' / 'ACTIVE' count as active
  from students s
),
chg as (   -- latest change INTO the student's current class (pure re-casing like 'left' -> 'Left ' is not a change)
  select distinct on (c.sid) c.sid, c.at, c.user_id
  from (select l.entity_id as sid, l.created_at as at, l.user_id,
                case when l."before" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."before" ->> 'status') like '%temp%' then 'temp' else 'other' end as kb,
                case when l."after" ->> 'status' is null then 'NULL'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
                     when lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
                     when lower(l."after" ->> 'status') like '%temp%' then 'temp' else 'other' end as ka
        from audit_logs l where l.entity_type = 'students' and l.action = 'update'
          and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) c
  join st on st.id = c.sid
  where st.k <> 'active' and c.kb is distinct from c.ka and c.ka = st.k
  order by c.sid, c.at desc
),
sk0 as (   -- same name keys as Q5
  select st.id,
         coalesce(nullif(regexp_replace(lower(coalesce(st.full_name, '')), '[^[:alnum:]]+', '', 'g'), ''), lower(trim(coalesce(st.full_name, '')))) as nk,
         regexp_replace(regexp_replace(lower(coalesce(st.father_name, '')), '^(\s*(mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''), '[^[:alnum:]]+', '', 'g') as fk0,
         array[right(regexp_replace(coalesce(st.mobile, ''), '[^0-9]', '', 'g'), 10), right(regexp_replace(coalesce(st.parent_mobile, ''), '[^0-9]', '', 'g'), 10),
               right(regexp_replace(coalesce(st.whatsapp, ''), '[^0-9]', '', 'g'), 10)] as ph0,
         regexp_replace(lower(coalesce(st.admission_number, '')), '[^[:alnum:]]+', '', 'g') as ak0
  from st
),
bad as (   -- placeholder / shared phones and admission numbers (same rule as Q5)
  select 'phone' as kt, v from (
    select u.v, count(distinct sk0.nk) as n_names from sk0 cross join lateral unnest(sk0.ph0) u(v) where length(u.v) = 10 group by u.v) p
  where n_names > 3 or v ~ '^(\d)\1{9}$' or v in ('1234567890', '0123456789', '9876543210')
  union all
  select 'adm no', ak0 from sk0 where ak0 <> '' group by ak0
  having count(distinct nk) > 3 or ak0 ~ '^(.)\1*$' or ak0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'test', 'pending', 'new', 'notknown', 'unknown', 'nodata', 'notavailable')
),
sk as (
  select sk0.id, sk0.nk,
         case when sk0.fk0 ~ '^(.)\1*$' or sk0.fk0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'notknown', 'unknown', 'nodata', 'notavailable', 'father') then '' else sk0.fk0 end as fk,
         case when sk0.ak0 <> '' and sk0.ak0 not in (select v from bad where kt = 'adm no') then sk0.ak0 else '' end as ak,
         coalesce((select array_agg(distinct v) from unnest(sk0.ph0) u(v) where length(v) = 10 and v not in (select b.v from bad b where b.kt = 'phone')), '{}'::text[]) as ph
  from sk0
),
dup as (   -- students that have a twin record (same name + father, phone or admission no.)
  select distinct a.id
  from sk a join sk b on a.id <> b.id and a.nk <> '' and a.nk = b.nk
   and ((a.fk <> '' and a.fk = b.fk) or a.ph && b.ph or (a.ak <> '' and a.ak = b.ak))
),
x as (
  select o.*, s.status::text as status, st.k, s.exit_date, s.current_bed_id, c.at as left_at,
         (o.created_at at time zone 'Asia/Kolkata')::date as made_on,
         case when o.created_by is not null then 'payment RPC' else 'generator / SQL' end as origin,
         case when o.created_by is not null then coalesce(cu.full_name, cu.email, o.created_by::text)
              when di.logged is null then '(no audit row)'
              when di.user_id is null then 'SQL editor / cron (no login)'
              else coalesce(au.full_name, au.email, di.user_id::text) end as session_of,
         case when o.created_by is not null then cr.name when di.user_id is not null then ar.name end as role,
         (o.student_id in (select id from dup)) as is_dup,
         h.code as hcode
  from oct o
  left join students s on s.id = o.student_id
  left join st on st.id = o.student_id
  left join chg c on c.sid = o.student_id
  left join dins di on di.entity_id = o.id
  left join users au on au.id = di.user_id left join roles ar on ar.id = au.role_id
  left join users cu on cu.id = o.created_by left join roles cr on cr.id = cu.role_id
  left join hostels h on h.id = o.hostel_id
)
select case when grouping(made_on) = 1 then 'TOTAL' else made_on::text end as made_on_ist,
       case when grouping(origin) = 1 then '' else origin end as origin,
       case when grouping(session_of) = 1 then '' else session_of end as made_in_session_of,
       case when grouping(role) = 1 then '' else coalesce(role, '-') end as role,
       count(*) as n_bills, sum(fee_amount) as fee_total, sum(pending) as pending_total,
       count(distinct hostel_id) as n_hostels, string_agg(distinct hcode, ',') as hostels,
       min((created_at at time zone 'Asia/Kolkata')::timestamp(0)) as first_made_ist,
       max((created_at at time zone 'Asia/Kolkata')::timestamp(0)) as last_made_ist,
       count(*) filter (where coalesce(k, '?') <> 'active') as n_student_not_active_now,
       count(*) filter (where exit_date < date '2026-10-01') as n_exit_before_oct,
       count(*) filter (where exit_date >= date '2026-10-01' and exit_date <= date '2026-10-31') as n_exit_in_oct,
       count(*) filter (where coalesce(k, '?') <> 'active' and left_at > created_at) as n_left_after_bill_made,
       count(*) filter (where coalesce(k, '?') <> 'active' and left_at <= created_at) as n_already_not_active_when_made,
       count(*) filter (where is_dup) as n_duplicate_record,
       count(*) filter (where current_bed_id is null) as n_no_bed_now,
       count(*) filter (where status is null and student_id is not null) as n_status_null
from x
group by grouping sets ((made_on, origin, session_of, role), ())
order by grouping(made_on), made_on, origin, session_of;
