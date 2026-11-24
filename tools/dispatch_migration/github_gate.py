"""Future GitHub admission before DB secrets; never dispatches or changes settings."""
from pathlib import Path
import io
import json
import os
import subprocess
import zipfile
import hashlib
from .policy import (LOCK, ENV_ONLY, require, validate_source, validate_request, validate_connection,
                        validate_environment, validate_preview)
from .recovery import FAILED_GUARDED_JOB_ID, validate_failed_run, validate_prior_attempts
from tools.migration_preflight import DISPATCH_SECRETS, SettingsError, report_settings_failure
from github_gate import github  # read-only gh api helper; no changes to the old gate

MAPPING={'event':'GITHUB_EVENT_NAME','operation':'ORBITA_OPERATION','repository':'GITHUB_REPOSITORY',
 'git_ref':'GITHUB_REF','attempt':'GITHUB_RUN_ATTEMPT','sha':'GITHUB_SHA','run_id':'GITHUB_RUN_ID',
 'repo_enabled':'ORBITA_DISPATCH_REPO_ENABLED','env_enabled':'ORBITA_DISPATCH_CLOUD_ENABLED',
 'allowed_sha':'ORBITA_DISPATCH_ALLOWED_SHA','allowed_operation':'ORBITA_DISPATCH_ALLOWED_OPERATION',
 'approved_sha':'ORBITA_REQUEST_SHA','expected_ref':'ORBITA_EXPECTED_REF','forbidden_ref':'ORBITA_FORBIDDEN_REF',
 'requested_ref':'ORBITA_REQUEST_REF','preview_run_id':'ORBITA_PREVIEW_RUN_ID','backup_sha256':'ORBITA_BACKUP_SHA256',
 'recovery_run_id':'ORBITA_RECOVERY_RUN_ID'}

def context():
    root=Path(os.environ['GITHUB_WORKSPACE'])
    c={k:os.environ.get(v,'') for k,v in MAPPING.items()}
    c['checkout_sha']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    require(not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),'Unclean checkout.')
    return root,c

def entry():
    root,c=context()
    outside={key:os.environ.get('OUTSIDE_'+key,'') for key in ENV_ONLY}
    validate_source(c,root,outside)
    if c['operation'] in ('preview', 'apply'):
        exposed = [name for name in DISPATCH_SECRETS if os.environ.get('OUTSIDE_' + name) == 'true']
        if exposed:
            raise SettingsError(exposed, environment_only=True)
    with open(os.environ['GITHUB_OUTPUT'],'a') as f:f.write('admitted=true\n')

def artifact(run_id, items, name, filename, limit):
    matches=[a for a in items if a['name']==name and not a['expired']]
    require(len(matches)==1,'Unique retained artifact required.')
    raw=subprocess.run(['gh','api',f'repos/{LOCK["repository"]}/actions/artifacts/{matches[0]["id"]}/zip'],capture_output=True,timeout=60)
    require(raw.returncode==0 and len(raw.stdout)<limit,'Artifact unavailable/oversized.')
    with zipfile.ZipFile(io.BytesIO(raw.stdout)) as archive:
        require(archive.namelist()==[filename] and archive.getinfo(filename).file_size<limit,'Unexpected artifact contents.')
        return archive.read(filename)


def verify_recovery_incident(base, run_id):
    route = base + '/actions/runs/' + run_id
    log = subprocess.run(
        ['gh', 'api', base + '/actions/jobs/' + str(FAILED_GUARDED_JOB_ID) + '/logs'],
        capture_output=True, timeout=60,
    )
    require(log.returncode == 0 and 0 < len(log.stdout) < 1024 * 1024,
            'Historical guarded-job log unavailable.')
    validate_failed_run(
        github(route), github(route + '/jobs?per_page=100'),
        github(route + '/artifacts?per_page=100'), github(route + '/approvals'),
        log=log.stdout.decode('utf-8'),
    )


def gate():
    root,c=context();validate_request(c,root)
    validate_connection(os.environ['ORBITA_DATABASE_URL'],LOCK['project_ref'])
    base=f'repos/{LOCK["repository"]}'
    environment=github(base+'/environments/'+LOCK['environment'])
    validate_environment(environment,github(base+'/environments/'+LOCK['environment']+'/deployment-branch-policies'),
                         github(base+'/actions/runs/'+c['run_id']+'/approvals'))
    proof=None
    recovery_run_id = c.get('recovery_run_id') or None
    if c['operation']=='apply' or recovery_run_id:
        pages=github(base+'/actions/workflows/'+LOCK['workflow']+'/runs?per_page=100',True)
        runs = [run for page in pages for run in page['workflow_runs']]
        require(pages and all(page.get('total_count') == len(runs) for page in pages),
                'Complete Dispatch workflow history is required.')
        validate_prior_attempts(
            runs, c['run_id'], recovery_run_id,
            operation=c['operation'], current_sha=c['sha'],
        )
        if recovery_run_id:
            verify_recovery_incident(base, recovery_run_id)
    if c['operation']=='apply':
        run=github(base+'/actions/runs/'+c['preview_run_id'])
        items=github(base+'/actions/runs/'+c['preview_run_id']+'/artifacts')['artifacts']
        proof=json.loads(artifact(c['preview_run_id'],items,'ORBITA-dispatch-preview-'+c['preview_run_id'],'preview.json',65536))
        validate_preview(run,proof,c)
        backup=artifact(c['preview_run_id'],items,'ORBITA-dispatch-backup-'+c['preview_run_id'],'snapshot.tar.gpg',64*1024*1024)
        require(hashlib.sha256(backup).hexdigest()==c['backup_sha256'],'Encrypted backup digest mismatch.')
    path=Path(os.environ['RUNNER_TEMP'])/'orbita-dispatch-gate.json'
    path.write_text(json.dumps({'context':c,'preview':proof})+'\n');path.chmod(0o600)
    print('Independent orders admission verified; no DB connection yet.')

if __name__=='__main__':
    try:
        import sys
        require(sys.argv[1:] in (['entry'],['gate']),'Explicit gate command required.')
        entry() if sys.argv[1]=='entry' else gate()
    except SettingsError as exc:
        report_settings_failure(exc)
        raise SystemExit(1)
    except BaseException:
        print('DISPATCH_ADMISSION_REJECTED; no DB secrets or raw errors emitted.')
        raise SystemExit(1)
