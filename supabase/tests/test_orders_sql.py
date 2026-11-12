"""Реальный PostgreSQL 17, только синтетические данные и локальный transport.

python3 -m unittest discover -s supabase/tests -p test_orders_sql.py -v
ORBITA_ORDERS_PG_BIN указывает на проверенную PostgreSQL 17 без установки/сети.
ORBITA_ORDERS_PG_VERSION фиксирует точный --version предоставленного бинарника.
Кластер принадлежит тесту, слушает только private Unix socket (TCP отключён).
JWT GUC-модель НЕ проверяет подпись JWT, Auth HTTP или настоящий PostgREST.
Прежние bootstrap/Auth-тесты, миграция и migration runners не изменяются.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = ROOT / 'supabase/proposals/20261112172442_passenger_orders.sql'
NATIVE_POSTGRES_VERSION = 'postgres (PostgreSQL) 17.11 (Debian 17.11-0+deb13u1)'
USERS = [f'00000000-0000-4000-8000-{n:012d}' for n in range(1, 7)]
A, B, D, N, M, X = USERS
SESSIONS = {user: str(uuid.UUID(int=100 + index)) for index, user in enumerate(USERS)}
PICKUP = {'address': 'Чик, улица Учебная, 1', 'latitude': 55.0, 'longitude': 82.43}
DESTINATION = {'address': 'Чик, улица Речная, 2', 'latitude': 55.01, 'longitude': 82.44}
DEFAULT = object()


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def point_sql(point):
    return 'null' if point is None else literal(json.dumps(point, ensure_ascii=False)) + '::jsonb'


def create_sql(request_id, pickup=PICKUP, destination=DESTINATION):
    request = 'null' if request_id is None else literal(request_id) + '::uuid'
    return f'select public.orbita_create_order({request},{point_sql(pickup)},{point_sql(destination)});'


class OrdersSQLTests(unittest.TestCase):
    records = []

    @classmethod
    def setUpClass(cls):
        # Никаких PATH-fallback, скачиваний, облачных адресов или Docker pull.
        location = os.environ.get('ORBITA_ORDERS_PG_BIN')
        expected_version = os.environ.get('ORBITA_ORDERS_PG_VERSION')
        if not location or not expected_version:
            raise RuntimeError('Нужны отдельно проверенные ORBITA_ORDERS_PG_BIN и ORBITA_ORDERS_PG_VERSION')
        cls.bin = Path(location).resolve()
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith('PG')}
        version = subprocess.run([str(cls.bin / 'postgres'), '--version'], env=cls.env,
                                 capture_output=True, text=True, check=True).stdout.strip()
        if version != expected_version or not version.startswith('postgres (PostgreSQL) 17.'):
            raise RuntimeError('Предоставленный PostgreSQL не совпадает с точным pin PostgreSQL 17')
        if version != NATIVE_POSTGRES_VERSION:
            raise RuntimeError('Native package pin не совпадает с отдельно проверенными Debian security пакетами')
        cls.server_version = version
        cls.directory = tempfile.TemporaryDirectory(prefix='orbita-orders-pg-')
        cls.path = Path(cls.directory.name)
        cls.socket = cls.path / 'socket'
        cls.socket.mkdir(mode=0o700)
        cls.data = cls.path / 'data'
        cls.started = False
        try:
            subprocess.run([str(cls.bin / 'initdb'), '-D', str(cls.data), '-U', 'postgres',
                            '-L', str(cls.bin.parents[3] / 'share/postgresql/17'),
                            '--auth=trust', '--encoding=UTF8', '--no-locale'],
                           env=cls.env, check=True, capture_output=True, text=True, timeout=30)
            # Фиксированный порт существует только внутри уникальной socket-директории.
            subprocess.run([str(cls.bin / 'pg_ctl'), '-D', str(cls.data), '-l', str(cls.path / 'server.log'),
                            '-o', f"-k {cls.socket} -p 55432 -c listen_addresses='' -c fsync=off",
                            '-w', 'start'], env=cls.env, check=True, capture_output=True, text=True, timeout=30)
            cls.started = True
            cls.owner('create database orbita_orders_template;')
            for file in ['bootstrap_local.sql', 'bootstrap_orders_local.sql']:
                cls.owner((ROOT / 'supabase/tests' / file).read_text(), db='orbita_orders_template')
            cls.owner('begin;\n' + (ROOT / 'supabase/migrations/202611050001_stage3b_auth.sql').read_text()
                      + '\ncommit;', db='orbita_orders_template')
            cls.owner('begin;\n' + CANDIDATE.read_text() + '\ncommit;', db='orbita_orders_template')
            cls.owner("select pg_terminate_backend(pid) from pg_stat_activity where datname='orbita_orders_template';")
        except BaseException:
            cls.stop_server()
            raise

    @classmethod
    def stop_server(cls):
        # Проверяем owned data даже после прерванного pg_ctl start: он мог
        # успеть поднять backend до клиентского таймаута.
        if (cls.data / 'postmaster.pid').exists():
            subprocess.run([str(cls.bin / 'pg_ctl'), '-D', str(cls.data), '-m', 'immediate', '-w', 'stop'],
                           env=cls.env, check=True, capture_output=True, text=True, timeout=20)
        cls.started = False
        cls.directory.cleanup()

    @classmethod
    def tearDownClass(cls):
        try:
            output = ROOT / 'build/passenger-orders-sql-results.json'
            output.parent.mkdir(exist_ok=True)
            output.write_text(json.dumps({
                'environment': cls.server_version,
                'transport': 'private Unix socket; listen_addresses empty; no TCP',
                'client_connections': 'LOGIN anon/authenticated, no SET ROLE, no BYPASSRLS',
                'limitation': 'Synthetic JWT GUCs; JWT signature/Auth HTTP/PostgREST/cloud not tested',
                'records': cls.records,
            }, ensure_ascii=False, indent=2) + '\n')
        finally:
            cls.stop_server()

    @classmethod
    def sql(cls, statement, *, role='postgres', uid=B, claims=DEFAULT, db='postgres', app=None):
        prefix = '\\set VERBOSITY verbose\n'
        if app:
            prefix += 'select set_config(\'application_name\',' + literal(app) + ',false);\n'
        if role != 'postgres':
            if claims is DEFAULT:
                claims = {'sub': uid, 'session_id': SESSIONS.get(uid), 'exp': int(time.time()) + 3600}
            prefix += "select set_config('request.jwt.claim.sub'," + literal(uid or '') + ',false);\n'
            prefix += "select set_config('request.jwt.claims'," + literal(json.dumps(claims)) + ',false);\n'
            prefix += """select json_build_object('client_context',true,'current_user',current_user,
                'session_user',session_user,'bypassrls',rolbypassrls,'superuser',rolsuper,
                'owns_orders',exists(select 1 from pg_class where oid='public.orbita_orders'::regclass
                  and relowner=pg_roles.oid),'uid',auth.uid()) from pg_roles where rolname=current_user;
                """
        return subprocess.run([str(cls.bin / 'psql'), '-X', '-Atq', '-v', 'ON_ERROR_STOP=1',
                               '-h', str(cls.socket), '-p', '55432', '-U', role, '-d', db],
                              env=cls.env, input=prefix + statement, capture_output=True, text=True, timeout=25)

    @classmethod
    def owner(cls, statement, db='postgres'):
        result = cls.sql(statement, db=db)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def setUp(self):
        self.db = 'orders_' + uuid.uuid4().hex[:12]
        self.events = []
        self.owner(f'create database {self.db} template orbita_orders_template;')
        self.admin('insert into auth.users(id,email) values ' + ','.join(
            f"('{user}','orders{i}@example.test')" for i, user in enumerate(USERS)) + ';')
        for user in [A, B, D, N, M]:
            self.action(user, 'provision')
        self.action(A, 'bootstrap', 'admin', True)
        for user, role in [(B, 'passenger'), (D, 'driver'), (M, 'passenger')]:
            self.action(user, 'assign', role)
        self.admin('insert into auth.sessions(id,user_id) values ' + ','.join(
            f"('{session}','{user}')" for user, session in SESSIONS.items()) + ';')
        self.assertEqual(self.admin("select current_setting('listen_addresses')='' and inet_server_addr() is null;"), 't')

    def tearDown(self):
        result = self._outcome.result
        failed = any(test is self for test, _ in result.failures + result.errors)
        self.records.append({'test': self.id(), 'passed': not failed, 'events': self.events})
        self.owner(f'drop database {self.db};')

    def admin(self, statement):
        return self.owner(statement, db=self.db)

    def action_sql(self, target, action, role=None, confirm=False):
        role_sql = 'null' if role is None else literal(role)
        return (f"select orbita_mobile_private.admin_access('{target}','{action}',{role_sql},null,"
                f"'Локальный синтетический orders тест',{str(confirm).lower()});")

    def action(self, target, action, role=None, confirm=False):
        return self.admin(self.action_sql(target, action, role, confirm))

    def client_raw(self, statement, *, role='authenticated', uid=B, claims=DEFAULT, app=None):
        result = self.sql(statement, role=role, uid=uid, claims=claims, db=self.db, app=app)
        objects = []
        for line in result.stdout.splitlines():
            try:
                value = json.loads(line)
                if isinstance(value, dict):
                    objects.append(value)
            except json.JSONDecodeError:
                pass
        context = next(value for value in objects if value.get('client_context'))
        self.assertEqual(context['current_user'], role)
        self.assertEqual(context['session_user'], role)
        self.assertEqual(context['uid'], uid)
        self.assertFalse(context['superuser'] or context['bypassrls'] or context['owns_orders'])
        return result, objects

    def invoke(self, statement, *, error=None, code='P0001', **kwargs):
        result, objects = self.client_raw(statement, **kwargs)
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(code, result.stderr)
            self.assertIn(error, result.stderr)
            # Проверяем primary message, а не только SQLSTATE или факт ошибки.
            primary = next(line for line in result.stderr.splitlines() if 'ERROR:' in line)
            self.assertTrue(primary.endswith(error), primary)
            for user in USERS:
                self.assertNotIn(user, result.stderr)
            self.assertNotIn(PICKUP['address'], result.stderr)
            self.events.append({'error': error, 'sqlstate': code, 'client': kwargs.get('role', 'authenticated')})
            return primary
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = next(value for value in reversed(objects) if 'contract_version' in value)
        self.assertEqual(set(receipt), {'contract_version', 'server_time', 'order'})
        self.assertEqual(receipt['contract_version'], 1)
        self.assertTrue(receipt['server_time'].endswith('Z'))
        self.events.append({'status': receipt['order']['status'] if receipt['order'] else None})
        return receipt

    def create(self, request=None, **kwargs):
        return self.invoke(create_sql(request or str(uuid.uuid4())), **kwargs)

    def snapshot(self):
        return self.admin('select coalesce(jsonb_agg(t order by id),\'[]\') from public.orbita_orders t;')

    def expire(self, order_id):
        self.admin("with moment as (select clock_timestamp()-interval '6 minutes' as t) "
                   f"update public.orbita_orders set created_at=moment.t,expires_at=moment.t+interval '5 minutes' "
                   f"from moment where id='{order_id}';")

    def wait_backend(self, app, event):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            count = self.admin(f"select count(*) from pg_stat_activity where application_name='{app}' and {event};")
            if count == '1':
                return
            time.sleep(.02)
        self.fail('Синтетический backend не достиг ожидаемого состояния')

    def test_01_acl_rls_private_helpers_and_real_login(self):
        self.assertEqual(self.admin("select relrowsecurity from pg_class where oid='public.orbita_orders'::regclass;"), 't')
        self.assertEqual(self.admin("select count(*) from pg_policies where schemaname='public' and tablename='orbita_orders';"), '0')
        self.assertEqual(self.admin("""select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where p.proname in ('orbita_create_order','orbita_get_current_order','orbita_get_order','orbita_cancel_order',
              'order_point','order_session_uid','order_envelope') and (p.proowner<>'postgres'::regrole
              or not p.prosecdef or p.proconfig is distinct from array['search_path=""']);"""), '0')
        before = self.snapshot()
        for role in ['anon', 'authenticated']:
            for statement in ['select * from public.orbita_orders;', 'insert into public.orbita_orders default values;',
                              "update public.orbita_orders set status='cancelled';", 'delete from public.orbita_orders;']:
                result, _ = self.client_raw(statement, role=role)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('42501', result.stderr)
            self.assertEqual(self.admin(f"select has_schema_privilege('{role}','orbita_mobile_private','USAGE');"), 'f')
        self.assertEqual(before, self.snapshot())
        self.invoke('select public.orbita_get_current_order();', role='anon',
                    error='permission denied for function orbita_get_current_order', code='42501')
        for role in ['anon', 'authenticated', 'service_role']:
            self.assertEqual(self.admin(f"select has_table_privilege('{role}','public.orbita_orders','SELECT,INSERT,UPDATE,DELETE,TRUNCATE');"), 'f')
            self.assertEqual(self.admin(f"select has_function_privilege('{role}','orbita_mobile_private.order_session_uid()','EXECUTE');"), 'f')
        self.assertEqual(self.admin("select has_function_privilege('service_role','public.orbita_create_order(uuid,jsonb,jsonb)','EXECUTE');"), 'f')

    def test_02_creation_shape_server_deadline_and_no_price(self):
        receipt = self.create()
        order = receipt['order']
        self.assertEqual(set(order), {'id', 'passenger_id', 'request_id', 'pickup', 'destination', 'status',
                                     'cancellation_reason', 'created_at', 'expires_at', 'cancelled_at', 'version'})
        self.assertEqual(order['passenger_id'], B)
        self.assertEqual(order['pickup'], PICKUP)
        self.assertEqual(order['destination'], DESTINATION)
        self.assertEqual((order['status'], order['version'], order['cancellation_reason'], order['cancelled_at']),
                         ('created', 1, None, None))
        self.assertEqual((datetime.fromisoformat(order['expires_at']) - datetime.fromisoformat(order['created_at'])).total_seconds(), 300)
        for key in ['price', 'fare', 'tariff', 'eta']:
            self.assertNotIn('"' + key + '"', json.dumps(receipt).lower())
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '1')

    def test_03_current_product_role_block_and_consistency(self):
        self.admin(f'''update auth.users set raw_user_meta_data='{{"role":"passenger"}}' where id='{N}';''')
        for user in [A, D, N, X]:
            self.create(uid=user, error='ORB_ORDER_CREATE_FORBIDDEN', code='42501')
        self.action(B, 'block')
        self.create(error='ORB_ORDER_CREATE_FORBIDDEN', code='42501')
        self.action(B, 'unblock')
        self.admin(f"delete from public.orbita_account_access where user_id='{M}';")
        self.create(uid=M, error='ORB_ORDER_CREATE_FORBIDDEN', code='42501')
        self.assertEqual(self.snapshot(), '[]')

    def test_04_session_uid_binding_expiry_revocation_all_rpc(self):
        request = str(uuid.uuid4())
        missing_id = str(uuid.uuid4())
        statements = [create_sql(request), 'select public.orbita_get_current_order();',
                      f"select public.orbita_get_order('{missing_id}');", f"select public.orbita_cancel_order('{missing_id}');"]
        valid = {'sub': B, 'session_id': SESSIONS[B], 'exp': int(time.time()) + 3600}
        cases = [{}, {**valid, 'exp': 1}, {**valid, 'exp': str(valid['exp'])},
                 {**valid, 'session_id': 'invalid'}, {**valid, 'session_id': str(uuid.uuid4())},
                 {**valid, 'session_id': SESSIONS[M]}, {**valid, 'sub': M}]
        for claims in cases:
            for statement in statements:
                self.invoke(statement, claims=claims, error='ORB_ORDER_SESSION_REQUIRED', code='28000')
        for statement in statements:
            self.invoke(statement, uid=None, error='ORB_ORDER_SESSION_REQUIRED', code='28000')
        self.admin(f"update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id='{SESSIONS[B]}';")
        for statement in statements:
            self.invoke(statement, error='ORB_ORDER_SESSION_REQUIRED', code='28000')
        self.admin(f"delete from auth.sessions where id='{SESSIONS[B]}';")
        for statement in statements:
            self.invoke(statement, error='ORB_ORDER_SESSION_REQUIRED', code='28000')
        self.assertEqual(self.snapshot(), '[]')

    def test_05_exact_point_shape_numbers_bounds_and_unicode_canonicalization(self):
        invalid = [None, [], {}, {**PICKUP, 'price': 1}, {k: v for k, v in PICKUP.items() if k != 'address'},
                   {**PICKUP, 'address': None}, {**PICKUP, 'address': ' \t\n'}, {**PICKUP, 'address': 'я' * 501},
                   {**PICKUP, 'latitude': '55'}, {**PICKUP, 'latitude': None}, {**PICKUP, 'latitude': 90.0001},
                   {**PICKUP, 'longitude': -180.0001}, {**PICKUP, 'latitude': 'NaN'}]
        for point in invalid:
            self.invoke(create_sql(str(uuid.uuid4()), pickup=point), error='ORB_ORDER_INVALID_REQUEST')
        self.invoke(create_sql(None), error='ORB_ORDER_INVALID_REQUEST')
        self.invoke(create_sql(str(uuid.uuid4()), destination=PICKUP), error='ORB_ORDER_INVALID_REQUEST')
        spaces = ''.join(chr(code) for code in [*range(9, 14), 32, 0x85, 0xa0, 0x1680, *range(0x2000, 0x200b),
                                               0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff])
        request = str(uuid.uuid4())
        point = {'address': spaces + 'Чик,' + spaces + 'дом 1' + spaces, 'latitude': -90, 'longitude': -180}
        destination = {**DESTINATION, 'latitude': 90, 'longitude': 180}
        receipt = self.invoke(create_sql(request, point, destination))
        canonical = {**point, 'address': 'Чик, дом 1'}
        self.assertEqual(receipt['order']['pickup'], canonical)
        self.assertEqual(self.invoke(create_sql(request, canonical, destination))['order'], receipt['order'])

    def test_06_replay_canonical_payload_and_after_passenger_cancel(self):
        request = str(uuid.uuid4())
        order = self.create(request)['order']
        equivalent = {**PICKUP, 'address': '  Чик,  улица Учебная, 1\n'}
        replay = self.invoke(create_sql(request, equivalent))['order']
        self.assertEqual(order, replay)
        cancelled = self.invoke(f"select public.orbita_cancel_order('{order['id']}');")['order']
        self.assertEqual(self.create(request)['order'], cancelled)
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '1')

    def test_07_changed_payload_conflicts_and_request_key_scoped_to_owner(self):
        request = str(uuid.uuid4())
        order = self.create(request)['order']
        before = self.snapshot()
        for changed in [{**PICKUP, 'address': 'Другой адрес'}, {**PICKUP, 'latitude': 54.0}]:
            self.invoke(create_sql(request, changed), error='ORB_ORDER_IDEMPOTENCY_CONFLICT')
            self.assertEqual(before, self.snapshot())
        other = self.create(request, uid=M)['order']
        self.assertNotEqual(order['id'], other['id'])
        self.assertEqual(other['passenger_id'], M)

    def test_08_two_concurrent_same_keys_commit_one_receipt(self):
        request = str(uuid.uuid4())
        barrier = threading.Barrier(2)
        def create():
            barrier.wait(timeout=5)
            return self.invoke(create_sql(request))['order']
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: create(), range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '1')

    def test_09_two_concurrent_different_keys_one_active(self):
        barrier = threading.Barrier(2)
        def create():
            barrier.wait(timeout=5)
            return self.client_raw(create_sql(str(uuid.uuid4())))[0]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: create(), range(2)))
        self.assertEqual(sum(result.returncode == 0 for result in results), 1)
        failure = next(result for result in results if result.returncode)
        self.assertIn('P0001: ORB_ORDER_ACTIVE_EXISTS', failure.stderr)
        self.assertEqual(self.admin("select count(*) from public.orbita_orders where status='created';"), '1')
        # Отдельная проверка ограничения самой таблицы под владельцем, не RLS.
        probe = self.sql("insert into public.orbita_orders(passenger_id,request_id,pickup,destination,created_at,expires_at) "
                         "select passenger_id,gen_random_uuid(),pickup,destination,created_at,expires_at from public.orbita_orders;", db=self.db)
        self.assertNotEqual(probe.returncode, 0)
        self.assertIn('23505', probe.stderr)

    def test_10_restore_own_only_and_foreign_missing_same_error(self):
        self.assertIsNone(self.invoke('select public.orbita_get_current_order();')['order'])
        order = self.create()['order']
        self.assertEqual(self.invoke('select public.orbita_get_current_order();')['order'], order)
        self.assertEqual(self.invoke(f"select public.orbita_get_order('{order['id']}');")['order'], order)
        before = self.snapshot()
        for function in ['orbita_get_order', 'orbita_cancel_order']:
            foreign = self.invoke(f"select public.{function}('{order['id']}');", uid=M, error='ORB_ORDER_NOT_FOUND')
            missing = self.invoke(f"select public.{function}('{uuid.uuid4()}');", uid=M, error='ORB_ORDER_NOT_FOUND')
            self.assertEqual(foreign, missing)
            self.invoke(f'select public.{function}(null);', error='ORB_ORDER_INVALID_REQUEST')
        self.assertEqual(before, self.snapshot())

    def test_11_cancel_repeat_latest_recovery_and_active_preferred(self):
        first = self.create()['order']
        cancelled = self.invoke(f"select public.orbita_cancel_order('{first['id']}');")['order']
        self.assertEqual((cancelled['status'], cancelled['cancellation_reason'], cancelled['version']), ('cancelled', 'passenger', 2))
        self.assertEqual(self.invoke(f"select public.orbita_cancel_order('{first['id']}');")['order'], cancelled)
        self.assertEqual(self.invoke('select public.orbita_get_current_order();')['order'], cancelled)
        active = self.create()['order']
        # Синтетический tie: latest fallback выбрал бы terminal с большим UUID.
        self.admin("update public.orbita_orders old set id='ffffffff-ffff-4fff-8fff-ffffffffffff',"
                   "created_at=live.created_at,expires_at=live.expires_at from public.orbita_orders live "
                   f"where old.id='{first['id']}' and live.id='{active['id']}';")
        self.assertEqual(self.invoke('select public.orbita_get_current_order();')['order'], active)

    def test_12_timeout_reads_without_writes_and_next_create_normalizes(self):
        request = str(uuid.uuid4())
        order = self.create(request)['order']
        self.expire(order['id'])
        before = self.snapshot()
        timed_out = self.invoke(f"select public.orbita_get_order('{order['id']}');")['order']
        self.assertEqual((timed_out['status'], timed_out['cancellation_reason'], timed_out['version']), ('cancelled', 'search_timeout', 2))
        self.assertEqual(timed_out['cancelled_at'], timed_out['expires_at'])
        self.assertEqual(self.invoke('select public.orbita_get_current_order();')['order'], timed_out)
        self.assertEqual(self.create(request)['order'], timed_out)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(self.admin(f"select status||':'||version from public.orbita_orders where id='{order['id']}';"), 'created:1')
        next_order = self.create()['order']
        self.assertNotEqual(next_order['id'], order['id'])
        self.assertEqual(self.invoke(f"select public.orbita_get_order('{order['id']}');")['order'], timed_out)
        self.assertEqual(self.create(request)['order'], timed_out)
        self.assertEqual(self.admin(f"select status||':'||version from public.orbita_orders where id='{order['id']}';"), 'cancelled:2')

    def test_13_cancel_at_deadline_timeout_reason_wins_and_is_stable(self):
        order = self.create()['order']
        self.admin("with moment as (select clock_timestamp() as t) update public.orbita_orders "
                   "set created_at=moment.t-interval '5 minutes',expires_at=moment.t from moment "
                   f"where id='{order['id']}';")
        effective = self.invoke(f"select public.orbita_get_order('{order['id']}');")['order']
        cancelled = self.invoke(f"select public.orbita_cancel_order('{order['id']}');")['order']
        self.assertEqual(effective, cancelled)
        self.assertEqual(cancelled['cancellation_reason'], 'search_timeout')
        self.assertEqual(self.invoke(f"select public.orbita_cancel_order('{order['id']}');")['order'], effective)

    def test_14_create_waits_for_block_or_revoke_and_checks_fresh_rights(self):
        for action in ['block', 'revoke']:
            app = 'orders-access-' + uuid.uuid4().hex[:12]
            waiter = 'orders-wait-' + uuid.uuid4().hex[:12]
            with ThreadPoolExecutor(max_workers=2) as pool:
                blocking = pool.submit(self.sql, 'begin; ' + self.action_sql(B, action) + ' select pg_sleep(1.2); commit;', db=self.db, app=app)
                self.wait_backend(app, "wait_event='PgSleep'")
                creating = pool.submit(self.client_raw, create_sql(str(uuid.uuid4())), app=waiter)
                self.wait_backend(waiter, "wait_event_type='Lock'")
                owner_result = blocking.result()
                result, _ = creating.result()
            self.assertEqual(owner_result.returncode, 0, owner_result.stderr)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('42501: ORB_ORDER_CREATE_FORBIDDEN', result.stderr)
            self.assertEqual(self.snapshot(), '[]')
            self.action(B, 'unblock' if action == 'block' else 'assign', None if action == 'block' else 'passenger')

    def test_15_owner_read_replay_cancel_survive_block_and_role_change(self):
        for action in ['block', 'revoke']:
            request = str(uuid.uuid4())
            order = self.create(request)['order']
            self.action(B, action)
            self.assertEqual(self.invoke(f"select public.orbita_get_order('{order['id']}');")['order'], order)
            self.assertEqual(self.invoke('select public.orbita_get_current_order();')['order'], order)
            self.assertEqual(self.create(request)['order'], order)
            self.create(error='ORB_ORDER_CREATE_FORBIDDEN', code='42501')
            cancelled = self.invoke(f"select public.orbita_cancel_order('{order['id']}');")['order']
            self.assertEqual(self.create(request)['order'], cancelled)
            self.action(B, 'unblock' if action == 'block' else 'assign', None if action == 'block' else 'passenger')

    def test_16_real_server_timeout_rolls_back_and_retry_same_intent_once(self):
        request = str(uuid.uuid4())
        app = 'orders-timeout-' + uuid.uuid4().hex[:12]
        with ThreadPoolExecutor(max_workers=2) as pool:
            blocking = pool.submit(self.sql, 'begin; select orbita_mobile_private.lock_access(); select pg_sleep(1); commit;', db=self.db, app=app)
            self.wait_backend(app, "wait_event='PgSleep'")
            result, _ = self.client_raw("begin; set local statement_timeout='120ms'; " + create_sql(request) + ' commit;')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('57014', result.stderr)
            self.assertIn('statement timeout', result.stderr)
            self.assertEqual(blocking.result().returncode, 0)
        self.assertEqual(self.snapshot(), '[]')
        order = self.create(request)['order']
        self.assertEqual(self.create(request)['order'], order)
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '1')


if __name__ == '__main__':
    unittest.main(verbosity=2)
