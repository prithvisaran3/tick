-- RLS tests: runs inside one DO block and always rolls back (raises RLS_TESTS_PASSED at the end).
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
  n int; cat_a uuid; txn_a uuid; t text; fails text := '';
  owner_tables text[] := array['profiles','settings','ingest_tokens','connections','accounts','categories','transactions','rules','budgets','goals','people','recurring','expected','insights','chats','messages','ingest_logs','snapshots','ai_usage'];
begin
  insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data, created_at, updated_at)
    values (a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a-' || a || '@test.local', '{}', now(), now()),
           (b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b-' || b || '@test.local', '{}', now(), now());

  -- Every table has RLS enabled and forced.
  for t in select unnest(owner_tables) loop
    if not (select relrowsecurity and relforcerowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      fails := fails || format('RLS not enabled+forced on %s; ', t);
    end if;
  end loop;

  -- Seed as service (superuser) for user A.
  select id into cat_a from public.categories where user_id = a limit 1;
  if cat_a is null then fails := fails || 'default categories not seeded on signup; '; end if;
  insert into public.transactions (user_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, -1840, now(), 'Uber', cat_a) returning id into txn_a;
  insert into public.accounts (user_id, name) values (a, 'Checking');
  insert into public.connections (user_id, institution) values (a, 'Chase');
  insert into public.goals (user_id, name, target_cents) values (a, 'Trip', 100000);
  insert into public.recurring (user_id, merchant, cadence, expected_cents, next_date) values (a, 'Rent', 'monthly', 185000, current_date);
  insert into public.expected (user_id, kind, label, amount_cents, expected_date) values (a, 'paycheck', 'Payroll', 231000, current_date);
  insert into public.ai_usage (user_id, feature, model) values (a, 'ask', 'x');
  insert into public.ingest_logs (user_id, source, payload) values (a, 'sms', '{}');

  -- Act as user B.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;

  for t in select unnest(array['transactions','accounts','connections','goals','recurring','expected','ai_usage','ingest_logs']) loop
    execute format('select count(*) from public.%I where user_id = %L', t, a) into n;
    if n <> 0 then fails := fails || format('B can read A rows in %s; ', t); end if;
  end loop;
  select count(*) into n from public.categories where user_id = a; if n <> 0 then fails := fails || 'B reads A categories; '; end if;
  select count(*) into n from public.profiles where user_id = a; if n <> 0 then fails := fails || 'B reads A profile; '; end if;
  select count(*) into n from public.settings where user_id = a; if n <> 0 then fails := fails || 'B reads A settings; '; end if;

  update public.transactions set note = 'hacked' where id = txn_a; get diagnostics n = row_count;
  if n <> 0 then fails := fails || 'B updated A txn; '; end if;
  delete from public.transactions where id = txn_a; get diagnostics n = row_count;
  if n <> 0 then fails := fails || 'B deleted A txn; '; end if;

  begin
    insert into public.transactions (user_id, amount_cents, occurred_at) values (a, -1, now());
    fails := fails || 'B inserted a txn as A; ';
  exception when insufficient_privilege or check_violation then null; end;

  -- B can write own rows
  insert into public.transactions (user_id, amount_cents, occurred_at, merchant_raw) values (b, -500, now(), 'Coffee');
  select count(*) into n from public.transactions; if n <> 1 then fails := fails || format('B should see exactly its own txn, saw %s; ', n); end if;

  -- Server-only tables: the app cannot write them.
  begin insert into public.connections (user_id, institution) values (b, 'Evil'); fails := fails || 'app inserted a connection; ';
  exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.ai_usage (user_id, feature, model) values (b, 'x', 'y'); fails := fails || 'app inserted ai_usage; ';
  exception when insufficient_privilege or check_violation then null; end;
  begin insert into public.ingest_logs (user_id, source, payload) values (b, 'x', '{}'); fails := fails || 'app inserted ingest_logs; ';
  exception when insufficient_privilege or check_violation then null; end;

  -- Anonymous sees nothing.
  reset role;
  perform set_config('request.jwt.claims', '', true);
  set local role anon;
  begin
    select count(*) into n from public.transactions; if n <> 0 then fails := fails || 'anon reads transactions; '; end if;
  exception when insufficient_privilege then null; end;
  reset role;

  -- Storage: receipts bucket is private and folder-scoped.
  if (select public from storage.buckets where id = 'receipts') is distinct from false then fails := fails || 'receipts bucket missing or public; '; end if;
  insert into storage.objects (bucket_id, name, owner) values ('receipts', a || '/r1.jpg', a);
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from storage.objects where bucket_id = 'receipts' and name = a || '/r1.jpg'; if n <> 0 then fails := fails || 'B reads A receipt; '; end if;
  reset role;

  -- Realtime publication includes the required tables.
  select count(*) into n from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename in ('transactions','expected','messages','connections');
  if n <> 4 then fails := fails || format('realtime publication has %s of 4 tables; ', n); end if;

  if fails <> '' then raise exception 'RLS_TESTS_FAILED: %', fails; end if;
  raise exception 'RLS_TESTS_PASSED';
end $$;
