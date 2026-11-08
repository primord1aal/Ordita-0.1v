"""Real Session Supavisor + PostgreSQL; one network-none namespace, fake data."""
from pathlib import Path
import json
import os
import secrets
import subprocess
import time

from test_b1_timeout import B1Fixture,docker,remove_owned,FAKE_REF,dbtools,ROOT

POOLER_HOST='aws-0-test.pooler.supabase.com'
POOLER_URL='postgresql://postgres.'+FAKE_REF+'@'+POOLER_HOST+':5432/postgres?sslmode=verify-full'


class PoolerFixture(B1Fixture):
    def __init__(self):
        super().__init__()
        self.pooler_cid=None
        self.password='artificial-only-'+secrets.token_hex(16)

    def start(self):
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2',
            '-subj','/CN='+POOLER_HOST,'-addext','subjectAltName=DNS:'+POOLER_HOST+',DNS:localhost,IP:127.0.0.1',
            '-keyout',str(self.path/'key.pem'),'-out',str(self.path/'ca.pem')],check=True,capture_output=True)
        env=dbtools.restricted_process_env();env['POSTGRES_PASSWORD']=self.password
        result=subprocess.run(dbtools.DOCKER+['create','--name','orbita-pooler-pg-'+self.token[:16],
            '--label','orbita.b1.fixture='+self.token,'--network','none',
            '--add-host',POOLER_HOST+':127.0.0.1',
            '--tmpfs','/var/lib/postgresql/data:rw,noexec,nosuid,size=256m',
            '-e','POSTGRES_PASSWORD','-e','POSTGRES_HOST_AUTH_METHOD=scram-sha-256',
            dbtools.LOCK['postgres_image'],'postgres','-p','55432','-c','log_statement=all'],
            env=env,check=True,capture_output=True,text=True)
        self.cid=result.stdout.strip()
        if len(self.cid)!=64:raise AssertionError('Missing exact local PostgreSQL CID')
        docker('cp',str(self.path/'ca.pem'),self.cid+':/tmp/orbita-pooler-ca.pem')
        docker('start',self.cid)
        deadline=time.monotonic()+35
        while True:
            process=docker('exec',self.cid,'cat','/proc/1/comm',check=False)
            ready=docker('exec',self.cid,'pg_isready','-p','55432','-U','postgres',check=False)
            if process.stdout.strip()=='postgres' and ready.returncode==0:break
            if time.monotonic()>deadline:raise AssertionError('Local pooler PostgreSQL did not start')
            time.sleep(.2)
        self.query('create database orbita_pooler_metadata;')
        self.query((ROOT/'supabase/tests/bootstrap_local.sql').read_text())
        seed=self.path/'tenant.exs'
        seed.write_text('''{:ok, _} = Application.ensure_all_started(:supavisor)
{:ok, version} = Supavisor.Helpers.parse_pg_version(Supavisor.Repo.query!("select version()").rows |> hd() |> hd())
params = %{
  "external_id" => System.fetch_env!("POOLER_TENANT_ID"),
  "db_host" => "127.0.0.1", "db_port" => 55432, "db_database" => "postgres",
  "require_user" => true, "upstream_ssl" => false, "ip_version" => "v4",
  "default_max_clients" => 20, "default_pool_size" => 5,
  "default_parameter_status" => %{"server_version" => version},
  "users" => [%{"db_user" => "postgres", "db_password" => System.fetch_env!("POSTGRES_PASSWORD"),
               "mode_type" => "session", "pool_size" => 5, "is_manager" => true}]
}
{:ok, _} = Supavisor.Tenants.create_tenant(params)
''')
        env.update(DATABASE_URL='ecto://postgres:'+self.password+'@127.0.0.1:55432/orbita_pooler_metadata',
            SECRET_KEY_BASE=secrets.token_hex(32),VAULT_ENC_KEY=secrets.token_hex(16),
            API_JWT_SECRET=secrets.token_hex(32),METRICS_JWT_SECRET=secrets.token_hex(32),
            REGION='orbita_local',PORT='4000',DB_POOL_SIZE='2',POOLER_TENANT_ID=FAKE_REF,NODE_IP='127.0.0.1',
            GLOBAL_DOWNSTREAM_CERT_PATH='/tmp/orbita-pooler-ca.pem',
            GLOBAL_DOWNSTREAM_KEY_PATH='/tmp/orbita-pooler-key.pem',ERL_FLAGS='+S 2:2')
        args=dbtools.DOCKER+['create','--name','orbita-session-pooler-'+self.token[:16],
            '--label','orbita.pooler.fixture='+self.token,'--network','container:'+self.cid]
        for key in ['DATABASE_URL','POSTGRES_PASSWORD','SECRET_KEY_BASE','VAULT_ENC_KEY','API_JWT_SECRET',
                    'METRICS_JWT_SECRET','REGION','PORT','DB_POOL_SIZE','POOLER_TENANT_ID',
                    'GLOBAL_DOWNSTREAM_CERT_PATH','GLOBAL_DOWNSTREAM_KEY_PATH','ERL_FLAGS','NODE_IP']:
            args+=['--env',key]
        args+=['--entrypoint','/bin/sh',dbtools.LOCK['test_pooler_image'],'-c',
               '/app/bin/migrate && /app/bin/supavisor eval "$(cat /tmp/orbita-tenant.exs)" && exec /app/bin/server']
        result=subprocess.run(args,env=env,check=True,capture_output=True,text=True)
        self.pooler_cid=result.stdout.strip()
        if len(self.pooler_cid)!=64:raise AssertionError('Missing exact owned Supavisor CID')
        for source,target in [(seed,'/tmp/orbita-tenant.exs'),(self.path/'ca.pem','/tmp/orbita-pooler-ca.pem'),
                              (self.path/'key.pem','/tmp/orbita-pooler-key.pem')]:
            docker('cp',str(source),self.pooler_cid+':'+target)
        docker('start',self.pooler_cid)
        deadline=time.monotonic()+55
        while True:
            result=self.pooler_query('select 1;',check=False)
            if result.returncode==0 and result.stdout.strip()=='1':return
            if time.monotonic()>deadline:
                # Contains synthetic local credentials only; never collected from cloud.
                log=docker('logs','--tail','40',self.pooler_cid,check=False)
                (self.path/'startup.log').write_text(log.stdout+log.stderr)
                raise AssertionError('Isolated Supavisor did not become ready; see private fixture startup.log')
            time.sleep(.3)

    def query(self,sql):
        return docker('exec','-i',self.cid,'psql','-X','-Atq','-v','ON_ERROR_STOP=1',
                      '-p','55432','-U','postgres','-d','postgres',input=sql).stdout.strip()

    def pooler_query(self,sql,*,options=None,target_attrs=None,check=True,timeout=15):
        args=['exec','-i','-e','PGPASSWORD='+self.password]
        if options is not None:args+=['-e','PGOPTIONS='+options]
        if target_attrs is not None:args+=['-e','PGTARGETSESSIONATTRS='+target_attrs]
        url='postgresql://postgres.'+FAKE_REF+'@localhost:5432/postgres?sslmode=verify-full&sslrootcert=/tmp/orbita-pooler-ca.pem'
        return docker(*args,self.cid,'psql','-X','-Atq','-v','ON_ERROR_STOP=1','--dbname',url,
                      input=sql,timeout=timeout,check=check)

    def close(self):
        if self.pooler_cid:remove_owned(self.pooler_cid,'orbita.pooler.fixture',self.token)
        super().close()
