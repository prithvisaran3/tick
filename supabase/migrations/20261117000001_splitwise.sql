-- Splitwise money without Splitwise's API. A "Splitwise" category behaves like Friends and family; a card charge matched to a Splitwise expense counts only my share.
do $$ declare u uuid; begin
  for u in select id from auth.users loop
    insert into public.categories (user_id, name, icon, color_key, kind, sort, is_default) values (u, 'Splitwise', 'tally', 'shop', 'spend', 20, true) on conflict (user_id, name) do nothing;
  end loop;
end $$;
create or replace function public.seed_splitwise_category() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.categories (user_id, name, icon, color_key, kind, sort, is_default) values (new.id, 'Splitwise', 'tally', 'shop', 'spend', 20, true) on conflict (user_id, name) do nothing;
  return new;
end $$;
revoke all on function public.seed_splitwise_category() from public, anon, authenticated;
drop trigger if exists seed_splitwise_category_t on auth.users;
create trigger seed_splitwise_category_t after insert on auth.users for each row execute function public.seed_splitwise_category();

alter table public.transactions add column if not exists shared_cents bigint not null default 0 check (shared_cents >= 0);   -- others' part of a charge I fronted

-- Parsed fields and the Gmail message id only, never the body. kind 'rejected': I said a suggestion wasn't Splitwise.
create table if not exists public.splitwise_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  gmail_id text,
  kind text not null check (kind in ('expense','settle_out','settle_in','rejected')),
  description text,
  total_cents bigint,
  my_share_cents bigint,
  person text,
  occurred_on date,
  matched_txn uuid references public.transactions(id) on delete set null,
  covers jsonb not null default '[]',             -- a settlement: the expenses it covered
  created_at timestamptz not null default now()
);
create unique index if not exists splitwise_events_gmail_idx on public.splitwise_events (user_id, gmail_id) where gmail_id is not null;
alter table public.splitwise_events enable row level security;
alter table public.splitwise_events force row level security;
create policy splitwise_events_read on public.splitwise_events for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete, truncate on public.splitwise_events from authenticated, anon;

-- The money rules again, with two changes: Splitwise rows count as money with friends, and a purchase is net of what others owe me for it.
create or replace function public.tick_classified(p_uid uuid, p_from timestamptz, p_to timestamptz)
returns table (id uuid, occurred_at timestamptz, amount_cents bigint, category_id uuid, account_id uuid, flow text, tags text[], needs_review boolean,
               merchant text, search text, note text, cat_kind text, cat_name text, acct_type text, excluded boolean, out_c bigint, in_c bigint, friends_c bigint)
language sql stable security invoker set search_path = public as $$
  with cfg as (select coalesce((select s.include_friends from public.settings s where s.user_id = p_uid), false) as include_friends),
  r as (
    select t.*, c.kind as cat_kind, c.name as cat_name, a.type as acct_type,
           (t.flow is null and c.name in ('Friends and family', 'Splitwise')) as friends,
           (t.flow in ('transfer','settlement','reimbursement')) is true or (t.flow is null and c.name in ('Friends and family', 'Splitwise') and not cfg.include_friends) as excluded
    from public.transactions t
    cross join cfg
    left join public.categories c on c.id = t.category_id
    left join public.accounts a on a.id = t.account_id
    where t.user_id = p_uid and (p_from is null or t.occurred_at >= p_from) and (p_to is null or t.occurred_at < p_to)
  )
  select r.id, r.occurred_at, r.amount_cents, r.category_id, r.account_id, r.flow, r.tags, r.needs_review,
         coalesce(nullif(r.merchant_clean, ''), r.merchant_raw, '') as merchant,
         lower(coalesce(r.merchant_clean, '') || ' ' || coalesce(r.merchant_raw, '') || ' ' || coalesce(r.note, '')) as search,
         r.note, r.cat_kind, r.cat_name, r.acct_type, r.excluded,
         case when r.excluded then 0::bigint
              when r.amount_cents < 0 then -r.amount_cents - r.reimbursed_cents - r.shared_cents
              when r.amount_cents > 0 and r.cat_kind is distinct from 'income' and r.acct_type in ('credit','loan') then -r.amount_cents
              else 0::bigint end as out_c,
         case when r.excluded then 0::bigint
              when r.amount_cents > 0 and (r.cat_kind = 'income' or coalesce(r.acct_type, 'checking') not in ('credit','loan')) then r.amount_cents
              else 0::bigint end as in_c,
         case when r.friends then r.amount_cents else 0::bigint end as friends_c
  from r
$$;
