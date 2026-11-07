-- Tally v2, phase 1: money with friends stops distorting the totals.
--   1. Friends and family rows are shown as ONE net line. By default they are excluded from spending and income (settings.include_friends).
--   2. A person-to-person credit can be accepted as a payback for a purchase: the credit stops being income and the purchase counts net of it.
-- Both rules live in tick_classified, the one place money rules exist (docs/MONEY_RULES.md).

alter table public.settings add column if not exists include_friends boolean not null default false;

alter table public.transactions add column if not exists reimbursed_cents bigint not null default 0 check (reimbursed_cents >= 0);   -- written only by the trigger below
alter table public.transactions drop constraint if exists transactions_flow_check;
alter table public.transactions add constraint transactions_flow_check check (flow is null or flow in ('transfer','bill','settlement','reimbursement'));

-- A payback is one whole credit against one purchase; a purchase can have several. Links are only ever made by the person accepting a suggestion,
-- or by the server when a Tally settlement already matches exactly (source = 'settlement').
create table if not exists public.txn_paybacks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  purchase_id uuid not null,
  payback_id uuid not null,
  amount_cents bigint not null check (amount_cents > 0),
  source text not null default 'user' check (source in ('user','settlement')),
  created_at timestamptz not null default now(),
  unique (payback_id),
  foreign key (purchase_id, user_id) references public.transactions (id, user_id) on delete cascade,
  foreign key (payback_id, user_id) references public.transactions (id, user_id) on delete cascade
);
create index if not exists txn_paybacks_purchase_idx on public.txn_paybacks (purchase_id);

-- "Not a payback": this credit is never suggested again.
create table if not exists public.txn_payback_dismissals (
  user_id uuid not null references auth.users(id) on delete cascade,
  payback_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, payback_id),
  foreign key (payback_id, user_id) references public.transactions (id, user_id) on delete cascade
);

alter table public.txn_paybacks enable row level security;
alter table public.txn_paybacks force row level security;
alter table public.txn_payback_dismissals enable row level security;
alter table public.txn_payback_dismissals force row level security;
create policy txn_paybacks_read on public.txn_paybacks for select to authenticated using (user_id = auth.uid());
create policy txn_payback_dismissals_read on public.txn_payback_dismissals for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete, truncate on public.txn_paybacks, public.txn_payback_dismissals from authenticated, anon;
revoke all on public.txn_paybacks, public.txn_payback_dismissals from anon;

-- Keeps the two denormalised facts true: the purchase's reimbursed_cents, and the credit's flow. Unlinking puts the credit back to ordinary.
create or replace function public.txn_payback_sync() returns trigger language plpgsql security definer set search_path = public as $$
declare r public.txn_paybacks := coalesce(new, old);
begin
  update public.transactions t set reimbursed_cents = coalesce((select sum(p.amount_cents) from public.txn_paybacks p where p.purchase_id = r.purchase_id), 0)
   where t.id = r.purchase_id and t.user_id = r.user_id;
  if tg_op = 'INSERT' then
    update public.transactions t set flow = 'reimbursement', user_edited = case when 'flow' = any(t.user_edited) then t.user_edited else array_append(t.user_edited, 'flow') end
     where t.id = r.payback_id and t.user_id = r.user_id and t.flow is null;
  else
    update public.transactions t set flow = null, user_edited = array_remove(t.user_edited, 'flow')
     where t.id = r.payback_id and t.user_id = r.user_id and t.flow = 'reimbursement';
  end if;
  return null;
end $$;
drop trigger if exists txn_payback_sync_t on public.txn_paybacks;
create trigger txn_payback_sync_t after insert or delete on public.txn_paybacks for each row execute function public.txn_payback_sync();

-- Accepting a suggestion. Row locks make two paybacks arriving together unable to overshoot the purchase. Server only (the API checks who is asking).
create or replace function public.tick_payback_link(p_uid uuid, p_purchase uuid, p_payback uuid, p_source text default 'user') returns jsonb
language plpgsql security invoker set search_path = public as $$
declare pur public.transactions; pb public.transactions;
begin
  select * into pur from public.transactions where id = p_purchase and user_id = p_uid for update;
  select * into pb from public.transactions where id = p_payback and user_id = p_uid for update;
  if pur.id is null or pb.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if pur.amount_cents >= 0 or pur.flow in ('transfer','settlement','reimbursement') then raise exception 'not a purchase' using errcode = '22023'; end if;
  if pb.amount_cents <= 0 or pb.flow in ('transfer','bill') then raise exception 'not a payback' using errcode = '22023'; end if;
  if exists (select 1 from public.txn_paybacks x where x.payback_id = p_payback) then raise exception 'already linked' using errcode = '23505'; end if;
  if pb.amount_cents > -pur.amount_cents - pur.reimbursed_cents then raise exception 'more than the purchase' using errcode = '22023'; end if;
  insert into public.txn_paybacks (user_id, purchase_id, payback_id, amount_cents, source) values (p_uid, p_purchase, p_payback, pb.amount_cents, coalesce(p_source, 'user'));
  delete from public.txn_payback_dismissals d where d.user_id = p_uid and d.payback_id = p_payback;
  return jsonb_build_object('purchase_id', p_purchase, 'reimbursed_cents', pur.reimbursed_cents + pb.amount_cents, 'net_cents', -pur.amount_cents - pur.reimbursed_cents - pb.amount_cents);
end $$;

-- Splitwise history import: a group export becomes a Tally group; refs make re-importing a no-op, the batch makes it undoable. Server only.
alter table public.tally_groups add column if not exists import_key text;
alter table public.tally_expenses add column if not exists external_ref text;
alter table public.tally_expenses add column if not exists import_batch_id uuid references public.import_batches(id) on delete set null;
alter table public.tally_settlements add column if not exists external_ref text;
alter table public.tally_settlements add column if not exists import_batch_id uuid references public.import_batches(id) on delete set null;
create unique index if not exists tally_groups_import_key_idx on public.tally_groups (user_id, import_key) where import_key is not null;
create unique index if not exists tally_expenses_ref_idx on public.tally_expenses (user_id, external_ref) where external_ref is not null;
create unique index if not exists tally_settlements_ref_idx on public.tally_settlements (user_id, external_ref) where external_ref is not null;

create or replace function public.tally_import_splitwise(p_uid uuid, p_batch uuid, p jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare gid uuid; n text; pid uuid; ids jsonb := '{}'; e jsonb; s jsonb; eid uuid; added_e int := 0; added_s int := 0;
begin
  select id into gid from public.tally_groups where user_id = p_uid and import_key = p->'group'->>'import_key';
  if gid is null then
    insert into public.tally_groups (user_id, name, import_key) values (p_uid, p->'group'->>'name', p->'group'->>'import_key') returning id into gid;
  end if;
  for n in select jsonb_array_elements_text(p->'people') loop
    select id into pid from public.people where user_id = p_uid and lower(name) = lower(n) limit 1;
    if pid is null then insert into public.people (user_id, name) values (p_uid, n) returning id into pid; end if;
    insert into public.tally_members (group_id, person_id, user_id) values (gid, pid, p_uid) on conflict do nothing;
    ids := ids || jsonb_build_object(n, pid);
  end loop;
  for e in select * from jsonb_array_elements(p->'expenses') loop
    insert into public.tally_expenses (user_id, group_id, description, amount_cents, paid_by, split_type, spent_on, category, external_ref, import_batch_id)
    values (p_uid, gid, e->>'description', (e->>'amount_cents')::bigint, (ids->>(e->>'paid_by'))::uuid, 'exact', (e->>'spent_on')::date, e->>'category', e->>'ref', p_batch)
    on conflict do nothing returning id into eid;
    if eid is not null then
      added_e := added_e + 1;
      for s in select * from jsonb_array_elements(e->'shares') loop
        insert into public.tally_shares (user_id, expense_id, person_id, owed_cents) values (p_uid, eid, (ids->>(s->>'person'))::uuid, (s->>'owed_cents')::bigint);
      end loop;
    end if;
    eid := null;
  end loop;
  for s in select * from jsonb_array_elements(p->'settlements') loop
    insert into public.tally_settlements (user_id, group_id, from_person, to_person, amount_cents, method, settled_on, external_ref, import_batch_id)
    values (p_uid, gid, (ids->>(s->>'from'))::uuid, (ids->>(s->>'to'))::uuid, (s->>'amount_cents')::bigint, 'other', (s->>'on')::date, s->>'ref', p_batch)
    on conflict do nothing;
    if found then added_s := added_s + 1; end if;
  end loop;
  return jsonb_build_object('group_id', gid, 'expenses', added_e, 'settlements', added_s);
end $$;

-- Zelle to a person called Rent is rent, not a friend: without this it would vanish from spending under the new rule.
update public.transactions t set category_id = r.id
  from public.categories f, public.categories r
 where f.id = t.category_id and f.name = 'Friends and family' and r.user_id = t.user_id and r.name = 'Rent' and t.amount_cents < 0
   and coalesce(t.merchant_clean, t.merchant_raw, '') ~* '\yrent\y' and not ('category' = any(t.user_edited));

-- A P2P "bill" detected before this rule would keep shrinking Safe to spend after the rows stopped counting.
update public.recurring r set status = 'ended'
 where r.status = 'active' and not r.is_manual and r.merchant ~* '\y(zelle|venmo|cash ?app|paypal)\y' and r.merchant !~* '\yrent\y';

-- ---------- the money rules ----------
-- Adds to the rules in 20261107000001: friends = a Friends and family row with no flow.
--   excluded also covers flow 'reimbursement' and, unless settings.include_friends is on, friends rows.
--   out_c of a purchase is net of its paybacks (reimbursed_cents).
--   friends_c is the signed amount of a friends row whether or not it counts: the Insights net line, Ask Tick.
drop function if exists public.tick_filtered(timestamptz, timestamptz, text[], uuid[], uuid[], text, boolean, boolean);
drop function if exists public.tick_classified(uuid, timestamptz, timestamptz);
create function public.tick_classified(p_uid uuid, p_from timestamptz, p_to timestamptz)
returns table (id uuid, occurred_at timestamptz, amount_cents bigint, category_id uuid, account_id uuid, flow text, tags text[], needs_review boolean,
               merchant text, search text, note text, cat_kind text, cat_name text, acct_type text, excluded boolean, out_c bigint, in_c bigint, friends_c bigint)
language sql stable security invoker set search_path = public as $$
  with cfg as (select coalesce((select s.include_friends from public.settings s where s.user_id = p_uid), false) as include_friends),
  r as (
    select t.*, c.kind as cat_kind, c.name as cat_name, a.type as acct_type,
           (t.flow is null and c.name = 'Friends and family') as friends,
           (t.flow in ('transfer','settlement','reimbursement')) is true or (t.flow is null and c.name = 'Friends and family' and not cfg.include_friends) as excluded
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
              when r.amount_cents < 0 then -r.amount_cents - r.reimbursed_cents
              when r.amount_cents > 0 and r.cat_kind is distinct from 'income' and r.acct_type in ('credit','loan') then -r.amount_cents
              else 0::bigint end as out_c,
         case when r.excluded then 0::bigint
              when r.amount_cents > 0 and (r.cat_kind = 'income' or coalesce(r.acct_type, 'checking') not in ('credit','loan')) then r.amount_cents
              else 0::bigint end as in_c,
         case when r.friends then r.amount_cents else 0::bigint end as friends_c
  from r
$$;

create function public.tick_filtered(p_from timestamptz, p_to timestamptz, p_types text[], p_accounts uuid[], p_categories uuid[],
                                     p_query text, p_business boolean, p_review boolean)
returns table (id uuid, occurred_at timestamptz, amount_cents bigint, category_id uuid, account_id uuid, flow text, tags text[],
               needs_review boolean, cat_kind text, acct_type text, excluded boolean, out_c bigint, in_c bigint, friends_c bigint)
language sql stable security invoker set search_path = public, extensions as $$
  select k.id, k.occurred_at, k.amount_cents, k.category_id, k.account_id, k.flow, k.tags, k.needs_review, k.cat_kind, k.acct_type, k.excluded, k.out_c, k.in_c, k.friends_c
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
    'friends_in', coalesce(sum(friends_c) filter (where friends_c > 0), 0),
    'friends_out', coalesce(-sum(friends_c) filter (where friends_c < 0), 0),
    'friends_net', coalesce(sum(friends_c), 0),
    'friends_count', count(*) filter (where friends_c <> 0),
    'friends_included', coalesce((select s.include_friends from public.settings s where s.user_id = auth.uid()), false),
    'by_category', coalesce((select jsonb_object_agg(coalesce(category_id::text, 'none'), s) from
                     (select category_id, sum(out_c) s from m where out_c <> 0 group by category_id) x), '{}'::jsonb),
    'by_account', coalesce((select jsonb_object_agg(coalesce(account_id::text, 'none'), s) from
                     (select account_id, sum(out_c) s from m where out_c <> 0 group by account_id) x), '{}'::jsonb),
    'daily_out', coalesce((select jsonb_object_agg(day::text, s) from (select day, sum(out_c) s from m group by day having sum(out_c) <> 0) x), '{}'::jsonb)
  ) from m
$$;

-- standing lockdown again for everything new (tick_payback_link stays server only)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname in ('tick_flows','tick_activity_page','tick_months','tick_filtered','tick_links_used','tick_account_counts','tick_top_merchants','tick_classified',
                     'tally_save_expense','tally_balances','tally_owed_to_me') then
      execute format('grant execute on function %s to authenticated', f.sig);
    else
      execute format('revoke execute on function %s from authenticated', f.sig);
    end if;
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
