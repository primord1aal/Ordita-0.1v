"""Separate admission; never mutates the first migration policy/Environment."""
from pathlib import Path
import hashlib
import json
import re
import sys

LEGACY = Path(__file__).resolve().parents[1] / 'migrations'
if str(LEGACY) not in sys.path:
    sys.path.insert(0, str(LEGACY))
from policy import GuardError, require, validate_connection  # unchanged transport guard

LOCK = json.loads((Path(__file__).parent / 'lock.json').read_text())
HEX40 = re.compile(r'[a-f0-9]{40}')
HEX64 = re.compile(r'[a-f0-9]{64}')
ENV_ONLY = ('ORBITA_ORDERS_CLOUD_ENABLED', 'ORBITA_ORDERS_ALLOWED_SHA', 'ORBITA_ORDERS_ALLOWED_OPERATION')

def sources(root):
    root = Path(root)
    require([p.name for p in sorted((root / 'supabase/migrations').glob('*.sql'))]
            == [Path(LOCK['first_path']).name], 'Unexpected runnable migration.')
    result = []
    for path, digest in [(LOCK['first_path'], LOCK['first_sha256']), (LOCK['path'], LOCK['sha256'])]:
        p = root / path
        require(p.is_file() and not p.is_symlink(), 'Fixed source is missing or linked.')
        raw = p.read_bytes()
        require(hashlib.sha256(raw).hexdigest() == digest, 'Fixed SQL checksum changed.')
        result.append(raw)
    return result

def validate_source(c, root, outside=None):
    require(c.get('event') == 'workflow_dispatch' and c.get('operation') in ('preview', 'apply', 'inspect'),
            'Only separately approved manual operations are allowed.')
    require(c.get('repository') == LOCK['repository'] and c.get('git_ref') == 'refs/heads/' + LOCK['branch'],
            'Repository/branch mismatch.')
    require(str(c.get('attempt')) == '1' and c.get('repo_enabled') == 'true', 'No retry or repository admission.')
    sha = c.get('sha', '')
    require(HEX40.fullmatch(sha) is not None and sha == c.get('approved_sha') == c.get('checkout_sha'),
            'Exact commit approval required.')
    if outside is not None:
        require(all(not outside.get(k) for k in ENV_ONLY), 'Environment flag/SHA exists outside Environment.')
    sources(root)
    from .catalog import reference
    reference('auth'); reference('orders')

def validate_request(c, root):
    validate_source(c, root)
    require(c.get('env_enabled') == 'true' and c.get('allowed_sha') == c['sha'] and c.get('allowed_operation') == c['operation'], 'Environment admission missing.')
    require(c.get('expected_ref') == c.get('requested_ref') == LOCK['project_ref']
            and c.get('forbidden_ref') == LOCK['forbidden_ref'], 'Exact target/forbidden refs required.')
    if c['operation'] == 'apply':
        require(str(c.get('preview_run_id', '')).isdigit() and HEX64.fullmatch(c.get('backup_sha256', '')) is not None,
                'Successful preview and encrypted backup digest required.')

def validate_environment(environment, branches, reviews):
    owner = LOCK['repository'].split('/')[0]
    require(environment.get('name') == LOCK['environment'] and environment.get('can_admins_bypass') is False,
            'Dedicated non-bypassable Environment required.')
    require(environment.get('deployment_branch_policy') == {'protected_branches': False, 'custom_branch_policies': True},
            'Exact branch policy required.')
    require(branches.get('branch_policies') and len(branches['branch_policies']) == 1
            and branches['branch_policies'][0].get('name') == LOCK['branch']
            and branches['branch_policies'][0].get('type') == 'branch', 'No wildcard/tag branch policies.')
    require(any(rule.get('type') == 'required_reviewers' and any(
        item.get('type') == 'User' and item.get('reviewer', {}).get('login') == owner
        for item in rule.get('reviewers', [])) for rule in environment.get('protection_rules', [])),
        'Owner reviewer required.')
    require(any(r.get('state') == 'approved' and r.get('user', {}).get('login') == owner and any(
        e.get('id') == environment.get('id') for e in r.get('environments', [])) for r in reviews),
        'Actual approval for this run/Environment required.')

def validate_preview(run, receipt, c):
    require(str(run.get('id')) == c['preview_run_id'] and run.get('conclusion') == 'success'
            and run.get('event') == 'workflow_dispatch' and run.get('run_attempt') == 1
            and run.get('head_sha') == c['sha'] and run.get('head_branch') == LOCK['branch']
            and run.get('path') == '.github/workflows/' + LOCK['workflow']
            and run.get('display_title', '').startswith('Орбита Orders: preview @'), 'Preview provenance mismatch.')
    validate_receipt(receipt, c)

def validate_receipt(receipt, c):
    require(receipt.get('status') == 'preview_passed' and receipt.get('source_sha') == c['sha']
            and str(receipt.get('run_id')) == c['preview_run_id']
            and receipt.get('project_ref') == LOCK['project_ref']
            and receipt.get('sql_sha256') == LOCK['sha256'] and receipt.get('executor') == LOCK['executor']
            and receipt.get('before_versions') == [LOCK['first_version']]
            and receipt.get('pending') == [LOCK['version']], 'Preview contract mismatch.')
    backup = receipt.get('backup', {})
    require(backup.get('encrypted_sha256') == c['backup_sha256']
            and backup.get('decryption_checked') is True and backup.get('restore_checked') is True
            and backup.get('rehearsal_checked') is True and backup.get('network') == 'none'
            and HEX64.fullmatch(receipt.get('state_sha256', '')) is not None,
            'Verified backup/isolated rehearsal required.')

def no_prior_apply(runs, current):
    require(not any(int(r['id']) < int(current) and r.get('event') == 'workflow_dispatch'
                    and r.get('display_title', '').startswith('Орбита Orders: apply @') for r in runs),
            'Prior apply attempt requires separate read-only investigation; no automatic retry.')
