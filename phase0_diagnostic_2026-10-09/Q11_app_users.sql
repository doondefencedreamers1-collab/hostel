-- DDD Hostel - Phase 0 diagnostic - file Q11 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q11.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q11] ================================================================
-- Q11 APP USERS: ROLE, STATUS, KAUN SA HOSTEL, AUR STUDENTS PAR KYA KIYA
--     Har login user: role, status, assigned hostels, aakhri activity,
--     students add / edit / delete ki ginti (29-Sep hotfix ke pehle/baad),
--     aur khatre: removed/pending user ke paas abhi bhi hostel access (RLS
--     status nahi dekhta), manager bina hostel, role khaali par active.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
act as (
  select l.user_id,
         max(l.created_at) as last_any,
         count(*) filter (where l.entity_type = 'students' and l.action = 'insert') as stu_ins,
         count(*) filter (where l.entity_type = 'students' and l.action = 'insert' and l.created_at >= timestamptz '2026-09-29 14:11:35+05:30') as stu_ins_after_fix,
         count(*) filter (where l.entity_type = 'students' and l.action = 'update'
                            and (l."before" ->> 'paid_till') is not distinct from (l."after" ->> 'paid_till')) as stu_upd,
         count(*) filter (where l.entity_type = 'students' and l.action = 'update'
                            and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) as stu_status_changes,
         count(*) filter (where l.entity_type = 'students' and l.action = 'delete') as stu_del,
         count(*) filter (where l.entity_type = 'fee_payments' and l.action = 'insert') as payments,
         max(l.created_at) filter (where l.entity_type = 'students' and l.action = 'insert') as last_stu_ins
  from audit_logs l
  where l.user_id is not null
  group by l.user_id
),
uha as (
  select a.user_id, string_agg(coalesce(h.code, '?'), ',' order by h.code) as hostels, count(*) as n
  from user_hostel_assignments a left join hostels h on h.id = a.hostel_id
  group by a.user_id
)
select coalesce(r.name, '(no role)') as role, u.full_name, u.email, u.status, u.is_active,
       uha.hostels as assigned_hostels,
       (select h.code from hostels h where h.id::text = to_jsonb(u) ->> 'requested_hostel_id') as requested_hostel,
       (u.created_at at time zone 'Asia/Kolkata')::timestamp(0) as created_ist,
       (act.last_any at time zone 'Asia/Kolkata')::timestamp(0) as last_activity_ist,
       coalesce(act.stu_ins, 0) as students_added, coalesce(act.stu_ins_after_fix, 0) as students_added_after_29sep_fix,
       (act.last_stu_ins at time zone 'Asia/Kolkata')::timestamp(0) as last_student_add_ist,
       coalesce(act.stu_upd, 0) as student_edits, coalesce(act.stu_status_changes, 0) as student_status_changes,
       coalesce(act.stu_del, 0) as students_deleted, coalesce(act.payments, 0) as fee_payment_rows,
       concat_ws(' | ',
         case when coalesce(u.status::text, 'active') <> 'active' and uha.n > 0 then 'NOT ACTIVE but still has hostel rows -> RLS still gives access' end,
         case when coalesce(u.is_active, true) = false and uha.n > 0 then 'is_active=false but still has hostel rows' end,
         case when r.name = 'manager' and uha.n is null then 'manager without any hostel' end,
         case when r.name is null and coalesce(u.status::text, 'active') = 'active' then 'active user without role' end,
         case when r.name in ('director', 'accountant') and uha.n > 0 then 'also has hostel rows (harmless)' end
       ) as flags,
       u.id as user_id
from users u
left join roles r on r.id = u.role_id
left join uha on uha.user_id = u.id
left join act on act.user_id = u.id
order by case r.name when 'director' then 1 when 'accountant' then 2 when 'manager' then 3 else 4 end, u.full_name;
