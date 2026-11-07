-- One definition of the pay period. A rule: {frequency, next_date (the anchor: any known payday), amount_cents, days: [15, 30] for twice a month}.
-- All maths is on `date`, so daylight saving can't move a payday. "Today" is a New York day.

-- US bank holidays: fixed dates (Sunday ones observed on Monday) and the nth-weekday ones.
create or replace function public.is_bank_holiday(d date) returns boolean
language sql immutable set search_path = public as $$
  with x as (select extract(month from d)::int m, extract(day from d)::int dd, extract(dow from d)::int w, ((extract(day from d)::int - 1) / 7 + 1) nth,
                    extract(month from d + 7)::int next_m)
  select
    (m, dd) in ((1,1),(6,19),(7,4),(11,11),(12,25))
    or (w = 1 and (extract(month from d - 1)::int, extract(day from d - 1)::int) in ((1,1),(6,19),(7,4),(11,11),(12,25)))
    or (w = 1 and m = 1 and nth = 3)                   -- Martin Luther King Jr. Day
    or (w = 1 and m = 2 and nth = 3)                   -- Washington's Birthday
    or (w = 1 and m = 5 and next_m <> 5)               -- Memorial Day: last Monday
    or (w = 1 and m = 9 and nth = 1)                   -- Labor Day
    or (w = 1 and m = 10 and nth = 2)                  -- Columbus Day
    or (w = 4 and m = 11 and nth = 4)                  -- Thanksgiving
  from x
$$;

-- Weekend or holiday: paid the business day before.
create or replace function public.business_day_before(d date) returns date
language plpgsql immutable set search_path = public as $$
declare x date := d;
begin
  while extract(dow from x) in (0, 6) or public.is_bank_holiday(x) loop x := x - 1; end loop;
  return x;
end $$;

-- The paydays around a date: the last one on or before it, and the first one after it. Null for an unusable rule.
create or replace function public.pay_dates(p_rule jsonb, p_date date) returns table (prev_payday date, next_payday date)
language plpgsql immutable set search_path = public as $$
declare f text := coalesce(p_rule->>'frequency', 'biweekly'); a date; step int; k int;
begin
  begin a := (p_rule->>'next_date')::date; exception when others then return; end;
  if a is null then return; end if;
  if f in ('weekly', 'biweekly') then
    step := case f when 'weekly' then 7 else 14 end;
    k := floor((p_date - a)::numeric / step);
    -- "My next payday is the 13th" stays true even if the 13th is several steps away: nothing is projected between now and the anchor.
    if p_date < a - step then return query select a - step, a; end if;
    return query select a + k * step, a + (k + 1) * step;
  elsif f = 'monthly' then
    return query
      with c as (select (make_date(extract(year from b)::int, extract(month from b)::int, 1)
                         + (least(extract(day from a)::int, extract(day from (b + interval '1 month - 1 day'))::int) - 1))::date as d
                 from generate_series(date_trunc('month', p_date) - interval '2 month', date_trunc('month', p_date) + interval '2 month', interval '1 month') b)
      select (select max(d) from c where d <= p_date), (select min(d) from c where d > p_date);
  else
    return query
      with days as (select coalesce((select array_agg(v::int) from jsonb_array_elements_text(p_rule->'days') v), array[extract(day from a)::int, least(extract(day from a)::int + 15, 31)]) ds),
      c as (select public.business_day_before((make_date(extract(year from b)::int, extract(month from b)::int, 1)
                     + (least(x, extract(day from (b + interval '1 month - 1 day'))::int) - 1))::date) as d
            from generate_series(date_trunc('month', p_date) - interval '2 month', date_trunc('month', p_date) + interval '2 month', interval '1 month') b, days, unnest(days.ds) x)
      select (select max(d) from c where d <= p_date), (select min(d) from c where d > p_date);
  end if;
end $$;

create or replace function public.pay_period(p_user uuid, p_date date default null) returns table (period_start date, period_end date, next_payday date)
language sql stable security invoker set search_path = public as $$
  select x.prev_payday, x.next_payday - 1, x.next_payday
  from public.settings s
  cross join lateral public.pay_dates(s.payday_rule, coalesce(p_date, (now() at time zone 'America/New_York')::date)) x
  where s.user_id = p_user and s.payday_rule is not null
$$;

revoke all on function public.is_bank_holiday(date), public.business_day_before(date), public.pay_dates(jsonb, date), public.pay_period(uuid, date) from public, anon;
grant execute on function public.is_bank_holiday(date), public.business_day_before(date), public.pay_dates(jsonb, date), public.pay_period(uuid, date) to authenticated, service_role;
