from pathlib import Path
import hashlib
import json
import re
from tools.orders_migration.admission import GuardError, require, validate_connection
from tools.dispatch_migration.policy import validate_environment as validate_shared_environment

LOCK = json.loads((Path(__file__).parent / 'lock.json').read_text())
HEX40 = re.compile('[a-f0-9]{40}')
HEX64 = re.compile('[a-f0-9]{64}')
ENV_ONLY = ('ORBITA_DISPATCH_CLOUD_ENABLED', 'ORBITA_DISPATCH_ALLOWED_SHA', 'ORBITA_DISPATCH_ALLOWED_OPERATION')

def versions():
    return [LOCK['first_version'], LOCK['second_version'], LOCK['third_version']]

def history(after=False):
    result = [dict(version=LOCK[p+'version'],name=LOCK[p+'name'],entries=1,sha256=LOCK[p+'sha256'])
              for p in ('first_', 'second_', 'third_')]
    if after:
        result.append(dict(version=LOCK['version'],name=LOCK['name'],entries=1,sha256=LOCK['sha256']))
    return result

def sources(root):
    root=Path(root)
    result=[]
    for prefix in ('first_', 'second_', 'third_', ''):
        path=root/LOCK[prefix+'path']
        require(path.is_file() and not path.is_symlink(), 'Fixed SQL missing/linked.')
        raw=path.read_bytes()
        require(hashlib.sha256(raw).hexdigest()==LOCK[prefix+'sha256'], 'SQL checksum mismatch.')
        result.append(raw)
    return result

def validate_source(c,root,outside=None):
    require(c.get('event')=='workflow_dispatch' and c.get('operation') in ('preview','apply','inspect'), 'Manual operation required.')
    require(c.get('repository')==LOCK['repository'] and c.get('git_ref')=='refs/heads/'+LOCK['branch'], 'Wrong repository/branch.')
    require(str(c.get('attempt'))=='1' and c.get('repo_enabled')=='true','No retry/repository admission.')
    require(HEX40.fullmatch(c.get('sha','')) and c['sha']==c.get('approved_sha')==c.get('checkout_sha'),'Exact source SHA required.')
    if outside is not None:
        require(all(not outside.get(k) for k in ENV_ONLY),'Admission controls outside Environment.')
    sources(root)
    from .state import baseline_reference
    baseline_reference()

def validate_request(c,root):
    validate_source(c,root)
    from tools.migration_preflight import validate_admission_settings
    validate_admission_settings(c, LOCK['project_ref'], LOCK['forbidden_ref'])
    if c['operation']=='apply':
        require(str(c.get('preview_run_id','')).isdigit() and HEX64.fullmatch(c.get('backup_sha256','')),
                'Verified Preview and backup required.')

def validate_environment(environment,branches,reviews):
    validate_shared_environment(environment,branches,reviews,lock=LOCK)

def validate_receipt(receipt,c):
    require(receipt.get('status')=='preview_passed' and receipt.get('source_sha')==c['sha']
      and str(receipt.get('run_id'))==c['preview_run_id'] and receipt.get('project_ref')==LOCK['project_ref']
      and receipt.get('sql_sha256')==LOCK['sha256'] and receipt.get('executor')==LOCK['executor']
      and receipt.get('before_versions')==versions() and receipt.get('pending')==[LOCK['version']], 'Preview mismatch.')
    backup=receipt.get('backup',{})
    require(backup.get('encrypted_sha256')==c['backup_sha256'] and backup.get('decryption_checked') is True
      and backup.get('restore_checked') is True and backup.get('rehearsal_checked') is True
      and backup.get('network')=='none' and HEX64.fullmatch(receipt.get('state_sha256','')),
      'Verified encrypted backup and isolated restore required.')

def validate_preview(run,receipt,c):
    require(str(run.get('id'))==c['preview_run_id'] and run.get('conclusion')=='success'
      and run.get('event')=='workflow_dispatch' and run.get('run_attempt')==1 and run.get('head_sha')==c['sha']
      and run.get('head_branch')==LOCK['branch'] and run.get('path')=='.github/workflows/'+LOCK['workflow']
      and run.get('display_title','').startswith('Орбита Maps: preview @'), 'Preview provenance mismatch.')
    validate_receipt(receipt,c)

def no_prior_apply(runs,current):
    require(not any(int(r['id'])<int(current) and r.get('event')=='workflow_dispatch'
      and r.get('display_title','').startswith('Орбита Maps: apply @') for r in runs),
      'Prior Apply attempt; read-only investigation required, no retry.')
