-- Shared groups: is_tally_member, member vs stranger, creator vs owner rights, leaving and removal, search, invites, activity. Always rolls back.
do $$
declare
  o uuid := gen_random_uuid(); m uuid := gen_random_uuid(); m2 uuid := gen_random_uuid(); x uuid := gen_random_uuid(); hid uuid := gen_random_uuid();
  fails text := ''; g uuid; mo uuid; mm uuid; mm2 uuid; guest uuid; e_m uuid; e_o uuid; st uuid; inv uuid; n int; t text; j jsonb; r record; txm uuid;
begin
  insert into auth.users (id, aud, role, email) values (o, 'authenticated', 'authenticated', 'owner@test.local'), (m, 'authenticated', 'authenticated', 'mem@test.local'),
    (m2, 'authenticated', 'authenticated', 'mem2@test.local'), (x, 'authenticated', 'authenticated', 'x@test.local'), (hid, 'authenticated', 'authenticated', 'hid@test.local');
  update public.profiles set display_name = 'Olive Owner', handle = 'olive' where user_id = o;
  update public.profiles set display_name = 'Mina Member', handle = 'mina', phone = '+15551234567' where user_id = m;
  update public.profiles set display_name = 'Max Member', handle = 'mina_two' where user_id = m2;
  update public.profiles set display_name = 'Xander', handle = 'xander' where user_id = x;
  update public.profiles set display_name = 'Hidden', handle = 'minah', phone = '+15559999999', discoverable = false where user_id = hid;

  -- ---- search, as the API calls it ----
  select count(*) into n from public.tally_search_people(o, 'min');            if n <> 2 then fails := fails || format('prefix found %s, want 2 (hidden stays out); ', n); end if;
  select count(*) into n from public.tally_search_people(o, 'mi');             if n <> 0 then fails := fails || 'two letters searched; '; end if;
  select count(*) into n from public.tally_search_people(o, '@mina');          if n <> 2 then fails := fails || 'handle with @ failed; '; end if;
  select handle into t from public.tally_search_people(o, 'mina') limit 1;     if t <> 'mina' then fails := fails || 'exact handle not first; '; end if;
  select count(*) into n from public.tally_search_people(o, 'mem@test.local'); if n <> 1 then fails := fails || 'exact email failed; '; end if;
  select count(*) into n from public.tally_search_people(o, 'MEM@TEST.LOCAL'); if n <> 1 then fails := fails || 'email case; '; end if;
  select count(*) into n from public.tally_search_people(o, 'mem@test');       if n <> 0 then fails := fails || 'partial email matched; '; end if;
  select count(*) into n from public.tally_search_people(o, '(555) 123-4567'); if n <> 1 then fails := fails || 'phone failed; '; end if;
  select count(*) into n from public.tally_search_people(o, '555123');         if n <> 0 then fails := fails || 'partial phone matched; '; end if;
  select count(*) into n from public.tally_search_people(o, 'minah');          if n <> 0 then fails := fails || 'hidden found by handle; '; end if;
  select count(*) into n from public.tally_search_people(o, 'hid@test.local'); if n <> 0 then fails := fails || 'hidden found by email; '; end if;
  select count(*) into n from public.tally_search_people(o, '+15559999999');   if n <> 0 then fails := fails || 'hidden found by phone; '; end if;
  select count(*) into n from public.tally_search_people(o, 'olive');          if n <> 0 then fails := fails || 'found myself; '; end if;
  select count(*) into n from public.tally_search_people(o, '%%%');            if n <> 0 then fails := fails || 'wildcard searched; '; end if;
  select count(*) into n from public.tally_search_people(o, '___');            if n <> 0 then fails := fails || 'underscore wildcard; '; end if;
  -- a claimed profile email is not an identity
  update public.profiles set email = 'mem@test.local' where user_id = x;
  select count(*) into n from public.tally_search_people(o, 'mem@test.local') s where s.handle = 'xander'; if n <> 0 then fails := fails || 'profile email claimed; '; end if;
  -- never more than five
  for i in 1..7 loop
    declare u uuid := gen_random_uuid(); begin
      insert into auth.users (id, aud, role, email) values (u, 'authenticated', 'authenticated', format('z%s@test.local', i));
      update public.profiles set handle = format('zed_%s', i) where user_id = u;
    end;
  end loop;
  select count(*) into n from public.tally_search_people(o, 'zed');            if n <> 5 then fails := fails || format('search returned %s; ', n); end if;

  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true); set local role authenticated;
  begin perform public.tally_search_people(x, 'mina'); fails := fails || 'app can search without the API; '; exception when insufficient_privilege then null; end;
  select count(*) into n from public.profiles;                                 if n <> 1 then fails := fails || format('profiles browsable: %s; ', n); end if;
  reset role;

  -- ---- a group with invites ----
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true); set local role authenticated;
  g := public.tally_create_group(jsonb_build_object('name', 'Flat', 'guests', jsonb_build_array(jsonb_build_object('name', 'Gia Guest', 'phone', '5550001111')), 'invite', jsonb_build_array(m)));
  mo := public.tally_my_member(g);
  select id into guest from public.tally_members where group_id = g and name = 'Gia Guest';
  if not public.is_tally_member(g) then fails := fails || 'owner is not a member; '; end if;
  begin perform public.tally_invite_user(g, hid, null); fails := fails || 'hidden user invited; '; exception when no_data_found then null; end;

  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  if public.is_tally_member(g) then fails := fails || 'invited counts as a member before accepting; '; end if;
  select count(*) into n from public.tally_groups where id = g;                if n <> 0 then fails := fails || 'pending invitee reads the group; '; end if;
  select id, group_name, inviter_name into r from public.tally_invites where invitee = m;
  if r.group_name <> 'Flat' or r.inviter_name <> 'Olive Owner' then fails := fails || 'invite text; '; end if;
  inv := r.id;
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  begin perform public.tally_invite_respond(inv, true); fails := fails || 'someone else accepted the invite; '; exception when no_data_found then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  mm := public.tally_invite_respond(inv, true);
  if not public.is_tally_member(g) then fails := fails || 'accepting did not join; '; end if;
  select count(*) into n from public.tally_groups where id = g;                if n <> 1 then fails := fails || 'member cannot read the group; '; end if;
  begin perform public.tally_invite_respond(inv, true); fails := fails || 'an invite accepted twice; '; exception when no_data_found then null; end;
  -- a member never sees a guest's phone, or the owner's people book
  select count(*) into n from public.people;                                   if n <> 0 then fails := fails || 'member reads the people book; '; end if;

  -- anyone can add
  e_m := public.tally_save_expense(jsonb_build_object('group_id', g, 'description', 'Mina paid', 'amount_cents', 3000, 'paid_by', null, 'shares',
         jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 1000), jsonb_build_object('member_id', mo, 'owed_cents', 1000), jsonb_build_object('member_id', guest, 'owed_cents', 1000))));
  select paid_by_member, created_by, user_id into r from public.tally_expenses where id = e_m;
  if r.paid_by_member <> mm or r.created_by <> m or r.user_id <> o then fails := fails || 'expense owner, creator or payer wrong; '; end if;
  -- null = me for each reader
  j := public.tally_owed_to_me();                                              if (j->>'owed_to_me')::bigint <> 2000 then fails := fails || format('member owed %s; ', j); end if;
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  j := public.tally_owed_to_me();                                              if (j->>'i_owe')::bigint <> 1000 then fails := fails || format('owner owes %s; ', j); end if;
  e_o := public.tally_save_expense(jsonb_build_object('group_id', g, 'description', 'Owner paid', 'amount_cents', 1000, 'paid_by', null, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 500), jsonb_build_object('member_id', mm, 'owed_cents', 500))));
  -- owner can edit and delete a member's expense
  perform public.tally_save_expense(jsonb_build_object('id', e_m, 'group_id', g, 'description', 'Mina paid', 'amount_cents', 3300, 'paid_by', mm, 'shares',
          jsonb_build_array(jsonb_build_object('member_id', mm, 'owed_cents', 1100), jsonb_build_object('member_id', mo, 'owed_cents', 1100), jsonb_build_object('member_id', guest, 'owed_cents', 1100))));
  update public.tally_expenses set deleted_at = now() where id = e_m; get diagnostics n = row_count; if n <> 1 then fails := fails || 'owner cannot delete; '; end if;
  update public.tally_expenses set deleted_at = null where id = e_m;

  -- a second member, not the creator: reads, but can't touch
  perform public.tally_invite_user(g, m2, null);
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  select id into inv from public.tally_invites where invitee = m2;
  mm2 := public.tally_invite_respond(inv, true);
  select count(*) into n from public.tally_expenses where group_id = g;        if n <> 2 then fails := fails || 'member cannot read expenses; '; end if;
  select count(*) into n from public.tally_shares;                             if n <> 5 then fails := fails || format('member reads %s shares; ', n); end if;
  update public.tally_expenses set deleted_at = now() where id = e_m; get diagnostics n = row_count; if n <> 0 then fails := fails || 'non-creator deleted; '; end if;
  begin perform public.tally_save_expense(jsonb_build_object('id', e_m, 'group_id', g, 'description', 'Hijack', 'amount_cents', 100, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 100))));
    fails := fails || 'non-creator edited; '; exception when insufficient_privilege then null; end;
  insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, created_by) values (g, mo, mm, 100, m2) returning id into st;
  begin insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, created_by) values (g, mo, mm, 100, o); fails := fails || 'created_by spoofed; '; exception when insufficient_privilege then null; end;

  -- editing a payment: its creator or the owner, nobody else
  perform public.tally_edit_settlement(st, 150, 'venmo');
  if (select amount_cents from public.tally_settlements where id = st) <> 150 then fails := fails || 'settlement edit; '; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  begin perform public.tally_edit_settlement(st, 1, 'cash'); fails := fails || 'non-creator edited a settlement; '; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  perform public.tally_edit_settlement(st, 100, 'venmo');

  -- creator can edit and delete their own
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  update public.tally_settlements set deleted_at = now() where id = st; get diagnostics n = row_count;  if n <> 0 then fails := fails || 'non-creator deleted a settlement; '; end if;
  update public.tally_expenses set deleted_at = now() where id = e_m; get diagnostics n = row_count;    if n <> 1 then fails := fails || 'creator cannot delete; '; end if;
  update public.tally_expenses set deleted_at = null where id = e_m;
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  update public.tally_settlements set deleted_at = now() where id = st; get diagnostics n = row_count;  if n <> 1 then fails := fails || 'settlement creator cannot delete; '; end if;

  -- owner-only powers
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  update public.tally_groups set name = 'Mine now' where id = g; get diagnostics n = row_count;         if n <> 0 then fails := fails || 'member renamed the group; '; end if;
  update public.tally_groups set deleted_at = now() where id = g; get diagnostics n = row_count;        if n <> 0 then fails := fails || 'member deleted the group; '; end if;
  begin perform public.tally_remove_member(mm2); fails := fails || 'member removed someone; '; exception when insufficient_privilege then null; end;
  begin update public.tally_groups set user_id = m where id = g; fails := fails || 'group ownership stolen; '; exception when insufficient_privilege then null; end;
  begin update public.tally_expenses set created_by = m2 where id = e_m; fails := fails || 'created_by rewritten; '; exception when insufficient_privilege then null; end;

  -- a bank row can only be linked by its owner
  reset role;
  insert into public.transactions (user_id, amount_cents, occurred_at, merchant_raw) values (o, -3000, now(), 'Owner card') returning id into txm;
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true); set local role authenticated;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', g, 'description', 'Link', 'amount_cents', 100, 'transaction_id', txm, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 100))));
    fails := fails || 'linked someone else''s bank row; '; exception when foreign_key_violation then null; end;

  -- leaving and removal need a zero balance, and say what is outstanding
  begin perform public.tally_leave_group(g); fails := fails || 'left with a balance; ';
  exception when raise_exception then if sqlerrm not like 'outstanding:%' then fails := fails || 'leave error: ' || sqlerrm || '; '; end if; end;
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  begin perform public.tally_remove_member(mm); fails := fails || 'removed with a balance; ';
  exception when raise_exception then if sqlerrm not like 'outstanding:%' then fails := fails || 'remove error: ' || sqlerrm || '; '; end if; end;
  begin perform public.tally_leave_group(g); fails := fails || 'owner left; '; exception when insufficient_privilege then null; end;
  begin perform public.tally_remove_member(mo); fails := fails || 'owner removed; '; exception when insufficient_privilege then null; end;

  -- removed member loses access at once; zero balance member m2 goes
  perform public.tally_remove_member(mm2);
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  if public.is_tally_member(g) then fails := fails || 'removed member still a member; '; end if;
  select count(*) into n from public.tally_groups where id = g;                if n <> 0 then fails := fails || 'removed member reads the group; '; end if;
  select count(*) into n from public.tally_expenses;                           if n <> 0 then fails := fails || 'removed member reads expenses; '; end if;
  select count(*) into n from public.tally_shares;                             if n <> 0 then fails := fails || 'removed member reads shares; '; end if;
  select count(*) into n from public.tally_settlements;                        if n <> 0 then fails := fails || 'removed member reads settlements; '; end if;
  select count(*) into n from public.tally_activity;                           if n <> 0 then fails := fails || 'removed member reads activity; '; end if;
  select count(*) into n from public.tally_members;                            if n <> 0 then fails := fails || 'removed member reads members; '; end if;
  select count(*) into n from public.tally_net(g);                             if n <> 0 then fails := fails || 'removed member reads nets; '; end if;
  begin perform public.tally_save_expense(jsonb_build_object('group_id', g, 'description', 'Back', 'amount_cents', 100, 'shares', jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 100))));
    fails := fails || 'removed member wrote; '; exception when raise_exception then null; end;
  begin insert into public.tally_settlements (group_id, from_member, to_member, amount_cents, created_by) values (g, mo, mm, 100, m2); fails := fails || 'removed member settled; '; exception when insufficient_privilege then null; end;

  -- a stranger sees nothing at all
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  if public.is_tally_member(g) then fails := fails || 'stranger is a member; '; end if;
  select count(*) into n from public.tally_activity;                           if n <> 0 then fails := fails || 'stranger reads activity; '; end if;
  select count(*) into n from public.tally_invites;                            if n <> 0 then fails := fails || 'stranger reads invites; '; end if;

  -- a guest becomes a real member, keeping their balance
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  select net_cents into n from public.tally_net(g) where member_id = guest;
  inv := public.tally_invite_user(g, x, guest);
  perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
  if public.tally_invite_respond(inv, true) <> guest then fails := fails || 'guest not linked; '; end if;
  if (select net_cents from public.tally_net(g) where member_id = guest) <> n then fails := fails || 'guest balance lost; '; end if;
  -- declining joins nothing
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  inv := public.tally_invite_user(g, m2, null);
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  perform public.tally_invite_respond(inv, false);
  if public.is_tally_member(g) then fails := fails || 'decline joined; '; end if;

  -- reminders: amount from the balance, once per person per group per day, only someone who owes, members only
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  select member_id into st from public.tally_net(g) where net_cents < 0 order by net_cents limit 1;
  perform public.tally_remind(st, 'firm');
  select amount_cents, tone into r from public.tally_reminders where to_member = st;
  if r.amount_cents <> -(select net_cents from public.tally_net(g) where member_id = st) or r.tone <> 'firm' then fails := fails || 'reminder amount or tone; '; end if;
  begin perform public.tally_remind(st, 'friendly'); fails := fails || 'second reminder inside 24 hours; '; exception when sqlstate '53400' then null; end;
  begin perform public.tally_remind((select member_id from public.tally_net(g) where net_cents > 0 limit 1)); fails := fails || 'reminded someone who owes nothing; '; exception when raise_exception then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  begin perform public.tally_remind(st); fails := fails || 'non-member reminded; '; exception when no_data_found then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);

  -- recurring bills: members add, the server posts once per date, nobody else stops them, a bill with a departed member stops itself
  declare rid uuid; ex uuid; begin
    rid := public.tally_save_recurring(jsonb_build_object('group_id', g, 'description', 'Wifi', 'amount_cents', 6000, 'cadence', 'monthly', 'next_on', '2026-11-30', 'shares',
           jsonb_build_array(jsonb_build_object('member_id', null, 'owed_cents', 3000), jsonb_build_object('member_id', mm, 'owed_cents', 3000))));
    begin perform public.tally_post_recurring(rid); fails := fails || 'app posted a bill; '; exception when insufficient_privilege then null; end;
    perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
    select count(*) into n from public.tally_recurring;                        if n <> 0 then fails := fails || 'non-member reads bills; '; end if;
    begin perform public.tally_stop_recurring(rid); fails := fails || 'non-member stopped a bill; '; exception when no_data_found then null; end;
    perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
    reset role;
    ex := public.tally_post_recurring(rid);
    if ex is null then fails := fails || 'bill did not post; '; end if;
    if (select next_on from public.tally_recurring where id = rid) <> '2026-12-30' then fails := fails || 'next date; '; end if;
    select count(*) into n from public.tally_shares where expense_id = ex;     if n <> 2 then fails := fails || 'bill shares; '; end if;
    update public.tally_recurring set next_on = '2026-11-30' where id = rid;
    if public.tally_post_recurring(rid) is not null then fails := fails || 'same date posted twice; '; end if;
    update public.tally_expenses set deleted_at = now() where id = ex;          -- keep the balances the checks below expect
    update public.tally_members set status = 'left' where id = mm;
    if public.tally_post_recurring(rid) is not null then fails := fails || 'bill posted to a departed member; '; end if;
    if (select active from public.tally_recurring where id = rid) then fails := fails || 'bill kept running after a member left; '; end if;
    update public.tally_members set status = 'active' where id = mm;
    set local role authenticated;
  end;

  -- Zelle: co-members read what someone shared, strangers and ex-members don't; a note is mine alone
  reset role;
  update public.profiles set zelle = 'mina@zelle.test' where user_id = m;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  select count(*) into n from public.tally_zelle_book() z where z.member_id = mm and z.zelle = 'mina@zelle.test';   if n <> 1 then fails := fails || 'co-member can''t read Zelle; '; end if;
  insert into public.tally_zelle_notes (member_id, zelle) values (guest, '5551112222');
  perform set_config('request.jwt.claims', json_build_object('sub', m2, 'role', 'authenticated')::text, true);
  select count(*) into n from public.tally_zelle_book();                       if n <> 0 then fails := fails || 'ex-member reads Zelle; '; end if;
  select count(*) into n from public.tally_zelle_notes;                        if n <> 0 then fails := fails || 'someone else reads my Zelle note; '; end if;
  begin insert into public.tally_zelle_notes (member_id, zelle) values (guest, 'x@y.z'); fails := fails || 'note on a stranger group; '; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);

  -- the history says who did what, with old and new amounts
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  select count(*) into n from public.tally_activity where action = 'expense_edited' and old_cents = 3000 and new_cents = 3300 and actor = o and actor_name = 'Olive Owner'; if n <> 1 then fails := fails || 'edit not logged; '; end if;
  select count(*) into n from public.tally_activity where action = 'expense_deleted' and entity_id = e_m;  if n <> 2 then fails := fails || format('deletes logged %s; ', n); end if;
  select count(*) into n from public.tally_activity where action = 'expense_restored';                     if n <> 2 then fails := fails || 'restores not logged; '; end if;
  select count(*) into n from public.tally_activity where action = 'settlement_deleted';                   if n <> 1 then fails := fails || 'settlement delete not logged; '; end if;
  select count(*) into n from public.tally_activity where action = 'member_removed';                       if n <> 1 then fails := fails || 'removal not logged; '; end if;
  select count(*) into n from public.tally_activity where action = 'member_joined';                        if n <> 1 then fails := fails || 'join not logged; '; end if;
  begin insert into public.tally_activity (group_id, action) values (g, 'fake'); fails := fails || 'activity forged; '; exception when insufficient_privilege then null; end;
  begin update public.tally_activity set label = 'x'; fails := fails || 'activity rewritten; '; exception when insufficient_privilege then null; end;

  -- owner deletes the group: gone for members at once, undo brings it back
  update public.tally_groups set deleted_at = now() where id = g; get diagnostics n = row_count;  if n <> 1 then fails := fails || 'owner cannot delete the group; '; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  select count(*) into n from public.tally_groups where id = g;                if n <> 0 then fails := fails || 'deleted group still visible; '; end if;
  j := public.tally_owed_to_me();                                              if (j->>'owed_to_me')::bigint <> 0 then fails := fails || 'deleted group still in totals; '; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
  update public.tally_groups set deleted_at = null where id = g; get diagnostics n = row_count;   if n <> 1 then fails := fails || 'undo of group delete; '; end if;
  reset role;

  if fails <> '' then raise exception 'TALLY_SHARED_TESTS_FAILED: %', fails; end if;
  raise exception 'TALLY_SHARED_TESTS_PASSED';
end $$;
