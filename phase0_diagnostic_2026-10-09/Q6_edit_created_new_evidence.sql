-- DDD Hostel - Phase 0 diagnostic - file Q6 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q6.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q6] =================================================================
-- Q6  "EDIT KARNE PAR NAYA STUDENT BAN GAYA" — AUDIT LOG SE SABOOT
--     audit_logs mein har student INSERT (app user ne kiya) jiske waqt
--     usi naam (+ father / phone / admission no.) ka student PEHLE se tha,
--     YA jiska created_at kisi purane record se copy hua tha (= Edit form
--     se insert hua = asli app bug, chahe naam / father badla ho).
--     Har insert ke liye: kab (IST), kisne, role, purana record kaunsa,
--     kya usi user ne purane record ko +-30 min mein EDIT kiya tha,
--     aur 29-Sep hotfix se PEHLE ya BAAD.
--     Upar "A summary" rows, neeche "B detail" rows (max 300, hotfix ke
--     BAAD wale pehle, sabse naye upar).
--     Agar 29-Sep ke BAAD bhi "EDIT->INSERT" dikhe to live par purana app hai.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
ins as (   -- every student INSERT done by a logged-in app user
  select l.id as log_id, l.entity_id as sid, l.user_id, l.created_at as at, l."after" as a
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'insert' and l.user_id is not null
),
known as (   -- every student identity: rows that exist now + inserted rows that were deleted later
  select s.id, s.full_name, s.father_name, s.mobile, s.parent_mobile, s.whatsapp, s.admission_number, s.hostel_id,
         s.created_at, s.created_at as row_created, s.created_by, true as exists_now, s.status::text as status
  from students s
  union all
  select l.entity_id, l."after" ->> 'full_name', l."after" ->> 'father_name', l."after" ->> 'mobile', l."after" ->> 'parent_mobile',
         l."after" ->> 'whatsapp', l."after" ->> 'admission_number',
         case when (l."after" ->> 'hostel_id') ~* '^[0-9a-f-]{36}$' then (l."after" ->> 'hostel_id')::uuid end,
         l.created_at, coalesce((l."after" ->> 'created_at')::timestamptz, l.created_at), l.user_id, false, '(deleted)'
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'insert' and l.entity_id is not null
    and not exists (select 1 from students s where s.id = l.entity_id)
),
k0 as (
  select k.*,
         coalesce(nullif(regexp_replace(lower(coalesce(k.full_name, '')), '[^[:alnum:]]+', '', 'g'), ''), lower(trim(coalesce(k.full_name, '')))) as nk,
         regexp_replace(regexp_replace(lower(coalesce(k.father_name, '')), '^(\s*(mr|mrs|smt|shri|sri|sh|late|lt|dr|s/o|d/o|so|do)(\.|\s|/)+)+', ''), '[^[:alnum:]]+', '', 'g') as fk0,
         right(regexp_replace(coalesce(k.mobile, ''), '[^0-9]', '', 'g'), 10) as mk0,
         right(regexp_replace(coalesce(k.parent_mobile, ''), '[^0-9]', '', 'g'), 10) as pk0,
         right(regexp_replace(coalesce(k.whatsapp, ''), '[^0-9]', '', 'g'), 10) as wk0,
         regexp_replace(lower(coalesce(k.admission_number, '')), '[^[:alnum:]]+', '', 'g') as ak0
  from known k
),
bad as (   -- placeholder / shared phones and admission numbers (same rule as Q5): not used for matching
  select 'phone' as kt, v from (
    select u.v, count(distinct k0.nk) as n_names from k0 cross join lateral unnest(array[k0.mk0, k0.pk0, k0.wk0]) u(v)
    where length(u.v) = 10 group by u.v) p
  where n_names > 3 or v ~ '^(\d)\1{9}$' or v in ('1234567890', '0123456789', '9876543210')
  union all
  select 'adm no', ak0 from k0 where ak0 <> '' group by ak0
  having count(distinct nk) > 3 or ak0 ~ '^(.)\1*$' or ak0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'test', 'pending', 'new', 'notknown', 'unknown', 'nodata', 'notavailable')
),
kn as (
  select k0.*,
         case when k0.fk0 ~ '^(.)\1*$' or k0.fk0 in ('na', 'nil', 'nill', 'none', 'null', 'nan', 'notknown', 'unknown', 'nodata', 'notavailable', 'father') then '' else k0.fk0 end as fk,
         case when length(k0.mk0) = 10 and k0.mk0 not in (select v from bad where kt = 'phone') then k0.mk0 else '' end as mk,
         case when k0.ak0 <> '' and k0.ak0 not in (select v from bad where kt = 'adm no') then k0.ak0 else '' end as ak,
         coalesce((select array_agg(distinct v) from unnest(array[k0.mk0, k0.pk0, k0.wk0]) u(v)
                   where length(v) = 10 and v not in (select b.v from bad b where b.kt = 'phone')), '{}'::text[]) as ph
  from k0
),
inn as (
  select i.*, k.nk, k.fk, k.mk, k.ak, k.ph, k.hostel_id, k.full_name, k.exists_now, k.status as status_now,
         coalesce((i.a ->> 'created_at') is not null and abs(extract(epoch from ((i.a ->> 'created_at')::timestamptz - i.at))) > 120, false) as copied_created_at,
         date_trunc('second', (i.a ->> 'created_at')::timestamptz) as copied_ts
  from ins i join kn k on k.id = i.sid
),
pairs as (   -- older records that look like the same student: same name, or (copied created_at = old row's created_at)
  select i.log_id, o.id as old_id from inn i join kn o on o.nk = i.nk and o.nk <> '' and o.id <> i.sid and o.created_at < i.at
  union
  select i.log_id, o.id from inn i join kn o on date_trunc('second', o.row_created) = i.copied_ts and i.copied_created_at and o.id <> i.sid and o.created_at < i.at
),
mm as (
  select p.log_id, o.id as old_id, o.full_name as old_name, o.hostel_id as old_hostel, o.created_at as old_created,
         o.created_by as old_by, o.exists_now as old_exists, o.status as old_status_now,
         (o.nk <> '' and o.nk = i.nk) as nm,
         (i.copied_created_at and date_trunc('second', o.row_created) = i.copied_ts) as ts_match,
         (i.fk <> '' and i.fk = o.fk) as f_match, (i.ph && o.ph) as p_match, (i.ak <> '' and i.ak = o.ak) as a_match,
         (i.hostel_id is not distinct from o.hostel_id) as same_hostel,
         ((cardinality(i.ph) > 0 and cardinality(o.ph) > 0 and not (i.ph && o.ph)) or (i.ak <> '' and o.ak <> '' and i.ak <> o.ak)) as conflict
  from pairs p join inn i on i.log_id = p.log_id join kn o on o.id = p.old_id
),
mq as (   -- keep only real matches
  select mm.* from mm
  where (mm.nm and (mm.f_match or mm.p_match or mm.a_match))                                  -- name + father / phone / adm no
     or (mm.ts_match and (mm.nm or mm.f_match or mm.p_match or mm.a_match))                   -- copied created_at + any key
     or (mm.nm and mm.same_hostel and not mm.conflict)                                       -- weak: name only, same hostel, nothing contradicts
),
m as (   -- best older match per insert; inserts with a copied created_at are kept even without any match
  select distinct on (i.log_id) i.*, q.old_id, q.old_name, q.old_hostel, q.old_created, q.old_by, q.old_exists, q.old_status_now, q.ts_match,
         concat_ws('+', case when q.nm then 'name' end, case when q.f_match then 'father' end, case when q.p_match then 'phone' end,
                        case when q.a_match then 'adm no' end, case when q.ts_match then 'copied created_at' end) as why,
         (q.old_id is not null and not (q.f_match or q.p_match or q.a_match or q.ts_match)) as weak
  from inn i left join mq q on q.log_id = i.log_id
  where q.old_id is not null or i.copied_created_at
  order by i.log_id, q.ts_match desc nulls last, q.same_hostel desc nulls last,
           (q.nm::int + q.f_match::int + q.p_match::int + q.a_match::int) desc nulls last, q.old_created desc nulls last
),
upd as (   -- real edits of the OLD rows (system-only paid_till / plan_amount recalcs are ignored)
  select l.entity_id, l.user_id, l.created_at,
         coalesce((select string_agg(e.k, ',' order by e.k) from jsonb_each(l."after"::jsonb) e(k, v)
                   where (l."before"::jsonb -> e.k) is distinct from e.v and e.k not in ('updated_at', 'paid_till', 'plan_amount')), '') as keys
  from audit_logs l
  where l.entity_type = 'students' and l.action = 'update'
    and l.entity_id in (select old_id from m)
    and (l."before" ->> 'paid_till') is not distinct from (l."after" ->> 'paid_till')
),
x as (
  select m.*, se.mins as same_user_edit_min, se.keys as same_user_edit_keys,
         exists (select 1 from upd u where u.entity_id = m.old_id and u.created_at between m.at - interval '30 minutes' and m.at + interval '30 minutes') as any_edit_30m,
         case when m.at < timestamptz '2026-09-29 14:11:35+05:30' then '1 BEFORE 29-Sep hotfix' else '2 AFTER 29-Sep hotfix' end as win
  from m
  left join lateral (
    select round((extract(epoch from (u.created_at - m.at)) / 60.0)::numeric, 1) as mins, coalesce(nullif(u.keys, ''), '(saved, nothing changed)') as keys
    from upd u
    where u.entity_id = m.old_id and u.user_id = m.user_id
      and u.created_at between m.at - interval '30 minutes' and m.at + interval '30 minutes'
    order by abs(extract(epoch from (u.created_at - m.at))) limit 1
  ) se on true
),
v as (
  select x.*,
         case
           when x.copied_created_at and x.old_id is not null then 'EDIT->INSERT (strong: form of an existing row was saved as new)'
           when x.copied_created_at then 'EDIT->INSERT (strong: created_at copied; original not found - deleted / merged, or name+father+phone+adm all changed)'
           when x.old_by = x.user_id and x.at - x.old_created < interval '15 minutes' and x.same_user_edit_min is null then 'DOUBLE SAVE / RETRY (same user, minutes apart)'
           when x.same_user_edit_min is not null then 'EDIT then NEW row by same user within 30 min (edit->insert or re-add after failed edit)'
           when x.old_hostel is distinct from x.hostel_id then 'CROSS-HOSTEL re-add (old copy in another hostel)'
           else 'RE-ADDED later (manual Add, no edit nearby)'
         end || case when x.weak then ' [weak match: name only]' else '' end as verdict
  from x
)
select * from (
  select 'A summary' as sec, v.win, v.verdict, coalesce(r.name, '(no role)') as role, count(*)::int as n_inserts,
         min((v.at at time zone 'Asia/Kolkata')::timestamp(0))::text as first_ist, max((v.at at time zone 'Asia/Kolkata')::timestamp(0))::text as last_ist,
         string_agg(distinct coalesce(u.full_name, u.email), ', ') as by_users,
         null::text as new_student, null::text as new_hostel, null::text as new_now, null::text as old_student, null::text as old_hostel,
         null::text as old_created_ist, null::text as old_now, null::text as match_on, null::text as same_user_edit_min, null::text as same_user_edit_keys, null::text as anyone_edit_30m,
         null::text as created_at_copied, null::text as new_id, null::text as old_id
  from v left join users u on u.id = v.user_id left join roles r on r.id = u.role_id
  group by v.win, v.verdict, coalesce(r.name, '(no role)')
  union all
  select * from (
    select 'B detail', v.win, v.verdict, coalesce(r.name, '(no role)'), null::int,
           ((v.at at time zone 'Asia/Kolkata')::timestamp(0))::text, null, coalesce(u.full_name, u.email, v.user_id::text),
           v.full_name, hn.code, case when v.exists_now then v.status_now else '(deleted)' end,
           v.old_name, ho.code, ((v.old_created at time zone 'Asia/Kolkata')::timestamp(0))::text,
           case when v.old_id is null then null when v.old_exists then v.old_status_now else '(deleted)' end,
           case when v.old_id is null then '(no older record found)' when v.weak then 'name only (weak)' else v.why end,
           v.same_user_edit_min::text, v.same_user_edit_keys, v.any_edit_30m::text, v.copied_created_at::text, v.sid::text, v.old_id::text
    from v left join users u on u.id = v.user_id left join roles r on r.id = u.role_id
    left join hostels hn on hn.id = v.hostel_id left join hostels ho on ho.id = v.old_hostel
    order by v.win desc, v.at desc
    limit 300
  ) d
) z
order by sec, win desc, first_ist desc nulls last;
