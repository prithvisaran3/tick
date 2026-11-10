-- Ask Tick reflection: the nightly job turns a week's thumbs-down into proposals; nothing applies until I approve one.
-- 'proposal': value {shape, tool, params, questions, count, label, status: open|approved|dismissed}. 'eval': an approved question, kept for the eval.
alter table public.ask_memory drop constraint if exists ask_memory_kind_check;
alter table public.ask_memory add constraint ask_memory_kind_check check (kind in ('alias','rule','index','proposal','eval'));
create index if not exists ask_log_down_idx on public.ask_log (user_id, created_at desc) where rating = -1;
