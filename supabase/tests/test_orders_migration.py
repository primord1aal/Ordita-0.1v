"""New admission/atomic/backup integration. Synthetic local PG17, no cloud transport."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch
import hashlib
import json
import os
import tempfile
import unittest

from tools.orders_migration.admission import LOCK, GuardError
from tools.orders_migration.local import Native
from tools.orders_migration.catalog import capture, validate_before, state_hash, protected_hash, catalog_sql
from tools.orders_migration.atomic import body
from tools.orders_migration.backup import create
from tools.orders_migration.runner import execute
from atomic_apply import migration_body

ROOT=Path(__file__).resolve().parents[2]
A='00000000-0000-4000-8000-000000000001'
B='00000000-0000-4000-8000-000000000002'
SID='00000000-0000-4000-8000-000000000099'

class OrdersMigrationTests(unittest.TestCase):
    def setUp(self):
        self.db=Native(os.environ.get('TMPDIR'))
        self.addCleanup(self.db.close)
        for name in ['bootstrap_local.sql','bootstrap_orders_local.sql']:
            self.db.psql((ROOT/'supabase/tests'/name).read_text())
        self.db.execute(migration_body(ROOT))
        # Opaque password/session values are synthetic but must survive backup,
        # restore and DDL exactly; row counts alone would miss their corruption.
        self.db.psql("alter table auth.users add column encrypted_password text default 'synthetic-password-hash'; create table auth.refresh_tokens(id bigint primary key,token text,user_id uuid);")
        self.db.psql(f"insert into auth.users(id,email,raw_user_meta_data) values ('{A}','a@example.test','{{}}'),('{B}','b@example.test','{{\"role\":\"admin\",\"synthetic\":\"preserve-value\"}}');")
        for uid in [A,B]:self.action(uid,'provision')
        self.action(A,'bootstrap','admin',True);self.action(B,'assign','passenger')
        self.db.psql(f"insert into auth.sessions(id,user_id) values('{SID}','{B}'); insert into auth.refresh_tokens values(1,'synthetic-refresh-token','{B}');")
        self.before=capture(self.db);validate_before(self.before)
        self.sha=state_hash(self.db);self.protected=protected_hash(self.db)
    def action(self,uid,action,role=None,confirm=False):
        value='null' if role is None else "'"+role+"'"
        self.db.psql(f"select orbita_mobile_private.admin_access('{uid}','{action}',{value},null,'Synthetic admission fixture',{str(confirm).lower()});")
    def apply(self,script=None):return self.db.execute(body(ROOT,self.sha) if script is None else script)
    def assert_initial(self):
        self.assertEqual(capture(self.db),self.before)
        self.assertEqual(state_hash(self.db),self.sha)
        self.assertEqual(protected_hash(self.db),self.protected)
    def test_01_first_then_second_preserves_auth_rows_catalog_and_history(self):
        self.apply();after=capture(self.db)
        self.assertEqual(protected_hash(self.db),self.protected)
        self.assertEqual(after['history'][0],self.before['history'][0])
        self.assertEqual([x['version'] for x in after['history']],[LOCK['first_version'],LOCK['version']])
        self.assertEqual(after['history'][1]['sha256'],LOCK['sha256'])
        self.assertEqual(self.db.query("select count(*) from public.orbita_orders;"),'0')
    def test_16_rpc_acl_session_and_owner_after_wrapped_migration(self):
        import time
        self.apply()
        claims=json.dumps({'sub':B,'session_id':SID,'exp':int(time.time())+3600,'user_metadata':{'role':'admin'}})
        params="'{\"address\":\"Тестовая, 1\",\"latitude\":55,\"longitude\":82.43}'::jsonb,'{\"address\":\"Тестовая, 2\",\"latitude\":55.01,\"longitude\":82.44}'::jsonb"
        prefix=f"BEGIN; SELECT set_config('request.jwt.claim.sub','{B}',true); SELECT set_config('request.jwt.claims','{claims}',true);"
        response=self.db.psql(prefix+"SELECT jsonb_build_object('role',current_user,'session',session_user); SELECT public.orbita_create_order('00000000-0000-4000-8000-000000000077',"+params+"); ROLLBACK;",role='authenticated')
        objects=[json.loads(line) for line in response.splitlines() if line.startswith('{')]
        self.assertIn({'role':'authenticated','session':'authenticated'},objects)
        receipt=next(value for value in objects if 'order' in value)
        self.assertEqual(receipt['order']['passenger_id'],B)
        self.assertEqual(receipt['order']['status'],'created')
        # Missing session, anon RPC and direct table reads all fail closed.
        for sql,role in [("select public.orbita_get_current_order();",'authenticated'),
                         ("select public.orbita_get_current_order();",'anon'),
                         ("select * from public.orbita_orders;",'authenticated')]:
            with self.subTest(role=role,sql=sql),self.assertRaises(GuardError):self.db.psql(sql,role=role)
        self.assertEqual(protected_hash(self.db),self.protected)

    def test_02_repeat_rejected_without_repair_or_changes(self):
        self.apply();before=state_hash(self.db)
        with self.assertRaises(GuardError):self.apply()
        self.assertEqual(state_hash(self.db),before)
    def test_03_first_history_payload_tamper_fails_closed(self):
        self.db.psql("update supabase_migrations.schema_migrations set statements=array['tampered'];")
        before=state_hash(self.db)
        with self.assertRaises(GuardError):validate_before(capture(self.db))
        with self.assertRaises(GuardError):self.apply()
        self.assertEqual(state_hash(self.db),before)
    def test_04_acl_drift_is_detected_before_write(self):
        self.db.psql('revoke select on public.orbita_profiles from authenticated;')
        before=state_hash(self.db)
        with self.assertRaises(GuardError):validate_before(capture(self.db))
        with self.assertRaises(GuardError):self.apply()
        self.assertEqual(state_hash(self.db),before)
    def test_05_data_changes_after_preview_fail_under_transaction_lock(self):
        self.action(B,'block')
        before=state_hash(self.db)
        with self.assertRaises(GuardError):self.apply()
        self.assertEqual(state_hash(self.db),before)
        self.assertEqual(self.db.query("select to_regclass('public.orbita_orders') is null;"),'t')
    def test_06_error_before_history_rolls_back_all_order_ddl(self):
        sql=body(ROOT,self.sha).replace(b'INSERT INTO supabase_migrations.schema_migrations',b'SELECT 1/0;\nINSERT INTO supabase_migrations.schema_migrations')
        with self.assertRaises(GuardError):self.apply(sql)
        self.assert_initial()
    def test_07_error_after_history_rolls_back_history_and_ddl(self):
        sql=body(ROOT,self.sha).replace(b'DO $post$',b'SELECT 1/0;\nDO $post$')
        with self.assertRaises(GuardError):self.apply(sql)
        self.assert_initial()
    def test_08_two_apply_connections_only_one_commits(self):
        def attempt():
            try:self.apply();return True
            except GuardError:return False
        with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lambda _:attempt(),range(2)))
        self.assertEqual(sorted(results),[False,True]);self.assertEqual(len(capture(self.db)['history']),2)
        self.assertEqual(protected_hash(self.db),self.protected)
    def test_09_backup_decrypt_restore_and_local_rehearsal_with_populated_auth(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as work:
            work=Path(work)
            try:
                result=create(self.db,ROOT,work,work/'encrypted','synthetic-only-backup-passphrase-2026',factory=Native)
            except Exception:
                print('Synthetic source diagnostic:',self.db.last_error)
                raise
            self.assertTrue(result['restore_checked'] and result['rehearsal_checked'])
            self.assertFalse(result['full_project_restore_proven'])
            self.assertEqual(hashlib.sha256((work/'encrypted/snapshot.tar.gpg').read_bytes()).hexdigest(),result['encrypted_sha256'])
            self.assertFalse((work/'before.dump').exists());self.assertFalse((work/'verified.dump').exists())
            self.assert_initial()
    def test_10_wrong_passphrase_creates_no_preview_receipt(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as work:
            work=Path(work)
            with self.assertRaises(GuardError):
                execute({'operation':'preview','sha':'a'*40,'run_id':'1'},self.db,ROOT,work,work/'public',work/'encrypted','short',backup_factory=Native)
            self.assertFalse((work/'public/preview.json').exists());self.assert_initial()
    def test_11_unknown_apply_result_records_attempt_once_no_retry(self):
        class Broken:
            calls=0
            def apply_orders(s,*args):s.calls+=1;raise GuardError('synthetic private password must not escape')
        proof={'status':'preview_passed','source_sha':'a'*40,'project_ref':LOCK['project_ref'],'sql_sha256':LOCK['sha256'],
               'executor':LOCK['executor'],'state_sha256':self.sha,'run_id':'1',
               'before_versions':[LOCK['first_version']],'pending':[LOCK['version']],
               'backup':dict(encrypted_sha256='b'*64,decryption_checked=True,restore_checked=True,rehearsal_checked=True,network='none')}
        broken=Broken()
        with tempfile.TemporaryDirectory() as work,patch('tools.orders_migration.runner.capture',return_value=self.before),\
             patch('tools.orders_migration.runner.state_hash',return_value=self.sha),\
             patch('tools.orders_migration.runner.protected_hash',return_value=self.protected):
            work=Path(work)
            with self.assertRaisesRegex(GuardError,'separately authorized'):
                execute({'operation':'apply','sha':'a'*40,'run_id':'2','preview_run_id':'1','backup_sha256':'b'*64},broken,ROOT,work,work/'public',work/'encrypted',proof=proof)
            self.assertEqual(broken.calls,1)
            self.assertEqual(json.loads((work/'public/apply.json').read_text())['status'],'apply_outcome_unknown')
            self.assertNotIn('password',(work/'public/apply.json').read_text())

    def test_12_column_acl_drift_is_detected(self):
        self.db.psql('grant update(user_id) on public.orbita_profiles to authenticated;')
        before=state_hash(self.db)
        with self.assertRaises(GuardError):validate_before(capture(self.db))
        with self.assertRaises(GuardError):self.apply()
        self.assertEqual(state_hash(self.db),before)
    def test_13_incompatible_auth_dependency_is_detected(self):
        self.db.psql("drop function auth.jwt(); create function auth.jwt() returns text language sql as $$select '{}'::text$$;")
        before=state_hash(self.db)
        with self.assertRaises(GuardError):validate_before(capture(self.db))
        with self.assertRaises(GuardError):self.apply()
        self.assertEqual(state_hash(self.db),before)
    def test_14_preview_queries_are_explicit_read_only(self):
        self.assertEqual(self.db.query("select current_setting('transaction_read_only');"),'on')
        with self.assertRaises(GuardError):self.db.query('delete from public.orbita_user_roles;')
        self.assert_initial()
    def test_15_corrupted_decryption_never_becomes_verified_backup(self):
        from backup import crypt_file
        def corrupt(source,destination,passphrase,home,decrypt=False):
            crypt_file(source,destination,passphrase,home,decrypt)
            if decrypt:Path(destination).write_bytes(Path(destination).read_bytes()+b'corrupt')
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as work,\
             patch('tools.orders_migration.backup.crypt_file',side_effect=corrupt),\
             patch('tools.orders_migration.backup.Docker') as factory:
            work=Path(work)
            with self.assertRaises(GuardError):
                execute({'operation':'preview','sha':'a'*40,'run_id':'1'},self.db,ROOT,work,work/'public',work/'encrypted','synthetic-only-backup-passphrase-2026',backup_factory=factory)
            factory.assert_not_called();self.assertFalse((work/'public/preview.json').exists());self.assert_initial()
