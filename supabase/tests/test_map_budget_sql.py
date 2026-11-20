"""Actual private-socket PostgreSQL. Only synthetic users and server role."""
from concurrent.futures import ThreadPoolExecutor
import unittest
import json
try:
    from . import test_orders_sql as base
except ImportError:
    import test_orders_sql as base

class MapBudgetSQLTests(unittest.TestCase):
    records=[]
    for name in ('setUpClass','stop_server','tearDown','sql','owner','admin',
                 'action_sql','action','client_raw'):
        locals()[name]=base.OrdersSQLTests.__dict__[name]
    @classmethod
    def tearDownClass(cls):
        try:
            output=base.ROOT/'build/map-budget-sql-results.json'
            output.parent.mkdir(exist_ok=True)
            output.write_text(json.dumps({'environment':cls.server_version,
                'transport':'private Unix socket, no TCP',
                'limitation':'Synthetic accounts; hosted Auth/Edge not tested',
                'records':cls.records},indent=2)+'\n')
        finally:
            cls.stop_server()
    def setUp(self):
        base.OrdersSQLTests.setUp(self)
        self.admin('begin;'+(base.ROOT/'supabase/proposals/20261120173504_managed_maps.sql').read_text()+'commit;')
    def budget(self,units=1,user=base.B):
        return self.admin(f"set role service_role;select public.orbita_map_budget('{user}',{units});")
    def test_browser_and_authenticated_clients_cannot_spend_budget(self):
        for role in ('anon','authenticated'):
            result,_=self.client_raw(f"select public.orbita_map_budget('{base.B}',1);",role=role)
            self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.budget(),'t')
    def test_role_block_and_missing_user_rejected(self):
        self.assertEqual(self.budget(user=base.A),'f')
        self.assertEqual(self.budget(user=base.X),'f')
        self.action(base.B,'block')
        self.assertEqual(self.budget(),'f')
    def test_daily_cap_and_minute_cap_are_atomic(self):
        with ThreadPoolExecutor(max_workers=20) as pool:
            values=list(pool.map(lambda _:self.budget(10),range(20)))
        self.assertEqual(values.count('t'),12)
        self.assertEqual(self.admin("select units from orbita_mobile_private.map_budget where bucket='global';"),'120')
        self.admin("update orbita_mobile_private.map_budget set units=2499 where bucket='global';")
        self.assertEqual(self.budget(2,user=base.D),'f')
        self.assertEqual(self.budget(1,user=base.D),'t')
        self.assertEqual(self.budget(1,user=base.D),'f')
    def test_no_direct_budget_table_access_and_invalid_cost_rejected(self):
        self.assertEqual(self.budget(0),'f')
        self.assertEqual(self.budget(11),'f')
        result,_=self.client_raw('select * from orbita_mobile_private.map_budget;')
        self.assertNotEqual(result.returncode,0)
