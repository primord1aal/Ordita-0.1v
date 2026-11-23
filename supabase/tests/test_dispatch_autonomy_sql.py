"""Disposable PostgreSQL, artificial clocks/identities and no cron extension."""

import select
import subprocess
import unittest

try:
    from . import test_dispatch_sql as dispatch
except ImportError:
    import test_dispatch_sql as dispatch


PROPOSALS = dispatch.base.ROOT / 'supabase/proposals'
SCHEDULED_TICK = 'select orbita_mobile_private.dispatch_scheduled_tick();'


class DispatchAutonomyTests(unittest.TestCase):
    records = []

    for _name in (
        'setUpClass', 'stop_server', 'sql', 'owner', 'tearDown', 'admin',
        'action_sql', 'action', 'client_raw', 'expire', 'statement', 'rpc',
        'create', 'online', 'offer', 'queue',
    ):
        locals()[_name] = dispatch.DispatchSQLTests.__dict__[_name]

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()

    def setUp(self):
        dispatch.DispatchSQLTests.setUp(self)
        self.admin('begin;\n' + (PROPOSALS / '20261120173504_managed_maps.sql').read_text() + '\ncommit;')
        self.admin('begin;\n' + (PROPOSALS / 'orbita_dispatch_autonomy.sql').read_text() + '\ncommit;')

    def test_idle_tick_does_not_advance_access_mutex_or_expose_runner(self):
        revision = 'select revision from orbita_mobile_private.access_mutex where singleton;'
        before = self.admin(revision)
        self.assertEqual(self.admin(SCHEDULED_TICK), 'f')
        self.assertEqual(self.admin(revision), before)
        for role in ('anon', 'authenticated', 'service_role'):
            self.assertEqual(self.admin(
                f"select has_function_privilege('{role}',"
                " 'orbita_mobile_private.dispatch_scheduled_tick()', 'EXECUTE');"
            ), 'f')

    def test_order_deadline_expires_without_any_client_rpc(self):
        order = self.create()['order']['id']
        self.expire(order)
        self.assertEqual(self.admin(SCHEDULED_TICK), 't')
        self.assertEqual(self.admin(
            f"select status,cancellation_reason,cancelled_at=expires_at from public.orbita_orders where id='{order}';"
        ), 'cancelled|search_timeout|t')
        self.assertEqual(self.admin(SCHEDULED_TICK), 'f')

    def test_offer_expires_and_moves_to_next_driver_without_client_rpc(self):
        self.online()
        self.online(dispatch.N)
        order = self.create()['order']['id']
        offer = self.offer()
        before = int(self.queue())
        self.admin(f"""
          update orbita_mobile_private.dispatch_offers
          set created_at=created_at-interval '26 seconds', expires_at=expires_at-interval '26 seconds'
          where id='{offer}';
        """)
        self.assertEqual(self.admin(SCHEDULED_TICK), 't')
        after = int(self.queue())
        self.assertGreater(after, before)
        self.assertEqual(self.admin(
            f"select driver_id from orbita_mobile_private.dispatch_offers where order_id='{order}' and status='pending';"
        ), dispatch.N)
        self.assertEqual(self.admin(SCHEDULED_TICK), 't')
        self.assertEqual(int(self.queue()), after)

    def test_busy_access_mutex_is_skipped_then_expiry_resumes(self):
        order = self.create()['order']['id']
        self.expire(order)
        with subprocess.Popen([
            str(self.bin / 'psql'), '-X', '-Atq', '-v', 'ON_ERROR_STOP=1',
            '-h', str(self.socket), '-p', '55432', '-U', 'postgres', '-d', self.db,
        ], env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True) as blocker:
            try:
                blocker.stdin.write("begin; select 'held' from orbita_mobile_private.access_mutex where singleton for update;\n")
                blocker.stdin.flush()
                self.assertTrue(select.select([blocker.stdout], [], [], 5)[0], 'Lock holder did not answer')
                self.assertEqual(blocker.stdout.readline().strip(), 'held')
                self.assertEqual(self.admin("set statement_timeout='1s'; " + SCHEDULED_TICK), 'f')
                self.assertEqual(self.admin(f"select status from public.orbita_orders where id='{order}';"), 'created')
            finally:
                try:
                    blocker.communicate('rollback;\n', timeout=5)
                except subprocess.TimeoutExpired:
                    blocker.kill()
                    blocker.communicate()
        self.assertEqual(self.admin(SCHEDULED_TICK), 't')
        self.assertEqual(self.admin(f"select status from public.orbita_orders where id='{order}';"), 'cancelled')
