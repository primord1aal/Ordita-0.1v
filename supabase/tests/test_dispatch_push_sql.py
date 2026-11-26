"""Outbox rehearsal on disposable PostgreSQL; provider and hosted Auth excluded."""

from concurrent.futures import ThreadPoolExecutor
import json
import threading
import unittest
import uuid

try:
    from . import test_dispatch_sql as dispatch
except ImportError:
    import test_dispatch_sql as dispatch


PROPOSALS = dispatch.base.ROOT / 'supabase/proposals'
OUTBOX = 'orbita_mobile_private.driver_offer_push'
CLAIM = 'orbita_mobile_private.claim_driver_offer_push'
FINISH = 'orbita_mobile_private.finish_driver_offer_push'
CLAIM_QUERY = f'select row_to_json(claim) from {CLAIM}(20) claim;'


class DispatchPushTests(unittest.TestCase):
    records = []

    for _name in (
        'setUpClass', 'stop_server', 'sql', 'owner', 'tearDown', 'admin',
        'action_sql', 'action', 'client_raw', 'statement', 'rpc',
        'create', 'online', 'offer', 'respond',
    ):
        locals()[_name] = dispatch.DispatchSQLTests.__dict__[_name]

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()

    def setUp(self):
        dispatch.DispatchSQLTests.setUp(self)
        for name in ('20261120173504_managed_maps.sql', 'orbita_dispatch_push.sql'):
            self.admin('begin;\n' + (PROPOSALS / name).read_text() + '\ncommit;')

    def claim(self):
        return [json.loads(line) for line in self.admin(CLAIM_QUERY).splitlines()]

    def finish(self, claim, result='provider_accepted'):
        return self.admin(
            f"select {FINISH}('{claim['event_id']}', '{claim['lease_id']}', '{result}');"
        )

    def test_enqueue_commits_with_offer_and_replay_preserves_one_event(self):
        self.online()
        intent = {
            'request_id': str(uuid.uuid4()),
            'pickup': dispatch.base.PICKUP,
            'destination': dispatch.base.DESTINATION,
        }
        result, _ = self.client_raw('begin; ' + self.statement('create', intent) + ' rollback;')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.admin(f'select count(*) from {OUTBOX};'), '0')
        self.assertIsNone(self.rpc('passenger_poll')['order'])

        self.rpc('create', intent)
        offer = self.rpc('driver_poll', uid=dispatch.D)['offer']
        self.rpc('create', intent)
        self.assertEqual(self.admin(f'select event_id from {OUTBOX};'), offer['id'])

        event, = self.claim()
        self.assertEqual(set(event), {'event_id', 'recipient_id', 'lease_id', 'expires_at'})
        self.assertEqual(event['event_id'], offer['id'])
        self.assertEqual(event['recipient_id'], dispatch.D)
        self.assertEqual(event['expires_at'], offer['expires_at'])

    def test_concurrent_workers_do_not_share_a_lease(self):
        self.online()
        self.create()
        barrier = threading.Barrier(2)

        def collect():
            barrier.wait(timeout=5)
            return self.claim()

        with ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [pool.submit(collect) for _ in range(2)]
            claims = [job.result(timeout=10) for job in jobs]
        self.assertEqual(sorted(map(len, claims)), [0, 1])
        active, = (claim for result in claims for claim in result)
        self.assertEqual(self.finish({**active, 'lease_id': str(uuid.uuid4())}), 'f')
        self.assertEqual(self.finish(active), 't')
        self.assertEqual(self.finish(active), 'f')
        self.assertEqual(self.claim(), [])
        self.assertEqual(self.admin(f'select attempts, outcome from {OUTBOX};'), '1|provider_accepted')

    def test_crashed_worker_can_be_replaced_and_cannot_finish_new_lease(self):
        self.online()
        self.create()
        original, = self.claim()
        self.admin(f"update {OUTBOX} set lease_until = clock_timestamp() - interval '1 second';")
        replacement, = self.claim()
        self.assertEqual(original['event_id'], replacement['event_id'])
        self.assertNotEqual(original['lease_id'], replacement['lease_id'])
        self.assertEqual(self.finish(original), 'f')
        self.assertEqual(self.finish(replacement), 't')

    def test_retry_waits_then_stops_at_attempt_limit(self):
        self.online()
        self.create()
        for attempt in range(1, 4):
            claim, = self.claim()
            self.assertEqual(self.finish(claim, 'retry'), 't')
            self.assertEqual(self.claim(), [])
            self.assertEqual(self.admin(f'select attempts from {OUTBOX};'), str(attempt))
            self.admin(f"update {OUTBOX} set available_at = clock_timestamp() - interval '1 second';")
        self.assertEqual(self.claim(), [])
        self.assertEqual(self.admin(f'select outcome from {OUTBOX};'), 'discarded')

    def test_cancelled_or_accepted_offer_is_not_sent(self):
        self.online()
        self.online(dispatch.N)
        self.create()
        self.respond(self.offer())
        second = self.create(uid=dispatch.M)['order']
        self.rpc('cancel', {'order_id': second['id']}, uid=dispatch.M)
        self.assertEqual(self.admin(f'select count(*) from {OUTBOX};'), '2')
        self.assertEqual(self.claim(), [])

    def test_expired_offer_is_skipped_without_dispatch_tick(self):
        self.online()
        self.create()
        self.admin("""
          update orbita_mobile_private.dispatch_offers
          set created_at = created_at - interval '26 seconds',
              expires_at = expires_at - interval '26 seconds'
          where status = 'pending';
        """)
        self.assertEqual(self.claim(), [])
        self.assertEqual(self.admin(f'select attempts from {OUTBOX};'), '0')

    def test_revoked_driver_is_skipped_before_dispatch_cleanup(self):
        self.online()
        self.create()
        self.action(dispatch.D, 'block')
        self.assertEqual(self.claim(), [])
        self.assertEqual(self.admin(f'select attempts from {OUTBOX};'), '0')

    def test_outbox_and_worker_are_private(self):
        for role in ('anon', 'authenticated', 'service_role'):
            with self.subTest(role=role):
                self.assertEqual(self.admin(
                    f"select has_table_privilege('{role}', '{OUTBOX}', 'SELECT,INSERT,UPDATE,DELETE'),"
                    f" has_function_privilege('{role}', '{CLAIM}(integer)', 'EXECUTE'),"
                    f" has_function_privilege('{role}', '{FINISH}(uuid,uuid,text)', 'EXECUTE');"
                ), 'f|f|f')
        for query in (f'select * from {OUTBOX};', CLAIM_QUERY):
            result, _ = self.client_raw(query, uid=dispatch.D)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('permission denied', result.stderr)
