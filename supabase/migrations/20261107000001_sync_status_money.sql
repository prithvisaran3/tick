-- Final polish, part 0 + 1: honest bank sync status, and ONE definition of the money rules in SQL.

-- ---------- connections: a real sync state machine ----------
alter table public.connections add column if not exists sync_state text not null default 'pending';
alter table public.connections drop constraint if exists connections_sync_state_check;
alter table public.connections add constraint connections_sync_state_check
  check (sync_state in ('pending','syncing','ok','partial','login_required','bank_issue','error'));
alter table public.connections add column if not exists sync_started_at timestamptz;
alter table public.connections add column if not exists last_attempt_at timestamptz;
alter table public.connections add column if not exists last_error text;           -- a Plaid error code or an exception class; never user data
alter table public.connections add column if not exists initial_complete boolean not null default false;
alter table public.connections add column if not exists historical_complete boolean not null default false;
alter table public.connections add column if not exists last_webhook_code text;
alter table public.connections add column if not exists last_webhook_at timestamptz;
alter table public.connections add column if not exists last_added int not null default 0;

update public.connections set
  sync_state = case when status = 'login_required' then 'login_required'
                    when status = 'error' then 'error'
                    when last_synced_at is not null then 'ok' else 'pending' end,
  initial_complete = (last_synced_at is not null),
  historical_complete = (last_synced_at is not null),
  last_error = case when status = 'error' then error_code else null end
where sync_state = 'pending';

-- Counts per account for the Banks screen (owner only through RLS; SECURITY INVOKER).
create or replace function public.tick_account_counts() returns jsonb
language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_object_agg(account_id::text, jsonb_build_object('count', n, 'latest', latest)), '{}'::jsonb)
  from (select account_id, count(*) n, max(occurred_at) latest from public.transactions where account_id is not null group by account_id) x
$$;
revoke all on function public.tick_account_counts() from public, anon;
grant execute on function public.tick_account_counts() to authenticated;

-- ---------- money rules (docs/MONEY_RULES.md): the ONLY place they exist ----------
-- flow: null ordinary | 'transfer' between my own accounts or a card/loan payment (excluded both sides) | 'bill' loan payment from checking
--       | 'settlement' a Tally settle-up (excluded: the expense was already tracked in Tally).
alter table public.transactions drop constraint if exists transactions_flow_check;
alter table public.transactions add constraint transactions_flow_check check (flow is null or flow in ('transfer','bill','settlement'));

-- Friends and family: Zelle and other person-to-person money is real spending / income, never a transfer.
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
   (uid,'Friends and family','arrow-out','shop','spend',14,true),
   (uid,'Loan payment','bank','home','spend',15,true),
   (uid,'Fees and interest','card','shop','spend',16,true),
   (uid,'Transfer','repeat','shop','transfer',17,true),
   (uid,'Income','arrow-in','inc','income',18,true),
   (uid,'Other','card','shop','spend',19,true)
  on conflict (user_id, name) do nothing;
$$;
revoke all on function public.seed_default_categories(uuid) from public, anon, authenticated;
do $$ declare u uuid; begin
  for u in select id from auth.users loop perform public.seed_default_categories(u); end loop;
end $$;

-- THE money rules, in one place. Everything that totals money (Activity, Today, Insights, Tally, Ask Tick, demo parity tests) reads these
-- columns instead of re-deriving them:
--   excluded = flow in (transfer, settlement): never spending, never income. A Transfer-kind CATEGORY is only a label and hides nothing
--              (that is how "Zelle to Kaarthik" used to show $0).
--   out_c    = money leaving as a positive number (purchases, card purchases, Zelle/P2P to people, fees, interest, loan payments). A positive
--              amount on a card or loan that is not an Income row is a refund: it makes out_c NEGATIVE (spending goes down), never income.
--   in_c     = money arriving in a cash account (payroll, Zelle/P2P from people, interest) or anything categorised Income.
create or replace function public.tick_classified(p_uid uuid, p_from timestamptz, p_to timestamptz)
returns table (id uuid, occurred_at timestamptz, amount_cents bigint, category_id uuid, account_id uuid, flow text, tags text[], needs_review boolean,
               merchant text, search text, note text, cat_kind text, cat_name text, acct_type text, excluded boolean, out_c bigint, in_c bigint)
language sql stable security invoker set search_path = public as $$
  select t.id, t.occurred_at, t.amount_cents, t.category_id, t.account_id, t.flow, t.tags, t.needs_review,
         coalesce(nullif(t.merchant_clean, ''), t.merchant_raw, '') as merchant,
         lower(coalesce(t.merchant_clean, '') || ' ' || coalesce(t.merchant_raw, '') || ' ' || coalesce(t.note, '')) as search,
         t.note, c.kind, c.name, a.type,
         (t.flow in ('transfer','settlement')) is true as excluded,
         case when (t.flow in ('transfer','settlement')) is true then 0::bigint
              when t.amount_cents < 0 then -t.amount_cents
              when t.amount_cents > 0 and c.kind is distinct from 'income' and a.type in ('credit','loan') then -t.amount_cents
              else 0::bigint end as out_c,
         case when (t.flow in ('transfer','settlement')) is true then 0::bigint
              when t.amount_cents > 0 and (c.kind = 'income' or coalesce(a.type, 'checking') not in ('credit','loan')) then t.amount_cents
              else 0::bigint end as in_c
  from public.transactions t
  left join public.categories c on c.id = t.category_id
  left join public.accounts a on a.id = t.account_id
  where t.user_id = p_uid and (p_from is null or t.occurred_at >= p_from) and (p_to is null or t.occurred_at < p_to)
$$;

drop function if exists public.tick_filtered(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean);
create or replace function public.tick_filtered(p_from timestamptz, p_to timestamptz, p_types text[], p_accounts uuid[], p_categories uuid[],
                                                p_query text, p_business boolean, p_review boolean)
returns table (id uuid, occurred_at timestamptz, amount_cents bigint, category_id uuid, account_id uuid, flow text, tags text[],
               needs_review boolean, cat_kind text, acct_type text, excluded boolean, out_c bigint, in_c bigint)
language sql stable security invoker set search_path = public, extensions as $$
  select k.id, k.occurred_at, k.amount_cents, k.category_id, k.account_id, k.flow, k.tags, k.needs_review, k.cat_kind, k.acct_type, k.excluded, k.out_c, k.in_c
  from public.tick_classified(auth.uid(), p_from, p_to) k
  where (coalesce(cardinality(p_types), 0) = 0 or coalesce(k.acct_type, 'checking') = any (p_types))
    and (coalesce(cardinality(p_accounts), 0) = 0 or k.account_id = any (p_accounts))
    and (coalesce(cardinality(p_categories), 0) = 0 or k.category_id = any (p_categories))
    and (not coalesce(p_business, false) or 'business' = any (k.tags))
    and (not coalesce(p_review, false) or k.needs_review)
    and (coalesce(p_query, '') = '' or k.search like '%' || replace(replace(replace(lower(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%'
         or lower(coalesce(k.cat_name, '')) like '%' || replace(replace(replace(lower(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%')
$$;

create or replace function public.tick_flows(p_from timestamptz, p_to timestamptz, p_types text[] default null, p_accounts uuid[] default null,
                                             p_categories uuid[] default null, p_query text default null, p_business boolean default false,
                                             p_review boolean default false)
returns jsonb language sql stable security invoker set search_path = public as $$
  with m as (
    select *, (occurred_at at time zone 'America/New_York')::date as day
    from public.tick_filtered(p_from, p_to, p_types, p_accounts, p_categories, p_query, p_business, p_review)
  )
  select jsonb_build_object(
    'in', coalesce(sum(in_c), 0),
    'out', coalesce(sum(out_c), 0),
    'net', coalesce(sum(in_c), 0) - coalesce(sum(out_c), 0),
    'business', coalesce(sum(out_c) filter (where 'business' = any (tags)), 0),
    'bills', coalesce(sum(out_c) filter (where flow = 'bill'), 0),
    'count', count(*),
    'by_category', coalesce((select jsonb_object_agg(coalesce(category_id::text, 'none'), s) from
                     (select category_id, sum(out_c) s from m where out_c <> 0 group by category_id) x), '{}'::jsonb),
    'by_account', coalesce((select jsonb_object_agg(coalesce(account_id::text, 'none'), s) from
                     (select account_id, sum(out_c) s from m where out_c <> 0 group by account_id) x), '{}'::jsonb),
    'daily_out', coalesce((select jsonb_object_agg(day::text, s) from (select day, sum(out_c) s from m group by day having sum(out_c) <> 0) x), '{}'::jsonb)
  ) from m
$$;

create or replace function public.tick_top_merchants(p_from timestamptz, p_to timestamptz, p_limit int default 8)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('merchant', m, 'cents', s, 'count', n) order by s desc), '[]'::jsonb) from (
    select merchant m, sum(out_c) s, count(*) n from public.tick_classified(auth.uid(), p_from, p_to)
    where out_c <> 0 group by merchant having sum(out_c) > 0 order by sum(out_c) desc limit least(greatest(p_limit, 1), 25)
  ) x
$$;
revoke all on function public.tick_top_merchants(timestamptz, timestamptz, int) from public, anon;
grant execute on function public.tick_top_merchants(timestamptz, timestamptz, int) to authenticated;

-- Import batches (revertible statement imports, part 4).
create table if not exists public.import_batches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  source text not null,                       -- apple_card_csv, chase_csv, ...
  account_id uuid references public.accounts(id) on delete set null,
  filename text,
  rows_added int not null default 0,
  rows_skipped int not null default 0,
  created_at timestamptz not null default now(),
  undone_at timestamptz
);
alter table public.import_batches enable row level security;
alter table public.import_batches force row level security;
create policy import_batches_read on public.import_batches for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete, truncate on public.import_batches from authenticated, anon;
alter table public.transactions add column if not exists import_batch_id uuid references public.import_batches(id) on delete set null;
create index if not exists transactions_import_batch_idx on public.transactions (import_batch_id) where import_batch_id is not null;

-- re-run the standing lockdown for anything created above
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname in ('tick_flows','tick_activity_page','tick_months','tick_filtered','tick_links_used','tick_account_counts','tick_top_merchants','tick_classified') then
      execute format('grant execute on function %s to authenticated', f.sig);
    else
      execute format('revoke execute on function %s from authenticated', f.sig);
    end if;
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Safety net next to webhooks: every 10 minutes retry connections that are not up to date and were last tried over 10 minutes ago.
select cron.schedule('tick-sync-stuck', '*/10 * * * *', $$select public.tick_call_api('/jobs/sync-all?stuck=true')$$);
