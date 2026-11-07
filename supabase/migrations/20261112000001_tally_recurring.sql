-- Tally v2, phase 4: shared bills that post on a schedule, and notice the bank charge when it appears.
create table if not exists public.tally_recurring (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.tally_groups(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  description text not null check (char_length(description) between 1 and 120),
  amount_cents bigint not null check (amount_cents > 0 and amount_cents < 100000000000),
  paid_by_member uuid not null references public.tally_members(id) on delete cascade,
  shares jsonb not null,                       -- [{member_id, owed_cents}], summing to the amount
  split_type text not null default 'exact',
  category text,
  cadence text not null check (cadence in ('weekly','monthly','yearly')),
  next_on date not null,
  match_text text,                             -- what the bank row says, for "it posted on your card"
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists tally_recurring_due_idx on public.tally_recurring (next_on) where active;
alter table public.tally_recurring enable row level security;
alter table public.tally_recurring force row level security;
create policy tally_recurring_read on public.tally_recurring for select to authenticated using (public.is_tally_member(group_id));
revoke all on public.tally_recurring from anon, authenticated;
grant select on public.tally_recurring to authenticated;

create or replace function public.tally_save_recurring(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare gid uuid := (p->>'group_id')::uuid; mine uuid := public.tally_my_member(gid); payer uuid; total bigint; s jsonb; shares jsonb := '[]'; mid uuid; rid uuid;
begin
  if mine is null then raise exception 'group not found'; end if;
  payer := coalesce(nullif(p->>'paid_by', '')::uuid, mine);
  if not exists (select 1 from public.tally_members m where m.id = payer and m.group_id = gid and m.status = 'active') then raise exception 'the payer is not in this group'; end if;
  select coalesce(sum((x->>'owed_cents')::bigint), 0) into total from jsonb_array_elements(p->'shares') x;
  if total <> (p->>'amount_cents')::bigint then raise exception 'shares add up to % but the bill is %', total, p->>'amount_cents'; end if;
  for s in select * from jsonb_array_elements(p->'shares') loop
    mid := coalesce(nullif(s->>'member_id', '')::uuid, mine);
    if not exists (select 1 from public.tally_members m where m.id = mid and m.group_id = gid and m.status = 'active') then raise exception 'a sharer is not in this group'; end if;
    shares := shares || jsonb_build_object('member_id', mid, 'owed_cents', (s->>'owed_cents')::bigint);
  end loop;
  insert into public.tally_recurring (group_id, created_by, description, amount_cents, paid_by_member, shares, split_type, category, cadence, next_on, match_text)
  values (gid, auth.uid(), p->>'description', (p->>'amount_cents')::bigint, payer, shares, coalesce(p->>'split_type', 'exact'), p->>'category', p->>'cadence', (p->>'next_on')::date, coalesce(nullif(p->>'match_text', ''), p->>'description'))
  returning id into rid;
  perform public.tally_log(gid, 'recurring_added', rid, p->>'description', null, (p->>'amount_cents')::bigint);
  return rid;
end $$;

create or replace function public.tally_stop_recurring(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.tally_recurring;
begin
  select * into r from public.tally_recurring where id = p_id and active for update;
  if r.id is null or not public.is_tally_member(r.group_id) then raise exception 'bill not found' using errcode = 'P0002'; end if;
  if r.created_by is distinct from auth.uid() and not public.is_tally_owner(r.group_id) then raise exception 'only the person who added this, or the group owner, can stop it' using errcode = '42501'; end if;
  update public.tally_recurring set active = false where id = p_id;
  perform public.tally_log(r.group_id, 'recurring_stopped', p_id, r.description);
end $$;

-- Server only. Posts one occurrence and moves the date on. external_ref makes a retry of the same date a no-op. A bill whose people have left stops
-- instead of posting to someone who is gone.
create or replace function public.tally_post_recurring(p_id uuid, p_txn uuid default null) returns uuid
language plpgsql security invoker set search_path = public as $$
declare r public.tally_recurring; eid uuid; s jsonb; owner uuid; ref text;
begin
  select * into r from public.tally_recurring where id = p_id and active for update;
  if r.id is null then return null; end if;
  select g.user_id into owner from public.tally_groups g where g.id = r.group_id and g.deleted_at is null and g.archived_at is null;
  if owner is null then return null; end if;
  if exists (select 1 from public.tally_members m where m.group_id = r.group_id and m.status <> 'active'
             and (m.id = r.paid_by_member or m.id in (select (x->>'member_id')::uuid from jsonb_array_elements(r.shares) x))) then
    update public.tally_recurring set active = false where id = p_id;
    perform public.tally_log(r.group_id, 'recurring_stopped', p_id, r.description);
    return null;
  end if;
  ref := format('recurring:%s:%s', r.id, r.next_on);
  insert into public.tally_expenses (group_id, description, amount_cents, paid_by_member, split_type, spent_on, category, transaction_id, external_ref, created_by)
  values (r.group_id, r.description, r.amount_cents, r.paid_by_member, r.split_type, r.next_on, r.category, p_txn, ref, r.created_by)
  on conflict do nothing returning id into eid;
  if eid is not null then
    for s in select * from jsonb_array_elements(r.shares) loop
      insert into public.tally_shares (expense_id, user_id, member_id, owed_cents) values (eid, owner, (s->>'member_id')::uuid, (s->>'owed_cents')::bigint);
    end loop;
  end if;
  update public.tally_recurring set next_on = case r.cadence when 'weekly' then r.next_on + 7 when 'yearly' then (r.next_on + interval '1 year')::date else (r.next_on + interval '1 month')::date end where id = p_id;
  return eid;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f' and p.proname in ('tally_save_recurring','tally_stop_recurring','tally_post_recurring') loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.proname = 'tally_post_recurring' then execute format('revoke execute on function %s from authenticated', f.sig);
    else execute format('grant execute on function %s to authenticated', f.sig); end if;
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

select cron.schedule('tick-tally-recurring', '0 11 * * *', $$select public.tick_call_api('/jobs/tally-recurring')$$);
