"""Fixed read-only export and encrypted packaging; no migration/restore operation."""
from pathlib import Path
import hashlib
import json
import os
import re
import resource
import selectors
import subprocess
import tarfile
import tempfile
import time

PROJECT = 'fjqghohhohgvwlmefdmo'
FORBIDDEN = 'swrvjwlwxeaecdhnzkjv'
REPOSITORY = 'primord1aal/Ordita-0.1v'
BRANCH = 'refs/heads/codex/orbita-flutter-design-integration'
READER = 'orbita_backup_reader'
SCHEMAS = ('auth', 'public', 'orbita_mobile_private', 'supabase_migrations')
PG_BIN = Path('/usr/lib/postgresql/17/bin')
LIMIT = 64 * 1024 * 1024
WRITE_LO = ('lo_create', 'lo_creat', 'lo_from_bytea', 'lo_put', 'lo_unlink',
            'lowrite', 'lo_import', 'lo_export', 'lo_truncate', 'lo_truncate64')
SCHEMA_SQL = "'auth','public','orbita_mobile_private','supabase_migrations'"


class BackupError(Exception):
    """Only fixed categories, never server/client error text."""


def require(condition, category):
    if not condition:
        raise BackupError(category)


def child_env():
    return {'PATH': os.defpath, 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8'}


def run(args, *, env=None, data=None, timeout=120, limit_file=False):
    require(Path(args[0]).name in ('git', 'gpg', 'pg_dump', 'pg_restore'), 'PROGRAM_REJECTED')
    try:
        result = subprocess.run(args, input=data, capture_output=True,
                                env=env or child_env(), timeout=timeout,
                                preexec_fn=(lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (LIMIT, LIMIT)))
                                if limit_file else None)
    except (OSError, subprocess.SubprocessError):
        raise BackupError('CLIENT_FAILED') from None
    require(result.returncode == 0, 'CLIENT_FAILED')
    require(len(result.stdout) <= LIMIT, 'RESULT_TOO_LARGE')
    return result.stdout


def validate_source(env, root):
    require(env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'MANUAL_ONLY')
    require(env.get('GITHUB_REPOSITORY') == REPOSITORY and env.get('GITHUB_REF') == BRANCH,
            'SOURCE_REJECTED')
    require(env.get('GITHUB_ACTOR') == 'primord1aal' and
            env.get('GITHUB_TRIGGERING_ACTOR') == 'primord1aal', 'OWNER_ONLY')
    require(env.get('GITHUB_RUN_ATTEMPT') == '1', 'NO_RETRY')
    sha = env.get('GITHUB_SHA', '')
    require(re.fullmatch('[a-f0-9]{40}', sha) is not None and
            env.get('ORBITA_BACKUP_APPROVED_SHA') == sha, 'SHA_REJECTED')
    require(env.get('ORBITA_BACKUP_PROJECT_REF') == PROJECT and PROJECT != FORBIDDEN,
            'PROJECT_REJECTED')
    require(env.get('ORBITA_BACKUP_CONFIRMATION') == 'BACKUP_ONLY', 'CONFIRMATION_REQUIRED')
    require(re.fullmatch('[0-9]+', env.get('GITHUB_RUN_ID', '')) is not None, 'RUN_ID_REJECTED')
    actual = run(['git', '-C', str(root), 'rev-parse', 'HEAD']).decode().strip()
    require(actual == sha and not run(['git', '-C', str(root), 'status', '--porcelain']).strip(),
            'CHECKOUT_REJECTED')


def connection_env(password, ca):
    require(len(password) >= 16 and not any(c in password for c in '\x00\r\n'),
            'READER_PASSWORD_REQUIRED')
    env = child_env()
    env.update(PGHOST='aws-0-eu-north-1.pooler.supabase.com', PGPORT='5432',
               PGDATABASE='postgres', PGUSER=READER + '.' + PROJECT, PGPASSWORD=password,
               PGSSLMODE='verify-full', PGSSLROOTCERT=str(ca), PGCONNECT_TIMEOUT='10',
               PGPASSFILE='/dev/null', PGAPPNAME='orbita_current_backup',
               PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=30000 '
                         '-c lock_timeout=5000 -c idle_in_transaction_session_timeout=180000')
    # No PGTARGETSESSIONATTRS: session poolers can reject that startup probe.
    return env


class ReadSession:
    """One held REPEATABLE READ READ ONLY transaction for manifest + exported snapshot."""
    def __init__(self, env, pg_bin=PG_BIN):
        self.env, self.pg_bin = env, Path(pg_bin)

    def __enter__(self):
        self.errors = tempfile.TemporaryFile()
        self.process = subprocess.Popen(
            [str(self.pg_bin / 'psql'), '-X', '--no-password', '-Atq',
             '--set=ON_ERROR_STOP=1'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.errors, env=self.env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            self._exchange("BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY; "
                           "SET LOCAL statement_timeout=30000; SET LOCAL lock_timeout=5000; "
                           "SET LOCAL idle_in_transaction_session_timeout=180000; "
                           "SET LOCAL search_path=pg_catalog; SET LOCAL TimeZone='UTC'; "
                           "SET LOCAL datestyle='ISO, YMD'; SET LOCAL bytea_output='hex';")
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def _exchange(self, statement):
        marker = b'ORBITA_BACKUP_QUERY_FINISHED'
        try:
            self.process.stdin.write(statement.encode() + b'\n\\echo ' + marker + b'\n')
            self.process.stdin.flush()
            chunks, size, deadline = [], 0, time.monotonic() + 40
            while True:
                require(self.selector.select(max(0, deadline - time.monotonic())), 'QUERY_TIMEOUT')
                chunk = os.read(self.process.stdout.fileno(), 65536)
                require(bool(chunk), 'SOURCE_QUERY_FAILED')
                chunks.append(chunk); size += len(chunk)
                require(size <= 8 * 1024 * 1024, 'MANIFEST_TOO_LARGE')
                raw = b''.join(chunks)
                if raw.endswith(marker + b'\n'):
                    return raw[:-len(marker)-1].strip().decode()
                require(time.monotonic() < deadline, 'QUERY_TIMEOUT')
        except (OSError, ValueError):
            raise BackupError('SOURCE_QUERY_FAILED') from None

    def select(self, sql):
        require(sql.startswith('SELECT ') and not any(v in sql for v in (';', '\\', '--', '/*')),
                'QUERY_REJECTED')
        return self._exchange(sql + ';')

    def __exit__(self, *_):
        try:
            if self.process.poll() is None:
                try:
                    self.process.stdin.write(b'ROLLBACK;\n\\q\n'); self.process.stdin.flush()
                    self.process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    self.process.kill(); self.process.wait(timeout=5)
        finally:
            self.selector.close(); self.errors.close()
            self.process.stdin.close(); self.process.stdout.close()


PREFLIGHT_SQL = """SELECT json_build_object(
 'current_user', current_user, 'session_user', session_user,
 'read_only', current_setting('transaction_read_only'),
 'default_read_only', current_setting('default_transaction_read_only'),
 'version', current_setting('server_version_num')::int,
 'tls', coalesce((SELECT ssl FROM pg_catalog.pg_stat_ssl WHERE pid=pg_backend_pid()),false),
 'role', (SELECT json_build_object('super',rolsuper,'createdb',rolcreatedb,
   'createrole',rolcreaterole,'replication',rolreplication,'inherit',rolinherit,
   'bypassrls',rolbypassrls,'login',rolcanlogin,
   'default_ro',coalesce(rolconfig @> ARRAY['default_transaction_read_only=on'],false))
   FROM pg_catalog.pg_roles WHERE rolname=current_user),
 'memberships',(SELECT count(*) FROM pg_catalog.pg_auth_members
   WHERE member=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user)),
 'database_write',has_database_privilege(current_database(),'CREATE,TEMP'),
 'ownership',(SELECT count(*) FROM pg_catalog.pg_shdepend d
   WHERE d.deptype='o' AND d.refclassid='pg_catalog.pg_authid'::regclass
   AND d.refobjid=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user)),
 'schema_create',(SELECT count(*) FROM pg_catalog.pg_namespace n
   WHERE has_schema_privilege(n.oid,'CREATE')),
 'scoped_schemas',(SELECT count(*) FROM pg_catalog.pg_namespace n
   WHERE n.nspname IN ({schemas}) AND has_schema_privilege(n.oid,'USAGE')),
 'table_writes',(SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
   WHERE left(n.nspname,3)<>'pg_' AND n.nspname<>'information_schema' AND c.relkind IN ('r','p','v','m','f')
   AND (has_table_privilege(c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
     OR EXISTS(SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
       AND has_column_privilege(c.oid,a.attnum,'INSERT,UPDATE,REFERENCES')))),
 'sequence_writes',(SELECT count(*) FROM pg_catalog.pg_class c WHERE c.relkind='S'
   AND CASE WHEN c.relkind='S' THEN has_sequence_privilege(c.oid,'USAGE,UPDATE') ELSE false END),
 'missing_reads',(SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname IN ({schemas}) AND c.relkind IN ('r','p','m','v','S') AND
   CASE WHEN c.relkind='S' THEN NOT has_sequence_privilege(c.oid,'SELECT')
   ELSE NOT has_table_privilege(c.oid,'SELECT') END),
 'outside_reads',(SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
   WHERE left(n.nspname,3)<>'pg_' AND n.nspname<>'information_schema' AND n.nspname NOT IN ({schemas})
   AND c.relkind IN ('r','p','m','v','S') AND has_schema_privilege(n.oid,'USAGE')
   AND CASE WHEN c.relkind='S' THEN has_sequence_privilege(c.oid,'SELECT') ELSE has_table_privilege(c.oid,'SELECT') END),
 'definers',(SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
   WHERE p.prosecdef AND p.prorettype NOT IN ('pg_catalog.trigger'::regtype,'pg_catalog.event_trigger'::regtype)
   AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE')),
 'large_object_writes',(SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='pg_catalog' AND p.proname IN ({large_objects}) AND has_function_privilege(p.oid,'EXECUTE')),
 'extension_side_effects',(SELECT count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname<>'pg_catalog' AND p.provolatile='v'
   AND p.prorettype NOT IN ('pg_catalog.trigger'::regtype,'pg_catalog.event_trigger'::regtype)
   AND has_schema_privilege(n.oid,'USAGE') AND has_function_privilege(p.oid,'EXECUTE')),
 'grant_options',(SELECT count(*) FROM (
   SELECT a.* FROM pg_catalog.pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a UNION ALL
   SELECT a.* FROM pg_catalog.pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a UNION ALL
   SELECT a.* FROM pg_catalog.pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a) a
   WHERE a.is_grantable AND a.grantee IN (0,(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user)))
)""".format(schemas=SCHEMA_SQL, large_objects=','.join("'"+v+"'" for v in WRITE_LO))


def validate_facts(facts, *, require_tls=True):
    require(facts['current_user'] == facts['session_user'] == READER, 'READER_IDENTITY_REJECTED')
    require(facts['read_only'] == facts['default_read_only'] == 'on', 'READ_ONLY_REJECTED')
    require(170000 <= facts['version'] < 180000, 'POSTGRES_VERSION_REJECTED')
    require(not require_tls or facts['tls'] is True, 'TLS_REQUIRED')
    role = facts['role']
    require(role['bypassrls'] and role['login'] and role['default_ro'], 'COMPLETE_READER_REQUIRED')
    require(not any(role[k] for k in ('super','createdb','createrole','replication','inherit')),
            'ADMIN_ROLE_REJECTED')
    require(facts['scoped_schemas'] == len(SCHEMAS) and facts['missing_reads'] == 0,
            'INCOMPLETE_SCOPE')
    for key in ('memberships','database_write','ownership','schema_create','table_writes',
                'sequence_writes','outside_reads','definers','large_object_writes',
                'extension_side_effects','grant_options'):
        require(not facts[key], 'UNSAFE_READER_PRIVILEGES')


def identifier(value):
    require(re.fullmatch('[A-Za-z_][A-Za-z0-9_$]{0,62}', value) is not None,
            'UNSUPPORTED_OBJECT_NAME')
    return '"' + value + '"'


def table_fingerprint(session, schema, name):
    table = identifier(schema) + '.' + identifier(name)
    return json.loads(session.select("SELECT json_build_object('rows',count(*),'sha256',"
        "encode(sha256(convert_to(coalesce(string_agg(row_to_json(t)::text,chr(10) "
        "ORDER BY row_to_json(t)::text COLLATE \"C\"),''),'UTF8')),'hex')) FROM ONLY " + table + ' t'))


CATALOG_SQL = """SELECT json_build_object(
 'tables',(SELECT coalesce(json_agg(json_build_object('schema',n.nspname,'name',c.relname,'kind',c.relkind)
   ORDER BY n.nspname,c.relname),'[]') FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname IN ({schemas}) AND c.relkind IN ('r','p','m','v','S')),
 'roles',(SELECT json_agg(rolname ORDER BY rolname) FROM pg_catalog.pg_roles),
 'extensions',(SELECT json_agg(json_build_object('name',e.extname,'version',e.extversion,'schema',n.nspname))
   FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid=e.extnamespace),
 'event_triggers',(SELECT coalesce(json_agg(json_build_object('name',e.evtname,'event',e.evtevent,
   'enabled',e.evtenabled,'tags',e.evttags,'owner',pg_get_userbyid(e.evtowner),
   'function',e.evtfoid::regprocedure::text)),'[]') FROM pg_catalog.pg_event_trigger e),
 'history',(SELECT coalesce(json_agg(version ORDER BY version),'[]') FROM supabase_migrations.schema_migrations)
)""".format(schemas=SCHEMA_SQL)


def export(session, pg_bin, destination, *, require_tls=True):
    facts = json.loads(session.select(PREFLIGHT_SQL)); validate_facts(facts, require_tls=require_tls)
    require(run([str(Path(pg_bin)/'pg_dump'), '--version']).startswith(b'pg_dump (PostgreSQL) 17.'),
            'CLIENT_VERSION_REJECTED')
    catalog = json.loads(session.select(CATALOG_SQL))
    manifest = {'format':'orbita-current-backup-v1','schemas':list(SCHEMAS),'catalog':catalog,
                'tables':{},'sequences':{},'full_project_restore_proven':False,
                'excluded':['Storage objects','other schemas and external dependencies',
                            'cluster passwords/memberships/settings','Auth/API/JWT/SMTP settings'],
                'event_triggers_require_separate_local_review':True}
    # Sequence state is not MVCC-versioned, unlike table rows in the exported snapshot.
    manifest['sequence_state_is_not_transactionally_consistent'] = True
    for table in catalog['tables']:
        schema, name, kind = table['schema'], table['name'], table['kind']
        if kind in ('r','m'):
            manifest['tables'][schema+'.'+name] = table_fingerprint(session,schema,name)
        elif kind == 'S':
            manifest['sequences'][schema+'.'+name] = json.loads(session.select(
                "SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM " +
                identifier(schema)+'.'+identifier(name)))
    snapshot = session.select('SELECT pg_export_snapshot()')
    require(re.fullmatch('[A-Fa-f0-9]+-[A-Fa-f0-9]+-[0-9]+', snapshot) is not None,
            'SNAPSHOT_REJECTED')
    destination = Path(destination)
    args = [str(Path(pg_bin)/'pg_dump'),'--no-password','--format=custom','--strict-names',
            '--lock-wait-timeout=5000','--snapshot='+snapshot,'--file='+str(destination)]
    args += ['--schema='+schema for schema in SCHEMAS]
    run(args,env=session.env,limit_file=True)
    require(destination.is_file() and 0 < destination.stat().st_size <= LIMIT, 'DUMP_SIZE_REJECTED')
    run([str(Path(pg_bin)/'pg_restore'),'--list',str(destination)])
    manifest['dump_sha256'] = hashlib.sha256(destination.read_bytes()).hexdigest()
    manifest['source_read_only_confirmed'] = session.select("SELECT current_setting('transaction_read_only')") == 'on'
    require(manifest['source_read_only_confirmed'], 'READ_ONLY_REJECTED')
    return manifest


def crypt(source, target, phrase, home, *, decrypt=False):
    require(len(phrase) >= 24 and not any(c in phrase for c in '\x00\r\n'), 'BACKUP_PHRASE_REQUIRED')
    Path(home).mkdir(mode=0o700,exist_ok=True)
    args = ['gpg','--no-options','--homedir',str(home),'--batch','--yes','--pinentry-mode','loopback',
            '--no-symkey-cache','--passphrase-fd','0','--output',str(target)]
    args += ['--decrypt'] if decrypt else ['--symmetric','--cipher-algo','AES256','--s2k-digest-algo','SHA256']
    run(args+[str(source)],data=phrase.encode())


def package(dump, manifest, phrase, temporary, output, source_sha, run_id):
    temporary, output = Path(temporary), Path(output)
    raw_manifest = temporary/'manifest.json'
    raw_manifest.write_text(json.dumps(manifest,ensure_ascii=False,sort_keys=True)+'\n')
    payload = temporary/'snapshot.tar'
    with tarfile.open(payload,'w') as archive:
        archive.add(dump,arcname='database.dump'); archive.add(raw_manifest,arcname='manifest.json')
    require(payload.stat().st_size <= LIMIT, 'PAYLOAD_TOO_LARGE')
    encrypted, verified = temporary/'snapshot.tar.gpg', temporary/'verified.tar'
    crypt(payload,encrypted,phrase,temporary/'gpg')
    crypt(encrypted,verified,phrase,temporary/'gpg',decrypt=True)
    require(hashlib.sha256(payload.read_bytes()).digest() == hashlib.sha256(verified.read_bytes()).digest(),
            'DECRYPTION_MISMATCH')
    with tarfile.open(verified) as archive:
        require(archive.getnames() == ['database.dump','manifest.json'], 'PAYLOAD_REJECTED')
        require(hashlib.sha256(archive.extractfile('database.dump').read()).hexdigest() == manifest['dump_sha256'],
                'DUMP_CHECKSUM_MISMATCH')
    output.mkdir(mode=0o700,parents=True,exist_ok=False)
    cipher = output/'snapshot.tar.gpg'; cipher.write_bytes(encrypted.read_bytes()); cipher.chmod(0o600)
    digest = hashlib.sha256(cipher.read_bytes()).hexdigest()
    (output/'SHA256SUMS').write_text(digest+'  snapshot.tar.gpg\n')
    receipt = {'format':'orbita-current-backup-v1','status':'encrypted_export_verified',
               'source_sha':source_sha,'run_id':run_id,'schemas':list(SCHEMAS),
               'encrypted_sha256':digest,'decryption_checked':True,'dump_catalog_checked':True,
               'isolated_restore_checked':False,'full_project_restore_proven':False}
    (output/'receipt.json').write_text(json.dumps(receipt,sort_keys=True)+'\n')
    require({p.name for p in output.iterdir()} == {'snapshot.tar.gpg','SHA256SUMS','receipt.json'},
            'OUTPUT_REJECTED')
    return receipt
