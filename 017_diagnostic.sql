-- =====================================================================
-- 017 DIAGNOSTIC — READ-ONLY. Run each QUERY separately in SQL Editor
-- (select its lines -> Run) and send me all 3 results.
-- =====================================================================

-- ---------------------------------------------------------------------
-- QUERY 1 — status counts (same rule the app uses today) + why
-- ---------------------------------------------------------------------
with t as (select (now() at time zone 'Asia/Kolkata')::date d),
s as (
  select st.*,
         (st.status = 'left' or st.joining_date is null or coalesce(st.monthly_fee, 0) <= 0) as not_billable,
         (select min(date_trunc('month', md.month))::date from monthly_dues md
           where md.student_id = st.id and coalesce(md.pending, 0) > 0) as first_unpaid
  from students st
)
select
  count(*)                                                                       as total_students,
  count(*) filter (where status = 'left')                                        as left_students,
  count(*) filter (where status <> 'left' and (joining_date is null or coalesce(monthly_fee,0) <= 0)) as not_billable_active,
  count(*) filter (where status <> 'left' and paid_till is null)                  as no_paid_till,
  count(*) filter (where status <> 'left' and paid_till < (select d from t))      as app_shows_overdue,
  count(*) filter (where status <> 'left' and paid_till < (select d from t) and not_billable) as overdue_but_not_billable,
  count(*) filter (where status <> 'left' and paid_till >= (select d from t)
                   and paid_till - (select d from t) + 1 <= 7)                    as due_in_7_days,
  count(*) filter (where status <> 'left' and paid_till >= (date_trunc('month', (select d from t)) + interval '1 month - 1 day')::date) as paid_in_advance,
  count(*) filter (where status <> 'left' and first_unpaid = date_trunc('month', (select d from t))::date) as only_this_month_unpaid,
  count(*) filter (where status <> 'left' and first_unpaid < date_trunc('month', (select d from t))::date) as has_older_unpaid_months,
  (select sum(pending) from monthly_dues where coalesce(pending,0) > 0
      and coalesce(period_from, month) <= (select d from t))                     as pending_total_app,
  (select sum(md.pending) from monthly_dues md join s on s.id = md.student_id
    where coalesce(md.pending,0) > 0 and coalesce(md.period_from, md.month) <= (select d from t)
      and s.not_billable)                                                        as pending_from_not_billable
from s;

-- ---------------------------------------------------------------------
-- QUERY 2 — unpaid dues by month (are old months still open?)
-- ---------------------------------------------------------------------
select to_char(date_trunc('month', month), 'YYYY-MM') as month,
       count(*)                                     as dues_rows,
       count(*) filter (where coalesce(pending,0) > 0) as unpaid_rows,
       count(*) filter (where status = 'paid')      as paid_rows,
       coalesce(sum(pending) filter (where coalesce(pending,0) > 0), 0) as pending_amount
from monthly_dues
group by 1 order by 1;

-- ---------------------------------------------------------------------
-- QUERY 3 — top 10 overdue students
-- ---------------------------------------------------------------------
select st.full_name, h.code as hostel, st.joining_date, st.monthly_fee, st.status,
       st.paid_till,
       (select min(date_trunc('month', md.month))::date from monthly_dues md
         where md.student_id = st.id and coalesce(md.pending,0) > 0) as first_unpaid_month,
       (select count(*) from monthly_dues md where md.student_id = st.id and coalesce(md.pending,0) > 0) as unpaid_months,
       (select coalesce(sum(md.pending),0) from monthly_dues md where md.student_id = st.id and coalesce(md.pending,0) > 0
          and coalesce(md.period_from, md.month) <= (now() at time zone 'Asia/Kolkata')::date) as pending_amount
from students st left join hostels h on h.id = st.hostel_id
where st.status <> 'left' and st.paid_till < (now() at time zone 'Asia/Kolkata')::date
order by pending_amount desc, st.paid_till
limit 10;
