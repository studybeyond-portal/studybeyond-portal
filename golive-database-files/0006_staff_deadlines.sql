-- Counsellors and compliance keep intake deadlines up to date, not only the admin.
drop policy if exists deadlines_admin on public.deadlines;
create policy deadlines_staff on public.deadlines for all to authenticated
  using (public.is_staff()) with check (public.is_staff());
