do $$
begin
  if (select data_type from information_schema.columns
       where table_schema = 'public' and table_name = 'tasks' and column_name = 'due_date') = 'date' then
    alter table public.tasks
      alter column due_date type timestamptz
      using ((due_date + time '23:59:59') at time zone 'Africa/Kampala');
  end if;

  if (select data_type from information_schema.columns
       where table_schema = 'public' and table_name = 'todo_list' and column_name = 'due_date') = 'date' then
    alter table public.todo_list
      alter column due_date type timestamptz
      using ((due_date + time '23:59:59') at time zone 'Africa/Kampala');
  end if;
end $$;

notify pgrst, 'reload schema';
