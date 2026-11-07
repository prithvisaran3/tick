-- Tally v2, phase 2: Tally stops being owner-only. A group has MEMBERS: a Tick user (member_user_id) or a guest (a name, with phone and email kept
-- in the adder's private `people` book). Balances, expenses and settlements point at members, so "me" is no longer a null: it depends on who is reading.
-- `user_id` on every Tally table stays the GROUP OWNER (the tenant): composite keys and account deletion keep working. `created_by` is who wrote the row.
-- The old person columns are renamed legacy_*, kept for one release, and never written again.

-- This whole design relies on SECURITY DEFINER helpers reading past RLS (otherwise is_tally_member recurses through its own policy). Fail loudly, not subtly.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = current_user and (rolsuper or rolbypassrls)) then
    raise exception 'tally_shared needs a migration role with BYPASSRLS, % has none', current_user;
  end if;
end $$;

-- ---------- finding people ----------
alter table public.profiles add column if not exists handle text;
alter table public.profiles add column if not exists phone text;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles add column if not exists discoverable boolean not null default true;
alter table public.profiles add constraint profiles_handle_format check (handle is null or handle ~ '^[a-z0-9_]{3,20}$');
alter table public.profiles add constraint profiles_phone_format check (phone is null or phone ~ '^\+?[0-9]{7,15}$');
create unique index if not exists profiles_handle_idx on public.profiles (handle) where handle is not null;
create index if not exists profiles_handle_prefix_idx on public.profiles (handle text_pattern_ops) where handle is not null;
create index if not exists profiles_phone_idx on public.profiles (phone) where phone is not null;

-- ---------- groups and members ----------
alter table public.tally_groups add column if not exists deleted_at timestamptz;

alter table public.tally_members add column if not exists id uuid not null default gen_random_uuid();
alter table public.tally_members drop constraint tally_members_pkey;
alter table public.tally_members add primary key (id);
alter table public.tally_members alter column person_id drop not null;
alter table public.tally_members drop constraint tally_members_person_id_user_id_fkey;
alter table public.tally_members add constraint tally_members_person_fkey foreign key (person_id) references public.people (id) on delete set null;
alter table public.tally_members add column if not exists member_user_id uuid references auth.users(id) on delete set null;
alter table public.tally_members add column if not exists name text;
alter table public.tally_members add column if not exists color_key text not null default 'shop';
alter table public.tally_members add column if not exists role text not null default 'member' check (role in ('owner','member'));
alter table public.tally_members add column if not exists status text not null default 'active' check (status in ('active','left','removed'));
alter table public.tally_members add column if not exists created_at timestamptz not null default now();
alter table public.tally_members add column if not exists left_at timestamptz;
create unique index if not exists tally_members_id_group_idx on public.tally_members (id, group_id);
create unique index if not exists tally_members_person_idx on public.tally_members (group_id, person_id) where person_id is not null;
create unique index if not exists tally_members_user_idx on public.tally_members (group_id, member_user_id) where member_user_id is not null;
create index if not exists tally_members_mine_idx on public.tally_members (member_user_id) where member_user_id is not null;

-- Every existing person in a group becomes a guest; every owner becomes the owner member.
update public.tally_members m set name = p.name, color_key = p.color_key from public.people p where p.id = m.person_id;
insert into public.tally_members (group_id, user_id, member_user_id, name, role)
  select g.id, g.user_id, g.user_id, coalesce(nullif(pr.display_name, ''), 'Me'), 'owner'
  from public.tally_groups g left join public.profiles pr on pr.user_id = g.user_id;
-- A person who took part but was since dropped from the group still has history: they stay as a past member.
insert into public.tally_members (group_id, user_id, person_id, name, color_key, status)
  select distinct x.group_id, x.user_id, p.id, p.name, p.color_key, 'left'
  from (select group_id, user_id, paid_by as person_id from public.tally_expenses
        union select e.group_id, e.user_id, s.person_id from public.tally_shares s join public.tally_expenses e on e.id = s.expense_id
        union select group_id, user_id, from_person from public.tally_settlements
        union select group_id, user_id, to_person from public.tally_settlements) x
  join public.people p on p.id = x.person_id
  where not exists (select 1 from public.tally_members m where m.group_id = x.group_id and m.person_id = x.person_id);
alter table public.tally_members alter column name set not null;
alter table public.tally_members add constraint tally_members_name_len check (char_length(name) between 1 and 80);
alter table public.tally_members add constraint tally_members_who check (member_user_id is not null or role = 'member');

-- ---------- expenses, shares, settlements point at members ----------
alter table public.tally_expenses drop constraint tally_expenses_paid_by_user_id_fkey;
alter table public.tally_expenses drop constraint tally_expenses_transaction_id_user_id_fkey;
alter table public.tally_expenses rename column paid_by to legacy_paid_by;
alter table public.tally_expenses add column paid_by_member uuid;
alter table public.tally_expenses add column created_by uuid references auth.users(id) on delete set null;
update public.tally_expenses e set created_by = e.user_id,
  paid_by_member = (select m.id from public.tally_members m where m.group_id = e.group_id and (case when e.legacy_paid_by is null then m.role = 'owner' else m.person_id = e.legacy_paid_by end));
alter table public.tally_expenses alter column paid_by_member set not null;
alter table public.tally_expenses alter column user_id drop default;
alter table public.tally_expenses add constraint tally_expenses_paid_by_fkey foreign key (paid_by_member, group_id) references public.tally_members (id, group_id) on delete restrict;
alter table public.tally_expenses add constraint tally_expenses_txn_fkey foreign key (transaction_id) references public.transactions (id) on delete set null;

drop index if exists public.tally_shares_unique;
alter table public.tally_shares drop constraint tally_shares_person_id_user_id_fkey;
alter table public.tally_shares rename column person_id to legacy_person_id;
alter table public.tally_shares add column member_id uuid references public.tally_members (id) on delete restrict;
update public.tally_shares s set member_id = (select m.id from public.tally_members m join public.tally_expenses e on e.id = s.expense_id
                                              where m.group_id = e.group_id and (case when s.legacy_person_id is null then m.role = 'owner' else m.person_id = s.legacy_person_id end));
alter table public.tally_shares alter column member_id set not null;
alter table public.tally_shares alter column user_id drop default;
create unique index tally_shares_unique on public.tally_shares (expense_id, member_id);

alter table public.tally_settlements drop constraint tally_settlements_from_person_user_id_fkey;
alter table public.tally_settlements drop constraint tally_settlements_to_person_user_id_fkey;
alter table public.tally_settlements drop constraint tally_settlements_transaction_id_user_id_fkey;
alter table public.tally_settlements drop constraint tally_settlements_check;
alter table public.tally_settlements drop constraint tally_settlements_method_check;
alter table public.tally_settlements add constraint tally_settlements_method_check check (method in ('zelle','venmo','cashapp','cash','other'));
alter table public.tally_settlements rename column from_person to legacy_from_person;
alter table public.tally_settlements rename column to_person to legacy_to_person;
alter table public.tally_settlements add column from_member uuid;
alter table public.tally_settlements add column to_member uuid;
alter table public.tally_settlements add column created_by uuid references auth.users(id) on delete set null;
update public.tally_settlements s set created_by = s.user_id,
  from_member = (select m.id from public.tally_members m where m.group_id = s.group_id and (case when s.legacy_from_person is null then m.role = 'owner' else m.person_id = s.legacy_from_person end)),
  to_member = (select m.id from public.tally_members m where m.group_id = s.group_id and (case when s.legacy_to_person is null then m.role = 'owner' else m.person_id = s.legacy_to_person end));
alter table public.tally_settlements alter column from_member set not null;
alter table public.tally_settlements alter column to_member set not null;
alter table public.tally_settlements alter column user_id drop default;
alter table public.tally_settlements add constraint tally_settlements_from_fkey foreign key (from_member, group_id) references public.tally_members (id, group_id) on delete restrict;
alter table public.tally_settlements add constraint tally_settlements_to_fkey foreign key (to_member, group_id) references public.tally_members (id, group_id) on delete restrict;
alter table public.tally_settlements add constraint tally_settlements_txn_fkey foreign key (transaction_id) references public.transactions (id) on delete set null;
alter table public.tally_settlements add constraint tally_settlements_two_people check (from_member <> to_member);

-- ---------- the membership helpers ----------
create or replace function public.is_tally_member(p_group uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from public.tally_members m where m.group_id = p_group and m.member_user_id = auth.uid() and m.status = 'active')
$$;
create or replace function public.is_tally_owner(p_group uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from public.tally_groups g where g.id = p_group and g.user_id = auth.uid())
$$;
create or replace function public.tally_my_member(p_group uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select m.id from public.tally_members m where m.group_id = p_group and m.member_user_id = auth.uid() and m.status = 'active'
$$;

-- ---------- RLS by membership ----------
drop policy tally_groups_owner on public.tally_groups;
drop policy tally_members_owner on public.tally_members;
drop policy tally_expenses_owner on public.tally_expenses;
drop policy tally_shares_owner on public.tally_shares;
drop policy tally_settlements_owner on public.tally_settlements;
drop policy tally_links_read on public.tally_links;

create policy tally_groups_read on public.tally_groups for select to authenticated using (public.is_tally_member(id) and (deleted_at is null or user_id = auth.uid()));
create policy tally_groups_add on public.tally_groups for insert to authenticated with check (user_id = auth.uid());
create policy tally_groups_owner_edit on public.tally_groups for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tally_members_read on public.tally_members for select to authenticated using (public.is_tally_member(group_id));
create policy tally_expenses_read on public.tally_expenses for select to authenticated using (public.is_tally_member(group_id));
create policy tally_expenses_add on public.tally_expenses for insert to authenticated with check (public.is_tally_member(group_id) and created_by = auth.uid());
create policy tally_expenses_edit on public.tally_expenses for update to authenticated
  using (public.is_tally_member(group_id) and (created_by = auth.uid() or public.is_tally_owner(group_id)))
  with check (public.is_tally_member(group_id));
create policy tally_shares_read on public.tally_shares for select to authenticated using (exists (select 1 from public.tally_expenses e where e.id = expense_id));
create policy tally_settlements_read on public.tally_settlements for select to authenticated using (public.is_tally_member(group_id));
create policy tally_settlements_add on public.tally_settlements for insert to authenticated with check (public.is_tally_member(group_id) and created_by = auth.uid());
create policy tally_settlements_edit on public.tally_settlements for update to authenticated
  using (public.is_tally_member(group_id) and (created_by = auth.uid() or public.is_tally_owner(group_id)))
  with check (public.is_tally_member(group_id));
create policy tally_links_read on public.tally_links for select to authenticated using (public.is_tally_member(group_id));

-- The app writes through the RPCs below. Direct writes are narrow on purpose: a row can be added, soft deleted and restored, never hard deleted,
-- and an amount can't be changed without its shares.
revoke all on public.tally_groups, public.tally_members, public.tally_expenses, public.tally_shares, public.tally_settlements from authenticated;
grant select on public.tally_groups, public.tally_members, public.tally_expenses, public.tally_shares, public.tally_settlements to authenticated;
grant insert (name, emoji, color_key, kind, user_id) on public.tally_groups to authenticated;
grant update (name, emoji, color_key, archived_at, deleted_at) on public.tally_groups to authenticated;
grant insert on public.tally_expenses, public.tally_settlements to authenticated;
grant update (deleted_at) on public.tally_expenses to authenticated;
grant update (deleted_at, status) on public.tally_settlements to authenticated;

-- Writes fill in who and whose, and the keys can't be moved. A bank row may only be linked by the person whose bank row it is.
create or replace function public.tally_row_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if tg_op = 'INSERT' then
    select g.user_id into new.user_id from public.tally_groups g where g.id = new.group_id;
    new.created_by := coalesce(new.created_by, uid);
  elsif new.group_id is distinct from old.group_id or new.user_id is distinct from old.user_id or new.created_by is distinct from old.created_by then
    raise exception 'that can''t be moved';
  end if;
  if uid is not null and new.transaction_id is not null and (tg_op = 'INSERT' or new.transaction_id is distinct from old.transaction_id)
     and not exists (select 1 from public.transactions t where t.id = new.transaction_id and t.user_id = uid) then
    raise exception 'that transaction isn''t yours' using errcode = '23503';
  end if;
  return new;
end $$;
drop trigger if exists tally_expenses_guard on public.tally_expenses;
create trigger tally_expenses_guard before insert or update on public.tally_expenses for each row execute function public.tally_row_guard();
drop trigger if exists tally_settlements_guard on public.tally_settlements;
create trigger tally_settlements_guard before insert or update on public.tally_settlements for each row execute function public.tally_row_guard();

-- A group always has its owner as a member.
create or replace function public.tally_group_owner_member() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.tally_members (group_id, user_id, member_user_id, name, role)
    select new.id, new.user_id, new.user_id, coalesce((select nullif(p.display_name, '') from public.profiles p where p.user_id = new.user_id), 'Me'), 'owner';
  return null;
end $$;
drop trigger if exists tally_group_owner_member_t on public.tally_groups;
create trigger tally_group_owner_member_t after insert on public.tally_groups for each row execute function public.tally_group_owner_member();

-- ---------- activity: who did what, old and new amount ----------
create table if not exists public.tally_activity (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.tally_groups(id) on delete cascade,
  actor uuid references auth.users(id) on delete set null,
  actor_name text,
  action text not null,                      -- expense_added, expense_edited, expense_deleted, expense_restored, settlement_*, member_*, group_*
  entity_id uuid,
  label text,                                -- the expense's description, the member's name, the group's name
  old_cents bigint,
  new_cents bigint,
  created_at timestamptz not null default now()
);
create index if not exists tally_activity_group_idx on public.tally_activity (group_id, created_at desc);
alter table public.tally_activity enable row level security;
alter table public.tally_activity force row level security;
create policy tally_activity_read on public.tally_activity for select to authenticated using (public.is_tally_member(group_id));
revoke all on public.tally_activity from anon, authenticated;
grant select on public.tally_activity to authenticated;

create or replace function public.tally_log(p_group uuid, p_action text, p_entity uuid, p_label text, p_old bigint default null, p_new bigint default null) returns void
language sql security definer set search_path = public as $$
  insert into public.tally_activity (group_id, actor, actor_name, action, entity_id, label, old_cents, new_cents)
  values (p_group, auth.uid(), (select m.name from public.tally_members m where m.group_id = p_group and m.member_user_id = auth.uid()), p_action, p_entity, p_label, p_old, p_new)
$$;

create or replace function public.tally_expense_log() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.import_batch_id is not null and tg_op = 'INSERT' then return null; end if;          -- an import logs once, not per row
  if tg_op = 'INSERT' then perform public.tally_log(new.group_id, 'expense_added', new.id, new.description, null, new.amount_cents);
  elsif old.deleted_at is null and new.deleted_at is not null then perform public.tally_log(new.group_id, 'expense_deleted', new.id, new.description, new.amount_cents, null);
  elsif old.deleted_at is not null and new.deleted_at is null then perform public.tally_log(new.group_id, 'expense_restored', new.id, new.description, null, new.amount_cents);
  elsif new.updated_at is distinct from old.updated_at then perform public.tally_log(new.group_id, 'expense_edited', new.id, new.description, old.amount_cents, new.amount_cents);
  end if;
  return null;
end $$;
drop trigger if exists tally_expense_log_t on public.tally_expenses;
create trigger tally_expense_log_t after insert or update on public.tally_expenses for each row execute function public.tally_expense_log();

create or replace function public.tally_settlement_log() returns trigger language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if new.import_batch_id is not null and tg_op = 'INSERT' then return null; end if;
  select f.name || ' → ' || t.name into who from public.tally_members f, public.tally_members t where f.id = new.from_member and t.id = new.to_member;
  if tg_op = 'INSERT' then perform public.tally_log(new.group_id, 'settlement_added', new.id, who, null, new.amount_cents);
  elsif old.deleted_at is null and new.deleted_at is not null then perform public.tally_log(new.group_id, 'settlement_deleted', new.id, who, new.amount_cents, null);
  elsif old.deleted_at is not null and new.deleted_at is null then perform public.tally_log(new.group_id, 'settlement_restored', new.id, who, null, new.amount_cents);
  elsif new.status is distinct from old.status then perform public.tally_log(new.group_id, 'settlement_' || new.status, new.id, who, null, new.amount_cents);
  elsif new.amount_cents is distinct from old.amount_cents then perform public.tally_log(new.group_id, 'settlement_edited', new.id, who, old.amount_cents, new.amount_cents);
  end if;
  return null;
end $$;
drop trigger if exists tally_settlement_log_t on public.tally_settlements;
create trigger tally_settlement_log_t after insert or update on public.tally_settlements for each row execute function public.tally_settlement_log();

create or replace function public.tally_group_log() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then perform public.tally_log(new.id, 'group_created', new.id, new.name);
  elsif old.deleted_at is null and new.deleted_at is not null then perform public.tally_log(new.id, 'group_deleted', new.id, new.name);
  elsif old.deleted_at is not null and new.deleted_at is null then perform public.tally_log(new.id, 'group_restored', new.id, new.name);
  elsif old.archived_at is null and new.archived_at is not null then perform public.tally_log(new.id, 'group_archived', new.id, new.name);
  elsif old.archived_at is not null and new.archived_at is null then perform public.tally_log(new.id, 'group_unarchived', new.id, new.name);
  elsif new.name is distinct from old.name then perform public.tally_log(new.id, 'group_renamed', new.id, new.name);
  end if;
  return null;
end $$;
drop trigger if exists tally_group_log_t on public.tally_groups;
create trigger tally_group_log_t after insert or update on public.tally_groups for each row execute function public.tally_group_log();

create or replace function public.tally_member_log() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.role <> 'owner' and new.status = 'active' then perform public.tally_log(new.group_id, 'member_added', new.id, new.name); end if;
  elsif new.status <> old.status then perform public.tally_log(new.group_id, case new.status when 'left' then 'member_left' when 'removed' then 'member_removed' else 'member_added' end, new.id, new.name);
  elsif old.member_user_id is null and new.member_user_id is not null then perform public.tally_log(new.group_id, 'member_joined', new.id, new.name);
  end if;
  return null;
end $$;
drop trigger if exists tally_member_log_t on public.tally_members;
create trigger tally_member_log_t after insert or update on public.tally_members for each row execute function public.tally_member_log();

-- ---------- balances ----------
drop function if exists public.tally_balances(uuid, uuid);
create function public.tally_net(p_group uuid) returns table (member_id uuid, net_cents bigint)
language sql stable security definer set search_path = public as $$
  with legs as (
    select e.paid_by_member as member_id, e.amount_cents as c from public.tally_expenses e where e.group_id = p_group and e.deleted_at is null
    union all
    select s.member_id, -s.owed_cents from public.tally_shares s join public.tally_expenses e on e.id = s.expense_id where e.group_id = p_group and e.deleted_at is null
    union all
    select st.from_member, st.amount_cents from public.tally_settlements st where st.group_id = p_group and st.deleted_at is null and st.status = 'confirmed'
    union all
    select st.to_member, -st.amount_cents from public.tally_settlements st where st.group_id = p_group and st.deleted_at is null and st.status = 'confirmed'
  )
  select l.member_id, sum(l.c)::bigint from legs l where auth.uid() is null or public.is_tally_member(p_group) group by l.member_id having sum(l.c) <> 0
$$;

-- Net per member of the groups p_uid belongs to (positive = is owed, negative = owes). The single definition the app, the page and Today read.
-- Invoker: a signed-in caller only sees groups RLS lets them see, whatever p_uid they pass.
create function public.tally_balances(p_uid uuid, p_group uuid default null)
returns table (group_id uuid, member_id uuid, net_cents bigint)
language sql stable security invoker set search_path = public as $$
  select g.id, n.member_id, n.net_cents
  from public.tally_groups g
  join public.tally_members me on me.group_id = g.id and me.member_user_id = p_uid and me.status = 'active'
  cross join lateral public.tally_net(g.id) n
  where g.deleted_at is null and (p_group is null or g.id = p_group)
$$;

create or replace function public.tally_owed_to_me()
returns jsonb language sql stable security invoker set search_path = public as $$
  select jsonb_build_object('owed_to_me', coalesce(sum(case when b.net_cents > 0 then b.net_cents else 0 end), 0), 'i_owe', coalesce(sum(case when b.net_cents < 0 then -b.net_cents else 0 end), 0))
  from public.tally_balances(auth.uid()) b
  join public.tally_members m on m.id = b.member_id and m.member_user_id = auth.uid()
$$;

-- ---------- writing ----------
-- p: {id?, group_id, description, amount_cents, paid_by (member id, null = me), split_type, spent_on, category, note, receipt_path, transaction_id,
--     shares: [{member_id (null = me), owed_cents, weight?}]}. Shares must sum EXACTLY to the amount. Atomic; definer because shares have no direct writes.
create or replace function public.tally_save_expense(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); eid uuid := nullif(p->>'id', '')::uuid; gid uuid := (p->>'group_id')::uuid; amt bigint := (p->>'amount_cents')::bigint;
  s jsonb; total bigint := 0; mid uuid; mine uuid; owner uuid; cur public.tally_expenses; txn uuid := nullif(p->>'transaction_id', '')::uuid;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select g.user_id into owner from public.tally_groups g where g.id = gid and g.deleted_at is null;
  mine := public.tally_my_member(gid);
  if owner is null or mine is null then raise exception 'group not found'; end if;
  if eid is not null then
    select * into cur from public.tally_expenses e where e.id = eid and e.group_id = gid and e.deleted_at is null for update;
    if cur.id is null then raise exception 'expense not found'; end if;
    if cur.created_by is distinct from uid and owner <> uid then raise exception 'only the person who added this, or the group owner, can change it' using errcode = '42501'; end if;
  end if;
  if jsonb_typeof(p->'shares') <> 'array' or jsonb_array_length(p->'shares') = 0 then raise exception 'at least one share is required'; end if;
  for s in select * from jsonb_array_elements(p->'shares') loop
    total := total + (s->>'owed_cents')::bigint;
    mid := coalesce(nullif(s->>'member_id', '')::uuid, mine);
    if not exists (select 1 from public.tally_members m where m.id = mid and m.group_id = gid and (m.status = 'active' or eid is not null)) then raise exception 'a sharer is not in this group'; end if;
  end loop;
  if total <> amt then raise exception 'shares add up to % but the expense is %', total, amt; end if;
  mid := coalesce(nullif(p->>'paid_by', '')::uuid, mine);
  if not exists (select 1 from public.tally_members m where m.id = mid and m.group_id = gid and (m.status = 'active' or eid is not null)) then raise exception 'the payer is not in this group'; end if;
  if eid is null then
    insert into public.tally_expenses (group_id, description, amount_cents, paid_by_member, split_type, spent_on, category, note, receipt_path, transaction_id, created_by)
    values (gid, p->>'description', amt, mid, coalesce(p->>'split_type', 'equal'), coalesce((p->>'spent_on')::date, (now() at time zone 'America/New_York')::date), p->>'category', p->>'note', p->>'receipt_path', txn, uid) returning id into eid;
  else
    update public.tally_expenses set description = p->>'description', amount_cents = amt, paid_by_member = mid, split_type = coalesce(p->>'split_type', 'equal'),
           spent_on = coalesce((p->>'spent_on')::date, spent_on), category = p->>'category', note = p->>'note', receipt_path = p->>'receipt_path', transaction_id = coalesce(txn, transaction_id), updated_at = clock_timestamp()
     where id = eid;
    delete from public.tally_shares where expense_id = eid;
  end if;
  for s in select * from jsonb_array_elements(p->'shares') loop
    insert into public.tally_shares (expense_id, user_id, member_id, owed_cents, weight) values (eid, owner, coalesce(nullif(s->>'member_id', '')::uuid, mine), (s->>'owed_cents')::bigint, nullif(s->>'weight', '')::numeric);
  end loop;
  return eid;
end $$;

-- p: {name, emoji?, color_key?, kind?, guests: [{name, person_id?, phone?, email?}], invite: [user ids]}.
create or replace function public.tally_create_group(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); gid uuid; x jsonb; u text;
begin
  if uid is null then raise exception 'not signed in'; end if;
  insert into public.tally_groups (user_id, name, emoji, color_key, kind) values (uid, p->>'name', p->>'emoji', coalesce(p->>'color_key', 'shop'), coalesce(p->>'kind', 'group')) returning id into gid;
  for x in select * from jsonb_array_elements(coalesce(p->'guests', '[]'::jsonb)) loop
    perform public.tally_add_guest(gid, x->>'name', nullif(x->>'person_id', '')::uuid, x->>'phone', x->>'email');
  end loop;
  for u in select jsonb_array_elements_text(coalesce(p->'invite', '[]'::jsonb)) loop
    perform public.tally_invite_user(gid, u::uuid, null);
  end loop;
  return gid;
end $$;

-- A guest: a name in the group, with any phone or email kept only in the adder's own people book. Anyone in the group can add one.
create or replace function public.tally_add_guest(p_group uuid, p_name text, p_person uuid default null, p_phone text default null, p_email text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); owner uuid; pid uuid := p_person; nm text := btrim(coalesce(p_name, '')); col text := 'shop'; mid uuid;
begin
  if not public.is_tally_member(p_group) then raise exception 'group not found'; end if;
  select g.user_id into owner from public.tally_groups g where g.id = p_group and g.deleted_at is null;
  if pid is not null then
    select p.name, p.color_key into nm, col from public.people p where p.id = pid and p.user_id = uid;
    if not found then raise exception 'person not found'; end if;
  else
    if nm = '' then raise exception 'a name is required'; end if;
    insert into public.people (user_id, name, phone, email) values (uid, nm, nullif(btrim(p_phone), ''), nullif(btrim(p_email), '')) returning id into pid;
  end if;
  select m.id into mid from public.tally_members m where m.group_id = p_group and m.person_id = pid;
  if mid is not null then
    update public.tally_members set status = 'active', left_at = null where id = mid;
    return mid;
  end if;
  insert into public.tally_members (group_id, user_id, person_id, name, color_key) values (p_group, owner, pid, nm, col) returning id into mid;
  return mid;
end $$;

create or replace function public.tally_owner_gate(p_member uuid) returns void
language plpgsql stable security definer set search_path = public as $$
declare n bigint; m public.tally_members;
begin
  select * into m from public.tally_members where id = p_member;
  select x.net_cents into n from public.tally_net(m.group_id) x where x.member_id = p_member;
  if coalesce(n, 0) <> 0 then raise exception 'outstanding:%', n using errcode = 'P0001'; end if;
end $$;

-- Owner only. Blocked with the amount while the member has a balance, so the app can offer to settle first.
create or replace function public.tally_remove_member(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.tally_members;
begin
  select * into m from public.tally_members where id = p_member for update;
  if m.id is null or not public.is_tally_owner(m.group_id) then raise exception 'only the group owner can remove people' using errcode = '42501'; end if;
  if m.role = 'owner' then raise exception 'the owner can''t be removed' using errcode = '42501'; end if;
  perform public.tally_owner_gate(p_member);
  update public.tally_members set status = 'removed', left_at = now() where id = p_member;
  update public.tally_invites set status = 'cancelled', responded_at = now() where group_id = m.group_id and status = 'pending' and (guest_member = p_member or invitee = m.member_user_id);
end $$;

create or replace function public.tally_leave_group(p_group uuid) returns void
language plpgsql security definer set search_path = public as $$
declare mid uuid := public.tally_my_member(p_group);
begin
  if mid is null then raise exception 'group not found'; end if;
  if public.is_tally_owner(p_group) then raise exception 'the owner can''t leave: delete the group instead' using errcode = '42501'; end if;
  perform public.tally_owner_gate(mid);
  update public.tally_members set status = 'left', left_at = now() where id = mid;
end $$;

-- ---------- invites ----------
create table if not exists public.tally_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.tally_groups(id) on delete cascade,
  invited_by uuid references auth.users(id) on delete set null,
  invitee uuid not null references auth.users(id) on delete cascade,
  guest_member uuid references public.tally_members(id) on delete set null,      -- accepting links this guest (and their balance) to the account
  group_name text not null,
  inviter_name text not null,
  status text not null default 'pending' check (status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now(),
  responded_at timestamptz
);
create unique index if not exists tally_invites_pending_idx on public.tally_invites (group_id, invitee) where status = 'pending';
create index if not exists tally_invites_inbox_idx on public.tally_invites (invitee, created_at desc);
alter table public.tally_invites enable row level security;
alter table public.tally_invites force row level security;
create policy tally_invites_read on public.tally_invites for select to authenticated using (invitee = auth.uid() or public.is_tally_member(group_id));
revoke all on public.tally_invites from anon, authenticated;
grant select on public.tally_invites to authenticated;

-- Any member can invite someone they found. Someone hidden from search can't be invited, whatever id is passed.
create or replace function public.tally_invite_user(p_group uuid, p_user uuid, p_guest uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); iid uuid; gname text; me text;
begin
  if not public.is_tally_member(p_group) then raise exception 'group not found'; end if;
  if p_user = uid then raise exception 'you''re already here'; end if;
  if not exists (select 1 from public.profiles p where p.user_id = p_user and p.discoverable) then raise exception 'person not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.tally_members m where m.group_id = p_group and m.member_user_id = p_user and m.status = 'active') then raise exception 'already in this group'; end if;
  if p_guest is not null and not exists (select 1 from public.tally_members m where m.id = p_guest and m.group_id = p_group and m.member_user_id is null) then raise exception 'guest not found'; end if;
  if (select count(*) from public.tally_invites i where i.invited_by = uid and i.status = 'pending') >= 30 then raise exception 'too many invites are waiting' using errcode = '53400'; end if;
  select g.name into gname from public.tally_groups g where g.id = p_group and g.deleted_at is null;
  select m.name into me from public.tally_members m where m.group_id = p_group and m.member_user_id = uid;
  insert into public.tally_invites (group_id, invited_by, invitee, guest_member, group_name, inviter_name) values (p_group, uid, p_user, p_guest, gname, me)
    on conflict (group_id, invitee) where status = 'pending' do update set guest_member = coalesce(excluded.guest_member, public.tally_invites.guest_member) returning id into iid;
  return iid;
end $$;

create or replace function public.tally_invite_respond(p_invite uuid, p_accept boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); i public.tally_invites; nm text; owner uuid; mid uuid;
begin
  select * into i from public.tally_invites where id = p_invite and invitee = uid and status = 'pending' for update;
  if i.id is null then raise exception 'invite not found' using errcode = 'P0002'; end if;
  update public.tally_invites set status = case when p_accept then 'accepted' else 'declined' end, responded_at = now() where id = i.id;
  if not p_accept then return null; end if;
  select g.user_id into owner from public.tally_groups g where g.id = i.group_id and g.deleted_at is null;
  if owner is null then raise exception 'that group is gone' using errcode = 'P0002'; end if;
  select coalesce(nullif(p.display_name, ''), p.handle, 'Friend') into nm from public.profiles p where p.user_id = uid;
  select m.id into mid from public.tally_members m where m.group_id = i.group_id and m.member_user_id = uid;
  if mid is not null then                                                -- came back after leaving
    update public.tally_members set status = 'active', left_at = null, name = nm where id = mid;
  elsif i.guest_member is not null and exists (select 1 from public.tally_members m where m.id = i.guest_member and m.status = 'active' and m.member_user_id is null) then
    update public.tally_members set member_user_id = uid, name = nm where id = i.guest_member returning id into mid;
  else
    insert into public.tally_members (group_id, user_id, member_user_id, name) values (i.group_id, owner, uid, nm) returning id into mid;
  end if;
  return mid;
end $$;

-- ---------- search: never a directory ----------
-- Exact handle, exact email or exact phone; a handle prefix from 3 characters; at most 5 results; never an email or phone out. Server only: the API rate limits it.
-- Email is matched against auth.users, not the editable profile copy, so nobody can claim another person's address.
create or replace function public.tally_search_people(p_caller uuid, p_q text) returns table (user_id uuid, display_name text, handle text, avatar_url text)
language plpgsql stable security definer set search_path = public as $$
declare q text := lower(btrim(coalesce(p_q, ''))); digits text;
begin
  q := ltrim(q, '@');
  if q = '' then return; end if;
  if position('@' in q) > 1 then
    return query select p.user_id, p.display_name, p.handle, p.avatar_url from public.profiles p join auth.users u on u.id = p.user_id
      where lower(u.email) = q and p.discoverable and p.user_id <> p_caller limit 1;
  elsif q ~ '^\+?[0-9 ().-]{7,20}$' then
    digits := regexp_replace(q, '[^0-9+]', '', 'g');
    return query select p.user_id, p.display_name, p.handle, p.avatar_url from public.profiles p
      where (p.phone = digits or p.phone = '+' || digits or '+1' || digits = p.phone) and p.discoverable and p.user_id <> p_caller limit 1;
  elsif q ~ '^[a-z0-9_]+$' then
    return query select p.user_id, p.display_name, p.handle, p.avatar_url from public.profiles p
      where p.handle is not null and p.discoverable and p.user_id <> p_caller
        and (p.handle = q or (char_length(q) >= 3 and p.handle like replace(q, '_', '\_') || '%'))
      order by (p.handle = q) desc, p.handle limit 5;
  end if;
end $$;

-- ---------- Splitwise import, now by member ----------
create or replace function public.tally_import_splitwise(p_uid uuid, p_batch uuid, p jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare gid uuid; n text; pid uuid; mid uuid; mine uuid; ids jsonb := '{}'; e jsonb; s jsonb; eid uuid; added_e int := 0; added_s int := 0;
begin
  select id into gid from public.tally_groups where user_id = p_uid and import_key = p->'group'->>'import_key' and deleted_at is null;
  if gid is null then
    insert into public.tally_groups (user_id, name, import_key) values (p_uid, p->'group'->>'name', p->'group'->>'import_key') returning id into gid;
  end if;
  select id into mine from public.tally_members where group_id = gid and role = 'owner';
  for n in select jsonb_array_elements_text(p->'people') loop
    select id into mid from public.tally_members where group_id = gid and lower(name) = lower(n) limit 1;
    if mid is null then
      select id into pid from public.people where user_id = p_uid and lower(name) = lower(n) limit 1;
      if pid is null then insert into public.people (user_id, name) values (p_uid, n) returning id into pid; end if;
      insert into public.tally_members (group_id, user_id, person_id, name) values (gid, p_uid, pid, n) returning id into mid;
    end if;
    ids := ids || jsonb_build_object(n, mid);
  end loop;
  for e in select * from jsonb_array_elements(p->'expenses') loop
    eid := null;
    insert into public.tally_expenses (group_id, description, amount_cents, paid_by_member, split_type, spent_on, category, external_ref, import_batch_id, created_by)
    values (gid, e->>'description', (e->>'amount_cents')::bigint, coalesce((ids->>(e->>'paid_by'))::uuid, mine), 'exact', (e->>'spent_on')::date, e->>'category', e->>'ref', p_batch, p_uid)
    on conflict do nothing returning id into eid;
    if eid is not null then
      added_e := added_e + 1;
      for s in select * from jsonb_array_elements(e->'shares') loop
        insert into public.tally_shares (user_id, expense_id, member_id, owed_cents) values (p_uid, eid, coalesce((ids->>(s->>'person'))::uuid, mine), (s->>'owed_cents')::bigint);
      end loop;
    end if;
  end loop;
  for s in select * from jsonb_array_elements(p->'settlements') loop
    insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, method, settled_on, external_ref, import_batch_id, created_by)
    values (gid, coalesce((ids->>(s->>'from'))::uuid, mine), coalesce((ids->>(s->>'to'))::uuid, mine), (s->>'amount_cents')::bigint, 'other', (s->>'on')::date, s->>'ref', p_batch, p_uid)
    on conflict do nothing;
    if found then added_s := added_s + 1; end if;
  end loop;
  insert into public.tally_activity (group_id, actor, action, entity_id, label, new_cents) values (gid, p_uid, 'imported', p_batch, 'Splitwise', added_e + added_s);
  return jsonb_build_object('group_id', gid, 'expenses', added_e, 'settlements', added_s);
end $$;

-- A settlement's bank row now belongs to whoever linked it, so the flow follows the row, not the group owner.
create or replace function public.tally_settlement_flow() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.transaction_id is not null then
    update public.transactions t set flow = null
     where t.id = old.transaction_id and t.flow = 'settlement'
       and not exists (select 1 from public.tally_settlements s where s.transaction_id = old.transaction_id and s.id <> old.id and s.status = 'confirmed' and s.deleted_at is null);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.transaction_id is not null and new.status = 'confirmed' and new.deleted_at is null then
    update public.transactions t set flow = 'settlement', user_edited = case when 'flow' = any(t.user_edited) then t.user_edited else array_append(t.user_edited, 'flow') end
     where t.id = new.transaction_id and t.flow is distinct from 'reimbursement';
  end if;
  return coalesce(new, old);
end $$;

-- standing lockdown again for everything new
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname in ('tick_flows','tick_activity_page','tick_months','tick_filtered','tick_links_used','tick_account_counts','tick_top_merchants','tick_classified',
                     'tally_save_expense','tally_balances','tally_owed_to_me','is_tally_member','is_tally_owner','tally_my_member','tally_net','tally_create_group','tally_add_guest',
                     'tally_remove_member','tally_leave_group','tally_invite_user','tally_invite_respond') then
      execute format('grant execute on function %s to authenticated', f.sig);
    else
      execute format('revoke execute on function %s from authenticated', f.sig);
    end if;
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
