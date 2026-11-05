"""Допуск GitHub проверяется до выдачи процессу пароля БД."""
from pathlib import Path
import json
import os
import subprocess
import zipfile
import io
import hashlib

from policy import (LOCK,REPOSITORY,GuardError,require,validate_request,validate_connection,
                    validate_environment,validate_no_prior_apply,validate_preview)


def github(endpoint,paginate=False):
    args=['gh','api',endpoint]
    if paginate:args+=['--paginate','--slurp']
    result=subprocess.run(args,capture_output=True,timeout=60)
    require(result.returncode==0,'Не удалось проверить метаданные GitHub; подключение к БД запрещено.')
    try:return json.loads(result.stdout)
    except (ValueError,TypeError):raise GuardError('Неожиданный ответ GitHub.') from None


def context_from_env():
    root=Path(os.environ['GITHUB_WORKSPACE'])
    sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    require(not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),
            'Checkout содержит незакоммиченные изменения.')
    mapping={'event':'GITHUB_EVENT_NAME','operation':'ORBITA_OPERATION','enabled':'ORBITA_CLOUD_ENABLED',
        'repository':'GITHUB_REPOSITORY','git_ref':'GITHUB_REF','attempt':'GITHUB_RUN_ATTEMPT',
        'sha':'GITHUB_SHA','approved_sha':'ORBITA_REQUEST_SHA','allowed_sha':'ORBITA_ALLOWED_SHA',
        'expected_ref':'ORBITA_EXPECTED_REF','forbidden_ref':'ORBITA_FORBIDDEN_REF',
        'requested_ref':'ORBITA_REQUEST_REF','preview_run_id':'ORBITA_PREVIEW_RUN_ID',
        'backup_sha256':'ORBITA_BACKUP_SHA256','run_id':'GITHUB_RUN_ID'}
    context={key:os.environ.get(value,'') for key,value in mapping.items()}
    context['checkout_sha']=sha
    validate_request(context,root)
    validate_connection(os.environ.get('ORBITA_DATABASE_URL',''),context['expected_ref'])
    return context


def preview_receipt(context):
    run_id=context['preview_run_id']
    require(run_id.isdigit(),'Некорректный номер предварительного запуска.')
    run=github(f'repos/{REPOSITORY}/actions/runs/{run_id}')
    artifacts=github(f'repos/{REPOSITORY}/actions/runs/{run_id}/artifacts')['artifacts']
    matches=[a for a in artifacts if a['name']==f'ORBITA-migration-preview-{run_id}' and not a['expired']]
    require(len(matches)==1,'Не найден единственный действительный предварительный отчёт.')
    artifact_id=matches[0]['id']
    result=subprocess.run(['gh','api',f'repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip'],capture_output=True,timeout=60)
    require(result.returncode==0 and len(result.stdout)<1024*1024,'Не удалось получить предварительный отчёт.')
    try:
        with zipfile.ZipFile(io.BytesIO(result.stdout)) as archive:
            require(archive.namelist()==['preview.json'],'Неожиданный состав предварительного отчёта.')
            require(archive.getinfo('preview.json').file_size<65536,'Предварительный отчёт слишком велик.')
            receipt=json.loads(archive.read('preview.json'))
    except (ValueError,zipfile.BadZipFile,KeyError):raise GuardError('Повреждён предварительный отчёт.') from None
    validate_preview(run,receipt,context)
    backups=[a for a in artifacts if a['name']==f'ORBITA-migration-backup-{run_id}' and not a['expired']]
    require(len(backups)==1,'Зашифрованный снимок отсутствует или уже истёк.')
    result=subprocess.run(['gh','api',f'repos/{REPOSITORY}/actions/artifacts/{backups[0]["id"]}/zip'],capture_output=True,timeout=60)
    require(result.returncode==0 and len(result.stdout)<16*1024*1024,'Не удалось проверить зашифрованный снимок.')
    try:
        with zipfile.ZipFile(io.BytesIO(result.stdout)) as archive:
            require(archive.namelist()==['snapshot.tar.gpg'] and archive.getinfo('snapshot.tar.gpg').file_size<16*1024*1024,
                    'Неожиданный состав зашифрованного снимка.')
            require(hashlib.sha256(archive.read('snapshot.tar.gpg')).hexdigest()==context['backup_sha256'],
                    'Зашифрованный снимок не совпал с подтверждённым хешем.')
    except (ValueError,zipfile.BadZipFile,KeyError):raise GuardError('Повреждён снимок.') from None
    return receipt


def gate():
    context=context_from_env()
    environment=github(f'repos/{REPOSITORY}/environments/{LOCK["environment"]}')
    branches=github(f'repos/{REPOSITORY}/environments/{LOCK["environment"]}/deployment-branch-policies')
    reviews=github(f'repos/{REPOSITORY}/actions/runs/{context["run_id"]}/approvals')
    validate_environment(environment,branches,reviews,REPOSITORY.split('/')[0])
    receipt=None
    if context['operation']=='apply':
        pages=github(f'repos/{REPOSITORY}/actions/workflows/{LOCK["workflow"]}/runs?per_page=100',True)
        runs=[run for page in pages for run in page['workflow_runs']]
        validate_no_prior_apply(runs,context['run_id'])
        receipt=preview_receipt(context)
    # Никаких паролей. Файл создаётся до шага выдачи DB/backup секретов.
    output=Path(os.environ['RUNNER_TEMP'])/'orbita-migration-gate.json'
    output.write_text(json.dumps({'context':context,'preview':receipt},ensure_ascii=False)+'\n')
    output.chmod(0o600)
    print('Ручной допуск Environment, ветка, коммит и параметры назначения проверены. БД ещё не подключалась.')


if __name__=='__main__':
    try:gate()
    except Exception:
        print('Допуск миграции отклонён. Проверьте ручное одобрение и конфигурацию GitHub; БД не подключалась.')
        raise SystemExit(1)
