"""Local PostgreSQL 17.11 with Unix sockets and synthetic session claims."""

import unittest
import uuid

try:
    from . import test_orders_sql as base
except ImportError:
    import test_orders_sql as base


PROPOSALS = base.ROOT / 'supabase/proposals'
ACTIVE_SQL = 'select orbita_admin_api.snapshot();'


class OrbitaAdminReadTests(unittest.TestCase):
    records = []

    for name in ('setUpClass', 'stop_server', 'sql', 'owner', 'tearDown',
                 'admin', 'action_sql', 'action', 'client_raw'):
        locals()[name] = base.OrdersSQLTests.__dict__[name]

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()

    def setUp(self):
        base.OrdersSQLTests.setUp(self)
        for file in ('20261120160748_taxi_dispatch.sql', 'orbita_admin_read_model.sql'):
            self.admin('begin;\n' + (PROPOSALS / file).read_text() + '\ncommit;')

    def read_as(self, uid=base.A, statement=ACTIVE_SQL, **options):
        process, objects = self.client_raw(statement, uid=uid, **options)
        self.assertEqual(process.returncode, 0, process.stderr)
        return next(record for record in objects if record.get('contract_version') == 1)

    def deny(self, uid, message, statement=ACTIVE_SQL, **options):
        process, objects = self.client_raw(statement, uid=uid, **options)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn(message, process.stderr)
        self.assertFalse(any('active_orders' in record for record in objects))

    def dispatch(self, action, uid, payload):
        process, objects = self.client_raw(
            f"select public.orbita_dispatch({base.literal(action)}, {base.point_sql(payload)});",
            uid=uid,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        return next(record for record in objects if record.get('contract_version') == 2)

    def create_order(self, uid):
        return self.dispatch('create', uid, {
            'request_id': str(uuid.uuid4()),
            'pickup': base.PICKUP,
            'destination': base.DESTINATION,
        })['order']

    def test_snapshot_requires_real_admin_role_even_when_helper_called_directly(self):
        admin = self.read_as()
        self.assertEqual(admin['active_orders'], [])
        self.assertEqual(admin['history'], [])
        self.assertEqual(admin['queue'], [])
        self.assertEqual(self.read_as(statement='select orbita_admin_private.snapshot();')['history'], [])
        for user in (base.B, base.D, base.N, base.X):
            with self.subTest(user=user):
                self.deny(user, 'ORB_ADMIN_FORBIDDEN')
                self.deny(
                    user, 'ORB_ADMIN_FORBIDDEN',
                    statement='select orbita_admin_private.snapshot();',
                    claims={'sub': user, 'session_id': base.SESSIONS[user], 'exp': 4102444800,
                            'app_metadata': {'role': 'admin'}, 'user_metadata': {'role': 'admin'}},
                )
        for namespace in ('orbita_admin_api', 'orbita_admin_private'):
            self.deny(base.A, 'permission denied for schema', role='anon',
                      statement=f'select {namespace}.snapshot();')
            self.assertEqual(self.admin(
                f"select has_schema_privilege('service_role', '{namespace}', 'USAGE');"), 'f')
            self.assertEqual(self.admin(
                f"select has_function_privilege('service_role', '{namespace}.snapshot()', 'EXECUTE');"), 'f')
        for table in ('public.orbita_orders', 'orbita_mobile_private.dispatch_drivers',
                      'orbita_mobile_private.dispatch_offers'):
            self.deny(base.A, 'permission denied', statement=f'select * from {table};')

    def test_revoked_session_and_blocked_admin_cannot_read(self):
        self.action(base.N, 'assign', 'admin')
        self.read_as(base.N)
        self.action(base.N, 'block', confirm=True)
        self.deny(base.N, 'ORB_ADMIN_FORBIDDEN')
        self.action(base.N, 'unblock')
        self.admin(f"delete from auth.sessions where user_id='{base.N}';")
        self.deny(base.N, 'ORB_ORDER_SESSION_REQUIRED')
        self.read_as()

    def test_active_projection_and_queue_follow_dispatch_without_writing(self):
        self.action(base.N, 'assign', 'driver')
        self.dispatch('online', base.D, {'online': True})
        self.dispatch('online', base.N, {'online': True})
        self.assertEqual(
            [(row['driver_id'], row['queue_rank']) for row in self.read_as()['queue']],
            [(base.D, 1), (base.N, 2)],
        )
        trip = self.create_order(base.B)
        self.assertEqual(
            [(row['driver_id'], row['queue_rank']) for row in self.read_as()['queue']],
            [(base.D, None), (base.N, 1)],
        )
        offer_id = self.dispatch('driver_poll', base.D, {})['offer']['id']
        self.dispatch('respond', base.D, {'offer_id': offer_id, 'response': 'accept'})
        search = self.create_order(base.M)
        self.admin(f"""
          update orbita_mobile_private.dispatch_offers
          set created_at=created_at-interval '26 seconds', expires_at=expires_at-interval '26 seconds'
          where order_id='{search['id']}' and status='pending';
        """)
        snapshot = self.read_as(statement='begin read only; ' + ACTIVE_SQL + ' rollback;')
        orders = snapshot['active_orders']
        queue = snapshot['queue']
        self.assertEqual([(r['id'], r['status']) for r in orders],
                         [(trip['id'], 'accepted'), (search['id'], 'created')])
        self.assertEqual(set(orders[0]), {
            'id', 'status', 'created_at', 'expires_at',
            'driver_id', 'pickup_address', 'destination_address'})
        self.assertEqual(orders[0]['pickup_address'], base.PICKUP['address'])
        self.assertEqual([(r['driver_id'], r['state'], r['order_id']) for r in queue],
                         [(base.N, 'updating', search['id']), (base.D, 'busy', trip['id'])])
        self.assertEqual([row['queue_rank'] for row in queue], [None, None])
        self.assertEqual(self.admin(
            f"select status from orbita_mobile_private.dispatch_offers where order_id='{search['id']}';"),
            'pending')

    def test_recent_history_is_bounded_and_maps_real_cancellation(self):
        trip = self.create_order(base.B)
        self.dispatch('cancel', base.B, {'order_id': trip['id']})
        history = self.read_as()['history']
        self.assertEqual([(row['id'], row['status'], row['cancellation_reason']) for row in history],
                         [(trip['id'], 'cancelled', 'passenger')])
        self.assertEqual(set(history[0]), {'id', 'status', 'finished_at', 'cancellation_reason'})
        self.admin(f"""
          insert into public.orbita_orders (passenger_id, request_id, pickup, destination,
            status, cancellation_reason, created_at, expires_at, cancelled_at, version)
          select '{base.B}', gen_random_uuid(), {base.point_sql(base.PICKUP)},
            {base.point_sql(base.DESTINATION)}, 'cancelled', 'search_timeout',
            t - interval '5 minutes', t, t, 2
          from (select now()-n*interval '1 minute' as t from generate_series(1,52) n) v;
        """)
        snapshot = self.read_as()
        self.assertEqual(len(snapshot['history']), 50)
        self.assertEqual(snapshot['history'][0]['id'], trip['id'])
        self.assertEqual(snapshot['history'][1]['cancellation_reason'], 'search_timeout')
        self.assertEqual(snapshot['truncated'], {'active_orders': False, 'queue': False, 'history': True})
