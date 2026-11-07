#!/usr/bin/env python3
"""Proves 20261110000001_tally_shared.sql keeps data: builds a database at the migration BEFORE it, seeds owner-only Tally rows, applies it, and checks
every balance, expense, share, settlement and person survived. Uses the throwaway local Postgres from tools/local_db.py."""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import local_db as L
TARGET = "20261110000001_tally_shared.sql"
SEED = """
insert into auth.users (id, aud, role, email) values ('aaaaaaaa-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'a@test.local');
update public.profiles set display_name = 'Prithvi S' where user_id = 'aaaaaaaa-0000-4000-8000-000000000001';
insert into public.people (id, user_id, name, phone) values
  ('bbbbbbbb-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'Kaarthik', '5551112222'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'Jo', null),
  ('bbbbbbbb-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 'Dropped', null);
insert into public.tally_groups (id, user_id, name) values ('cccccccc-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'Flat');
insert into public.tally_members (group_id, person_id, user_id) values
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001'),
  ('cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001');
insert into public.tally_expenses (id, user_id, group_id, description, amount_cents, paid_by) values
  ('dddddddd-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Rent', 9000, null),
  ('dddddddd-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Wifi', 3000, 'bbbbbbbb-0000-4000-8000-000000000001');
insert into public.tally_expenses (id, user_id, group_id, description, amount_cents, paid_by, deleted_at) values
  ('dddddddd-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'Gone', 500, 'bbbbbbbb-0000-4000-8000-000000000003', now());
insert into public.tally_shares (expense_id, person_id, user_id, owed_cents) values
  ('dddddddd-0000-4000-8000-000000000001', null, 'aaaaaaaa-0000-4000-8000-000000000001', 3000),
  ('dddddddd-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 3000),
  ('dddddddd-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002', 'aaaaaaaa-0000-4000-8000-000000000001', 3000),
  ('dddddddd-0000-4000-8000-000000000002', null, 'aaaaaaaa-0000-4000-8000-000000000001', 1500),
  ('dddddddd-0000-4000-8000-000000000002', 'bbbbbbbb-0000-4000-8000-000000000001', 'aaaaaaaa-0000-4000-8000-000000000001', 1500),
  ('dddddddd-0000-4000-8000-000000000003', 'bbbbbbbb-0000-4000-8000-000000000003', 'aaaaaaaa-0000-4000-8000-000000000001', 500);
insert into public.tally_settlements (user_id, group_id, from_person, to_person, amount_cents) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000001', 'bbbbbbbb-0000-4000-8000-000000000002', null, 1000);
"""
CHECK = """
do $$ declare fails text := ''; n bigint; r record;
begin
  select count(*) into n from public.tally_members where role = 'owner';                   if n <> 1 then fails := fails || 'owner member; '; end if;
  select count(*) into n from public.tally_members where person_id is not null and status = 'active'; if n <> 2 then fails := fails || format('guests %s; ', n); end if;
  select count(*) into n from public.tally_members where name = 'Dropped' and status = 'left';        if n <> 1 then fails := fails || 'past member; '; end if;
  select count(*) into n from public.tally_expenses;                                       if n <> 3 then fails := fails || 'expenses; '; end if;
  select count(*) into n from public.tally_shares;                                         if n <> 6 then fails := fails || 'shares; '; end if;
  select count(*) into n from public.tally_settlements;                                    if n <> 1 then fails := fails || 'settlements; '; end if;
  select count(*) into n from public.people where name = 'Kaarthik' and phone = '5551112222'; if n <> 1 then fails := fails || 'people; '; end if;
  -- me: paid 9000, owes 3000 + 1500 = +4500. Kaarthik: paid 3000, owes 4500 = -1500. Jo: owes 3000, paid back 1000 = -2000... to owner? settlement to me: me -1000 => +3500.
  for r in select m.name, m.role, x.net_cents from public.tally_net('cccccccc-0000-4000-8000-000000000001') x join public.tally_members m on m.id = x.member_id loop
    if (r.role = 'owner' and r.net_cents <> 3500) or (r.name = 'Kaarthik' and r.net_cents <> -1500) or (r.name = 'Jo' and r.net_cents <> -2000) then fails := fails || format('%s net %s; ', r.name, r.net_cents); end if;
  end loop;
  if fails <> '' then raise exception 'MIGRATION_FAILED: %', fails; end if;
end $$;
"""
def main():
    orig = sorted((L.ROOT / "supabase/migrations").glob("*.sql"))
    before = [m for m in orig if m.name < TARGET]
    real = L.ROOT
    tmp = pathlib.Path(L.DATA).parent / "tally_mig"
    (tmp / "supabase/migrations").mkdir(parents=True, exist_ok=True)
    for f in (tmp / "supabase/migrations").glob("*.sql"):
        f.unlink()
    for m in before:
        (tmp / "supabase/migrations" / m.name).write_text(m.read_text())
    L.ROOT = tmp
    try:
        L.fresh()
    finally:
        L.ROOT = real
    L.psql(SEED)
    r = L.psql(file=real / "supabase/migrations" / TARGET, check=False)
    if r.returncode:
        sys.exit("migration failed:\n" + r.stderr[-1500:])
    r = L.psql(CHECK, check=False)
    if r.returncode:
        sys.exit(r.stderr[-1500:])
    print("migration keeps every row and balance")
if __name__ == "__main__":
    main()
