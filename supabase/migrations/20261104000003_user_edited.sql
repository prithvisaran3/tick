-- Fields a person changed by hand; later sources (SMS, Apple Pay, Plaid) never overwrite these.
alter table public.transactions add column if not exists user_edited text[] not null default '{}';
