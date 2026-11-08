"""B1: реальные session limits, pg_dump cleanup и закреплённый CLI в сети none."""
from pathlib import Path
import json
import os
import subprocess
import threading
import time
import unittest
import uuid
from unittest.mock import patch

from test_b1_timeout import B1Fixture,FAKE_HOST,FAKE_REF,REAL_DOCKER,docker,remove_owned,dbtools,GuardError,ROOT


class B1LiveLimitsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture=B1Fixture()
        try:cls.fixture.start()
        except BaseException:
            cls.fixture.close()
            raise
        cls.records=[]

    @classmethod
    def tearDownClass(cls):
        try:
            dest=ROOT/'build/b1-live-limits-results.json';dest.parent.mkdir(exist_ok=True)
            dest.write_text(json.dumps(cls.records,ensure_ascii=False,indent=2)+'\n')
        finally:cls.fixture.close()

    def setUp(self):
        self.token=uuid.uuid4().hex
        self.marker='orbita_b1_'+self.token
        self.db=dbtools.Database('postgresql://postgres@'+FAKE_HOST+':5432/postgres?sslmode=verify-full',
                                FAKE_REF,'local-fixture-only',self.fixture.path/'ca.pem')
        self.routing=patch.object(dbtools,'DOCKER',self.fixture.shim(self.token));self.routing.start()
        self.tagging=patch.object(dbtools,'_new_operation_token',return_value=self.marker);self.tagging.start()

    def tearDown(self):
        self.tagging.stop();self.routing.stop()
        leftovers=self.fixture.clients(self.token)
        for cid in leftovers:remove_owned(cid,'orbita.b1.test',self.token)
        # Отсутствие own SQL проверяется до fixture teardown, а не после удаления сервера.
        sessions=self.fixture.sessions(self.marker)
        self.assertEqual(leftovers,[],{'owned_clients_left':leftovers})
        self.assertEqual(sessions,[],{'sessions_left':sessions})

    def observe(self,condition):
        stop=threading.Event();seen=[];errors=[]
        def watch():
            try:
                while not stop.is_set():
                    sessions=self.fixture.sessions(self.marker)
                    if any(condition(s) for s in sessions):
                        seen.extend(sessions);return
                    stop.wait(.03)
            except BaseException as error:errors.append(type(error).__name__)
        thread=threading.Thread(target=watch);thread.start()
        return stop,seen,errors,thread

    def finish_observer(self,observer):
        stop,seen,errors,thread=observer
        stop.set();thread.join(timeout=5)
        self.assertFalse(thread.is_alive());self.assertEqual(errors,[]);self.assertTrue(seen)
        return seen

    def test_read_only_preview_rejects_ddl_inside_real_postgresql(self):
        preview=dbtools.Database(self.db.url,FAKE_REF,'local-fixture-only',
                                 self.fixture.path/'ca.pem',read_only=True)
        self.assertEqual(preview.query('reset all; show default_transaction_read_only;'),'on')
        target='b1_ro_'+self.token[:16]
        with self.assertRaises(GuardError):
            preview.query('create table public.'+target+'(n integer);')
        self.assertEqual(self.fixture.query("select to_regclass('public."+target+"') is null;"),'t')
        self.records.append({'test':self.id(),'server_read_only':True,'ddl_blocked':True})

    def test_psql_limits_are_server_settings_and_survive_reset_all(self):
        result=json.loads(self.db.query("reset all; select json_build_object("
            "'statement',current_setting('statement_timeout'),'lock',current_setting('lock_timeout'),"
            "'idle',current_setting('idle_in_transaction_session_timeout'),'app',current_setting('application_name'));"))
        self.assertEqual(result,{'statement':'30s','lock':'5s','idle':'15s','app':self.marker})
        self.records.append({'test':self.id(),'server_settings':result,'wrapper_timeout_seconds':60,
                             'connect_timeout_seconds':10,'tls':'verify-full'})

    def test_idle_transaction_is_terminated_by_real_postgresql(self):
        observer=self.observe(lambda s:s['state']=='idle in transaction')
        started=time.monotonic()
        try:
            with self.assertRaises(GuardError):
                self.db.tool('psql',['-X','-Atq','-v','ON_ERROR_STOP=1','--dbname',self.db.url],
                    input=b'begin; select 1;\n\\! sleep 4\nselect 1; commit;\n',timeout=8)
        finally:seen=self.finish_observer(observer)
        logs=docker('logs',self.fixture.cid,check=False)
        confirmed=any('['+str(seen[0]['pid'])+']' in line and
                      'terminating connection due to idle-in-transaction timeout' in line
                      for line in (logs.stderr+logs.stdout).splitlines())
        self.assertTrue(confirmed,'PostgreSQL должен сам сообщить об idle-in-transaction timeout')
        self.assertEqual(self.fixture.sessions(self.marker),[])
        self.records.append({'test':self.id(),'idle_session_observed':seen,'server_idle_timeout_confirmed':confirmed,
                             'idle_timeout_ms':2000,'elapsed_seconds':round(time.monotonic()-started,3)})

    def test_statement_timeout_is_enforced_by_real_postgresql(self):
        observer=self.observe(lambda s:s['state']=='active')
        try:
            with self.assertRaises(GuardError):
                self.db.tool('psql',['-X','-Atq','-v','ON_ERROR_STOP=1','--dbname',self.db.url],
                             input=b'begin; select pg_sleep(20); commit;',timeout=8)
        finally:seen=self.finish_observer(observer)
        logs=docker('logs',self.fixture.cid,check=False)
        confirmed=any('['+str(seen[0]['pid'])+']' in line and
                      'canceling statement due to statement timeout' in line
                      for line in (logs.stderr+logs.stdout).splitlines())
        self.assertTrue(confirmed,'Должен сработать серверный statement_timeout, а не wrapper timeout')
        self.assertEqual(self.fixture.sessions(self.marker),[])
        self.records.append({'test':self.id(),'observed_running':seen,'server_statement_timeout_confirmed':confirmed,
                             'statement_timeout_ms':4000,'wrapper_timeout_seconds':8})

    def test_lost_create_response_recovers_and_removes_only_own_container(self):
        real_checked=dbtools.checked;lost=[]
        def lose_response(args,**kwargs):
            result=real_checked(args,**kwargs)
            if not lost and args[:len(dbtools.DOCKER)+1]==dbtools.DOCKER+['create']:
                cid=result.decode().strip();lost.append(cid)
                Path(args[args.index('--cidfile')+1]).unlink()
                raise GuardError('Искусственная потеря create response до чтения CID')
            return result
        with patch.object(dbtools,'checked',side_effect=lose_response),self.assertRaises(GuardError):
            self.db.query('select 1;')
        self.assertEqual(len(lost),1)
        self.assertEqual(self.fixture.clients(self.token),[])
        self.assertEqual(self.fixture.sessions(self.marker),[])
        self.records.append({'test':self.id(),'lost_response_cid':lost[0],'owned_clients_left':[],
                             'recovered_cid_before_removal':True})

    def test_own_anonymous_client_volumes_are_removed(self):
        before=set(docker('volume','ls','--quiet').stdout.split())
        real_checked=dbtools.checked;created=[]
        def record_volumes(args,**kwargs):
            result=real_checked(args,**kwargs)
            if args[:len(dbtools.DOCKER)+1]==dbtools.DOCKER+['create']:
                cid=result.decode().strip()
                data=json.loads(docker('inspect',cid).stdout)[0]
                self.assertEqual(data['Config']['Labels'][dbtools.OWNER_LABEL],self.marker)
                for mount in data['Mounts']:
                    if mount['Type']=='volume':created.append({'cid':cid,'volume':mount['Name']})
            return result
        with patch.object(dbtools,'checked',side_effect=record_volumes):
            self.assertEqual(self.db.query('select 1;'),'1')
        self.assertTrue(created,'PG image должен создать проверяемый собственный anonymous volume')
        for row in created:
            result=docker('volume','inspect',row['volume'],check=False)
            self.assertNotEqual(result.returncode,0,row)
        after=set(docker('volume','ls','--quiet').stdout.split())
        self.assertEqual(after,before,'Исходные тома сохранены, дополнительных томов нет')
        self.records.append({'test':self.id(),'created_owned_volumes':created,'volumes_after_equal_before':True})

    def test_pg_dump_waiting_lock_is_cancelled_after_wrapper_timeout(self):
        table='b1_dump_'+self.token[:16];neighbor='orbita_b1_neighbor_'+self.token[:20]
        self.fixture.query('create table public.'+table+'(n integer);')
        process=subprocess.Popen(REAL_DOCKER+['exec','-i',self.fixture.cid,'psql','-X','-Atq','-v',
            'ON_ERROR_STOP=1','-U','postgres','-d','postgres'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,text=True)
        try:
            process.stdin.write("set application_name='"+neighbor+"'; begin; lock table public."+table+
                                ' in access exclusive mode; select pg_sleep(60);\n');process.stdin.flush()
            deadline=time.monotonic()+5
            while not self.fixture.sessions(neighbor):
                if time.monotonic()>deadline:self.fail('Соседняя собственная транзакция не запустилась')
                time.sleep(.03)
            observer=self.observe(lambda s:s['state']=='active' and s['wait_event_type']=='Lock')
            try:
                # Прямой pg_dump намеренно без --lock-wait-timeout, чтобы проверить fallback cleanup.
                with self.assertRaises(GuardError):
                    self.db.tool('pg_dump',['--format=custom','--schema=public','--dbname',self.db.url],timeout=5)
            finally:seen=self.finish_observer(observer)
            sessions=self.fixture.sessions(self.marker)
            locks=int(self.fixture.query("select count(*) from pg_locks l join pg_stat_activity a on a.pid=l.pid "
                                         "where a.application_name='"+self.marker+"' and not l.granted;"))
            neighbor_alive=any(s['state']=='active' for s in self.fixture.sessions(neighbor))
            clients=self.fixture.clients(self.token)
            self.records.append({'test':self.id(),'observed_running':seen,'sessions_after_timeout':sessions,
                                 'waiting_locks':locks,'owned_clients_left':clients,'neighbor_untouched':neighbor_alive})
            self.assertEqual(sessions,[]);self.assertEqual(locks,0);self.assertEqual(clients,[])
            self.assertTrue(neighbor_alive)
        finally:
            self.fixture.query("select pg_terminate_backend(pid) from pg_stat_activity where application_name='"+
                               neighbor+"' and datname='postgres' and usename='postgres' and pid<>pg_backend_pid();")
            try:process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill();process.communicate(timeout=5)
            self.fixture.query('drop table public.'+table+';')

    def test_cli_service_limits_apply_inside_actual_migration_after_reset_all(self):
        binary=Path(os.environ.get('ORBITA_SUPABASE_CLI','/workspace/.tooling/orbita/supabase-3.0.0/supabase'))
        self.assertTrue(binary.is_file(),'Нужен закреплённый локальный CLI; облачная замена запрещена')
        docker('cp',str(binary),self.fixture.cid+':/tmp/b1-supabase')
        version=docker('exec',self.fixture.cid,'/tmp/b1-supabase','--version').stdout.strip()
        self.assertEqual(version,'3.0.0')
        work=self.fixture.path/('cli-'+self.token);migrations=work/'supabase/migrations';migrations.mkdir(parents=True)
        (work/'supabase/config.toml').write_text('project_id="orbita_b1_local"\n[db]\nmajor_version=17\n[db.seed]\nenabled=false\n')
        table='b1_cli_'+self.token[:16]
        (migrations/'202611060098_b1probe.sql').write_text('reset all; create table public.'+table+
            " as select current_setting('statement_timeout') as statement_timeout,current_setting('lock_timeout') as lock_timeout,"
            "current_setting('idle_in_transaction_session_timeout') as idle_timeout,current_setting('application_name') as app;")
        target='/tmp/b1-work-'+self.token
        docker('cp',str(work),self.fixture.cid+':'+target)
        real_run=subprocess.run;observed=[]
        def local_cli(args,**kwargs):
            if not args or args[0]!='supabase':return real_run(args,**kwargs)
            service=Path(kwargs['env']['PGSERVICEFILE'])
            observed.append(str(service))
            inside='/tmp/b1-service-'+self.token+'.conf'
            docker('cp',str(service),self.fixture.cid+':'+inside)
            env=kwargs['env'].copy();env['PGSERVICEFILE']=inside;env['PGSSLROOTCERT']='/tmp/b1-ca.pem'
            forwarded=[]
            for key in ['PGPASSWORD','PGSSLMODE','PGCONNECT_TIMEOUT','PGSSLROOTCERT','PGSERVICEFILE','PGSERVICE']:
                forwarded+=['--env',key]
            command=REAL_DOCKER+['exec','--workdir',target,*forwarded,self.fixture.cid,'/tmp/b1-supabase',*args[1:]]
            return real_run(command,**{**kwargs,'env':env})
        with patch('subprocess.run',side_effect=local_cli):
            self.db.cli(work,False)
        result=json.loads(self.fixture.query('select row_to_json(t) from public.'+table+' t;'))
        self.assertEqual(result,{'statement_timeout':'30s','lock_timeout':'5s','idle_timeout':'15s','app':'@effect/sql-pg'})
        self.assertTrue(observed);self.assertFalse(Path(observed[0]).exists())
        self.records.append({'test':self.id(),'cli_version':version,'server_settings_after_reset_all':result,
                             'unique_cli_appname_supported':False,'wrapper_timeout_seconds':120})
        self.fixture.query('drop schema supabase_migrations cascade; drop table public.'+table+';')


if __name__=='__main__':unittest.main(verbosity=2)
