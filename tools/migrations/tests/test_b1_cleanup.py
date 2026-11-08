"""Отказы cleanup должны закрывать допуск, не задевать чужие ресурсы и не раскрывать секреты."""
from pathlib import Path
import json
import os
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools/migrations'))
import dbtools
from policy import GuardError


class B1CleanupGuards(unittest.TestCase):
    def setUp(self):
        self.db=dbtools.Database('postgresql://postgres@db.'+'a'*20+'.supabase.co:5432/postgres?sslmode=verify-full',
                                'a'*20,'artificial-db-secret','/tmp/artificial-ca.pem')
        self.token='orbita_mig_'+'a'*32

    def test_database_unavailable_after_timeout_is_explicitly_uncertain(self):
        with patch.object(self.db,'_owned_tool',side_effect=GuardError('artificial-db-secret')),\
             patch.object(self.db,'_end_sql',side_effect=OSError('artificial-db-secret')):
            with self.assertRaises(GuardError) as caught:self.db.tool('psql',[],timeout=5)
        self.assertIn('Завершение SQL не подтверждено',str(caught.exception))
        self.assertNotIn('artificial-db-secret',str(caught.exception))

    def test_foreign_container_label_is_never_removed(self):
        cid='c'*64
        def command(args,**kwargs):
            if 'create' in args:output=cid.encode()
            elif 'inspect' in args:output=(json.dumps(cid)+'\n'+json.dumps('foreign-operation')+'\n').encode()
            else:raise AssertionError('Чужой контейнер нельзя запускать или удалять')
            return subprocess.CompletedProcess(args,0,stdout=output,stderr=b'')
        with patch('subprocess.run',side_effect=command) as run,self.assertRaises(GuardError):
            self.db._owned_tool('psql',[],self.token)
        self.assertFalse(any('rm' in call.args[0] for call in run.call_args_list))

    def test_unknown_create_result_never_deletes_a_guessed_name(self):
        with patch.object(dbtools,'checked',side_effect=GuardError('unknown create')) as run,\
             self.assertRaises(GuardError) as caught:
            self.db._owned_tool('psql',[],self.token)
        self.assertEqual(run.call_count,2)
        self.assertIn('create',run.call_args_list[0].args[0])
        self.assertIn('inspect',run.call_args_list[1].args[0])
        self.assertFalse(any('rm' in call.args[0] for call in run.call_args_list))
        self.assertIn('Очистка Docker-клиента не подтверждена',str(caught.exception))

    def test_uncertain_create_recovers_exact_owned_cid_before_deleting(self):
        cid='c'*64
        def command(args,**kwargs):
            if 'create' in args:raise GuardError('create timed out before cidfile')
            if 'inspect' in args:
                return (json.dumps(cid)+'\n'+json.dumps(self.token)+'\n').encode()
            if 'rm' in args:
                self.assertEqual(args[-1],cid)
                return b''
            raise AssertionError('Неожиданная команда')
        with patch.object(dbtools,'checked',side_effect=command) as run,self.assertRaises(GuardError):
            self.db._owned_tool('psql',[],self.token)
        self.assertEqual(run.call_count,4)
        self.assertIn('orbita-db-',run.call_args_list[1].args[0][-1])
        self.assertEqual(run.call_args_list[2].args[0][-1],cid)
        self.assertEqual(run.call_args_list[3].args[0][-1],cid)

    def test_docker_uncertainty_is_not_hidden_by_successful_sql_check(self):
        with patch.object(self.db,'_owned_tool',side_effect=dbtools._DockerCleanupUncertain('Очистка Docker-клиента не подтверждена')),\
             patch.object(self.db,'_end_sql'):
            with self.assertRaises(GuardError) as caught:self.db.tool('psql',[])
        self.assertIn('Очистка Docker-клиента не подтверждена',str(caught.exception))

    def test_cancellation_requires_exact_identity_and_still_checks_final_state(self):
        session={'pid':123,'backend_start':'2026-11-06 10:00:00+00'}
        with patch.object(self.db,'_sessions',side_effect=[[session],[session],[]]),\
             patch.object(self.db,'_control',return_value='t') as control:
            self.db._end_sql(self.token)
        self.assertEqual(control.call_count,2)
        for call in control.call_args_list:
            sql=call.args[0]
            for value in ["application_name='"+self.token+"'",'usename=session_user',
                          'datname=current_database()',"backend_type='client backend'",'pid<>pg_backend_pid()',
                          'pid=123',"backend_start='2026-11-06 10:00:00+00'::timestamptz"]:
                self.assertIn(value,sql)
        self.assertIn('pg_cancel_backend',control.call_args_list[0].args[0])
        self.assertIn('pg_terminate_backend',control.call_args_list[1].args[0])

    def test_live_session_after_cancel_and_terminate_never_reports_success(self):
        session={'pid':123,'backend_start':'2026-11-06 10:00:00+00'}
        with patch.object(self.db,'_sessions',return_value=[session]),\
             patch.object(self.db,'_signal') as signal,self.assertRaises(GuardError):
            self.db._end_sql(self.token)
        self.assertEqual(signal.call_count,2)

    def test_hostile_marker_and_identity_never_enter_cancellation_sql(self):
        with patch.object(self.db,'_control') as control:
            for marker in ['@effect/sql-pg',"orbita_x' or true --",'']:
                with self.subTest(marker=marker),self.assertRaises(GuardError):
                    self.db._signal(marker,[{'pid':1,'backend_start':'2026-11-06 10:00:00+00'}])
            with self.assertRaises(GuardError):
                self.db._signal(self.token,[{'pid':1,'backend_start':"x';select 1;--"}])
        control.assert_not_called()

    def test_preview_cli_service_is_read_only_and_apply_is_rejected(self):
        db=dbtools.Database(self.db.url,'a'*20,'artificial-db-secret',
                            '/tmp/artificial-ca.pem',read_only=True)
        observed=[]
        def run(args,**kwargs):
            env=kwargs['env'];service=Path(env['PGSERVICEFILE'])
            observed.append(service.read_text())
            self.assertEqual(env['PGTARGETSESSIONATTRS'],'read-only')
            return subprocess.CompletedProcess(args,0,stdout=b'dry run',stderr=b'')
        with patch('subprocess.run',side_effect=run):
            self.assertEqual(db.cli('/tmp',True),'dry run')
        self.assertEqual(len(observed),1)
        self.assertIn('default_transaction_read_only=on',observed[0])
        with self.assertRaises(GuardError):
            db.cli('/tmp',False)

    def test_cli_private_service_has_only_limits_and_is_removed_after_call(self):
        observed=[]
        def run(args,**kwargs):
            env=kwargs['env'];service=Path(env['PGSERVICEFILE'])
            observed.append(service)
            self.assertEqual(service.stat().st_mode & 0o777,0o600)
            self.assertEqual(service.parent.stat().st_mode & 0o777,0o700)
            self.assertEqual(service.read_text(),
                '[orbita_b1]\noptions=-c statement_timeout=30000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=15000\n')
            self.assertEqual(env['PGSERVICE'],'orbita_b1')
            self.assertEqual(env['PGSSLMODE'],'verify-full')
            self.assertEqual(env['PGCONNECT_TIMEOUT'],'10')
            self.assertEqual(args,['supabase','db','push','--remote='+self.db.url,'--skip-vault','--dry-run'])
            self.assertNotIn('artificial-db-secret',' '.join(args))
            raise subprocess.TimeoutExpired(args,kwargs['timeout'],output=b'artificial-db-secret')
        with patch('subprocess.run',side_effect=run),self.assertRaises(GuardError) as caught:
            self.db.cli('/tmp',True)
        self.assertIn('завершение его SQL не подтверждено',str(caught.exception))
        self.assertNotIn('artificial-db-secret',str(caught.exception))
        self.assertTrue(observed)
        self.assertFalse(observed[0].exists())


if __name__=='__main__':unittest.main(verbosity=2)
