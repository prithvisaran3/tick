-- Person-aware categories. Rent to Kaarthik and a Splitwise settle-up to Kaarthik are the same Zelle line: what tells them apart is amount and day.
-- Rules run after transfer pairing and before the Friends and family default. A row a person categorised by hand never moves.

-- "Zelle payment to KAARTHIK ROSHAN 31446078428" -> "kaarthik roshan". Words with digits are reference codes.
create or replace function public.tick_p2p_person(p_text text) returns text
language sql immutable set search_path = public as $$
  select nullif(btrim(array_to_string(array(
    select w from regexp_split_to_table(lower(regexp_replace(coalesce(p_text, ''), '[®™.,;:#*()/\\-]', ' ', 'g')), '\s+') w
    where w <> '' and w !~ '[0-9]' and w not in ('zelle','payment','payments','to','from','venmo','cash','app','cashapp','paypal','transfer','sent','received','send','conf','ref','id','web','ach','credit','debit','for','pmt')
  ), ' ')), '')
$$;

create or replace function public.tick_is_p2p(p_text text) returns boolean
language sql immutable set search_path = public as $$ select coalesce(p_text, '') ~* '\y(zelle|venmo|cash ?app|paypal)' $$;

create table if not exists public.category_rules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  person_key text not null,                       -- tick_p2p_person of the name
  aliases text[] not null default '{}',           -- other spellings the bank has used for this person
  display_name text,
  amount_cents bigint check (amount_cents is null or amount_cents > 0),
  band_pct int not null default 10 check (band_pct between 0 and 100),
  day_of_month int check (day_of_month is null or day_of_month between 1 and 31),
  day_window int not null default 5 check (day_window between 0 and 15),
  keywords text[] not null default '{}',          -- optional memo words; any one is enough
  category_id uuid references public.categories(id) on delete cascade,
  priority int not null default 100,
  ignored boolean not null default false,         -- "Not recurring": never ask again, never apply
  source text not null default 'suggested' check (source in ('suggested','manual','seed')),
  created_at timestamptz not null default now(),
  check (ignored or category_id is not null)
);
create index if not exists category_rules_user_idx on public.category_rules (user_id);
alter table public.category_rules enable row level security;
alter table public.category_rules force row level security;
create policy category_rules_owner on public.category_rules for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.category_rules from anon;
alter table public.transactions add column if not exists category_rule_id uuid references public.category_rules(id) on delete set null;
create index if not exists transactions_rule_idx on public.transactions (category_rule_id) where category_rule_id is not null;

-- Does a rule fit this payment? The day compares round the month end: the 1st and the 30th are close.
create or replace function public.tick_rule_fits(r public.category_rules, p_person text, p_cents bigint, p_at timestamptz, p_text text) returns boolean
language sql stable set search_path = public as $$
  with d as (select extract(day from p_at at time zone 'America/New_York')::int dd,
                    extract(day from date_trunc('month', p_at at time zone 'America/New_York') + interval '1 month - 1 day')::int dim)
  select (p_person = r.person_key or p_person = any(r.aliases))
     and (r.amount_cents is null or abs(abs(p_cents) - r.amount_cents) * 100 <= r.amount_cents * r.band_pct)
     and (r.day_of_month is null or least(abs(dd - least(r.day_of_month, dim)), dim - abs(dd - least(r.day_of_month, dim))) <= r.day_window)
     and (cardinality(r.keywords) = 0 or exists (select 1 from unnest(r.keywords) k where position(lower(k) in lower(coalesce(p_text, ''))) > 0))
  from d
$$;

-- Runs after pairing, on every sync and whenever a rule changes. Idempotent; a hand-edited row is never touched, so manual edits survive any re-sync.
create or replace function public.tick_apply_category_rules(p_uid uuid) returns int
language plpgsql security invoker set search_path = public as $$
declare ff uuid; n int;
begin
  select id into ff from public.categories where user_id = p_uid and name = 'Friends and family';
  update public.transactions t set category_id = ff, category_rule_id = null
   where t.user_id = p_uid and t.category_rule_id is not null and not ('category' = any(t.user_edited)) and ff is not null;
  with hit as (
    select distinct on (t.id) t.id, r.category_id, r.id as rule_id
    from public.transactions t
    join public.category_rules r on r.user_id = t.user_id and not r.ignored
    where t.user_id = p_uid and t.amount_cents < 0 and t.flow is null and not ('category' = any(t.user_edited))
      and public.tick_is_p2p(coalesce(t.merchant_raw, t.merchant_clean))
      and public.tick_rule_fits(r, public.tick_p2p_person(coalesce(t.merchant_raw, t.merchant_clean)), t.amount_cents, t.occurred_at, coalesce(t.merchant_raw, '') || ' ' || coalesce(t.note, ''))
    order by t.id, r.priority desc, r.created_at
  )
  update public.transactions t set category_id = h.category_id, category_rule_id = h.rule_id from hit h where t.id = h.id;
  get diagnostics n = row_count;
  return n;
end $$;

-- Outgoing person-to-person rows with the person worked out, for recurrence detection and the rent seed.
create or replace function public.tick_p2p_rows(p_uid uuid, p_days int default 400) returns table (id uuid, person text, amount_cents bigint, day date, rule_id uuid, edited boolean)
language sql stable security invoker set search_path = public as $$
  select t.id, public.tick_p2p_person(coalesce(t.merchant_raw, t.merchant_clean)), -t.amount_cents, (t.occurred_at at time zone 'America/New_York')::date, t.category_rule_id, 'category' = any(t.user_edited)
  from public.transactions t
  where t.user_id = p_uid and t.amount_cents < 0 and t.flow is null and public.tick_is_p2p(coalesce(t.merchant_raw, t.merchant_clean)) and t.occurred_at >= now() - make_interval(days => p_days)
$$;

revoke all on function public.tick_p2p_person(text), public.tick_is_p2p(text), public.tick_rule_fits(public.category_rules, text, bigint, timestamptz, text), public.tick_apply_category_rules(uuid), public.tick_p2p_rows(uuid, int) from public, anon, authenticated;
grant execute on function public.tick_p2p_person(text), public.tick_is_p2p(text), public.tick_rule_fits(public.category_rules, text, bigint, timestamptz, text), public.tick_apply_category_rules(uuid), public.tick_p2p_rows(uuid, int) to service_role;
