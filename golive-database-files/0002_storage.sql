-- Private bucket for every uploaded document. Paths:
--   students/<student_id>/<document_id>-<safe file name>
--   partners/<partner_id>/<document_id>-<safe file name>
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 26214400,
        array['application/pdf','image/jpeg','image/png','image/heic','image/heif',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.can_access_object(object_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare parts text[] := storage.foldername(object_name); oid uuid;
begin
  if array_length(parts, 1) < 2 then return false; end if;
  begin oid := parts[2]::uuid; exception when others then return false; end;
  if parts[1] = 'students' then return public.can_access_student(oid);
  elsif parts[1] = 'partners' then return public.can_access_partner(oid);
  end if;
  return false;
end $$;

create policy "documents read" on storage.objects for select to authenticated
  using (bucket_id = 'documents' and public.can_access_object(name));
create policy "documents upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and public.can_access_object(name));
create policy "documents replace" on storage.objects for update to authenticated
  using (bucket_id = 'documents' and public.can_access_object(name));
create policy "documents delete by admin" on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and public.sees_everything());
