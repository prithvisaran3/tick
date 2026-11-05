-- Part 6: security hardening. Deny by default, owner-only, nothing for anon, an append-only audit trail.

-- ---------- tables: anon gets nothing at all ----------
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;
alter default privileges in schema public revoke all on tables from anon;

-- ---------- audit log: who, what, when; no PII ----------
create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  user_id uuid,                           -- not a foreign key: the trail outlives "delete all my data"
  event text not null check (event in ('sign_in','token_created','token_revoked','tokens_revoked_all','bank_linked','bank_removed',
                                       'data_deleted','sessions_revoked','bad_token_burst','plaid_item_removed')),
  detail jsonb not null default '{}',     -- institution name, counts, token last-4. Never amounts, merchants, emails or tokens.
  at timestamptz not null default now()
);
create index if not exists audit_log_user_idx on public.audit_log (user_id, at desc);
alter table public.audit_log enable row level security;
alter table public.audit_log force row level security;
drop policy if exists audit_log_read on public.audit_log;
create policy audit_log_read on public.audit_log for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete, truncate on public.audit_log from authenticated, anon;

create or replace function public.audit_log_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'audit_log is append-only';
end $$;
drop trigger if exists audit_log_no_change on public.audit_log;
create trigger audit_log_no_change before update or delete on public.audit_log for each row execute function public.audit_log_append_only();
revoke truncate on public.audit_log from service_role;

-- Sign-ins are recorded by the database itself (the API never sees them).
create or replace function public.audit_sign_in() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.last_sign_in_at is distinct from old.last_sign_in_at then
    insert into public.audit_log (user_id, event) values (new.id, 'sign_in');
  end if;
  return new;
end $$;
revoke execute on function public.audit_sign_in() from public, anon, authenticated;
drop trigger if exists on_auth_sign_in on auth.users;
create trigger on_auth_sign_in after update on auth.users for each row execute function public.audit_sign_in();

-- ---------- capture tokens: created by the server only, scoped, hash only ----------
alter table public.ingest_tokens add column if not exists scope text not null default 'ingest';
alter table public.ingest_tokens drop constraint if exists ingest_tokens_scope_check;
alter table public.ingest_tokens add constraint ingest_tokens_scope_check check (scope in ('ingest'));
-- The app may list its tokens and revoke them; it can't mint one (the server generates the secret and stores only the hash).
-- Revoking goes through the API (POST /tokens/{id}/revoke, /security/panic); the app has no write access at all, so a stolen session
-- can't un-revoke a leaked token (hostile review F2). A revoked token also stays revoked for the server itself:
revoke insert, update, truncate on public.ingest_tokens from authenticated;
create or replace function public.ingest_tokens_stay_revoked() returns trigger language plpgsql as $$
begin
  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
    raise exception 'a revoked capture token stays revoked';
  end if;
  if new.token_hash is distinct from old.token_hash or new.user_id is distinct from old.user_id or new.scope is distinct from old.scope then
    raise exception 'capture token identity is immutable';
  end if;
  return new;
end $$;
drop trigger if exists ingest_tokens_revoke_once on public.ingest_tokens;
create trigger ingest_tokens_revoke_once before update on public.ingest_tokens for each row execute function public.ingest_tokens_stay_revoked();

-- ---------- connections and Plaid ----------
-- connections stays readable in full by its owner (Realtime needs whole-row SELECT). vault_secret_id is only a reference: the
-- token itself is in Vault, readable through tick_vault_get, which only service_role may execute.
revoke all on public.plaid_link_sessions from authenticated;
-- The hosted Link URL of an open session, so re-opening the sheet reuses it instead of starting a second session (review F5).
alter table public.plaid_link_sessions add column if not exists hosted_link_url text;
revoke all on public.ai_cache from authenticated;

-- ---------- storage: private, per-user folders, small images only ----------
update storage.buckets set public = false, file_size_limit = 8000000,
       allowed_mime_types = array['image/jpeg','image/png','image/heic','image/heif','image/webp']
 where id = 'receipts';

-- ---------- functions: nothing executable by default (runs LAST so it covers everything above) ----------
-- Postgres grants EXECUTE on new functions to PUBLIC (which includes anon). Stop that for everything created from now on,
-- and take it back from every existing function in public except the few the app is meant to call.
alter default privileges revoke execute on functions from public;     -- global form: the built-in PUBLIC default
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname in ('tick_flows', 'tick_activity_page', 'tick_months', 'tick_filtered', 'tick_links_used') then
      execute format('grant execute on function %s to authenticated', f.sig);
    else
      execute format('revoke execute on function %s from authenticated', f.sig);    -- trigger functions don't need EXECUTE to fire
    end if;
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;


-- ---------- Vault: delete a Plaid token (used by "Delete all my data" after /item/remove) ----------
create or replace function public.tick_vault_delete(secret_id uuid) returns void
language sql security definer set search_path = public, vault as $$
  delete from vault.secrets where id = secret_id;
$$;
revoke all on function public.tick_vault_delete(uuid) from public, anon, authenticated;
grant execute on function public.tick_vault_delete(uuid) to service_role;
