"""Vehicle approval and active order peer projection on local PostgreSQL."""

import unittest

try:
    from . import test_dispatch_sql as dispatch
    from . import test_orders_sql as base
except ImportError:
    import test_dispatch_sql as dispatch
    import test_orders_sql as base


class TripPeopleTests(unittest.TestCase):
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
        proposal = base.ROOT / 'supabase/proposals/orbita_trip_people.sql'
        self.admin('begin;\n' + proposal.read_text() + '\ncommit;')

    def read(self, uid, query, error=None, role='authenticated'):
        result, rows = self.client_raw(query, uid=uid, role=role)
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        return rows[-1]

    def test_vehicle_admin_and_order_peer_permissions(self):
        vehicle = dict(make='Тест', model='Модель', color='Серый', plate='A 123 BB')
        edit = f"select public.orbita_admin_set_vehicle('{base.D}',{base.point_sql(vehicle)});"
        self.read(base.D, edit, 'ORB_DISPATCH_FORBIDDEN')
        self.read(base.B, edit, 'ORB_DISPATCH_FORBIDDEN')
        self.read(base.A, edit)
        self.assertEqual(self.read(base.D, 'select public.orbita_my_vehicle();')['vehicle'], vehicle)
        self.read(base.B, 'select public.orbita_my_vehicle();', 'ORB_DISPATCH_FORBIDDEN')
        self.read(base.D, "select * from orbita_trip_people_private.vehicles;", 'permission denied')
        self.online()
        order = self.create()['order']
        status = f"select public.orbita_trip_peer('{order['id']}');"
        self.read(base.B, status, 'ORB_DISPATCH_NOT_FOUND')
        self.respond(self.offer())
        passenger = self.read(base.B, status)
        self.assertEqual(passenger['vehicle'], vehicle)
        self.assertEqual(set(passenger), {'order_id','display_name','vehicle'})
        self.assertIsNone(self.read(base.D, status)['vehicle'])
        self.read(base.N, status, 'ORB_DISPATCH_NOT_FOUND')
        self.read(base.B, status, 'permission denied', role='anon')
        for action in ('to_pickup','arrived','riding','completed'):
            self.rpc('advance', {'order_id':order['id'],'status':action},uid=base.D)
        self.read(base.B, status, 'ORB_DISPATCH_NOT_FOUND')

    def test_revoked_session_and_admin_remove(self):
        vehicle = dict(make='Тест', model='Модель', color='Серый', plate='A 123 BB')
        self.read(base.A, f"select public.orbita_admin_set_vehicle('{base.D}',{base.point_sql(vehicle)});")
        self.read(base.A, f"select public.orbita_admin_set_vehicle('{base.D}',null);")
        self.assertIsNone(self.read(base.D, 'select public.orbita_my_vehicle();')['vehicle'])
        self.admin(f"delete from auth.sessions where user_id='{base.A}';")
        self.read(base.A, f"select public.orbita_admin_set_vehicle('{base.D}',null);", 'ORB_ORDER_SESSION_REQUIRED')
