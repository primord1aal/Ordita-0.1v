"""CLI planning on an owned, network-none restored snapshot; never cloud CLI."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

from dbtools import DOCKER,checked,restricted_process_env,inspect,baseline_fingerprint
from policy import LOCK,require,GuardError,parse_dry_run,validate_local_plan

RESTORE_LABEL='orbita.restore.operation'


def verify_restore(cid,token):
    require(bool(re.fullmatch(r'[a-f0-9]{64}',cid)),'Нужен точный CID локальной копии.')
    template='[{{json .Id}},{{json .HostConfig.NetworkMode}},{{json (index .Config.Labels "'+RESTORE_LABEL+'")}}]'
    raw=checked(DOCKER+['inspect','--format',template,cid],env=restricted_process_env(),timeout=10)
    require(json.loads(raw)==[cid,'none',token],'Локальная копия должна принадлежать этой операции и не иметь сети.')


def cleanup_restore(name,token,cid=None):
    env=restricted_process_env()
    if cid is None:
        found=checked(DOCKER+['ps','-aq','--no-trunc','--filter','name=^/'+name+'$'],env=env,timeout=10).decode().splitlines()
        require(len(found)<=1,'Не удалось однозначно найти локальную копию.')
        if not found:return
        cid=found[0]
    verify_restore(cid,token)
    checked(DOCKER+['rm','--force','--volumes',cid],env=env,timeout=15)
    remaining=checked(DOCKER+['ps','-aq','--no-trunc','--filter','id='+cid],env=env,timeout=10)
    require(not remaining.strip(),'Остановка локальной копии не подтверждена; автоматического повтора нет.')


def run_local_plan(cid,token,cli_binary,root,expected_versions,directory,on_phase=None):
    verify_restore(cid,token)
    root=Path(root);directory=Path(directory);env=restricted_process_env()
    migration=root/'supabase/migrations'/LOCK['migration']
    require(hashlib.sha256(migration.read_bytes()).hexdigest()==LOCK['migration_sha256'],'Файл миграции изменился перед локальным планированием.')
    require(Path(cli_binary).is_file(),'Нужен ранее проверенный локальный CLI.')
    work='/tmp/orbita-preview-plan'
    checked(DOCKER+['exec',cid,'mkdir','-p',work+'/supabase/migrations'],env=env)
    config=directory/'local-config.toml'
    config.write_text('project_id="orbita_offline_preview"\n[db]\nmajor_version=17\n[db.migrations]\nenabled=true\n[db.seed]\nenabled=false\n')
    for source,target in [(cli_binary,'/tmp/orbita-supabase'),(config,work+'/supabase/config.toml'),
                          (migration,work+'/supabase/migrations/'+LOCK['migration'])]:
        checked(DOCKER+['cp',str(source),cid+':'+target],env=env)
    prefix=DOCKER+['exec','--workdir',work,'-e','SUPABASE_TELEMETRY_DISABLED=1','-e','DO_NOT_TRACK=1',cid,'/tmp/orbita-supabase']
    require(checked(prefix+['--version'],env=env,timeout=10).decode().strip()==LOCK['cli_version'],'Версия локального CLI не совпала.')

    class LocalDatabase:
        def query(self,sql):
            return checked(DOCKER+['exec','-i',cid,'psql','-X','-Atq','-v','ON_ERROR_STOP=1',
                '-U','postgres','-d','restore'],input=sql.encode(),env=env,timeout=30).decode().strip()
    db=LocalDatabase()
    before=inspect(db);before_fingerprint=baseline_fingerprint(db)
    before_history_schema=db.query("select exists(select 1 from pg_namespace where nspname='supabase_migrations');")
    require(before['versions']==expected_versions,'История восстановленной копии отличается от прочитанной облачной истории.')
    # Fixed loopback target: URL, passwords and API tokens of the cloud DB are
    # neither accepted by this function nor forwarded into the container.
    target='postgresql://postgres@localhost:5432/restore?sslmode=verify-full&sslrootcert=/tmp/orbita-restore-ca.pem'
    if on_phase is not None:on_phase('LOCAL_CLI_DRY_RUN')
    try:
        result=subprocess.run(prefix+['db','push','--remote='+target,'--skip-vault','--dry-run'],
            env=env,capture_output=True,timeout=120)
    except (OSError,subprocess.SubprocessError):
        raise GuardError('Локальный CLI не завершился; копия будет остановлена, автоматического повтора нет.') from None
    require(result.returncode==0,'Локальный CLI завершился с ошибкой; сырой ответ скрыт.')
    pending=parse_dry_run((result.stdout+result.stderr).decode(errors='replace'))
    unchanged=(inspect(db)==before and baseline_fingerprint(db)==before_fingerprint and
        db.query("select exists(select 1 from pg_namespace where nspname='supabase_migrations');")==before_history_schema)
    plan={'target':'isolated_restored_snapshot','versions':before['versions'],'pending':pending,
          'scoped_state_unchanged':unchanged,'network':'none','tls':'verify-full'}
    validate_local_plan(plan,expected_versions)
    return plan
