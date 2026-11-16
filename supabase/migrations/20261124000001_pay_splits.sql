-- Paycheck splits: one paycheck, several destinations. A line is a percent of net, a fixed amount, or "the rest" (exactly one).
-- Fixed lines are taken first in order, then percents of the whole net, and the rest line gets what is left, so the lines always sum to net.
create table if not exists public.pay_splits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  account_id uuid references public.accounts(id) on delete cascade,          -- null: an account Tick doesn't see ("other account")
  label text check (label is null or char_length(label) between 1 and 60),
  mask text check (mask is null or mask ~ '^[0-9]{2,4}$'),
  kind text not null check (kind in ('percent','fixed','rest')),
  value bigint not null default 0,                                           -- percent: basis points (1..10000). fixed: cents. rest: 0
  sort int not null default 0,
  created_at timestamptz not null default now(),
  check ((kind = 'percent' and value between 1 and 10000) or (kind = 'fixed' and value between 1 and 100000000) or (kind = 'rest' and value = 0)),
  check (account_id is not null or label is not null)
);
create unique index if not exists pay_splits_one_rest on public.pay_splits (user_id) where kind = 'rest';
create index if not exists pay_splits_user_idx on public.pay_splits (user_id, sort);
alter table public.pay_splits enable row level security;
alter table public.pay_splits force row level security;
create policy pay_splits_read on public.pay_splits for select to authenticated using (user_id = auth.uid());
revoke all on public.pay_splits from anon;
revoke insert, update, delete, truncate on public.pay_splits from authenticated;          -- written only through save_pay_splits, whole set at once

-- The amounts for a net pay. Pure: the lines come in as jsonb so the app, the API and the tests run the very same thing.
create or replace function public.pay_split_amounts(p_net bigint, p_splits jsonb)
returns table (idx int, cents bigint) language plpgsql immutable set search_path = public as $$
declare left_c bigint := greatest(p_net, 0); s jsonb; i int; c bigint; out_c bigint[] := '{}';
begin
  for i in 0 .. coalesce(jsonb_array_length(p_splits), 0) - 1 loop out_c := out_c || 0::bigint; end loop;
  for i in 0 .. coalesce(jsonb_array_length(p_splits), 0) - 1 loop
    s := p_splits -> i;
    if s ->> 'kind' = 'fixed' then c := least((s ->> 'value')::bigint, left_c); out_c[i + 1] := c; left_c := left_c - c; end if;
  end loop;
  for i in 0 .. coalesce(jsonb_array_length(p_splits), 0) - 1 loop
    s := p_splits -> i;
    if s ->> 'kind' = 'percent' then c := least(greatest(p_net, 0) * (s ->> 'value')::bigint / 10000, left_c); out_c[i + 1] := c; left_c := left_c - c; end if;
  end loop;
  for i in 0 .. coalesce(jsonb_array_length(p_splits), 0) - 1 loop
    if (p_splits -> i) ->> 'kind' = 'rest' then out_c[i + 1] := left_c; left_c := 0; end if;
    idx := i; cents := out_c[i + 1]; return next;
  end loop;
end $$;

-- Replace my splits with a validated set: none at all, or lines with exactly one "rest", percents within 100%, accounts that are mine.
create or replace function public.save_pay_splits(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); s jsonb; n int := coalesce(jsonb_array_length(p), 0); i int := 0;
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if n > 8 then raise exception 'At most 8 lines.' using errcode = '22023'; end if;
  if n > 0 and (select count(*) from jsonb_array_elements(p) e where e ->> 'kind' = 'rest') <> 1 then raise exception 'One line must take the rest.' using errcode = '22023'; end if;
  if (select coalesce(sum((e ->> 'value')::bigint), 0) from jsonb_array_elements(p) e where e ->> 'kind' = 'percent') > 10000 then raise exception 'The percents add up to more than 100.' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(p) e where e ->> 'account_id' is not null and not exists (select 1 from public.accounts a where a.id = (e ->> 'account_id')::uuid and a.user_id = uid)) then
    raise exception 'not found' using errcode = '42501';
  end if;
  if (select count(*) from jsonb_array_elements(p) e where e ->> 'account_id' is not null) <> (select count(distinct e ->> 'account_id') from jsonb_array_elements(p) e where e ->> 'account_id' is not null) then
    raise exception 'Each account can have one line.' using errcode = '22023';
  end if;
  delete from public.pay_splits where user_id = uid;
  for s in select * from jsonb_array_elements(p) loop
    insert into public.pay_splits (user_id, account_id, label, mask, kind, value, sort)
    values (uid, nullif(s ->> 'account_id', '')::uuid, nullif(left(s ->> 'label', 60), ''), nullif(s ->> 'mask', ''), s ->> 'kind', case when s ->> 'kind' = 'rest' then 0 else (s ->> 'value')::bigint end, i);
    i := i + 1;
  end loop;
  return n;
end $$;
revoke all on function public.save_pay_splits(jsonb) from public, anon;
grant execute on function public.save_pay_splits(jsonb) to authenticated;

-- An expected paycheck can now be one line of a split: which account it should land in.
alter table public.expected add column if not exists account_id uuid references public.accounts(id) on delete set null;
