-- Plan v5: paycheck splits, balances, goals, planned one-offs, suggestions. Math vectors come from api/tests/data/*.json. Always rolls back.
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); fails text := ''; chk uuid; sav uuid; other uuid; n int;
begin
  insert into auth.users (id, aud, role, email) values (a, 'authenticated', 'authenticated', 'a@test.local'), (b, 'authenticated', 'authenticated', 'b@test.local');
  insert into public.accounts (user_id, name, type) values (a, 'Chase', 'checking') returning id into chk;
  insert into public.accounts (user_id, name, type) values (a, 'SoFi', 'savings') returning id into sav;
  insert into public.accounts (user_id, name, type) values (b, 'Theirs', 'checking') returning id into other;
  -- ---------- phase 2: splits ----------
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(247707, '[]'::jsonb)), '{}') <> '{}'::bigint[] then fails := fails || 'split no splits; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(247707, '[{"kind": "rest", "value": 0}]'::jsonb)), '{}') <> '{247707}'::bigint[] then fails := fails || 'split rest only; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(247707, '[{"kind": "fixed", "value": 50000}, {"kind": "rest", "value": 0}]'::jsonb)), '{}') <> '{50000,197707}'::bigint[] then fails := fails || 'split fixed then rest; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(247707, '[{"kind": "percent", "value": 3333}, {"kind": "rest", "value": 0}]'::jsonb)), '{}') <> '{82560,165147}'::bigint[] then fails := fails || 'split percent floors, rest takes the cent; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(100000, '[{"kind": "rest", "value": 0}, {"kind": "percent", "value": 1000}, {"kind": "fixed", "value": 25000}]'::jsonb)), '{}') <> '{65000,10000,25000}'::bigint[] then fails := fails || 'split rest listed first still gets what is left; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(30000, '[{"kind": "fixed", "value": 50000}, {"kind": "percent", "value": 5000}, {"kind": "rest", "value": 0}]'::jsonb)), '{}') <> '{30000,0,0}'::bigint[] then fails := fails || 'split fixed bigger than the paycheck is capped; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(100000, '[{"kind": "fixed", "value": 60000}, {"kind": "percent", "value": 5000}, {"kind": "rest", "value": 0}]'::jsonb)), '{}') <> '{60000,40000,0}'::bigint[] then fails := fails || 'split percent of the whole net, capped by what fixed left; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(247707, '[{"kind": "fixed", "value": 50000}, {"kind": "percent", "value": 1000}, {"kind": "rest", "value": 0}]'::jsonb)), '{}') <> '{50000,24770,172937}'::bigint[] then fails := fails || 'split three accounts; '; end if;
  if coalesce((select array_agg(cents order by idx) from public.pay_split_amounts(99999, '[{"kind": "percent", "value": 10000}, {"kind": "rest", "value": 0}]'::jsonb)), '{}') <> '{99999,0}'::bigint[] then fails := fails || 'split 100 percent leaves the rest nothing; '; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true); set local role authenticated;
  perform public.save_pay_splits(jsonb_build_array(jsonb_build_object('account_id', sav, 'kind', 'fixed', 'value', 50000), jsonb_build_object('account_id', chk, 'kind', 'rest', 'value', 0)));
  if (select count(*) from public.pay_splits) <> 2 then fails := fails || 'A cannot read own splits; '; end if;
  begin perform public.save_pay_splits(jsonb_build_array(jsonb_build_object('account_id', sav, 'kind', 'fixed', 'value', 50000))); fails := fails || 'saved without a rest line; ';
  exception when invalid_parameter_value then null; end;
  begin perform public.save_pay_splits(jsonb_build_array(jsonb_build_object('account_id', chk, 'kind', 'rest', 'value', 0), jsonb_build_object('label', 'Other', 'kind', 'rest', 'value', 0))); fails := fails || 'two rest lines; ';
  exception when invalid_parameter_value then null; end;
  begin perform public.save_pay_splits(jsonb_build_array(jsonb_build_object('account_id', sav, 'kind', 'percent', 'value', 6000), jsonb_build_object('label', 'Other', 'kind', 'percent', 'value', 5000), jsonb_build_object('account_id', chk, 'kind', 'rest', 'value', 0))); fails := fails || 'percents over 100; ';
  exception when invalid_parameter_value then null; end;
  begin perform public.save_pay_splits(jsonb_build_array(jsonb_build_object('account_id', other, 'kind', 'rest', 'value', 0))); fails := fails || 'split into someone else''s account; ';
  exception when insufficient_privilege then null; end;
  begin insert into public.pay_splits (user_id, label, kind, value) values (a, 'Sneaky', 'fixed', 1); fails := fails || 'app wrote a split row directly; ';
  exception when insufficient_privilege then null; end;
  if (select count(*) from public.pay_splits) <> 2 then fails := fails || 'a refused save changed the splits; '; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  if (select count(*) from public.pay_splits) <> 0 then fails := fails || 'B reads A splits; '; end if;
  perform public.save_pay_splits('[]'::jsonb);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  if (select count(*) from public.pay_splits) <> 2 then fails := fails || 'B cleared A splits; '; end if;
  reset role;
  -- ---------- phase 3: balances, goals, moves ----------
  insert into public.account_balances (user_id, account_id, day, balance_cents) values (a, sav, '2026-11-14', 500000), (b, other, '2026-11-14', 1);
  insert into public.goal_moves (user_id, pay_date, cents, balance_before_cents) values (a, '2026-11-13', 150000, 500000);
  begin insert into public.goal_moves (user_id, pay_date, cents, balance_before_cents) values (a, '2026-11-13', 1, 1); fails := fails || 'two moves for one payday; ';
  exception when unique_violation then null; end;
  if (select count(*) from public.paydays_between('{"frequency": "biweekly", "next_date": "2026-11-27"}'::jsonb, '2026-11-15', '2027-02-15')) <> 6 then
    fails := fails || format('paydays in 3 months: %s; ', (select array_agg(d) from public.paydays_between('{"frequency": "biweekly", "next_date": "2026-11-27"}'::jsonb, '2026-11-15', '2027-02-15') d)); end if;
  if (select count(*) from public.paydays_between('{"frequency": "biweekly", "next_date": "2026-11-27"}'::jsonb, '2026-11-27', '2026-11-27')) <> 0 then fails := fails || 'paydays_between includes its start; '; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true); set local role authenticated;
  if (select count(*) from public.account_balances) <> 1 or (select count(*) from public.goal_moves) <> 1 then fails := fails || 'A reads own balances and moves; '; end if;
  begin insert into public.account_balances (user_id, account_id, day, balance_cents) values (a, sav, '2026-11-15', 9); fails := fails || 'app wrote a balance; ';
  exception when insufficient_privilege then null; end;
  begin update public.goal_moves set status = 'confirmed'; fails := fails || 'app confirmed its own move; ';
  exception when insufficient_privilege then null; end;
  insert into public.goals (name, target_cents, mode, start_cents, account_ids, due_date) values ('Move', 900000, 'save_more', 500000, array[sav], '2027-02-15');
  begin insert into public.goals (name, target_cents, mode) values ('Bad', 1, 'someday'); fails := fails || 'unknown goal mode; ';
  exception when check_violation then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  if (select count(*) from public.account_balances) <> 1 or (select count(*) from public.goal_moves) <> 0 or (select count(*) from public.goals) <> 0 then fails := fails || 'B reads A balances, moves or goals; '; end if;
  reset role;
  -- ---------- phase 4: planned one-offs ----------
  declare pe uuid; tb uuid; begin
    insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw) values (b, other, -50000, '2026-11-20 15:00Z', 'Theirs') returning id into tb;
    perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true); set local role authenticated;
    insert into public.planned_expenses (name, amount_cents, due) values ('Birthday gift', 50000, '2026-11-22') returning id into pe;
    begin update public.planned_expenses set matched_txn = tb, status = 'matched' where id = pe; fails := fails || 'matched to someone else''s transaction; ';
    exception when insufficient_privilege then null; end;
    begin insert into public.planned_expenses (name, amount_cents, due) values ('Free', 0, '2026-11-22'); fails := fails || 'a zero planned expense; ';
    exception when check_violation then null; end;
    perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
    if (select count(*) from public.planned_expenses) <> 0 then fails := fails || 'B reads A planned; '; end if;
    update public.planned_expenses set status = 'dismissed' where id = pe;
    begin insert into public.planned_expenses (user_id, name, amount_cents, due) values (a, 'Planted', 100, '2026-11-22'); fails := fails || 'B planned an expense for A; ';
    exception when insufficient_privilege then null; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
    if (select status from public.planned_expenses where id = pe) <> 'planned' then fails := fails || 'B changed A planned; '; end if;
    reset role;
  end;
  -- ---------- more phases append above this line ----------
  if fails <> '' then raise exception 'PLAN_V5_TESTS_FAILED: %', fails; end if;
  raise exception 'PLAN_V5_TESTS_PASSED';
end $$;
