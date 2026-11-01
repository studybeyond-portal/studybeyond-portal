-- Commission rates Study Beyond receives (from aggregators and direct deals), visible to admin and compliance only.
-- Partners never read these tables; they see the settings text and their BDM's contact instead.
create table public.commission_rates (
  id bigint generated always as identity primary key,
  institution text not null,
  country char(2),
  source text not null,              -- e.g. GEA, KC Overseas, Unipool, Leap GeeBee, Direct
  level text,                        -- UG, PG, Foundation, PhD, All...
  program text,
  rate_pct numeric(6,3),             -- percentage of tuition (Tier 1)
  rate_pct_tier2 numeric(6,3),       -- volume tier, where given
  flat_amount numeric(12,2),         -- fixed commission instead of a percentage
  flat_amount_tier2 numeric(12,2),
  currency text,
  basis text,                        -- Net / Gross
  notes text,
  valid_for text,                    -- e.g. 'Spring/Sept 2026-27'
  updated_at timestamptz not null default now()
);
create index on public.commission_rates (lower(institution));
alter table public.commission_rates enable row level security;
create policy commission_admin_read on public.commission_rates for select to authenticated using (public.sees_everything());
create policy commission_admin_write on public.commission_rates for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- Portal-wide settings. Partner-facing text is readable by every signed-in user; internal ones by staff only.
create table public.app_settings (
  key text primary key,
  value jsonb not null,
  public boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
create policy settings_read on public.app_settings for select to authenticated using (public or public.is_staff());
create policy settings_admin on public.app_settings for all to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');
insert into public.app_settings (key, value, public) values
  ('partner_margin_pct', '15', false),     -- admin view: partner rate = our rate less 15% of it
  ('partner_display_share_pct', '80', true) -- what partners are told: 80% of Study Beyond's receivable
on conflict (key) do nothing;

-- A partner may see the name and contact of the BDM (owner counsellor) assigned to their agency, nothing else.
create or replace function public.my_bdm() returns table (full_name text, email text, phone text)
language sql stable security definer set search_path = public as $$
  select pr.full_name, pr.email, pr.phone from public.partners p
  join public.profiles pr on pr.id = p.owner_counsellor_id
  where p.id = public.my_partner_id() and pr.active
$$;
revoke all on function public.my_bdm() from public, anon;
grant execute on function public.my_bdm() to authenticated;

-- WhatsApp community channel for partners (set the invite link in Supabase or the admin settings).
insert into public.app_settings (key, value, public) values ('whatsapp_community_url', '"https://wa.me/8801773491244"', true)
on conflict (key) do nothing;
