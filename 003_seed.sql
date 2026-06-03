-- =====================================================================
--  DDD HOSTEL MANAGEMENT SYSTEM  ·  003_seed.sql   (OPTIONAL sample data)
--  Run this THIRD if you want demo hostels/rooms/beds/students to start.
--  Safe to skip — you can add everything from inside the app.
-- =====================================================================

do $$
declare h1 uuid; h2 uuid; h3 uuid;
        r1 uuid; r2 uuid; r3 uuid;
        s1 uuid; s2 uuid; s3 uuid; s4 uuid;
        b uuid;
begin
  insert into hostels(name,code,type,address,manager_name,contact_number,total_floors,monthly_rent,security_deposit,owner_name,owner_mobile,agreement_start,agreement_end)
  values ('DDD Boys Hostel 1','DDB1','boys','Prem Nagar, Dehradun','Rajesh Negi','9876500001',2,90000,200000,'R.P. Singh','9000011111','2024-04-01','2027-03-31') returning id into h1;
  insert into hostels(name,code,type,address,manager_name,contact_number,total_floors)
  values ('DDD Boys Hostel 2','DDB2','boys','Ballupur, Dehradun','Sunil Rawat','9876500002',3) returning id into h2;
  insert into hostels(name,code,type,address,manager_name,contact_number,total_floors)
  values ('DDD Girls Hostel 1','DDG1','girls','Clement Town, Dehradun','Anjali Sharma','9876500003',2) returning id into h3;

  insert into rooms(hostel_id,floor_number,room_number,room_type,total_beds,attached_bathroom,monthly_fee_per_bed)
    values (h1,1,'101','4 seater',4,true,8000) returning id into r1;
  insert into rooms(hostel_id,floor_number,room_number,room_type,total_beds,attached_bathroom,monthly_fee_per_bed)
    values (h1,1,'102','4 seater',4,true,8000) returning id into r2;
  insert into rooms(hostel_id,floor_number,room_number,room_type,total_beds,attached_bathroom,monthly_fee_per_bed)
    values (h3,1,'G1','3 seater',3,true,8500) returning id into r3;

  -- students
  insert into students(full_name,father_name,mobile,parent_mobile,whatsapp,course,batch,admission_number,hostel_id,monthly_fee,security_deposit,joining_date,address,state)
    values ('Aarav Thapa','Mohan Thapa','9000000001','9000000011','9000000001','NDA','2026','DDD-1042',h1,8000,5000,'2025-04-01','Pithoragarh','Uttarakhand') returning id into s1;
  insert into students(full_name,father_name,mobile,parent_mobile,course,admission_number,hostel_id,monthly_fee,joining_date)
    values ('Rohan Mehra','Vinod Mehra','9000000002','9000000012','NDA Foundation','DDD-1043',h1,8000,'2025-04-05') returning id into s2;
  insert into students(full_name,father_name,mobile,course,admission_number,hostel_id,monthly_fee,joining_date)
    values ('Kabir Singh','Jeet Singh','9000000003','CDS','DDD-1051',h1,7500,'2025-05-01') returning id into s3;
  insert into students(full_name,father_name,mobile,course,admission_number,hostel_id,monthly_fee,joining_date)
    values ('Ananya Rao','Suresh Rao','9000000004','SSB','DDD-1077',h3,8500,'2025-04-10') returning id into s4;

  -- beds for room 101, allocate first three students
  insert into beds(hostel_id,room_id,bed_number,bed_status,student_id,joining_date,monthly_fee)
    values (h1,r1,'1','occupied',s1,'2025-04-01',8000);
  insert into beds(hostel_id,room_id,bed_number,bed_status,student_id,joining_date,monthly_fee)
    values (h1,r1,'2','occupied',s2,'2025-04-05',8000);
  insert into beds(hostel_id,room_id,bed_number,bed_status,monthly_fee) values (h1,r1,'3','reserved',8000);
  insert into beds(hostel_id,room_id,bed_number,bed_status,monthly_fee) values (h1,r1,'4','maintenance',8000);
  -- room 102 empty
  insert into beds(hostel_id,room_id,bed_number,bed_status,student_id,joining_date,monthly_fee)
    values (h1,r2,'1','occupied',s3,'2025-05-01',8000);
  insert into beds(hostel_id,room_id,bed_number,bed_status,monthly_fee) values (h1,r2,'2','vacant',8000);
  insert into beds(hostel_id,room_id,bed_number,bed_status,monthly_fee) values (h1,r2,'3','vacant',8000);
  insert into beds(hostel_id,room_id,bed_number,bed_status,monthly_fee) values (h1,r2,'4','vacant',8000);
  -- girls room
  insert into beds(hostel_id,room_id,bed_number,bed_status,student_id,joining_date,monthly_fee)
    values (h3,r3,'1','occupied',s4,'2025-04-10',8500);
  insert into beds(hostel_id,room_id,bed_number,bed_status,monthly_fee) values (h3,r3,'2','vacant',8500);
  insert into beds(hostel_id,room_id,bed_number,bed_status,monthly_fee) values (h3,r3,'3','vacant',8500);

  -- sync current_bed_id
  update students s set current_bed_id = b.id from beds b where b.student_id = s.id;

  -- dues for June 2026 + some payments
  perform generate_monthly_dues('2026-06-01');
  update monthly_dues set paid_amount = fee_amount, status='paid' where student_id = s1;
  update monthly_dues set paid_amount = fee_amount, status='paid' where student_id = s3;
  update monthly_dues set paid_amount = 4250, status='partial' where student_id = s4;

  insert into fee_payments(student_id,hostel_id,amount,mode,receipt_number,payment_date)
    values (s1,h1,8000,'upi','R-2041','2026-06-03'),
           (s3,h1,7500,'cash','R-2039','2026-06-02'),
           (s4,h3,4250,'bank','R-2035','2026-06-01');

  -- expenses
  insert into expenses(hostel_id,expense_date,category,amount,paid_to,mode,status)
    values (h1,'2026-06-03','Food/Grocery',4200,'Sharma Kirana','cash','approved'),
           (h1,'2026-06-03','Milk',920,'Amul','cash','approved'),
           (h2,'2026-06-02','Repair & Maintenance',15500,'Cool Tech AC','upi','pending');

  -- employees
  insert into employees(full_name,role,hostel_id,mobile,monthly_salary,joining_date)
    values ('Rajesh Negi','Warden',h1,'9876510001',22000,'2024-04-01'),
           ('Mohan Lal','Cook',h1,'9876510002',15000,'2024-06-01'),
           ('Geeta Devi','Housekeeping',h1,'9876510003',11000,'2025-01-01'),
           ('Anjali Sharma','Warden',h3,'9876510004',23000,'2024-04-01');

  -- a couple of complaints + inventory
  insert into complaints(hostel_id,room_id,student_id,type,description,priority,status)
    values (h1,r1,s1,'Electricity','Fan not working in room 101','medium','open');
  insert into inventory(hostel_id,item_name,category,quantity,price,condition)
    values (h1,'Ceiling Fan','Electrical',16,1400,'good'),
           (h1,'Mattress','Bedding',32,1200,'good');
end $$;
