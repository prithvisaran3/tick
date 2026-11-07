-- Zelle first: friends pay by Zelle, so Tick keeps where to send it.
--   profiles.zelle: my own Zelle email or phone. I set it; people in my groups can read it, nobody else.
--   tally_zelle_notes: what I noted for a member. Private to me, like my people book.
alter table public.profiles add column if not exists zelle text;
alter table public.profiles add constraint profiles_zelle_len check (zelle is null or char_length(zelle) between 3 and 120);

create table if not exists public.tally_zelle_notes (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  member_id uuid not null references public.tally_members(id) on delete cascade,
  zelle text not null check (char_length(zelle) between 3 and 120),
  updated_at timestamptz not null default now(),
  primary key (user_id, member_id)
);
alter table public.tally_zelle_notes enable row level security;
alter table public.tally_zelle_notes force row level security;
create policy tally_zelle_notes_mine on public.tally_zelle_notes for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and exists (select 1 from public.tally_members m where m.id = member_id));
revoke all on public.tally_zelle_notes from anon, authenticated;
grant select, insert, update, delete on public.tally_zelle_notes to authenticated;

-- The Zelle of everyone who shares an active group with me, by member id. Never a way to look up a stranger.
create or replace function public.tally_zelle_book() returns table (member_id uuid, zelle text)
language sql stable security definer set search_path = public as $$
  select o.id, p.zelle
  from public.tally_members me
  join public.tally_members o on o.group_id = me.group_id and o.status = 'active' and o.id <> me.id
  join public.profiles p on p.user_id = o.member_user_id
  where me.member_user_id = auth.uid() and me.status = 'active' and p.zelle is not null
$$;
revoke execute on function public.tally_zelle_book() from public, anon;
grant execute on function public.tally_zelle_book() to authenticated, service_role;
