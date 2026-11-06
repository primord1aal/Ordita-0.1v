"""Предварительный допуск без Environment, секретов, GitHub API и БД."""
from pathlib import Path
import os
import subprocess

from policy import require,validate_repository_admission


def main():
    root=Path(os.environ['GITHUB_WORKSPACE'])
    sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    require(not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),
            'Checkout содержит незакоммиченные изменения.')
    mapping={'event':'GITHUB_EVENT_NAME','operation':'ORBITA_OPERATION','repo_enabled':'ORBITA_REPO_ENABLED',
        'repository':'GITHUB_REPOSITORY','git_ref':'GITHUB_REF','attempt':'GITHUB_RUN_ATTEMPT',
        'sha':'GITHUB_SHA','approved_sha':'ORBITA_REQUEST_SHA'}
    context={key:os.environ.get(value,'') for key,value in mapping.items()}
    context['checkout_sha']=sha
    outside_environment={
        'ORBITA_CLOUD_MIGRATIONS_ENABLED':os.environ.get('ORBITA_OUTSIDE_ENV_ENABLED',''),
        'ORBITA_ALLOWED_MIGRATION_SHA':os.environ.get('ORBITA_OUTSIDE_ENV_ALLOWED_SHA','')}
    validate_repository_admission(context,outside_environment)
    # Только булев результат. Ни SHA, ни значения конфигурации в outputs не нужны.
    with open(os.environ['GITHUB_OUTPUT'],'a') as output:output.write('repo_enabled=true\n')
    print('Предварительный допуск репозитория проверен. Допуск Environment ещё не получен.')


if __name__=='__main__':
    try:main()
    except Exception:
        print('Предварительный допуск отклонён. Environment, секреты и БД не использовались.')
        raise SystemExit(1)
