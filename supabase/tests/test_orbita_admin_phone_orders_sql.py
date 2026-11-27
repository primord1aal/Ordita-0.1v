"""Phone and mobile orders on disposable PostgreSQL with synthetic accounts."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import threading
import unittest
import uuid

try:
    from . import test_dispatch_sql as dispatch
except ImportError:
    import test_dispatch_sql as dispatch


base = dispatch.base
PROPOSALS = base.ROOT / 'supabase/proposals'
PHONE_API = 'orbita_admin_api.create_phone_order'


class AdminPhoneOrderTests(unittest.TestCase):
    records = []

    for name in ('setUpClass', 'stop_server', 'sql', 'owner', 'tearDown',
                 'admin', 'action_sql', 'action', 'client_raw', 'expire',
                 'statement', 'rpc', 'online', 'offer', 'respond'):
        locals()[name] = dispatch.DispatchSQLTests.__dict__[name]

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()

    def setUp(self):
        dispatch.DispatchSQLTests.setUp(self)
        for file in ('20261120173504_managed_maps.sql', 'orbita_admin_read_model.sql',
                     'orbita_admin_operations.sql', 'orbita_admin_phone_orders.sql'):
            self.admin('begin;\n' + (PROPOSALS / file).read_text() + '\ncommit;')

    def statement_for_phone(self, request, *, passenger=base.B, pickup=base.PICKUP,
                            destination=base.DESTINATION, function=PHONE_API):
        return (
            f"select {function}({base.literal(passenger)}, {base.literal(request)}, "
            f"{base.point_sql(pickup)}, {base.point_sql(destination)});"
        )

    def phone(self, request=None, *, actor=base.A, error=None, sqlstate=None,
              claims=base.DEFAULT, role='authenticated', **payload):
        query = self.statement_for_phone(request or str(uuid.uuid4()), **payload)
        result, objects = self.client_raw(query, uid=actor, claims=claims, role=role)
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            if sqlstate:
                self.assertIn(sqlstate, result.stderr)
            self.assertFalse(any('order_id' in row for row in objects))
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = next(row for row in objects if 'order_id' in row)
        self.assertEqual(set(receipt), {'order_id', 'status', 'expires_at'})
        return receipt

    def test_phone_order_enters_the_same_queue_and_has_a_five_minute_deadline(self):
        self.online()
        self.online(base.N)
        created = self.phone()
        mobile = self.rpc('passenger_poll')['order']
        self.assertEqual(created['order_id'], mobile['id'])
        self.assertEqual(mobile['passenger_id'], base.B)
        self.assertEqual(mobile['pickup'], base.PICKUP)
        self.assertEqual(datetime.fromisoformat(created['expires_at']),
                         datetime.fromisoformat(mobile['expires_at']))
        self.assertEqual(
            (datetime.fromisoformat(mobile['expires_at']) -
             datetime.fromisoformat(mobile['created_at'])).total_seconds(),
            300,
        )
        offered = self.rpc('driver_poll', uid=base.D)
        self.assertEqual(offered['offer']['order_id'], created['order_id'])
        self.assertIsNone(self.rpc('driver_poll', uid=base.N)['offer'])
        accepted = self.respond(offered['offer']['id'])
        self.assertEqual(accepted['order']['status'], 'accepted')
        self.assertEqual(self.rpc('passenger_poll')['order']['driver_id'], base.D)

    def test_only_authorized_admin_and_allowed_existing_passenger(self):
        for user in (base.B, base.D, base.X):
            claims = {
                'sub': user, 'session_id': base.SESSIONS[user], 'exp': 4102444800,
                'app_metadata': {'role': 'admin'}, 'user_metadata': {'role': 'admin'},
            }
            self.phone(actor=user, claims=claims, error='ORB_ADMIN_FORBIDDEN', sqlstate='42501')
        self.phone(role='anon', error='permission denied', sqlstate='42501')
        self.phone(
            actor=base.D, function='orbita_admin_private.create_phone_order',
            error='ORB_ADMIN_FORBIDDEN', sqlstate='42501',
        )
        self.phone(
            claims={'sub': base.A, 'session_id': base.SESSIONS[base.B], 'exp': 4102444800},
            error='ORB_ORDER_SESSION_REQUIRED', sqlstate='28000',
        )
        for target in (base.A, base.D, base.X, str(uuid.uuid4())):
            self.phone(passenger=target, error='ORB_ORDER_CREATE_FORBIDDEN', sqlstate='22023')
        self.action(base.B, 'block')
        self.phone(error='ORB_ORDER_CREATE_FORBIDDEN', sqlstate='22023')
        self.action(base.N, 'assign', 'admin')
        self.action(base.N, 'block', confirm=True)
        self.phone(actor=base.N, error='ORB_ADMIN_FORBIDDEN', sqlstate='42501')
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '0')
        self.assertEqual(self.admin('select count(*) from orbita_admin_private.operation_audit;'), '0')
        for role in ('anon', 'authenticated', 'service_role'):
            self.assertEqual(self.admin(
                f"select has_function_privilege('{role}', "
                "'orbita_mobile_private.order_create_for_passenger(uuid,uuid,jsonb,jsonb)', 'execute');"
            ), 'f')
        self.assertEqual(self.admin(
            "select has_function_privilege('service_role', "
            "'orbita_admin_api.create_phone_order(uuid,uuid,jsonb,jsonb)', 'execute');"
        ), 'f')

    def test_same_intent_replays_without_resetting_search_and_audits_once(self):
        request = str(uuid.uuid4())
        original = self.phone(request)
        normalized = {**base.PICKUP, 'address': '  Чик,  улица Учебная, 1  '}
        self.assertEqual(self.phone(request, pickup=normalized), original)
        self.phone(request, passenger=base.M, error='ORB_ORDER_IDEMPOTENCY_CONFLICT', sqlstate='23505')
        self.phone(request, pickup=base.DESTINATION, error='ORB_ORDER_IDEMPOTENCY_CONFLICT', sqlstate='23505')
        result, objects = self.client_raw('select orbita_admin_api.operations();', uid=base.A)
        self.assertEqual(result.returncode, 0, result.stderr)
        operations = next(row for row in objects if 'audit' in row)
        self.assertTrue(operations['phone_orders_enabled'])
        self.assertEqual(len(operations['audit']), 1)
        entry = operations['audit'][0]
        self.assertEqual((entry['actor_id'], entry['request_id'], entry['action'],
                          entry['target_id'], entry['details']),
                         (base.A, request, 'phone_order', original['order_id'], {}))
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '1')
        self.rpc('cancel', {'order_id': original['order_id']})
        self.assertEqual(self.phone(request), {**original, 'status': 'cancelled'})

    def test_bad_points_and_cross_operation_key_leave_no_order(self):
        self.phone(destination=base.PICKUP, error='ORB_ORDER_INVALID_REQUEST')
        self.phone(pickup={**base.PICKUP, 'latitude': '55'}, error='ORB_ORDER_INVALID_REQUEST')
        reserved = str(uuid.uuid4())
        restricted, _ = self.client_raw(
            f"select orbita_admin_api.set_driver_restriction('{reserved}', '{base.D}', true);",
            uid=base.A,
        )
        self.assertEqual(restricted.returncode, 0, restricted.stderr)
        self.phone(reserved, error='ORB_ORDER_IDEMPOTENCY_CONFLICT', sqlstate='23505')
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '0')
        self.assertEqual(self.admin('select count(*) from orbita_admin_private.operation_audit;'), '1')

    def test_concurrent_app_and_phone_orders_serialize_on_one_active_order(self):
        phone_request = str(uuid.uuid4())
        mobile_request = str(uuid.uuid4())
        jobs = (
            (base.A, self.statement_for_phone(phone_request)),
            (base.B, self.statement('create', {
                'request_id': mobile_request, 'pickup': base.PICKUP,
                'destination': base.DESTINATION,
            })),
        )
        barrier = threading.Barrier(2)

        def create(job):
            actor, query = job
            barrier.wait(timeout=5)
            return self.sql(query, uid=actor, role='authenticated', db=self.db)

        with ThreadPoolExecutor(max_workers=2) as executor:
            phone, mobile = executor.map(create, jobs)
        self.assertEqual(sum(result.returncode == 0 for result in (phone, mobile)), 1)
        failure = phone if phone.returncode else mobile
        self.assertIn('ORB_ORDER_ACTIVE_EXISTS', failure.stderr)
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '1')
        self.assertEqual(self.admin('select count(*) from orbita_admin_private.operation_audit;'),
                         '1' if phone.returncode == 0 else '0')

    def test_accepted_trip_blocks_new_phone_order_without_touching_it(self):
        self.online()
        first = self.phone()
        self.respond(self.offer())
        order_id = first['order_id']
        self.phone(error='ORB_ORDER_ACTIVE_EXISTS', sqlstate='23505')
        self.assertEqual(self.rpc('driver_poll', uid=base.D)['order']['id'], order_id)
        self.assertEqual(self.rpc('passenger_poll')['order']['status'], 'accepted')
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'), '1')

    def test_original_mobile_v1_replay_and_v2_read_keep_their_contracts(self):
        request = str(uuid.uuid4())
        result, objects = self.client_raw(base.create_sql(request))
        self.assertEqual(result.returncode, 0, result.stderr)
        v1 = next(row for row in objects if row.get('contract_version') == 1)
        self.assertEqual(set(v1), {'contract_version', 'server_time', 'order'})
        self.assertEqual(self.rpc('passenger_poll')['order']['request_id'], request)
        self.action(base.B, 'revoke')
        retried, objects = self.client_raw(base.create_sql(request))
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertEqual(next(row for row in objects if row.get('contract_version') == 1)['order'],
                         v1['order'])
        denied, _ = self.client_raw(base.create_sql(str(uuid.uuid4())))
        self.assertNotEqual(denied.returncode, 0)
        self.assertIn('42501: ORB_ORDER_CREATE_FORBIDDEN', denied.stderr)
