-- DDD Hostel - Phase 0 diagnostic - file Q8 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q8.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q8] =================================================================
-- Q8  STUDENT STATUS KI SAFAI-JAANCH
--     1_status_value : har alag status value (exact, space/case ke saath) aur ginti
--                      - generator sirf exact 'active' ko bill karta hai,
--                        app sirf exact 'left' ko "left" maanta hai.
--     2_left_no_exit : left/inactive hain par exit_date khaali
--     3_exit_passed_still_active : exit_date beet gayi (aaj se pehle) par status abhi bhi active/temp
--     4_left_bed_not_freed : left-jaise status par bed abhi bhi unke naam
--     5_active_maybe_gone : status active, bed nahi, 45 din se payment nahi, Oct bill
--                      pending (shayad chale gaye par status nahi badla - jaanch karein)
--     (har section max 300 rows). Is block ko select karke Run karein,
--     result ka CSV bhejein.
-- =====================================================================
with
td as (select (now() at time zone 'Asia/Kolkata')::date as today),
st as (
  select s.id, s.full_name, s.father_name, s.hostel_id, s.status::text as status, s.joining_date, s.exit_date, s.current_bed_id, s.monthly_fee,
         case when s.status::text is null then 'NULL' when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
              when lower(s.status::text) like '%temp%' then 'temp' else 'other' end as k,   -- coarse class (same as Q7/Q9)
         case when s.status::text = 'active' then 'active'
              when s.status::text = 'left' then 'left'
              when s.status is null then 'NULL'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active-odd-spelling'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout')
                   then 'left-like (odd spelling)'
              when s.status::text = 'temporary_leave' then 'temporary_leave'
              when lower(s.status::text) like '%temp%' then 'temp-leave-odd-spelling'
              else 'other' end as cls
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
  where c.kb is distinct from c.ka and c.ka = st.k
  order by c.sid, c.at desc
),
oct as (
  select d.student_id, sum(d.fee_amount) as fee, sum(d.pending) as pend
  from monthly_dues d where d.month >= date '2026-10-01' and d.month < date '2026-11-01' group by d.student_id
),
lastpay as (select f.student_id, max(f.payment_date) as last_pay from fee_payments f group by f.student_id),
bedq as (
  select b.student_id, string_agg(coalesce(r.room_number, '?') || '/' || b.bed_number || ' (' || coalesce(b.bed_status::text, '?') || ')', ' ') as bed
  from beds b left join rooms r on r.id = b.room_id where b.student_id is not null group by b.student_id
),
det as (
  select st.*, h.code, (c.at at time zone 'Asia/Kolkata')::timestamp(0) as changed_ist, coalesce(u.full_name, u.email) as changed_by,
         oct.fee as oct_fee, oct.pend as oct_pending, bedq.bed,
         (st.current_bed_id is not null) as has_current_bed, lp.last_pay
  from st
  left join lastpay lp on lp.student_id = st.id
  left join hostels h on h.id = st.hostel_id
  left join chg c on c.sid = st.id
  left join users u on u.id = c.user_id
  left join oct on oct.student_id = st.id
  left join bedq on bedq.student_id = st.id
)
select * from (
  select '1_status_value' as sec, '[' || coalesce(st.status, 'NULL') || ']' as status_raw, st.cls as status_class, count(*)::int as n_students,
         count(*) filter (where st.exit_date is not null)::int as n_with_exit_date,
         count(*) filter (where st.current_bed_id is not null)::int as n_with_bed,
         count(*) filter (where exists (select 1 from oct where oct.student_id = st.id))::int as n_with_oct_2026_bill,
         case when st.status = 'active' then 'yes' else 'no' end as generator_bills_it,
         case when coalesce(st.status, 'active') <> 'left' then 'yes' else 'no' end as dashboard_and_bell_treat_as_billable,
         null::text as hostel, null::text as full_name, null::text as father_name, null::date as joining_date, null::date as exit_date,
         null::text as status_changed_ist, null::text as status_changed_by, null::text as bed_now, null::numeric as oct_fee, null::numeric as oct_pending,
         null::text as student_id
  from st group by st.status, st.cls
  union all
  select * from (
    select '2_left_no_exit', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by, d.bed, d.oct_fee, d.oct_pending, d.id::text
    from det d where d.cls in ('left', 'left-like (odd spelling)') and d.exit_date is null
    order by d.changed_ist desc nulls last limit 300) a
  union all
  select * from (
    select '3_exit_passed_still_active', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by, d.bed, d.oct_fee, d.oct_pending, d.id::text
    from det d, td where d.exit_date < td.today and d.cls not in ('left', 'left-like (odd spelling)')   -- exit_date = last day stayed
    order by d.exit_date desc limit 300) b
  union all
  select * from (
    select '4_left_bed_not_freed', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by,
           coalesce(d.bed, '') || case when d.has_current_bed then ' | students.current_bed_id still set' else '' end, d.oct_fee, d.oct_pending, d.id::text
    from det d where d.cls in ('left', 'left-like (odd spelling)') and (d.bed is not null or d.has_current_bed)
    order by d.code, d.full_name limit 300) c
  union all
  select * from (
    select '5_active_maybe_gone', '[' || coalesce(d.status, 'NULL') || ']', d.cls, null::int, null::int, null::int, null::int, null::text, null::text,
           d.code, d.full_name, d.father_name, d.joining_date, d.exit_date, d.changed_ist::text, d.changed_by,
           'NO BED | last payment ' || coalesce(d.last_pay::text, 'never'), d.oct_fee, d.oct_pending, d.id::text
    from det d, td
    where d.cls in ('active', 'active-odd-spelling') and d.joining_date <= td.today - 30
      and d.bed is null and not d.has_current_bed
      and coalesce(d.last_pay, date '2000-01-01') < td.today - 45
      and coalesce(d.oct_pending, 0) > 0
    order by d.code, d.full_name limit 300) e
) z
order by sec, n_students desc nulls last, hostel, full_name;
