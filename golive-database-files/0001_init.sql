-- Study Beyond Agent Application Portal (SBAP): core schema, access rules and audit.
-- Access model (enforced here, not only in the app):
--   admin       : everything
--   compliance  : read/review every student and partner
--   counsellor  : students assigned to them, and students of partners they own
--   partner     : their own partner record and their own students
--   student     : their own student record
create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums
create type public.user_role as enum ('admin','compliance','counsellor','partner','student');
create type public.partner_type as enum ('business','individual');
create type public.partner_status as enum ('applied','fit_check','verifying','agreement','active','paused','rejected');
create type public.doc_status as enum ('missing','uploaded','needs_fix','approved','expiring','expired');
create type public.owner_kind as enum ('student','partner');
create type public.app_stage as enum (
  'enquiry','profile_complete','documents_complete','applied','offer_conditional','offer_unconditional',
  'offer_accepted','deposit_paid','cas_coe_issued','visa_lodged','visa_granted','visa_refused','enrolled',
  'declined','withdrawn','deferred');

-- ---------------------------------------------------------------- tables
create table public.partners (
  id uuid primary key default gen_random_uuid(),
  type public.partner_type not null,
  company_name text not null,
  director_name text,
  email text not null,
  whatsapp text,
  country char(2) not null default 'BD',
  city text,
  address text,
  website text,
  years_experience text,
  target_destinations text[] not null default '{}',
  expected_students_per_intake int,
  status public.partner_status not null default 'applied',
  fit_score int check (fit_score between 0 and 100),
  owner_counsellor_id uuid,
  commission_split_pct numeric(5,2),
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.user_role not null default 'student',
  full_name text,
  email text,
  phone text,
  partner_id uuid references public.partners(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.partners add constraint partners_owner_fk
  foreign key (owner_counsellor_id) references public.profiles(id) on delete set null;

create table public.students (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  partner_id uuid references public.partners(id) on delete set null,
  counsellor_id uuid references public.profiles(id) on delete set null,
  full_name text not null,
  email text,
  phone text,
  source text,
  destination text,                 -- e.g. 'NZ', 'UK'
  study_level text,                 -- e.g. 'master', 'bachelor'
  stage public.app_stage not null default 'enquiry',
  profile jsonb not null default '{}'::jsonb,   -- application_profile.json standard
  rules text,                       -- what must / must not be said (fed to the AI every time)
  consent_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.students (partner_id);
create index on public.students (counsellor_id);

create table public.requirements (
  id uuid primary key default gen_random_uuid(),
  applies_to public.owner_kind not null,
  track text not null default 'all',          -- partner: business|individual ; student: country code or 'all'
  study_level text not null default 'all',
  category text not null,
  name text not null,
  description text,
  mandatory boolean not null default true,
  has_expiry boolean not null default false,
  sort_order int not null default 0,
  unique (applies_to, track, study_level, name)
);

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  owner_kind public.owner_kind not null,
  student_id uuid references public.students(id) on delete cascade,
  partner_id uuid references public.partners(id) on delete cascade,
  requirement_id uuid references public.requirements(id) on delete set null,
  storage_path text,
  file_name text,
  mime_type text,
  size_bytes bigint,
  status public.doc_status not null default 'missing',
  expiry_date date,
  reason text,
  ai_extracted jsonb,
  reviewer_id uuid references public.profiles(id) on delete set null,
  second_reviewer_id uuid references public.profiles(id) on delete set null,
  uploaded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((owner_kind = 'student' and student_id is not null and partner_id is null)
      or (owner_kind = 'partner' and partner_id is not null and student_id is null))
);
create index on public.documents (student_id);
create index on public.documents (partner_id);

create table public.institutions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  country char(2) not null,
  city text,
  website text,
  qs_rank text,
  notes text,
  unique (name, country)
);

create table public.courses (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  name text not null,
  level text,
  field text,
  duration text,
  tuition_per_year numeric,
  currency char(3),
  intakes text[] not null default '{}',
  ielts_overall numeric(3,1),
  min_gpa text,
  scholarship text,
  url text
);
create index on public.courses (institution_id);

create table public.deadlines (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid references public.institutions(id) on delete cascade,
  intake text not null,
  kind text not null,            -- application, deposit, CAS, early bird...
  due_on date not null,
  note text
);

create table public.applications (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  institution_id uuid references public.institutions(id) on delete set null,
  course_id uuid references public.courses(id) on delete set null,
  course_name text,
  intake text,
  stage public.app_stage not null default 'enquiry',
  university_ref text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.applications (student_id);

create table public.application_events (
  id bigint generated always as identity primary key,
  application_id uuid not null references public.applications(id) on delete cascade,
  from_stage public.app_stage,
  to_stage public.app_stage not null,
  reason text,
  actor_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.messages (
  id bigint generated always as identity primary key,
  student_id uuid not null references public.students(id) on delete cascade,
  sender_id uuid references public.profiles(id) on delete set null,
  is_ai boolean not null default false,
  body text not null check (length(body) <= 8000),
  created_at timestamptz not null default now()
);
create index on public.messages (student_id, created_at);

create table public.ai_runs (
  id bigint generated always as identity primary key,
  kind text not null,              -- chat, extract, checklist, match, form, draft, summary
  student_id uuid references public.students(id) on delete cascade,
  partner_id uuid references public.partners(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  model text,
  input_tokens int,
  output_tokens int,
  output jsonb,
  status text not null default 'draft',  -- draft | approved | rejected
  approved_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid,
  action text not null,
  entity text not null,
  entity_id text,
  detail jsonb,
  created_at timestamptz not null default now()
);
create index on public.audit_log (entity, entity_id);

-- ---------------------------------------------------------------- helper functions
-- security definer so policies can read profiles without recursive RLS.
create or replace function public.my_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create or replace function public.my_partner_id() returns uuid
language sql stable security definer set search_path = public as $$
  select partner_id from public.profiles where id = auth.uid() and active and role = 'partner'
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin','compliance','counsellor'), false)
$$;

create or replace function public.sees_everything() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin','compliance'), false)
$$;

create or replace function public.can_access_student(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.students s
    left join public.partners p on p.id = s.partner_id
    where s.id = sid and (
         public.sees_everything()
      or (public.my_role() = 'counsellor' and (s.counsellor_id = auth.uid() or p.owner_counsellor_id = auth.uid()))
      or (public.my_role() = 'partner' and s.partner_id is not null and s.partner_id = public.my_partner_id())
      or (public.my_role() = 'student' and s.user_id = auth.uid())
    ))
$$;

create or replace function public.can_access_partner(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.partners p where p.id = pid and (
         public.sees_everything()
      or (public.my_role() = 'counsellor' and p.owner_counsellor_id = auth.uid())
      or (public.my_role() = 'partner' and p.id = public.my_partner_id())
    ))
$$;

-- ---------------------------------------------------------------- triggers
create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger t_partners_upd before update on public.partners for each row execute function public.touch_updated_at();
create trigger t_students_upd before update on public.students for each row execute function public.touch_updated_at();
create trigger t_documents_upd before update on public.documents for each row execute function public.touch_updated_at();
create trigger t_apps_upd before update on public.applications for each row execute function public.touch_updated_at();

-- New auth user -> profile row. Role is always 'student' here; staff and partner roles
-- are granted only by an admin (or by partner sign-up via the server with the service key).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', ''))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Nobody but an admin (or the server's service key, where auth.uid() is null) may change roles, partner links or the active flag.
create or replace function public.guard_profile_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.role is distinct from old.role or new.partner_id is distinct from old.partner_id
      or new.active is distinct from old.active)
     and auth.uid() is not null
     and coalesce(public.my_role() <> 'admin', true) then
    raise exception 'only an admin can change role, partner or active status';
  end if;
  return new;
end $$;
create trigger t_profiles_guard before update on public.profiles for each row execute function public.guard_profile_update();

-- Partners and students cannot move their own stage/status, counsellor or partner link.
create or replace function public.guard_student_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() in ('partner','student') and (
       new.stage is distinct from old.stage or new.counsellor_id is distinct from old.counsellor_id
    or new.partner_id is distinct from old.partner_id or new.user_id is distinct from old.user_id
    or new.rules is distinct from old.rules) then
    raise exception 'not allowed to change stage, assignment or rules';
  end if;
  return new;
end $$;
create trigger t_students_guard before update on public.students for each row execute function public.guard_student_update();

create or replace function public.guard_partner_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() = 'partner' and (
       new.status is distinct from old.status or new.fit_score is distinct from old.fit_score
    or new.owner_counsellor_id is distinct from old.owner_counsellor_id
    or new.commission_split_pct is distinct from old.commission_split_pct
    or new.activated_at is distinct from old.activated_at) then
    raise exception 'not allowed to change status, score, owner or commission';
  end if;
  return new;
end $$;
create trigger t_partners_guard before update on public.partners for each row execute function public.guard_partner_update();

-- Only staff can approve documents; owners can upload / re-upload (status uploaded) only.
create or replace function public.guard_document_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() is null for the server's service key, which may set any status.
  if auth.uid() is not null and not public.is_staff() then
    if new.status not in ('missing','uploaded') or new.reviewer_id is distinct from old.reviewer_id
       or new.second_reviewer_id is distinct from old.second_reviewer_id then
      raise exception 'only staff can review documents';
    end if;
  end if;
  return new;
end $$;
create trigger t_documents_guard before update on public.documents for each row execute function public.guard_document_update();

-- Stage changes on applications are logged automatically, with the actor.
create or replace function public.log_application_stage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.application_events (application_id, from_stage, to_stage, actor_id)
    values (new.id, null, new.stage, auth.uid());
  elsif new.stage is distinct from old.stage then
    insert into public.application_events (application_id, from_stage, to_stage, actor_id, reason)
    values (new.id, old.stage, new.stage, auth.uid(), nullif(current_setting('sbap.reason', true), ''));
  end if;
  return new;
end $$;
create trigger t_apps_log after insert or update on public.applications
  for each row execute function public.log_application_stage();

-- Generic audit trail for sensitive tables.
create or replace function public.audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor_id, action, entity, entity_id, detail)
  values (auth.uid(), lower(tg_op), tg_table_name,
          coalesce((case when tg_op = 'DELETE' then old.id else new.id end)::text, null),
          case when tg_op = 'UPDATE' then jsonb_build_object('status_from',
                 to_jsonb(old)->>'status', 'status_to', to_jsonb(new)->>'status',
                 'stage_from', to_jsonb(old)->>'stage', 'stage_to', to_jsonb(new)->>'stage')
               else null end);
  return coalesce(new, old);
end $$;
create trigger t_audit_students after insert or update or delete on public.students for each row execute function public.audit();
create trigger t_audit_partners after insert or update or delete on public.partners for each row execute function public.audit();
create trigger t_audit_documents after insert or update or delete on public.documents for each row execute function public.audit();
create trigger t_audit_applications after insert or update or delete on public.applications for each row execute function public.audit();
create trigger t_audit_profiles after update on public.profiles for each row execute function public.audit();

-- When a student or partner is created, create one 'missing' document row per requirement.
create or replace function public.seed_student_checklist() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.documents (owner_kind, student_id, requirement_id, status)
  select 'student', new.id, r.id, 'missing' from public.requirements r
  where r.applies_to = 'student'
    and r.track in ('all', coalesce(new.destination, 'all'))
    and r.study_level in ('all', coalesce(new.study_level, 'all'));
  return new;
end $$;
create trigger t_students_checklist after insert on public.students for each row execute function public.seed_student_checklist();

create or replace function public.seed_partner_checklist() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.documents (owner_kind, partner_id, requirement_id, status)
  select 'partner', new.id, r.id, 'missing' from public.requirements r
  where r.applies_to = 'partner' and r.track in ('all', new.type::text);
  return new;
end $$;
create trigger t_partners_checklist after insert on public.partners for each row execute function public.seed_partner_checklist();

-- Go-live gate: a partner can only become 'active' when every mandatory item is approved and unexpired.
create or replace function public.partner_ready(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.documents d join public.requirements r on r.id = d.requirement_id
    where d.partner_id = pid and r.mandatory
      and (d.status <> 'approved' or (d.expiry_date is not null and d.expiry_date < current_date)))
$$;
create or replace function public.guard_partner_activation() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and old.status is distinct from 'active' then
    if not public.partner_ready(new.id) then
      raise exception 'partner cannot go live: mandatory documents are not all approved';
    end if;
    new.activated_at := now();
  end if;
  return new;
end $$;
create trigger t_partners_activate before update on public.partners for each row execute function public.guard_partner_activation();

-- ---------------------------------------------------------------- row level security
alter table public.partners enable row level security;
alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.requirements enable row level security;
alter table public.documents enable row level security;
alter table public.institutions enable row level security;
alter table public.courses enable row level security;
alter table public.deadlines enable row level security;
alter table public.applications enable row level security;
alter table public.application_events enable row level security;
alter table public.messages enable row level security;
alter table public.ai_runs enable row level security;
alter table public.audit_log enable row level security;

-- profiles
create policy profiles_self_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());
create policy profiles_self_update on public.profiles for update to authenticated
  using (id = auth.uid() or public.my_role() = 'admin') with check (id = auth.uid() or public.my_role() = 'admin');

-- partners
create policy partners_read on public.partners for select to authenticated using (public.can_access_partner(id));
create policy partners_update on public.partners for update to authenticated
  using (public.can_access_partner(id)) with check (public.can_access_partner(id));
create policy partners_admin_insert on public.partners for insert to authenticated with check (public.my_role() = 'admin');
create policy partners_admin_delete on public.partners for delete to authenticated using (public.my_role() = 'admin');

-- students
create policy students_read on public.students for select to authenticated using (public.can_access_student(id));
create policy students_update on public.students for update to authenticated
  using (public.can_access_student(id)) with check (public.can_access_student(id));
create policy students_insert on public.students for insert to authenticated with check (
     public.is_staff()
  or (public.my_role() = 'partner' and partner_id = public.my_partner_id() and public.my_partner_id() is not null
      and exists (select 1 from public.partners p where p.id = public.my_partner_id() and p.status = 'active'))
  or (public.my_role() = 'student' and user_id = auth.uid() and partner_id is null and counsellor_id is null));
create policy students_admin_delete on public.students for delete to authenticated using (public.my_role() = 'admin');

-- requirements, institutions, courses, deadlines: everyone signed in reads, admin writes
create policy req_read on public.requirements for select to authenticated using (true);
create policy req_admin on public.requirements for all to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');
create policy inst_read on public.institutions for select to authenticated using (true);
create policy inst_admin on public.institutions for all to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');
create policy courses_read on public.courses for select to authenticated using (true);
create policy courses_admin on public.courses for all to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');
create policy deadlines_read on public.deadlines for select to authenticated using (true);
create policy deadlines_admin on public.deadlines for all to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- documents
create policy docs_read on public.documents for select to authenticated using (
  (owner_kind = 'student' and public.can_access_student(student_id))
  or (owner_kind = 'partner' and public.can_access_partner(partner_id)));
create policy docs_insert on public.documents for insert to authenticated with check (
  (owner_kind = 'student' and public.can_access_student(student_id))
  or (owner_kind = 'partner' and public.can_access_partner(partner_id)));
create policy docs_update on public.documents for update to authenticated using (
  (owner_kind = 'student' and public.can_access_student(student_id))
  or (owner_kind = 'partner' and public.can_access_partner(partner_id)))
  with check ((owner_kind = 'student' and public.can_access_student(student_id))
  or (owner_kind = 'partner' and public.can_access_partner(partner_id)));
create policy docs_staff_delete on public.documents for delete to authenticated using (public.sees_everything());

-- applications: read for anyone who can see the student; write for staff only
create policy apps_read on public.applications for select to authenticated using (public.can_access_student(student_id));
create policy apps_staff_write on public.applications for insert to authenticated
  with check (public.is_staff() and public.can_access_student(student_id));
create policy apps_staff_update on public.applications for update to authenticated
  using (public.is_staff() and public.can_access_student(student_id))
  with check (public.is_staff() and public.can_access_student(student_id));
create policy apps_admin_delete on public.applications for delete to authenticated using (public.my_role() = 'admin');
create policy app_events_read on public.application_events for select to authenticated
  using (exists (select 1 from public.applications a where a.id = application_id and public.can_access_student(a.student_id)));

-- messages
create policy msg_read on public.messages for select to authenticated using (public.can_access_student(student_id));
create policy msg_insert on public.messages for insert to authenticated
  with check (public.can_access_student(student_id) and sender_id = auth.uid() and not is_ai);

-- ai_runs: staff see runs for students they can access; written by the server (service role)
create policy ai_read on public.ai_runs for select to authenticated using (
  public.is_staff() and (student_id is null or public.can_access_student(student_id)));
create policy ai_approve on public.ai_runs for update to authenticated using (
  public.is_staff() and (student_id is null or public.can_access_student(student_id)));

-- audit log: admin only
create policy audit_admin_read on public.audit_log for select to authenticated using (public.my_role() = 'admin');

-- No anonymous access to anything.
revoke all on all tables in schema public from anon;
