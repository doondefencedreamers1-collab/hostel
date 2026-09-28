-- READ-ONLY: students with missing joining_date and/or zero monthly_fee.
-- Fix these before rollout — no dues (and no paid_till) can be computed for them.
select
  case when s.joining_date is null and coalesce(s.monthly_fee,0)=0 then 'BOTH'
       when s.joining_date is null then 'NO_JOINING_DATE'
       else 'ZERO_FEE' end            as problem,
  s.full_name,
  coalesce(h.code, '—')               as hostel_code,
  coalesce(h.name, '(no hostel)')     as hostel_name,
  s.admission_number,
  s.status,
  s.joining_date,
  s.monthly_fee,
  s.id                                as student_id
from students s
left join hostels h on h.id = s.hostel_id
where s.joining_date is null or coalesce(s.monthly_fee,0) = 0
order by problem, hostel_code, s.full_name;
