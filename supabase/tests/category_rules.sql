-- Rent vs settle-up to the same person, drift, late rent, manual edits, and isolation. Always rolls back.
do $$
declare a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); fails text := ''; rent uuid; ff uuid; rule uuid; acct uuid; n int;
  t_rent uuid; t_settle uuid; t_drift uuid; t_late uuid; t_small uuid; t_other uuid; t_edit uuid; t_wrap uuid; c uuid;
begin
  insert into auth.users (id, aud, role, email) values (a, 'authenticated', 'authenticated', 'a@test.local'), (b, 'authenticated', 'authenticated', 'b@test.local');
  select id into rent from public.categories where user_id = a and name = 'Rent';
  select id into ff from public.categories where user_id = a and name = 'Friends and family';
  insert into public.accounts (user_id, name, type) values (a, 'Chase', 'checking') returning id into acct;
  if public.tick_p2p_person('Zelle payment to KAARTHIK ROSHAN 31446078428') <> 'kaarthik roshan' then fails := fails || 'person; '; end if;
  if public.tick_p2p_person('Zelle® Payment to K. Roshan JPM99cr1tlu9') <> 'k roshan' then fails := fails || 'initial person; '; end if;
  insert into public.category_rules (user_id, person_key, aliases, amount_cents, day_of_month, category_id) values (a, 'kaarthik roshan', array['k roshan'], 120000, 1, rent) returning id into rule;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -120000, '2026-10-01 15:00Z', 'Zelle payment to KAARTHIK ROSHAN 1', ff) returning id into t_rent;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -4500, '2026-10-02 15:00Z', 'Zelle payment to KAARTHIK ROSHAN 2', ff) returning id into t_settle;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -128000, '2026-09-01 15:00Z', 'Zelle payment to K ROSHAN 3', ff) returning id into t_drift;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -120000, '2026-08-05 15:00Z', 'Zelle payment to KAARTHIK ROSHAN 4', ff) returning id into t_late;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -120000, '2026-07-30 15:00Z', 'Zelle payment to KAARTHIK ROSHAN 5', ff) returning id into t_wrap;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -120000, '2026-10-15 15:00Z', 'Zelle payment to KAARTHIK ROSHAN 6', ff) returning id into t_small;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -120000, '2026-10-01 15:00Z', 'Zelle payment to KAARTHIK KUMAR 7', ff) returning id into t_other;
  insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id, user_edited) values (a, acct, -120000, '2026-06-01 15:00Z', 'Zelle payment to KAARTHIK ROSHAN 8', ff, array['category']) returning id into t_edit;
  perform public.tick_apply_category_rules(a);
  select category_id into c from public.transactions where id = t_rent;   if c <> rent then fails := fails || 'rent not rent; '; end if;
  select category_id into c from public.transactions where id = t_settle; if c <> ff then fails := fails || 'settle-up became rent; '; end if;
  select category_id into c from public.transactions where id = t_drift;  if c <> rent then fails := fails || 'drift in band missed; '; end if;
  select category_id into c from public.transactions where id = t_late;   if c <> rent then fails := fails || 'late rent missed; '; end if;
  select category_id into c from public.transactions where id = t_wrap;   if c <> rent then fails := fails || 'month-end wrap missed; '; end if;
  select category_id into c from public.transactions where id = t_small;  if c <> ff then fails := fails || 'rent amount off the day became rent; '; end if;
  select category_id into c from public.transactions where id = t_other;  if c <> ff then fails := fails || 'another Kaarthik became rent; '; end if;
  select category_id into c from public.transactions where id = t_edit;   if c <> ff then fails := fails || 'manual edit overwritten; '; end if;
  -- a re-sync: a person moves a rule row by hand, the rules re-run, the hand edit stays
  update public.transactions set category_id = ff, user_edited = array['category'] where id = t_rent;
  perform public.tick_apply_category_rules(a);
  perform public.tick_apply_category_rules(a);
  select category_id into c from public.transactions where id = t_rent;   if c <> ff then fails := fails || 'manual override lost on re-sync; '; end if;
  -- rent is real spending; the settle-up stays out with friends
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true); set local role authenticated;
  if (select out_c from public.tick_classified(a, null, null) where id = t_drift) <> 128000 then fails := fails || 'rent not counted; '; end if;
  if (select out_c from public.tick_classified(a, null, null) where id = t_settle) <> 0 then fails := fails || 'settle-up counted; '; end if;
  begin perform public.tick_apply_category_rules(a); fails := fails || 'app can apply rules; '; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  select count(*) into n from public.category_rules;                       if n <> 0 then fails := fails || 'B reads A rules; '; end if;
  begin insert into public.category_rules (user_id, person_key, ignored) values (a, 'x', true); fails := fails || 'B wrote A rule; '; exception when insufficient_privilege then null; end;
  reset role;
  -- Splitwise: out of the totals like friends; a matched charge counts my share only
  declare sw uuid; t1 uuid; t2 uuid; begin
    select id into sw from public.categories where user_id = a and name = 'Splitwise';
    if sw is null then fails := fails || 'no Splitwise category; '; end if;
    insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, category_id) values (a, acct, -4500, '2026-10-03 15:00Z', 'Zelle payment to ASHA', sw) returning id into t1;
    insert into public.transactions (user_id, account_id, amount_cents, occurred_at, merchant_raw, shared_cents) values (a, acct, -9000, '2026-10-03 15:00Z', 'Dishoom', 6000) returning id into t2;
    if (select out_c from public.tick_classified(a, null, null) where id = t1) <> 0 then fails := fails || 'Splitwise counted; '; end if;
    if (select friends_c from public.tick_classified(a, null, null) where id = t1) <> -4500 then fails := fails || 'Splitwise not in friends net; '; end if;
    if (select out_c from public.tick_classified(a, null, null) where id = t2) <> 3000 then fails := fails || 'my share wrong; '; end if;
  end;
  -- pay statements: owner reads and deletes, nobody writes from the app, nobody else sees them
  declare ps uuid; begin
    insert into public.pay_statements (user_id, employer, pay_date, gross_cents, taxes_cents, deductions_cents, net_cents, source) values (a, 'ACME', '2026-11-13', 100, 10, 10, 80, 'adp') returning id into ps;
    insert into public.pay_statement_lines (statement_id, user_id, kind, label, cents) values (ps, a, 'tax', 'Federal', 10);
    begin insert into public.pay_statements (user_id, employer, pay_date, gross_cents, taxes_cents, deductions_cents, net_cents, source) values (a, 'ACME', '2026-11-13', 100, 10, 10, 80, 'adp'); fails := fails || 'duplicate statement; ';
    exception when unique_violation then null; end;
    perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true); set local role authenticated;
    if (select count(*) from public.pay_statements) + (select count(*) from public.pay_statement_lines) <> 0 then fails := fails || 'B reads A pay; '; end if;
    begin insert into public.pay_statements (user_id, employer, pay_date, gross_cents, taxes_cents, deductions_cents, net_cents, source) values (b, 'X', '2026-11-13', 1, 0, 0, 1, 'adp'); fails := fails || 'app wrote a statement; ';
    exception when insufficient_privilege then null; end;
    perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
    if (select count(*) from public.pay_statement_lines) <> 1 then fails := fails || 'A cannot read own lines; '; end if;
    delete from public.pay_statements where id = ps;
    if (select count(*) from public.pay_statement_lines) <> 0 then fails := fails || 'lines outlived the statement; '; end if;
    reset role;
  end;
  -- removing the rule puts rows back
  delete from public.category_rules where id = rule;
  perform public.tick_apply_category_rules(a);
  select category_id into c from public.transactions where id = t_drift;
  if fails <> '' then raise exception 'RULES_TESTS_FAILED: %', fails; end if;
  raise exception 'RULES_TESTS_PASSED';
end $$;
