select cron.unschedule(jobid) from cron.job where jobname = 'books-fx-refresh';

select cron.schedule(
  'books-fx-refresh',
  '*/10 * * * *',
  $$
    select net.http_post(
      url := 'https://ozanawzeovdrngnqzeja.supabase.co/functions/v1/books-fx-refresh',
      headers := '{"content-type": "application/json"}'::jsonb,
      body := '{}'::jsonb,
      timeout_milliseconds := 15000
    );
  $$
);
