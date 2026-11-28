"""Participant-scoped terminal trips on a disposable PostgreSQL server."""

import unittest

try:
    from . import test_dispatch_sql as dispatch
    from . import test_orders_sql as base
except ImportError:
    import test_dispatch_sql as dispatch
    import test_orders_sql as base


class TripHistoryTests(unittest.TestCase):
    records = []
    for method in ('setUpClass', 'stop_server', 'sql', 'owner', 'tearDown',
                   'admin', 'action_sql', 'action', 'client_raw', 'expire'):
        locals()[method] = base.OrdersSQLTests.__dict__[method]
    for method in ('statement', 'rpc', 'create', 'online', 'offer', 'respond'):
        locals()[method] = dispatch.DispatchSQLTests.__dict__[method]

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()

    def setUp(self):
        dispatch.DispatchSQLTests.setUp(self)
        proposal = base.ROOT / 'supabase/proposals/orbita_trip_history.sql'
        self.admin('begin;\n' + proposal.read_text() + '\ncommit;')

    def page(self, uid, role, cursor=None, error=None, db_role='authenticated'):
        cursor_sql = '' if cursor is None else ', ' + ', '.join(map(base.literal, cursor))
        result, values = self.client_raw(
            f'select public.orbita_order_history({base.literal(role)}{cursor_sql});',
            uid=uid, role=db_role,
        )
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        value = next(item for item in values if 'items' in item)
        self.assertEqual((value['user_id'], value['role']), (uid, role))
        return value

    def test_trip_is_visible_to_its_participants_after_completion(self):
        self.online()
        order = self.create()['order']
        self.respond(self.offer())
        self.assertEqual(self.page(base.B, 'passenger')['items'], [])
        self.assertEqual(self.page(base.D, 'driver')['items'], [])
        for status in ('to_pickup', 'arrived', 'riding', 'completed'):
            self.rpc('advance', {'order_id': order['id'], 'status': status}, uid=base.D)
        passenger = self.page(base.B, 'passenger')['items']
        self.assertEqual(passenger, self.page(base.D, 'driver')['items'])
        self.assertEqual([item['id'] for item in passenger], [order['id']])
        self.assertEqual(set(passenger[0]), {
            'id', 'status', 'created_at', 'finished_at', 'pickup_address', 'destination_address',
        })
        self.assertEqual(self.page(base.M, 'passenger')['items'], [])
        self.assertEqual(self.page(base.N, 'driver')['items'], [])

    def test_cancelled_history_and_bounded_cursor_have_no_gaps(self):
        ids = []
        for _ in range(31):
            order = self.create()['order']
            ids.append(order['id'])
            self.rpc('cancel', {'order_id': order['id']})
        first = self.page(base.B, 'passenger')
        self.assertTrue(first['has_more'])
        self.assertEqual(len(first['items']), 30)
        self.assertTrue(all(row['status'] == 'cancelled' for row in first['items']))
        last = first['items'][-1]
        second = self.page(base.B, 'passenger', (last['created_at'], last['id']))
        self.assertFalse(second['has_more'])
        self.assertEqual([row['id'] for row in first['items'] + second['items']], ids[::-1])
        self.assertEqual(self.page(base.D, 'driver')['items'], [])

    def test_access_is_rechecked_and_table_grants_stay_closed(self):
        self.page(base.B, 'driver', error='ORB_DISPATCH_FORBIDDEN')
        self.page(base.D, 'driver', error='permission denied', db_role='anon')
        self.assertEqual(self.admin(
            "select has_function_privilege('service_role', "
            "'public.orbita_order_history(text,timestamptz,uuid)', 'EXECUTE');"), 'f')
        self.page(base.B, 'passenger', ('infinity', base.D), error='ORB_DISPATCH_INVALID')
        self.assertEqual(self.admin(
            "select has_table_privilege('authenticated', 'public.orbita_orders', 'select');"), 'f')
        self.action(base.D, 'block')
        self.page(base.D, 'driver', error='ORB_DISPATCH_FORBIDDEN')
        self.admin(f"delete from auth.sessions where user_id='{base.B}';")
        self.page(base.B, 'passenger', error='ORB_ORDER_SESSION_REQUIRED')
