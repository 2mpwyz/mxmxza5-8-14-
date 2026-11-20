alter table public.video_uploads
  add column if not exists aspect_ratio double precision;

do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'video_uploads_aspect_ratio_positive'
       and conrelid = 'public.video_uploads'::regclass
  ) then
    alter table public.video_uploads
      add constraint video_uploads_aspect_ratio_positive
      check (aspect_ratio is null or aspect_ratio > 0);
  end if;
end;
$$;
