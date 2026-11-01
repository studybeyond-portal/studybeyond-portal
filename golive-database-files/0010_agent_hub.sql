-- Agent hub: registration details and POC choice, admin-created partner portals, network catalogue,
-- programmes (IELTS, packages) with referral sign-ups, resources, shortlists, AI interview practice,
-- and the "1 deposit" unlock.

-- ---------------------------------------------------------------- partners
create type public.poc_choice as enum ('study_beyond', 'self', 'team');

alter table public.partners
  alter column email drop not null,
  add column poc public.poc_choice,
  add column profession text,
  add column area text,
  add column most_recruited text,
  add column urgency text,
  add column referral_source text,
  add column notes text,
  add column portal_plan jsonb,
  add column created_by_admin boolean not null default false,
  add column hub_unlocked boolean not null default false;

create unique index partners_email_uq on public.partners (lower(email)) where email is not null;

-- Partners may edit their own contact details, but not their POC tier, plan, unlock or admin flags.
create or replace function public.guard_partner_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.my_role() = 'partner' and (
       new.status is distinct from old.status or new.fit_score is distinct from old.fit_score
    or new.owner_counsellor_id is distinct from old.owner_counsellor_id
    or new.commission_split_pct is distinct from old.commission_split_pct
    or new.activated_at is distinct from old.activated_at
    or (old.poc is not null and new.poc is distinct from old.poc)
    or new.portal_plan is distinct from old.portal_plan
    or new.created_by_admin is distinct from old.created_by_admin
    or new.hub_unlocked is distinct from old.hub_unlocked
    or new.notes is distinct from old.notes) then
    raise exception 'not allowed to change status, score, owner, commission, POC tier or portal settings';
  end if;
  return new;
end $$;

insert into public.app_settings (key, value, public) values
  ('poc_share_ranges', '{"study_beyond":[40,50],"self":[60,70],"team":[70,80]}', true),
  ('deposit_unlock_min', '1', true)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- catalogue
alter table public.institutions
  add column on_website boolean not null default false,
  add column in_network boolean not null default false;

-- Which B2B network lists an institution: staff only (agreements are confidential).
create table public.institution_sources (
  institution_id uuid not null references public.institutions(id) on delete cascade,
  source text not null,
  primary key (institution_id, source)
);
alter table public.institution_sources enable row level security;
create policy inst_src_staff on public.institution_sources for select to authenticated using (public.is_staff());
create policy inst_src_admin on public.institution_sources for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- ---------------------------------------------------------------- deposit unlock
create or replace function public.partner_deposit_count(p uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(distinct a.student_id)::int
  from public.applications a join public.students s on s.id = a.student_id
  where s.partner_id = p
    and a.stage in ('deposit_paid','cas_coe_issued','visa_lodged','visa_granted','visa_refused','enrolled');
$$;

create or replace function public.hub_unlocked(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select hub_unlocked from public.partners where id = p), false)
      or public.partner_deposit_count(p) >= coalesce((select (value #>> '{}')::int from public.app_settings where key = 'deposit_unlock_min'), 1);
$$;

create or replace function public.my_hub_status() returns table (deposits int, unlocked boolean)
language sql stable security definer set search_path = public as $$
  select public.partner_deposit_count(public.my_partner_id()), public.hub_unlocked(public.my_partner_id())
  where public.my_partner_id() is not null;
$$;
revoke execute on function public.partner_deposit_count(uuid) from public, anon;
revoke execute on function public.hub_unlocked(uuid) from public, anon;
revoke execute on function public.my_hub_status() from public, anon;
grant execute on function public.partner_deposit_count(uuid) to authenticated;
grant execute on function public.hub_unlocked(uuid) to authenticated;
grant execute on function public.my_hub_status() to authenticated;

-- ---------------------------------------------------------------- programmes and sign-ups
create table public.programmes (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  kind text not null check (kind in ('ielts', 'package', 'service', 'training')),
  title text not null,
  summary text,
  details text,
  price_text text,
  requires_deposit boolean not null default false,
  active boolean not null default true,
  sort int not null default 100,
  created_at timestamptz not null default now()
);
alter table public.programmes enable row level security;
create policy prog_read on public.programmes for select to authenticated using (active or public.is_staff());
create policy prog_admin on public.programmes for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

create table public.programme_signups (
  id uuid primary key default gen_random_uuid(),
  programme_id uuid not null references public.programmes(id) on delete cascade,
  partner_id uuid references public.partners(id) on delete set null,
  submitted_by uuid default auth.uid() references public.profiles(id) on delete set null,
  for_whom text not null check (for_whom in ('student', 'referral', 'self')),
  student_id uuid references public.students(id) on delete set null,
  full_name text not null,
  email text,
  phone text,
  notes text,
  status text not null default 'new' check (status in ('new', 'contacted', 'enrolled', 'closed')),
  created_at timestamptz not null default now()
);
create index on public.programme_signups (partner_id);
alter table public.programme_signups enable row level security;
create policy signup_read on public.programme_signups for select to authenticated
  using (public.is_staff() and (public.sees_everything() or public.can_access_partner(partner_id))
         or (partner_id is not null and partner_id = public.my_partner_id()));
create policy signup_insert on public.programme_signups for insert to authenticated
  with check (
    partner_id = public.my_partner_id() and submitted_by = auth.uid()
    and (student_id is null or public.can_access_student(student_id))
    and exists (select 1 from public.programmes pr where pr.id = programme_id and pr.active
                and (not pr.requires_deposit or public.hub_unlocked(partner_id))));
create policy signup_staff on public.programme_signups for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- ---------------------------------------------------------------- resources
create table public.resources (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  category text not null,
  description text,
  url text,
  audience text not null default 'partner' check (audience in ('partner', 'student', 'all')),
  sort int not null default 100,
  active boolean not null default true
);
alter table public.resources enable row level security;
create policy res_read on public.resources for select to authenticated using (
  public.is_staff() or (active and (audience = 'all'
    or (audience = 'partner' and public.my_role() = 'partner')
    or (audience = 'student' and public.my_role() = 'student'))));
create policy res_admin on public.resources for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- ---------------------------------------------------------------- shortlists
create table public.shortlists (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid references public.partners(id) on delete cascade,
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  student_id uuid references public.students(id) on delete set null,
  institution_id uuid not null references public.institutions(id) on delete cascade,
  course_id uuid references public.courses(id) on delete set null,
  note text,
  created_at timestamptz not null default now(),
  unique (owner_id, institution_id, course_id, student_id)
);
alter table public.shortlists enable row level security;
create policy sl_own on public.shortlists for all to authenticated
  using (owner_id = auth.uid() or (public.is_staff() and public.can_access_partner(partner_id)))
  with check (owner_id = auth.uid()
    and (partner_id is null or partner_id = public.my_partner_id() or public.is_staff())
    and (student_id is null or public.can_access_student(student_id)));

-- ---------------------------------------------------------------- AI interview practice
create table public.interview_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  partner_id uuid references public.partners(id) on delete set null,
  kind text not null,
  candidate text,
  transcript jsonb not null default '[]',
  feedback text,
  created_at timestamptz not null default now()
);
alter table public.interview_sessions enable row level security;
create policy iv_read on public.interview_sessions for select to authenticated
  using (user_id = auth.uid() or (public.is_staff() and public.can_access_partner(partner_id)));

-- ---------------------------------------------------------------- seed: programmes and resources
insert into public.programmes (slug, kind, title, summary, details, price_text, requires_deposit, sort) values
 ('ielts-classes', 'ielts', 'IELTS classes', 'Live IELTS preparation with Study Beyond trainers, online or in Dhaka.',
  'Class schedule, batches and fees are being finalised. Sign up now and your BDM will share the timetable as soon as it is published.', 'Fees: ask your BDM', false, 10),
 ('ielts-mock', 'ielts', 'IELTS mock test and band review', 'A full mock test with band scores and a study plan.', null, 'Ask your BDM', false, 20),
 ('package-full-service', 'package', 'Full application package', 'University shortlist, application, offer, CAS/CoE, finances and visa file, handled with your BDM.', null, 'Ask your BDM', true, 30),
 ('package-visa', 'package', 'Visa file package', 'Document check, financial matrix, SOP review and visa lodgement support.', null, 'Ask your BDM', true, 40),
 ('package-sop', 'package', 'SOP and cover letter package', 'Statement of purpose, study gap and sponsor letters reviewed by our team.', null, 'Ask your BDM', true, 50),
 ('package-pre-departure', 'package', 'Pre-departure and accommodation', 'Flights, accommodation, airport pick-up and arrival briefing.', null, 'Ask your BDM', true, 60),
 ('interview-coaching', 'training', 'Credibility and visa interview coaching', 'One-to-one mock interviews with a counsellor, after AI practice.', null, 'Ask your BDM', true, 70)
on conflict (slug) do nothing;

insert into public.resources (title, category, description, url, audience, sort) values
 ('Agent knowledge resource', 'Getting started', 'How Study Beyond works with partners, step by step.', '/resources/agent-knowledge-resource.pdf', 'partner', 10),
 ('Partner brief', 'Getting started', 'Our services, destinations and partner support in six pages.', '/resources/partner-brief.pdf', 'partner', 20),
 ('Company profile', 'Getting started', 'Study Beyond Ltd company profile.', '/resources/company-profile.pdf', 'partner', 30),
 ('UK agent basic guideline', 'United Kingdom', 'Entry requirements, documents and the UK application flow.', '/resources/uk-agent-basic-guideline.pdf', 'partner', 40),
 ('UK counsellor and agent guide', 'United Kingdom', 'Counselling a UK applicant from first call to CAS.', '/resources/uk-counsellor-agent-guide.pdf', 'partner', 50),
 ('Study in China', 'China', '150+ public and private universities on our website, and many more on request.', 'https://studyabroad-beyond.com/china/', 'all', 60);
