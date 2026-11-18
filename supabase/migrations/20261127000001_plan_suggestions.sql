-- Suggestions on payday and once a week: picked by rules in code from the plan's numbers, worded by the model (numbers checked), at most two.
-- Server-written; the app reads them and answers through the API. ask_memory kind 'suggestion' keeps accept/dismiss counts per kind.
create table if not exists public.plan_suggestions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  kind text not null check (kind in ('over_plan','goal_behind','move_to_savings','planned_soon','room_to_spare')),
  facts jsonb not null default '{}'::jsonb check (pg_column_size(facts) < 2048),
  text text not null check (char_length(text) between 1 and 240),
  status text not null default 'shown' check (status in ('shown','accepted','dismissed')),
  created_at timestamptz not null default now(),
  unique (user_id, day, kind)
);
create index if not exists plan_suggestions_user_idx on public.plan_suggestions (user_id, day desc);
alter table public.plan_suggestions enable row level security;
alter table public.plan_suggestions force row level security;
create policy plan_suggestions_read on public.plan_suggestions for select to authenticated using (user_id = auth.uid());
revoke all on public.plan_suggestions from anon;
revoke insert, update, delete, truncate on public.plan_suggestions from authenticated;

alter table public.ask_memory drop constraint if exists ask_memory_kind_check;
alter table public.ask_memory add constraint ask_memory_kind_check check (kind in ('alias','rule','index','proposal','eval','suggestion'));
