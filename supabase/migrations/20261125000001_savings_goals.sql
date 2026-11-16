-- Savings and goals from real balances.
-- account_balances: one row per account per New York day, written by the sync job. The trend line and "change this month" read it.
create table if not exists public.account_balances (
  user_id uuid not null references auth.users(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  day date not null,
  balance_cents bigint not null,
  primary key (account_id, day)
);
create index if not exists account_balances_user_idx on public.account_balances (user_id, day desc);
alter table public.account_balances enable row level security;
alter table public.account_balances force row level security;
create policy account_balances_read on public.account_balances for select to authenticated using (user_id = auth.uid());
revoke all on public.account_balances from anon;
revoke insert, update, delete, truncate on public.account_balances from authenticated;

-- A goal is tied to accounts and measured from their balances. mode 'balance': the accounts reach target_cents.
-- mode 'save_more': the accounts grow by target_cents from start_cents (their balance on start_date).
alter table public.goals add column if not exists mode text not null default 'balance' check (mode in ('balance','save_more'));
alter table public.goals add column if not exists start_cents bigint not null default 0;
alter table public.goals add column if not exists start_date date not null default current_date;
alter table public.goals add column if not exists account_ids uuid[] not null default '{}' check (coalesce(array_length(account_ids, 1), 0) <= 8);

-- "Move $X to savings" on payday: I say done, the next balance sync confirms it. Server-written.
create table if not exists public.goal_moves (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  pay_date date not null,
  cents bigint not null check (cents > 0),
  status text not null default 'done' check (status in ('done','confirmed','unconfirmed')),
  balance_before_cents bigint not null,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  unique (user_id, pay_date)
);
alter table public.goal_moves enable row level security;
alter table public.goal_moves force row level security;
create policy goal_moves_read on public.goal_moves for select to authenticated using (user_id = auth.uid());
revoke all on public.goal_moves from anon;
revoke insert, update, delete, truncate on public.goal_moves from authenticated;

-- Every payday after p_from, up to and including p_to, from the same rule maths as pay_dates. Capped so a bad rule can't loop.
create or replace function public.paydays_between(p_rule jsonb, p_from date, p_to date)
returns setof date language plpgsql stable set search_path = public as $$
declare d date := p_from; nxt date; n int := 0;
begin
  if p_rule is null or p_to is null or p_from is null then return; end if;
  loop
    select next_payday into nxt from public.pay_dates(p_rule, d);
    exit when nxt is null or nxt > p_to or nxt <= d or n >= 400;
    return next nxt;
    d := nxt; n := n + 1;
  end loop;
end $$;
