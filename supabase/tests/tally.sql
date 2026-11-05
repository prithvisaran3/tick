-- Tally: balances, the atomic expense RPC, settlements, and attacks by another user. Always rolls back.
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); fails text := '';
  tx uuid; ga uuid; gb uuid; pk uuid; pj uuid; pb uuid; e1 uuid; n int; r record; j jsonb; st uuid;
begin
  insert into auth.users (id, aud, role, email) values (a, 'authenticated', 'authenticated', 'a@test.local'), (b, 'authenticated', 'authenticated', 'b@test.local');
  insert into public.people (user_id, name) values (a, 'Kaarthik') returning id into pk;
  insert into public.people (user_id, name) values (a, 'Jo') returning id into pj;
  insert into public.people (user_id, name) values (b, 'Bob''s friend') returning id into pb;
  insert into public.tally_groups (user_id, name, emoji) values (a, 'Roommates', '🏠') returning id into ga;
  insert into public.tally_groups (user_id, name) values (b, 'B group') returning id into gb;
  insert into public.tally_members (group_id, person_id, user_id) values (ga, pk, a), (ga, pj, a), (gb, pb, b);

  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  -- I pay $90 split equally three ways (me, Kaarthik, Jo): Kaarthik and Jo each owe me $30.
  e1 := public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Groceries', 'amount_cents', 9000, 'paid_by', null, 'split_type', 'equal',
        'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 3000), jsonb_build_object('person_id', pk, 'owed_cents', 3000), jsonb_build_object('person_id', pj, 'owed_cents', 3000))));
  select net_cents into n from public.tally_balances(a, ga) where person_id is null;  if n <> 6000 then fails := fails || format('my net %s, want 6000; ', n); end if;
  select net_cents into n from public.tally_balances(a, ga) where person_id = pk;     if n <> -3000 then fails := fails || format('kaarthik net %s, want -3000; ', n); end if;
  j := public.tally_owed_to_me();                                                      if (j->>'owed_to_me')::bigint <> 6000 or (j->>'i_owe')::bigint <> 0 then fails := fails || format('owed_to_me %s; ', j); end if;

  -- Kaarthik pays $40 dinner, split between him and me 50/50 in exact amounts: I owe him $20.
  perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Dinner', 'amount_cents', 4000, 'paid_by', pk, 'split_type', 'exact',
        'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 2000), jsonb_build_object('person_id', pk, 'owed_cents', 2000))));
  select net_cents into n from public.tally_balances(a, ga) where person_id = pk;     if n <> -1000 then fails := fails || format('kaarthik net after dinner %s, want -1000; ', n); end if;

  -- A Zelle from Kaarthik for $10 settles him: balance goes to 0 (a row with zero net disappears). A pending "I paid" does NOT count yet.
  insert into public.tally_settlements (group_id, from_person, to_person, amount_cents, method, status) values (ga, pk, null, 500, 'zelle', 'pending');
  select count(*) into n from public.tally_balances(a, ga) where person_id = pk and net_cents = -1000;   if n <> 1 then fails := fails || 'pending settlement changed the balance; '; end if;
  update public.tally_settlements set status = 'confirmed' where status = 'pending';
  select net_cents into n from public.tally_balances(a, ga) where person_id = pk;     if n <> -500 then fails := fails || format('after $5 settle %s, want -500; ', n); end if;
  insert into public.tally_settlements (group_id, from_person, to_person, amount_cents, method) values (ga, pk, null, 500, 'cash');
  select count(*) into n from public.tally_balances(a, ga) where person_id = pk;      if n <> 0 then fails := fails || 'settled person still has a balance; '; end if;

  -- Deleting an expense (soft) removes it from balances.
  update public.tally_expenses set deleted_at = now() where id = e1;
  select count(*) into n from public.tally_balances(a, ga) where person_id = pj;       if n <> 0 then fails := fails || 'deleted expense still counted; '; end if;

  select count(*) into n from public.audit_log where user_id = a and event = 'tally_edit'; if n < 2 then fails := fails || format('tally edits not audited (%s); ', n); end if;

  -- Validation: shares must sum to the amount; sharers must be members; the payer must be a member.
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 1000, 'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 999))));
    fails := fails || 'shares not summing to the amount accepted; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 1000, 'shares', jsonb_build_array(jsonb_build_object('person_id', pb, 'owed_cents', 1000))));
    fails := fails || 'a stranger accepted as a sharer; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 1000, 'paid_by', pb, 'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 1000))));
    fails := fails || 'a stranger accepted as the payer; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 0, 'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 0))));
    fails := fails || 'a zero expense accepted; '; exception when check_violation then null; end;

  -- Editing keeps ONE expense and replaces its shares.
  perform public.tally_save_expense(jsonb_build_object('id', e1, 'group_id', ga, 'description', 'Groceries (edited)', 'amount_cents', 6000, 'split_type', 'equal',
        'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 3000), jsonb_build_object('person_id', pj, 'owed_cents', 3000))));
  select count(*) into n from public.tally_shares where expense_id = e1;                if n <> 2 then fails := fails || format('edit left %s shares; ', n); end if;

  -- a confirmed settlement linked to a bank row turns that row into a settlement (excluded), and rejecting it restores the row
  reset role; insert into public.transactions (user_id, amount_cents, occurred_at, merchant_raw) values (a, 6000, now(), 'Zelle from Kaarthik') returning id into tx;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true); set local role authenticated;
  insert into public.tally_settlements (group_id, from_person, to_person, amount_cents, transaction_id) values (ga, pk, null, 6000, tx) returning id into st;
  select count(*) into n from public.transactions where id = tx and flow = 'settlement';  if n <> 1 then fails := fails || 'settlement does not mark the row; '; end if;
  update public.tally_settlements set status = 'rejected' where id = st;
  select count(*) into n from public.transactions where id = tx and flow is null;          if n <> 1 then fails := fails || 'reject does not restore the row; '; end if;
  delete from public.tally_settlements where id = st;

  -- ---------- user B attacks ----------
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  -- B cannot link their expense/settlement to A's transaction (composite FK)
  reset role; insert into public.transactions (user_id, amount_cents, occurred_at) values (a, -100, now()) returning id into tx;
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true); set local role authenticated;
  begin insert into public.tally_expenses (group_id, description, amount_cents, transaction_id) values (gb, 'X', 100, tx); fails := fails || 'B links expense to A txn; ';
  exception when foreign_key_violation then null; end;
  select count(*) into n from public.tally_groups where id = ga;                         if n <> 0 then fails := fails || 'B reads A group; '; end if;
  select count(*) into n from public.tally_expenses;                                     if n <> 0 then fails := fails || 'B reads A expenses; '; end if;
  select count(*) into n from public.tally_balances(a);                                  if n <> 0 then fails := fails || 'B reads A balances; '; end if;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'X', 'amount_cents', 100, 'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 100))));
    fails := fails || 'B writes into A group; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('id', e1, 'group_id', gb, 'description', 'X', 'amount_cents', 100, 'shares', jsonb_build_array(jsonb_build_object('person_id', null, 'owed_cents', 100))));
    fails := fails || 'B edits A expense; '; exception when raise_exception then null; end;
  begin insert into public.tally_members (group_id, person_id, user_id) values (gb, pk, b); fails := fails || 'B put A person in own group; '; exception when foreign_key_violation or insufficient_privilege then null; end;
  begin insert into public.tally_members (group_id, person_id, user_id) values (ga, pb, b); fails := fails || 'B put own person in A group; '; exception when foreign_key_violation or insufficient_privilege then null; end;
  begin insert into public.tally_settlements (group_id, from_person, amount_cents) values (ga, pb, 100); fails := fails || 'B settled in A group; '; exception when foreign_key_violation or insufficient_privilege or check_violation then null; end;
  begin insert into public.tally_links (user_id, group_id, token_hash, expires_at) values (b, gb, 'x', now() + interval '1 day'); fails := fails || 'app minted a share link; ';
  exception when insufficient_privilege then null; end;
  update public.tally_settlements set status = 'confirmed' where group_id = ga; get diagnostics n = row_count;   if n <> 0 then fails := fails || 'B confirms A settlements; '; end if;
  delete from public.tally_expenses where id = e1; get diagnostics n = row_count;        if n <> 0 then fails := fails || 'B deletes A expense; '; end if;
  reset role;

  -- anon sees nothing
  perform set_config('request.jwt.claims', '', true);
  set local role anon;
  begin select count(*) into n from public.tally_expenses; if n <> 0 then fails := fails || 'anon reads expenses; '; end if; exception when insufficient_privilege then null; end;
  begin perform public.tally_balances(a); fails := fails || 'anon calls tally_balances; '; exception when insufficient_privilege then null; end;
  reset role;

  if fails <> '' then raise exception 'TALLY_TESTS_FAILED: %', fails; end if;
  raise exception 'TALLY_TESTS_PASSED';
end $$;
