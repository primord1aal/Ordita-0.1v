"""Administrative restrictions and audit against a disposable PostgreSQL."""

from concurrent.futures import ThreadPoolExecutor
import threading
import unittest
import uuid

try:
    from . import test_dispatch_sql as dispatch
except ImportError:
    import test_dispatch_sql as dispatch


base = dispatch.base
A, B, D, N, M = base.A, base.B, base.D, base.N, base.M
PROPOSALS = base.ROOT / 'supabase/proposals'
READ = 'select orbita_admin_api.operations();'
AUDIT = 'orbita_admin_private.operation_audit'
RESTRICTIONS = 'orbita_admin_private.driver_restrictions'


class OrbitaAdminOperationsTests(unittest.TestCase):
    records = []

    for name in (
        'setUpClass', 'stop_server', 'sql', 'owner', 'tearDown', 'admin',
        'action_sql', 'action', 'client_raw', 'statement', 'rpc', 'create',
        'online', 'offer', 'respond', 'queue',
    ):
        locals()[name] = dispatch.DispatchSQLTests.__dict__[name]

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()

    def setUp(self):
        dispatch.DispatchSQLTests.setUp(self)
        for name in (
            '20261120173504_managed_maps.sql',
            'orbita_admin_read_model.sql',
            'orbita_dispatch_push.sql',
            'orbita_admin_operations.sql',
        ):
            self.admin('begin;\n' + (PROPOSALS / name).read_text() + '\ncommit;')
        for driver, name in ((D, 'first'), (N, 'second')):
            result, _ = self.client_raw(
                f"select public.orbita_driver_push_device('synthetic-rustore-device-{name}');", uid=driver,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def restriction_sql(self, driver=D, value=True, request=None):
        request = request or uuid.uuid4()
        return (
            f"select orbita_admin_api.set_driver_restriction('{request}', '{driver}', "
            f"{str(value).lower()});"
        )

    def restrict(self, driver=D, value=True, request=None, uid=A, **options):
        process, rows = self.client_raw(
            self.restriction_sql(driver, value, request), uid=uid, **options,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        return next(row for row in rows if 'restricted' in row)

    def read(self, uid=A, statement=READ):
        process, rows = self.client_raw(statement, uid=uid)
        self.assertEqual(process.returncode, 0, process.stderr)
        return next(row for row in rows if row.get('contract_version') == 1)

    def deny(self, uid, statement, error, **options):
        result, _ = self.client_raw(statement, uid=uid, **options)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(error, result.stderr)

    def test_only_verified_admin_session_can_use_operations(self):
        for user in (B, D):
            forged_claims = {
                'sub': user, 'session_id': base.SESSIONS[user], 'exp': 4102444800,
                'app_metadata': {'role': 'admin'}, 'user_metadata': {'role': 'admin'},
            }
            for statement in (READ, self.restriction_sql(),
                              'select orbita_admin_private.operations();'):
                self.deny(user, statement, 'ORB_ADMIN_FORBIDDEN', claims=forged_claims)
        self.deny(A, READ, 'permission denied', role='anon')
        self.deny(A, f'select * from {AUDIT};', 'permission denied')
        self.deny(A, f'select * from {RESTRICTIONS};', 'permission denied')
        self.assertEqual(self.admin(
            "select has_function_privilege('service_role',"
            " 'orbita_admin_api.operations()', 'EXECUTE'),"
            f"has_table_privilege('service_role', '{AUDIT}', 'SELECT,INSERT,UPDATE,DELETE');"
        ), 'f|f')

        self.action(N, 'assign', 'admin')
        self.read(N)
        self.action(N, 'block', confirm=True)
        self.deny(N, READ, 'ORB_ADMIN_FORBIDDEN')
        self.deny(N, self.restriction_sql(), 'ORB_ADMIN_FORBIDDEN')
        self.action(N, 'unblock')
        self.admin(f"delete from auth.sessions where user_id='{N}';")
        self.deny(N, READ, 'ORB_ORDER_SESSION_REQUIRED')
        self.deny(N, self.restriction_sql(), 'ORB_ORDER_SESSION_REQUIRED')

    def test_pending_offer_is_reassigned_without_changing_old_position(self):
        self.online()
        self.online(N)
        order = self.create()['order']
        old_offer = self.offer()
        old_position = self.queue()
        self.assertEqual(self.restrict(), {'driver_id': D, 'restricted': True})
        self.assertEqual(self.queue(), old_position)
        self.assertFalse(self.online()['online'])
        self.assertEqual(self.queue(), old_position)
        self.assertIsNone(self.respond(old_offer)['offer'])
        self.assertEqual(self.admin(
            f"select status from orbita_mobile_private.dispatch_offers where id='{old_offer}';"
        ), 'cancelled')
        new_offer = self.rpc('driver_poll', uid=N)['offer']
        self.assertEqual(new_offer['order_id'], order['id'])
        self.assertEqual(self.admin(
            "select recipient_id from orbita_mobile_private.claim_driver_offer_push(20);"
        ), N)

        self.restrict(value=False)
        self.assertFalse(self.rpc('driver_poll', uid=D)['online'])
        self.assertTrue(self.online()['online'])
        self.assertGreater(int(self.queue()), int(old_position))

    def test_restriction_does_not_disclose_during_ride_and_closes_line_on_completion(self):
        self.online()
        first_order = self.create()['order']
        self.respond(self.offer())
        self.restrict()
        reading = self.rpc('driver_poll', uid=D)
        self.assertTrue(reading['online'])
        self.assertEqual(reading['order']['status'], 'accepted')
        self.assertEqual(reading['outcome'], 'ok')
        self.assertNotIn('restricted', reading)
        self.assertIsNone(reading['offer'])
        admin_driver = next(row for row in self.read()['drivers'] if row['driver_id'] == D)
        self.assertTrue(admin_driver['restricted'])
        self.assertEqual(admin_driver['active_order_id'], first_order['id'])
        second_order = self.create(uid=M)['order']
        for status in ('to_pickup', 'arrived', 'riding', 'completed'):
            reading = self.rpc('advance', {'order_id': first_order['id'], 'status': status}, uid=D)
            self.assertEqual(reading['order']['status'], status)
            self.assertEqual(reading['online'], status != 'completed')
            self.assertIsNone(reading['offer'])
        self.assertFalse(self.online()['online'])
        self.assertEqual(self.rpc('passenger_poll', uid=M)['order']['status'], 'created')
        self.assertEqual(self.admin(
            f"select count(*) from orbita_mobile_private.dispatch_offers where order_id='{second_order['id']}';"
        ), '0')
        self.assertEqual(self.admin("select count(*) from orbita_mobile_private.driver_offer_push;"), '1')
        self.assertEqual(self.admin(f"select is_blocked from public.orbita_account_access where user_id='{D}';"), 'f')

    def test_restriction_racing_accept_keeps_exactly_one_authoritative_result(self):
        self.online()
        self.online(N)
        order = self.create()['order']
        offer_id = self.offer()
        barrier = threading.Barrier(2)

        def concurrent(command):
            barrier.wait(timeout=5)
            return command()

        with ThreadPoolExecutor(max_workers=2) as pool:
            admin = pool.submit(concurrent, self.restrict)
            driver = pool.submit(concurrent, lambda: self.respond(offer_id))
            self.assertTrue(admin.result(timeout=10)['restricted'])
            driver.result(timeout=10)

        snapshot = self.rpc('passenger_poll')['order']
        if snapshot['status'] == 'accepted':
            self.assertEqual(snapshot['driver_id'], D)
            self.assertIsNone(self.rpc('driver_poll', uid=N)['offer'])
            self.assertEqual(
                self.rpc('advance', {'order_id': order['id'], 'status': 'to_pickup'}, uid=D)['order']['status'],
                'to_pickup',
            )
        else:
            self.assertEqual(snapshot['status'], 'created')
            self.assertIsNone(snapshot['driver_id'])
            self.assertFalse(self.rpc('driver_poll', uid=D)['online'])
            self.assertEqual(self.rpc('driver_poll', uid=N)['offer']['order_id'], order['id'])

    def test_replay_is_audited_once_and_does_not_reverse_later_action(self):
        request = str(uuid.uuid4())
        self.online()
        initial_receipt = self.restrict(request=request)
        self.restrict(value=False)
        self.assertTrue(self.online()['online'])
        self.assertEqual(self.restrict(request=request), initial_receipt)
        self.assertTrue(self.rpc('driver_poll', uid=D)['online'])
        self.deny(A, self.restriction_sql(value=False, request=request), 'ORB_ADMIN_REQUEST_CONFLICT')
        self.deny(A, self.restriction_sql(driver=B), 'ORB_ADMIN_DRIVER_NOT_FOUND')
        snapshot = self.read(statement='begin read only; ' + READ + ' rollback;')
        self.assertFalse(snapshot['phone_orders_enabled'])
        audit = snapshot['audit']
        self.assertEqual(len(audit), 2)
        self.assertEqual([row['details'] for row in audit], [
            {'restricted': False}, {'restricted': True},
        ])
        self.assertEqual(audit[1]['request_id'], request)
        self.assertTrue(all(row['action'] == 'driver_restriction' and row['actor_id'] == A
                            and row['target_id'] == D for row in audit))

    def test_phone_order_request_id_cannot_be_reused_for_a_restriction(self):
        request = str(uuid.uuid4())
        self.admin(
            f"insert into {AUDIT}(actor_id,request_id,action,target_id)"
            f" values ('{A}', '{request}', 'phone_order', gen_random_uuid());"
        )
        self.deny(A, self.restriction_sql(request=request), 'ORB_ADMIN_REQUEST_CONFLICT')
        self.assertEqual(self.admin(f'select count(*) from {RESTRICTIONS};'), '0')

    def test_audit_is_bounded_and_returns_only_registered_fields(self):
        self.admin(f"""
          insert into {AUDIT}(actor_id,request_id,action,target_id,created_at)
          select '{A}', gen_random_uuid(), 'phone_order', gen_random_uuid(),
            clock_timestamp() - n * interval '1 minute'
          from generate_series(1,52) n;
        """)
        self.restrict()
        snapshot = self.read()
        self.assertEqual(len(snapshot['audit']), 50)
        self.assertEqual(snapshot['audit'][0]['action'], 'driver_restriction')
        self.assertEqual(set(snapshot['audit'][0]), {
            'actor_id', 'request_id', 'action', 'target_id', 'created_at', 'details',
        })
        self.assertEqual(snapshot['truncated'], {'drivers': False, 'audit': True})
