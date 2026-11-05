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
import time
import uuid

from dbtools import DOCKER,checked,public_rows
from policy import LOCK,require,GuardError


def crypt_file(source,destination,passphrase,home,decrypt=False):
    require(len(passphrase)>=24 and '\n' not in passphrase and '\x00' not in passphrase,
            'Для снимка нужна отдельная длинная секретная фраза.')
    env=os.environ.copy();env['GNUPGHOME']=str(home)
    Path(home).mkdir(mode=0o700,exist_ok=True)
    args=['gpg','--batch','--yes','--pinentry-mode','loopback','--passphrase-fd','0','--output',str(destination)]
    args+=['--decrypt'] if decrypt else ['--symmetric','--cipher-algo','AES256','--s2k-digest-algo','SHA256']
    checked(args+[str(source)],input=passphrase.encode(),env=env)


def restore_local(dump_file,expected_rows,roles,root):
    """Только одноразовый --network none; владельцы/ACL не доказываются этим тестом."""
    container='orbita-restore-'+uuid.uuid4().hex[:12]
    try:
        checked(DOCKER+['run','--detach','--rm','--name',container,'--network','none',
            '--tmpfs','/var/lib/postgresql/data:rw,noexec,nosuid,size=256m',
            '-e','POSTGRES_HOST_AUTH_METHOD=trust','-e','POSTGRES_DB=restore',LOCK['postgres_image']])
        deadline=time.monotonic()+35
        while True:
            process=subprocess.run(DOCKER+['exec',container,'cat','/proc/1/comm'],capture_output=True,text=True)
            ready=subprocess.run(DOCKER+['exec',container,'pg_isready','-U','postgres'],capture_output=True)
            if process.stdout.strip()=='postgres' and ready.returncode==0:break
            require(time.monotonic()<deadline,'Локальная проверка восстановления не запустилась.')
            time.sleep(.2)
        prefix=DOCKER+['exec','-i',container,'psql','-X','-Atq','-v','ON_ERROR_STOP=1','-U','postgres','-d','restore']
        # Минимальные зависимости Supabase только в одноразовой БД, не реальный Auth.
        checked(prefix,input=(Path(root)/'supabase/tests/bootstrap_local.sql').read_bytes())
        existing=set(json.loads(checked(prefix,input=b"select json_agg(rolname) from pg_roles;").decode()))
        for role in roles:
            if role not in existing:
                identifier='"'+role.replace('"','""')+'"'
                checked(prefix,input=('create role '+identifier+' nologin nosuperuser nobypassrls;').encode())
        checked(prefix,input=b'drop schema public cascade;')
        checked(DOCKER+['cp',str(dump_file),container+':/tmp/backup.dump'])
        checked(DOCKER+['exec',container,'pg_restore','--exit-on-error','--no-owner',
            '--no-privileges','--username','postgres','--dbname','restore','/tmp/backup.dump'],timeout=90)
        for table,count in expected_rows.items():
            identifier='"'+table.replace('"','""')+'"'
            actual=checked(prefix,input=('select count(*) from public.'+identifier+';').encode()).decode().strip()
            require(int(actual)==count,'Число строк после локального восстановления не совпало.')
        actual_names=json.loads(checked(prefix,input=b"select coalesce(json_agg(tablename order by tablename),'[]') from pg_tables where schemaname='public';").decode())
        require(set(actual_names)==set(expected_rows),'Состав таблиц после восстановления не совпал.')
    finally:
        subprocess.run(DOCKER+['rm','-f',container],capture_output=True)


def create_backup(db,state,passphrase,temporary,output_dir,root):
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
    restore_local(dump_file,rows,roles,root)
    return {'schemas':schemas,'encrypted_sha256':hashlib.sha256(encrypted.read_bytes()).hexdigest(),
        'decryption_checked':True,'local_restore_checked':True,
        'restore_scope':'public tables/DDL and row counts, disposable PostgreSQL with Auth model',
        'full_project_restore_proven':False,'ownership_acl_restore_proven':False,
        'exclusions':manifest['excluded']}
