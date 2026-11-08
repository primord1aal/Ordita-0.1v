"""Ограниченные вызовы PostgreSQL/CLI. Сырые stdout/stderr никогда не печатаются."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import re
import math
import tempfile
import uuid

from policy import LOCK,GuardError,require,validate_connection

DOCKER=['env','-u','DOCKER_HOST','-u','DOCKER_CONTEXT','-u','DOCKER_TLS','-u','DOCKER_TLS_VERIFY',
        '-u','DOCKER_CERT_PATH','docker','--host=unix:///var/run/docker.sock']
OWNER_LABEL='orbita.migration.operation'


class _DockerCleanupUncertain(GuardError):
    pass


def _new_operation_token():
    return 'orbita_mig_'+uuid.uuid4().hex


def _timeout_options(timeout,*,read_only=False):
    require(isinstance(timeout,(int,float)) and math.isfinite(timeout) and timeout>=1,
            'Некорректный бюджет времени клиента.')
    statement=min(30000,int(timeout*500))
    lock=min(5000,statement//3)
    # Это служебные соединения без ожидания человека: забытая транзакция не должна жить долго.
    idle=min(15000,int(timeout*250))
    options=f'-c statement_timeout={statement} -c lock_timeout={lock} -c idle_in_transaction_session_timeout={idle}'
    # Запрет записи задаётся на сервере при старте каждого соединения.
    return options+(' -c default_transaction_read_only=on' if read_only else '')


def restricted_process_env():
    """Окружение дочерних инструментов без секретов другого назначения."""
    env=os.environ.copy()
    for key in list(env):
        if key.startswith(('PG','SUPABASE_','ORBITA_')) or key in ('GH_TOKEN','GITHUB_TOKEN'):
            env.pop(key)
    # Поддерживаемые CLI 3.0.0 переключатели, включая самый первый --version.
    env.update(SUPABASE_TELEMETRY_DISABLED='1',DO_NOT_TRACK='1')
    return env


def checked(args,*,input=None,env=None,cwd=None,timeout=60):
    try:result=subprocess.run(args,input=input,capture_output=True,env=env,cwd=cwd,timeout=timeout)
    except (OSError,subprocess.SubprocessError):raise GuardError('Команда не завершилась; результат требует проверки.') from None
    require(result.returncode==0,'Команда завершилась с ошибкой; сырые данные и секреты скрыты.')
    return result.stdout


class Database:
    def __init__(self,url,project_ref,password,ca_file,*,read_only=False):
        validate_connection(url,project_ref)
        require(bool(password) and '\x00' not in password,'Не предоставлен корректный защищённый пароль БД.')
        require(type(read_only) is bool,'Некорректный режим подключения.')
        self.url=url;self.password=password;self.ca_file=Path(ca_file);self.read_only=read_only
        self.env=restricted_process_env()
        # Никаких сохранённых linked-проектов, альтернативных подключений и API-токенов.
        self.env.update({'PGPASSWORD':password,'PGSSLMODE':'verify-full','PGCONNECT_TIMEOUT':'10',
                         'PGSSLROOTCERT':str(self.ca_file)})

    def tool(self,program,args,*,input=None,timeout=60):
        token=_new_operation_token()
        require(bool(re.fullmatch(r'orbita_[a-z0-9_]{1,54}',token)),'Некорректная метка SQL-операции.')
        try:
            return self._owned_tool(program,args,token,input=input,timeout=timeout)
        except BaseException as error:
            # Убийство Docker CLI не отменяет SQL. После попытки закрыть контейнер
            # backend может ещё выполнять pg_sleep или ждать блокировку.
            try:self._end_sql(token)
            except Exception:
                raise GuardError('Завершение SQL не подтверждено; результат неизвестен. '
                                 'Автоматический повтор запрещён.') from None
            if isinstance(error,(KeyboardInterrupt,SystemExit)):raise
            if isinstance(error,_DockerCleanupUncertain):raise error from None
            raise GuardError('Команда прервана; результат операции требует проверки. '
                             'Автоматический повтор запрещён.') from None

    def _owned_tool(self,program,args,token,*,input=None,timeout=60):
        env=self.env.copy()
        env.update(PGSSLROOTCERT='/run/orbita-ca.pem',PGAPPNAME=token,PGOPTIONS=_timeout_options(timeout,read_only=self.read_only),
                   PGCONNECT_TIMEOUT=str(min(10,max(2,int(timeout/4)))))
        if self.read_only:env['PGTARGETSESSIONATTRS']='read-only'
        # create даёт точный CID. Без --rm ресурс не исчезнет до проверки ownership.
        # Имя само по себе никогда не является основанием для удаления.
        cid=None
        with tempfile.TemporaryDirectory(prefix='orbita-db-client-') as directory:
            cidfile=Path(directory)/'client.cid'
            name='orbita-db-'+uuid.uuid4().hex
            command=DOCKER+['create','--cidfile',str(cidfile),'--name',name,
                '--label',OWNER_LABEL+'='+token,'-i']
            for key in ('PGPASSWORD','PGSSLMODE','PGCONNECT_TIMEOUT','PGSSLROOTCERT','PGAPPNAME','PGOPTIONS','PGTARGETSESSIONATTRS'):
                if key in env:command+=['--env',key]
            command+=['--mount',f'type=bind,src={self.ca_file},dst=/run/orbita-ca.pem,readonly',
                      LOCK['postgres_image'],program,*args]
            try:
                raw=checked(command,env=env,timeout=15).decode().strip()
                require(bool(re.fullmatch(r'[a-f0-9]{64}',raw)),'Не получен точный CID клиента.')
                cid=raw
                self._check_owner(cid,token)
                return checked(DOCKER+['start','--attach','--interactive',cid],input=input,env=env,timeout=timeout)
            finally:
                try:
                    # CLI мог получить CID и записать файл до собственного таймаута.
                    if cid is None and cidfile.is_file():
                        raw=cidfile.read_text().strip()
                        require(bool(re.fullmatch(r'[a-f0-9]{64}',raw)),'Создание Docker-клиента не подтверждено.')
                        cid=raw
                    if cid is None:
                        # create мог завершиться на daemon до записи cidfile. Имя
                        # используется только для поиска: метка обязательна, rm — по CID.
                        cid=self._check_owner(name,token,allow_name=True)
                    self._check_owner(cid,token)
                    checked(DOCKER+['rm','--force','--volumes',cid],env=env,timeout=15)
                except Exception:
                    raise _DockerCleanupUncertain('Очистка Docker-клиента не подтверждена; результат неизвестен. '
                                                  'Автоматический повтор запрещён.') from None

    def _check_owner(self,reference,token,*,allow_name=False):
        template='{{json .Id}}\n{{json (index .Config.Labels "'+OWNER_LABEL+'")}}'
        raw=checked(DOCKER+['inspect','--format',template,reference],env=self.env,timeout=10).decode().splitlines()
        require(len(raw)==2,'Не подтверждена идентичность Docker-ресурса.')
        cid=json.loads(raw[0])
        require(isinstance(cid,str) and bool(re.fullmatch(r'[a-f0-9]{64}',cid)) and
                (cid==reference or (allow_name and bool(re.fullmatch(r'orbita-db-[a-f0-9]{32}',reference)))) and
                json.loads(raw[1])==token,
                'Docker-ресурс не принадлежит этой операции; остановка запрещена.')
        return cid

    def _control(self,sql):
        # Не вызывать tool(): это сделало бы очистку рекурсивной. Собственная метка
        # контроллера не совпадает с меткой отменяемой операции.
        token='orbita_ctl_'+uuid.uuid4().hex
        return self._owned_tool('psql',['--no-psqlrc','--set','ON_ERROR_STOP=1','-Atq','--dbname',self.url],
                                token,input=sql.encode(),timeout=10).decode().strip()

    @staticmethod
    def _session_filter(token):
        require(bool(re.fullmatch(r'orbita_[a-z0-9_]{1,54}',token)),'Некорректная метка SQL-операции.')
        return ("application_name='"+token+"' and datname=current_database() and usename=session_user "
                "and backend_type='client backend' and pid<>pg_backend_pid()")

    def _sessions(self,token):
        return json.loads(self._control("select coalesce(json_agg(json_build_object('pid',pid,"
            "'backend_start',backend_start::text)), '[]') from pg_catalog.pg_stat_activity where "+
            self._session_filter(token)+';'))

    def _signal(self,token,sessions,terminate=False):
        identities=[]
        for row in sessions:
            pid=row.get('pid');start=row.get('backend_start')
            require(type(pid) is int and pid>0 and isinstance(start,str) and
                    bool(re.fullmatch(r'[0-9 .:+-]{1,64}',start)),'Не подтверждена идентичность SQL-сеанса.')
            identities.append(f"(pid={pid} and backend_start='{start}'::timestamptz)")
        require(bool(identities),'Нет подтверждённых SQL-сеансов для отмены.')
        function='pg_terminate_backend(pid,1000)' if terminate else 'pg_cancel_backend(pid)'
        self._control('select pg_catalog.'+function+' from pg_catalog.pg_stat_activity where '+
                      self._session_filter(token)+' and ('+' or '.join(identities)+');')

    def _end_sql(self,token):
        sessions=self._sessions(token)
        if sessions:
            self._signal(token,sessions)
            sessions=self._sessions(token)
        if sessions:
            # cancel может оставить idle in transaction; terminate адресует ту же
            # подтверждённую пару PID/backend_start и освобождает её блокировки.
            self._signal(token,sessions,terminate=True)
        require(self._sessions(token)==[],
                'SQL-сеанс остался после отмены; завершение операции не подтверждено.')

    def query(self,sql):
        # Даже если session default меняется, каждая preview/inspect проверка
        # выполняется в явно READ ONLY транзакции с безусловным ROLLBACK.
        if self.read_only:sql='BEGIN TRANSACTION READ ONLY;\n'+sql+'\nROLLBACK;'
        raw=self.tool('psql',['--no-psqlrc','--set','ON_ERROR_STOP=1','-Atq','--dbname',self.url],input=sql.encode())
        return raw.decode().strip()

    def cli(self,workdir,dry_run):
        require(not(self.read_only and not dry_run),'Read-only режим запрещает применение миграций.')
        # Все параметры определены кодом. Ни reset/repair, ни seeds/roles/Vault.
        args=['supabase','db','push','--remote='+self.url,'--skip-vault']
        args+=['--dry-run'] if dry_run else ['--yes']
        # CLI 3.0.0 не читает PGOPTIONS, но читает libpq service options.
        # Только фиксированные GUC: адрес, Ref, пользователь и TLS не переопределяются.
        with tempfile.TemporaryDirectory(prefix='orbita-cli-session-') as directory:
            service=Path(directory)/'pg_service.conf'
            with service.open('x') as stream:
                service.chmod(0o600)
                stream.write('[orbita_b1]\noptions='+_timeout_options(120,read_only=self.read_only)+'\n')
            env=self.env.copy();env.update(PGSERVICEFILE=str(service),PGSERVICE='orbita_b1')
            if self.read_only:env['PGTARGETSESSIONATTRS']='read-only'
            try:result=subprocess.run(args,cwd=workdir,env=env,capture_output=True,timeout=120)
            except (OSError,subprocess.SubprocessError):
                # CLI заменяет PGAPPNAME общим @effect/sql-pg: по нему нельзя
                # безопасно отменять backend. Не объявляем SQL завершённым.
                raise GuardError('Результат CLI неизвестен; завершение его SQL не подтверждено. '
                                 'Автоматический повтор запрещён.') from None
        require(result.returncode==0,'CLI завершился с ошибкой; автоматический повтор запрещён.')
        return (result.stdout+result.stderr).decode(errors='replace')

    def dump(self,schemas):
        # pg_dump сбрасывает GUC timeouts в 0. Этот параметр ограничивает его
        # начальные table locks; общий deadline и _end_sql остаются обязательными.
        args=['--format=custom','--lock-wait-timeout=5000','--dbname',self.url]
        for schema in schemas:args+=['--schema',schema]
        return self.tool('pg_dump',args,timeout=120)


def inspect(db):
    basic=json.loads(db.query("""select json_build_object(
      'sql_user',current_user,
      'auth_users',(select count(*) from auth.users),
      'app_tables',(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname in ('orbita_profiles','orbita_user_roles','orbita_account_access','orbita_access_audit')),
      'private_schema',exists(select 1 from pg_namespace where nspname='orbita_mobile_private'),
      'access_rpc',to_regprocedure('public.orbita_get_access()') is not null,
      'history_table',to_regclass('supabase_migrations.schema_migrations') is not null);"""))
    basic['versions']=json.loads(db.query('select coalesce(json_agg(version order by version),\'[]\') from supabase_migrations.schema_migrations;')) if basic['history_table'] else []
    require(all(isinstance(v,str) and re.fullmatch(r'[0-9]{1,20}',v) for v in basic['versions']),
            'Неожиданный формат истории; сырой ответ не публикуется.')
    require(basic['sql_user']=='postgres','Соединение должно выполнять операции от postgres.')
    return basic


def require_initial(state):
    require(state['auth_users']==0,'Исходное условие 0 Auth-пользователей изменилось; остановитесь.')
    require(state['app_tables']==0 and not state['private_schema'] and not state['access_rpc'],
            'Прикладные объекты уже существуют; не применять повторно.')
    require(state['versions']==[],'История содержит неожиданные версии; автоматическое исправление запрещено.')


def baseline_fingerprint(db):
    # Отпечаток согласованного логического объёма, а не всего проекта Supabase.
    schema=db.query("""select jsonb_build_object(
      'relations',(select coalesce(jsonb_agg(jsonb_build_array(c.relname,c.relkind,c.relrowsecurity,
        c.relowner,c.relacl,(select jsonb_agg(jsonb_build_array(a.attname,a.atttypid,a.attnotnull)
          order by a.attnum) from pg_attribute a where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped)) order by c.relname),'[]')
        from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m','S')),
      'functions',(select coalesce(jsonb_agg(pg_get_functiondef(p.oid) order by p.oid),'[]') from pg_proc p
        join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prokind in ('f','p')),
      'auth_triggers',(select coalesce(jsonb_agg(pg_get_triggerdef(oid) order by tgname),'[]')
        from pg_trigger where tgrelid='auth.users'::regclass and not tgisinternal));""")
    return hashlib.sha256((schema+'\n'+json.dumps(public_rows(db),sort_keys=True)).encode()).hexdigest()


def public_rows(db):
    names=json.loads(db.query("""select coalesce(json_agg(tablename order by tablename),'[]')
        from pg_tables where schemaname='public';"""))
    counts={}
    for name in names:
        identifier='"'+name.replace('"','""')+'"'
        counts[name]=int(db.query('select count(*) from public.'+identifier+';'))
    return counts


def postflight(db):
    state=inspect(db)
    require(state['auth_users']==0 and state['app_tables']==4 and state['private_schema'] and state['access_rpc']
        and state['versions']==[LOCK['version']],'Структура или история после применения не совпала с ожидаемой.')
    details=json.loads(db.query("""select json_build_object(
      'rls_tables',(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname in ('orbita_profiles','orbita_user_roles','orbita_account_access','orbita_access_audit') and c.relrowsecurity),
      'policies',(select count(*) from pg_policies where schemaname='public' and tablename like 'orbita_%'),
      'private_functions',(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='orbita_mobile_private'),
      'unsafe_private_functions',(select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='orbita_mobile_private' and (p.proowner<>'postgres'::regrole or not p.prosecdef
          or p.proconfig is distinct from array['search_path=""']
          or has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE')
          or has_function_privilege('service_role',p.oid,'EXECUTE'))),
      'triggers',(select count(*) from pg_trigger where tgname like 'orbita_%' and not tgisinternal));"""))
    require(details=={'rls_tables':4,'policies':2,'private_functions':7,'unsafe_private_functions':0,'triggers':11},
            'Проверка прав/политик/триггеров не прошла; требуется расследование.')
    acl=json.loads(db.query("""select json_build_object(
      'no_unexpected_table_rights',not exists(
        select 1 from (values('anon'),('authenticated'),('service_role')) r(name)
        cross join (values('orbita_profiles'),('orbita_user_roles'),('orbita_account_access'),('orbita_access_audit')) t(name)
        cross join (values('SELECT'),('INSERT'),('UPDATE'),('DELETE'),('TRUNCATE'),('REFERENCES'),('TRIGGER')) p(name)
        where not(r.name='authenticated' and t.name='orbita_profiles' and p.name='SELECT')
          and has_table_privilege(r.name,'public.'||t.name,p.name)),
      'no_unexpected_column_rights',not exists(
        select 1 from (values('anon'),('authenticated'),('service_role')) r(name)
        cross join (values('SELECT'),('INSERT'),('UPDATE'),('REFERENCES')) p(name)
        cross join pg_attribute a join pg_class c on c.oid=a.attrelid
        join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname in ('orbita_profiles','orbita_user_roles','orbita_account_access','orbita_access_audit')
          and a.attnum>0 and not a.attisdropped
          and not(r.name='authenticated' and c.relname='orbita_profiles'
            and (p.name='SELECT' or(p.name='UPDATE' and a.attname='display_name')))
          and has_column_privilege(r.name,c.oid,a.attnum,p.name)),
      'profile_columns',has_table_privilege('authenticated','public.orbita_profiles','SELECT')
        and has_column_privilege('authenticated','public.orbita_profiles','display_name','UPDATE')
        and not has_column_privilege('authenticated','public.orbita_profiles','user_id','UPDATE')
        and not has_column_privilege('authenticated','public.orbita_profiles','created_at','UPDATE'),
      'private_schema_closed',not exists(select 1 from (values('anon'),('authenticated'),('service_role')) r(name)
        where has_schema_privilege(r.name,'orbita_mobile_private','USAGE')
          or has_schema_privilege(r.name,'orbita_mobile_private','CREATE')
          or has_sequence_privilege(r.name,'public.orbita_access_audit_id_seq','USAGE,SELECT,UPDATE')),
      'rpc',exists(select 1 from pg_proc where oid='public.orbita_get_access()'::regprocedure
        and proowner='postgres'::regrole and prosecdef and proconfig=array['search_path=""'])
        and has_function_privilege('authenticated','public.orbita_get_access()','EXECUTE')
        and not has_function_privilege('anon','public.orbita_get_access()','EXECUTE')
        and not has_function_privilege('service_role','public.orbita_get_access()','EXECUTE'));
      """))
    require(all(value is True for value in acl.values()),'Клиентские права после применения не совпали с ожидаемыми.')
    details['client_acl_verified']=True
    require(all(value==0 for value in public_rows(db).values()),'После применения появились неожиданные строки.')
    return details
