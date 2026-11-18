-- Planned one-off expenses ("Birthday gift, $500, Nov 22"). Subtracted from Safe to spend in their pay period, then matched to the real
-- transaction and dropped. If one leaves a goal short this paycheck, `resolution` records what I chose: later paychecks carry it, or the deadline moved.
create table if not exists public.planned_expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name text not null check (char_length(name) between 1 and 60),
  amount_cents bigint not null check (amount_cents > 0 and amount_cents < 100000000),
  due date not null,
  status text not null default 'planned' check (status in ('planned','matched','dismissed')),
  matched_txn uuid references public.transactions(id) on delete set null,
  rejected_txns uuid[] not null default '{}' check (coalesce(array_length(rejected_txns, 1), 0) <= 50),
  goal_id uuid references public.goals(id) on delete set null,
  resolution text check (resolution in ('catch_up','move_deadline')),
  shortfall_cents bigint not null default 0 check (shortfall_cents >= 0),
  created_at timestamptz not null default now()
);
create index if not exists planned_expenses_user_idx on public.planned_expenses (user_id, status, due);
alter table public.planned_expenses enable row level security;
alter table public.planned_expenses force row level security;
create policy planned_expenses_owner on public.planned_expenses for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.planned_expenses from anon;

-- A matched transaction has to be mine too.
create or replace function public.planned_expense_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.matched_txn is not null and not exists (select 1 from public.transactions t where t.id = new.matched_txn and t.user_id = new.user_id) then
    raise exception 'not found' using errcode = '42501';
  end if;
  if new.goal_id is not null and not exists (select 1 from public.goals g where g.id = new.goal_id and g.user_id = new.user_id) then
    raise exception 'not found' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.planned_expense_guard() from public, anon, authenticated;
drop trigger if exists planned_expense_guard_t on public.planned_expenses;
create trigger planned_expense_guard_t before insert or update on public.planned_expenses for each row execute function public.planned_expense_guard();
