"""Зашифрованный логический снимок и проверка scoped restore без внешней сети.

Не экспортирует Auth/Storage/роли/инфраструктуру и не выполняет restore в облако.
"""
from pathlib import Path
import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import time
import uuid

from dbtools import DOCKER,checked,public_rows,restricted_process_env
from policy import LOCK,require,GuardError
from local_plan import RESTORE_LABEL,verify_restore,cleanup_restore,run_local_plan


def crypt_file(source,destination,passphrase,home,decrypt=False):
    require(len(passphrase)>=24 and '\n' not in passphrase and '\x00' not in passphrase,
            'Для снимка нужна отдельная длинная секретная фраза.')
    env=restricted_process_env();env['GNUPGHOME']=str(home)
    Path(home).mkdir(mode=0o700,exist_ok=True)
    args=['gpg','--batch','--yes','--pinentry-mode','loopback','--passphrase-fd','0','--output',str(destination)]
    args+=['--decrypt'] if decrypt else ['--symmetric','--cipher-algo','AES256','--s2k-digest-algo','SHA256']
    checked(args+[str(source)],input=passphrase.encode(),env=env)


def restore_local(dump_file,expected_rows,roles,root,*,cli_binary=None,expected_versions=None,on_phase=None):
    """Только одноразовый --network none; владельцы/ACL не доказываются этим тестом."""
    token=uuid.uuid4().hex;name='orbita-restore-'+token[:12];container=None
    env=restricted_process_env()
    if on_phase is not None:on_phase('LOCAL_RESTORE')
    with tempfile.TemporaryDirectory(prefix='orbita-local-restore-') as directory:
        directory=Path(directory)
        checked(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2',
            '-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1',
            '-keyout',str(directory/'key.pem'),'-out',str(directory/'ca.pem')],env=env)
        try:
            raw_cid=checked(DOCKER+['create','--name',name,'--label',RESTORE_LABEL+'='+token,'--network','none',
                '--tmpfs','/var/lib/postgresql/data:rw,noexec,nosuid,size=256m',
                '-e','POSTGRES_HOST_AUTH_METHOD=trust','-e','POSTGRES_DB=restore','--entrypoint','sh',LOCK['postgres_image'],
                '-c','chown postgres:postgres /tmp/orbita-restore-key.pem /tmp/orbita-restore-ca.pem; '
                'chmod 600 /tmp/orbita-restore-key.pem; exec docker-entrypoint.sh postgres -c ssl=on '
                '-c ssl_cert_file=/tmp/orbita-restore-ca.pem -c ssl_key_file=/tmp/orbita-restore-key.pem '
                '-c statement_timeout=30000 -c lock_timeout=5000 -c idle_in_transaction_session_timeout=15000'],env=env).decode().strip()
            container=raw_cid if len(raw_cid)==64 and set(raw_cid)<=set('0123456789abcdef') else None
            require(container is not None,'Не получен точный CID локальной копии.')
            verify_restore(container,token)
            for source,target in [(directory/'key.pem','/tmp/orbita-restore-key.pem'),(directory/'ca.pem','/tmp/orbita-restore-ca.pem')]:
                checked(DOCKER+['cp',str(source),container+':'+target],env=env)
            checked(DOCKER+['start',container],env=env)
            deadline=time.monotonic()+35
            while True:
                process=subprocess.run(DOCKER+['exec',container,'cat','/proc/1/comm'],env=env,capture_output=True,text=True)
                ready=subprocess.run(DOCKER+['exec',container,'pg_isready','-U','postgres'],env=env,capture_output=True)
                if process.stdout.strip()=='postgres' and ready.returncode==0:break
                require(time.monotonic()<deadline,'Локальная проверка восстановления не запустилась.')
                time.sleep(.2)
            prefix=DOCKER+['exec','-i',container,'psql','-X','-Atq','-v','ON_ERROR_STOP=1','-U','postgres','-d','restore']
            checked(prefix,input=(Path(root)/'supabase/tests/bootstrap_local.sql').read_bytes(),env=env)
            existing=set(json.loads(checked(prefix,input=b"select json_agg(rolname) from pg_roles;",env=env).decode()))
            for role in roles:
                if role not in existing:
                    identifier='"'+role.replace('"','""')+'"'
                    checked(prefix,input=('create role '+identifier+' nologin nosuperuser nobypassrls;').encode(),env=env)
            checked(prefix,input=b'drop schema public cascade;',env=env)
            checked(DOCKER+['cp',str(dump_file),container+':/tmp/backup.dump'],env=env)
            checked(DOCKER+['exec',container,'pg_restore','--exit-on-error','--no-owner',
                '--no-privileges','--username','postgres','--dbname','restore','/tmp/backup.dump'],env=env,timeout=90)
            for table,count in expected_rows.items():
                identifier='"'+table.replace('"','""')+'"'
                actual=checked(prefix,input=('select count(*) from public.'+identifier+';').encode(),env=env).decode().strip()
                require(int(actual)==count,'Число строк после локального восстановления не совпало.')
            actual_names=json.loads(checked(prefix,input=b"select coalesce(json_agg(tablename order by tablename),'[]') from pg_tables where schemaname='public';",env=env).decode())
            require(set(actual_names)==set(expected_rows),'Состав таблиц после восстановления не совпал.')
            if cli_binary is not None:
                return run_local_plan(container,token,cli_binary,root,expected_versions,directory,on_phase)
        finally:
            cleanup_restore(name,token,container)


def create_backup(db,state,passphrase,temporary,output_dir,root,*,cli_binary=None,on_phase=None):
    temporary=Path(temporary);output_dir=Path(output_dir);output_dir.mkdir(parents=True,exist_ok=True)
    schemas=['public']+(['supabase_migrations'] if state['history_table'] else [])
    rows=public_rows(db)
    # Этот путь намеренно ограничен первой миграцией пустого тестового проекта.
    require(all(count==0 for count in rows.values()),'В публичных таблицах есть данные; нужен отдельный план резервирования.')
    roles=json.loads(db.query("select json_agg(rolname order by rolname) from pg_roles;"))
    auth_triggers=json.loads(db.query("""select coalesce(json_agg(json_build_object('name',t.tgname,
      'definition',pg_get_triggerdef(t.oid)) order by t.tgname),'[]')
      from pg_trigger t where t.tgrelid='auth.users'::regclass and not t.tgisinternal;"""))
    dump_file=temporary/'before.dump';dump_file.write_bytes(db.dump(schemas));dump_file.chmod(0o600)
    payload=temporary/'snapshot.tar'
    manifest={'schemas':schemas,'public_rows':rows,'roles_names_only':roles,'auth_trigger_definitions':auth_triggers,
        'excluded':['managed Auth/Storage data and schemas','cluster roles/passwords/membership',
                    'ownership/ACL verification','storage files','project/Auth/network settings','PITR']}
    with tarfile.open(payload,'w') as archive:
        archive.add(dump_file,arcname='before.dump')
        data=json.dumps(manifest,ensure_ascii=False).encode();entry=tarfile.TarInfo('manifest.json');entry.size=len(data)
        archive.addfile(entry,io.BytesIO(data))
    encrypted=output_dir/'snapshot.tar.gpg'
    crypt_file(payload,encrypted,passphrase,temporary/'gpg')
    decrypted=temporary/'checked.tar'
    crypt_file(encrypted,decrypted,passphrase,temporary/'gpg',True)
    require(hashlib.sha256(payload.read_bytes()).digest()==hashlib.sha256(decrypted.read_bytes()).digest(),
            'Проверка расшифровки снимка не прошла.')
    with tarfile.open(decrypted) as archive:
        require(archive.getnames()==['before.dump','manifest.json'],'Неожиданный состав расшифрованной копии.')
        checked_dump=temporary/'checked-before.dump'
        checked_dump.write_bytes(archive.extractfile('before.dump').read());checked_dump.chmod(0o600)
    plan=restore_local(checked_dump,rows,roles,root,cli_binary=cli_binary,
                       expected_versions=state['versions'],on_phase=on_phase)
    result={'schemas':schemas,'encrypted_sha256':hashlib.sha256(encrypted.read_bytes()).hexdigest(),
        'decryption_checked':True,'local_restore_checked':True,
        'restore_scope':'public tables/DDL and row counts, disposable PostgreSQL with Auth model',
        'full_project_restore_proven':False,'ownership_acl_restore_proven':False,
        'exclusions':manifest['excluded']}
    if plan is not None:result['local_plan']=plan
    return result
