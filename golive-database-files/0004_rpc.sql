-- Stage change with a reason in one statement, so the log trigger records why.
create or replace function public.set_application_stage(app_id uuid, new_stage public.app_stage, why text)
returns void language plpgsql security invoker set search_path = public as $$
begin
  perform set_config('sbap.reason', coalesce(why, ''), true);
  update public.applications set stage = new_stage where id = app_id;
  if not found then raise exception 'application not found or not allowed'; end if;
end $$;

-- Record that someone opened a document (called when a signed link is issued).
create or replace function public.log_document_view(doc_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.documents d where d.id = doc_id and (
      (d.owner_kind = 'student' and public.can_access_student(d.student_id))
   or (d.owner_kind = 'partner' and public.can_access_partner(d.partner_id)))) then
    raise exception 'not allowed';
  end if;
  insert into public.audit_log (actor_id, action, entity, entity_id) values (auth.uid(), 'view', 'documents', doc_id::text);
end $$;

grant execute on function public.set_application_stage(uuid, public.app_stage, text) to authenticated;
grant execute on function public.log_document_view(uuid) to authenticated;

-- A new file wipes earlier reviews (runs after the guard trigger: triggers fire in name order).
create or replace function public.reset_reviews_on_new_file() returns trigger language plpgsql as $$
begin
  if new.storage_path is distinct from old.storage_path then
    new.reviewer_id := null; new.second_reviewer_id := null;
  end if;
  return new;
end $$;
create trigger t_documents_zreset before update on public.documents
  for each row execute function public.reset_reviews_on_new_file();
