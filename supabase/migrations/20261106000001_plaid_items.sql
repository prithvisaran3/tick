-- Part 1: Plaid slot-burn fix.
-- Root cause (Railway logs, 2026-11-05 01:34:58): the SESSION_FINISHED webhook and the app's POST /plaid/complete both exchanged the
-- same public token at the same moment. Both saw "no connection for this item_id yet", both bumped plaid_slots.used (read-modify-write),
-- the second Vault insert hit a 409 and the app showed "That didn't go through". Plaid created ONE Item; Tick counted two.
--
-- Fix: the lifetime counter is the number of DISTINCT Plaid item_ids ever created for the user (removed ones included), recorded in an
-- append-only table with a unique item_id. A link session is claimed atomically before any exchange, so the webhook and the app can
-- never both finish the same session.

create table if not exists public.plaid_items (
  item_id text primary key,                         -- Plaid item_id; unique forever, so a double exchange can't count twice
  user_id uuid not null references auth.users(id) on delete cascade,
  institution text,
  link_token_prefix text,                           -- first 24 chars only (enough to trace a session in logs, useless as a credential)
  created_at timestamptz not null default now(),
  removed_at timestamptz                            -- set when the Item is removed; the row stays so the slot is still counted
);
create index if not exists plaid_items_user_idx on public.plaid_items (user_id);
alter table public.plaid_items enable row level security;
alter table public.plaid_items force row level security;
drop policy if exists plaid_items_read on public.plaid_items;
create policy plaid_items_read on public.plaid_items for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete, truncate on public.plaid_items from anon, authenticated;

-- Backfill: every Plaid connection that ever existed is one Item. (The double-counted plaid_slots.used is not trusted any more.)
insert into public.plaid_items (item_id, user_id, institution, created_at)
  select item_id, user_id, institution, created_at from public.connections where provider = 'plaid' and item_id is not null
  on conflict (item_id) do nothing;

-- Removing an Item never frees a slot: plaid_items rows are never deleted by the app or the API.
create or replace function public.plaid_items_no_delete() returns trigger language plpgsql as $$
begin
  if current_setting('tick.allow_item_delete', true) = 'on' then return old; end if;   -- only "delete my account" cascades
  raise exception 'plaid_items is append-only';
end $$;
drop trigger if exists plaid_items_append_only on public.plaid_items;
create trigger plaid_items_append_only before delete on public.plaid_items for each row execute function public.plaid_items_no_delete();

-- Link sessions: an atomic claim so exactly one finisher (webhook or app) exchanges the public token.
alter table public.plaid_link_sessions add column if not exists claimed_at timestamptz;
alter table public.plaid_link_sessions add column if not exists finished_at timestamptz;
alter table public.plaid_link_sessions add column if not exists connection_ids uuid[] not null default '{}';

-- Store (or replace) a Plaid access token by name, so a retried exchange for the same Item reuses its Vault entry instead of failing.
create or replace function public.tick_vault_upsert(secret_name text, secret_value text) returns uuid
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  select id into sid from vault.secrets where name = secret_name;
  if sid is null then
    select vault.create_secret(secret_value, secret_name, 'plaid access token') into sid;
  else
    perform vault.update_secret(sid, secret_value);
  end if;
  return sid;
end $$;
revoke all on function public.tick_vault_upsert(text, text) from public, anon, authenticated;
grant execute on function public.tick_vault_upsert(text, text) to service_role;

-- Distinct Items ever created (removed included). The API and the app both read this.
create or replace function public.tick_links_used(uid uuid) returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.plaid_items where user_id = uid and (auth.uid() is null or auth.uid() = uid);
$$;
revoke all on function public.tick_links_used(uuid) from public, anon;
grant execute on function public.tick_links_used(uuid) to authenticated, service_role;
