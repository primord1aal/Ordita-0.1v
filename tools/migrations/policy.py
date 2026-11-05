"""Проверки до подключения к БД. Никаких Cloud SDK или секретов в сообщениях."""
from pathlib import Path
from urllib.parse import urlparse,parse_qs
import hashlib
import json
import re

LOCK=json.loads((Path(__file__).parent/'lock.json').read_text())
REPOSITORY='primord1aal/Ordita-0.1v'
REF_PATTERN=re.compile(r'^[a-z0-9]{20}$')
SHA_PATTERN=re.compile(r'^[a-f0-9]{40}$')


class GuardError(Exception):
    pass


def require(condition,message):
    if not condition:raise GuardError(message)


def validate_request(context,repository_root):
    require(context.get('event')=='workflow_dispatch','Облачный режим допустим только при ручном событии.')
    require(context.get('operation') in ('preview','apply','inspect'),'Неизвестный режим миграции.')
    require(context.get('enabled')=='true','Облачные миграции выключены. Подготовка не даёт разрешения.')
    require(context.get('repository')==REPOSITORY,'Неверный репозиторий.')
    require(context.get('git_ref')=='refs/heads/'+LOCK['branch'],'Эта ветка не разрешена для миграции.')
    require(str(context.get('attempt'))=='1','Повтор запуска запрещён; сначала расследуйте предыдущий результат.')
    sha=context.get('sha','')
    require(bool(SHA_PATTERN.fullmatch(sha)),'Нужен полный SHA коммита.')
    require(context.get('approved_sha')==sha==context.get('allowed_sha')==context.get('checkout_sha'),
            'Коммит запроса, допуска, checkout и запуска не совпадает.')
    expected=context.get('expected_ref','');forbidden=context.get('forbidden_ref','')
    require(bool(REF_PATTERN.fullmatch(expected)) and bool(REF_PATTERN.fullmatch(forbidden)),
            'Не заданы корректные разрешённый и запрещённый Ref.')
    require(expected!=forbidden and context.get('requested_ref')==expected,'Целевой Ref не подтверждён.')
    files=sorted((Path(repository_root)/'supabase/migrations').glob('*.sql'))
    require([p.name for p in files]==[LOCK['migration']],'Разрешён только один согласованный файл миграции.')
    require(hashlib.sha256(files[0].read_bytes()).hexdigest()==LOCK['migration_sha256'],'Содержимое миграции изменилось.')
    if context['operation']=='apply':
        require(str(context.get('preview_run_id','')).isdigit(),'Нужен номер успешного предварительного запуска.')
        require(bool(re.fullmatch(r'[a-f0-9]{64}',context.get('backup_sha256',''))),'Нужно подтвердить хеш резервного снимка.')


def validate_connection(url,expected_ref):
    # Пароль должен быть только PGPASSWORD, поэтому его нет даже в argv.
    try:
        uri=urlparse(url);port=uri.port;query=parse_qs(uri.query,strict_parsing=True)
    except (ValueError,TypeError):raise GuardError('Некорректные параметры соединения.') from None
    require(uri.scheme in ('postgresql','postgres'),'Нужен URL PostgreSQL.')
    require(uri.password is None,'Пароль в URL запрещён; используйте защищённый PGPASSWORD.')
    require(port==5432 and uri.path=='/postgres' and not uri.fragment,'Нужны Session/direct, порт 5432 и база postgres.')
    direct=uri.hostname==f'db.{expected_ref}.supabase.co' and uri.username=='postgres'
    pooler=bool(re.fullmatch(r'[a-z0-9.-]+\.pooler\.supabase\.com',uri.hostname or '')) and uri.username==f'postgres.{expected_ref}'
    require(direct or pooler,'Адрес или пользователь соединения не соответствует разрешённому Ref.')
    require(query=={'sslmode':['verify-full']},'Разрешена только полная проверка TLS, без дополнительных параметров URL.')


def validate_environment(environment,branch_policies,reviews,owner):
    require(environment.get('name')==LOCK['environment'],'Не найдено точное защищённое Environment.')
    rules=environment.get('protection_rules',[])
    reviewers=[rule for rule in rules if rule.get('type')=='required_reviewers']
    require(any(any(item.get('type')=='User' and item.get('reviewer',{}).get('login')==owner
                for item in rule.get('reviewers',[])) for rule in reviewers),
            'В Environment требуется ручной допуск владельца.')
    require(environment.get('deployment_branch_policy')=={'protected_branches':False,'custom_branch_policies':True},
            'Нужна точная политика разрешённых веток Environment.')
    policies=branch_policies.get('branch_policies',[])
    require(len(policies)==1 and policies[0].get('name')==LOCK['branch'] and policies[0].get('type')=='branch',
            'Environment должен разрешать только согласованную ветку, без тегов/масок.')
    approved=any(review.get('state')=='approved' and review.get('user',{}).get('login')==owner
        and any(e.get('id')==environment.get('id') for e in review.get('environments',[])) for review in reviews)
    require(approved,'В этом запуске отсутствует фактическое ручное одобрение Environment владельцем.')


def validate_no_prior_apply(runs,current_run_id):
    # Консервативно: любая прежняя попытка apply требует отдельного расследования.
    # Даже failed/cancelled не означает, что COMMIT не произошёл.
    prior=[run for run in runs if int(run['id'])<int(current_run_id)
           and run.get('event')=='workflow_dispatch'
           and run.get('display_title','').startswith('Орбита 3Б: apply @')]
    require(not prior,'Уже есть попытка применения. Автоматический повтор запрещён: сначала read-only расследование.')


def validate_preview(run,receipt,context):
    require(str(run.get('id'))==str(context['preview_run_id']) and run.get('conclusion')=='success',
            'Предварительный запуск не завершился успешно.')
    require(run.get('event')=='workflow_dispatch' and run.get('head_sha')==context['sha']
            and run.get('head_branch')==LOCK['branch'] and run.get('run_attempt')==1
            and run.get('display_title','').startswith('Орбита 3Б: preview @'),
            'Предварительный запуск принадлежит другому событию/коммиту/ветке.')
    require(receipt.get('source_sha')==context['sha'] and receipt.get('project_ref')==context['expected_ref']
            and str(receipt.get('run_id'))==str(context['preview_run_id'])
            and receipt.get('migration_sha256')==LOCK['migration_sha256'],
            'Предварительный отчёт не соответствует допускаемой миграции.')
    require(receipt.get('pending')==[LOCK['version']] and receipt.get('auth_users')==0
            and receipt.get('objects_absent') is True,'Предварительные условия не выполнены.')
    backup=receipt.get('backup',{})
    require(backup.get('encrypted_sha256')==context['backup_sha256'] and backup.get('decryption_checked') is True
            and backup.get('local_restore_checked') is True,'Резервный снимок не подтверждён.')


def parse_dry_run(output):
    # CLI может печатать ANSI-цвета. При неожиданном формате отказываем.
    text=re.sub(r'\x1b\[[0-9;]*m','',output)
    files=re.findall(r'\b[0-9]+_[A-Za-z0-9_-]+\.sql\b',text)
    require('Would push these migrations:' in text and files==[LOCK['migration']],
            'Dry-run должен показать ровно одну ожидающую миграцию.')
    require('Would seed' not in text and 'Would create custom roles' not in text,
            'План содержит дополнительные операции.')
    return [LOCK['version']]
