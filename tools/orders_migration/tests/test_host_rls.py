"""Pinned metadata tests: no database, credentials or cloud operations."""
import copy
import unittest

from tools.orders_migration.admission import GuardError
from tools.orders_migration.catalog import reference
from tools.orders_migration.host_rls import metadata_sql, validate


class HostRLSTests(unittest.TestCase):
    def test_only_exact_reviewed_function_and_bound_trigger_are_accepted(self):
        expected = reference('host_rls')
        validate(copy.deepcopy(expected), expected)
        self.assertEqual(expected['functions'][0]['definition_sha256'],
                         'b21d88816c445d14cef5032c3cd4abaebc1db2001fcb3435022ab6b496182ca4')
        for collection in ('functions', 'event_triggers'):
            for key in expected[collection][0]:
                changed = copy.deepcopy(expected)
                changed[collection][0][key] = None if changed[collection][0][key] is not None else 'tamper'
                with self.subTest(collection=collection, key=key), self.assertRaises(GuardError):
                    validate(changed, expected)
            for mutation in ('missing', 'duplicate'):
                changed = copy.deepcopy(expected)
                changed[collection] = [] if mutation == 'missing' else changed[collection]*2
                with self.subTest(collection=collection,mutation=mutation), self.assertRaises(GuardError):
                    validate(changed, expected)
        with self.assertRaises(GuardError):
            validate(None, expected)

    def test_query_collects_binding_overloads_and_additional_linked_triggers(self):
        sql = metadata_sql()
        self.assertTrue(sql.startswith('SELECT '))
        self.assertIn('p.oid=e.evtfoid', sql)
        self.assertIn("e.evtname='ensure_rls' OR", sql)
        self.assertNotIn('p.pronargs=0', sql)  # Extra overloads cannot be hidden.
        self.assertNotIn('EXECUTE FUNCTION',sql)
        self.assertNotIn('CREATE ',sql)
