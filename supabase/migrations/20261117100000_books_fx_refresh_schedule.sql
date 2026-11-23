create extension if not exists pg_cron with schema extensions;
create extension if not exists pg_net with schema extensions;

select cron.unschedule(jobid) from cron.job where jobname = 'books-fx-refresh';

select cron.schedule(
  'books-fx-refresh',
  '*/10 * * * *',
  $$
    select net.http_get(
      url := current_setting('app.fx_refresh_url'),
      timeout_milliseconds := 15000
    );
  $$
);
