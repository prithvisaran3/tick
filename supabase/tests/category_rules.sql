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
  -- removing the rule puts rows back
  delete from public.category_rules where id = rule;
  perform public.tick_apply_category_rules(a);
  select category_id into c from public.transactions where id = t_drift;
  if fails <> '' then raise exception 'RULES_TESTS_FAILED: %', fails; end if;
  raise exception 'RULES_TESTS_PASSED';
end $$;
