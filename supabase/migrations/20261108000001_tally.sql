-- Tally: in-house group splits. Friends don't have Tick and sign-up is locked, so they are PEOPLE (a name and an optional phone/email),
-- never accounts. Everything is owner-only. Money is integer cents. "Me" is NULL in a person column (paid_by, share, settlement ends).
-- Tick never moves money: a settlement is a RECORD of money that moved somewhere else (Zelle, Venmo, cash).

-- The existing people table (name, email) gains a phone number and a colour for the avatar.
alter table public.people add column if not exists phone text;
alter table public.people add column if not exists color_key text not null default 'shop';
alter table public.people add column if not exists archived_at timestamptz;
create unique index if not exists people_id_user_idx on public.people (id, user_id);

create table if not exists public.tally_groups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  kind text not null default 'group' check (kind in ('group','direct')),     -- direct = a 1:1 tally with one friend
  name text not null check (char_length(name) between 1 and 60),
  emoji text check (emoji is null or char_length(emoji) <= 8),
  color_key text not null default 'shop',
  created_at timestamptz not null default now(),
  archived_at timestamptz
);
create unique index if not exists tally_groups_id_user_idx on public.tally_groups (id, user_id);

create table if not exists public.tally_members (
  group_id uuid not null,
  person_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  primary key (group_id, person_id),
  -- composite keys: a group can only contain MY people, never another user's row (the review's S1 class of bug)
  foreign key (group_id, user_id) references public.tally_groups (id, user_id) on delete cascade,
  foreign key (person_id, user_id) references public.people (id, user_id) on delete cascade
);

create table if not exists public.tally_expenses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  group_id uuid not null,
  description text not null check (char_length(description) between 1 and 120),
  amount_cents bigint not null check (amount_cents > 0 and amount_cents < 100000000000),
  paid_by uuid,                                              -- null = me
  split_type text not null default 'equal' check (split_type in ('equal','exact','percent','shares')),
  spent_on date not null default current_date,
  category text,
  note text check (note is null or char_length(note) <= 500),
  receipt_path text,
  transaction_id uuid references public.transactions(id) on delete set null,     -- "Split this" from Activity
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  foreign key (group_id, user_id) references public.tally_groups (id, user_id) on delete cascade,
  foreign key (paid_by, user_id) references public.people (id, user_id) on delete restrict
);
create unique index if not exists tally_expenses_id_user_idx on public.tally_expenses (id, user_id);
create index if not exists tally_expenses_group_idx on public.tally_expenses (group_id, spent_on desc);

create table if not exists public.tally_shares (
  expense_id uuid not null,
  person_id uuid,                                            -- null = me
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  owed_cents bigint not null check (owed_cents >= 0),
  weight numeric,                                            -- the percent / share count / exact amount the person typed (for editing)
  foreign key (expense_id, user_id) references public.tally_expenses (id, user_id) on delete cascade,
  foreign key (person_id, user_id) references public.people (id, user_id) on delete restrict
);
create unique index if not exists tally_shares_unique on public.tally_shares (expense_id, coalesce(person_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table if not exists public.tally_settlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  group_id uuid not null,
  from_person uuid,                                          -- who paid: null = me
  to_person uuid,                                            -- who received: null = me
  amount_cents bigint not null check (amount_cents > 0 and amount_cents < 100000000000),
  method text not null default 'zelle' check (method in ('zelle','venmo','cash','other')),
  settled_on date not null default current_date,
  note text check (note is null or char_length(note) <= 300),
  status text not null default 'confirmed' check (status in ('confirmed','pending','rejected')),   -- pending = "I paid" from the share page, awaiting me
  transaction_id uuid references public.transactions(id) on delete set null,     -- the Zelle row in Activity this settles
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  foreign key (group_id, user_id) references public.tally_groups (id, user_id) on delete cascade,
  foreign key (from_person, user_id) references public.people (id, user_id) on delete restrict,
  foreign key (to_person, user_id) references public.people (id, user_id) on delete restrict,
  check (from_person is distinct from to_person)
);
create index if not exists tally_settlements_group_idx on public.tally_settlements (group_id, settled_on desc);

-- Read-only share links for the public page. Only the SHA-256 of the token is stored; the token is shown once.
create table if not exists public.tally_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  group_id uuid not null,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_viewed_at timestamptz,
  views int not null default 0,
  foreign key (group_id, user_id) references public.tally_groups (id, user_id) on delete cascade
);
create index if not exists tally_links_group_idx on public.tally_links (group_id);

-- ---------- RLS: owner only, forced ----------
do $$
declare t text;
begin
  foreach t in array array['tally_groups','tally_members','tally_expenses','tally_shares','tally_settlements','tally_links'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;
create policy tally_groups_owner on public.tally_groups for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tally_members_owner on public.tally_members for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tally_expenses_owner on public.tally_expenses for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tally_shares_owner on public.tally_shares for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tally_settlements_owner on public.tally_settlements for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
-- Links: the app may LIST its links (no token hash is useful) but only the server creates, revokes or reads them for the public page.
create policy tally_links_read on public.tally_links for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete, truncate on public.tally_links from authenticated, anon;
revoke all on public.tally_groups, public.tally_members, public.tally_expenses, public.tally_shares, public.tally_settlements, public.tally_links from anon;

-- ---------- one RPC saves an expense and its shares atomically, validated ----------
-- p: {id?, group_id, description, amount_cents, paid_by, split_type, spent_on, category, note, receipt_path, transaction_id,
--     shares: [{person_id|null, owed_cents, weight?}]}.  Rules: shares must sum EXACTLY to the amount, the payer and every sharer must be
-- a member of the group (or me), and an edit may only touch my own expense. SECURITY INVOKER: RLS and the composite keys do the ownership.
create or replace function public.tally_save_expense(p jsonb) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  eid uuid := nullif(p->>'id', '')::uuid; gid uuid := (p->>'group_id')::uuid; amt bigint := (p->>'amount_cents')::bigint;
  s jsonb; total bigint := 0; pid uuid; n int := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.tally_groups g where g.id = gid and g.user_id = auth.uid()) then raise exception 'group not found'; end if;
  if jsonb_typeof(p->'shares') <> 'array' or jsonb_array_length(p->'shares') = 0 then raise exception 'at least one share is required'; end if;
  for s in select * from jsonb_array_elements(p->'shares') loop
    total := total + (s->>'owed_cents')::bigint; n := n + 1;
    pid := nullif(s->>'person_id', '')::uuid;
    if pid is not null and not exists (select 1 from public.tally_members m where m.group_id = gid and m.person_id = pid and m.user_id = auth.uid()) then
      raise exception 'a sharer is not in this group';
    end if;
  end loop;
  if total <> amt then raise exception 'shares add up to % but the expense is %', total, amt; end if;
  pid := nullif(p->>'paid_by', '')::uuid;
  if pid is not null and not exists (select 1 from public.tally_members m where m.group_id = gid and m.person_id = pid and m.user_id = auth.uid()) then
    raise exception 'the payer is not in this group';
  end if;
  if eid is null then
    insert into public.tally_expenses (group_id, description, amount_cents, paid_by, split_type, spent_on, category, note, receipt_path, transaction_id)
    values (gid, p->>'description', amt, pid, coalesce(p->>'split_type', 'equal'), coalesce((p->>'spent_on')::date, current_date), p->>'category', p->>'note', p->>'receipt_path',
            nullif(p->>'transaction_id', '')::uuid) returning id into eid;
  else
    update public.tally_expenses set description = p->>'description', amount_cents = amt, paid_by = pid, split_type = coalesce(p->>'split_type', 'equal'),
           spent_on = coalesce((p->>'spent_on')::date, spent_on), category = p->>'category', note = p->>'note', receipt_path = p->>'receipt_path', updated_at = now()
     where id = eid and group_id = gid and user_id = auth.uid();
    if not found then raise exception 'expense not found'; end if;
    delete from public.tally_shares where expense_id = eid and user_id = auth.uid();
  end if;
  for s in select * from jsonb_array_elements(p->'shares') loop
    insert into public.tally_shares (expense_id, person_id, owed_cents, weight) values (eid, nullif(s->>'person_id', '')::uuid, (s->>'owed_cents')::bigint, nullif(s->>'weight', '')::numeric);
  end loop;
  return eid;
end $$;
revoke all on function public.tally_save_expense(jsonb) from public, anon;
grant execute on function public.tally_save_expense(jsonb) to authenticated, service_role;

-- Net balance per person (positive = the group owes THEM, negative = THEY owe the group; me is person_id null), from live rows only.
-- This is the single definition; the app, the public page and "you're owed" on Today all read it.
create or replace function public.tally_balances(p_uid uuid, p_group uuid default null)
returns table (group_id uuid, person_id uuid, net_cents bigint)
language sql stable security invoker set search_path = public as $$
  with legs as (
    -- the payer is owed the whole amount; every sharer owes their share (me is null)
    select e.group_id, e.paid_by as person_id, e.amount_cents as c from public.tally_expenses e where e.user_id = p_uid and e.deleted_at is null and (p_group is null or e.group_id = p_group)
    union all
    select e.group_id, s.person_id, -s.owed_cents from public.tally_shares s join public.tally_expenses e on e.id = s.expense_id and e.user_id = s.user_id
     where s.user_id = p_uid and e.deleted_at is null and (p_group is null or e.group_id = p_group)
    union all
    -- a settlement: the payer's balance goes up (they paid out), the receiver's goes down; only confirmed ones count
    select st.group_id, st.from_person, st.amount_cents from public.tally_settlements st where st.user_id = p_uid and st.deleted_at is null and st.status = 'confirmed' and (p_group is null or st.group_id = p_group)
    union all
    select st.group_id, st.to_person, -st.amount_cents from public.tally_settlements st where st.user_id = p_uid and st.deleted_at is null and st.status = 'confirmed' and (p_group is null or st.group_id = p_group)
  )
  select l.group_id, l.person_id, sum(l.c)::bigint from legs l group by l.group_id, l.person_id having sum(l.c) <> 0
$$;
revoke all on function public.tally_balances(uuid, uuid) from public, anon;
grant execute on function public.tally_balances(uuid, uuid) to authenticated, service_role;

-- What the friends owe ME in total (for Today: "You're owed $X"): my balance is the negative of everyone else's, per group.
create or replace function public.tally_owed_to_me()
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object('owed_to_me', coalesce(sum(case when me > 0 then me else 0 end), 0), 'i_owe', coalesce(sum(case when me < 0 then -me else 0 end), 0))
  from (select g.group_id, coalesce(sum(g.net_cents) filter (where g.person_id is null), 0) as me from public.tally_balances(auth.uid()) g group by g.group_id) x
$$;
revoke all on function public.tally_owed_to_me() from public, anon;
grant execute on function public.tally_owed_to_me() to authenticated;

-- Edits and deletes of Tally records are audit-logged by the database itself (who, what, when; no names or amounts).
create or replace function public.tally_audit() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (user_id, event, detail)
    values (coalesce(old.user_id, new.user_id), case when tg_op = 'DELETE' then 'tally_deleted' else 'tally_edit' end, jsonb_build_object('scope', tg_table_name, 'reason', lower(tg_op)));
  return coalesce(new, old);
end $$;
revoke all on function public.tally_audit() from public, anon, authenticated;
drop trigger if exists tally_expenses_audit on public.tally_expenses;
create trigger tally_expenses_audit after update or delete on public.tally_expenses for each row execute function public.tally_audit();
drop trigger if exists tally_settlements_audit on public.tally_settlements;
create trigger tally_settlements_audit after update or delete on public.tally_settlements for each row execute function public.tally_audit();
drop trigger if exists tally_groups_audit on public.tally_groups;
create trigger tally_groups_audit after update or delete on public.tally_groups for each row execute function public.tally_audit();

-- standing lockdown again for everything new
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
