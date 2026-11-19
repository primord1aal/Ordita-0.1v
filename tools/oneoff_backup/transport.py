"""Private client TLS attestation on the existing one-off psql connection."""
from pathlib import Path
import ipaddress
import re

from tools.current_backup import backup as base

HOST = 'aws-0-eu-north-1.pooler.supabase.com'
PORT = '5432'
DATABASE = 'postgres'
USER = 'orbita_oneoff_backup_reader.' + base.PROJECT


def attest_client_tls(session):
    """Confirm client-to-pooler TLS; this does not attest the pooler's DB hop."""
    try:
        env = session.env
        expected = {'PGHOST': HOST, 'PGPORT': PORT, 'PGDATABASE': DATABASE,
                    'PGUSER': USER, 'PGSSLMODE': 'verify-full'}
        configured = all(env.get(key) == value for key, value in expected.items())
        configured = configured and not any(
            key in env for key in ('PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE'))
        certificate = env.get('PGSSLROOTCERT')
        configured = configured and isinstance(certificate, str) and bool(certificate)
        if configured:
            ca = Path(certificate)
            configured = ca.is_file() and not ca.is_symlink()
    except Exception:
        configured = False
    base.require(configured, 'CLIENT_TLS_CONFIGURATION_REJECTED')

    try:
        # _exchange uses this held session's existing framing, timeout and bound.
        # Do not add a general meta-command path to the strict select() API.
        raw = session._exchange(r'\conninfo')
    except Exception:
        raise base.BackupError('CLIENT_TLS_ATTESTATION_FAILED') from None

    base.require(isinstance(raw, str) and len(raw) <= 4096,
                 'CLIENT_TLS_NOT_CONFIRMED')
    lines = raw.split('\n')
    base.require(len(lines) == 2, 'CLIENT_TLS_NOT_CONFIRMED')
    identity = (r'You are connected to database "' + re.escape(DATABASE) +
                r'" as user "' + re.escape(USER) + r'" on host "' + re.escape(HOST) +
                r'"(?: \(address "([^"\n]{1,64})"\))? at port "' +
                re.escape(PORT) + r'"\.')
    match = re.fullmatch(identity, lines[0])
    base.require(match is not None, 'CLIENT_TLS_NOT_CONFIRMED')
    if match[1] is not None:
        try:
            ipaddress.ip_address(match[1])
        except ValueError:
            raise base.BackupError('CLIENT_TLS_NOT_CONFIRMED') from None
    ssl = re.fullmatch(
        r'SSL connection \(protocol: (TLSv1\.[23]), '
        r'cipher: ([A-Za-z0-9][A-Za-z0-9_-]{0,127}), compression: off'
        r'(?:, ALPN: (?:none|\(none\)|postgresql))?\)', lines[1])
    base.require(ssl is not None, 'CLIENT_TLS_NOT_CONFIRMED')
    return {'client_tls_verified': True, 'client_sslmode': 'verify-full',
            'client_hostname_verified': True, 'scope': 'client_to_pooler',
            'protocol': ssl[1], 'cipher': ssl[2]}
