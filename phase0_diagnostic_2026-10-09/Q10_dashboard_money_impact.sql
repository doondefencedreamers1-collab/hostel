-- DDD Hostel - Phase 0 diagnostic - file Q10 (11 mein se) - 100% READ-ONLY (sirf SELECT, kuch nahi badalta)
-- Supabase -> SQL Editor -> "New query" -> yeh POORI file paste karein -> Run
-- -> result ke upar "Export -> CSV" -> file ka naam "Q10.csv" rakhein.
-- Row-limit ka option dikhe to "No limit" chunein. Error aaye to uska screenshot bhej dein.
-- CSV bhejne se pehle Ctrl+F: "eyJ" / "Bearer" / "sb_secret" - ***MASKED*** ke bina koi key dikhe to pehle bata dein.
--
-- [Q10] ================================================================
-- Q10 DASHBOARD / LEDGER PAR GALAT ASAR (hostel-wise + TOTAL)
--     a) Oct-2026 "Fee Billed" mein chhode hue students ka bill (dashboard Billed / Collection %)
--     b) jis mahine chhoda us mahine ka extra (rehne ke dinon se zyada) bill
--     c) Monthly ledger / profile mein left students ka pending (Receive button dikhta hai)
--     d) Dashboard "Pending" + Bell "Overdue" mein galti se gine gaye: exit_date beet chuki
--        ya 'Left '/'inactive' jaisa status (app sirf exact 'left' ko left maanta hai)
--     e) temporary_leave / NULL status wale jo app mein "billable" (OVERDUE dikh sakte) hain
--     Is block ko select karke Run karein, result ka CSV bhejein.
-- =====================================================================
with
td as (select (now() at time zone 'Asia/Kolkata')::date as today),
st as (
  select s.id, s.hostel_id, s.status::text as status, s.exit_date, s.joining_date, s.monthly_fee,
         coalesce(lower(regexp_replace(s.status::text, '[^a-zA-Z]', '', 'g'))
              in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout'), false) as is_leftish,
         (coalesce(s.status::text, 'active') <> 'left' and s.joining_date is not null and coalesce(s.monthly_fee, 0) > 0) as app_billable
  from students s
),
chg as (   -- latest change INTO a left-like status from a non-left status (same leave date as Q7)
  select distinct on (c.sid) c.sid, (c.at at time zone 'Asia/Kolkata')::date as on_date
  from (select l.entity_id as sid, l.created_at as at,
               coalesce(lower(regexp_replace(l."before" ->> 'status', '[^a-zA-Z]', '', 'g'))
                        in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout'), false) as was_left,
               coalesce(lower(regexp_replace(l."after" ->> 'status', '[^a-zA-Z]', '', 'g'))
                        in ('left', 'inactive', 'exit', 'exited', 'gone', 'discontinued', 'dropped', 'dropout', 'passedout', 'removed', 'leftout'), false) as is_left
        from audit_logs l where l.entity_type = 'students' and l.action = 'update'
          and (l."before" ->> 'status') is distinct from (l."after" ->> 'status')) c
  where c.is_left and not c.was_left
  order by c.sid, c.at desc
),
lv as (
  select st.*, coalesce(st.exit_date, case when st.is_leftish then c.on_date end) as leave_date
  from st left join chg c on c.sid = st.id
),
dd as (
  select d.id, d.student_id, d.hostel_id, d.month, d.payable, d.pending,
         coalesce(nullif(to_jsonb(d) ->> 'period_from', '')::date, d.month) as p_from,
         coalesce(nullif(to_jsonb(d) ->> 'period_to', '')::date, (d.month + interval '1 month - 1 day')::date) as p_to
  from monthly_dues d
),
j as (
  select dd.*, lv.status, lv.is_leftish, lv.app_billable, lv.exit_date, lv.leave_date, lv.monthly_fee,
         (dd.month >= date '2026-10-01' and dd.month < date '2026-11-01') as is_oct,
         ((lv.leave_date is not null and dd.p_from > lv.leave_date) or (lv.leave_date is null and lv.is_leftish)) as full_wrong,
         case when lv.leave_date >= dd.p_from and lv.leave_date < dd.p_to   -- same fair fee and +1 tolerance as Q7 LEAVE_MONTH_FULL
              then case when dd.payable > fr.fair + 1 then dd.payable - fr.fair else 0 end end as leave_month_extra
  from dd join lv on lv.id = dd.student_id
  cross join lateral (select round(lv.monthly_fee * greatest(lv.leave_date - greatest(dd.p_from, coalesce(lv.joining_date, dd.p_from)) + 1, 0)
                                   / ((dd.month + interval '1 month')::date - dd.month), 0) as fair) fr
),
per as (
  select j.hostel_id,
         count(*) filter (where is_oct) as oct_bills,
         sum(payable) filter (where is_oct) as oct_billed,
         count(*) filter (where is_oct and (full_wrong or leave_month_extra > 0)) as a_oct_bills_of_left,
         coalesce(sum(case when full_wrong then payable else coalesce(leave_month_extra, 0) end) filter (where is_oct), 0) as a_oct_billed_wrongly,
         coalesce(sum(leave_month_extra), 0) as b_leave_month_extra_all_months,
         coalesce(sum(pending) filter (where is_leftish and p_from <= (select today from td) and pending > 0), 0) as c_ledger_pending_of_left,
         count(distinct student_id) filter (where is_leftish and p_from <= (select today from td) and pending > 0) as c_left_students_with_pending,
         coalesce(sum(pending) filter (where app_billable and (is_leftish or exit_date < (select today from td)) and p_from <= (select today from td) and pending > 0), 0) as d_dashboard_pending_wrong
  from j group by j.hostel_id
),
stu as (
  select st.hostel_id,
         count(*) filter (where st.app_billable and (st.is_leftish or st.exit_date < (select today from td))) as d_students_counted_but_gone,
         count(*) filter (where st.app_billable and not st.is_leftish and coalesce(st.status, '') <> 'active'
                            and (st.exit_date is null or st.exit_date >= (select today from td))) as e_templeave_null_odd_billable
  from st group by st.hostel_id
),
hs as (select hostel_id from per union select hostel_id from stu)
select case when grouping(h.code) = 1 then 'TOTAL' else coalesce(h.code, '(no hostel)') end as hostel,
       sum(coalesce(per.oct_bills, 0)) as oct_bills, sum(coalesce(per.oct_billed, 0)) as oct_billed_total,
       sum(coalesce(per.a_oct_bills_of_left, 0)) as a_oct_bills_of_left_students,
       sum(coalesce(per.a_oct_billed_wrongly, 0)) as a_oct_billed_wrongly,
       sum(coalesce(per.b_leave_month_extra_all_months, 0)) as b_leave_month_extra_all_months,
       sum(coalesce(per.c_ledger_pending_of_left, 0)) as c_ledger_pending_of_left_students,
       sum(coalesce(per.c_left_students_with_pending, 0)) as c_left_students_with_pending,
       sum(coalesce(per.d_dashboard_pending_wrong, 0)) as d_dashboard_pending_wrong,
       sum(coalesce(stu.d_students_counted_but_gone, 0)) as d_students_counted_billable_but_gone,
       sum(coalesce(stu.e_templeave_null_odd_billable, 0)) as e_templeave_null_or_odd_status_billable
from hs
left join per on per.hostel_id is not distinct from hs.hostel_id
left join stu on stu.hostel_id is not distinct from hs.hostel_id
left join hostels h on h.id = hs.hostel_id
group by rollup (h.code)
order by grouping(h.code), h.code;
