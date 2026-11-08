"""Будущий защищённый runner. Сейчас не запускать против облака.

Preview: только SELECT/экспорт/dry-run. Apply: один вызов CLI после GitHub gate.
Сырые ответы CLI/БД, дампы и пароли не попадают в публичный отчёт.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

from backup import create_backup
from dbtools import Database,inspect,require_initial,postflight,baseline_fingerprint,restricted_process_env
from policy import LOCK,GuardError,require,validate_request,validate_connection,parse_dry_run

# Fixed, non-sensitive diagnostic codes. Never print exception text, SQL, paths or URLs.
SAFE_PHASES=frozenset({
    'START','GATE_FILE','SOURCE_VALIDATION','DATABASE_URL','CLI_VERSION',
    'CA_CONFIG','DB_CLIENT_CONFIG','READ_ONLY_CONNECTION','WORKSPACE',
    'DB_INSPECT','BASELINE','CLI_DRY_RUN','BACKUP','PUBLIC_RECEIPT'
})


def run_safely(action):
    """Report only the last fixed phase; raw cloud errors may contain credentials."""
    phase=['START']
    def mark(name):
        require(name in SAFE_PHASES,'Неизвестный этап диагностики.')
        phase[0]=name
    try:
        action(mark)
        return 0
    except Exception:
        print('ORBITA_CLOUD_FAILURE_PHASE='+phase[0])
        print('Процесс остановлен. Причина и сырые ответы скрыты; автоматического повтора нет.')
        return 1


def workspace(root,temporary):
    work=Path(temporary)/'cli';(work/'supabase/migrations').mkdir(parents=True)
    (work/'supabase/config.toml').write_text('project_id = "orbita_migration_runner"\n[db]\nmajor_version = 17\n[db.migrations]\nenabled = true\n[db.seed]\nenabled = false\n')
    shutil.copyfile(Path(root)/'supabase/migrations'/LOCK['migration'],work/'supabase/migrations'/LOCK['migration'])
    return work


def execute(context,db,workdir,root,temporary,public_dir,backup_dir,passphrase,preview=None,on_phase=None):
    """Зависимости передаются явно для отрицательных локальных тестов."""
    if on_phase is None:on_phase=lambda phase:None
    on_phase('DB_INSPECT')
    before=inspect(db)
    if context['operation']=='inspect':
        on_phase('PUBLIC_RECEIPT')
        receipt={'status':'read_only_inspection','run_id':context['run_id'],'source_sha':context['sha'],
            'project_ref':context['expected_ref'],'observed':before,
            'next':'Оценка оператором; этот режим не разрешает повторное применение или repair.'}
        Path(public_dir).mkdir(parents=True,exist_ok=True)
        (Path(public_dir)/'inspection.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
        return receipt
    require_initial(before)
    on_phase('BASELINE')
    baseline=baseline_fingerprint(db)
    on_phase('CLI_DRY_RUN')
    plan=parse_dry_run(db.cli(workdir,True))
    if context['operation']=='preview':
        on_phase('BACKUP')
        backup=create_backup(db,before,passphrase,temporary,backup_dir,root)
        on_phase('PUBLIC_RECEIPT')
        receipt={'status':'preview_passed','run_id':context['run_id'],'source_sha':context['sha'],
            'project_ref':context['expected_ref'],'migration_sha256':LOCK['migration_sha256'],
            'version':LOCK['version'],'pending':plan,'auth_users':before['auth_users'],
            'objects_absent':True,'baseline_fingerprint':baseline,'backup':backup,
            'limitation':'Dry-run не исполняет все SQL. Scoped restore не доказывает полное восстановление Supabase.'}
        Path(public_dir).mkdir(parents=True,exist_ok=True)
        (Path(public_dir)/'preview.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
        return receipt
    require(context['operation']=='apply' and preview is not None,'Применение без предварительного отчёта запрещено.')
    require(preview.get('baseline_fingerprint')==baseline,'Исходная схема или строки изменились после снимка; нужен новый preview.')
    # После этой отметки любой неизвестный исход рассматривается консервативно.
    receipt={'status':'apply_outcome_unknown','run_id':context['run_id'],'source_sha':context['sha'],
        'project_ref':context['expected_ref'],'version':LOCK['version'],'migration_sha256':LOCK['migration_sha256']}
    Path(public_dir).mkdir(parents=True,exist_ok=True)
    target=Path(public_dir)/'apply.json'
    target.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
    try:
        db.cli(workdir,False)  # Ровно один вызов; ни повторов, ни repair/reset.
        details=postflight(db)
        receipt.update({'status':'applied_and_catalog_verified','catalog':details})
        target.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
        return receipt
    except Exception:
        # Даже если следующий SELECT возможен, не возобновляем запись.
        try:
            state=inspect(db)
            receipt['observed_after_error']={k:state[k] for k in ['auth_users','app_tables','private_schema','access_rpc','versions']}
        except Exception:
            receipt['readback']='unavailable'
        target.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
        raise GuardError('Итог применения требует расследования. Автоматический повтор запрещён.') from None


def main(on_phase=None):
    if on_phase is None:on_phase=lambda phase:None
    on_phase('GATE_FILE')
    os.umask(0o077)
    root=Path(os.environ['GITHUB_WORKSPACE'])
    gate=Path(os.environ['RUNNER_TEMP'])/'orbita-migration-gate.json'
    require(gate.is_file(),'До выдачи секретов должен пройти независимый GitHub gate.')
    approved=json.loads(gate.read_text());context=approved['context']
    on_phase('SOURCE_VALIDATION')
    validate_request(context,root)
    actual=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    require(actual==context['sha'],'После допуска checkout изменился.')
    on_phase('DATABASE_URL')
    validate_connection(os.environ.get('ORBITA_DATABASE_URL',''),context['expected_ref'])
    on_phase('CLI_VERSION')
    binary=shutil.which('supabase');require(binary is not None,'CLI не установлен.')
    result=subprocess.run([binary,'--version'],env=restricted_process_env(),capture_output=True,text=True,timeout=10)
    require(result.returncode==0 and result.stdout.strip()==LOCK['cli_version'],'Неподходящая версия CLI.')
    public_dir=root/'build/migration-public';backup_dir=root/'build/migration-backup'
    with tempfile.TemporaryDirectory(prefix='orbita-migration-',dir=os.environ['RUNNER_TEMP']) as directory:
        temporary=Path(directory)
        on_phase('CA_CONFIG')
        ca=os.environ.get('ORBITA_DATABASE_CA_PEM','')
        require(ca.startswith('-----BEGIN CERTIFICATE-----'),'Нужен проверенный публичный сертификат CA из Dashboard.')
        ca_file=temporary/'ca.pem';ca_file.write_text(ca)
        read_only=context['operation'] in ('preview','inspect')
        on_phase('DB_CLIENT_CONFIG')
        db=Database(os.environ['ORBITA_DATABASE_URL'],context['expected_ref'],os.environ.get('PGPASSWORD',''),ca_file,
                    read_only=read_only)
        if read_only:
            on_phase('READ_ONLY_CONNECTION')
            try:
                setting=db.query('show default_transaction_read_only;')
            except Exception:
                print('ORBITA_CONNECTION_ERROR_CATEGORY='+db.failure_category)
                raise
            if setting!='on':print('ORBITA_CONNECTION_ERROR_CATEGORY=READ_ONLY_NOT_CONFIRMED')
            require(setting=='on',
                    'Сервер не подтвердил READ ONLY для предварительных подключений.')
        on_phase('WORKSPACE')
        work=workspace(root,temporary)
        receipt=execute(context,db,work,root,temporary,public_dir,backup_dir,
            os.environ.get('ORBITA_BACKUP_PASSPHRASE',''),approved.get('preview'),on_phase=on_phase)
    messages={'preview_passed':'Предварительная проверка завершена.',
        'applied_and_catalog_verified':'Миграция применена; структура проверена.',
        'read_only_inspection':'Read-only состояние получено; повторное применение не разрешено.'}
    print(messages[receipt['status']])


if __name__=='__main__':
    raise SystemExit(run_safely(main))
