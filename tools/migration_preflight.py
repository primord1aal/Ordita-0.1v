"""Validate migration settings before opening the test database."""
import os
import ssl

from tools.orders_migration.admission import GuardError
from backup import validate_passphrase


DB_PASSWORD = 'ORBITA_TEST_DB_PASSWORD'
BACKUP_PASSPHRASE = 'ORBITA_ORDERS_BACKUP_PASSPHRASE'
CA_PEM = 'ORBITA_TEST_DB_CA_PEM'
PROJECT_REF = 'SUPABASE_TEST_PROJECT_REF'
CLIENT_KEY = 'SUPABASE_TEST_PUBLISHABLE_KEY'
PASSENGER_EMAIL = 'ORBITA_DISPATCH_PASSENGER_EMAIL'
DRIVER_EMAIL = 'ORBITA_DISPATCH_DRIVER_EMAIL'
DISPATCH_SECRETS = (
    PASSENGER_EMAIL,
    'ORBITA_DISPATCH_PASSENGER_PASSWORD',
    DRIVER_EMAIL,
    'ORBITA_DISPATCH_DRIVER_PASSWORD',
)


class SettingsError(GuardError):
    def __init__(self, settings, *, environment_only=False):
        self.settings = tuple(dict.fromkeys(settings))
        self.environment_only = environment_only
        super().__init__('Migration settings check failed.')


def report_settings_failure(exc):
    category = 'MIGRATION_SETTINGS_REQUIRE_ENVIRONMENT_SCOPE' if exc.environment_only else 'MIGRATION_SETTINGS_INVALID'
    print(category + ': ' + ', '.join(exc.settings), flush=True)


def validate_admission_settings(context, project_ref, forbidden_ref):
    expected = (
        ('env_enabled', 'ORBITA_DISPATCH_CLOUD_ENABLED', 'true'),
        ('allowed_sha', 'ORBITA_DISPATCH_ALLOWED_SHA', context['sha']),
        ('allowed_operation', 'ORBITA_DISPATCH_ALLOWED_OPERATION', context['operation']),
        ('expected_ref', PROJECT_REF, project_ref),
        ('forbidden_ref', 'SUPABASE_FORBIDDEN_PROJECT_REF', forbidden_ref),
        ('requested_ref', 'workflow input project_ref', project_ref),
    )
    invalid = [setting for field, setting, value in expected if context.get(field) != value]
    if invalid:
        raise SettingsError(invalid)


def _ca_is_valid(certificate):
    if not certificate.startswith('-----BEGIN CERTIFICATE-----'):
        return False
    try:
        ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(cadata=certificate)
    except (ssl.SSLError, ValueError):
        return False
    return True


def validate_settings(operation, project_ref, *, check_dispatch_accounts=False, env=None):
    env = os.environ if env is None else env
    invalid = []
    password = env.get('PGPASSWORD', '')
    if not password.strip():
        invalid.append(DB_PASSWORD)
    if not _ca_is_valid(env.get('ORBITA_DATABASE_CA_PEM', '')):
        invalid.append(CA_PEM)
    if env.get(PROJECT_REF) != project_ref:
        invalid.append(PROJECT_REF)

    if operation == 'preview':
        passphrase = env.get(BACKUP_PASSPHRASE, '')
        try:
            validate_passphrase(passphrase)
            if not passphrase.strip() or passphrase == password:
                invalid.append(BACKUP_PASSPHRASE)
        except GuardError:
            invalid.append(BACKUP_PASSPHRASE)

    if check_dispatch_accounts and operation in ('preview', 'apply'):
        key = env.get(CLIENT_KEY, '')
        if not key.startswith('sb_publishable_') or not key.removeprefix('sb_publishable_').strip() or key != key.strip():
            invalid.append(CLIENT_KEY)
        invalid.extend(name for name in DISPATCH_SECRETS if not env.get(name, '').strip())
        passenger_email = env.get(PASSENGER_EMAIL, '').strip().casefold()
        driver_email = env.get(DRIVER_EMAIL, '').strip().casefold()
        if passenger_email and passenger_email == driver_email:
            invalid.extend((PASSENGER_EMAIL, DRIVER_EMAIL))

    if invalid:
        raise SettingsError(invalid)
