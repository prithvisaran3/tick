-- OpenRouter free-model usage tracking, result cache, link-token ownership for Plaid webhooks.
alter table public.ai_usage add column if not exists provider text not null default 'gemini';
alter table public.ai_usage add column if not exists model_used text;
alter table public.ai_usage add column if not exists status text not null default 'ok';
create index if not exists ai_usage_day_idx on public.ai_usage (provider, created_at desc);

create table if not exists public.ai_cache (
  key text primary key,                 -- sha256 of feature + scrubbed input
  feature text not null,
  value jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.ai_cache enable row level security;
alter table public.ai_cache force row level security;      -- no policies: server (service role) only

create table if not exists public.plaid_link_sessions (
  link_token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  connection_id uuid,                    -- set for update mode
  created_at timestamptz not null default now()
);
alter table public.plaid_link_sessions enable row level security;
alter table public.plaid_link_sessions force row level security;   -- server only

-- Budgets and goals editors write through the owner policies that already exist.
create table if not exists public.paydays (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  day date not null,
  moved_cents bigint not null default 0,
  note text,
  primary key (user_id, day)
);
alter table public.paydays enable row level security;
alter table public.paydays force row level security;
create policy paydays_owner on public.paydays for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

select cron.schedule('tick-daily-advice', '0 12 * * *', $$select public.tick_call_api('/jobs/daily-advice')$$);
