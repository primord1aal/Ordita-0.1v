"""Real PostgreSQL 17.11, private Unix socket, synthetic identities only.
JWT signatures / hosted Auth / PostgREST are NOT simulated as integration results.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import threading
import unittest
import uuid
try:
    from . import test_orders_sql as base
except ImportError:
    import test_orders_sql as base

B, D, N, M = base.B, base.D, base.N, base.M
MIGRATION = base.ROOT / 'supabase/proposals/20261120160748_taxi_dispatch.sql'


class DispatchSQLTests(unittest.TestCase):
    records = []
    for _name in ('setUpClass', 'stop_server', 'sql', 'owner',
                  'tearDown', 'admin', 'action_sql', 'action', 'client_raw', 'expire'):
        locals()[_name] = base.OrdersSQLTests.__dict__[_name]

    @classmethod
    def tearDownClass(cls):
        try:
            output = base.ROOT / 'build/dispatch-sql-results.json'
            output.parent.mkdir(exist_ok=True)
            output.write_text(json.dumps({
                'environment': cls.server_version,
                'transport': 'Private Unix socket, no TCP',
                'limitation': 'Synthetic JWT GUCs; no JWT signature / Auth HTTP / PostgREST / cloud test',
                'records': cls.records,
            }, ensure_ascii=False, indent=2) + '\n')
        finally:
            cls.stop_server()

    def setUp(self):
        base.OrdersSQLTests.setUp(self)
        self.admin('begin;\n' + MIGRATION.read_text() + '\ncommit;')
        self.action(N, 'assign', 'driver')

    def statement(self, action, payload=None):
        return f"select public.orbita_dispatch({base.literal(action)},{base.point_sql(payload or {})});"

    def rpc(self, action, payload=None, uid=B, error=None, role='authenticated'):
        result, objects = self.client_raw(self.statement(action, payload), uid=uid, role=role)
        if error:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        value = next(x for x in reversed(objects) if x.get('contract_version') == 2)
        self.assertEqual(value['user_id'], uid)
        self.events.append({'action': action, 'status': value['order']['status'] if value['order'] else None})
        return value

    def create(self, uid=B, request=None):
        return self.rpc('create', {'request_id': request or str(uuid.uuid4()),
          'pickup': base.PICKUP, 'destination': base.DESTINATION}, uid=uid)

    def online(self, driver=D):
        return self.rpc('online', {'online': True}, uid=driver)

    def offer(self, driver=D):
        return self.rpc('driver_poll', uid=driver)['offer']['id']

    def respond(self, offer, driver=D, response='accept'):
        return self.rpc('respond', {'offer_id': offer, 'response': response}, uid=driver)

    def queue(self, driver=D):
        return self.admin(f"select queue_position from orbita_mobile_private.dispatch_drivers where driver_id='{driver}';")

    def parallel(self, *operations):
        barrier = threading.Barrier(len(operations))
        def run(item):
            uid, action, payload = item
            barrier.wait()
            return self.sql(self.statement(action,payload),role='authenticated',uid=uid,db=self.db)
        with ThreadPoolExecutor(max_workers=len(operations)) as pool:
            return list(pool.map(run,operations))

    def test_full_trip_and_restart_recovery(self):
        self.online()
        order = self.create()['order']
        offer = self.offer()
        accepted = self.respond(offer)
        self.assertEqual(accepted['order']['status'], 'accepted')
        # Each RPC is a new physical DB connection: no client memory required.
        self.assertEqual(self.rpc('passenger_poll')['order']['driver_id'], D)
        self.assertEqual(self.rpc('driver_poll',uid=D)['order']['id'], order['id'])
        for status in ('to_pickup','arrived','riding','completed'):
            self.rpc('advance', {'order_id':order['id'],'status':status},uid=D)
            self.assertEqual(self.rpc('passenger_poll')['order']['status'], status)
        self.assertIsNotNone(self.rpc('driver_poll',uid=D)['order']['completed_at'])
        self.create(uid=M)
        self.assertIsNotNone(self.rpc('driver_poll',uid=D)['offer'])

    def test_decline_moves_once_and_assigns_next(self):
        self.online(); self.online(N); self.create()
        offer = self.offer(); before = self.queue()
        self.respond(offer,response='decline')
        after = self.queue()
        self.assertGreater(int(after),int(before))
        self.respond(offer,response='decline')
        self.assertEqual(after,self.queue())
        self.assertIsNotNone(self.rpc('driver_poll',uid=N)['offer'])
        self.assertIsNone(self.rpc('driver_poll',uid=D)['offer'])

    def test_offer_expiry_server_enforced(self):
        self.online(); self.online(N); self.create(); offer = self.offer()
        self.admin(f"update orbita_mobile_private.dispatch_offers set created_at=created_at-interval '26 seconds',expires_at=expires_at-interval '26 seconds' where id='{offer}';")
        self.respond(offer)
        self.assertIsNotNone(self.rpc('driver_poll',uid=N)['offer'])
        self.assertEqual(self.rpc('passenger_poll')['order']['status'],'created')
        self.assertGreater(int(self.queue()),int(self.queue(N)))

    def test_search_expiry_without_reset_on_retry(self):
        self.online(); request = str(uuid.uuid4()); order = self.create(request=request)['order']
        self.expire(order['id'])
        expired = self.create(request=request)['order']
        self.assertEqual(expired['status'],'cancelled')
        self.assertEqual(expired['cancellation_reason'],'search_timeout')
        self.assertIsNone(self.rpc('driver_poll',uid=D)['offer'])
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'),'1')

    def test_duplicate_create_concurrent_and_network_retry(self):
        payload = {'request_id':str(uuid.uuid4()),'pickup':base.PICKUP,'destination':base.DESTINATION}
        results = self.parallel((B,'create',payload),(B,'create',payload))
        self.assertTrue(all(x.returncode == 0 for x in results), [x.stderr for x in results])
        self.rpc('create',payload)
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'),'1')

    def test_only_one_active_passenger_even_old_v1_client(self):
        self.online(); self.create(); self.respond(self.offer())
        self.rpc('create',{'request_id':str(uuid.uuid4()),'pickup':base.PICKUP,'destination':base.DESTINATION},error='ORB_ORDER_ACTIVE_EXISTS')
        result,_ = self.client_raw(base.create_sql(str(uuid.uuid4())))
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.admin('select count(*) from public.orbita_orders;'),'1')

    def test_two_drivers_cannot_accept_same_offer(self):
        self.online(); self.online(N); order=self.create()['order']; offer=self.offer()
        results=self.parallel((D,'respond',{'offer_id':offer,'response':'accept'}),
                              (N,'respond',{'offer_id':offer,'response':'accept'}))
        self.assertEqual(sorted(x.returncode == 0 for x in results),[False,True])
        self.assertEqual(self.rpc('passenger_poll')['order']['driver_id'],D)
        self.assertEqual(self.admin(f"select count(*) from public.orbita_orders where id='{order['id']}' and status='accepted';"),'1')

    def test_accept_cancel_race(self):
        self.online(); order=self.create()['order']; offer=self.offer()
        self.parallel((D,'respond',{'offer_id':offer,'response':'accept'}),(B,'cancel',{'order_id':order['id']}))
        result=self.rpc('passenger_poll')['order']
        self.assertIn(result['status'],('accepted','cancelled'))
        self.assertEqual(result['driver_id'] is None,result['status']=='cancelled')
        self.assertEqual(self.admin("select count(*) from orbita_mobile_private.dispatch_offers where status='pending';"),'0')

    def test_cancel_preserves_driver_position(self):
        self.online(); self.online(N); order=self.create()['order']; before=self.queue()
        self.rpc('cancel',{'order_id':order['id']})
        self.assertEqual(before,self.queue())
        self.assertIsNone(self.rpc('driver_poll',uid=D)['offer'])

    def test_busy_driver_excluded_and_status_replay(self):
        self.online(); self.online(N); order=self.create()['order']; offer=self.offer()
        self.respond(offer); position=self.queue(); self.respond(offer)
        self.assertEqual(position,self.queue())
        self.create(uid=M)
        self.assertIsNone(self.rpc('driver_poll',uid=D)['offer'])
        self.assertIsNotNone(self.rpc('driver_poll',uid=N)['offer'])
        payload={'order_id':order['id'],'status':'to_pickup'}
        self.rpc('advance',payload,uid=D)
        version=self.rpc('advance',payload,uid=D)['order']['version']
        self.assertEqual(version,3)
        self.rpc('advance',{'order_id':order['id'],'status':'completed'},uid=D,error='ORB_ORDER_STATE_CHANGED')

    def test_foreign_operations_and_roles(self):
        self.online(); order=self.create()['order']; offer=self.offer()
        self.rpc('cancel',{'order_id':order['id']},uid=M,error='ORB_ORDER_NOT_FOUND')
        self.rpc('respond',{'offer_id':offer,'response':'accept'},uid=B,error='ORB_DISPATCH_FORBIDDEN')
        self.respond(offer)
        self.rpc('advance',{'order_id':order['id'],'status':'to_pickup'},uid=N,error='ORB_DISPATCH_NOT_FOUND')
        self.assertIsNone(self.rpc('passenger_poll',uid=M)['order'])
        self.assertIsNone(self.rpc('driver_poll',uid=N)['order'])
        self.rpc('driver_poll',uid=D,role='anon',error='permission denied')
        for table in ('public.orbita_orders','orbita_mobile_private.dispatch_drivers','orbita_mobile_private.dispatch_offers'):
            result,_=self.client_raw(f'select * from {table};',uid=D)
            self.assertNotEqual(result.returncode,0)

    def test_revoked_access_and_session(self):
        self.online(); self.online(N); self.create(); offer=self.offer()
        self.action(D,'block')
        self.rpc('respond',{'offer_id':offer,'response':'accept'},uid=D,error='ORB_DISPATCH_FORBIDDEN')
        self.rpc('passenger_poll')
        self.assertIsNotNone(self.rpc('driver_poll',uid=N)['offer'])
        self.admin(f"delete from auth.sessions where user_id='{N}';")
        self.rpc('driver_poll',uid=N,error='ORB_ORDER_SESSION_REQUIRED')

    def test_stale_heartbeat_goes_offline_and_return_moves_once(self):
        self.online(); before=self.queue()
        self.admin(f"update orbita_mobile_private.dispatch_drivers set heartbeat_at=clock_timestamp()-interval '16 seconds' where driver_id='{D}';")
        self.assertFalse(self.rpc('driver_poll',uid=D)['online'])
        self.create(); self.assertIsNone(self.rpc('driver_poll',uid=D)['offer'])
        self.online(); after=self.queue(); self.assertGreater(int(after),int(before))
        self.online(); self.assertEqual(after,self.queue())
        self.assertIsNotNone(self.rpc('driver_poll',uid=D)['offer'])

    def test_concurrent_orders_have_distinct_drivers(self):
        self.online(); self.online(N)
        p=lambda: {'request_id':str(uuid.uuid4()),'pickup':base.PICKUP,'destination':base.DESTINATION}
        results=self.parallel((B,'create',p()),(M,'create',p()))
        self.assertTrue(all(r.returncode==0 for r in results))
        self.assertEqual(self.admin("select count(distinct driver_id)=2 and count(distinct order_id)=2 from orbita_mobile_private.dispatch_offers where status='pending';"),'t')

    def test_private_helpers_cannot_be_called(self):
        for statement in ("select orbita_mobile_private.dispatch_tick();",
          f"select orbita_mobile_private.dispatch_snapshot('{B}','passenger','ok');",
          f"select orbita_mobile_private.dispatch_allowed('{B}','passenger');"):
            result,_=self.client_raw(statement)
            self.assertNotEqual(result.returncode,0)
