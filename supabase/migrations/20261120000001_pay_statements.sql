-- Pay statements, imported as PDF files. Money in cents. Personal details (name, address, SSN, employee ID) are never stored.
create table if not exists public.pay_statements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  employer text not null check (char_length(employer) between 1 and 120),
  pay_date date not null,
  period_start date,
  period_end date,
  gross_cents bigint not null check (gross_cents >= 0),
  taxes_cents bigint not null check (taxes_cents >= 0),
  deductions_cents bigint not null check (deductions_cents >= 0),
  net_cents bigint not null check (net_cents >= 0),
  ytd jsonb not null default '{}',                     -- {gross, taxes, deductions, net} year to date, cents
  status text not null default 'ok' check (status in ('ok','review')),   -- review: the sum didn't come out to the cent
  source text not null check (source in ('adp','ai')),
  matched_txn uuid references public.transactions(id) on delete set null,
  pdf_path text,                                       -- only with "Keep the PDF" on
  created_at timestamptz not null default now()
);
create unique index if not exists pay_statements_dedupe on public.pay_statements (user_id, pay_date, net_cents, lower(employer));
create index if not exists pay_statements_user_idx on public.pay_statements (user_id, pay_date desc);

create table if not exists public.pay_statement_lines (
  id uuid primary key default gen_random_uuid(),
  statement_id uuid not null references public.pay_statements(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  kind text not null check (kind in ('earning','tax','deduction')),
  label text not null check (char_length(label) between 1 and 80),
  cents bigint not null,
  ytd_cents bigint,
  sort int not null default 0
);
create index if not exists pay_statement_lines_idx on public.pay_statement_lines (statement_id, sort);

do $$ declare t text; begin
  foreach t in array array['pay_statements','pay_statement_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (user_id = auth.uid())', t || '_read', t);
    execute format('create policy %I on public.%I for delete to authenticated using (user_id = auth.uid())', t || '_delete', t);
    execute format('revoke insert, update, truncate on public.%I from authenticated, anon', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

alter table public.settings add column if not exists keep_pay_pdfs boolean not null default false;

-- "Keep the PDF": a private bucket, each person's own folder.
insert into storage.buckets (id, name, public) values ('paystubs', 'paystubs', false) on conflict (id) do nothing;
create policy paystubs_owner_select on storage.objects for select to authenticated using (bucket_id = 'paystubs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy paystubs_owner_delete on storage.objects for delete to authenticated using (bucket_id = 'paystubs' and (storage.foldername(name))[1] = auth.uid()::text);
