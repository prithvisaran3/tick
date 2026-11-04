-- Tick schema. Every table carries user_id; RLS is owner-only (see 0002).
create extension if not exists pgcrypto;

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  display_name text, email text,
  timezone text not null default 'America/New_York',
  currency text not null default 'USD',
  created_at timestamptz not null default now()
);

create table public.settings (
  user_id uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  haptics text not null default 'full' check (haptics in ('full','subtle','off')),
  sound boolean not null default true,
  theme text not null default 'system' check (theme in ('system','dark','light')),
  face_id_lock boolean not null default false,
  privacy_blur boolean not null default true,
  morning_time text not null default '08:00',
  weekly_dow int not null default 7 check (weekly_dow between 1 and 7),
  weekly_time text not null default '19:00',
  payday_rule jsonb,            -- {frequency: weekly|biweekly|semimonthly|monthly, next_date: 'YYYY-MM-DD', amount_cents: int}
  onboarding_done boolean not null default false,
  demo_mode boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.ingest_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  token_hash text not null unique,      -- sha256 hex of the token; the token itself is shown once
  last4 text not null,
  label text not null default 'Shortcuts',
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);

create table public.connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  provider text not null default 'plaid',
  institution text,
  item_id text,
  status text not null default 'active' check (status in ('active','login_required','error','removed')),
  vault_secret_id uuid,                 -- reference into vault.secrets; the access token never leaves the server
  cursor text,
  last_synced_at timestamptz,
  error_code text,
  created_at timestamptz not null default now()
);
create unique index connections_item_idx on public.connections(provider, item_id) where item_id is not null;

create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  connection_id uuid references public.connections(id) on delete set null,
  provider_account_id text,
  name text not null,
  mask text,
  type text not null default 'checking' check (type in ('checking','savings','credit','cash','other')),
  balance_cents bigint,
  available_cents bigint,
  currency text not null default 'USD',
  is_manual boolean not null default false,
  include_in_safe boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index accounts_provider_idx on public.accounts(user_id, provider_account_id) where provider_account_id is not null;

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name text not null,
  icon text not null default 'card',
  color_key text not null default 'shop' check (color_key in ('food','ride','sub','home','biz','inc','shop')),
  kind text not null default 'spend' check (kind in ('spend','income','transfer')),
  sort int not null default 0,
  is_default boolean not null default false,
  unique (user_id, name)
);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  amount_cents bigint not null,          -- negative = money out
  currency text not null default 'USD',
  occurred_at timestamptz not null,
  merchant_raw text,
  merchant_clean text,
  category_id uuid references public.categories(id) on delete set null,
  account_id uuid references public.accounts(id) on delete set null,
  card_last4 text,
  status text not null default 'posted' check (status in ('pending','posted')),
  sources jsonb not null default '[]',   -- [{source, ref, at, amount_cents?}] every channel that reported this purchase
  plaid_transaction_id text,
  plaid_pending_id text,
  confidence numeric(3,2) not null default 1.0,
  needs_review boolean not null default false,
  tags text[] not null default '{}',
  note text,
  receipt_path text,
  splits jsonb,
  participants jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index transactions_user_time_idx on public.transactions(user_id, occurred_at desc);
create unique index transactions_plaid_idx on public.transactions(user_id, plaid_transaction_id) where plaid_transaction_id is not null;
create index transactions_review_idx on public.transactions(user_id) where needs_review;
create trigger transactions_updated before update on public.transactions for each row execute function public.set_updated_at();

create table public.rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  pattern text not null,                 -- lower-cased merchant substring
  category_id uuid references public.categories(id) on delete cascade,
  tags text[] not null default '{}',
  source text not null default 'learned' check (source in ('learned','manual')),
  hits int not null default 0,
  created_at timestamptz not null default now(),
  unique (user_id, pattern)
);

create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  category_id uuid not null references public.categories(id) on delete cascade,
  monthly_cap_cents bigint not null check (monthly_cap_cents > 0),
  created_at timestamptz not null default now(),
  unique (user_id, category_id)
);

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name text not null,
  target_cents bigint not null check (target_cents > 0),
  saved_cents bigint not null default 0,
  per_payday_cents bigint not null default 0,
  due_date date,
  created_at timestamptz not null default now()
);

create table public.people (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name text not null,
  email text,
  created_at timestamptz not null default now()
);

create table public.recurring (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  merchant text not null,
  category_id uuid references public.categories(id) on delete set null,
  cadence text not null check (cadence in ('weekly','biweekly','monthly','yearly')),
  expected_cents bigint not null,        -- positive magnitude
  next_date date not null,
  price_history jsonb not null default '[]',   -- [{date, cents}]
  status text not null default 'active' check (status in ('active','paused','ended')),
  is_manual boolean not null default false,
  last_seen date,
  created_at timestamptz not null default now(),
  unique (user_id, merchant)
);

create table public.expected (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  kind text not null check (kind in ('paycheck','refund','iou')),
  label text not null,
  amount_cents bigint not null check (amount_cents > 0),
  expected_date date not null,
  status text not null default 'expected' check (status in ('expected','landed','missed','cancelled')),
  matched_transaction_id uuid references public.transactions(id) on delete set null,
  person_id uuid references public.people(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  kind text not null,                    -- weekly | morning_advice | nudge
  body text not null,
  payload jsonb,
  period date,
  created_at timestamptz not null default now()
);

create table public.chats (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  title text, created_at timestamptz not null default now()
);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  chat_id uuid not null references public.chats(id) on delete cascade,
  role text not null check (role in ('user','assistant','tool')),
  content text,
  blocks jsonb,                          -- charts / transaction refs rendered inline
  created_at timestamptz not null default now()
);

create table public.ingest_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  source text not null,
  payload jsonb not null,
  result jsonb,
  status text not null default 'ok',
  transaction_id uuid references public.transactions(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.snapshots (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  day date not null,
  spent_cents bigint not null default 0,
  earned_cents bigint not null default 0,
  safe_to_spend_cents bigint,
  balance_cents bigint,
  primary key (user_id, day)
);

create table public.ai_usage (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade default auth.uid(),
  feature text not null,
  model text not null,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  latency_ms int,
  ok boolean not null default true,
  created_at timestamptz not null default now()
);
create index ai_usage_user_idx on public.ai_usage(user_id, created_at desc);

-- Default categories (also used for new sign-ups).
create or replace function public.seed_default_categories(uid uuid) returns void language sql security definer set search_path = public as $$
  insert into public.categories (user_id, name, icon, color_key, kind, sort, is_default) values
   (uid,'Groceries','receipt','food','spend',1,true),
   (uid,'Restaurants','receipt','food','spend',2,true),
   (uid,'Coffee','receipt','food','spend',3,true),
   (uid,'Rideshare','arrow-out','ride','spend',4,true),
   (uid,'Travel','arrow-out','ride','spend',5,true),
   (uid,'Shopping','card','shop','spend',6,true),
   (uid,'Subscriptions','repeat','sub','spend',7,true),
   (uid,'Software','briefcase','biz','spend',8,true),
   (uid,'Rent','bank','home','spend',9,true),
   (uid,'Utilities','bank','home','spend',10,true),
   (uid,'Phone and internet','bank','home','spend',11,true),
   (uid,'Health','goal','shop','spend',12,true),
   (uid,'Fun','card','shop','spend',13,true),
   (uid,'Transfer','repeat','shop','transfer',14,true),
   (uid,'Income','arrow-in','inc','income',15,true),
   (uid,'Other','card','shop','spend',16,true)
  on conflict (user_id, name) do nothing;
$$;
revoke all on function public.seed_default_categories(uuid) from public, anon, authenticated;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(user_id, display_name, email)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'), new.email)
    on conflict do nothing;
  insert into public.settings(user_id) values (new.id) on conflict do nothing;
  perform public.seed_default_categories(new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
