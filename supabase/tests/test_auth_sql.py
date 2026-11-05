"""Одноразовая PostgreSQL без сети; клиентские соединения НЕ владелец/SET ROLE.

Запуск: python3 -m unittest discover -s supabase/tests -p test_auth_sql.py -v
Образ должен быть заранее загружен. Отчёт build/stage3b-sql-results.json.
Подпись JWT, Auth HTTP и настоящий PostgREST этим стендом не проверяются.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
IMAGE = 'postgres@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5'
DOCKER = ['env', '-u', 'DOCKER_HOST', '-u', 'DOCKER_CONTEXT', '-u', 'DOCKER_TLS',
          '-u', 'DOCKER_TLS_VERIFY', '-u', 'DOCKER_CERT_PATH', 'docker', '--host=unix:///var/run/docker.sock']
A, B, D, N, M, X = [f'00000000-0000-4000-8000-{n:012d}' for n in range(1, 7)]


class AuthSQLTests(unittest.TestCase):
    records = []

    @classmethod
    def setUpClass(cls):
        cls.container = 'orbita-stage3b-' + uuid.uuid4().hex[:12]
        subprocess.run(DOCKER + ['run', '--detach', '--rm', '--name', cls.container,
            '--network', 'none', '--tmpfs', '/var/lib/postgresql/data:rw,noexec,nosuid,size=256m',
            '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', '-e', 'POSTGRES_DB=orbita_test', IMAGE],
            check=True, capture_output=True, text=True)
        try:
            deadline = time.monotonic() + 30
            while True:
                process = subprocess.run(DOCKER + ['exec', cls.container, 'cat', '/proc/1/comm'], capture_output=True, text=True)
                ready = subprocess.run(DOCKER + ['exec', cls.container, 'pg_isready', '-U', 'postgres'], capture_output=True)
                if process.stdout.strip() == 'postgres' and ready.returncode == 0:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError('Одноразовая PostgreSQL не запустилась')
                time.sleep(.2)
            cls.owner((ROOT / 'supabase/tests/bootstrap_local.sql').read_text())
            # В рабочем пути транзакцией владеет CLI. Здесь psql воспроизводит
            # эту внешнюю границу; прямой запуск файла без неё не используется.
            cls.owner('begin;\n' + (ROOT / 'supabase/migrations/202611050001_stage3b_auth.sql').read_text() + '\ncommit;')
            # Шаблон без профильных/ролевых данных, отдельная БД для каждого теста.
            cls.owner("select pg_terminate_backend(pid) from pg_stat_activity where datname='orbita_test' and pid<>pg_backend_pid();")
        except BaseException:
            subprocess.run(DOCKER + ['rm', '-f', cls.container], capture_output=True)
            raise

    @classmethod
    def tearDownClass(cls):
        out = ROOT / 'build/stage3b-sql-results.json'
        out.parent.mkdir(exist_ok=True)
        out.write_text(json.dumps({'environment': 'PostgreSQL 17, Docker --network none, JWT GUC model',
            'client_connections': 'LOGIN authenticated/anon; no SET ROLE and no BYPASSRLS',
            'records': cls.records}, ensure_ascii=False, indent=2) + '\n')
        subprocess.run(DOCKER + ['rm', '-f', cls.container], capture_output=True, check=True)

    @classmethod
    def sql(cls, statement, role='postgres', uid=None, db='orbita_test'):
        prefix = "\\set VERBOSITY verbose\n"
        if uid is not None:
            prefix += f"select set_config('request.jwt.claim.sub','{uid}',false);\n"
        return subprocess.run(DOCKER + ['exec', '-i', cls.container, 'psql', '--no-psqlrc',
            '--set', 'ON_ERROR_STOP=1', '-U', role, '-d', db, '-Atq'],
            input=prefix + statement, capture_output=True, text=True, timeout=25)

    @classmethod
    def owner(cls, statement):
        r = cls.sql(statement)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    def setUp(self):
        self._record_admin = False
        self.db = 'case_' + uuid.uuid4().hex[:12]
        self.owner(f'create database {self.db} template orbita_test;')
        self.assertEqual(self.admin("select current_user||':'||session_user;"),'postgres:postgres')
        self.admin(f"insert into auth.users(id,email) values " + ','.join(
            f"('{u}','u{i}@example.test')" for i, u in enumerate([A, B, D, N, M, X])) + ';')
        for user in [A, B, D, N, M]:
            self.action(user, 'provision')
        self.action(A, 'bootstrap', 'admin', confirm=True)
        self.action(B, 'assign', 'passenger')
        self.action(D, 'assign', 'driver')
        self._record_admin = True

    def tearDown(self):
        self.owner(f'drop database {self.db};')

    def admin(self, statement):
        r = self.sql(statement, db=self.db)
        if getattr(self, '_record_admin', False) and not statement.startswith('select jsonb_build_object'):
            self.records.append({'test': self.id(), 'context': {'current_user':'postgres','session_user':'postgres'},
                'operation':statement,'mechanism':'administrative control/state check; NOT client RLS',
                'actual_rows':r.stdout.strip().splitlines(),'actual_error':r.stderr.strip(),'passed':r.returncode==0})
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def action_sql(self, target, action, role=None, confirm=False, actor=None):
        role_sql = 'null' if role is None else "'" + role + "'"
        actor_sql = 'null' if actor is None else "'" + actor + "'::uuid"
        return f"select orbita_mobile_private.admin_access('{target}','{action}',{role_sql},{actor_sql},'Локальный вымышленный сценарий',{str(confirm).lower()});"

    def action(self, target, action, role=None, confirm=False, actor=None):
        return self.admin(self.action_sql(target, action, role, confirm, actor))

    def context(self, role, uid):
        r = self.sql("""select json_build_object('current_user',current_user,'session_user',session_user,
            'superuser',rolsuper,'bypassrls',rolbypassrls,'uid',auth.uid(),
            'owns_table',exists(select 1 from pg_class where relname='orbita_profiles' and relowner=pg_roles.oid))
            from pg_roles where rolname=current_user;""".replace('\n', ' '), role, uid, self.db)
        self.assertEqual(r.returncode, 0, r.stderr)
        value = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(value['current_user'], role)
        self.assertEqual(value['session_user'], role)
        self.assertFalse(value['superuser']); self.assertFalse(value['bypassrls']); self.assertFalse(value['owns_table'])
        self.assertEqual(value['uid'], uid)
        return value

    def client(self, statement, role='authenticated', uid=B, error=None, mechanism='RLS', expected=None):
        context = self.context(role, uid)
        before = self.admin("""select jsonb_build_object('profiles',(select jsonb_agg(t order by user_id) from public.orbita_profiles t),
          'roles',(select jsonb_agg(t order by user_id) from public.orbita_user_roles t),
          'access',(select jsonb_agg(t order by user_id) from public.orbita_account_access t),
          'audit',(select jsonb_agg(t order by id) from public.orbita_access_audit t));""".replace('\n',' '))
        r = self.sql(statement, role, uid, self.db)
        passed = (r.returncode != 0 and error in r.stderr) if error else r.returncode == 0
        if mechanism == 'RLS WITH CHECK':
            passed = passed and 'row-level security' in r.stderr
        result = r.stdout.strip().splitlines()[1:] if uid is not None else r.stdout.strip().splitlines()
        if expected is not None:
            passed = passed and result == expected
        if error or expected == []:
            after = self.admin("""select jsonb_build_object('profiles',(select jsonb_agg(t order by user_id) from public.orbita_profiles t),
              'roles',(select jsonb_agg(t order by user_id) from public.orbita_user_roles t),
              'access',(select jsonb_agg(t order by user_id) from public.orbita_account_access t),
              'audit',(select jsonb_agg(t order by id) from public.orbita_access_audit t));""".replace('\n',' '))
            passed = passed and before == after
        self.records.append({'test': self.id(), 'context': context, 'operation': statement,
            'mechanism': mechanism, 'expected_sqlstate': error, 'expected_rows': expected,
            'actual_rows': result, 'actual_error': r.stderr.strip(), 'passed': passed,
            'limitation': 'JWT подпись и PostgREST не моделируются'})
        self.assertTrue(passed, r.stderr or repr(result))
        return result

    def access(self, uid):
        return json.loads(self.client('select public.orbita_get_access();', uid=uid, mechanism='own-current-access')[-1])

    def test_01_real_client_context_and_own_read(self):
        self.client('select user_id from public.orbita_profiles order by user_id;', expected=[B])
        self.assertEqual(self.admin('select count(*) from public.orbita_profiles;'), '5')
        self.assertEqual(self.access(D)['role'], 'driver')

    def test_02_anonymous_grant_denial_and_admin_control(self):
        self.client('select * from public.orbita_profiles;', 'anon', None, error='42501', mechanism='GRANT')
        self.assertEqual(self.admin('select count(*) from public.orbita_profiles;'), '5')
        self.client('select public.orbita_get_access();', 'anon', None, error='42501', mechanism='EXECUTE')

    def test_03_foreign_profile_update_rls_and_positive_own_update(self):
        self.client(f"update public.orbita_profiles set display_name='Тест' where user_id='{D}' returning user_id;", expected=[])
        self.assertEqual(self.admin(f"update public.orbita_profiles set display_name='Тест' where user_id='{D}' returning user_id;"), D)
        self.client(f"update public.orbita_profiles set display_name='Тест' where user_id='{B}' returning user_id;", expected=[B])

    def test_04_client_role_writes_denied_valid_admin_controls(self):
        for role in ['driver','admin']:
            statement=f"update public.orbita_user_roles set role='{role}' where user_id='{B}' returning role;"
            self.client(statement,error='42501',mechanism='GRANT')
            self.assertEqual(self.admin('begin; '+statement+' rollback;'),role)
        statement=f"delete from public.orbita_user_roles where user_id='{D}' returning user_id;"
        self.client(statement,error='42501',mechanism='GRANT')
        self.assertEqual(self.admin('begin; '+statement+' rollback;'),D)

    def test_05_block_writes_denied_and_admin_control(self):
        for target in [B,D]:
            statement=f"update public.orbita_account_access set is_blocked=true where user_id='{target}' returning user_id;"
            self.client(statement,error='42501',mechanism='GRANT')
            self.assertEqual(self.admin('begin; '+statement+' rollback;'),target)

    def test_06_role_block_audit_rls_in_isolated_privilege_probe(self):
        # Только эта одноразовая БД: временно открываем базовые права, чтобы
        # отдельно проверить достижение RLS. Миграция таких GRANT НЕ содержит.
        self.admin('grant select,update,delete,insert on public.orbita_user_roles,public.orbita_account_access,public.orbita_access_audit to authenticated;')
        for table,field,value in [('orbita_user_roles','role',"'admin'"),('orbita_account_access','is_blocked','true')]:
            self.client(f'select * from public.{table};',expected=[],mechanism='RLS after temporary test GRANT')
            self.client(f"update public.{table} set {field}={value} where user_id='{B}' returning user_id;",expected=[],mechanism='RLS after temporary test GRANT')
            self.client(f"delete from public.{table} where user_id='{B}' returning user_id;",expected=[],mechanism='RLS after temporary test GRANT')
        self.client(f"insert into public.orbita_user_roles(user_id,role) values('{N}','admin');",error='42501',mechanism='RLS WITH CHECK')
        self.assertEqual(self.admin(f"begin; insert into public.orbita_user_roles(user_id,role) values('{N}','admin') returning user_id; rollback;"),N)
        self.client('select * from public.orbita_access_audit;',expected=[],mechanism='RLS after temporary test GRANT')
        audit_insert=f"insert into public.orbita_access_audit(id,target_user_id,operation,database_actor,source) overriding system value values(10000,'{B}','test',session_user,'direct_database');"
        self.client(audit_insert,error='42501',mechanism='RLS WITH CHECK')
        self.admin('begin; '+audit_insert+' rollback;')

    def test_15_missing_account_state_and_repeated_migration_fail_closed(self):
        self.admin(f"delete from public.orbita_account_access where user_id='{N}';")
        self.assertEqual(self.access(N)['status'],'inconsistent')
        self.client('select * from public.orbita_profiles;',uid=N,expected=[])
        r=self.sql('begin;\n'+(ROOT/'supabase/migrations/202611050001_stage3b_auth.sql').read_text()+'\ncommit;',db=self.db)
        self.assertNotEqual(r.returncode,0)
        self.assertIn('Объекты уже существуют',r.stderr)
        self.assertEqual(self.access(B)['role'],'passenger')

    def test_16_default_grants_and_truncate_do_not_open_admin_paths(self):
        self.assertEqual(self.admin("select has_function_privilege('service_role','orbita_mobile_private.admin_access(uuid,text,text,uuid,text,boolean,text)','EXECUTE');"),'f')
        self.assertEqual(self.admin("select has_table_privilege('service_role','public.orbita_user_roles','UPDATE');"),'f')
        for table in ['orbita_user_roles','orbita_account_access','orbita_profiles']:
            r=self.sql(f'truncate public.{table} cascade;',db=self.db)
            self.assertNotEqual(r.returncode,0); self.assertIn('23514',r.stderr)
        self.assertEqual(self.access(A)['role'],'admin')

    def test_17_profile_update_waiting_for_block_cannot_use_old_rights(self):
        context=self.context('authenticated',B)
        with ThreadPoolExecutor(max_workers=2) as pool:
            blocking=pool.submit(self.sql,'begin; '+self.action_sql(B,'block')+' select pg_sleep(1.5); commit;',db=self.db)
            deadline=time.monotonic()+5
            while True:
                waiting=self.admin("select count(*) from pg_stat_activity where datname=current_database() and wait_event='PgSleep';")
                if waiting=='1':break
                self.assertLess(time.monotonic(),deadline)
                time.sleep(.02)
            updating=pool.submit(self.sql,f"update public.orbita_profiles set display_name='Старые права' where user_id='{B}' returning user_id;",'authenticated',B,self.db)
            owner_result=blocking.result(); result=updating.result()
        self.assertEqual(owner_result.returncode,0,owner_result.stderr)
        self.assertNotEqual(result.returncode,0); self.assertIn('42501',result.stderr)
        self.assertEqual(self.admin(f"select display_name from public.orbita_profiles where user_id='{B}';"),'')
        self.records.append({'test':self.id(),'context':context,'operation':'own profile UPDATE waits behind concurrent account block',
            'mechanism':'fresh server guard after mutex, NOT GRANT/RLS denial','actual_sqlstate':'42501','passed':True,
            'limitation':'PostgreSQL READ COMMITTED; JWT context model'})

    def test_07_audit_mutation_denied_and_append_only_admin_guard(self):
        statement="insert into public.orbita_access_audit(target_user_id,operation,database_actor,source) values('"+B+"','test',session_user,'direct_database');"
        self.client(statement,error='42501',mechanism='GRANT')
        self.admin('begin; '+statement+' rollback;')
        self.client('delete from public.orbita_access_audit;',error='42501',mechanism='GRANT')
        r=self.sql('delete from public.orbita_access_audit;',db=self.db)
        self.assertNotEqual(r.returncode,0); self.assertIn('42501',r.stderr)

    def test_08_no_role_blocked_revoked_missing_profile(self):
        self.assertEqual(self.access(N)['status'],'no_role')
        self.client('select * from public.orbita_profiles;',uid=N,expected=[])
        self.assertEqual(self.access(X)['status'],'no_profile')
        self.action(B,'block'); self.assertEqual(self.access(B)['status'],'blocked')
        self.client('select * from public.orbita_profiles;',expected=[])
        self.action(B,'unblock'); self.assertEqual(self.access(B)['role'],'passenger')
        self.action(B,'revoke'); self.assertEqual(self.access(B)['status'],'no_role')
        self.client('select * from public.orbita_profiles;',expected=[])

    def test_09_metadata_does_not_grant_access(self):
        self.admin(f'''update auth.users set raw_user_meta_data='{{"role":"admin"}}' where id='{N}';''')
        self.assertEqual(self.access(N)['status'],'no_role')
        self.client('select * from public.orbita_profiles;',uid=N,expected=[])

    def test_10_private_admin_and_alternative_paths_closed(self):
        for role,uid in [('anon',None),('authenticated',B),('authenticated',A)]:
            self.client(self.action_sql(B,'assign','admin'),role,uid,error='42501',mechanism='schema+EXECUTE')
        self.assertEqual(self.admin("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='orbita_mobile_private' and (has_function_privilege('anon',p.oid,'EXECUTE') or has_function_privilege('authenticated',p.oid,'EXECUTE'));"),'0')
        self.assertEqual(self.admin('''select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='orbita_mobile_private' and (p.proowner<>'postgres'::regrole
              or p.proconfig is distinct from array['search_path=""']);'''),'0')
        self.assertEqual(json.loads(self.action(B,'assign','driver'))['role'],'driver')

    def test_11_last_admin_change_block_delete_and_confirmation(self):
        for statement in [self.action_sql(A,'revoke',confirm=True),self.action_sql(A,'block',confirm=True),
            self.action_sql(A,'assign','driver',True),f"delete from auth.users where id='{A}';",
            f"delete from public.orbita_profiles where user_id='{A}';"]:
            r=self.sql(statement,db=self.db); self.assertNotEqual(r.returncode,0); self.assertIn('23514',r.stderr)
        self.action(D,'assign','admin')
        r=self.sql(self.action_sql(A,'revoke'),db=self.db)
        self.assertNotEqual(r.returncode,0); self.assertIn('22023',r.stderr)
        self.action(A,'revoke',confirm=True,actor=A)
        self.assertEqual(self.access(A)['status'],'no_role')
        self.assertEqual(self.access(D)['role'],'admin')

    def test_12_concurrent_last_admin_changes(self):
        for isolation in ['read committed','repeatable read']:
            with self.subTest(isolation=isolation):
                self.action(D,'assign','admin')
                def change(target,delay):
                    return self.sql(f'begin isolation level {isolation}; select count(*) from public.orbita_user_roles; '+
                        self.action_sql(target,'block',confirm=True)+f' select pg_sleep({delay}); commit;',db=self.db)
                with ThreadPoolExecutor(max_workers=2) as pool:
                    first=pool.submit(change,A,1)
                    time.sleep(.2)
                    second=pool.submit(change,D,0)
                    results=[first.result(),second.result()]
                self.assertEqual(sum(r.returncode==0 for r in results),1)
                self.assertTrue(any('23514' in r.stderr or '40001' in r.stderr for r in results))
                self.assertEqual(self.admin('select orbita_mobile_private.active_admins();'),'1')
                self.records.append({'test':self.id(),'context':{'current_user':'postgres','session_user':'postgres'},
                    'operation':'two concurrent admin blocks; '+isolation,'mechanism':'write mutex + last-admin guard',
                    'actual_sqlstates':['00000' if r.returncode==0 else ('40001' if '40001' in r.stderr else '23514') for r in results],
                    'passed':True,'limitation':'административный тест конкуренции; не клиентский RLS'})
                self.action(A,'unblock'); self.action(D,'unblock')

    def test_13_lifecycle_delete_keeps_audit_and_no_orphans(self):
        self.admin(f"delete from auth.users where id='{B}';")
        for table in ['orbita_profiles','orbita_account_access','orbita_user_roles']:
            self.assertEqual(self.admin(f"select count(*) from public.{table} where user_id='{B}';"),'0')
        self.assertGreater(int(self.admin(f"select count(*) from public.orbita_access_audit where target_user_id='{B}';")),0)
        self.assertEqual(self.access(B)['status'],'invalid_session')

    def test_14_constraints_and_invalid_input_separate_from_rls(self):
        for statement,code in [(f"insert into public.orbita_user_roles values('{N}','unknown');",'23514'),
            (f"insert into public.orbita_user_roles values('{X}','passenger');",'23503'),
            (f"insert into public.orbita_user_roles values('{B}','driver');",'23505'),
            (self.action_sql(X,'assign','passenger'),'22023')]:
            r=self.sql(statement,db=self.db); self.assertNotEqual(r.returncode,0); self.assertIn(code,r.stderr)
            self.records.append({'test':self.id(),'context':{'current_user':'postgres','session_user':'postgres'},
                'operation':statement,'mechanism':'constraint/input, NOT RLS','actual_sqlstate':code,'passed':True})


if __name__ == '__main__':
    unittest.main(verbosity=2)
