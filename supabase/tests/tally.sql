-- Tally: balances, the atomic expense RPC, settlements, soft delete, and attacks by a stranger. Always rolls back. Sharing is in tally_shared.sql.
do $$
declare
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); fails text := '';
  tx uuid; ga uuid; gb uuid; mk uuid; mj uuid; mb uuid; ma uuid; e1 uuid; n int; j jsonb; st uuid;
begin
  insert into auth.users (id, aud, role, email) values (a, 'authenticated', 'authenticated', 'a@test.local'), (b, 'authenticated', 'authenticated', 'b@test.local');
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true); set local role authenticated;
  gb := public.tally_create_group(jsonb_build_object('name', 'B group'));
  mb := public.tally_add_guest(gb, 'Bob''s friend');
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  ga := public.tally_create_group(jsonb_build_object('name', 'Roommates', 'emoji', '🏠'));
  mk := public.tally_add_guest(ga, 'Kaarthik');
  mj := public.tally_add_guest(ga, 'Jo');
  ma := public.tally_my_member(ga);

  -- I pay $90 split equally three ways: Kaarthik and Jo each owe me $30.
  e1 := public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Groceries', 'amount_cents', 9000, 'paid_by', null, 'split_type', 'equal',
        'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 3000), jsonb_build_object('member_id', mk, 'owed_cents', 3000), jsonb_build_object('member_id', mj, 'owed_cents', 3000))));
  select net_cents into n from public.tally_balances(a, ga) where member_id = ma;  if n <> 6000 then fails := fails || format('my net %s, want 6000; ', n); end if;
  select net_cents into n from public.tally_balances(a, ga) where member_id = mk;  if n <> -3000 then fails := fails || format('kaarthik net %s, want -3000; ', n); end if;
  j := public.tally_owed_to_me();                                                   if (j->>'owed_to_me')::bigint <> 6000 or (j->>'i_owe')::bigint <> 0 then fails := fails || format('owed_to_me %s; ', j); end if;

  -- Kaarthik pays $40 dinner, 50/50 with me: I owe him $20.
  perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Dinner', 'amount_cents', 4000, 'paid_by', mk, 'split_type', 'exact',
        'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 2000), jsonb_build_object('member_id', mk, 'owed_cents', 2000))));
  select net_cents into n from public.tally_balances(a, ga) where member_id = mk;  if n <> -1000 then fails := fails || format('kaarthik net after dinner %s, want -1000; ', n); end if;

  -- Settling: a pending "I paid" does not count until it is confirmed; zero nets disappear.
  insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, method, status, created_by) values (ga, mk, ma, 500, 'zelle', 'pending', a);
  select count(*) into n from public.tally_balances(a, ga) where member_id = mk and net_cents = -1000;   if n <> 1 then fails := fails || 'pending settlement changed the balance; '; end if;
  update public.tally_settlements set status = 'confirmed' where status = 'pending';
  select net_cents into n from public.tally_balances(a, ga) where member_id = mk;  if n <> -500 then fails := fails || format('after $5 settle %s, want -500; ', n); end if;
  insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, method, created_by) values (ga, mk, ma, 500, 'cash', a);
  select count(*) into n from public.tally_balances(a, ga) where member_id = mk;   if n <> 0 then fails := fails || 'settled person still has a balance; '; end if;

  -- A soft delete leaves balances, and undo puts it back.
  update public.tally_expenses set deleted_at = now() where id = e1;
  select count(*) into n from public.tally_balances(a, ga) where member_id = mj;   if n <> 0 then fails := fails || 'deleted expense still counted; '; end if;
  update public.tally_expenses set deleted_at = null where id = e1;
  select net_cents into n from public.tally_balances(a, ga) where member_id = mj;  if n <> -3000 then fails := fails || 'undo did not restore; '; end if;
  update public.tally_expenses set deleted_at = now() where id = e1;
  select count(*) into n from public.audit_log where user_id = a and event = 'tally_edit'; if n < 2 then fails := fails || format('tally edits not audited (%s); ', n); end if;

  -- Validation.
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 1000, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 999))));
    fails := fails || 'shares not summing to the amount accepted; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 1000, 'shares', jsonb_build_array(jsonb_build_object('member_id', mb, 'owed_cents', 1000))));
    fails := fails || 'a stranger accepted as a sharer; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 1000, 'paid_by', mb, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 1000))));
    fails := fails || 'a stranger accepted as the payer; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'Bad', 'amount_cents', 0, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 0))));
    fails := fails || 'a zero expense accepted; '; exception when check_violation then null; end;

  -- Editing keeps ONE expense and replaces its shares. A deleted one can't be edited.
  update public.tally_expenses set deleted_at = null where id = e1;
  perform public.tally_save_expense(jsonb_build_object('id', e1, 'group_id', ga, 'description', 'Groceries (edited)', 'amount_cents', 6000, 'split_type', 'equal',
        'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 3000), jsonb_build_object('member_id', mj, 'owed_cents', 3000))));
  select count(*) into n from public.tally_shares where expense_id = e1;           if n <> 2 then fails := fails || format('edit left %s shares; ', n); end if;

  -- A confirmed settlement linked to a bank row turns that row into a settlement (excluded); rejecting restores it.
  reset role; insert into public.transactions (user_id, amount_cents, occurred_at, merchant_raw) values (a, 6000, now(), 'Zelle from Kaarthik') returning id into tx;
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true); set local role authenticated;
  insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, transaction_id, created_by) values (ga, mk, ma, 6000, tx, a) returning id into st;
  select count(*) into n from public.transactions where id = tx and flow = 'settlement';  if n <> 1 then fails := fails || 'settlement does not mark the row; '; end if;
  update public.tally_settlements set status = 'rejected' where id = st;
  select count(*) into n from public.transactions where id = tx and flow is null;          if n <> 1 then fails := fails || 'reject does not restore the row; '; end if;

  -- Nobody hard deletes, not even the owner.
  begin delete from public.tally_expenses where id = e1; fails := fails || 'owner hard deleted an expense; '; exception when insufficient_privilege then null; end;
  begin update public.tally_expenses set amount_cents = 1 where id = e1; fails := fails || 'amount changed without its shares; '; exception when insufficient_privilege then null; end;

  -- ---------- user B attacks ----------
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);
  begin insert into public.tally_expenses (group_id, description, amount_cents, paid_by_member, transaction_id, created_by) values (gb, 'X', 100, mb, tx, b); fails := fails || 'B links expense to A txn; ';
  exception when foreign_key_violation then null; end;
  select count(*) into n from public.tally_groups where id = ga;                     if n <> 0 then fails := fails || 'B reads A group; '; end if;
  select count(*) into n from public.tally_expenses where group_id = ga;             if n <> 0 then fails := fails || 'B reads A expenses; '; end if;
  select count(*) into n from public.tally_balances(a);                              if n <> 0 then fails := fails || 'B reads A balances; '; end if;
  select count(*) into n from public.tally_net(ga);                                  if n <> 0 then fails := fails || 'B reads A nets; '; end if;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', ga, 'description', 'X', 'amount_cents', 100, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 100))));
    fails := fails || 'B writes into A group; '; exception when raise_exception then null; end;
  begin perform public.tally_save_expense(jsonb_build_object('id', e1, 'group_id', gb, 'description', 'X', 'amount_cents', 100, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 100))));
    fails := fails || 'B edits A expense; '; exception when raise_exception then null; end;
  begin perform public.tally_add_guest(ga, 'Sneaky'); fails := fails || 'B added a guest to A group; '; exception when raise_exception then null; end;
  begin insert into public.tally_members (group_id, user_id, name) values (ga, b, 'x'); fails := fails || 'B wrote a member row; '; exception when insufficient_privilege then null; end;
  begin insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, created_by) values (ga, mk, ma, 100, b); fails := fails || 'B settled in A group; '; exception when insufficient_privilege then null; end;
  begin insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, created_by) values (gb, mk, ma, 100, b); fails := fails || 'B settled with A members; '; exception when foreign_key_violation then null; end;
  begin insert into public.tally_links (user_id, group_id, token_hash, expires_at) values (b, gb, 'x', now() + interval '1 day'); fails := fails || 'app minted a share link; ';
  exception when insufficient_privilege then null; end;
  update public.tally_settlements set status = 'confirmed' where group_id = ga; get diagnostics n = row_count;   if n <> 0 then fails := fails || 'B confirms A settlement; '; end if;
  update public.tally_expenses set deleted_at = now() where id = e1; get diagnostics n = row_count;              if n <> 0 then fails := fails || 'B deletes A expense; '; end if;
  reset role;

  -- anon sees nothing
  perform set_config('request.jwt.claims', '', true);
  set local role anon;
  begin select count(*) into n from public.tally_expenses; if n <> 0 then fails := fails || 'anon reads expenses; '; end if; exception when insufficient_privilege then null; end;
  begin perform public.tally_balances(a); fails := fails || 'anon calls tally_balances; '; exception when insufficient_privilege then null; end;
  begin perform public.is_tally_member(ga); fails := fails || 'anon calls is_tally_member; '; exception when insufficient_privilege then null; end;
  reset role;

  -- Splitwise import: one call, one group, and a repeat adds nothing.
  j := '{"group":{"name":"Trip","import_key":"splitwise:k"},"people":["Asha"],"expenses":[{"ref":"splitwise:1:0","description":"Fuel","category":"Gas","spent_on":"2026-09-01","amount_cents":1000,"paid_by":null,"shares":[{"person":null,"owed_cents":500},{"person":"Asha","owed_cents":500}]}],"settlements":[{"ref":"splitwise:2:0","from":"Asha","to":null,"amount_cents":200,"on":"2026-09-02"}]}'::jsonb;
  j := public.tally_import_splitwise(a, null, j);
  if (j->>'expenses')::int <> 1 or (j->>'settlements')::int <> 1 then fails := fails || format('import %s; ', j); end if;
  select net_cents into n from public.tally_balances(a, (j->>'group_id')::uuid) b join public.tally_members m on m.id = b.member_id where m.role = 'owner';
  if n <> 300 then fails := fails || format('import balance %s; ', n); end if;
  j := public.tally_import_splitwise(a, null, '{"group":{"name":"Trip","import_key":"splitwise:k"},"people":["Asha"],"expenses":[{"ref":"splitwise:1:0","description":"Fuel","category":"Gas","spent_on":"2026-09-01","amount_cents":1000,"paid_by":null,"shares":[{"person":null,"owed_cents":500},{"person":"Asha","owed_cents":500}]}],"settlements":[{"ref":"splitwise:2:0","from":"Asha","to":null,"amount_cents":200,"on":"2026-09-02"}]}'::jsonb);
  if (j->>'expenses')::int <> 0 or (j->>'settlements')::int <> 0 then fails := fails || format('re-import %s; ', j); end if;

  if fails <> '' then raise exception 'TALLY_TESTS_FAILED: %', fails; end if;
  raise exception 'TALLY_TESTS_PASSED';
end $$;
