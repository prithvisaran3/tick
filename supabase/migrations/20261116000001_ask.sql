-- Ask Tick learns. Numbers still come from the money rules; these tables only remember which tool answered which question.
alter table public.settings add column if not exists ask_cloud boolean not null default true;

create table if not exists public.ask_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  question text not null check (char_length(question) <= 500),
  normalised text not null,
  path text not null check (path in ('rules','learned','device','cloud','none')),
  tool text,
  params jsonb not null default '{}',
  latency_ms int,
  summary jsonb not null default '{}',          -- numbers only
  rating smallint check (rating in (-1, 1)),
  correction jsonb,                             -- {reason, tool, params}
  created_at timestamptz not null default now()
);
create index if not exists ask_log_user_idx on public.ask_log (user_id, created_at desc);
create index if not exists ask_log_good_idx on public.ask_log (user_id) where rating = 1 or correction is not null;

create table if not exists public.ask_memory (
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  kind text not null check (kind in ('alias','rule','index')),
  key text not null,
  value jsonb not null,
  hits int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, kind, key)
);

do $$ declare t text; begin
  foreach t in array array['ask_log','ask_memory'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('create policy %I on public.%I for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_owner', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- What Ask Tick's tools read: the money rules' rows, plus who a person-to-person row was with.
create or replace function public.ask_rows(p_uid uuid, p_from timestamptz) returns table (id uuid, occurred_at timestamptz, amount_cents bigint, category_id uuid, cat_name text, merchant text, tags text[],
    account_id uuid, excluded boolean, out_c bigint, in_c bigint, friends_c bigint, person text, rule_id uuid)
language sql stable security invoker set search_path = public as $$
  select k.id, k.occurred_at, k.amount_cents, k.category_id, k.cat_name, k.merchant, k.tags, k.account_id, k.excluded, k.out_c, k.in_c, k.friends_c,
         case when public.tick_is_p2p(k.merchant) then public.tick_p2p_person(k.merchant) end, t.category_rule_id
  from public.tick_classified(p_uid, p_from, null) k join public.transactions t on t.id = k.id
$$;
revoke all on function public.ask_rows(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.ask_rows(uuid, timestamptz) to service_role;

select cron.schedule('tick-ask-nightly', '20 8 * * *', $$select public.tick_call_api('/jobs/ask-nightly')$$);
