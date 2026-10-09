-- DDD Hostel - Phase 0 diagnostic - file Q7 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q7.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q7] =================================================================
-- Q7  CHHODE HUE (LEFT / INACTIVE) STUDENTS KE GALAT BILL
--     Har woh monthly_dues row jo:
--       AFTER_LEAVE     : chhodne ki tareekh ke BAAD shuru hone wale mahine ka bill
--       LEAVE_MONTH_FULL: jis mahine chhoda us mahine ka bill rehne ke dinon se zyada
--       NOT_ACTIVE_NO_DATE: Oct-2026+ bill, status left-jaisa, chhodne ki date pata nahi
--       STATUS_UNCLEAR  : Oct-2026+ bill, status NULL ya ajeeb value (haath se jaanchein)
--       TEMP_LEAVE_BILLED: temporary_leave ke baad shuru hone wala bill
--     'Active' / 'ACTIVE' / 'active ' = active (sirf exit_date se leave maana jaata hai).
--     Chhodne ki tareekh = exit_date, warna audit_logs mein status left-jaisa
--     hone ka din. Saari list aati hai (300 ki seema nahi).
--     Oct-2026 wale bills sabse upar. "likely_cause" batata hai bill kaise bana.
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
st as (
  select s.id, s.full_name, s.father_name, s.hostel_id, s.status::text as status, s.joining_date, s.exit_date, s.monthly_fee,
         case when s.status::text is null then 'NULL' when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout') then 'left'
              when lower(s.status::text) like '%temp%' then 'temp' else 'other' end as k,   -- coarse class: active / left / temp / NULL / other
         case when s.status::text = 'active' then 'active'
              when s.status::text = 'left' then 'left'
              when s.status is null then 'NULL'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) = 'active' then 'active-odd-spelling'
              when lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g')) in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout')
                   then 'left-like (odd spelling)'
              when lower(s.status::text) like '%temp%' then 'temporary_leave'
              else 'other: ' || s.status::text end as cls
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
lv as (
  select st.*, c.at as changed_at, c.user_id as changed_by,
         coalesce(st.exit_date, case when st.k = 'left' then (c.at at time zone 'Asia/Kolkata')::date end) as leave_date,   -- only left-like statuses get a date from the audit log
         case when st.exit_date is not null then 'exit_date'
              when st.k = 'left' and c.at is not null then 'status change (audit)'
              else null end as leave_src
  from st left join chg c on c.sid = st.id
  where st.k <> 'active' or st.exit_date is not null
),
dd as (
  select d.id, d.student_id, d.hostel_id, d.month, d.fee_amount, coalesce(d.discount, 0) as discount, d.payable, d.paid_amount, d.pending,
         d.status::text as status, d.created_at, d.created_by,
         coalesce(nullif(to_jsonb(d) ->> 'period_from', '')::date, d.month) as p_from,
         coalesce(nullif(to_jsonb(d) ->> 'period_to', '')::date, (d.month + interval '1 month - 1 day')::date) as p_to
  from monthly_dues d
  where d.student_id in (select id from lv)
),
calc as (
  select lv.*, dd.id as due_id, dd.month, dd.p_from, dd.p_to, dd.fee_amount, dd.discount, dd.payable, dd.paid_amount, dd.pending,
         dd.status as due_status, dd.created_at as due_created, dd.created_by as due_created_by,
         ((dd.month + interval '1 month')::date - dd.month) as cycle_days,
         case when lv.leave_date >= dd.p_from and lv.leave_date < dd.p_to   -- days stayed = max(bill start, joining_date) .. leave date
              then round(lv.monthly_fee * greatest(lv.leave_date - greatest(dd.p_from, coalesce(lv.joining_date, dd.p_from)) + 1, 0)
                         / ((dd.month + interval '1 month')::date - dd.month), 0) end as fair_fee
  from lv join dd on dd.student_id = lv.id
),
fl as (
  select c.*,
         concat_ws(' + ',
           case when c.leave_date is not null and c.p_from > c.leave_date then 'AFTER_LEAVE' end,
           case when c.fair_fee is not null and c.payable > c.fair_fee + 1 then 'LEAVE_MONTH_FULL' end,
           case when c.leave_date is null and c.k = 'left' and c.month >= date '2026-10-01' then 'NOT_ACTIVE_NO_DATE' end,
           case when c.leave_date is null and c.k in ('NULL', 'other') and c.month >= date '2026-10-01' then 'STATUS_UNCLEAR' end,
           case when c.k = 'temp' and c.changed_at is not null and c.p_from > (c.changed_at at time zone 'Asia/Kolkata')::date then 'TEMP_LEAVE_BILLED' end
         ) as flags
  from calc c
),
pay as (
  select f.due_id, count(*) as n, coalesce(sum(f.amount), 0) as amt
  from fee_payments f where f.due_id in (select due_id from fl where flags <> '') group by f.due_id
),
dins as (   -- who made the due (audit insert row = the app user whose session called the generator/RPC)
  select distinct on (l.entity_id) l.entity_id, l.user_id
  from audit_logs l
  where l.entity_type = 'monthly_dues' and l.action = 'insert' and l.entity_id in (select due_id from fl where flags <> '')
  order by l.entity_id, l.created_at
)
select case when fl.month >= date '2026-10-01' and fl.month < date '2026-11-01' then 'OCT-2026' else to_char(fl.month, 'YYYY-MM') end as bill_month,
       fl.flags, h.code as hostel, fl.full_name, fl.father_name, fl.status as status_raw, fl.cls as status_class,
       fl.joining_date, fl.exit_date, (fl.changed_at at time zone 'Asia/Kolkata')::timestamp(0) as status_changed_ist,
       coalesce(cu.full_name, cu.email) as status_changed_by, fl.leave_date as leave_date_used, fl.leave_src,
       fl.p_from as bill_from, fl.p_to as bill_to, fl.monthly_fee, fl.fee_amount, fl.discount, fl.payable,
       fl.fair_fee as fair_fee_for_days_stayed,
       case when fl.flags like '%AFTER_LEAVE%' or fl.flags like '%NOT_ACTIVE_NO_DATE%' or fl.flags like '%TEMP_LEAVE%' then fl.payable
            when fl.flags like '%LEAVE_MONTH_FULL%' then fl.payable - fl.fair_fee end as overbilled_by,   -- STATUS_UNCLEAR: unknown
       fl.paid_amount, fl.pending, fl.due_status, coalesce(pay.n, 0) as n_payments_on_bill, coalesce(pay.amt, 0) as paid_via_payments,
       (fl.due_created at time zone 'Asia/Kolkata')::timestamp(0) as bill_made_ist,
       case when fl.due_created_by is null then 'generator / SQL' else 'payment RPC (record_*)' end as bill_origin,
       coalesce(du.full_name, du.email, case when di.user_id is null and di.entity_id is not null then 'SQL editor / cron' end, '(no audit row)') as bill_made_in_session_of,
       case
         when fl.due_created_by is not null then 'bill created by a fee payment RPC (no status / exit check)'
         when fl.k = 'active' and fl.exit_date is not null then 'status still ACTIVE: generator ignores exit_date'
         when fl.k in ('NULL', 'other') then 'status NULL / unknown value (repo generator bills only exact ''active''): check who made this bill'
         when fl.changed_at is not null and fl.changed_at > fl.due_created then 'marked left AFTER the bill was made (nothing cancels / prorates it)'
         when fl.changed_at is not null and fl.changed_at <= fl.due_created then 'bill made while ALREADY not active: CHECK live generator / manual insert'
         when fl.exit_date is not null and (fl.due_created at time zone 'Asia/Kolkata')::date > fl.exit_date then 'bill made after exit_date (status change not in audit log)'
         else 'no status change in audit log (changed via SQL / before audit?)'
       end as likely_cause,
       fl.id as student_id, fl.due_id
from fl
left join hostels h on h.id = fl.hostel_id
left join users cu on cu.id = fl.changed_by
left join pay on pay.due_id = fl.due_id
left join dins di on di.entity_id = fl.due_id
left join users du on du.id = coalesce(fl.due_created_by, di.user_id)
where fl.flags <> ''
order by (fl.month >= date '2026-10-01' and fl.month < date '2026-11-01') desc, fl.month desc, h.code, fl.full_name;
