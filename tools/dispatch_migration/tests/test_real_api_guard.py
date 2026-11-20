import unittest
from unittest.mock import patch
from tools.dispatch_migration.real_api import Accounts, ApiRejected
from tools.dispatch_migration.policy import GuardError

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
