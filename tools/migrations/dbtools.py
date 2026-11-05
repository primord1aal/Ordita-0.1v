"""Ограниченные вызовы PostgreSQL/CLI. Сырые stdout/stderr никогда не печатаются."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import re

from policy import LOCK,GuardError,require,validate_connection

DOCKER=['env','-u','DOCKER_HOST','-u','DOCKER_CONTEXT','-u','DOCKER_TLS','-u','DOCKER_TLS_VERIFY',
        '-u','DOCKER_CERT_PATH','docker','--host=unix:///var/run/docker.sock']


def checked(args,*,input=None,env=None,cwd=None,timeout=60):
    try:result=subprocess.run(args,input=input,capture_output=True,env=env,cwd=cwd,timeout=timeout)
    except (OSError,subprocess.SubprocessError):raise GuardError('Команда не завершилась; результат требует проверки.') from None
    require(result.returncode==0,'Команда завершилась с ошибкой; сырые данные и секреты скрыты.')
    return result.stdout


class Database:
    def __init__(self,url,project_ref,password,ca_file):
        validate_connection(url,project_ref)
        require(bool(password) and '\x00' not in password,'Не предоставлен корректный защищённый пароль БД.')
        self.url=url;self.password=password;self.ca_file=Path(ca_file)
        self.env=os.environ.copy()
        # Никаких сохранённых linked-проектов, альтернативных подключений и API-токенов.
        for key in list(self.env):
            if key.startswith(('PG','SUPABASE_')) or key in ('GH_TOKEN','GITHUB_TOKEN','ORBITA_BACKUP_PASSPHRASE'):
                self.env.pop(key)
        self.env.update({'PGPASSWORD':password,'PGSSLMODE':'verify-full','PGCONNECT_TIMEOUT':'10',
                         'PGSSLROOTCERT':str(self.ca_file),'SUPABASE_TELEMETRY_OPTOUT':'1'})

    def tool(self,program,args,*,input=None,timeout=60):
        env=self.env.copy();env['PGSSLROOTCERT']='/run/orbita-ca.pem'
        command=DOCKER+['run','--rm','-i','--env','PGPASSWORD','--env','PGSSLMODE','--env','PGCONNECT_TIMEOUT',
            '--env','PGSSLROOTCERT','--mount',f'type=bind,src={self.ca_file},dst=/run/orbita-ca.pem,readonly',
            LOCK['postgres_image'],program,*args]
        return checked(command,input=input,env=env,timeout=timeout)

    def query(self,sql):
        raw=self.tool('psql',['--no-psqlrc','--set','ON_ERROR_STOP=1','-Atq','--dbname',self.url],input=sql.encode())
        return raw.decode().strip()

    def cli(self,workdir,dry_run):
        # Все параметры определены кодом. Ни reset/repair, ни seeds/roles/Vault.
        args=['supabase','db','push','--remote='+self.url,'--skip-vault']
        args+=['--dry-run'] if dry_run else ['--yes']
        try:result=subprocess.run(args,cwd=workdir,env=self.env,capture_output=True,timeout=120)
        except (OSError,subprocess.SubprocessError):raise GuardError('Результат CLI неизвестен; автоматический повтор запрещён.') from None
        require(result.returncode==0,'CLI завершился с ошибкой; автоматический повтор запрещён.')
        return (result.stdout+result.stderr).decode(errors='replace')

    def dump(self,schemas):
        args=['--format=custom','--dbname',self.url]
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
