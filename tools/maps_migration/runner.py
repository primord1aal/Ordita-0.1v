"""Future gated operations. No CLI against cloud, no operation/retry on import."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
from tools.migration_preflight import SettingsError, report_settings_failure, validate_settings
from .policy import LOCK, GuardError, require, validate_request, validate_connection, sources, validate_receipt, versions
from .state import capture, validate_before, state_hash, protected_hash
from .atomic import body
from .backup import PreviewPhase, create, ignore_phase
from dbtools import Database, SAFE_CONNECTION_CATEGORIES

class MapsDatabase(Database):
    def apply_maps(self, root, expected):
        require(not self.read_only,'Read-only client cannot write.')
        return self.tool('psql',['--no-psqlrc','--set','ON_ERROR_STOP=1','-Atq','--dbname',self.url],
                         input=body(root,expected),timeout=120,atomic_write=True)

def execute(c, db, root, temporary, public, encrypted, passphrase='', proof=None, backup_factory=None, *, on_phase=ignore_phase):
    public=Path(public);public.mkdir(parents=True,exist_ok=True)
    on_phase(PreviewPhase.SOURCE_CATALOG)
    doc=capture(db)
    if c['operation']=='inspect':
        # Diagnostic does not renew admission or permit repair/retry.
        receipt={'status':'read_only_inspection','source_sha':c['sha'],'run_id':c['run_id'],
                 'versions':[r['version'] for r in doc['history']],
                 'state_sha256':state_hash(db),'no_retry_authorized':True}
        (public/'inspection.json').write_text(json.dumps(receipt)+'\n');return receipt
    on_phase(PreviewPhase.SOURCE_BASELINE)
    validate_before(doc)
    on_phase(PreviewPhase.SOURCE_FINGERPRINT)
    before=state_hash(db);protected=protected_hash(db)
    if c['operation']=='preview':
        kwargs={} if backup_factory is None else {'factory':backup_factory}
        backup=create(db,root,temporary,encrypted,passphrase,on_phase=on_phase,**kwargs)
        on_phase(PreviewPhase.RECHECK_SOURCE)
        require(state_hash(db)==before,'Preview source state changed.')
        on_phase(PreviewPhase.WRITE_RECEIPT)
        receipt={'status':'preview_passed','source_sha':c['sha'],'run_id':c['run_id'],
                 'project_ref':LOCK['project_ref'],'sql_sha256':LOCK['sha256'],'executor':LOCK['executor'],
                 'before_versions':versions(),'pending':[LOCK['version']],
                 'state_sha256':before,'backup':backup}
        (public/'preview.json').write_text(json.dumps(receipt,indent=2)+'\n');return receipt
    require(c['operation']=='apply' and isinstance(proof,dict)
            and proof.get('state_sha256')==before and proof.get('source_sha')==c['sha']
            and proof.get('project_ref')==LOCK['project_ref'] and proof.get('sql_sha256')==LOCK['sha256']
            and proof.get('status')=='preview_passed' and proof.get('executor')==LOCK['executor'],
            'Fresh proven preview required.')
    validate_receipt(proof,c)
    body(root,before)  # reject changed sources before recording a write attempt
    receipt={'status':'apply_outcome_unknown','source_sha':c['sha'],'run_id':c['run_id'],
             'sql_sha256':LOCK['sha256'],'project_ref':LOCK['project_ref']}
    target=public/'apply.json';target.write_text(json.dumps(receipt)+'\n')
    # A failure at/after this point NEVER loops, retries, repairs or resets.
    try:
        db.apply_maps(root,before)
        require(protected_hash(db)==protected,'Protected Auth/orders/dispatch state changed after apply.')
        after=capture(db)
        require([r['version'] for r in after['history']]==versions()+[LOCK['version']], 'Postflight history mismatch.')
        receipt['status']='applied_and_verified';target.write_text(json.dumps(receipt)+'\n');return receipt
    except BaseException:
        try:
            observed=capture(db)
            (public/'apply_inspection.json').write_text(json.dumps({
                'status':'read_only_after_apply_error','source_sha':c['sha'],
                'history':observed['history'],'state_sha256':state_hash(db),'no_retry_authorized':True})+'\n')
        except BaseException:
            pass
        raise GuardError('Apply result needs read-only investigation; no retry.') from None

def main(diagnostic=None):
    diagnostic = {} if diagnostic is None else diagnostic
    diagnostic['stage'] = 'LOCAL_SETUP'
    os.umask(0o077)
    root=Path(os.environ['GITHUB_WORKSPACE'])
    diagnostic['stage'] = 'GATE_LOAD'
    gate=Path(os.environ['RUNNER_TEMP'])/'orbita-maps-gate.json'
    require(gate.is_file(),'Independent GitHub gate required before DB secrets.')
    approved=json.loads(gate.read_text());c=approved['context']
    diagnostic['stage'] = 'REQUEST_VALIDATION'
    require(c.get('operation') in ('preview', 'apply', 'inspect'), 'Unsupported maps operation.')
    validate_request(c,root)
    applying = c['operation'] == 'apply'
    if applying:
        proof = approved.get('preview')
        require(isinstance(proof, dict), 'Verified preview receipt required before opening the database.')
        validate_receipt(proof, c)
    diagnostic['stage'] = 'CHECKOUT_VALIDATION'
    actual=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
    require(actual==c['sha'] and not subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip(),
            'Checkout changed after gate.')
    diagnostic['stage'] = 'URL_VALIDATION'
    url=os.environ.get('ORBITA_DATABASE_URL','');validate_connection(url,LOCK['project_ref'])
    validate_settings(c['operation'], LOCK['project_ref'])
    with tempfile.TemporaryDirectory(prefix='orbita-maps-',dir=os.environ['RUNNER_TEMP']) as directory:
        work=Path(directory);ca=work/'ca.pem'
        diagnostic['stage'] = 'CA_CONFIGURATION'
        ca.write_text(os.environ['ORBITA_DATABASE_CA_PEM'])
        diagnostic['stage'] = 'DB_CLIENT_CONFIGURATION'
        db=MapsDatabase(url,LOCK['project_ref'],os.environ.get('PGPASSWORD',''),ca,
                          read_only=not applying,
                          check_read_only_session=False)
        diagnostic['db'] = db
        diagnostic['stage'] = 'READ_ONLY_PROBE'
        require(db.query('show transaction_read_only;')=='on','Explicit read-only control query required.')
        diagnostic['stage'] = 'PREVIEW_OR_APPLY_EXECUTION'
        execute(c,db,root,work,root/'build/maps-public',root/'build/maps-backup',
                os.environ.get('ORBITA_ORDERS_BACKUP_PASSPHRASE',''),approved.get('preview'),
                on_phase=lambda phase: diagnostic.update(stage=phase))

_DIAGNOSTIC_STAGES = frozenset((
    'STARTUP', 'LOCAL_SETUP', 'GATE_LOAD', 'REQUEST_VALIDATION',
    'CHECKOUT_VALIDATION', 'URL_VALIDATION', 'CA_CONFIGURATION',
    'DB_CLIENT_CONFIGURATION', 'READ_ONLY_PROBE', 'PREVIEW_OR_APPLY_EXECUTION',
))

def cli():
    diagnostic = {'stage': 'STARTUP', 'db': None}
    try:
        main(diagnostic)
        return 0
    except SettingsError as error:
        report_settings_failure(error)
        return 1
    except BaseException:
        stage = diagnostic.get('stage')
        if isinstance(stage, PreviewPhase):
            stage = stage.name
        elif not isinstance(stage, str) or stage not in _DIAGNOSTIC_STAGES:
            stage = 'UNKNOWN'
        category = 'NOT_CONNECTED'
        db = diagnostic.get('db')
        if db is not None:
            try:
                candidate = db.failure_category
            except BaseException:
                candidate = None
            category = candidate if isinstance(candidate, str) and candidate in SAFE_CONNECTION_CATEGORIES else 'UNKNOWN_PRIVATE_ERROR'
        print(f'MAPS_OPERATION_FAILED: stage={stage}; category={category}; no raw errors; no automatic retry.')
        return 1

if __name__=='__main__':
    raise SystemExit(cli())
