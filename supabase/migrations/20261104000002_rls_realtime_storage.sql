-- Owner-only RLS on every table.
do $$
declare t text;
begin
  foreach t in array array['profiles','settings','ingest_tokens','connections','accounts','categories','transactions','rules','budgets','goals','people','recurring','expected','insights','chats','messages','ingest_logs','snapshots','ai_usage']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('create policy %I on public.%I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_owner', t);
  end loop;
end $$;

-- Clients never write bank secrets or sync state: tighten connections to read-only for the app.
drop policy connections_owner on public.connections;
create policy connections_read on public.connections for select to authenticated using (user_id = auth.uid());
-- ai_usage and ingest_logs are written by the server only.
drop policy ai_usage_owner on public.ai_usage;
create policy ai_usage_read on public.ai_usage for select to authenticated using (user_id = auth.uid());
drop policy ingest_logs_owner on public.ingest_logs;
create policy ingest_logs_read on public.ingest_logs for select to authenticated using (user_id = auth.uid());
-- Messages for Ask Tick are written by the server; the app can read and delete them.
drop policy messages_owner on public.messages;
create policy messages_read on public.messages for select to authenticated using (user_id = auth.uid());
create policy messages_delete on public.messages for delete to authenticated using (user_id = auth.uid());

-- Realtime
alter publication supabase_realtime add table public.transactions, public.expected, public.messages, public.connections;

-- Private receipts bucket; objects live under <user_id>/...
insert into storage.buckets (id, name, public) values ('receipts', 'receipts', false) on conflict (id) do nothing;
create policy receipts_owner_select on storage.objects for select to authenticated using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
create policy receipts_owner_insert on storage.objects for insert to authenticated with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
create policy receipts_owner_update on storage.objects for update to authenticated using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
create policy receipts_owner_delete on storage.objects for delete to authenticated using (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
