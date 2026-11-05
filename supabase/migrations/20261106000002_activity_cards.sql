-- Parts 2 and 3: server-side Activity (keyset pages, month totals, filters, search), credit cards, loans, internal transfers.
-- All totals the app shows come from tick_flows / tick_activity_page below. Both are SECURITY INVOKER: RLS decides what is visible.

create extension if not exists pg_trgm with schema extensions;

-- ---------- accounts: cards and loans ----------
alter table public.accounts drop constraint if exists accounts_type_check;
alter table public.accounts add constraint accounts_type_check check (type in ('checking','savings','credit','loan','cash','other'));
alter table public.accounts add column if not exists subtype text;                    -- Plaid subtype: credit card, student, ...
alter table public.accounts add column if not exists institution text;                -- "Discover" for labels like "Discover ••1234"
alter table public.accounts add column if not exists credit_limit_cents bigint;       -- cards; positive
alter table public.accounts add column if not exists statement_balance_cents bigint;  -- cards: last statement, positive = owed
alter table public.accounts add column if not exists minimum_payment_cents bigint;    -- cards and loans; positive
alter table public.accounts add column if not exists next_payment_due_date date;      -- cards and loans
alter table public.accounts add column if not exists last_statement_date date;        -- cards: statement issue date
alter table public.accounts add column if not exists last_payment_cents bigint;       -- positive
alter table public.accounts add column if not exists last_payment_date date;
alter table public.accounts add column if not exists apr_bps int;                     -- cards: purchase APR, basis points (2499 = 24.99%)
alter table public.accounts add column if not exists interest_rate_bps int;           -- loans
alter table public.accounts add column if not exists next_payment_cents bigint;       -- loans: next scheduled payment, positive
alter table public.accounts add column if not exists liabilities_updated_at timestamptz;
alter table public.accounts add column if not exists hidden boolean not null default false;
-- Balances: depository positive = money you have; credit and loan NEGATIVE = money you owe (balance_cents).

-- Products the Item was granted at link time (e.g. {transactions,liabilities}). Liabilities is only ever read when granted, so an
-- older Item is never silently upgraded to a billed product.
alter table public.connections add column if not exists products text[] not null default '{}';

-- ---------- transactions: internal transfers and bills ----------
-- flow: null = ordinary; 'transfer' = money moving between my own accounts (excluded from spending AND income, both sides);
-- 'bill' = a loan payment leaving checking (cash out, counted as a bill, never discretionary).
alter table public.transactions add column if not exists flow text;
alter table public.transactions drop constraint if exists transactions_flow_check;
alter table public.transactions add constraint transactions_flow_check check (flow is null or flow in ('transfer','bill'));
alter table public.transactions add column if not exists transfer_pair_id uuid;      -- the other side (null = unmatched)
alter table public.transactions add column if not exists external_ref text;          -- import de-duplication key (Apple Card CSV)
create unique index if not exists transactions_external_ref_idx on public.transactions (user_id, external_ref) where external_ref is not null;

-- Keyset pagination (occurred_at desc, id desc), per-account filters and search.
create index if not exists transactions_user_time_id_idx on public.transactions (user_id, occurred_at desc, id desc);
create index if not exists transactions_user_account_time_idx on public.transactions (user_id, account_id, occurred_at desc);
create index if not exists transactions_merchant_trgm_idx on public.transactions using gin (lower(coalesce(merchant_clean, '') || ' ' || coalesce(merchant_raw, '') || ' ' || coalesce(note, '')) extensions.gin_trgm_ops);
create index if not exists transactions_pair_idx on public.transactions (transfer_pair_id) where transfer_pair_id is not null;

-- ---------- categories ----------
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
   (uid,'Loan payment','bank','home','spend',14,true),
   (uid,'Fees and interest','card','shop','spend',15,true),
   (uid,'Transfer','repeat','shop','transfer',16,true),
   (uid,'Income','arrow-in','inc','income',17,true),
   (uid,'Other','card','shop','spend',18,true)
  on conflict (user_id, name) do nothing;
$$;
revoke all on function public.seed_default_categories(uuid) from public, anon, authenticated;
do $$ declare u uuid; begin
  for u in select id from auth.users loop perform public.seed_default_categories(u); end loop;
end $$;

-- ---------- shared filter ----------
-- One definition of "which rows" used by both the page and the totals, so the list, its headers and the month strip always agree.
-- p_types: account types ('checking','savings','credit','loan','cash'); p_accounts / p_categories: ids; p_query: case-insensitive
-- substring of merchant, note or category name; p_business / p_review: tag filters. Null or empty arrays mean "no filter".
create or replace function public.tick_filtered(p_from timestamptz, p_to timestamptz, p_types text[], p_accounts uuid[], p_categories uuid[],
                                                p_query text, p_business boolean, p_review boolean)
returns table (id uuid, occurred_at timestamptz, amount_cents bigint, category_id uuid, account_id uuid, flow text, tags text[],
               needs_review boolean, cat_kind text, acct_type text)
language sql stable security invoker set search_path = public, extensions as $$
  select t.id, t.occurred_at, t.amount_cents, t.category_id, t.account_id, t.flow, t.tags, t.needs_review, c.kind, a.type
  from public.transactions t
  left join public.categories c on c.id = t.category_id
  left join public.accounts a on a.id = t.account_id
  where t.user_id = auth.uid()
    and (p_from is null or t.occurred_at >= p_from)
    and (p_to is null or t.occurred_at < p_to)
    and (coalesce(cardinality(p_types), 0) = 0 or coalesce(a.type, 'checking') = any (p_types))
    and (coalesce(cardinality(p_accounts), 0) = 0 or t.account_id = any (p_accounts))
    and (coalesce(cardinality(p_categories), 0) = 0 or t.category_id = any (p_categories))
    and (not coalesce(p_business, false) or 'business' = any (t.tags))
    and (not coalesce(p_review, false) or t.needs_review)
    and (coalesce(p_query, '') = '' or
         lower(coalesce(t.merchant_clean, '') || ' ' || coalesce(t.merchant_raw, '') || ' ' || coalesce(t.note, '')) like '%' || replace(replace(replace(lower(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%'
         or lower(coalesce(c.name, '')) like '%' || replace(replace(replace(lower(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%')
$$;

-- Money rules (mirrored by app/lib/domain/flows.dart for demo mode; both are tested on the same fixture):
--   excluded  = internal transfer (flow 'transfer') or a Transfer-kind category: never spending, never income.
--   out       = money leaving, as a positive number (purchases, card purchases, fees, loan payments).
--   refund    = money coming back onto a card or loan that isn't a payment: it lowers out, it is not income.
--   in        = money arriving in cash accounts (checking, savings, cash) or anything categorised Income.
create or replace function public.tick_flows(p_from timestamptz, p_to timestamptz, p_types text[] default null, p_accounts uuid[] default null,
                                             p_categories uuid[] default null, p_query text default null, p_business boolean default false,
                                             p_review boolean default false)
returns jsonb language sql stable security invoker set search_path = public as $$
  with f as (
    select *, (flow = 'transfer' or cat_kind = 'transfer') is true as excluded,
           (occurred_at at time zone 'America/New_York')::date as day
    from public.tick_filtered(p_from, p_to, p_types, p_accounts, p_categories, p_query, p_business, p_review)
  ), m as (
    select *,
      case when not excluded and amount_cents < 0 then -amount_cents
           when not excluded and amount_cents > 0 and cat_kind is distinct from 'income' and acct_type in ('credit','loan') then -amount_cents
           else 0 end as out_c,
      case when not excluded and amount_cents > 0 and (cat_kind = 'income' or coalesce(acct_type, 'checking') not in ('credit','loan')) then amount_cents
           else 0 end as in_c
    from f
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

-- One page of Activity, newest first, plus the net total of every day that appears on the page (computed over the whole filter,
-- not just the loaded rows). Cursor = (occurred_at, id) of the last row of the previous page.
create or replace function public.tick_activity_page(p_from timestamptz, p_to timestamptz, p_types text[] default null, p_accounts uuid[] default null,
                                                     p_categories uuid[] default null, p_query text default null, p_business boolean default false,
                                                     p_review boolean default false, p_before_at timestamptz default null, p_before_id uuid default null,
                                                     p_limit int default 40)
returns jsonb language sql stable security invoker set search_path = public as $$
  with page as (
    select f.id, f.occurred_at from public.tick_filtered(p_from, p_to, p_types, p_accounts, p_categories, p_query, p_business, p_review) f
    where p_before_at is null or (f.occurred_at, f.id) < (p_before_at, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid))
    order by f.occurred_at desc, f.id desc
    limit least(greatest(coalesce(p_limit, 40), 1), 100)
  ), days as (
    select distinct (occurred_at at time zone 'America/New_York')::date as day from page
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(t) - 'user_id' order by t.occurred_at desc, t.id desc) from public.transactions t join page p on p.id = t.id), '[]'::jsonb),
    'day_totals', coalesce((select jsonb_object_agg(d.day::text, (public.tick_flows(
                      greatest(p_from, (d.day::timestamp at time zone 'America/New_York')),
                      least(p_to, ((d.day + 1)::timestamp at time zone 'America/New_York')),
                      p_types, p_accounts, p_categories, p_query, p_business, p_review) ->> 'net')::bigint) from days d), '{}'::jsonb)
  )
$$;

-- Month strip: one entry per ET month that has activity, newest first, each with in / out / net under the same rules.
create or replace function public.tick_months(p_types text[] default null, p_accounts uuid[] default null)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('month', m::text) || (public.tick_flows(
           (m::timestamp at time zone 'America/New_York'), ((m + interval '1 month')::timestamp at time zone 'America/New_York'), p_types, p_accounts)
           - 'by_category' - 'by_account' - 'daily_out') order by m desc), '[]'::jsonb)
  from (select distinct date_trunc('month', occurred_at at time zone 'America/New_York')::date m
        from public.tick_filtered(null, null, p_types, p_accounts, null, null, false, false)) x
$$;

revoke all on function public.tick_filtered(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean) from public, anon;
revoke all on function public.tick_flows(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean) from public, anon;
revoke all on function public.tick_activity_page(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean, timestamptz, uuid, int) from public, anon;
revoke all on function public.tick_months(text[], uuid[]) from public, anon;
grant execute on function public.tick_filtered(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean) to authenticated;
grant execute on function public.tick_flows(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean) to authenticated;
grant execute on function public.tick_activity_page(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean, timestamptz, uuid, int) to authenticated;
grant execute on function public.tick_months(text[], uuid[]) to authenticated;
