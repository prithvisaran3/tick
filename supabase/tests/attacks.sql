-- Hostile tests: user B (and anon) attacking user A through every table, view and function in public, plus storage.
-- Enumerates the catalogue, so a NEW table, view or function is attacked automatically. Always rolls back.
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
  r record; n int; fails text := ''; ok boolean; txn_a uuid; acct_a uuid; conn_a uuid; tok_a uuid; cat_a uuid;
  callable text[] := array['tick_flows','tick_activity_page','tick_months','tick_filtered','tick_links_used'];
begin
  insert into auth.users (id, aud, role, email) values (a, 'authenticated', 'authenticated', 'a@test.local'), (b, 'authenticated', 'authenticated', 'b@test.local');
  select id into cat_a from public.categories where user_id = a limit 1;
  insert into public.accounts (user_id, name, type, mask) values (a, 'Checking', 'checking', '1173') returning id into acct_a;
  insert into public.transactions (user_id, amount_cents, occurred_at, merchant_raw, account_id) values (a, -1840, now(), 'Uber', acct_a) returning id into txn_a;
  insert into public.connections (user_id, institution, item_id, vault_secret_id) values (a, 'Chase', 'item-a', gen_random_uuid()) returning id into conn_a;
  insert into public.plaid_items (item_id, user_id) values ('item-a', a);
  insert into public.ingest_tokens (user_id, token_hash, last4) values (a, 'hash-a', 'abcd') returning id into tok_a;
  insert into public.audit_log (user_id, event) values (a, 'bank_linked');
  insert into public.budgets (user_id, category_id, monthly_cap_cents) values (a, cat_a, 100);
  insert into public.goals (user_id, name, target_cents) values (a, 'Trip', 100);
  insert into public.rules (user_id, pattern, category_id) values (a, 'uber', cat_a);
  insert into public.people (user_id, name) values (a, 'Sam');
  insert into public.chats (user_id, title) values (a, 'q');
  insert into public.insights (user_id, kind, body) values (a, 'weekly', 'x');
  insert into public.snapshots (user_id, day) values (a, current_date);
  insert into public.paydays (user_id, day) values (a, current_date);
  insert into public.plaid_link_sessions (link_token, user_id) values ('lt-' || a, a);
  insert into public.ai_cache (key, feature, value) values ('k-' || a, 'x', '{}');

  -- 1. Every table in public: RLS enabled AND forced (deny by default even for the table owner).
  for r in select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind = 'r' loop
    if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = ('public.' || r.relname)::regclass) then
      fails := fails || format('RLS not enabled+forced on %s; ', r.relname);
    end if;
  end loop;
  -- 2. Views must not bypass RLS (security_invoker), and there should be none exposing other users' rows.
  for r in select c.relname, c.reloptions from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind in ('v','m') loop
    if r.reloptions is null or not ('security_invoker=true' = any (r.reloptions) or 'security_invoker=on' = any (r.reloptions)) then
      fails := fails || format('view %s is not security_invoker; ', r.relname);
    end if;
  end loop;
  -- 3. SECURITY DEFINER functions pin search_path; none is executable by anon; only the allow-list by authenticated.
  for r in select p.oid::regprocedure::text sig, p.proname, p.prosecdef, p.proconfig from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.prokind = 'f' loop
    if r.prosecdef and (r.proconfig is null or not exists (select 1 from unnest(r.proconfig) c where c like 'search_path=%')) then
      fails := fails || format('definer %s has no search_path; ', r.sig);
    end if;
    if has_function_privilege('anon', r.sig, 'execute') then fails := fails || format('anon can execute %s; ', r.sig); end if;
    if r.prosecdef and has_function_privilege('authenticated', r.sig, 'execute') and not r.proname = any (callable) then
      fails := fails || format('authenticated can execute definer %s; ', r.sig);
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.tick_vault_get(uuid)', 'execute') then fails := fails || 'app can read Vault; '; end if;
  -- 4. No Plaid token, secret or full account / routing number column anywhere in public.
  for r in select table_name, column_name from information_schema.columns where table_schema = 'public'
             and (column_name ~* '(access_token|public_token|secret|password|account_number|routing|^numbers$)' and column_name not in ('vault_secret_id')) loop
    fails := fails || format('suspicious column %s.%s; ', r.table_name, r.column_name);
  end loop;

  -- 5. As B: read, update, delete A's rows in EVERY table with a user_id column.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  for r in select table_name from information_schema.columns where table_schema = 'public' and column_name = 'user_id'
             and table_name in (select tablename from pg_tables where schemaname = 'public') loop
    begin
      execute format('select count(*) from public.%I where user_id = %L', r.table_name, a) into n;
      if n <> 0 then fails := fails || format('B reads A in %s; ', r.table_name); end if;
    exception when insufficient_privilege then null; end;
    begin
      execute format('update public.%I set user_id = user_id where user_id = %L', r.table_name, a);
      get diagnostics n = row_count;
      if n <> 0 then fails := fails || format('B updates A in %s; ', r.table_name); end if;
    exception when insufficient_privilege then null; end;
    begin
      execute format('delete from public.%I where user_id = %L', r.table_name, a);
      get diagnostics n = row_count;
      if n <> 0 then fails := fails || format('B deletes A in %s; ', r.table_name); end if;
    exception when insufficient_privilege then null; end;
  end loop;
  -- 6. As B: insert rows that claim to be A's.
  begin insert into public.transactions (user_id, amount_cents, occurred_at) values (a, -1, now()); fails := fails || 'B inserts A txn; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.accounts (user_id, name) values (a, 'x'); fails := fails || 'B inserts A account; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.categories (user_id, name) values (a, 'x'); fails := fails || 'B inserts A category; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.budgets (user_id, category_id, monthly_cap_cents) values (a, cat_a, 1); fails := fails || 'B inserts A budget; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.rules (user_id, pattern) values (a, 'x'); fails := fails || 'B inserts A rule; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.goals (user_id, name, target_cents) values (a, 'x', 1); fails := fails || 'B inserts A goal; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.paydays (user_id, day) values (a, current_date + 1); fails := fails || 'B inserts A payday; '; exception when insufficient_privilege or check_violation then null; end;
  -- Server-only writes, even for one's OWN rows.
  begin insert into public.ingest_tokens (user_id, token_hash, last4) values (b, 'mine', 'mine'); fails := fails || 'app mints a capture token; '; exception when insufficient_privilege or check_violation then null; end;
  begin update public.ingest_tokens set token_hash = 'x' where user_id = b; fails := fails || 'app rewrites a token hash; '; exception when insufficient_privilege then null; end;
  begin insert into public.connections (user_id, institution) values (b, 'Evil'); fails := fails || 'app inserts a connection; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.plaid_items (item_id, user_id) values ('fake', b); fails := fails || 'app inserts plaid_items; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.audit_log (user_id, event) values (b, 'sign_in'); fails := fails || 'app writes audit_log; '; exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.transactions (user_id, amount_cents, occurred_at, account_id) values (b, -1, now(), acct_a);   -- foreign key into A's account
    select count(*) into n from public.transactions t join public.accounts x on x.id = t.account_id where t.user_id = b;
    if n <> 0 then fails := fails || 'B joins to A account via FK; '; end if;
  exception when insufficient_privilege or check_violation or foreign_key_violation then null; end;
  -- 7. As B through functions: A's data never comes back.
  if (public.tick_flows(null, null) ->> 'count')::int <> (select count(*) from public.transactions where user_id = b) then fails := fails || 'tick_flows leaks; '; end if;
  if public.tick_links_used(a) <> 0 then fails := fails || 'tick_links_used(A) as B; '; end if;
  begin perform public.tick_vault_get(gen_random_uuid()); fails := fails || 'B calls tick_vault_get; '; exception when insufficient_privilege then null; end;
  begin perform public.tick_vault_upsert('x', 'y'); fails := fails || 'B calls tick_vault_upsert; '; exception when insufficient_privilege then null; end;
  begin perform public.seed_default_categories(a); fails := fails || 'B seeds A categories; '; exception when insufficient_privilege then null; end;
  begin perform public.tick_call_api('/jobs/sync-all'); fails := fails || 'B calls tick_call_api; '; exception when insufficient_privilege then null; end;
  -- B's own token: the app can't write it at all (revoke goes through the API), so it can never un-revoke one.
  reset role;
  insert into public.ingest_tokens (user_id, token_hash, last4, revoked_at) values (b, 'hash-b', 'bbbb', now());
  set local role authenticated;
  begin update public.ingest_tokens set revoked_at = null where user_id = b; get diagnostics n = row_count;
    if n <> 0 then fails := fails || 'app un-revokes a capture token; '; end if;
  exception when insufficient_privilege then null; end;
  reset role;
  -- Not even the server can bring a revoked token back or swap its hash.
  begin update public.ingest_tokens set revoked_at = null where user_id = b; fails := fails || 'server un-revokes a token; ';
  exception when raise_exception then null; end;
  begin update public.ingest_tokens set token_hash = 'x' where user_id = a; fails := fails || 'token hash mutable; ';
  exception when raise_exception then null; end;

  -- 8. anon: nothing readable, nothing callable.
  perform set_config('request.jwt.claims', '', true);
  set local role anon;
  for r in select tablename from pg_tables where schemaname = 'public' loop
    begin
      execute format('select count(*) from public.%I', r.tablename) into n;
      if n <> 0 then fails := fails || format('anon reads %s; ', r.tablename); end if;
    exception when insufficient_privilege then null; end;
  end loop;
  begin perform public.tick_flows(null, null); fails := fails || 'anon calls tick_flows; '; exception when insufficient_privilege then null; end;
  reset role;

  -- 9. Append-only: audit_log and plaid_items can't be changed, even by the server.
  begin update public.audit_log set event = 'sign_in' where user_id = a; fails := fails || 'audit_log updatable; '; exception when raise_exception then null; end;
  begin delete from public.audit_log where user_id = a; fails := fails || 'audit_log deletable; '; exception when raise_exception then null; end;
  begin delete from public.plaid_items where user_id = a; fails := fails || 'plaid_items deletable; '; exception when raise_exception then null; end;
  -- Sign-in is audited by the database.
  update auth.users set last_sign_in_at = now() where id = a;
  if not exists (select 1 from public.audit_log where user_id = a and event = 'sign_in') then fails := fails || 'sign-in not audited; '; end if;

  -- 10. Storage: private, limited, per-user folders.
  if (select public from storage.buckets where id = 'receipts') then fails := fails || 'receipts bucket public; '; end if;
  if (select file_size_limit from storage.buckets where id = 'receipts') is null then fails := fails || 'receipts has no size limit; '; end if;
  if not exists (select 1 from storage.buckets where id = 'receipts' and 'image/jpeg' = any (allowed_mime_types)) then fails := fails || 'receipts mime list; '; end if;
  insert into storage.objects (bucket_id, name, owner) values ('receipts', a || '/r1.jpg', a);
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from storage.objects where name like a || '/%'; if n <> 0 then fails := fails || 'B lists A receipts; '; end if;
  begin insert into storage.objects (bucket_id, name, owner) values ('receipts', a || '/evil.jpg', b); fails := fails || 'B writes into A folder; ';
  exception when insufficient_privilege or check_violation then null; end;
  update storage.objects set name = b || '/stolen.jpg' where name = a || '/r1.jpg'; get diagnostics n = row_count;
  if n <> 0 then fails := fails || 'B moves A receipt; '; end if;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  set local role anon;
  begin select count(*) into n from storage.objects; if n <> 0 then fails := fails || 'anon lists receipts; '; end if; exception when insufficient_privilege then null; end;
  reset role;

  if fails <> '' then raise exception 'ATTACK_TESTS_FAILED: %', fails; end if;
  raise exception 'ATTACK_TESTS_PASSED';
end $$;
