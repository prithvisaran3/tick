-- Server totals and keyset pages on a fixed fixture. The same fixture and the same expected numbers are in
-- app/test/flows_parity_test.dart, so demo mode (Dart) and live mode (SQL) can never disagree. Always rolls back.
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
  chk uuid; disc uuid; loan uuid; c_inc uuid; c_gro uuid; c_tr uuid; c_loan uuid; c_fee uuid; c_cof uuid; c_sw uuid;
  j jsonb; n int; seen uuid[] := '{}'; cur_at timestamptz; cur_id uuid; r jsonb; fails text := '';
  nov_from timestamptz := '2026-11-01 00:00 America/New_York'; nov_to timestamptz := '2026-12-01 00:00 America/New_York';
begin
  insert into auth.users (id, aud, role, email) values (a, 'authenticated', 'authenticated', 'a@test.local'), (b, 'authenticated', 'authenticated', 'b@test.local');
  insert into public.accounts (user_id, name, type, mask) values (a, 'Chase checking', 'checking', '1173') returning id into chk;
  insert into public.accounts (user_id, name, type, mask, institution) values (a, 'Discover it', 'credit', '1234', 'Discover') returning id into disc;
  insert into public.accounts (user_id, name, type, mask, institution) values (a, 'Student loan', 'loan', '9001', 'SoFi') returning id into loan;
  select id into c_inc from public.categories where user_id = a and name = 'Income';
  select id into c_gro from public.categories where user_id = a and name = 'Groceries';
  select id into c_tr from public.categories where user_id = a and name = 'Transfer';
  select id into c_loan from public.categories where user_id = a and name = 'Loan payment';
  select id into c_fee from public.categories where user_id = a and name = 'Fees and interest';
  select id into c_cof from public.categories where user_id = a and name = 'Coffee';
  select id into c_sw from public.categories where user_id = a and name = 'Software';
  if c_loan is null or c_fee is null then fails := fails || 'new default categories missing; '; end if;

  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_clean, category_id, flow, tags) values
    (a, chk,  200000, '2026-11-14 15:00Z', 'Payroll',          c_inc,  null, '{}'),
    (a, disc,  -5000, '2026-11-03 18:00Z', 'Trader Joe''s',    c_gro,  null, '{}'),
    (a, disc,   1000, '2026-11-05 18:00Z', 'Trader Joe''s',    c_gro,  null, '{}'),          -- refund on the card
    (a, chk,  -30000, '2026-11-20 15:00Z', 'Discover payment', c_tr,   'transfer', '{}'),
    (a, disc,  30000, '2026-11-21 15:00Z', 'Payment received', c_tr,   'transfer', '{}'),
    (a, chk,  -40000, '2026-11-10 15:00Z', 'SoFi loan',        c_loan, 'bill', '{}'),
    (a, loan,  40000, '2026-11-11 15:00Z', 'Payment received', c_tr,   'transfer', '{}'),
    (a, disc,  -3500, '2026-11-25 15:00Z', 'Interest charge',  c_fee,  null, '{}'),
    (a, chk,   -2000, '2026-12-01 04:30Z', 'Blue Bottle',      c_cof,  null, '{}'),          -- 11:30 pm Nov 30 in New York
    (a, chk,    -999, '2026-11-01 03:00Z', 'Late snack',       c_cof,  null, '{}'),          -- 11 pm Oct 31 in New York
    (a, disc,  -1500, '2026-11-12 15:00Z', 'Cursor',           c_sw,   null, '{business}');

  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  j := public.tick_flows(nov_from, nov_to);
  if (j->>'in')::bigint <> 200000 then fails := fails || format('in %s; ', j->>'in'); end if;
  if (j->>'out')::bigint <> 51000 then fails := fails || format('out %s; ', j->>'out'); end if;
  if (j->>'net')::bigint <> 149000 then fails := fails || format('net %s; ', j->>'net'); end if;
  if (j->>'business')::bigint <> 1500 then fails := fails || 'business; '; end if;
  if (j->>'bills')::bigint <> 40000 then fails := fails || 'bills; '; end if;
  if (j->'by_category'->>c_gro::text)::bigint <> 4000 then fails := fails || 'groceries net of refund; '; end if;
  if j->'by_category' ? c_tr::text then fails := fails || 'transfers leaked into categories; '; end if;
  if (j->'daily_out'->>'2026-11-30')::bigint <> 2000 then fails := fails || 'ET day boundary; '; end if;

  -- Filters: credit cards only; one account; search; category.
  j := public.tick_flows(nov_from, nov_to, array['credit']);
  if (j->>'out')::bigint <> 9000 or (j->>'in')::bigint <> 0 then fails := fails || format('credit filter %s; ', j); end if;
  j := public.tick_flows(nov_from, nov_to, null, array[chk]);
  if (j->>'out')::bigint <> 42000 or (j->>'in')::bigint <> 200000 then fails := fails || format('account filter %s; ', j); end if;
  j := public.tick_flows(nov_from, nov_to, null, null, null, 'trader');
  if (j->>'out')::bigint <> 4000 or (j->>'count')::int <> 2 then fails := fails || 'search; '; end if;
  j := public.tick_flows(nov_from, nov_to, null, null, null, 'groc');      -- matches the category name
  if (j->>'count')::int <> 2 then fails := fails || 'search by category name; '; end if;
  j := public.tick_flows(nov_from, nov_to, null, null, null, '%');          -- wildcard is literal
  if (j->>'count')::int <> 0 then fails := fails || 'like wildcard not escaped; '; end if;
  j := public.tick_flows(null, null);                                        -- all time includes October
  if (j->>'out')::bigint <> 51999 then fails := fails || 'all time; '; end if;

  -- Months: newest first, each with totals.
  j := public.tick_months();
  if jsonb_array_length(j) <> 2 or j->0->>'month' <> '2026-11-01' or (j->0->>'out')::bigint <> 51000 then fails := fails || format('months %s; ', j); end if;

  -- Keyset pages of 3 cover all 10 November rows exactly once, newest first, with day totals from the full filter.
  cur_at := null; cur_id := null; n := 0;
  loop
    r := public.tick_activity_page(nov_from, nov_to, null, null, null, null, false, false, cur_at, cur_id, 3);
    exit when jsonb_array_length(r->'rows') = 0;
    for j in select * from jsonb_array_elements(r->'rows') loop
      if (j->>'id')::uuid = any (seen) then fails := fails || 'duplicate row across pages; '; end if;
      if j ? 'user_id' then fails := fails || 'page leaks user_id; '; end if;
      seen := seen || (j->>'id')::uuid; n := n + 1;
      cur_at := (j->>'occurred_at')::timestamptz; cur_id := (j->>'id')::uuid;
    end loop;
    if n = 3 and (r->'day_totals'->>'2026-11-25')::bigint <> -3500 then fails := fails || format('day totals %s; ', r->'day_totals'); end if;
  end loop;
  if n <> 10 then fails := fails || format('paged %s rows, want 10; ', n); end if;

  -- Another user sees nothing through any of the functions.
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  j := public.tick_flows(null, null);
  if (j->>'count')::int <> 0 then fails := fails || 'B sees A totals; '; end if;
  r := public.tick_activity_page(null, null);
  if jsonb_array_length(r->'rows') <> 0 then fails := fails || 'B pages A rows; '; end if;
  if jsonb_array_length(public.tick_months()) <> 0 then fails := fails || 'B sees A months; '; end if;
  reset role;

  if fails <> '' then raise exception 'FLOWS_TESTS_FAILED: %', fails; end if;
  raise exception 'FLOWS_TESTS_PASSED';
end $$;
