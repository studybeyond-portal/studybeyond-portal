-- Agent workflow tools: student self-input links, partner application requests, student transfer,
-- course filters (application fee), and versioned commission contracts (active / historical).

-- ---------------------------------------------------------------- student self-input links
-- A partner or staff member shares /join/<token>; the student fills their own profile and is created
-- under that partner (and counsellor). Tokens are random, expire, have a use limit and can be revoked.
create table public.student_intake_links (
  id uuid primary key default gen_random_uuid(),
  token text not null unique check (length(token) >= 24),
  partner_id uuid references public.partners(id) on delete cascade,
  counsellor_id uuid references public.profiles(id) on delete set null,
  created_by uuid references public.profiles(id) on delete set null,
  label text,
  destination text,
  max_uses int not null default 50 check (max_uses between 1 and 500),
  uses int not null default 0,
  expires_at timestamptz not null default now() + interval '30 days',
  revoked boolean not null default false,
  created_at timestamptz not null default now()
);
create index on public.student_intake_links (partner_id);
alter table public.student_intake_links enable row level security;

create policy intake_links_read on public.student_intake_links for select to authenticated using (
     public.sees_everything()
  or created_by = auth.uid()
  or (public.my_role() = 'partner' and partner_id = public.my_partner_id()));
create policy intake_links_insert on public.student_intake_links for insert to authenticated with check (
  created_by = auth.uid() and uses = 0 and (
       (public.is_staff() and (partner_id is null or public.can_access_partner(partner_id)))
    or (public.my_role() = 'partner' and partner_id = public.my_partner_id()
        and exists (select 1 from public.partners p where p.id = public.my_partner_id() and p.status = 'active'))));
-- Only revoking is allowed from the portal; use counts are changed by the server with the service key.
create policy intake_links_revoke on public.student_intake_links for update to authenticated
  using (public.sees_everything() or created_by = auth.uid() or (public.my_role() = 'partner' and partner_id = public.my_partner_id()))
  with check (public.sees_everything() or created_by = auth.uid() or (public.my_role() = 'partner' and partner_id = public.my_partner_id()));

create or replace function public.guard_intake_link_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and (
       new.token is distinct from old.token or new.partner_id is distinct from old.partner_id
    or new.counsellor_id is distinct from old.counsellor_id or new.uses is distinct from old.uses
    or new.max_uses is distinct from old.max_uses or new.expires_at > old.expires_at
    or new.created_by is distinct from old.created_by) then
    raise exception 'only revoking a link is allowed';
  end if;
  return new;
end $$;
create trigger t_intake_links_guard before update on public.student_intake_links
  for each row execute function public.guard_intake_link_update();

-- ---------------------------------------------------------------- partners can request an application
-- Partners add a course for their own student ("+ Add application"); it starts as an enquiry and
-- only staff move it forward (apps_staff_update is unchanged).
create policy apps_partner_request on public.applications for insert to authenticated with check (
  public.my_role() = 'partner' and stage = 'enquiry' and public.can_access_student(student_id)
  and exists (select 1 from public.partners p where p.id = public.my_partner_id() and p.status = 'active'));

-- ---------------------------------------------------------------- transfer students between counsellors
create or replace function public.transfer_students(student_ids uuid[], to_counsellor uuid, why text)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; sid uuid;
begin
  if not public.is_staff() then raise exception 'staff only'; end if;
  if to_counsellor is not null and not exists (
    select 1 from public.profiles where id = to_counsellor and active and role in ('admin','counsellor')) then
    raise exception 'pick an active counsellor';
  end if;
  foreach sid in array student_ids loop
    if public.can_access_student(sid) then
      update public.students set counsellor_id = to_counsellor where id = sid;
      insert into public.audit_log (actor_id, action, entity, entity_id, detail)
        values (auth.uid(), 'transfer', 'students', sid::text, jsonb_build_object('to', to_counsellor, 'why', left(coalesce(why, ''), 300)));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.transfer_students(uuid[], uuid, text) from public, anon;
grant execute on function public.transfer_students(uuid[], uuid, text) to authenticated;

-- ---------------------------------------------------------------- courses: application fee
alter table public.courses add column if not exists application_fee numeric;  -- 0 = free, null = unknown
alter table public.courses add column if not exists qs_subject_rank text;
create index if not exists courses_level_idx on public.courses (level);

-- ---------------------------------------------------------------- commission: contract versions
alter table public.commission_rates add column if not exists subsequent text;      -- later-year commission, e.g. "Year 2 at same rate"
alter table public.commission_rates add column if not exists tuition_basis text;   -- how tuition is counted, e.g. "first-year net tuition"
alter table public.commission_rates add column if not exists institution_type text; -- University, College, School...
alter table public.commission_rates add column if not exists active boolean not null default true;
alter table public.commission_rates add column if not exists superseded_at timestamptz;
create index if not exists commission_active_idx on public.commission_rates (active);
