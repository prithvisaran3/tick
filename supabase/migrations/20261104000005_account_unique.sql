-- PostgREST upserts need a non-partial unique constraint.
drop index if exists public.accounts_provider_idx;
alter table public.accounts add constraint accounts_user_provider_account_key unique (user_id, provider_account_id);
