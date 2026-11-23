create or replace function public.submit_task_response(
  p_task_id uuid,
  p_worker_id uuid,
  p_action text,
  p_response_message text,
  p_rate_acknowledged boolean,
  p_quoted_price numeric default null,
  p_proposal_notes text default null,
  p_proposed_timeline text default null,
  p_proposed_settlement_currency_code text default null
)
returns uuid
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  response_id uuid;
  task_manager_id uuid;
begin
  insert into public.task_responses (task_id, worker_id, action, response_message, rate_acknowledged)
  values (p_task_id, p_worker_id, p_action, p_response_message, p_rate_acknowledged)
  returning id into response_id;

  if p_action = 'propose' then
    select created_by into task_manager_id from public.tasks where id = p_task_id;

    insert into public.task_proposals (
      task_id, worker_id, manager_id, status, quoted_price, proposal_notes,
      proposed_timeline, proposed_settlement_currency_code, rate_acknowledged
    ) values (
      p_task_id, p_worker_id, task_manager_id, 'pending', p_quoted_price, p_proposal_notes,
      p_proposed_timeline, p_proposed_settlement_currency_code, p_rate_acknowledged
    );
  end if;

  return response_id;
end;
$$;

revoke all on function public.submit_task_response(uuid, uuid, text, text, boolean, numeric, text, text, text) from public, anon;
grant execute on function public.submit_task_response(uuid, uuid, text, text, boolean, numeric, text, text, text) to authenticated;
