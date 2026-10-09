-- DDD Hostel - Phase 0 follow-up - file Q12 - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run -> "Export -> CSV" -> naam "Q12.csv".
--
-- Q12  "LEFT" STUDENT KA BED-LINK WAPAS KAISE AAYA?
--     Q8 mein 16 left students ka students.current_bed_id abhi bhi set hai,
--     jabki Left karte hi trigger use khali kar deta hai. Yeh block un
--     students ki pichhle 45 din ki har status / bed badalne wali entry
--     dikhata hai: kab (IST), kisne, kaunse columns badle, aur bed abhi
--     kiske paas hai. Isse pata chalega ki Edit form ka purana data
--     (stale form) bed-link wapas likh raha hai ya kuch aur.
-- =====================================================================
with lf as (
  select s.id, s.full_name, h.code as hostel, s.current_bed_id
  from students s
  left join hostels h on h.id = s.hostel_id
  where lower(trim(coalesce(s.status, ''))) = 'left' and s.current_bed_id is not null
)
select lf.hostel, lf.full_name,
       (l.created_at at time zone 'Asia/Kolkata')::timestamp(0) as at_ist,
       coalesce(u.full_name, u.email, '(SQL / system)') as by_user,
       l."before" ->> 'status' as status_before, l."after" ->> 'status' as status_after,
       l."before" ->> 'current_bed_id' as bed_before, l."after" ->> 'current_bed_id' as bed_after,
       (select string_agg(k, ', ' order by k) from jsonb_object_keys(coalesce(l."after", '{}'::jsonb)) k
         where l."after" -> k is distinct from l."before" -> k and k not in ('updated_at')) as changed_columns,
       b.bed_number as linked_bed, b.bed_status as linked_bed_status,
       coalesce((select st.full_name || ' (' || coalesce(st.status, '?') || ')' from students st where st.id = b.student_id), '(nobody)') as linked_bed_now_has,
       lf.id as student_id
from lf
join audit_logs l on l.entity_type = 'students' and l.entity_id = lf.id and l.action = 'update'
left join users u on u.id = l.user_id
left join beds b on b.id = lf.current_bed_id
where l.created_at > now() - interval '45 days'
  and (l."before" ->> 'current_bed_id' is distinct from l."after" ->> 'current_bed_id'
       or l."before" ->> 'status' is distinct from l."after" ->> 'status')
order by lf.hostel, lf.full_name, l.created_at;
