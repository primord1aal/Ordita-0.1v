"""Compatibility regressions against actual pinned Supavisor, never cloud."""
from pathlib import Path
from contextlib import contextmanager
import hashlib
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

from pooler_fixture import PoolerFixture,POOLER_URL,FAKE_REF,dbtools,ROOT,docker
import cloud_run
from policy import GuardError,LOCK


class PreviewPoolerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture=PoolerFixture()
        try:cls.fixture.start()
        except BaseException:
            # Keep diagnostics of fake-only startup failure before fixture cleanup.
            log=cls.fixture.path/'startup.log'
            if log.exists():print(log.read_text()[-5000:])
            cls.fixture.close();raise
        cls.records=[]

    @classmethod
    def tearDownClass(cls):
        try:
            out=ROOT/'build/preview-pooler-results.json';out.parent.mkdir(exist_ok=True)
            out.write_text(json.dumps({'pooler_image':dbtools.LOCK['test_pooler_image'],
                'network':'none + shared local namespace; no published ports',
                'client_tls':'verify-full; disposable local CA','records':cls.records},indent=2)+'\n')
        finally:cls.fixture.close()

    def test_startup_read_only_filter_reproduces_cloud_failure(self):
        result=self.fixture.pooler_query('show default_transaction_read_only;',
            options='-c default_transaction_read_only=on',target_attrs='read-only',check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('session is not read-only',result.stderr)
        self.records.append({'test':self.id(),'original_session_filter_rejected':True})

    def test_sql_read_only_is_confirmed_inside_transaction(self):
        result=self.fixture.pooler_query('begin transaction read only; show transaction_read_only; rollback;')
        self.assertEqual(result.stdout.strip(),'on')
        self.records.append({'test':self.id(),'transaction_read_only':'on'})

    def test_server_limits_are_set_inside_pooler_transaction(self):
        db=dbtools.Database(POOLER_URL,FAKE_REF,self.fixture.password,self.fixture.path/'ca.pem',
                            read_only=True,check_read_only_session=False)
        with patch.object(dbtools,'DOCKER',self.fixture.shim('pooler-limits-'+self.fixture.token)):
            result=json.loads(db.query("select json_build_object('read_only',current_setting('transaction_read_only'),"
                "'statement',current_setting('statement_timeout'),'lock',current_setting('lock_timeout'),"
                "'idle',current_setting('idle_in_transaction_session_timeout'));"))
        self.assertEqual(result,{'read_only':'on','statement':'30s','lock':'5s','idle':'15s'})
        self.records.append({'test':self.id(),'server_settings':result})

    def database(self):
        return dbtools.Database(POOLER_URL,FAKE_REF,self.fixture.password,self.fixture.path/'ca.pem',
                                read_only=True,check_read_only_session=False)

    def test_server_statement_timeout_really_cancels_query_through_pooler(self):
        db=self.database();token=uuid.uuid4().hex
        with patch.object(dbtools,'DOCKER',self.fixture.shim(token)),self.assertRaises(GuardError):
            db.tool('psql',['--no-psqlrc','--set','ON_ERROR_STOP=1','-Atq','--dbname',db.url],
                input=b'select pg_sleep(8);',timeout=4,read_only_sql=True)
        self.assertEqual(db.failure_category,'SERVER_STATEMENT_TIMEOUT')
        self.records.append({'test':self.id(),'server_timeout_ms':2000,'client_timeout_seconds':4,
                             'server_error_category':db.failure_category})

    def test_read_only_transaction_blocks_ddl_through_pooler(self):
        db=self.database();name='denied_'+uuid.uuid4().hex[:12]
        with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)),self.assertRaises(GuardError):
            db.query('create table public.'+name+'(id integer);')
        self.assertEqual(self.fixture.query("select to_regclass('public."+name+"') is null;"),'t')
        self.records.append({'test':self.id(),'ddl_rejected_by_server':True})

    def test_pg_dump_uses_its_own_server_read_only_transaction(self):
        db=self.database();before=docker('logs',self.fixture.cid,check=False)
        with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)):
            data=db.dump(['public'])
        self.assertTrue(data.startswith(b'PGDMP'))
        after=docker('logs',self.fixture.cid,check=False)
        extra=(after.stdout+after.stderr)[len(before.stdout+before.stderr):]
        self.assertRegex(extra,r'SET TRANSACTION ISOLATION LEVEL [^\n]*READ ONLY')
        self.records.append({'test':self.id(),'native_pg_dump_read_only_confirmed':True,'format':'custom'})

    def test_complete_preview_encrypts_restores_and_plans_only_offline(self):
        binary=Path(os.environ.get('ORBITA_SUPABASE_CLI','/workspace/.tooling/orbita/supabase-3.0.0/supabase'))
        db=self.database();name='empty_'+uuid.uuid4().hex[:12]
        self.fixture.query('create table public.'+name+'(id integer primary key);')
        try:
            with tempfile.TemporaryDirectory(prefix='orbita-preview-live-') as directory:
                root=Path(directory);backup=root/'encrypted';public=root/'public'
                with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)),\
                     patch.object(db,'cli',side_effect=AssertionError('Cloud CLI forbidden')):
                    receipt=cloud_run.execute({'operation':'preview','run_id':'local','sha':'a'*40,'expected_ref':FAKE_REF},
                        db,root,ROOT,root,public,backup,'artificial-local-passphrase-'+uuid.uuid4().hex,cli_binary=binary)
                self.assertEqual(receipt['pending'],[LOCK['version']])
                self.assertEqual(receipt['cli_dry_run_target'],'isolated_restored_snapshot')
                self.assertTrue(receipt['backup']['decryption_checked'])
                self.assertTrue(receipt['backup']['local_restore_checked'])
                self.assertTrue(receipt['backup']['local_plan']['scoped_state_unchanged'])
                self.assertEqual([p.name for p in backup.iterdir()],['snapshot.tar.gpg'])
                self.assertEqual([p.name for p in public.iterdir()],['preview.json'])
                self.assertEqual(self.fixture.query("select to_regclass('supabase_migrations.schema_migrations') is null;"),'t')
                self.records.append({'test':self.id(),'encrypted_archive_checked':True,'decryption_checked':True,
                    'restore_checked':True,'offline_cli_only':True,'pending':[LOCK['version']],
                    'cloud_source_history_unchanged':True})
        finally:self.fixture.query('drop table public.'+name+';')

    def test_local_cli_timeout_stops_its_owned_clone(self):
        binary=Path(os.environ.get('ORBITA_SUPABASE_CLI','/workspace/.tooling/orbita/supabase-3.0.0/supabase'))
        original=docker('ps','-aq','--no-trunc').stdout.split();real_run=subprocess.run;timed_out=[]
        def timeout(args,**kwargs):
            if '/tmp/orbita-supabase' in args and 'push' in args:
                timed_out.append(True)
                raise subprocess.TimeoutExpired(args,120,output=b'artificial-private-output')
            return real_run(args,**kwargs)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);db=self.database()
            with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)),\
                 patch('subprocess.run',side_effect=timeout),self.assertRaises(GuardError):
                cloud_run.execute({'operation':'preview'},db,root,ROOT,root,root/'public',root/'encrypted',
                    'artificial-local-passphrase-'+uuid.uuid4().hex,cli_binary=binary)
            self.assertFalse((root/'public/preview.json').exists())
        self.assertEqual(set(docker('ps','-aq','--no-trunc').stdout.split()),set(original))
        self.assertEqual(timed_out,[True])
        self.records.append({'test':self.id(),'local_cli_timeout':'no_retry','owned_clone_removed':True})

    def atomic_cleanup(self):
        self.fixture.query("""set statement_timeout='10s'; set lock_timeout='3s';
            drop function if exists public.orbita_get_access() cascade;
            drop schema if exists orbita_mobile_private cascade;
            drop table if exists public.orbita_profiles,public.orbita_user_roles,
                public.orbita_account_access,public.orbita_access_audit cascade;
            drop schema if exists supabase_migrations cascade;
            drop table if exists public.fixture_atomic_probe cascade;
            drop function if exists public.fixture_atomic_capture() cascade;
            drop function if exists public.fixture_atomic_reject() cascade;""")

    @contextmanager
    def atomic_case(self,source=None):
        self.atomic_cleanup()
        db=dbtools.Database(POOLER_URL,FAKE_REF,self.fixture.password,self.fixture.path/'ca.pem',read_only=False)
        try:
            if source is None:
                yield db,ROOT
            else:
                # Synthetic failure migrations exist only in this owned local fixture.
                with tempfile.TemporaryDirectory() as directory:
                    root=Path(directory);migrations=root/'supabase/migrations';migrations.mkdir(parents=True)
                    data=source.encode();(migrations/LOCK['migration']).write_bytes(data)
                    with patch.dict(LOCK,{'migration_sha256':hashlib.sha256(data).hexdigest()}):yield db,root
        finally:self.atomic_cleanup()

    def atomic_call(self,db,root,**kwargs):
        with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)):
            return db.apply_migration(root,**kwargs)

    def create_history(self):
        self.fixture.query("""create schema supabase_migrations;
            create table supabase_migrations.schema_migrations(
                version text primary key,statements text[],name text);""")

    def assert_empty_application(self,history_exists=False):
        state=dbtools.inspect(type('Local',(),{'query':lambda _,sql:self.fixture.query(sql)})())
        self.assertEqual(state['auth_users'],0);self.assertEqual(state['app_tables'],0)
        self.assertFalse(state['private_schema']);self.assertFalse(state['access_rpc'])
        self.assertEqual(state['versions'],[]);self.assertEqual(state['history_table'],history_exists)
        self.assertEqual(self.fixture.query("select to_regclass('public.fixture_atomic_probe') is null;"),'t')

    def assert_cli_recognizes_history(self,db):
        binary=Path(os.environ.get('ORBITA_SUPABASE_CLI','/workspace/.tooling/orbita/supabase-3.0.0/supabase'))
        work=self.fixture.path/'atomic-history-compatibility';migrations=work/'supabase/migrations';migrations.mkdir(parents=True,exist_ok=True)
        (work/'supabase/config.toml').write_text('project_id="orbita_atomic_history"\n[db]\nmajor_version=17\n[db.seed]\nenabled=false\n')
        (migrations/LOCK['migration']).write_bytes((ROOT/'supabase/migrations'/LOCK['migration']).read_bytes())
        target='/tmp/orbita-atomic-history';docker('cp',str(work),self.fixture.cid+':'+target)
        docker('cp',str(binary),self.fixture.cid+':/tmp/orbita-atomic-cli')
        real_run=subprocess.run
        def local_cli(args,**kwargs):
            if not args or args[0]!='supabase':return real_run(args,**kwargs)
            service=Path(kwargs['env']['PGSERVICEFILE']);inside='/tmp/orbita-atomic-service.conf'
            docker('cp',str(service),self.fixture.cid+':'+inside)
            env=kwargs['env'].copy();env.update(PGSERVICEFILE=inside,PGSSLROOTCERT='/tmp/orbita-pooler-ca.pem')
            forwarded=[]
            for key in ['PGPASSWORD','PGSSLMODE','PGCONNECT_TIMEOUT','PGSSLROOTCERT','PGSERVICEFILE','PGSERVICE',
                        'SUPABASE_TELEMETRY_DISABLED','DO_NOT_TRACK']:forwarded+=['--env',key]
            return real_run(dbtools.DOCKER+['exec','--workdir',target,*forwarded,self.fixture.cid,'/tmp/orbita-atomic-cli',*args[1:]],**{**kwargs,'env':env})
        with patch('subprocess.run',side_effect=local_cli):output=db.cli(work,True)
        self.assertIn('up to date',output.lower());self.assertNotIn('Would push these migrations:',output)

    def test_atomic_success_keeps_canonical_source_history_and_limits_through_pooler(self):
        with self.atomic_case() as (db,root):
            self.create_history()
            self.fixture.query("""create table public.fixture_atomic_probe(settings jsonb);
                create function public.fixture_atomic_capture() returns trigger language plpgsql as $$
                begin insert into public.fixture_atomic_probe values(jsonb_build_object(
                  'statement',current_setting('statement_timeout'),'lock',current_setting('lock_timeout'),
                  'idle',current_setting('idle_in_transaction_session_timeout'),'app',current_setting('application_name')));
                return new; end; $$;
                create trigger fixture_capture before insert on supabase_migrations.schema_migrations
                  for each row execute function public.fixture_atomic_capture();""")
            self.atomic_call(db,root)
            settings=json.loads(self.fixture.query('select settings from public.fixture_atomic_probe;'))
            self.assertEqual({k:v for k,v in settings.items() if k!='app'},{'statement':'30s','lock':'5s','idle':'15s'})
            self.assertRegex(settings['app'],r'^orbita_mig_[a-f0-9]{32}$')
            digest=self.fixture.query("select encode(sha256(convert_to(statements[1],'UTF8')),'hex') from supabase_migrations.schema_migrations;")
            self.assertEqual(digest,LOCK['migration_sha256'])
            self.fixture.query('drop function public.fixture_atomic_capture() cascade; drop table public.fixture_atomic_probe;')
            catalog=dbtools.postflight(type('Local',(),{'query':lambda _,sql:self.fixture.query(sql)})())
            self.assertTrue(catalog['client_acl_verified']);self.assert_cli_recognizes_history(db)
            self.assertEqual(self.fixture.query('select count(*) from supabase_migrations.schema_migrations;'),'1')
            self.records.append({'test':self.id(),'canonical_sha256':digest,'server_limits_at_history_insert':{k:v for k,v in settings.items() if k!='app'},
                'unique_application_marker':True,'postflight':catalog,'cli_history_compatible':True})

    def test_atomic_sql_error_rolls_back_schema_ddl_and_history(self):
        with self.atomic_case('create table public.fixture_atomic_probe(id integer); select 1/0;') as (db,root):
            with self.assertRaises(GuardError):self.atomic_call(db,root)
            self.assert_empty_application()
            self.records.append({'test':self.id(),'schema_ddl_and_history_rolled_back':True})

    def test_atomic_history_error_rolls_back_already_executed_application_ddl(self):
        with self.atomic_case() as (db,root):
            self.create_history()
            self.fixture.query("""create function public.fixture_atomic_reject() returns trigger language plpgsql as $$
                begin raise exception 'artificial history insert failure'; end; $$;
                create trigger fixture_reject before insert on supabase_migrations.schema_migrations
                  for each row execute function public.fixture_atomic_reject();""")
            with self.assertRaises(GuardError):self.atomic_call(db,root)
            self.assert_empty_application(history_exists=True)
            self.records.append({'test':self.id(),'application_ddl_and_version_rolled_back_together':True})

    def test_atomic_statement_timeout_is_server_side_and_rolls_back(self):
        with self.atomic_case('create table public.fixture_atomic_probe(id integer); select pg_sleep(9);') as (db,root):
            with self.assertRaises(GuardError):self.atomic_call(db,root,timeout=4)
            self.assertEqual(db.failure_category,'SERVER_STATEMENT_TIMEOUT')
            self.assert_empty_application()
            self.records.append({'test':self.id(),'server_timeout_ms':2000,'client_deadline_seconds':4,'rollback':True})

    def test_atomic_concurrent_calls_commit_exactly_one_version(self):
        with self.atomic_case() as (db,root):
            other=dbtools.Database(POOLER_URL,FAKE_REF,self.fixture.password,self.fixture.path/'ca.pem',read_only=False)
            results=[];errors=[]
            def execute(client):
                try:client.apply_migration(root);results.append('applied')
                except GuardError:results.append('rejected')
                except BaseException as error:errors.append(type(error).__name__)
            with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)):
                threads=[threading.Thread(target=execute,args=(client,)) for client in [db,other]]
                for thread in threads:thread.start()
                for thread in threads:thread.join(timeout=45)
                self.assertFalse(any(thread.is_alive() for thread in threads))
            self.assertEqual(errors,[]);self.assertCountEqual(results,['applied','rejected'])
            self.assertEqual(self.fixture.query('select count(*) from supabase_migrations.schema_migrations;'),'1')
            self.records.append({'test':self.id(),'one_commit':True,'concurrent_repeat_rejected':True})

    def test_atomic_history_initialization_is_already_under_lock_timeout(self):
        with self.atomic_case('select 1;') as (db,root):
            self.create_history();tag='fixture_lock_'+uuid.uuid4().hex
            command=dbtools.DOCKER+['exec','-i','-e','PGAPPNAME='+tag,self.fixture.cid,'psql','-X','-Atq','-v',
                'ON_ERROR_STOP=1','-p','55432','-U','postgres','-d','postgres']
            holder=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                env=dbtools.restricted_process_env())
            try:
                holder.stdin.write(b'begin; lock table supabase_migrations.schema_migrations in access exclusive mode; select pg_sleep(30);\n');holder.stdin.flush()
                deadline=time.monotonic()+10
                while self.fixture.query("select count(*) from pg_stat_activity where application_name='"+tag+"' and state='active' and wait_event='PgSleep';")!='1':
                    self.assertLess(time.monotonic(),deadline);time.sleep(.1)
                with self.assertRaises(GuardError):self.atomic_call(db,root,timeout=6)
                self.assertEqual(db.failure_category,'SERVER_LOCK_TIMEOUT')
            finally:
                self.fixture.query("select pg_terminate_backend(pid,1000) from pg_stat_activity where application_name='"+tag+"' and usename=session_user and pid<>pg_backend_pid();")
                try:holder.communicate(timeout=5)
                except subprocess.TimeoutExpired:holder.kill();holder.communicate(timeout=5)
            self.assert_empty_application(history_exists=True)
            self.records.append({'test':self.id(),'history_initialization_lock_timeout_ms':1000,'no_version_written':True})

    def test_atomic_client_deadline_cancels_marked_backend_through_pooler(self):
        with self.atomic_case('create table public.fixture_atomic_probe(id integer); select pg_sleep(20);') as (db,root):
            result=[]
            def execute():
                try:db.apply_migration(root,timeout=4);result.append('unexpected_commit')
                except GuardError:result.append('stopped')
                except BaseException as error:result.append(type(error).__name__)
            with patch.object(dbtools,'DOCKER',self.fixture.shim(uuid.uuid4().hex)),\
                 patch.object(dbtools,'_timeout_options',return_value='-c statement_timeout=20000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=15000'):
                thread=threading.Thread(target=execute);thread.start();seen=[];deadline=time.monotonic()+8
                while not seen and thread.is_alive() and time.monotonic()<deadline:
                    seen=json.loads(self.fixture.query("select coalesce(json_agg(json_build_object('pid',pid,'start',backend_start::text)),'[]') from pg_stat_activity where application_name like 'orbita_mig_%' and state='active' and query like '%pg_sleep(20)%';"))
                    if not seen:time.sleep(.1)
                thread.join(timeout=45);self.assertFalse(thread.is_alive())
            self.assertTrue(seen,'Must observe the actual marked backend before client timeout')
            self.assertEqual(result,['stopped']);self.assertEqual(db.failure_category,'CLIENT_DEADLINE_UNCERTAIN')
            for row in seen:
                remaining=self.fixture.query("select count(*) from pg_stat_activity where pid="+str(int(row['pid']))+
                    " and backend_start='"+row['start']+"'::timestamptz and (xact_start is not null or state like 'idle in transaction%');")
                self.assertEqual(remaining,'0')
            self.assert_empty_application()
            self.records.append({'test':self.id(),'client_deadline_seconds':4,'marked_transaction_gone':True,'rollback':True})


if __name__=='__main__':unittest.main(verbosity=2)
