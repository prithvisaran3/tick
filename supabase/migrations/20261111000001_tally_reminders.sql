-- Tally v2, phase 3: reminders. A Tick user gets one in their inbox; a guest gets a message the sender sends themselves. Tick has no push (free Personal Team).
create table if not exists public.tally_reminders (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.tally_groups(id) on delete cascade,
  from_user uuid references auth.users(id) on delete set null,
  from_name text not null,
  to_member uuid not null references public.tally_members(id) on delete cascade,
  to_user uuid references auth.users(id) on delete set null,
  group_name text not null,
  amount_cents bigint not null check (amount_cents > 0),
  tone text not null default 'neutral' check (tone in ('friendly','neutral','firm')),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists tally_reminders_limit_idx on public.tally_reminders (group_id, to_member, created_at desc);
create index if not exists tally_reminders_inbox_idx on public.tally_reminders (to_user, created_at desc) where to_user is not null;
alter table public.tally_reminders enable row level security;
alter table public.tally_reminders force row level security;
create policy tally_reminders_read on public.tally_reminders for select to authenticated using (to_user = auth.uid() or public.is_tally_member(group_id));
revoke all on public.tally_reminders from anon, authenticated;
grant select on public.tally_reminders to authenticated;

-- One reminder per person per group per 24 hours, whoever sends it. The amount comes from the balance, not from the caller.
create or replace function public.tally_remind(p_member uuid, p_tone text default 'neutral') returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.tally_members; net bigint; me text; gname text; rid uuid;
begin
  select * into m from public.tally_members where id = p_member and status = 'active';
  if m.id is null or not public.is_tally_member(m.group_id) then raise exception 'member not found' using errcode = 'P0002'; end if;
  if m.member_user_id = auth.uid() then raise exception 'that''s you'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_member::text, 0));
  if exists (select 1 from public.tally_reminders r where r.group_id = m.group_id and r.to_member = p_member and r.created_at > now() - interval '24 hours') then
    raise exception 'reminded recently' using errcode = '53400';
  end if;
  select x.net_cents into net from public.tally_net(m.group_id) x where x.member_id = p_member;
  if coalesce(net, 0) >= 0 then raise exception 'nothing owed'; end if;
  select x.name into me from public.tally_members x where x.group_id = m.group_id and x.member_user_id = auth.uid();
  select g.name into gname from public.tally_groups g where g.id = m.group_id and g.deleted_at is null;
  insert into public.tally_reminders (group_id, from_user, from_name, to_member, to_user, group_name, amount_cents, tone)
  values (m.group_id, auth.uid(), me, p_member, m.member_user_id, gname, -net, coalesce(p_tone, 'neutral')) returning id into rid;
  perform public.tally_log(m.group_id, 'reminded', p_member, m.name, null, -net);
  return rid;
end $$;

create or replace function public.tally_reminders_seen() returns void
language sql security definer set search_path = public as $$
  update public.tally_reminders set read_at = now() where to_user = auth.uid() and read_at is null
$$;

-- Editing a settlement (partial amounts, method, note) goes through here, for its creator or the group owner.
create or replace function public.tally_edit_settlement(p_id uuid, p_cents bigint, p_method text, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare s public.tally_settlements;
begin
  select * into s from public.tally_settlements where id = p_id and deleted_at is null for update;
  if s.id is null or not public.is_tally_member(s.group_id) then raise exception 'settlement not found' using errcode = 'P0002'; end if;
  if s.created_by is distinct from auth.uid() and not public.is_tally_owner(s.group_id) then raise exception 'only the person who added this, or the group owner, can change it' using errcode = '42501'; end if;
  update public.tally_settlements set amount_cents = p_cents, method = p_method, note = p_note where id = p_id;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f' and p.proname in ('tally_remind','tally_reminders_seen','tally_edit_settlement') loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;
