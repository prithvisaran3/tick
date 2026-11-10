-- Profile: holidays observed on the Friday before a Saturday (federal rule), goals that pause, and a place for walkthrough state.

create or replace function public.is_bank_holiday(d date) returns boolean
language sql immutable set search_path = public as $$
  with x as (select extract(month from d)::int m, extract(day from d)::int dd, extract(dow from d)::int w, ((extract(day from d)::int - 1) / 7 + 1) nth,
                    extract(month from d + 7)::int next_m)
  select
    (m, dd) in ((1,1),(6,19),(7,4),(11,11),(12,25))
    or (w = 1 and (extract(month from d - 1)::int, extract(day from d - 1)::int) in ((1,1),(6,19),(7,4),(11,11),(12,25)))   -- Sunday holiday, observed Monday
    or (w = 5 and (extract(month from d + 1)::int, extract(day from d + 1)::int) in ((1,1),(6,19),(7,4),(11,11),(12,25)))   -- Saturday holiday, observed Friday
    or (w = 1 and m = 1 and nth = 3)
    or (w = 1 and m = 2 and nth = 3)
    or (w = 1 and m = 5 and next_m <> 5)
    or (w = 1 and m = 9 and nth = 1)
    or (w = 1 and m = 10 and nth = 2)
    or (w = 4 and m = 11 and nth = 4)
  from x
$$;

alter table public.goals add column if not exists paused boolean not null default false;
alter table public.profiles add column if not exists tips jsonb not null default '{}'::jsonb check (pg_column_size(tips) < 2048);
