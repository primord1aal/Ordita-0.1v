from copy import deepcopy
import unittest

from tools.dispatch_migration.recovery import (
    FAILED_APPLY_HEAD_SHA, FAILED_APPLY_RUN_ID, FAILED_GUARDED_JOB_ID,
    validate_failed_run, validate_prior_attempts,
)
from tools.orders_migration.admission import GuardError


CURRENT_ID = '45290000000'
CURRENT_SHA = 'a' * 40
REPOSITORY = {'id': 1443030751, 'full_name': 'primord1aal/Ordita-0.1v'}
BRANCH = 'codex/orbita-e2e-test-060'
PATH = '.github/workflows/orbita-dispatch-migration.yml'


def run(run_id, sha, operation='apply', **overrides):
    return {
        'id': int(run_id), 'head_sha': sha, 'repository': dict(REPOSITORY),
        'head_repository': dict(REPOSITORY), 'head_branch': BRANCH, 'path': PATH,
        'workflow_id': 425221225, 'event': 'workflow_dispatch', 'run_attempt': 1,
        'display_title': f'Орбита Dispatch: {operation} @ {sha}',
        **overrides,
    }


def previous():
    return run(FAILED_APPLY_RUN_ID, FAILED_APPLY_HEAD_SHA, status='completed', conclusion='failure')


def historical_log():
    lines = [
        '##[group]Run python3 -m tools.dispatch_migration.runner',
        '\x1b[36;1mpython3 -m tools.dispatch_migration.runner\x1b[0m',
        'shell: /usr/bin/bash -e {0}',
        'env:',
        '  ORBITA_DISPATCH_PASSENGER_EMAIL: ',
        '  ORBITA_DISPATCH_PASSENGER_PASSWORD: ',
        '  ORBITA_DISPATCH_DRIVER_EMAIL: ',
        '  ORBITA_DISPATCH_DRIVER_PASSWORD: ',
        '##[endgroup]',
        'DISPATCH_OPERATION_FAILED: stage=PREVIEW_OR_APPLY_EXECUTION; '
        'category=UNKNOWN_PRIVATE_ERROR; no raw errors; no automatic retry.',
        '##[error]Process completed with exit code 1.',
        'No files were found with the provided path: build/dispatch-public/apply.json. '
        'No artifacts will be uploaded.',
        'No files were found with the provided path: build/dispatch-public/server-test.json',
        'build/dispatch-public/*error*.json',
        'build/dispatch-public/*inspection*.json. No artifacts will be uploaded.',
    ]
    return '\r\n'.join('2026-11-23T23:24:38.5426086Z ' + line for line in lines)


def evidence():
    jobs = {'total_count': 3, 'jobs': [
        {'id': job_id, 'name': name, 'status': 'completed', 'run_id': int(FAILED_APPLY_RUN_ID),
         'run_attempt': 1, 'head_sha': FAILED_APPLY_HEAD_SHA, 'conclusion': conclusion}
        for job_id, name, conclusion in [
            (138089026217, 'verify', 'success'), (138089421973, 'entry', 'success'),
            (FAILED_GUARDED_JOB_ID, 'guarded', 'failure'),
        ]
    ]}
    jobs['jobs'][-1]['steps'] = [
        {'number': number, 'name': name, 'status': 'completed', 'conclusion': conclusion}
        for number, name, conclusion in [
            (3, 'Gate before database secrets', 'success'), (4, 'Fixed PostgreSQL image', 'success'),
            (5, 'Separately authorized operation', 'failure'),
        ]
    ]
    artifacts = {'total_count': 1, 'artifacts': [
        {'name': 'ORBITA-dispatch-local-tests', 'id': 14871838841, 'expired': False,
         'workflow_run': {'id': int(FAILED_APPLY_RUN_ID), 'head_sha': FAILED_APPLY_HEAD_SHA,
                          'head_branch': BRANCH, 'repository_id': REPOSITORY['id'],
                          'head_repository_id': REPOSITORY['id']}},
    ]}
    approvals = [{'state': 'approved', 'user': {'id': 351526818, 'login': 'primord1aal'},
                  'environments': [{'id': 27244178038, 'name': 'orbita-mobile-test-orders-migrations'}]}]
    return previous(), jobs, artifacts, approvals


class RecoveryEvidenceTests(unittest.TestCase):
    def test_normal_apply_does_not_allow_any_prior_apply_even_the_known_failure(self):
        current = run(CURRENT_ID, CURRENT_SHA)
        other = run('45287941745', CURRENT_SHA, 'preview')
        validate_prior_attempts([current, other], CURRENT_ID)
        with self.assertRaises(GuardError):
            validate_prior_attempts([current, other, previous()], CURRENT_ID)

    def test_recovery_accepts_exact_failure_and_current_first_run_for_each_operation(self):
        for operation in ('preview', 'apply'):
            with self.subTest(operation=operation):
                validate_prior_attempts(
                    [run(CURRENT_ID, CURRENT_SHA, operation), previous()], CURRENT_ID,
                    FAILED_APPLY_RUN_ID, operation=operation, current_sha=CURRENT_SHA,
                )

    def test_recovery_blocks_additional_applies_including_a_cancelled_recovery_attempt(self):
        earlier_recovery = run('45289999999', CURRENT_SHA, status='completed', conclusion='cancelled')
        for operation in ('preview', 'apply'):
            with self.subTest(operation=operation), self.assertRaises(GuardError):
                validate_prior_attempts(
                    [earlier_recovery, run(CURRENT_ID, CURRENT_SHA, operation), previous()],
                    CURRENT_ID, FAILED_APPLY_RUN_ID, operation=operation, current_sha=CURRENT_SHA,
                )

    def test_recovery_rejects_absent_or_inaccurate_history(self):
        current = run(CURRENT_ID, CURRENT_SHA)
        historical = previous()
        cases = {
            'missing current run': [historical],
            'missing historical run': [current],
            'duplicate run': [current, historical, historical],
            'other historical sha': [current, run(FAILED_APPLY_RUN_ID, 'b' * 40, status='completed', conclusion='failure')],
            'current sha mismatch': [run(CURRENT_ID, 'b' * 40), historical],
            'historical rerun': [current, {**historical, 'run_attempt': 2}],
            'current rerun': [{**current, 'run_attempt': 2}, historical],
            'other workflow': [{**current, 'workflow_id': 425221224}, historical],
            'other source branch': [current, {**historical, 'head_branch': 'main'}],
            'other source repository': [current, {**historical, 'head_repository': {'id': 108}}],
            'non-integer run id': [current, {**historical, 'id': True}],
            'unrecognized earlier manual run': [current, historical, run(
                '45287940000', 'b' * 40, display_title='Unknown operation')],
        }
        for name, runs in cases.items():
            with self.subTest(name=name), self.assertRaises(GuardError):
                validate_prior_attempts(runs, CURRENT_ID, FAILED_APPLY_RUN_ID, current_sha=CURRENT_SHA)
        with self.assertRaises(GuardError):
            validate_prior_attempts([current, historical], CURRENT_ID, '45287941747', current_sha=CURRENT_SHA)
        with self.assertRaises(GuardError):
            validate_prior_attempts([current, historical], CURRENT_ID, FAILED_APPLY_RUN_ID)

    def test_accepts_complete_historical_evidence_including_real_log_format(self):
        validate_failed_run(*evidence(), log=historical_log())

    def test_rejects_missing_or_modified_job_artifact_and_approval_provenance(self):
        original = evidence()
        variants = {
            'success instead of failure': lambda v: v[0].update(conclusion='success'),
            'truncated jobs': lambda v: v[1].update(total_count=4),
            'different guarded job': lambda v: v[1]['jobs'][-1].update(id=1),
            'runner step skipped': lambda v: v[1]['jobs'][-1]['steps'][-1].update(conclusion='skipped'),
            'gate step unsuccessful': lambda v: v[1]['jobs'][-1]['steps'][0].update(conclusion='failure'),
            'replaced local test artifact': lambda v: v[2]['artifacts'][0].update(id=4),
            'present write evidence': lambda v: (v[2]['artifacts'].append({'name': 'ORBITA-dispatch-apply-45287941746'}),
                                                 v[2].update(total_count=2)),
            'other repository artifact': lambda v: v[2]['artifacts'][0]['workflow_run'].update(repository_id=1),
            'right username wrong id': lambda v: v[3][0]['user'].update(id=1),
            'different Environment': lambda v: v[3][0]['environments'][0].update(id=1),
        }
        for name, change in variants.items():
            with self.subTest(name=name), self.assertRaises(GuardError):
                broken = deepcopy(original)
                change(broken)
                validate_failed_run(*broken, log=historical_log())

    def test_log_requires_all_four_empty_values_and_no_write_paths_in_order(self):
        original = historical_log()
        unexpected_value = 'synthetic-private-value'
        variants = (
            original.replace('ORBITA_DISPATCH_DRIVER_PASSWORD: ', 'ORBITA_DISPATCH_DRIVER_PASSWORD: ***'),
            original.replace('ORBITA_DISPATCH_DRIVER_PASSWORD: ', f'ORBITA_DISPATCH_DRIVER_PASSWORD: {unexpected_value}'),
            original.replace('ORBITA_DISPATCH_DRIVER_PASSWORD', 'DIFFERENT_VARIABLE'),
            original.replace('ORBITA_DISPATCH_DRIVER_PASSWORD', 'ORBITA_DISPATCH_DRIVER_EMAIL'),
            original.replace('PREVIEW_OR_APPLY_EXECUTION', 'SOURCE_CATALOG'),
            original.replace('##[endgroup]', '##[group]Unrelated step'),
            original.replace('build/dispatch-public/apply.json', 'other.json'),
            original.replace('build/dispatch-public/*inspection*.json', 'other.json'),
            '', 'x' * (256 * 1024 + 1),
        )
        for log in variants:
            with self.subTest(length=len(log)), self.assertRaises(GuardError) as caught:
                validate_failed_run(*evidence(), log=log)
            self.assertNotIn(unexpected_value, str(caught.exception))
