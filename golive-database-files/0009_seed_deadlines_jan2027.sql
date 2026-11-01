-- January 2027 UK intake deadlines from university updates shared on 1 Nov 2026 (only dates still ahead).
-- Confirm with the university before advising a student.
insert into public.deadlines (institution_id, intake, kind, due_on, note)
select i.id, v.intake, v.kind, v.due_on::date, v.note
from (values
  ('Glasgow Caledonian University', 'Jan 2027', 'Full tuition fee payment', '2026-11-06', 'Full fees must be paid before a CAS is issued'),
  ('Glasgow Caledonian University', 'Jan 2027', 'Financial documents', '2026-11-13', null),
  ('Glasgow Caledonian University', 'Jan 2027', 'CAS issuing deadline', '2026-11-20', null),
  ('Glasgow Caledonian University', 'Jan 2027', 'Visa application submission', '2026-11-25', null),
  ('Northeastern University London', 'Jan 2027', 'Early acceptance scholarship (10%)', '2026-11-09', 'Requires a GBP 3,000 deposit; 15% international scholarship is automatic'),
  ('Northeastern University London', 'Jan 2027', 'Regular acceptance deposit (visa required)', '2026-11-16', null),
  ('Northeastern University London', 'Jan 2027', 'CAS document submission', '2026-11-23', null),
  ('Northeastern University London', 'Jan 2027', 'CAS issuance deadline', '2026-11-30', null),
  ('Loughborough University', 'Jan 2027', 'Application deadline (UG and PG)', '2026-12-14', null),
  (null, 'Jan 2027', 'Regent College London: CAS documents and tuition fee (Bangladesh)', '2026-11-25', 'Course starts 18 Jan 2027')
) as v(iname, intake, kind, due_on, note)
left join public.institutions i on i.name = v.iname and i.country = 'GB'
where not exists (select 1 from public.deadlines d where d.kind = v.kind and d.due_on = v.due_on::date
                  and d.institution_id is not distinct from i.id);
