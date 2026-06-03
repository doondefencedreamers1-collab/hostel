-- =====================================================================
--  DDD HOSTEL MANAGEMENT SYSTEM  ·  001_schema.sql
--  Run this FIRST in Supabase → SQL Editor.
--  Covers every module in the spec, including the previously-missing ones.
-- =====================================================================

create extension if not exists "pgcrypto";

-- helper: auto-update updated_at
create or replace function set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end; $$ language plpgsql;

-- ============ IDENTITY & ACCESS ============
create table roles (
  id uuid primary key default gen_random_uuid(),
  name text unique not null,          -- director | manager | accountant | staff
  description text,
  created_at timestamptz default now()
);

-- app profile, 1:1 with Supabase auth.users
create table users (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text,
  phone text,
  role_id uuid references roles(id),
  is_active boolean default true,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'active'
);

create table hostels (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text unique not null,
  type text check (type in ('boys','girls')) not null default 'boys',
  address text,
  manager_user_id uuid references users(id),
  manager_name text,
  contact_number text,
  total_floors int default 1,
  monthly_rent numeric(12,2) default 0,
  security_deposit numeric(12,2) default 0,
  owner_name text,
  owner_mobile text,
  agreement_start date,
  agreement_end date,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'active'        -- active | inactive
);

create table user_hostel_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  hostel_id uuid references hostels(id) on delete cascade,
  created_at timestamptz default now(),
  unique (user_id, hostel_id)
);

-- ============ ROOMS / BEDS ============
create table rooms (
  id uuid primary key default gen_random_uuid(),
  hostel_id uuid references hostels(id) on delete cascade,
  floor_number int default 0,
  room_number text not null,
  room_type text default '4 seater',
  total_beds int not null default 1,
  attached_bathroom boolean default false,
  is_ac boolean default false,
  monthly_fee_per_bed numeric(10,2) default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'active',
  unique (hostel_id, room_number)
);

create table students (
  id uuid primary key default gen_random_uuid(),
  admission_number text,
  full_name text not null,
  father_name text, mother_name text,
  mobile text, parent_mobile text, whatsapp text, email text,
  course text, batch text,
  hostel_id uuid references hostels(id),
  current_bed_id uuid,                -- fk added after beds table
  joining_date date, exit_date date,
  monthly_fee numeric(10,2) default 0,
  security_deposit numeric(10,2) default 0,
  id_proof_type text, id_proof_number text,
  photo_url text,
  address text, state text,
  emergency_contact text,
  medical_note text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'active'        -- active | left | temporary_leave
);

create table beds (
  id uuid primary key default gen_random_uuid(),
  hostel_id uuid references hostels(id) on delete cascade,
  room_id uuid references rooms(id) on delete cascade,
  bed_number text not null,
  bed_status text default 'vacant'
    check (bed_status in ('vacant','occupied','reserved','maintenance')),
  student_id uuid references students(id) on delete set null,
  joining_date date,
  monthly_fee numeric(10,2) default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'active',
  unique (room_id, bed_number)
);
alter table students add constraint students_bed_fk
  foreign key (current_bed_id) references beds(id) on delete set null;

create table bed_allocations (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references students(id),
  bed_id uuid references beds(id),
  hostel_id uuid references hostels(id),
  from_date date not null default current_date,
  to_date date,
  monthly_fee numeric(10,2),
  created_at timestamptz default now(),
  created_by uuid,
  status text default 'active'
);

-- ============ FEES / INCOME ============
create table monthly_dues (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references students(id) on delete cascade,
  hostel_id uuid references hostels(id),
  month date not null,
  fee_amount numeric(10,2) not null default 0,
  discount numeric(10,2) default 0,
  paid_amount numeric(10,2) default 0,
  payable numeric(10,2) generated always as (fee_amount - discount) stored,
  pending numeric(10,2) generated always as (fee_amount - discount - paid_amount) stored,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'pending',      -- pending | partial | paid
  unique (student_id, month)
);

create table fee_payments (
  id uuid primary key default gen_random_uuid(),
  due_id uuid references monthly_dues(id),
  student_id uuid references students(id),
  hostel_id uuid references hostels(id),
  amount numeric(10,2) not null,
  payment_date date default current_date,
  mode text,                          -- cash | upi | bank | card | cheque
  transaction_id text,
  receipt_number text,
  proof_url text,
  collected_by uuid references users(id),
  remarks text,
  created_at timestamptz default now(),
  created_by uuid,
  status text default 'active'
);

-- ============ EXPENSES ============
create table expense_categories (
  id uuid primary key default gen_random_uuid(),
  name text unique not null
);

create table expenses (
  id uuid primary key default gen_random_uuid(),
  hostel_id uuid references hostels(id),
  expense_date date default current_date,
  category text,
  amount numeric(12,2) not null,
  paid_to text,
  mode text,
  bill_url text,
  added_by uuid references users(id),
  approved_by uuid references users(id),
  remarks text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'pending'       -- pending | approved | rejected
);

-- ============ STAFF / SALARY / ATTENDANCE ============
create table employees (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  role text,
  hostel_id uuid references hostels(id),
  mobile text, address text, aadhaar text,
  joining_date date,
  monthly_salary numeric(10,2) default 0,
  advance numeric(10,2) default 0,
  duty_timing text,
  photo_url text, id_proof_url text,
  user_id uuid references users(id),
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'active'        -- active | left
);

create table salary_payments (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) on delete cascade,
  hostel_id uuid references hostels(id),
  month date not null,
  salary_amount numeric(10,2) default 0,
  advance numeric(10,2) default 0,
  paid_amount numeric(10,2) default 0,
  pending numeric(10,2) generated always as (salary_amount - paid_amount) stored,
  paid_date date,
  created_at timestamptz default now(),
  created_by uuid,
  status text default 'pending'
);

create table staff_attendance (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references employees(id) on delete cascade,
  hostel_id uuid references hostels(id),
  date date default current_date,
  present boolean default true,
  remarks text,
  created_at timestamptz default now(),
  created_by uuid,
  unique (employee_id, date)
);

create table student_attendance (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references students(id) on delete cascade,
  hostel_id uuid references hostels(id),
  date date default current_date,
  present boolean default true,
  created_at timestamptz default now(),
  created_by uuid,
  unique (student_id, date)
);

-- ============ COMPLAINTS / MAINTENANCE / INVENTORY ============
create table complaints (
  id uuid primary key default gen_random_uuid(),
  hostel_id uuid references hostels(id),
  room_id uuid references rooms(id),
  student_id uuid references students(id),
  type text, description text,
  priority text default 'low',        -- low | medium | high | emergency
  assigned_employee_id uuid references employees(id),
  resolution_date date,
  photo_url text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  created_by uuid,
  status text default 'open'          -- open | in_progress | resolved
);

create table maintenance_tasks (
  id uuid primary key default gen_random_uuid(),
  hostel_id uuid references hostels(id),
  complaint_id uuid references complaints(id),
  title text, description text,
  assigned_employee_id uuid references employees(id),
  due_date date,
  created_at timestamptz default now(),
  created_by uuid,
  status text default 'open'
);

create table vendors (
  id uuid primary key default gen_random_uuid(),
  name text not null, phone text, category text,
  created_at timestamptz default now(), created_by uuid, status text default 'active'
);

create table inventory (
  id uuid primary key default gen_random_uuid(),
  hostel_id uuid references hostels(id),
  item_name text not null, category text,
  quantity int default 0,
  purchase_date date, price numeric(10,2),
  room_id uuid references rooms(id),
  condition text, vendor_id uuid references vendors(id),
  bill_url text,
  created_at timestamptz default now(), updated_at timestamptz default now(),
  created_by uuid, status text default 'active'
);

-- ============ SYSTEM ============
create table documents (
  id uuid primary key default gen_random_uuid(),
  entity_type text, entity_id uuid,
  file_url text, file_type text,
  created_at timestamptz default now(), created_by uuid
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id),
  hostel_id uuid references hostels(id),
  type text, title text, body text,
  is_read boolean default false,
  created_at timestamptz default now()
);

create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid,
  action text, entity_type text, entity_id uuid,
  before jsonb, after jsonb,
  created_at timestamptz default now()
);

-- ============ updated_at triggers ============
do $$ declare t text;
begin
  for t in select unnest(array['users','hostels','rooms','beds','students',
    'monthly_dues','expenses','employees','complaints','inventory']) loop
    execute format('create trigger trg_%s_upd before update on %I
      for each row execute function set_updated_at();', t, t);
  end loop;
end $$;

-- ============ AUTO: free bed + close allocation when a student leaves ============
create or replace function on_student_left() returns trigger as $$
begin
  if new.status = 'left' and old.status <> 'left' then
    update beds set student_id = null, bed_status = 'vacant'
      where student_id = new.id;
    update bed_allocations set to_date = current_date, status='closed'
      where student_id = new.id and to_date is null;
    new.current_bed_id = null;
  end if;
  return new;
end; $$ language plpgsql;
create trigger trg_student_left before update on students
  for each row execute function on_student_left();

-- ============ AUTO: generate monthly dues for all active students ============
-- call: select generate_monthly_dues('2026-06-01');
create or replace function generate_monthly_dues(p_month date)
returns int as $$
declare cnt int := 0; r record;
begin
  for r in select id, hostel_id, monthly_fee from students where status='active' loop
    insert into monthly_dues(student_id, hostel_id, month, fee_amount)
    values (r.id, r.hostel_id, date_trunc('month', p_month)::date, r.monthly_fee)
    on conflict (student_id, month) do nothing;
    cnt := cnt + 1;
  end loop;
  return cnt;
end; $$ language plpgsql;

-- ============ seed expense categories ============
insert into expense_categories(name) values
  ('Food/Grocery'),('Milk'),('Vegetables'),('Gas Cylinder'),('Electricity'),
  ('Water'),('Internet'),('Cleaning'),('Repair & Maintenance'),('Salary'),
  ('Rent'),('Security'),('Transport'),('Medical'),('Misc')
on conflict do nothing;

insert into roles(name, description) values
  ('director','Full access to all hostels'),
  ('manager','Assigned hostel only'),
  ('accountant','Finance modules across hostels'),
  ('staff','Limited self profile')
on conflict do nothing;
