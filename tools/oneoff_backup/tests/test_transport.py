"""Private parser checks and real local psql TLS through a terminating proxy."""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
import os
import select
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from tools.oneoff_backup import core as b
from tools.oneoff_backup import transport as t
from tools.orders_migration.local import Native


def conninfo(*, address='127.0.0.1', protocol='TLSv1.3', alpn='postgresql'):
    location = '' if address is None else ' (address "' + address + '")'
    first = ('You are connected to database "' + t.DATABASE + '" as user "' +
             t.USER + '" on host "' + t.HOST + '"' + location +
             ' at port "' + t.PORT + '".')
    last = ('' if alpn is None else ', ALPN: ' + alpn)
    return first + '\nSSL connection (protocol: ' + protocol + \
        ', cipher: TLS_AES_256_GCM_SHA384, compression: off' + last + ')'


class ClientTLSUnitTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='orbita-tls-unit-')
        self.addCleanup(self.directory.cleanup)
        self.ca = Path(self.directory.name) / 'ca.pem'
        self.ca.write_text('synthetic parser-only CA fixture')
        self.env = b.connection('synthetic-reader-password-only', self.ca)
        self.session = Mock(env=self.env)
        self.session._exchange.return_value = conninfo()

    def test_same_session_attestation_is_separate_from_backend_ssl(self):
        result = t.attest_client_tls(self.session)
        self.session._exchange.assert_called_once_with(r'\conninfo')
        self.assertEqual(result, {'client_tls_verified': True,
            'client_sslmode': 'verify-full', 'client_hostname_verified': True,
            'scope': 'client_to_pooler', 'protocol': 'TLSv1.3',
            'cipher': 'TLS_AES_256_GCM_SHA384'})
        for private in (t.HOST, t.USER, '127.0.0.1', str(self.ca)):
            self.assertNotIn(private, str(result))

    def test_supported_psql17_formats(self):
        for address in (None, '127.0.0.1', '::1'):
            for protocol in ('TLSv1.2', 'TLSv1.3'):
                for alpn in (None, 'none', '(none)', 'postgresql'):
                    with self.subTest(address=address, protocol=protocol, alpn=alpn):
                        self.session._exchange.return_value = conninfo(
                            address=address, protocol=protocol, alpn=alpn)
                        self.assertEqual(t.attest_client_tls(self.session)['protocol'], protocol)

    def test_config_changes_fail_before_any_connection_command(self):
        changes = [('PGHOST', 'unapproved.invalid'), ('PGPORT', '6543'),
                   ('PGDATABASE', 'other'), ('PGUSER', 'postgres'),
                   ('PGSSLMODE', 'require'), ('PGSSLMODE', 'disable'),
                   ('PGSSLROOTCERT', ''), ('PGSSLROOTCERT', '/missing/artificial-ca.pem'),
                   ('PGSSLROOTCERT', self.directory.name), ('PGSSLROOTCERT', None),
                   ('PGHOSTADDR', '127.0.0.1'), ('PGSERVICE', ''),
                   ('PGSERVICEFILE', '/private/service.conf')]
        linked = Path(self.directory.name) / 'linked.pem'
        linked.symlink_to(self.ca)
        changes.append(('PGSSLROOTCERT', str(linked)))
        for key, value in changes:
            with self.subTest(key=key, value=value):
                self.session.env = dict(self.env, **{key: value})
                with self.assertRaisesRegex(b.base.BackupError,
                                            '^CLIENT_TLS_CONFIGURATION_REJECTED$'):
                    t.attest_client_tls(self.session)
        self.session._exchange.assert_not_called()

    def test_unexpected_identity_or_transport_output_fails_closed(self):
        good = conninfo()
        first, last = good.split('\n')
        bad = [first, first + '\nGSSAPI-encrypted connection',
               first + '\n' + last + '\n' + last, good + '\n',
               good.replace(t.HOST, 'private.invalid'),
               good.replace(t.USER, 'postgres'),
               good.replace('database "postgres"', 'database "other"'),
               good.replace('port "5432"', 'port "6543"'),
               conninfo(protocol='TLSv1.1'), conninfo(alpn='unexpected'),
               good.replace('compression: off', 'compression: on'),
               good.replace('TLS_AES_256_GCM_SHA384', ''),
               good.replace('on host', 'via socket in'),
               conninfo(address='private.invalid'), good.replace('\n', '\r\n'),
               'synthetic-private-value\n' + good, 'x' * 4097, b'raw bytes', None]
        for raw in bad:
            with self.subTest(raw=repr(raw)[:90]):
                self.session._exchange.return_value = raw
                with self.assertRaisesRegex(b.base.BackupError,
                                            '^CLIENT_TLS_NOT_CONFIRMED$'):
                    t.attest_client_tls(self.session)

    def test_query_errors_and_raw_output_never_escape(self):
        private = 'synthetic-private-password-and-connection-output'
        for error in (OSError(private), b.base.BackupError(private)):
            self.session._exchange.side_effect = error
            output = StringIO()
            with redirect_stdout(output), redirect_stderr(output):
                with self.assertRaisesRegex(b.base.BackupError,
                                            '^CLIENT_TLS_ATTESTATION_FAILED$') as caught:
                    t.attest_client_tls(self.session)
            self.assertNotIn(private, str(caught.exception))
            self.assertEqual(output.getvalue(), '')


class LocalTLSProxy:
    """TEST ONLY: terminate loopback TLS and relay to Native's Unix socket."""
    def __init__(self, local, certificate, key, *, tls=True):
        self.path = str(local.socket / '.s.PGSQL.55432')
        self.tls = tls
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(certificate, key)
        self.context.set_alpn_protocols(['postgresql'])
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.listener.settimeout(0.2)
        self.port = str(self.listener.getsockname()[1])
        self.stop = threading.Event()
        self.backend_connections = 0
        self.peers = []
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def _track(self, peer):
        with self.lock:
            self.peers.append(peer)
        return peer

    @staticmethod
    def _request(peer):
        data = b''
        while len(data) < 8:
            chunk = peer.recv(8 - len(data))
            if not chunk:
                raise ConnectionError('Local synthetic client disconnected')
            data += chunk
        return data

    def _serve(self):
        try:
            deadline = time.monotonic() + 20
            while not self.stop.is_set() and time.monotonic() < deadline:
                try:
                    client, _ = self.listener.accept()
                except socket.timeout:
                    continue
                with self._track(client):
                    client.settimeout(3)
                    if self._request(client) != struct.pack('!II', 8, 80877103):
                        return
                    client.sendall(b'S' if self.tls else b'N')
                    if not self.tls:
                        return
                    with self._track(self.context.wrap_socket(client, server_side=True)) as secure:
                        # libpq can reject the hostname after the TLS handshake.
                        # Open the private DB hop only after an actual startup packet.
                        startup = secure.recv(65536)
                        if not startup:
                            return
                        backend = self._track(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM))
                        with backend:
                            backend.settimeout(3)
                            backend.connect(self.path)
                            self.backend_connections += 1
                            backend.sendall(startup)
                            while not self.stop.is_set() and time.monotonic() < deadline:
                                ready = [secure] if secure.pending() else select.select(
                                    [secure, backend], [], [], 0.2)[0]
                                for source in ready:
                                    raw = source.recv(65536)
                                    if not raw:
                                        return
                                    (backend if source is secure else secure).sendall(raw)
                    return
        except (OSError, ssl.SSLError):
            # Expected for wrong CA/hostname and for deliberate fixture shutdown.
            return

    def __exit__(self, *_):
        self.stop.set()
        self.listener.close()
        with self.lock:
            for peer in self.peers:
                try:
                    peer.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                peer.close()
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise AssertionError('Synthetic local TLS proxy did not stop')


@unittest.skipUnless(os.environ.get('ORBITA_ORDERS_PG_BIN') and shutil.which('openssl'),
                     'Separately verified PostgreSQL17 and openssl required')
class ClientTLSIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local = Native()
        try:
            cls.certificate = cls.local.path / 'server.pem'
            cls.key = cls.local.path / 'server.key'
            cls.other_ca = cls.local.path / 'other-ca.pem'
            for certificate, key, name in (
                    (cls.certificate, cls.key, 'localhost'),
                    (cls.other_ca, cls.local.path / 'other-ca.key', 'untrusted-synthetic-ca')):
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048',
                    '-nodes', '-days', '1', '-subj', '/CN=' + name,
                    '-addext', 'subjectAltName=DNS:' + name,
                    '-keyout', str(key), '-out', str(certificate)],
                    check=True, capture_output=True, timeout=15)
        except BaseException:
            cls.local.close()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.local.close()

    def session_env(self, proxy, *, host='localhost', ca=None):
        env = b.base.child_env()
        env.update(PGHOST=host, PGPORT=proxy.port, PGDATABASE='postgres', PGUSER='postgres',
                   PGSSLMODE='verify-full', PGSSLROOTCERT=str(ca or self.certificate),
                   PGCONNECT_TIMEOUT='3', PGPASSFILE='/dev/null', PGGSSENCMODE='disable',
                   PGOPTIONS='-c default_transaction_read_only=on')
        return env

    def patched_endpoint(self, env):
        stack = ExitStack()
        for name, variable in (('HOST', 'PGHOST'), ('PORT', 'PGPORT'),
                               ('DATABASE', 'PGDATABASE'), ('USER', 'PGUSER')):
            stack.enter_context(patch.object(t, name, env[variable]))
        return stack

    def test_real_client_tls_is_true_while_database_backend_tls_is_false(self):
        with LocalTLSProxy(self.local, self.certificate, self.key) as proxy:
            env = self.session_env(proxy)
            with self.patched_endpoint(env), b.base.ReadSession(env, self.local.bin) as session:
                backend_ssl = session.select('SELECT coalesce((SELECT ssl FROM '
                    'pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()),false)')
                self.assertEqual(backend_ssl, 'f')
                proof = t.attest_client_tls(session)
                self.assertTrue(proof['client_tls_verified'])
                self.assertTrue(proof['client_hostname_verified'])
                self.assertEqual(proof['scope'], 'client_to_pooler')
                self.assertIn(proof['protocol'], ('TLSv1.2', 'TLSv1.3'))
                self.assertEqual(session.select('SELECT current_setting('
                    "'transaction_read_only')"), 'on')
            self.assertEqual(proxy.backend_connections, 1)

    def test_wrong_ca_hostname_or_plaintext_server_never_reaches_export(self):
        for failure in ('ca', 'hostname', 'plaintext'):
            with self.subTest(failure=failure):
                with LocalTLSProxy(self.local, self.certificate, self.key,
                                   tls=failure != 'plaintext') as proxy:
                    env = self.session_env(proxy,
                        host='127.0.0.1' if failure == 'hostname' else 'localhost',
                        ca=self.other_ca if failure == 'ca' else self.certificate)
                    export = Mock()
                    output = StringIO()
                    with self.patched_endpoint(env), redirect_stdout(output), redirect_stderr(output):
                        with self.assertRaises(b.base.BackupError):
                            with b.base.ReadSession(env, self.local.bin) as session:
                                t.attest_client_tls(session)
                                export()
                    export.assert_not_called()
                    self.assertEqual(proxy.backend_connections, 0)
                    self.assertEqual(output.getvalue(), '')


if __name__ == '__main__':
    unittest.main()
