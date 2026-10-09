-- DDD Hostel - Phase 0 diagnostic - file Q5 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q5.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q5] =================================================================
-- Q5  DUPLICATE STUDENTS (ek hi bachcha 2+ baar)
--     Naam milaya jaata hai chhote/bade akshar, space, dot, hyphen hata kar.
--     Saath mein: father name, ya koi phone (mobile / parent mobile /
--     whatsapp, aakhri 10 digit), ya admission no. bhi milna chahiye.
--     Alag naam par bhi: same mobile / same admission no. (naam badla?),
--     aur "created_at copy hua" (Edit form se naya record bana).
--     "weak" = sirf naam + same hostel (father khali ya alag, aur phone /
--     admission no. aapas mein takraate nahi) - haath se jaanchein.
--     Placeholder / sabka ek hi phone ya admission no. (9999999999, NA,
--     0 ...) matching mein NAHI liya jaata - upar "NOTE" rows mein dikhta hai.
--     Har group ke saare members ek-ek row mein: kisne / kab banaya, status,
--     dues / payments, bed. scope = SAME HOSTEL ya CROSS-HOSTEL (transfer?).
--     Sabse naya group sabse upar, max ~300 rows (poore groups).
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
ins as (   -- the real INSERT moment from the audit log (row created_at can be copied from another row)
  select distinct on (l.entity_id) l.entity_id as sid, l.created_at as at, l.user_id
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'insert'
  order by l.entity_id, l.created_at
),
s0 as (
  select x.id, x.full_name, x.father_name, x.mobile, x.parent_mobile, x.admission_number, x.hostel_id, x.status::text as status,
         x.joining_date, x.exit_date, x.monthly_fee, x.created_at, x.created_by, x.updated_at, x.current_bed_id,
         coalesce(nullif(regexp_replace(lower(coalesce(x.full_name, '')), '[^[:alnum:]]+', '', 'g'), ''), lower(trim(coalesce(x.full_name, '')))) as nk,
         regexp_replace(regexp_replace(lower(coalesce(x.father_name, '')), '^(\s*(mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''), '[^[:alnum:]]+', '', 'g') as fk0,
         right(regexp_replace(coalesce(x.mobile, ''), '[^0-9]', '', 'g'), 10) as mk0,
         right(regexp_replace(coalesce(x.parent_mobile, ''), '[^0-9]', '', 'g'), 10) as pk0,
         right(regexp_replace(coalesce(x.whatsapp, ''), '[^0-9]', '', 'g'), 10) as wk0,
         regexp_replace(lower(coalesce(x.admission_number, '')), '[^[:alnum:]]+', '', 'g') as ak0,
         i.at as ins_at, i.user_id as ins_user,
         case when i.user_id is not null and abs(extract(epoch from (i.at - x.created_at))) > 120
              then date_trunc('second', x.created_at) end as copied_ts   -- app insert with an older created_at = saved from an Edit form
  from students x left join ins i on i.sid = x.id
),
kv as (   -- every phone / admission no. with how many different names use it
  select 'phone' as kt, k.v, count(distinct s0.id) as n_students, count(distinct s0.nk) as n_names
  from s0 cross join lateral (select distinct v from unnest(array[s0.mk0, s0.pk0, s0.wk0]) u(v)) k
  where length(k.v) = 10 group by k.v
  union all
  select 'adm no', s0.ak0, count(*), count(distinct s0.nk) from s0 where s0.ak0 <> '' group by s0.ak0
),
bad as (   -- placeholder or shared keys: NOT used for matching
  select kv.kt, kv.v, kv.n_students, kv.n_names,
         case when kv.n_names > 3 then 'shared by ' || kv.n_names || ' different names' else 'placeholder value' end as why
  from kv
  where kv.n_names > 3
     or (kv.kt = 'phone' and (kv.v ~ '^(\d)\1{9}$' or kv.v in ('1234567890', '0123456789', '9876543210')))
     or (kv.kt = 'adm no' and (kv.v ~ '^(.)\1*$' or kv.v in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'test', 'pending', 'new', 'notknown', 'unknown', 'nodata', 'notavailable')))
),
s as (
  select s0.*,
         case when s0.fk0 ~ '^(.)\1*$' or s0.fk0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'notknown', 'unknown', 'nodata', 'notavailable', 'father') then '' else s0.fk0 end as fk,
         case when length(s0.mk0) = 10 and s0.mk0 not in (select v from bad where kt = 'phone') then s0.mk0 else '' end as mk,
         case when s0.ak0 <> '' and s0.ak0 not in (select v from bad where kt = 'adm no') then s0.ak0 else '' end as ak,
         coalesce((select array_agg(distinct v) from unnest(array[s0.mk0, s0.pk0, s0.wk0]) u(v)
                   where length(v) = 10 and v not in (select b.v from bad b where b.kt = 'phone')), '{}'::text[]) as ph
  from s0
),
cand as (   -- candidate pairs from equality joins (fast hash joins); all columns needed later are carried along (no re-join)
  select a.id as a_id, b.id as b_id, a.nk as a_nk, b.nk as b_nk, a.fk as a_fk, b.fk as b_fk, a.mk as a_mk, b.mk as b_mk, a.ak as a_ak, b.ak as b_ak,
         a.ph as a_ph, b.ph as b_ph, a.hostel_id as a_h, b.hostel_id as b_h,
         coalesce(a.copied_ts = date_trunc('second', b.created_at) or b.copied_ts = date_trunc('second', a.created_at), false) as copied
  from s a join s b on b.nk = a.nk and a.nk <> '' and a.id < b.id
  union all
  select a.id, b.id, a.nk, b.nk, a.fk, b.fk, a.mk, b.mk, a.ak, b.ak, a.ph, b.ph, a.hostel_id, b.hostel_id,
         coalesce(a.copied_ts = date_trunc('second', b.created_at) or b.copied_ts = date_trunc('second', a.created_at), false)
  from s a join s b on b.mk = a.mk and a.mk <> '' and a.id < b.id
  where not (a.nk <> '' and a.nk = b.nk)
  union all
  select a.id, b.id, a.nk, b.nk, a.fk, b.fk, a.mk, b.mk, a.ak, b.ak, a.ph, b.ph, a.hostel_id, b.hostel_id,
         coalesce(a.copied_ts = date_trunc('second', b.created_at) or b.copied_ts = date_trunc('second', a.created_at), false)
  from s a join s b on b.ak = a.ak and a.ak <> '' and a.id < b.id
  where not (a.nk <> '' and a.nk = b.nk) and not (a.mk <> '' and a.mk = b.mk)
  union all   -- a = app insert with a copied created_at, b = a row with exactly that created_at (any name)
  select a.id, b.id, a.nk, b.nk, a.fk, b.fk, a.mk, b.mk, a.ak, b.ak, a.ph, b.ph, a.hostel_id, b.hostel_id, true
  from s a join s b on date_trunc('second', b.created_at) = a.copied_ts and b.id <> a.id
  where not (a.nk <> '' and a.nk = b.nk) and not (a.mk <> '' and a.mk = b.mk) and not (a.ak <> '' and a.ak = b.ak)
),
pr as (
  select least(c.a_id, c.b_id) as a_id, greatest(c.a_id, c.b_id) as b_id,
         concat_ws(' + ',
           case when x.nm and c.a_fk <> '' and c.a_fk = c.b_fk then 'name+father' end,
           case when x.nm and c.a_mk <> '' and c.a_mk = c.b_mk then 'name+mobile' end,
           case when x.nm and x.ph_overlap and not (c.a_mk <> '' and c.a_mk = c.b_mk) then 'name+parent/whatsapp phone' end,
           case when x.nm and c.a_ak <> '' and c.a_ak = c.b_ak then 'name+admission no' end,
           case when not x.nm and c.a_mk <> '' and c.a_mk = c.b_mk then 'mobile only (name differs)' end,
           case when not x.nm and c.a_ak <> '' and c.a_ak = c.b_ak then 'admission no only (name differs)' end,
           case when c.copied and (x.nm or (c.a_fk <> '' and c.a_fk = c.b_fk) or x.ph_overlap or (c.a_ak <> '' and c.a_ak = c.b_ak))
                then 'created_at copied from the other row (edit->insert)' end,
           case when x.nm and c.a_h is not distinct from c.b_h and not x.conflict
                     and not ((c.a_fk <> '' and c.a_fk = c.b_fk) or x.ph_overlap or (c.a_ak <> '' and c.a_ak = c.b_ak))
                then case when c.a_fk = '' or c.b_fk = '' then 'name only, father blank (weak)'
                          else 'same name+hostel, father differs, no phone/adm no to compare (weak, check by hand)' end end
         ) as why
  from cand c
  cross join lateral (
    select c.a_nk <> '' and c.a_nk = c.b_nk as nm,
           c.a_ph && c.b_ph as ph_overlap,
           (cardinality(c.a_ph) > 0 and cardinality(c.b_ph) > 0 and not (c.a_ph && c.b_ph)) or (c.a_ak <> '' and c.b_ak <> '' and c.a_ak <> c.b_ak) as conflict
  ) x
),
e as (select a_id, b_id, string_agg(distinct why, ' + ') as why from pr where why <> '' group by a_id, b_id),
ed as (select a_id as x, b_id as y from e union all select b_id, a_id from e),
g1 as (select ed.x as id, least(ed.x::text, min(ed.y::text)) as m from ed group by ed.x),
g2 as (select a.id, least(a.m, min(n.m)) as m from g1 a join ed on ed.x = a.id join g1 n on n.id = ed.y group by a.id, a.m),
grp as (   -- group id = smallest id within 3 steps (A~B, B~C, C~D => one group)
  select a.id::uuid as id, least(a.m, min(n.m)) as gid from g2 a join ed on ed.x = a.id join g2 n on n.id = ed.y group by a.id, a.m
),
gstat as (
  select g.gid, count(*) as n, count(distinct s.hostel_id) as n_hostels, max(greatest(s.created_at, s.ins_at)) as newest,
         count(*) filter (where lower(regexp_replace(coalesce(s.status, ''), '[^a-zA-Z]', '', 'g')) = 'active') as n_active   -- 'Active' / 'ACTIVE' count too
  from grp g join s on s.id = g.id group by g.gid
),
greasons as (select g.gid, string_agg(distinct e.why, ' / ') as reasons from e join grp g on g.id = e.a_id group by g.gid),
outp as (
  select dense_rank() over (order by (gs.n_hostels > 1), gs.newest desc, gs.gid) as grp_no,
         case when gs.n_hostels > 1 then 'CROSS-HOSTEL (transfer / invisible copy?)' else 'SAME HOSTEL' end as scope,
         gs.n as members, gs.n_active as active_members, gr.reasons as match_reasons,
         row_number() over (partition by gs.gid order by coalesce(s.ins_at, s.created_at), s.id) as nth_created,
         h.code as hostel, s.full_name, s.father_name, s.mobile, s.parent_mobile, s.admission_number, s.status, s.joining_date, s.exit_date, s.monthly_fee,
         (s.created_at at time zone 'Asia/Kolkata')::timestamp(0) as created_ist,
         coalesce(u.full_name, u.email, case when s.created_by is null then '(none / SQL)' else s.created_by::text end) as created_by_user,
         r.name as creator_role,
         (s.ins_at at time zone 'Asia/Kolkata')::timestamp(0) as audit_insert_ist,
         case when s.ins_at is null then 'no insert row in audit_logs'
              when abs(extract(epoch from (s.ins_at - s.created_at))) > 120 and s.ins_user is not null
                then 'created_at differs from real insert time: copied from an existing row (Edit form saved as NEW = edit->insert)?'
              when abs(extract(epoch from (s.ins_at - s.created_at))) > 120
                then 'SQL insert with explicit created_at (import?)'
              when r.name = 'director' and s.hostel_id = (select h1.id from hostels h1 order by h1.id limit 1)
                then 'added by Director into the form''s DEFAULT hostel (first by id): wrong hostel?'
         end as insert_note,
         (s.updated_at at time zone 'Asia/Kolkata')::timestamp(0) as updated_ist,
         coalesce(dues.n, 0) as n_dues, coalesce(dues.pend, 0) as dues_pending, dues.oct as oct_2026_due,
         coalesce(pays.n, 0) as n_payments, coalesce(pays.amt, 0) as paid_total, pays.last_pay as last_payment,
         beds_.bed as bed_now, s.id as student_id
  from grp g
  join gstat gs on gs.gid = g.gid
  left join greasons gr on gr.gid = g.gid
  join s on s.id = g.id
  left join hostels h on h.id = s.hostel_id
  left join users u on u.id = s.created_by
  left join roles r on r.id = u.role_id
  left join (   -- per-student totals as plain subqueries (not CTEs) so the planner keeps small row estimates
    select d.student_id, count(*) as n, coalesce(sum(d.pending), 0) as pend,
           max(case when d.month >= date '2026-10-01' and d.month < date '2026-11-01' then d.fee_amount::text || ' (pending ' || d.pending::text || ')' end) as oct
    from monthly_dues d group by d.student_id) dues on dues.student_id = s.id
  left join (
    select f.student_id, count(*) as n, coalesce(sum(f.amount), 0) as amt, max(f.payment_date) as last_pay
    from fee_payments f group by f.student_id) pays on pays.student_id = s.id
  left join (
    select b.student_id, string_agg(coalesce(r.room_number, '?') || '/' || b.bed_number, ' ') as bed
    from beds b left join rooms r on r.id = b.room_id where b.student_id is not null group by b.student_id) beds_ on beds_.student_id = s.id
),
capped as (select o.*, count(*) over (order by o.grp_no) as rows_upto from outp o),   -- whole groups, about 300 rows
notes as (
  select 1 as nord, 'NOTE: ' || b.kt || ' ' || b.v || ' = ' || b.n_students || ' students (' || b.why || ') -> NOT used for matching' as txt
  from (select * from bad order by n_students desc, v limit 20) b
  union all
  select 2, 'NOTE: only the newest ' || count(distinct grp_no) filter (where rows_upto <= 300 or grp_no = 1) || ' of ' || count(distinct grp_no)
            || ' duplicate groups are shown (300-row cap)'
  from capped having count(*) filter (where rows_upto > 300 and grp_no > 1) > 0
)
select grp_no, scope, members, active_members, match_reasons, nth_created, hostel, full_name, father_name, mobile, parent_mobile, admission_number,
       status, joining_date, exit_date, monthly_fee, created_ist, created_by_user, creator_role, audit_insert_ist, insert_note, updated_ist,
       n_dues, dues_pending, oct_2026_due, n_payments, paid_total, last_payment, bed_now, student_id
from (
  select 1 as part, 0 as nord, c.grp_no, c.scope, c.members, c.active_members, c.match_reasons, c.nth_created, c.hostel, c.full_name, c.father_name,
         c.mobile, c.parent_mobile, c.admission_number, c.status, c.joining_date, c.exit_date, c.monthly_fee, c.created_ist, c.created_by_user,
         c.creator_role, c.audit_insert_ist, c.insert_note, c.updated_ist, c.n_dues, c.dues_pending, c.oct_2026_due, c.n_payments, c.paid_total,
         c.last_payment, c.bed_now, c.student_id
  from capped c where c.rows_upto <= 300 or c.grp_no = 1
  union all
  select 0, n.nord, 0, n.txt, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null,
         null, null, null, null, null, null, null, null, null, null
  from notes n
) z
order by part, nord, grp_no, nth_created;
