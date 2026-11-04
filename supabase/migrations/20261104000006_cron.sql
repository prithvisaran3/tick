-- Scheduled jobs: pg_cron + pg_net call the FastAPI service with a CRON_SECRET header. The secret and URL live in Vault, never in SQL text.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.tick_call_api(path text) returns bigint
language plpgsql security definer set search_path = public, vault, extensions as $$
declare base text; sec text; rid bigint;
begin
  select decrypted_secret into base from vault.decrypted_secrets where name = 'tick_api_url';
  select decrypted_secret into sec from vault.decrypted_secrets where name = 'tick_cron_secret';
  if base is null or sec is null then return null; end if;
  select net.http_post(url := base || path, headers := jsonb_build_object('Content-Type', 'application/json', 'X-Cron-Secret', sec), body := '{}'::jsonb, timeout_milliseconds := 55000) into rid;
  return rid;
end $$;
revoke all on function public.tick_call_api(text) from public, anon, authenticated;

select cron.schedule('tick-sync-all', '0 */6 * * *', $$select public.tick_call_api('/jobs/sync-all')$$);
select cron.schedule('tick-weekly-insights', '0 22 * * 0', $$select public.tick_call_api('/jobs/weekly-insights')$$);
