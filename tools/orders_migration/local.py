"""Disposable Postgres transports. Native is TEST ONLY; cloud restore uses network-none Docker."""
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import uuid
from .admission import require
from dbtools import DOCKER, LOCK as OLD_LOCK, checked, restricted_process_env

class Native:
    network = 'native_test_unix_only'
    def __init__(self, parent=None):
        self.bin = Path(os.environ['ORBITA_ORDERS_PG_BIN']).resolve()
        expected = os.environ['ORBITA_ORDERS_PG_VERSION']
        self.env = restricted_process_env()
        version = checked([str(self.bin/'postgres'),'--version'],env=self.env).decode().strip()
        require(version == expected and version.startswith('postgres (PostgreSQL) 17.'), 'Unverified local PostgreSQL.')
        self.directory = tempfile.TemporaryDirectory(prefix='orbita-order-admission-', dir=parent)
        self.path = Path(self.directory.name)
        self.data=self.path/'data';self.socket=self.path/'socket';self.socket.mkdir(mode=0o700)
        self.started=False
        try:
            checked([str(self.bin/'initdb'),'-D',str(self.data),'-U','postgres','--auth=trust','--encoding=UTF8','--no-locale'],env=self.env)
            checked([str(self.bin/'pg_ctl'),'-D',str(self.data),'-l',str(self.path/'server.log'),'-o',
                f"-k {self.socket} -p 55432 -c listen_addresses='' -c fsync=off",'-w','start'],env=self.env)
            self.started=True
        except BaseException:
            self.close();raise
    def psql(self, sql, role='postgres'):
        result=subprocess.run([str(self.bin/'psql'),'-X','-Atq','-v','ON_ERROR_STOP=1','-h',str(self.socket),'-p','55432','-U',role,'-d','postgres'],
                       input=sql,env=self.env,timeout=60,capture_output=True,text=True)
        self.last_error=result.stderr
        require(result.returncode==0,'Synthetic local SQL failed.')
        return result.stdout.strip()
    def query(self, sql):
        return self.psql("BEGIN READ ONLY; SET LOCAL statement_timeout=30000; SET LOCAL lock_timeout=5000;"+sql.rstrip().rstrip(';')+';ROLLBACK;')
    def execute(self, raw):
        from dbtools import _atomic_write_sql
        return self.psql(_atomic_write_sql(raw,'orbita_orders_local_'+uuid.uuid4().hex[:12],120).decode())
    def dump(self, schemas):
        args=[str(self.bin/'pg_dump'),'-Fc','-h',str(self.socket),'-p','55432','-U','postgres','postgres']
        for schema in schemas:args+=['-n',schema]
        return checked(args,env=self.env,timeout=60)
    def load(self, path):
        checked([str(self.bin/'pg_restore'),'-e','-h',str(self.socket),'-p','55432','-U','postgres','-d','postgres',str(path)],env=self.env,timeout=60)
    def close(self):
        try:
            if self.started:
                checked([str(self.bin/'pg_ctl'),'-D',str(self.data),'-m','immediate','-w','stop'],env=self.env)
                self.started=False
        finally:self.directory.cleanup()

class Docker:
    network = 'none'
    def __init__(self, parent=None):
        self.token=uuid.uuid4().hex;self.cid=None;self.env=restricted_process_env()
        self.directory=tempfile.TemporaryDirectory(prefix='orbita-order-restore-',dir=parent);self.path=Path(self.directory.name)
        try:
            raw=checked(DOCKER+['create','--label','orbita.orders.restore='+self.token,'--network','none',
                '--tmpfs','/var/lib/postgresql/data:rw,noexec,nosuid,size=512m',
                '-e','POSTGRES_HOST_AUTH_METHOD=trust',OLD_LOCK['postgres_image']],env=self.env).decode().strip()
            require(re.fullmatch('[a-f0-9]{64}',raw) is not None,'Exact restore CID required.');self.cid=raw
            self.verify();checked(DOCKER+['start',self.cid],env=self.env)
            import time
            deadline=time.monotonic()+30
            while True:
                p=subprocess.run(DOCKER+['exec',self.cid,'pg_isready','-U','postgres'],capture_output=True,env=self.env)
                if p.returncode==0:break
                require(time.monotonic()<deadline,'Restore start failed.');time.sleep(.2)
        except BaseException:self.close();raise
    def verify(self):
        metadata=json.loads(checked(DOCKER+['inspect',self.cid],env=self.env))[0]
        require(metadata['Id']==self.cid and metadata['Config']['Labels'].get('orbita.orders.restore')==self.token
                and metadata['HostConfig']['NetworkMode']=='none','Unowned or networked restore container.')
    def psql(self,sql):
        self.verify()
        return checked(DOCKER+['exec','-i',self.cid,'psql','-X','-Atq','-v','ON_ERROR_STOP=1','-U','postgres'],input=sql.encode(),env=self.env).decode().strip()
    query=Native.query
    execute=Native.execute
    def load(self,path):
        self.verify();checked(DOCKER+['cp',str(path),self.cid+':/tmp/before.dump'],env=self.env)
        checked(DOCKER+['exec',self.cid,'pg_restore','--exit-on-error','-U','postgres','-d','postgres','/tmp/before.dump'],env=self.env,timeout=120)
    def close(self):
        try:
            if self.cid:
                self.verify();checked(DOCKER+['rm','-f','-v',self.cid],env=self.env);self.cid=None
        finally:self.directory.cleanup()
