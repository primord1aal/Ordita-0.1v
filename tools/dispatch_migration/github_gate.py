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
from .recovery import DISPATCH_WORKFLOW_ID, reviewed_guarded_log, validate_failed_run, validate_prior_attempts
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


def dispatch_runs(base):
    endpoint = f'{base}/actions/workflows/{DISPATCH_WORKFLOW_ID}/runs?per_page=100&page='
    first = github(endpoint + '1')
    count = first.get('total_count')
    require(type(count) is int and count >= 0, 'Invalid workflow history count.')
    runs = []
    for page in range(1, max(1, (count + 99) // 100) + 1):
        payload = first if page == 1 else github(endpoint + str(page))
        items = payload.get('workflow_runs')
        require(payload.get('total_count') == count and isinstance(items, list)
                and len(items) == min(100, count - len(runs)), 'Incomplete Dispatch workflow history.')
        runs.extend(items)
    return runs


def verify_recovery_incident(base, run_id, phase):
    route = base + '/actions/runs/' + run_id
    phase('RECOVERY_LOG_PROOF')
    log = reviewed_guarded_log()
    phase('RECOVERY_RUN')
    run = github(route)
    phase('RECOVERY_JOBS')
    jobs = github(route + '/jobs?per_page=100')
    phase('RECOVERY_ARTIFACTS')
    artifacts = github(route + '/artifacts?per_page=100')
    phase('RECOVERY_OWNER_APPROVAL')
    approvals = github(route + '/approvals')
    phase('RECOVERY_EVIDENCE')
    validate_failed_run(run, jobs, artifacts, approvals, log=log)


def check_protected_environment(base, approval_run, phase):
    route = base + '/environments/' + LOCK['environment']
    phase('ENVIRONMENT')
    environment = github(route)
    phase('ENVIRONMENT_BRANCHES')
    branches = github(route + '/deployment-branch-policies')
    phase('OWNER_APPROVAL')
    approvals = github(base + '/actions/runs/' + approval_run + '/approvals')
    phase('ENVIRONMENT_POLICY')
    validate_environment(environment, branches, approvals)


def check_run_history(base, c, phase):
    phase('DISPATCH_HISTORY')
    runs = dispatch_runs(base)
    phase('RUN_PROVENANCE')
    recovery_run_id = c.get('recovery_run_id') or None
    validate_prior_attempts(runs, c['run_id'], recovery_run_id,
                            operation=c['operation'], current_sha=c['sha'])
    if recovery_run_id:
        verify_recovery_incident(base, recovery_run_id, phase)


def recovery_precheck(phase):
    phase('RECOVERY_SOURCE')
    root, c = context()
    validate_source(c, root)
    require(c.get('recovery_run_id'), 'Specific recovery run is required.')
    base = f'repos/{LOCK["repository"]}'
    check_run_history(base, c, phase)
    check_protected_environment(base, c['recovery_run_id'], phase)
    print('Recovery archive and Environment rules verified. Current-run approval is required.')


def gate(phase=lambda _phase: None):
    phase('REQUEST')
    root,c=context();validate_request(c,root)
    phase('TARGET')
    validate_connection(os.environ['ORBITA_DATABASE_URL'],LOCK['project_ref'])
    base=f'repos/{LOCK["repository"]}'
    check_protected_environment(base, c['run_id'], phase)
    proof=None
    if c['operation']=='apply' or c.get('recovery_run_id'):
        check_run_history(base, c, phase)
    if c['operation']=='apply':
        phase('PREVIEW_RECEIPT')
        run=github(base+'/actions/runs/'+c['preview_run_id'])
        items=github(base+'/actions/runs/'+c['preview_run_id']+'/artifacts')['artifacts']
        proof=json.loads(artifact(c['preview_run_id'],items,'ORBITA-dispatch-preview-'+c['preview_run_id'],'preview.json',65536))
        validate_preview(run,proof,c)
        phase('PREVIEW_BACKUP')
        backup=artifact(c['preview_run_id'],items,'ORBITA-dispatch-backup-'+c['preview_run_id'],'snapshot.tar.gpg',64*1024*1024)
        require(hashlib.sha256(backup).hexdigest()==c['backup_sha256'],'Encrypted backup digest mismatch.')
    phase('GATE_RECEIPT')
    path=Path(os.environ['RUNNER_TEMP'])/'orbita-dispatch-gate.json'
    path.write_text(json.dumps({'context':c,'preview':proof})+'\n');path.chmod(0o600)
    print('Independent orders admission verified; no DB connection yet.')

def cli(argv):
    stage = 'STARTUP'

    def phase(name):
        nonlocal stage
        stage = name

    try:
        if argv == ['entry']:
            phase('SOURCE')
            entry()
        elif argv == ['gate']:
            gate(phase)
        elif argv == ['recovery-precheck']:
            recovery_precheck(phase)
        else:
            require(False, 'Explicit gate command required.')
    except SettingsError as exc:
        report_settings_failure(exc)
        return 1
    except BaseException:
        print(f'DISPATCH_ADMISSION_REJECTED: stage={stage}; no DB secrets or raw errors emitted.')
        return 1
    return 0


if __name__=='__main__':
    import sys
    raise SystemExit(cli(sys.argv[1:]))
