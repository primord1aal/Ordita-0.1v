import base64
from io import BytesIO
import json
import unittest
from urllib.error import HTTPError
from unittest.mock import patch
from tools.dispatch_migration.real_api import Accounts, ApiRejected
from tools.dispatch_migration.policy import GuardError

PASSENGER_UID = '00000000-0000-4000-8000-000000000001'
DRIVER_UID = '00000000-0000-4000-8000-000000000002'
PASSENGER_SESSION = '00000000-0000-4000-8000-000000000011'
DRIVER_SESSION = '00000000-0000-4000-8000-000000000012'
GRANT = '/auth/v1/token?grant_type=password'
ACCESS = '/rest/v1/rpc/orbita_get_access'
LOGOUT = '/auth/v1/logout?scope=local'


def fake_token(session_id):
    claims = json.dumps({'session_id': session_id}).encode()
    segment = base64.urlsafe_b64encode(claims).decode().rstrip('=')
    return f'header.{segment}.signature'


def response(payload=None, *, status=200):
    result = BytesIO(b'' if payload is None else json.dumps(payload).encode())
    result.status = status
    return result


class RealAPIGuardTests(unittest.TestCase):
    def test_missing_or_same_account_credentials_rejected_before_apply(self):
        with self.assertRaises(GuardError): Accounts('sb_publishable_fake',('',''),('d','p'))
        with self.assertRaises(GuardError): Accounts('sb_publishable_fake',('same','p'),('same','p'))
    def test_only_explicit_role_denial_counts(self):
        accounts=Accounts('sb_publishable_fake',('p','synthetic'),('d','synthetic'))
        with patch.object(accounts,'rpc',side_effect=ApiRejected(403,'ORB_DISPATCH_FORBIDDEN')):
            accounts.denied('passenger','driver_poll')
        for error in (ApiRejected(500,'OTHER'),RuntimeError('synthetic timeout')):
            with patch.object(accounts,'rpc',side_effect=error),self.assertRaises((RuntimeError,GuardError)):
                accounts.denied('passenger','driver_poll')
    def test_api_target_and_client_key_are_fixed(self):
        with patch.dict('os.environ',{'SUPABASE_TEST_PROJECT_REF':'wrong'}),self.assertRaises(GuardError):
            Accounts.from_environment()
        with self.assertRaises(GuardError): Accounts('sb_secret_fake',('p','s'),('d','s'))


class PreviewAuthTests(unittest.TestCase):
    def setUp(self):
        self.accounts = Accounts('sb_publishable_fake', ('p', 'test-p'), ('d', 'test-d'))
        self.passenger_token = fake_token(PASSENGER_SESSION)
        self.driver_token = fake_token(DRIVER_SESSION)

    def role_responses(self, *, driver_role='driver'):
        return [
            response({'access_token': self.passenger_token, 'user': {'id': PASSENGER_UID}}),
            response({'status': 'active', 'role': 'passenger', 'user_id': PASSENGER_UID}),
            response({'access_token': self.driver_token, 'user': {'id': DRIVER_UID}}),
            response({'status': 'active', 'role': driver_role, 'user_id': DRIVER_UID}),
        ]

    def assert_requests(self, opened, paths, tokens):
        requests = [call.args[0] for call in opened.call_args_list]
        self.assertEqual([request.selector for request in requests], paths)
        self.assertEqual(
            [request.get_header('Authorization') for request in requests],
            ['Bearer ' + token if token else None for token in tokens],
        )
        self.assertEqual(self.accounts.sessions, {})
        self.assertEqual(self.accounts.credentials, {})

    def test_roles_confirmed_and_both_new_sessions_signed_out(self):
        steps = self.role_responses() + [response(status=204), response(status=204)]
        with patch.object(self.accounts.http, 'open', side_effect=steps) as opened:
            self.assertIsNone(self.accounts.verify_preview_roles())
        self.assert_requests(opened, [GRANT, ACCESS, GRANT, ACCESS, LOGOUT, LOGOUT],
                             [None, self.passenger_token, None, self.driver_token,
                              self.passenger_token, self.driver_token])

    def test_driver_login_rejected_and_passenger_session_signed_out(self):
        rejects = HTTPError(self.accounts.base + GRANT, 400, 'Synthetic failure', None, BytesIO(b'{}'))
        steps = self.role_responses()[:2] + [rejects, response(status=204)]
        with patch.object(self.accounts.http, 'open', side_effect=steps) as opened:
            with self.assertRaises(ApiRejected):
                self.accounts.verify_preview_roles()
        self.assert_requests(opened, [GRANT, ACCESS, GRANT, LOGOUT],
                             [None, self.passenger_token, None, self.passenger_token])

    def test_driver_role_mismatch_still_signs_out_both(self):
        steps = self.role_responses(driver_role='passenger') + [response(status=204), response(status=204)]
        with patch.object(self.accounts.http, 'open', side_effect=steps) as opened:
            with self.assertRaises(GuardError):
                self.accounts.verify_preview_roles()
        self.assert_requests(opened, [GRANT, ACCESS, GRANT, ACCESS, LOGOUT, LOGOUT],
                             [None, self.passenger_token, None, self.driver_token,
                              self.passenger_token, self.driver_token])

    def test_first_logout_failure_does_not_skip_second_logout(self):
        steps = self.role_responses() + [response(status=200), response(status=204)]
        with patch.object(self.accounts.http, 'open', side_effect=steps) as opened:
            with self.assertRaises(GuardError):
                self.accounts.verify_preview_roles()
        self.assert_requests(opened, [GRANT, ACCESS, GRANT, ACCESS, LOGOUT, LOGOUT],
                             [None, self.passenger_token, None, self.driver_token,
                              self.passenger_token, self.driver_token])

    def test_zero_session_id_prevents_potential_global_logout(self):
        unsafe_token = fake_token('00000000-0000-0000-0000-000000000000')
        steps = [response({'access_token': unsafe_token, 'user': {'id': PASSENGER_UID}})]
        with patch.object(self.accounts.http, 'open', side_effect=steps) as opened:
            with self.assertRaises(GuardError):
                self.accounts.verify_preview_roles()
        self.assert_requests(opened, [GRANT], [None])
