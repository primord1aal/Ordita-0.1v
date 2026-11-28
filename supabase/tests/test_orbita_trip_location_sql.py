"""Check location ownership and lifetimes in isolated PostgreSQL."""

import unittest
from datetime import datetime, timedelta, timezone

try:
    from . import test_dispatch_sql as dispatch
    from . import test_orders_sql as base
except ImportError:
    import test_dispatch_sql as dispatch
    import test_orders_sql as base


class TripLocationTests(unittest.TestCase):
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
        proposal = base.ROOT / 'supabase/proposals/orbita_trip_location.sql'
        self.admin('begin;\n' + proposal.read_text() + '\ncommit;')
        self.online()
        self.order = self.create()['order']['id']

    def exchange(self, uid, fix=None, *, error=None, role='authenticated'):
        data = '' if fix is None else ', ' + base.point_sql(fix)
        result, rows = self.client_raw(
            f"select public.orbita_trip_location('{self.order}'{data});", uid=uid, role=role,
        )
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        return next(row for row in rows if row.get('order_id') == self.order)

    def fix(self, age=0, lat=55.006):
        return dict(latitude=lat, longitude=82.43, accuracy_meters=10,
                    captured_at=(datetime.now(timezone.utc) - timedelta(seconds=age)).isoformat())

    def test_position_scoped_to_assigned_participants_and_removed_on_finish(self):
        self.exchange(base.D, self.fix(), error='ORB_DISPATCH_NOT_FOUND')
        self.respond(self.offer())
        self.assertIsNone(self.exchange(base.B)['fix'])
        self.exchange(base.N, self.fix(), error='ORB_DISPATCH_NOT_FOUND')
        self.exchange(base.B, self.fix(), error='ORB_DISPATCH_FORBIDDEN')
        self.exchange(base.M, error='ORB_DISPATCH_NOT_FOUND')
        self.exchange(base.B, error='permission denied', role='anon')
        self.assertTrue(self.exchange(base.D, self.fix())['accepted'])
        self.assertEqual(self.exchange(base.B)['fix']['latitude'], 55.006)
        self.exchange(base.D, self.fix(age=5, lat=56))
        self.assertEqual(self.exchange(base.B)['fix']['latitude'], 55.006)
        for status in ('to_pickup','arrived','riding','completed'):
            self.rpc('advance', {'order_id':self.order,'status':status},uid=base.D)
        self.exchange(base.B, error='ORB_DISPATCH_NOT_FOUND')
        self.exchange(base.D, self.fix(), error='ORB_DISPATCH_NOT_FOUND')
        self.assertEqual(self.admin('select count(*) from orbita_trip_location_private.latest;'), '0')

    def test_stale_fixes_and_driver_revocation(self):
        self.respond(self.offer())
        self.exchange(base.D, self.fix(age=31), error='ORB_DISPATCH_INVALID')
        self.exchange(base.D, self.fix())
        self.admin("update orbita_trip_location_private.latest set captured_at=clock_timestamp()-interval '121 seconds';")
        self.assertIsNone(self.exchange(base.B)['fix'])
        self.admin(f"delete from auth.sessions where user_id='{base.B}';")
        self.exchange(base.B, error='ORB_ORDER_SESSION_REQUIRED')
        self.action(base.D,'block')
        self.exchange(base.D, self.fix(), error='ORB_DISPATCH_FORBIDDEN')
