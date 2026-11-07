-- Group icons and avatars. An avatar is a small JSON of layer choices, on the profile and copied to my member rows so people in my groups can draw it.
alter table public.tally_groups add column if not exists icon text check (icon is null or char_length(icon) <= 20);
update public.tally_groups set icon = case emoji when '🏠' then 'home' when '✈️' then 'trip' when '🍽️' then 'food' when '🎉' then 'party' when '🛒' then 'groceries' when '💼' then 'work'
  when '🍕' then 'food' when '🍻' then 'drinks' when '🍺' then 'drinks' when '☕' then 'coffee' when '🚗' then 'car' when '🎬' then 'movie' when '🎵' then 'concert' when '🎁' then 'gift' when '🐶' then 'pets'
  when '🏖️' then 'beach' when '⛷️' then 'ski' when '🏕️' then 'camping' else 'misc' end where emoji is not null and icon is null;
grant insert (icon) on public.tally_groups to authenticated;
grant update (icon) on public.tally_groups to authenticated;

alter table public.profiles add column if not exists avatar jsonb check (avatar is null or pg_column_size(avatar) < 512);
alter table public.tally_members add column if not exists avatar jsonb check (avatar is null or pg_column_size(avatar) < 512);

-- p: {name, icon?, emoji?, color_key?, kind?, guests, invite}.
create or replace function public.tally_create_group(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); gid uuid; x jsonb; u text;
begin
  if uid is null then raise exception 'not signed in'; end if;
  insert into public.tally_groups (user_id, name, icon, emoji, color_key, kind) values (uid, p->>'name', p->>'icon', p->>'emoji', coalesce(p->>'color_key', 'shop'), coalesce(p->>'kind', 'group')) returning id into gid;
  for x in select * from jsonb_array_elements(coalesce(p->'guests', '[]'::jsonb)) loop
    perform public.tally_add_guest(gid, x->>'name', nullif(x->>'person_id', '')::uuid, x->>'phone', x->>'email');
  end loop;
  for u in select jsonb_array_elements_text(coalesce(p->'invite', '[]'::jsonb)) loop
    perform public.tally_invite_user(gid, u::uuid, null);
  end loop;
  return gid;
end $$;

create or replace function public.tally_set_avatar(p_avatar jsonb) returns void
language sql security definer set search_path = public as $$
  update public.profiles set avatar = p_avatar where user_id = auth.uid();
  update public.tally_members set avatar = p_avatar where member_user_id = auth.uid();
$$;

-- A guest has no account, so anyone in their group can dress them.
create or replace function public.tally_set_guest_avatar(p_member uuid, p_avatar jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare m public.tally_members;
begin
  select * into m from public.tally_members where id = p_member;
  if m.id is null or m.member_user_id is not null or not public.is_tally_member(m.group_id) then raise exception 'member not found' using errcode = 'P0002'; end if;
  update public.tally_members set avatar = p_avatar where id = p_member;
end $$;

revoke execute on function public.tally_set_avatar(jsonb), public.tally_set_guest_avatar(uuid, jsonb) from public, anon;
grant execute on function public.tally_set_avatar(jsonb), public.tally_set_guest_avatar(uuid, jsonb) to authenticated, service_role;
