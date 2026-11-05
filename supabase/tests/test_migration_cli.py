"""Настоящий CLI 3.0.0 + PostgreSQL 17 в контейнере без внешней сети.

ORBITA_SUPABASE_CLI указывает на заранее проверенный бинарник. TLS проверяется
по одноразовому сертификату localhost. Секретов и адресов облака нет.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/migrations'))
from policy import parse_dry_run,GuardError
from dbtools import baseline_fingerprint,postflight,inspect
from backup import crypt_file,restore_local,create_backup
VERSION = '202611050001'
MIGRATION = ROOT / 'supabase/migrations/202611050001_stage3b_auth.sql'
IMAGE = 'postgres@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5'
DOCKER = ['env','-u','DOCKER_HOST','-u','DOCKER_CONTEXT','-u','DOCKER_TLS','-u','DOCKER_TLS_VERIFY','-u','DOCKER_CERT_PATH',
          'docker','--host=unix:///var/run/docker.sock']


class MigrationCLITests(unittest.TestCase):
    records = []

    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get('ORBITA_SUPABASE_CLI','/workspace/.tooling/orbita/supabase-3.0.0/supabase'))
        if not cls.binary.is_file():
            raise RuntimeError('Нужен заранее проверенный CLI 3.0.0; облачная замена запрещена')
        cls.directory = Path(tempfile.mkdtemp(prefix='orbita-cli-local-'))
        cls.container = 'orbita-cli-' + uuid.uuid4().hex[:12]
        cls.started = False
        try:
            # Сертификат исключительно для одноразовой локальной фикстуры.
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2',
                '-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1',
                '-keyout',str(cls.directory/'key.pem'),'-out',str(cls.directory/'cert.pem')],
                check=True,capture_output=True)
            subprocess.run(DOCKER+['create','--name',cls.container,'--network','none',
                '--tmpfs','/var/lib/postgresql/data:rw,noexec,nosuid,size=256m',
                '-e','POSTGRES_HOST_AUTH_METHOD=trust','-e','POSTGRES_DB=orbita_template',
                '--entrypoint','sh',IMAGE,'-c',
                'chown postgres:postgres /tmp/orbita-key.pem /tmp/orbita-cert.pem; chmod 600 /tmp/orbita-key.pem; '
                'exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/orbita-cert.pem -c ssl_key_file=/tmp/orbita-key.pem'],
                check=True,capture_output=True)
            for source,target in [(cls.directory/'key.pem','/tmp/orbita-key.pem'),(cls.directory/'cert.pem','/tmp/orbita-cert.pem'),(cls.binary,'/tmp/supabase')]:
                subprocess.run(DOCKER+['cp',str(source),cls.container+':'+target],check=True,capture_output=True)
            subprocess.run(DOCKER+['start',cls.container],check=True,capture_output=True)
            cls.started=True
            deadline=time.monotonic()+35
            while True:
                process=subprocess.run(DOCKER+['exec',cls.container,'cat','/proc/1/comm'],capture_output=True,text=True)
                ready=subprocess.run(DOCKER+['exec',cls.container,'pg_isready','-U','postgres'],capture_output=True)
                if process.stdout.strip()=='postgres' and ready.returncode==0:break
                if time.monotonic()>deadline:raise RuntimeError('Локальная PostgreSQL не запустилась')
                time.sleep(.2)
            cls.owner((ROOT/'supabase/tests/bootstrap_local.sql').read_text(),'orbita_template')
            result=subprocess.run(DOCKER+['exec',cls.container,'/tmp/supabase','--version'],capture_output=True,text=True,timeout=20)
            if result.returncode or result.stdout.strip()!='3.0.0':raise RuntimeError('Версия CLI не совпала с закреплённой')
        except BaseException:
            subprocess.run(DOCKER+['rm','-f',cls.container],capture_output=True)
            shutil.rmtree(cls.directory,ignore_errors=True)
            raise

    @classmethod
    def tearDownClass(cls):
        output=ROOT/'build/migration-cli-results.json';output.parent.mkdir(exist_ok=True)
        output.write_text(json.dumps({'cli':'3.0.0','postgres':'17','network':'none','tls':'verify-full; disposable localhost CA',
            'migration_sha256':hashlib.sha256(MIGRATION.read_bytes()).hexdigest(),'records':cls.records,
            'limitation':'Не проверяет облако, JWT/PostgREST и настройки GitHub Environment'},ensure_ascii=False,indent=2)+'\n')
        subprocess.run(DOCKER+['rm','-f',cls.container],capture_output=True,check=True)
        shutil.rmtree(cls.directory,ignore_errors=True)

    @classmethod
    def owner(cls,sql,db):
        result=subprocess.run(DOCKER+['exec','-i',cls.container,'psql','-X','-Atq','-v','ON_ERROR_STOP=1',
            '-U','postgres','-d',db],input=sql,capture_output=True,text=True,timeout=25)
        if result.returncode:raise AssertionError(result.stderr)
        return result.stdout.strip()

    def setUp(self):
        self.database='cli_'+uuid.uuid4().hex[:10]
        self.work='/tmp/'+self.database
        self.owner('create database '+self.database+' template orbita_template;','postgres')
        subprocess.run(DOCKER+['exec',self.container,'mkdir','-p',self.work+'/supabase/migrations'],check=True,capture_output=True)
        self.write('/supabase/config.toml','project_id = "orbita_cli_local"\n[db]\nmajor_version = 17\n[db.migrations]\nenabled = true\n[db.seed]\nenabled = false\n')
        self.write('/supabase/migrations/'+MIGRATION.name,MIGRATION.read_text())

    def tearDown(self):
        self.owner('drop database '+self.database+';','postgres')

    def write(self,suffix,content):
        subprocess.run(DOCKER+['exec','-i',self.container,'sh','-c','cat > "$1"','_',self.work+suffix],
            input=content,text=True,check=True,capture_output=True)

    def cli(self,*args):
        target='postgresql://postgres@localhost:5432/'+self.database+'?sslmode=verify-full&sslrootcert=/tmp/orbita-cert.pem'
        result=subprocess.run(DOCKER+['exec','-w',self.work,self.container,'/tmp/supabase',*args,
            '--remote='+target],capture_output=True,text=True,timeout=45)
        self.records.append({'test':self.id(),'arguments':list(args),'exit':result.returncode,
            'stdout':result.stdout,'stderr':result.stderr})
        return result

    def state(self):
        table=self.owner("select to_regclass('supabase_migrations.schema_migrations') is not null;",self.database)=='t'
        version=self.owner(f"select count(*) from supabase_migrations.schema_migrations where version='{VERSION}';",self.database) if table else '0'
        objects=self.owner("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('orbita_profiles','orbita_user_roles','orbita_account_access','orbita_access_audit');",self.database)
        return {'version':int(version),'tables':int(objects)}

    def database_adapter(self):
        test=self
        class LocalDatabase:
            def query(self,sql):return test.owner(sql,test.database)
            def dump(self,schemas):
                args=['pg_dump','--format=custom','-U','postgres','--dbname',test.database]
                for schema in schemas:args+=['--schema',schema]
                return subprocess.run(DOCKER+['exec',test.container,*args],capture_output=True,
                    check=True,timeout=20).stdout
        return LocalDatabase()

    def test_dry_run_exactly_one_and_no_application(self):
        result=self.cli('db','push','--dry-run','--skip-vault')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(MIGRATION.name,result.stderr+result.stdout)
        self.assertEqual(parse_dry_run(result.stderr+result.stdout),[VERSION])
        self.assertEqual(self.state(),{'version':0,'tables':0})
        self.assertEqual(self.owner("select to_regclass('supabase_migrations.schema_migrations') is null;",self.database),'t')
        self.assertEqual(len(baseline_fingerprint(self.database_adapter())),64)

    def test_apply_records_history_and_repeat_is_noop(self):
        first=self.cli('db','push','--skip-vault','--yes')
        self.assertEqual(first.returncode,0,first.stderr)
        self.assertEqual(self.state(),{'version':1,'tables':4})
        self.assertEqual(postflight(self.database_adapter())['unsafe_private_functions'],0)
        self.assertEqual(self.owner(f"select name from supabase_migrations.schema_migrations where version='{VERSION}';",self.database),'stage3b_auth')
        before=self.owner("select count(*) from pg_trigger where tgname like 'orbita_%';",self.database)
        second=self.cli('db','push','--skip-vault','--yes')
        self.assertEqual(second.returncode,0,second.stderr)
        self.assertNotIn('Applying migration',second.stderr)
        self.assertEqual(self.state(),{'version':1,'tables':4})
        self.assertEqual(self.owner("select count(*) from pg_trigger where tgname like 'orbita_%';",self.database),before)
        self.assertEqual(self.cli('migration','list').returncode,0)
        self.owner('grant update(user_id) on public.orbita_profiles to authenticated;',self.database)
        with self.assertRaises(GuardError):postflight(self.database_adapter())

    def test_artificial_sql_error_rolls_back_objects_and_version(self):
        self.write('/supabase/migrations/'+MIGRATION.name,MIGRATION.read_text()+'\nselect 1/0;\n')
        result=self.cli('db','push','--skip-vault','--yes')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.state(),{'version':0,'tables':0})
        self.assertEqual(self.owner("select count(*) from pg_namespace where nspname='orbita_mobile_private';",self.database),'0')

    def test_history_insert_error_rolls_back_already_executed_ddl(self):
        # Намеренный отказ именно последней записи CLI после всех DDL.
        self.owner("""create schema supabase_migrations;
          create table supabase_migrations.schema_migrations(version text primary key,name text,statements text[]);
          create function public.test_deny_history() returns trigger language plpgsql as $$begin raise exception 'artificial history failure'; end;$$;
          create trigger test_history before insert on supabase_migrations.schema_migrations for each row execute function public.test_deny_history();""",self.database)
        result=self.cli('db','push','--skip-vault','--yes')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.state(),{'version':0,'tables':0})

    def test_encrypted_dump_decrypts_and_restores_synthetic_rows_offline(self):
        self.owner("create table public.synthetic(id integer primary key,label text); insert into public.synthetic values(1,'Тест А'),(2,'Тест Б');",self.database)
        result=subprocess.run(DOCKER+['exec',self.container,'pg_dump','--format=custom','--schema=public',
            '-U','postgres','--dbname',self.database],capture_output=True,check=True,timeout=20)
        directory=self.directory/self.database;directory.mkdir()
        source=directory/'before.dump';source.write_bytes(result.stdout)
        encrypted=directory/'before.gpg';decrypted=directory/'checked.dump'
        phrase='artificial-test-only-'+uuid.uuid4().hex
        crypt_file(source,encrypted,phrase,directory/'gpg')
        crypt_file(encrypted,decrypted,phrase,directory/'gpg',True)
        self.assertEqual(hashlib.sha256(source.read_bytes()).digest(),hashlib.sha256(decrypted.read_bytes()).digest())
        with self.assertRaises(GuardError):crypt_file(encrypted,directory/'wrong.dump','different-artificial-'+uuid.uuid4().hex,directory/'gpg',True)
        restore_local(decrypted,{'synthetic':2},['anon','authenticated','service_role'],ROOT)
        self.records.append({'test':self.id(),'operation':'encrypted logical archive / decrypt / isolated restore 2 synthetic rows',
            'passed':True,'limitation':'Не проверяет полный Supabase, владельцев, ACL или managed schemas'})

    def test_preview_backup_bundle_contains_only_encrypted_export(self):
        self.owner('create table public.synthetic_empty(id integer primary key);',self.database)
        db=self.database_adapter();directory=self.directory/self.database;directory.mkdir()
        output=directory/'public-output';phrase='artificial-preview-only-'+uuid.uuid4().hex
        receipt=create_backup(db,inspect(db),phrase,directory,output,ROOT)
        encrypted=output/'snapshot.tar.gpg';decrypted=directory/'independent-check.tar'
        self.assertEqual([p.name for p in output.iterdir()],['snapshot.tar.gpg'])
        self.assertEqual(receipt['encrypted_sha256'],hashlib.sha256(encrypted.read_bytes()).hexdigest())
        self.assertTrue(receipt['decryption_checked'] and receipt['local_restore_checked'])
        self.assertFalse(receipt['full_project_restore_proven'] or receipt['ownership_acl_restore_proven'])
        crypt_file(encrypted,decrypted,phrase,directory/'independent-gpg',True)
        with tarfile.open(decrypted) as archive:
            self.assertEqual(archive.getnames(),['before.dump','manifest.json'])
            manifest=json.load(archive.extractfile('manifest.json'))
        self.assertEqual(manifest['schemas'],['public'])
        self.assertEqual(manifest['public_rows'],{'synthetic_empty':0})
        self.assertTrue(manifest['excluded'])
        self.records.append({'test':self.id(),'operation':'actual preview backup/export/encryption/decryption/offline restore',
            'passed':True,'limitation':'Scoped logical export, ownership/ACL/full project restoration not proven'})


if __name__=='__main__':unittest.main(verbosity=2)
