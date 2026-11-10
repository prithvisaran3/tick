-- Splitwise as a real category: tagging a row asks which group or friend it was with, and "Not this one" remembers which explanation was wrong.
-- kind 'tag': matched_txn = the row, group_id and/or person = what I picked. kind 'rejected' with description set = "Not this one" for that ref only.
alter table public.splitwise_events drop constraint if exists splitwise_events_kind_check;
alter table public.splitwise_events add constraint splitwise_events_kind_check check (kind in ('expense','settle_out','settle_in','rejected','tag'));
alter table public.splitwise_events add column if not exists group_id uuid references public.tally_groups(id) on delete set null;
create index if not exists splitwise_events_txn_idx on public.splitwise_events (user_id, matched_txn) where matched_txn is not null;
