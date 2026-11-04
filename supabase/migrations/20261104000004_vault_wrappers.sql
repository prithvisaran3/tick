-- Plaid access tokens live ONLY in Supabase Vault, referenced by id. These wrappers are callable by the server (service_role) only.
create or replace function public.tick_vault_put(secret_name text, secret_value text) returns uuid
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  select vault.create_secret(secret_value, secret_name, 'plaid access token') into sid;
  return sid;
end $$;

create or replace function public.tick_vault_get(secret_id uuid) returns text
language sql security definer set search_path = public, vault as $$
  select decrypted_secret from vault.decrypted_secrets where id = secret_id;
$$;

revoke all on function public.tick_vault_put(text, text) from public, anon, authenticated;
revoke all on function public.tick_vault_get(uuid) from public, anon, authenticated;
grant execute on function public.tick_vault_put(text, text) to service_role;
grant execute on function public.tick_vault_get(uuid) to service_role;

-- A running lifetime counter so removing an Item never frees a slot (Plaid Trial plan cap is 10 Items ever).
create table if not exists public.plaid_slots (
  user_id uuid primary key references auth.users(id) on delete cascade,
  used int not null default 0
);
alter table public.plaid_slots enable row level security;
alter table public.plaid_slots force row level security;
create policy plaid_slots_read on public.plaid_slots for select to authenticated using (user_id = auth.uid());
