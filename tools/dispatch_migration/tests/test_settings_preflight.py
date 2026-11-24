import contextlib
import hashlib
import io
import json
from pathlib import Path
import ssl
import tempfile
import unittest
from unittest.mock import Mock, patch

from tools.dispatch_migration import github_gate, policy, recovery, runner, state
from tools.migration_preflight import (
    BACKUP_PASSPHRASE, CA_PEM, CLIENT_KEY, DB_PASSWORD, DISPATCH_SECRETS,
    DRIVER_EMAIL, PASSENGER_EMAIL, PROJECT_REF, SettingsError,
    report_settings_failure, validate_admission_settings, validate_settings,
)


PROJECT = policy.LOCK['project_ref']
ROOT = Path(__file__).resolve().parents[3]


def context(operation):
    sha = '9' * 40
    return {
        'event': 'workflow_dispatch', 'operation': operation,
        'repository': policy.LOCK['repository'],
        'git_ref': 'refs/heads/' + policy.LOCK['branch'], 'attempt': '1',
        'repo_enabled': 'true', 'sha': sha, 'approved_sha': sha, 'checkout_sha': sha,
        'env_enabled': 'true', 'allowed_sha': sha, 'allowed_operation': operation,
        'expected_ref': PROJECT, 'requested_ref': PROJECT,
        'forbidden_ref': policy.LOCK['forbidden_ref'],
        'preview_run_id': '123456789', 'backup_sha256': 'a' * 64,
        'run_id': '456789123',
    }


class SettingsPreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ca = ssl.DER_cert_to_PEM_cert(ssl.create_default_context().get_ca_certs(binary_form=True)[0])

    def valid_settings(self):
        return {
            'PGPASSWORD': 'synthetic-db-password',
            'ORBITA_DATABASE_CA_PEM': self.ca,
            PROJECT_REF: PROJECT,
            BACKUP_PASSPHRASE: 'synthetic-different-backup-phrase',
            CLIENT_KEY: 'sb_publishable_synthetic',
            PASSENGER_EMAIL: 'passenger@example.invalid',
            'ORBITA_DISPATCH_PASSENGER_PASSWORD': 'synthetic-passenger-password',
            DRIVER_EMAIL: 'driver@example.invalid',
            'ORBITA_DISPATCH_DRIVER_PASSWORD': 'synthetic-driver-password',
        }

    def test_missing_settings_report_all_names_only(self):
        with self.assertRaises(SettingsError) as failure:
            validate_settings('preview', PROJECT, check_dispatch_accounts=True, env={})
        self.assertEqual(set(failure.exception.settings),
                         {DB_PASSWORD, CA_PEM, PROJECT_REF, BACKUP_PASSPHRASE, CLIENT_KEY, *DISPATCH_SECRETS})
        env = self.valid_settings()
        env[CLIENT_KEY] = 'synthetic-private-value'
        env['ORBITA_DATABASE_CA_PEM'] = '-----BEGIN CERTIFICATE-----\nBAD'
        env[BACKUP_PASSPHRASE] = env['PGPASSWORD'] = 'synthetic-shared-password-value'
        env[DRIVER_EMAIL] = ' PASSENGER@example.invalid '
        with self.assertRaises(SettingsError) as failure:
            validate_settings('preview', PROJECT, check_dispatch_accounts=True, env=env)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            report_settings_failure(failure.exception)
        self.assertEqual(set(failure.exception.settings), {CA_PEM, BACKUP_PASSPHRASE, CLIENT_KEY, PASSENGER_EMAIL, DRIVER_EMAIL})
        for value in (env[CLIENT_KEY], env['PGPASSWORD'], env[DRIVER_EMAIL]):
            self.assertNotIn(value, output.getvalue())

    def test_operation_specific_settings(self):
        env = self.valid_settings()
        validate_settings('preview', PROJECT, check_dispatch_accounts=True, env=env)
        del env[BACKUP_PASSPHRASE]
        validate_settings('apply', PROJECT, check_dispatch_accounts=True, env=env)
        for name in DISPATCH_SECRETS:
            del env[name]
        del env[CLIENT_KEY]
        validate_settings('apply', PROJECT, env=env)
        validate_settings('inspect', PROJECT, check_dispatch_accounts=True, env=env)
        with self.assertRaises(SettingsError) as failure:
            validate_settings('apply', PROJECT, check_dispatch_accounts=True, env=env)
        self.assertEqual(set(failure.exception.settings), {CLIENT_KEY, *DISPATCH_SECRETS})

    def test_protected_variables_report_all_problems(self):
        request = context('preview')
        validate_admission_settings(request, PROJECT, policy.LOCK['forbidden_ref'])
        request.update(env_enabled='', allowed_sha='', allowed_operation='apply',
                       expected_ref='', forbidden_ref='', requested_ref='')
        with self.assertRaises(SettingsError) as failure:
            validate_admission_settings(request, PROJECT, policy.LOCK['forbidden_ref'])
        self.assertEqual(set(failure.exception.settings), {
            'ORBITA_DISPATCH_CLOUD_ENABLED', 'ORBITA_DISPATCH_ALLOWED_SHA',
            'ORBITA_DISPATCH_ALLOWED_OPERATION', PROJECT_REF,
            'SUPABASE_FORBIDDEN_PROJECT_REF', 'workflow input project_ref',
        })

    def test_runner_rejects_missing_test_secret_before_constructing_database(self):
        for operation in ('preview', 'apply'):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as directory:
                request = context(operation)
                gate = Path(directory) / 'orbita-dispatch-gate.json'
                gate.write_text(json.dumps({'context': request, 'preview': {}}))
                env = self.valid_settings()
                del env['ORBITA_DISPATCH_PASSENGER_PASSWORD']
                env.update(GITHUB_WORKSPACE=str(ROOT), RUNNER_TEMP=directory)
                with patch.dict('os.environ', env, clear=True), patch.object(runner, 'validate_receipt'), \
                     patch.object(runner, 'validate_connection'), \
                     patch.object(runner.subprocess, 'check_output', side_effect=[request['sha'], '']), \
                     patch.object(runner, 'DispatchDatabase') as database:
                    with self.assertRaises(SettingsError):
                        runner.main()
                    database.assert_not_called()

    def test_entry_rejects_test_secrets_visible_without_environment(self):
        with patch.dict('os.environ', {'OUTSIDE_' + PASSENGER_EMAIL: 'true'}, clear=True), \
             patch.object(github_gate, 'context', return_value=(ROOT, context('preview'))):
            with self.assertRaises(SettingsError) as failure:
                github_gate.entry()
            self.assertEqual(failure.exception.settings, (PASSENGER_EMAIL,))
            self.assertTrue(failure.exception.environment_only)

    def test_recovery_binds_fresh_preview_to_original_digest(self):
        request = {**context('apply'), 'recovery_run_id': recovery.FAILED_APPLY_RUN_ID}
        policy.validate_request(request, ROOT)
        preview = {
            'status': 'preview_passed', 'source_sha': request['sha'],
            'run_id': request['preview_run_id'], 'project_ref': PROJECT,
            'sql_sha256': policy.LOCK['sha256'], 'executor': policy.LOCK['executor'],
            'before_versions': policy.versions(), 'pending': [policy.LOCK['version']],
            'state_sha256': '8' * 64,
            'settings_preflight': 'passed', 'recovery_run_id': recovery.FAILED_APPLY_RUN_ID,
            'original_state_sha256': recovery.RECOVERY_BASELINE_STATE_SHA256,
            'auth_preflight': {'passenger': True, 'driver': True, 'local_sessions_closed': True},
            'backup': {'encrypted_sha256': request['backup_sha256'], 'decryption_checked': True,
                       'restore_checked': True, 'rehearsal_checked': True, 'network': 'none'},
        }
        policy.validate_receipt(preview, request)
        for field, value in (('recovery_run_id', ''), ('settings_preflight', ''),
                             ('original_state_sha256', 'a' * 64), ('auth_preflight', {})):
            with self.subTest(field=field), self.assertRaises(policy.GuardError):
                policy.validate_receipt({**preview, field: value}, request)
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'capture'), \
             patch.object(runner, 'validate_before'), patch.object(runner, 'protected_hash'), \
             patch.object(runner, 'state_hash', return_value='b' * 64):
            database = Mock()
            with self.assertRaises(policy.GuardError):
                runner.execute(request, database, ROOT, directory, directory, directory, proof=preview)
            database.apply_dispatch.assert_not_called()
            self.assertFalse((Path(directory) / 'apply.json').exists())

    def test_recovery_checks_test_accounts_before_login_and_backs_up_post_login_state(self):
        context_for_preview = {**context('preview'), 'recovery_run_id': recovery.FAILED_APPLY_RUN_ID}
        env = self.valid_settings()
        email_hashes = {
            role: hashlib.sha256(env[key].encode()).hexdigest()
            for role, key in (('passenger', PASSENGER_EMAIL), ('driver', DRIVER_EMAIL))
        }
        source_digest = recovery.RECOVERY_BASELINE_STATE_SHA256
        snapshot = {
            'state_sha256': source_digest, 'account_count': 2,
            'email_hashes': email_hashes, 'cutoff': '2026-11-24T00:00:00.000000Z',
            'document': {'rows': {'auth.users': 'before', 'auth.sessions': 'same'}},
            'users': 'same', 'identities': 'same', 'audit': 'same', 'refresh_sequence': [23, True],
        }
        after = {**snapshot, 'state_sha256': '8' * 64, 'refresh_sequence': [25, True],
                 'document': {'rows': {'auth.users': 'after', 'auth.sessions': 'same'}}}
        events = []
        with tempfile.TemporaryDirectory() as directory, patch.dict('os.environ', env, clear=True), \
             patch.object(runner, 'capture'), patch.object(runner, 'validate_before'), \
             patch.object(runner, 'protected_hash'), \
             patch.object(runner, 'state_hash', side_effect=[source_digest, after['state_sha256']]), \
             patch.object(runner, 'auth_probe_snapshot', side_effect=[snapshot, after]), \
             patch.object(runner, 'create', side_effect=lambda *_args, **_kwargs: events.append('backup') or {}):
            receipt = runner.execute(context_for_preview, Mock(), ROOT, directory, directory, directory,
                                     authenticate=lambda: events.append('login and logout'))
        self.assertEqual(events, ['login and logout', 'backup'])
        self.assertEqual(receipt['state_sha256'], after['state_sha256'])
        self.assertEqual(receipt['original_state_sha256'], source_digest)
        self.assertTrue(receipt['auth_preflight']['local_sessions_closed'])
        with self.assertRaises(policy.GuardError):
            state.validate_auth_probe_delta(
                snapshot, {**after, 'document': {'rows': {'auth.sessions': 'changed'}}})
        with tempfile.TemporaryDirectory() as directory, patch.dict('os.environ', env, clear=True), \
             patch.object(runner, 'auth_probe_snapshot', return_value={**snapshot, 'email_hashes': {}}):
            authenticate = Mock()
            with self.assertRaises(policy.GuardError):
                runner.verify_recovery_auth(Mock(), authenticate, Path(directory) / 'auth.json')
            authenticate.assert_not_called()
