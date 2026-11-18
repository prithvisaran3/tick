-- Pay statements, reviewed: where net pay was deposited (one line per account on the statement) and which fields had to be fixed by hand.
alter table public.pay_statements add column if not exists deposits jsonb not null default '[]'::jsonb check (pg_column_size(deposits) < 4096);   -- [{label, mask, cents}]
alter table public.pay_statements add column if not exists problems jsonb not null default '[]'::jsonb check (pg_column_size(problems) < 1024);   -- field names only
