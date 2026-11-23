select cron.unschedule(jobid)
from cron.job
where jobname = 'books-fx-refresh';

select cron.schedule(
  'books-fx-refresh',
  '*/10 * * * *',
  $$
    select net.http_post(
      url := 'https://ozanawzeovdrngnqzeja.supabase.co/functions/v1/books-fx-refresh',
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'x-fx-refresh-secret', (
          select decrypted_secret
          from vault.decrypted_secrets
          where name = 'books_fx_refresh_secret'
          limit 1
        )
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 15000
    );
  $$
);
