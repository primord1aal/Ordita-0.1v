"""B1: настоящий PostgreSQL/TLS, короткий wrapper timeout и только свои ресурсы."""
from pathlib import Path
import contextlib
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/migrations'))
import dbtools
from policy import GuardError, LOCK

REAL_DOCKER = list(dbtools.DOCKER)
FAKE_REF = 'a' * 20
FAKE_HOST = 'db.' + FAKE_REF + '.supabase.co'


def docker(*args, input=None, timeout=25, check=True):
    return subprocess.run(REAL_DOCKER + list(args), input=input, capture_output=True,
                          text=True, timeout=timeout, check=check)


def containers():
    result = docker('ps', '-a', '--no-trunc', '--format', '{{json .}}')
    return {row['ID']: {key: row[key] for key in ('Names', 'State', 'Status')}
            for line in result.stdout.splitlines() if (row := json.loads(line))}


def inspect(container):
    result = docker('inspect', container, check=False)
    return json.loads(result.stdout)[0] if result.returncode == 0 else None


def remove_owned(cid, label, token):
    state = inspect(cid)
    if state is not None:
        if state['Id'] != cid or state['Config'].get('Labels', {}).get(label) != token:
            raise AssertionError('Удаление неидентифицированного контейнера запрещено')
        docker('rm', '-f', cid)


class B1Fixture:
    def __init__(self):
        self.directory = tempfile.TemporaryDirectory(prefix='orbita-b1-fixture-')
        self.path = Path(self.directory.name)
        self.token = uuid.uuid4().hex
        self.cid = None
        self.original = containers()

    def start(self):
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                        '-subj', '/CN=' + FAKE_HOST, '-addext',
                        'subjectAltName=DNS:' + FAKE_HOST + ',DNS:localhost,IP:127.0.0.1',
                        '-keyout', str(self.path / 'key.pem'), '-out', str(self.path / 'ca.pem')],
                       check=True, capture_output=True)
        result = docker('create', '--name', 'orbita-b1-server-' + self.token[:16],
                        '--label', 'orbita.b1.fixture=' + self.token, '--network', 'none',
                        '--add-host', FAKE_HOST + ':127.0.0.1',
                        '--tmpfs', '/var/lib/postgresql/data:rw,noexec,nosuid,size=256m',
                        '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', '--entrypoint', 'sh',
                        LOCK['postgres_image'], '-c',
                        'chown postgres:postgres /tmp/b1-key.pem /tmp/b1-ca.pem; '
                        'chmod 600 /tmp/b1-key.pem; exec docker-entrypoint.sh postgres '
                        '-c ssl=on -c ssl_cert_file=/tmp/b1-ca.pem -c ssl_key_file=/tmp/b1-key.pem')
        self.cid = result.stdout.strip()
        if len(self.cid) != 64:
            raise AssertionError('Не получен точный CID своего сервера')
        docker('cp', str(self.path / 'key.pem'), self.cid + ':/tmp/b1-key.pem')
        docker('cp', str(self.path / 'ca.pem'), self.cid + ':/tmp/b1-ca.pem')
        docker('start', self.cid)
        deadline = time.monotonic() + 30
        while True:
            process = docker('exec', self.cid, 'cat', '/proc/1/comm', check=False)
            ready = docker('exec', self.cid, 'pg_isready', '-U', 'postgres', check=False)
            if process.stdout.strip() == 'postgres' and ready.returncode == 0:
                return
            if time.monotonic() >= deadline:
                raise AssertionError('Собственный PostgreSQL не запустился')
            time.sleep(.1)

    def query(self, sql):
        return docker('exec', '-i', self.cid, 'psql', '-X', '-Atq', '-v', 'ON_ERROR_STOP=1',
                      '-U', 'postgres', '-d', 'postgres', input=sql).stdout.strip()

    def sessions(self, marker):
        return json.loads(self.query("select coalesce(json_agg(json_build_object("
            "'pid',pid,'backend_start',backend_start,'state',state,'xact_start',xact_start,"
            "'wait_event_type',wait_event_type)), '[]') from pg_stat_activity "
            "where application_name='" + marker + "' and datname='postgres' and usename='postgres';"))

    def shim(self, token):
        # Только клиенты этого теста: изолированная сеть сервера и дополнительная ownership-метка.
        # exec сохраняет настоящий сигнал/поведение Docker CLI, не имитирует работу PostgreSQL.
        script = self.path / ('docker-' + token + '.py')
        script.write_text('import os,sys,uuid\n'
            'args=sys.argv[1:]\n'
            'base=' + repr(REAL_DOCKER) + '\n'
            'if args and args[0] in ("run","create"):\n'
            ' extra=["--network",' + repr('container:' + self.cid) + ',"--label",' + repr('orbita.b1.test=' + token) + ']\n'
            ' if "--name" not in args:extra += ["--name",' + repr('orbita-b1-client-' + token[:16] + '-') + '+uuid.uuid4().hex[:8]]\n'
            ' args=[args[0]]+extra+args[1:]\n'
            'os.execvpe(base[0],base+args,os.environ)\n')
        return [sys.executable, str(script)]

    def clients(self, token):
        result = docker('ps', '-aq', '--no-trunc', '--filter', 'label=orbita.b1.test=' + token)
        return result.stdout.split()

    def close(self):
        if self.cid:
            remove_owned(self.cid, 'orbita.b1.fixture', self.token)
        after = containers()
        for cid, value in self.original.items():
            if cid not in after or after[cid]['Names'] != value['Names'] or after[cid]['State'] != value['State']:
                raise AssertionError('Исходные Docker-контейнеры изменились')
        self.directory.cleanup()


class B1TimeoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = B1Fixture()
        try:
            cls.fixture.start()
        except BaseException:
            cls.fixture.close()
            raise
        cls.records = []

    @classmethod
    def tearDownClass(cls):
        try:
            destination = ROOT / 'build/b1-regression-results.json'
            destination.parent.mkdir(exist_ok=True)
            destination.write_text(json.dumps(cls.records, ensure_ascii=False, indent=2) + '\n')
        finally:
            cls.fixture.close()

    def setUp(self):
        self.token = uuid.uuid4().hex
        self.marker = 'orbita_b1_' + self.token
        self.neighbor = 'orbita_b1_neighbor_' + self.token[:20]
        self.table = 'b1_' + self.token[:20]
        self.fixture.query('create table public.' + self.table + '(n integer);')
        self.neighbor_process = subprocess.Popen(REAL_DOCKER + ['exec', '-i', self.fixture.cid,
            'psql', '-X', '-Atq', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'postgres'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.neighbor_process.stdin.write("set application_name='" + self.neighbor + "'; begin; "
            'lock table public.' + self.table + ' in access exclusive mode; select pg_sleep(60);\n')
        self.neighbor_process.stdin.flush()
        deadline = time.monotonic() + 5
        while not self.fixture.sessions(self.neighbor):
            if time.monotonic() >= deadline:
                self.fail('Не запустилась собственная соседняя сессия')
            time.sleep(.05)

    def tearDown(self):
        # Удалять можно только CID с точной меткой текущего теста.
        for cid in self.fixture.clients(self.token):
            remove_owned(cid, 'orbita.b1.test', self.token)
        for marker in [self.marker, self.neighbor]:
            self.fixture.query("select pg_terminate_backend(pid) from pg_stat_activity where application_name='"
                + marker + "' and datname='postgres' and usename='postgres' and pid<>pg_backend_pid();")
        try:
            self.neighbor_process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.neighbor_process.kill()
            self.neighbor_process.communicate(timeout=5)
        self.fixture.query('drop table public.' + self.table + ';')

    def check_timeout(self, wait_for_lock):
        db = dbtools.Database('postgresql://postgres@' + FAKE_HOST + ':5432/postgres?sslmode=verify-full',
                              FAKE_REF, 'local-fixture-only', self.fixture.path / 'ca.pem')
        sql = "set application_name='" + self.marker + "'; begin; set statement_timeout=0; set lock_timeout=0; "
        sql += ('lock table public.' + self.table + ' in access share mode; ') if wait_for_lock else ''
        sql += 'select pg_sleep(30); commit;'
        observed = []
        observer_errors = []
        stop = threading.Event()
        def observe():
            try:
                while not stop.is_set():
                    sessions = self.fixture.sessions(self.marker)
                    if any(s['state'] == 'active' and
                           (not wait_for_lock or s['wait_event_type'] == 'Lock') for s in sessions):
                        observed.extend(sessions)
                        return
                    stop.wait(.03)
            except BaseException as error:
                observer_errors.append(type(error).__name__)
        with patch.object(dbtools, 'DOCKER', self.fixture.shim(self.token)),\
             patch.object(dbtools, '_new_operation_token', return_value=self.marker, create=True):
            self.assertEqual(db.query('select 1;'), '1', 'Контроль TLS-подключения не прошёл')
            watcher = threading.Thread(target=observe)
            watcher.start()
            try:
                with self.assertRaises(GuardError):
                    db.tool('psql', ['-X', '-Atq', '-v', 'ON_ERROR_STOP=1', '--dbname', db.url],
                            input=sql.encode(), timeout=5)
            finally:
                stop.set()
                watcher.join(timeout=5)
        sessions = self.fixture.sessions(self.marker)
        waiting = int(self.fixture.query("select count(*) from pg_locks l join pg_stat_activity a on a.pid=l.pid "
            "where a.application_name='" + self.marker + "' and not l.granted;"))
        idle = sum(s['xact_start'] is not None for s in sessions)
        clients = self.fixture.clients(self.token)
        neighbor_alive = any(s['state'] == 'active' for s in self.fixture.sessions(self.neighbor))
        record = {'test': self.id(), 'marker': self.marker, 'wait_for_lock': wait_for_lock,
            'observed_running': observed, 'observer_errors': observer_errors,
            'sessions_after_timeout': sessions, 'waiting_locks': waiting, 'transactions': idle,
            'owned_clients_left': clients, 'neighbor_untouched': neighbor_alive}
        self.records.append(record)
        self.assertFalse(watcher.is_alive(), record)
        self.assertEqual(observer_errors, [], record)
        self.assertTrue(observed, record)
        self.assertTrue(neighbor_alive, record)
        self.assertEqual(sessions, [], record)
        self.assertEqual(waiting, 0, record)
        self.assertEqual(idle, 0, record)
        self.assertEqual(clients, [], record)

    def test_long_query_is_gone_after_wrapper_timeout(self):
        self.check_timeout(False)

    def test_waiting_lock_and_transaction_are_gone_after_wrapper_timeout(self):
        self.check_timeout(True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
