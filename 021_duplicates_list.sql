-- =====================================================================
-- 021_duplicates_list.sql   READ-ONLY (sirf SELECT — kuch change nahi)
-- Har query alag select karke Run karein, result bhejein.
-- "keep" = purana (pehle bana) record, "dup" = baad wala copy.
-- =====================================================================

-- ---------- D1: STUDENTS — possible duplicate pairs, side by side ----------
with s as (
  select s.*,
         lower(regexp_replace(trim(coalesce(s.full_name, '')), '\s+', ' ', 'g'))   as nm,
         lower(regexp_replace(trim(coalesce(s.father_name, '')), '\s+', ' ', 'g')) as fa,
         right(regexp_replace(coalesce(s.mobile, ''), '[^0-9]', '', 'g'), 10)       as mob,
         lower(trim(coalesce(s.admission_number, '')))                             as adm
  from students s
),
p as (
  select a.id keep_id, b.id dup_id,
         concat_ws(', ', case when a.nm <> '' and a.nm = b.nm and a.fa <> '' and a.fa = b.fa then 'name+father' end,
                          case when length(a.mob) = 10 and a.mob = b.mob then 'mobile' end,
                          case when a.adm <> '' and a.adm = b.adm then 'adm no' end) as why
  from s a join s b on (a.created_at, a.id) < (b.created_at, b.id)
   and ((a.nm <> '' and a.nm = b.nm and a.fa <> '' and a.fa = b.fa)
        or (length(a.mob) = 10 and a.mob = b.mob)
        or (a.adm <> '' and a.adm = b.adm))
),
c as (
  select x.id,
         (select count(*) from monthly_dues d where d.student_id = x.id) dues,
         (select count(*) from fee_payments f where f.student_id = x.id) pays,
         (select coalesce(sum(amount), 0) from fee_payments f where f.student_id = x.id) paid,
         (select string_agg(r.room_number || '/' || b.bed_number, ' ') from beds b left join rooms r on r.id = b.room_id where b.student_id = x.id) bed,
         (select count(*) from complaints m where m.student_id = x.id) compl
  from students x
)
select p.why,
       k.full_name keep_name, k.father_name keep_father, k.mobile keep_mobile, k.admission_number keep_adm,
       hk.code keep_hostel, k.joining_date keep_join, k.monthly_fee keep_fee, k.status keep_status,
       (k.created_at at time zone 'Asia/Kolkata')::timestamp(0) keep_created, ck.dues keep_dues, ck.pays keep_payments, ck.paid keep_paid, ck.bed keep_bed,
       d.full_name dup_name, d.father_name dup_father, d.mobile dup_mobile, d.admission_number dup_adm,
       hd.code dup_hostel, d.joining_date dup_join, d.monthly_fee dup_fee, d.status dup_status,
       (d.created_at at time zone 'Asia/Kolkata')::timestamp(0) dup_created, cd.dues dup_dues, cd.pays dup_payments, cd.paid dup_paid, cd.bed dup_bed,
       (select coalesce(u.full_name, u.email) from users u where u.id = d.created_by) dup_created_by,
       p.keep_id, p.dup_id
from p join students k on k.id = p.keep_id join students d on d.id = p.dup_id
left join hostels hk on hk.id = k.hostel_id left join hostels hd on hd.id = d.hostel_id
join c ck on ck.id = k.id join c cd on cd.id = d.id
order by d.created_at desc;

-- ---------- D2: STAFF — same name + phone (or same name, same hostel, phone missing) ----------
with e as (
  select e.*, lower(regexp_replace(trim(coalesce(e.full_name, '')), '\s+', ' ', 'g')) nm,
         right(regexp_replace(coalesce(e.mobile, ''), '[^0-9]', '', 'g'), 10) mob
  from employees e
)
select case when length(a.mob) = 10 and a.mob = b.mob then 'name+phone' else 'same name, same hostel (phone missing)' end why,
       a.full_name keep_name, a.role keep_role, a.mobile keep_mobile, ha.code keep_hostel, a.status keep_status,
       (a.created_at at time zone 'Asia/Kolkata')::timestamp(0) keep_created,
       (select count(*) from salary_runs r where r.employee_id = a.id) keep_salary_rows,
       (select count(*) from staff_attendance t where t.employee_id = a.id) keep_attendance,
       (select count(*) from salary_advances v where v.employee_id = a.id) keep_advances,
       b.full_name dup_name, b.role dup_role, b.mobile dup_mobile, hb.code dup_hostel, b.status dup_status,
       (b.created_at at time zone 'Asia/Kolkata')::timestamp(0) dup_created,
       (select count(*) from salary_runs r where r.employee_id = b.id) dup_salary_rows,
       (select count(*) from staff_attendance t where t.employee_id = b.id) dup_attendance,
       (select count(*) from salary_advances v where v.employee_id = b.id) dup_advances,
       (select coalesce(u.full_name, u.email) from users u where u.id = b.created_by) dup_created_by,
       a.id keep_id, b.id dup_id
from e a join e b on (a.created_at, a.id) < (b.created_at, b.id) and a.nm <> '' and a.nm = b.nm
 and ((length(a.mob) = 10 and a.mob = b.mob) or (a.hostel_id = b.hostel_id and (a.mob = '' or b.mob = '')))
left join hostels ha on ha.id = a.hostel_id left join hostels hb on hb.id = b.hostel_id
order by b.created_at desc;

-- ---------- D3: EVIDENCE — naya record bante waqt purane ka Edit hua tha? ----------
-- Har dup ke liye: dup INSERT ke 30 min pehle/baad usi user ne keep ko UPDATE kiya?
-- "yes" bahut saare -> Edit se naya bana (app bug);  "no" -> kisi ne dobara Add kiya.
with dups as (
  select 'students' t, a.id keep_id, b.id dup_id, b.created_at, b.created_by
  from students a join students b on (a.created_at, a.id) < (b.created_at, b.id)
   and lower(trim(a.full_name)) = lower(trim(b.full_name))
   and (lower(trim(coalesce(a.father_name, ''))) = lower(trim(coalesce(b.father_name, '')))
        or right(regexp_replace(coalesce(a.mobile, ''), '[^0-9]', '', 'g'), 10) = right(regexp_replace(coalesce(b.mobile, ''), '[^0-9]', '', 'g'), 10))
  union all
  select 'employees', a.id, b.id, b.created_at, b.created_by
  from employees a join employees b on (a.created_at, a.id) < (b.created_at, b.id)
   and lower(trim(a.full_name)) = lower(trim(b.full_name)) and a.hostel_id is not distinct from b.hostel_id
)
select d.t as kind, (d.created_at at time zone 'Asia/Kolkata')::timestamp(0) as dup_created,
       (select coalesce(u.full_name, u.email) from users u where u.id = d.created_by) as by_user,
       case when exists (select 1 from audit_logs l where l.entity_id = d.keep_id and l.action = 'update'
                          and l.created_at between d.created_at - interval '30 minutes' and d.created_at + interval '30 minutes')
            then 'yes' else 'no' end as keep_edited_around_then,
       (select count(*) from audit_logs l where l.entity_id = d.dup_id and l.action = 'insert') as dup_insert_logged,
       d.keep_id, d.dup_id
from dups d
order by d.created_at desc;

-- ---------- D4: last 30 days — kitne Add (insert) vs Edit (update), din / user wise ----------
select (l.created_at at time zone 'Asia/Kolkata')::date as day, l.entity_type, l.action,
       coalesce(u.full_name, u.email, l.user_id::text) as by_user, count(*) n
from audit_logs l left join users u on u.id = l.user_id
where l.entity_type in ('students', 'employees') and l.action in ('insert', 'update')
  and l.created_at >= now() - interval '30 days'
group by 1, 2, 3, 4 order by 1 desc, 2, 3;

-- ---------- D5: admission_number conflicts (unique constraint se pehle yeh 0 hone chahiye) ----------
select lower(trim(admission_number)) as admission_number, count(*) n,
       string_agg(full_name || ' (' || coalesce(status, '') || ')', ' | ' order by created_at) as students
from students
where nullif(trim(admission_number), '') is not null
group by 1 having count(*) > 1
order by n desc, 1;
