-- NOT APPLIED to production by the audit (see docs/NEXT.md). Safe to run: indexes are created if missing; cron jobs only prune old rows.
-- Hot queries these serve: Activity/Today (transactions by user + time, by category), Safe to spend (recurring + expected by status/date),
-- the stored morning advice lookup (insights by kind + period), the AI daily-call counter (ai_usage by provider + day), Ask Tick history.
create index if not exists transactions_user_category_time_idx on public.transactions (user_id, category_id, occurred_at desc);
create index if not exists transactions_user_status_idx on public.transactions (user_id, status) where status = 'pending';
create index if not exists transactions_tags_idx on public.transactions using gin (tags);
create index if not exists recurring_user_active_idx on public.recurring (user_id, next_date) where status = 'active';
create index if not exists expected_user_open_idx on public.expected (user_id, expected_date) where status = 'expected';
create index if not exists insights_user_kind_period_idx on public.insights (user_id, kind, period desc);
create index if not exists ingest_logs_user_time_idx on public.ingest_logs (user_id, created_at desc);
create index if not exists messages_chat_time_idx on public.messages (chat_id, created_at);
create index if not exists accounts_user_idx on public.accounts (user_id);
create index if not exists connections_user_idx on public.connections (user_id, status);
create index if not exists ai_usage_ok_day_idx on public.ai_usage (provider, created_at desc) where ok;
create index if not exists ai_cache_created_idx on public.ai_cache (created_at);
create index if not exists plaid_link_sessions_created_idx on public.plaid_link_sessions (created_at);

-- Housekeeping (tables only grow otherwise).
select cron.schedule('tick-prune-link-sessions', '30 3 * * *', $$delete from public.plaid_link_sessions where created_at < now() - interval '2 days'$$);
select cron.schedule('tick-prune-ai-cache', '40 3 * * *', $$delete from public.ai_cache where created_at < now() - interval '120 days'$$);
select cron.schedule('tick-prune-ingest-logs', '50 3 * * *', $$delete from public.ingest_logs where created_at < now() - interval '180 days'$$);
