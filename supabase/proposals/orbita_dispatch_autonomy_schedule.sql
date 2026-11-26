-- Separate admission after the autonomy function and pg_cron are verified.
do $schedule$
declare
  v_name constant text := 'orbita-dispatch-tick';
  v_interval constant text := '5 seconds';
  v_command constant text := $job$set local lock_timeout = '500ms';
set local statement_timeout = '3s';
select orbita_mobile_private.dispatch_scheduled_tick();$job$;
  v_previous record;
begin
  if current_user <> 'postgres'
     or to_regprocedure('orbita_mobile_private.dispatch_scheduled_tick()') is null
     or to_regprocedure('cron.schedule(text,text,text)') is null then
    raise exception 'ORB_AUTONOMY_SCHEDULE_PREFLIGHT';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_name));
  select jobid, schedule, command, database, active into v_previous
  from cron.job where jobname = v_name and username = current_user;
  if found then
    if v_previous.schedule is distinct from v_interval
       or v_previous.command is distinct from v_command
       or v_previous.database is distinct from current_database()
       or v_previous.active is distinct from true then
      raise exception 'ORB_AUTONOMY_SCHEDULE_DRIFT';
    end if;
    return;
  end if;

  perform cron.schedule(v_name, v_interval, v_command);
end
$schedule$;
