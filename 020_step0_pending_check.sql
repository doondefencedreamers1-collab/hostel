-- =====================================================================
-- 020_step0_pending_check.sql   READ-ONLY (sirf SELECT, kuch change nahi)
-- Har query alag chalayein (select karke Run). Result copy karke bhejein.
-- "Pending Fees" card ka rule (app jaisa hi):
--   pending > 0, due ka start (period_from ya month) <= aaj (IST),
--   student billable: status <> 'left', joining_date hai, monthly_fee > 0
-- =====================================================================

-- ---------- Q1: TOTAL — card ka number DB se match karta hai? ----------
with t as (select (now() at time zone 'Asia/Kolkata')::date as today)
select
  count(*)                                   as due_rows,
  count(distinct d.student_id)               as students,
  sum(d.pending)                             as card_pending,
  (select sum(pending) from monthly_dues where pending > 0) as all_pending_incl_left,
  (select count(*) from monthly_dues)        as total_due_rows
from monthly_dues d
join students s on s.id = d.student_id, t
where d.pending > 0
  and coalesce(d.period_from, d.month) <= t.today
  and s.status is distinct from 'left' and s.joining_date is not null and coalesce(s.monthly_fee,0) > 0;

-- ---------- Q2: PENDING — due month ke hisaab se ----------
with t as (select (now() at time zone 'Asia/Kolkata')::date as today)
select to_char(date_trunc('month', d.month), 'YYYY-MM') as due_month,
       count(*)                       as rows,
       count(distinct d.student_id)   as students,
       sum(d.fee_amount)              as billed,
       sum(d.paid_amount)             as paid,
       sum(d.pending)                 as pending
from monthly_dues d
join students s on s.id = d.student_id, t
where d.pending > 0
  and coalesce(d.period_from, d.month) <= t.today
  and s.status is distinct from 'left' and s.joining_date is not null and coalesce(s.monthly_fee,0) > 0
group by 1 order by 1;

-- ---------- Q3: DUES ROWS KAB BANE (created_at, IST din) — pichhle 45 din ----------
-- 017 ke baad koi bada jump dikhe to yahi batayega. created_by khali = system/SQL ne banaya.
select (d.created_at at time zone 'Asia/Kolkata')::date   as created_on,
       count(*)                                          as rows,
       count(*) filter (where d.created_by is null)      as by_system,
       min(d.month)                                      as oldest_month,
       max(d.month)                                      as newest_month,
       sum(d.fee_amount)                                 as billed,
       sum(d.pending)                                    as still_pending
from monthly_dues d
where d.created_at >= now() - interval '45 days'
group by 1 order by 1;

-- ---------- Q4: TOP 20 students — sabse zyada pending ----------
with t as (select (now() at time zone 'Asia/Kolkata')::date as today),
p as (
  select d.student_id, count(*) as months_pending, sum(d.pending) as pending,
         min(d.month) as oldest_due, max(d.month) as latest_due
  from monthly_dues d, t
  where d.pending > 0 and coalesce(d.period_from, d.month) <= t.today
  group by d.student_id
)
select s.full_name, s.admission_number, h.name as hostel, s.joining_date,
       s.monthly_fee, s.paid_till, p.months_pending, p.oldest_due, p.latest_due, p.pending,
       (select max(payment_date) from fee_payments f where f.student_id = s.id) as last_payment,
       (select coalesce(sum(amount),0) from fee_payments f where f.student_id = s.id) as total_paid_ever
from p join students s on s.id = p.student_id
left join hostels h on h.id = s.hostel_id
where s.status is distinct from 'left' and s.joining_date is not null and coalesce(s.monthly_fee,0) > 0
order by p.pending desc
limit 20;

-- ---------- Q5: PENDING STUDENTS — kitno ne kabhi payment app mein jama hi nahi kiya ----------
-- (agar yeh number bada hai to payment offline hua, app mein entry nahi hui)
with t as (select (now() at time zone 'Asia/Kolkata')::date as today),
p as (
  select d.student_id, sum(d.pending) as pending, count(*) as months
  from monthly_dues d, t
  where d.pending > 0 and coalesce(d.period_from, d.month) <= t.today
  group by d.student_id
)
select case when not exists (select 1 from fee_payments f where f.student_id = p.student_id)
            then 'kabhi payment entry nahi' else 'payment entry hai' end as kind,
       count(*) as students, sum(p.pending) as pending, round(avg(p.months),1) as avg_months_pending
from p join students s on s.id = p.student_id
where s.status is distinct from 'left' and s.joining_date is not null and coalesce(s.monthly_fee,0) > 0
group by 1;
