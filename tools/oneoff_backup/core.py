"""One-off broad-read profile with encrypted handoff and mandatory isolated restore.

Reuses the existing strict backup's session, fingerprint and crypto primitives.
Its credential profile is deliberately separate: pg_read_all_data and PUBLIC
privileges require an explicit owner acknowledgement, never a strict-role claim.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

from tools.current_backup import backup as base
from tools.orders_migration.catalog import catalog_sql

READER = 'orbita_oneoff_backup_reader'
BRANCH = 'refs/heads/codex/orbita-oneoff-backup-preparation-20261116'
ENVIRONMENT = 'orbita-mobile-test-oneoff-backup'
ACK = 'ACK_BROAD_READ_AND_PUBLIC_PRIVILEGES'
IMAGE = 'postgres@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5'
SCOPED_CATALOG_SQL = 'SELECT' + catalog_sql()[6:]
PROFILE_SQL = """SELECT json_build_object(
 'members',(SELECT coalesce(json_agg(json_build_object('name',r.rolname,'inherit',m.inherit_option,
   'set',m.set_option,'admin',m.admin_option) ORDER BY r.rolname),'[]') FROM pg_catalog.pg_auth_members m
   JOIN pg_catalog.pg_roles r ON r.oid=m.roleid WHERE m.member=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user)),
 'expires_soon',(SELECT rolvaliduntil>clock_timestamp() AND rolvaliduntil<=clock_timestamp()+interval '65 minutes'
   FROM pg_catalog.pg_roles WHERE rolname=current_user),
 'connection_limit',(SELECT rolconnlimit FROM pg_catalog.pg_roles WHERE rolname=current_user),
 'database_create',has_database_privilege(current_database(),'CREATE'),
 'direct_function_grants',(SELECT count(*) FROM pg_catalog.pg_proc p
   CROSS JOIN LATERAL aclexplode(p.proacl) a
   WHERE a.grantee=(SELECT oid FROM pg_catalog.pg_roles WHERE rolname=current_user)),
 'scope_writes',(SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname IN ('auth','public','orbita_mobile_private','supabase_migrations')
   AND c.relkind IN ('r','p','m','v','f') AND
   (has_table_privilege(c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN') OR EXISTS(
    SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
     AND has_column_privilege(c.oid,a.attnum,'INSERT,UPDATE,REFERENCES')))),
 'scope_sequence_writes',(SELECT count(*) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname IN ('auth','public','orbita_mobile_private','supabase_migrations') AND c.relkind='S'
   AND CASE WHEN c.relkind='S' THEN has_sequence_privilege(c.oid,'USAGE,UPDATE') ELSE false END),
 'large_objects',(SELECT count(*) FROM pg_catalog.pg_largeobject_metadata)
)"""


def require(condition, category):
    base.require(condition, category)


def source(env, root):
    require(env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch', 'MANUAL_ONLY')
    require(env.get('GITHUB_REPOSITORY') == base.REPOSITORY and env.get('GITHUB_REF') == BRANCH, 'SOURCE_REJECTED')
    require(env.get('GITHUB_ACTOR') == env.get('GITHUB_TRIGGERING_ACTOR') == 'primord1aal', 'OWNER_ONLY')
    require(env.get('GITHUB_RUN_ATTEMPT') == '1', 'NO_RETRY')
    sha = env.get('GITHUB_SHA', '')
    require(re.fullmatch('[a-f0-9]{40}', sha) and env.get('ORBITA_ONEOFF_APPROVED_SHA') == sha, 'SHA_REJECTED')
    require(env.get('ORBITA_ONEOFF_PROJECT_REF') == base.PROJECT and base.PROJECT != base.FORBIDDEN, 'PROJECT_REJECTED')
    require(env.get('ORBITA_ONEOFF_ACK') == ACK, 'BROAD_PROFILE_NOT_APPROVED')
    git = ['git', '-c', 'safe.directory='+str(root), '-C', str(root)]
    try:
        actual = base.run(git+['rev-parse','HEAD']).decode().strip()
    except base.BackupError as error:
        if str(error) == 'CLIENT_FAILED':
            raise base.BackupError('SOURCE_GIT_HEAD_CLIENT_FAILED') from None
        raise
    require(actual == sha, 'CHECKOUT_REJECTED')
    try:
        status = base.run(git+['status','--porcelain']).strip()
    except base.BackupError as error:
        if str(error) == 'CLIENT_FAILED':
            raise base.BackupError('SOURCE_GIT_STATUS_CLIENT_FAILED') from None
        raise
    require(not status, 'CHECKOUT_REJECTED')
    return sha


def github(path, env):
    token = env.get('GITHUB_TOKEN', '')
    require(bool(token), 'GITHUB_METADATA_REQUIRED')
    try:
        request = urllib.request.Request('https://api.github.com/repos/'+base.REPOSITORY+path,
            headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json',
                     'X-GitHub-Api-Version':'2022-11-28'})
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    except Exception:
        raise base.BackupError('GITHUB_PROTECTION_UNCONFIRMED') from None


def gate(env, *, approved=False, request=github):
    name = '/environments/'+ENVIRONMENT
    environment = request(name, env)
    require(environment.get('name') == ENVIRONMENT and isinstance(environment.get('id'),int),
            'ENVIRONMENT_IDENTITY_REJECTED')
    require(environment.get('can_admins_bypass') is False, 'ADMIN_BYPASS_FORBIDDEN')
    policy = environment.get('deployment_branch_policy') or {}
    require(policy == {'protected_branches':False,'custom_branch_policies':True}, 'EXACT_BRANCH_POLICY_REQUIRED')
    reviewers = [rule for rule in environment.get('protection_rules',[]) if rule.get('type') == 'required_reviewers']
    require(len(reviewers)==1 and not reviewers[0].get('prevent_self_review') and
            any(item.get('type')=='User' and item.get('reviewer',{}).get('login')=='primord1aal'
                for item in reviewers[0].get('reviewers',[])), 'OWNER_REVIEW_REQUIRED')
    branches = request(name+'/deployment-branch-policies?per_page=100', env)
    require(branches.get('total_count') == 1 and len(branches.get('branch_policies',[])) == 1 and
            branches['branch_policies'][0].get('name') == BRANCH.removeprefix('refs/heads/') and
            branches['branch_policies'][0].get('type') == 'branch', 'EXACT_BRANCH_POLICY_REQUIRED')
    run_id = env.get('GITHUB_RUN_ID', '')
    require(re.fullmatch('[0-9]+',run_id), 'RUN_ID_REJECTED')
    run = request('/actions/runs/'+run_id, env)
    require(run.get('event')=='workflow_dispatch' and run.get('head_sha')==env.get('GITHUB_SHA') and
            run.get('head_branch')==BRANCH.removeprefix('refs/heads/') and run.get('run_attempt')==1 and
            run.get('path')=='.github/workflows/orbita-oneoff-backup.yml',
            'RUN_METADATA_REJECTED')
    if approved:
        history = request('/actions/runs/'+run_id+'/approvals', env)
        require(any(item.get('state')=='approved' and item.get('user',{}).get('login')=='primord1aal' and
                    any(value.get('name')==ENVIRONMENT and value.get('id')==environment['id']
                        for value in item.get('environments',[]))
                    for item in history), 'ACTUAL_APPROVAL_UNCONFIRMED')


def connection(password, ca):
    env = base.connection_env(password,ca)
    env['PGUSER'] = READER+'.'+base.PROJECT
    env['PGAPPNAME'] = 'orbita_oneoff_backup'
    return env


def validate(facts, profile, *, require_tls=True):
    require(facts['current_user']==facts['session_user']==READER, 'ONEOFF_IDENTITY_REJECTED')
    require(facts['read_only']==facts['default_read_only']=='on', 'READ_ONLY_REJECTED')
    require(170000<=facts['version']<180000, 'POSTGRES_VERSION_REJECTED')
    require(not require_tls or facts['tls'] is True, 'TLS_REQUIRED')
    role = facts['role']
    require(role['login'] and role['inherit'] and role['bypassrls'] and role['default_ro'] and
            not any(role[key] for key in ('super','createdb','createrole','replication')), 'NONADMIN_READER_REQUIRED')
    require(profile['members']==[{'name':'pg_read_all_data','inherit':True,'set':False,'admin':False}], 'READ_MEMBERSHIP_REJECTED')
    require(profile['expires_soon'] is True and profile['connection_limit']==2, 'TEMPORARY_CREDENTIAL_REQUIRED')
    require(facts['scoped_schemas']==4 and facts['missing_reads']==0, 'INCOMPLETE_SCOPE')
    require(not facts['ownership'] and not facts['grant_options'] and not facts['schema_create'] and
            not facts['table_writes'] and not facts['sequence_writes'] and
            not profile['database_create'] and not profile['direct_function_grants'] and
            not profile['scope_writes'] and not profile['scope_sequence_writes'],
            'ADDITIONAL_PRIVILEGES_REJECTED')
    require(profile['large_objects']==0, 'LARGE_OBJECT_SCOPE_REQUIRES_REVIEW')


def _sequence_states(dump, pg_bin, temporary, catalog):
    listing = base.run([str(pg_bin/'pg_restore'),'--list',str(dump)]).decode()
    sequence_lines = [line for line in listing.splitlines() if re.search(r'\bSEQUENCE SET\b',line) and not line.startswith(';')]
    expected = {item['schema']+'.'+item['name'] for item in catalog['tables'] if item['kind']=='S'}
    if not expected:
        require(not sequence_lines, 'SEQUENCE_CATALOG_MISMATCH')
        return {}
    use = temporary/'sequences.list'; use.write_text('\n'.join(sequence_lines)+'\n')
    sql = base.run([str(pg_bin/'pg_restore'),'--use-list='+str(use),'--file=-',str(dump)]).decode()
    states = {}
    for line in sql.splitlines():
        if line.startswith('SELECT pg_catalog.setval('):
            match = re.fullmatch(r"SELECT pg_catalog\.setval\('([A-Za-z_][A-Za-z0-9_$]*\.[A-Za-z_][A-Za-z0-9_$]*)', (-?[0-9]+), (true|false)\);",line)
            require(match is not None and match[1] not in states, 'SEQUENCE_STATE_REJECTED')
            states[match[1]] = {'last_value':int(match[2]),'is_called':match[3]=='true'}
    require(set(states)==expected, 'SEQUENCE_CATALOG_MISMATCH')
    return states


def export(session, pg_bin, dump, temporary, *, require_tls=True):
    facts = json.loads(session.select(base.PREFLIGHT_SQL))
    profile = json.loads(session.select(PROFILE_SQL))
    validate(facts,profile,require_tls=require_tls)
    require(base.run([str(pg_bin/'pg_dump'),'--version']).startswith(b'pg_dump (PostgreSQL) 17.'), 'CLIENT_VERSION_REJECTED')
    catalog = json.loads(session.select(base.CATALOG_SQL))
    manifest = {'format':'orbita-oneoff-backup-v1','project_ref':base.PROJECT,'schemas':list(base.SCHEMAS),'catalog':catalog,
        'scoped_catalog':json.loads(session.select(SCOPED_CATALOG_SQL)), 'tables':{},
        'credential_profile':'broad_read_with_public_residual_privileges','owner_ack':ACK,
        'residual_privileges':{key:facts[key] for key in ('outside_reads','database_write','large_object_writes','definers','extension_side_effects','table_writes')},
        'excluded':['Storage files','other schemas','cluster passwords/memberships/settings',
                    'Auth/API/JWT/SMTP settings','global event trigger installation'],
        'event_triggers_require_separate_local_review':True,'full_project_restore_proven':False}
    manifest['snapshot_transaction_utc'] = session.select("SELECT to_char(transaction_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')")
    for table in catalog['tables']:
        if table['kind'] in ('r','m'):
            manifest['tables'][table['schema']+'.'+table['name']] = base.table_fingerprint(session,table['schema'],table['name'])
    snapshot = session.select('SELECT pg_export_snapshot()')
    require(re.fullmatch('[A-Fa-f0-9]+-[A-Fa-f0-9]+-[0-9]+',snapshot), 'SNAPSHOT_REJECTED')
    base.run([str(pg_bin/'pg_dump'),'--no-password','--format=custom','--strict-names','--no-large-objects',
        '--lock-wait-timeout=5000','--snapshot='+snapshot,'--file='+str(dump)]+
        ['--schema='+value for value in base.SCHEMAS],env=session.env,limit_file=True)
    require(dump.is_file() and 0<dump.stat().st_size<=base.LIMIT, 'DUMP_SIZE_REJECTED')
    manifest['sequences'] = _sequence_states(dump,pg_bin,temporary,catalog)
    manifest['sequence_state_source']='dump; sequences are not MVCC-versioned'
    manifest['dump_sha256']=hashlib.sha256(dump.read_bytes()).hexdigest()
    require(session.select("SELECT current_setting('transaction_read_only')")=='on','READ_ONLY_REJECTED')
    return manifest


def decrypt(staging, phrase, temporary):
    require(staging.is_dir() and not staging.is_symlink() and
            {p.name for p in staging.iterdir()}=={'snapshot.tar.gpg','SHA256SUMS','receipt.json'},'PACKAGE_REJECTED')
    require(all(p.is_file() and not p.is_symlink() for p in staging.iterdir()), 'PACKAGE_REJECTED')
    cipher = staging/'snapshot.tar.gpg'
    digest = hashlib.sha256(cipher.read_bytes()).hexdigest()
    require((staging/'SHA256SUMS').read_text()==digest+'  snapshot.tar.gpg\n','CIPHER_CHECKSUM_MISMATCH')
    receipt = json.loads((staging/'receipt.json').read_text())
    require(receipt.get('encrypted_sha256')==digest,'RECEIPT_CIPHER_MISMATCH')
    plain = temporary/'restored.tar'
    base.crypt(cipher,plain,phrase,temporary/'restore-gpg',decrypt=True)
    require(plain.stat().st_size<=base.LIMIT,'PAYLOAD_TOO_LARGE')
    with tarfile.open(plain) as archive:
        require(archive.getnames()==['database.dump','manifest.json'] and
                all(value.isfile() and value.size<=base.LIMIT for value in archive.getmembers()),'PAYLOAD_REJECTED')
        manifest = json.load(archive.extractfile('manifest.json'))
        dump = temporary/'restored.dump'; dump.write_bytes(archive.extractfile('database.dump').read())
    require(manifest.get('format')=='orbita-oneoff-backup-v1' and manifest.get('schemas')==list(base.SCHEMAS) and
            manifest.get('project_ref')==base.PROJECT and manifest.get('owner_ack')==ACK and
            re.fullmatch('[a-f0-9]{40}',manifest.get('source_sha','')) and
            receipt.get('source_sha')==manifest['source_sha'] and receipt.get('run_id')==manifest.get('run_id') and
            hashlib.sha256(dump.read_bytes()).hexdigest()==manifest['dump_sha256'], 'DUMP_CHECKSUM_MISMATCH')
    return dump, manifest


def _local(args, *, env, sql=None):
    try:
        result = subprocess.run(args,input=sql,text=True,capture_output=True,env=env,check=True,timeout=60)
        return result.stdout.strip()
    except Exception:
        raise base.BackupError('ISOLATED_RESTORE_FAILED') from None


def restore(dump, manifest, temporary, pg_bin):
    data = temporary/'pgdata'
    # Unix socket names have a small platform limit; the archive workdir can
    # be much deeper in an owned local rehearsal. Keep this private and short.
    socket_directory = tempfile.TemporaryDirectory(prefix='orbita-sock-')
    socket = Path(socket_directory.name)
    env = base.child_env()
    ctl = [str(pg_bin/'pg_ctl'),'-D',str(data)]
    psql = [str(pg_bin/'psql'),'-X','-Atq','--set=ON_ERROR_STOP=1','-h',str(socket),'-p','55432','-U','postgres','-d','postgres']
    _local([str(pg_bin/'initdb'),'-D',str(data),'-U','postgres','--auth=trust','--encoding=UTF8','--no-locale',
            '-L',str(pg_bin.parents[3]/'share/postgresql/17')],env=env)
    try:
        _local(ctl+['-l',str(temporary/'postgres.log'),'-o',f"-k {socket} -p 55432 -c listen_addresses='' -c fsync=off",'-w','start'],env=env)
        require(_local(psql,env=env,sql="SELECT current_setting('listen_addresses')='' AND inet_server_addr() IS NULL;")=='t','ISOLATION_REJECTED')
        roles = json.loads(_local(psql,env=env,sql='SELECT json_agg(rolname) FROM pg_roles;'))
        for role in manifest['catalog']['roles']:
            if role not in roles:
                _local(psql,env=env,sql='CREATE ROLE '+base.identifier(role)+' NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;')
        _local(psql,env=env,sql='DROP SCHEMA public;')
        _local([str(pg_bin/'pg_restore'),'--exit-on-error','-h',str(socket),'-p','55432','-U','postgres','-d','postgres',str(dump)],env=env)
        # pg_dump may omit the initdb public ACL. Reconstruct it only locally.
        for name, owner, acl in manifest['scoped_catalog']['schemas']:
            schema = base.identifier(name)
            old = json.loads(_local(psql,env=env,sql="SELECT coalesce(json_agg(DISTINCT CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END),'[]') FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a WHERE n.nspname='"+name+"';"))
            for role in old:
                _local(psql,env=env,sql='REVOKE ALL ON SCHEMA '+schema+' FROM '+('PUBLIC' if role=='PUBLIC' else base.identifier(role))+';')
            for role, grantor, privilege, grantable in acl:
                require(grantor==owner and privilege in ('USAGE','CREATE'),'SCHEMA_ACL_REVIEW_REQUIRED')
                _local(psql,env=env,sql='SET ROLE '+base.identifier(owner)+'; GRANT '+privilege+' ON SCHEMA '+schema+' TO '+
                    ('PUBLIC' if role=='PUBLIC' else base.identifier(role))+(' WITH GRANT OPTION' if grantable else '')+'; RESET ROLE;')
        session_env = dict(env,PGHOST=str(socket),PGPORT='55432',PGDATABASE='postgres',PGUSER='postgres',PGOPTIONS='-c default_transaction_read_only=on')
        with base.ReadSession(session_env,pg_bin) as session:
            require(json.loads(session.select(SCOPED_CATALOG_SQL))==manifest['scoped_catalog'],'RESTORED_CATALOG_MISMATCH')
            for table, expected in manifest['tables'].items():
                schema, name = table.split('.')
                require(base.table_fingerprint(session,schema,name)==expected,'RESTORED_DATA_MISMATCH')
            for sequence, expected in manifest['sequences'].items():
                schema, name = sequence.split('.')
                actual = json.loads(session.select("SELECT json_build_object('last_value',last_value,'is_called',is_called) FROM "+base.identifier(schema)+'.'+base.identifier(name)))
                require(actual==expected,'RESTORED_SEQUENCE_MISMATCH')
    finally:
        try:
            if (data/'postmaster.pid').exists():
                _local(ctl+['-m','immediate','-w','stop'],env=env)
        finally:
            socket_directory.cleanup()


def accept(staging, output, phrase, temporary, pg_bin, *, isolation):
    dump, manifest = decrypt(staging,phrase,temporary)
    restore(dump,manifest,temporary,pg_bin)
    require(not output.exists(),'OUTPUT_ALREADY_EXISTS')
    output.mkdir(mode=0o700)
    for name in ('snapshot.tar.gpg','SHA256SUMS'):
        shutil.copyfile(staging/name,output/name)
    receipt = json.loads((staging/'receipt.json').read_text())
    receipt.update(format='orbita-oneoff-backup-v1',status='logical_restore_verified',
        project_ref=base.PROJECT,
        isolated_restore_checked=True,network_isolation=isolation,
        credential_profile='broad_read_with_public_residual_privileges',global_event_triggers_restored=False)
    (output/'receipt.json').write_text(json.dumps(receipt,sort_keys=True)+'\n')
    return receipt


def isolated_network():
    require({item.name for item in Path('/sys/class/net').iterdir()} <= {'lo'}, 'RESTORE_NETWORK_NOT_ISOLATED')
    require(not any(os.environ.get(key) for key in ('PGPASSWORD','PGPASSFILE','PGSERVICE','SUPABASE_ACCESS_TOKEN',
            'ORBITA_ONEOFF_READER_PASSWORD','GITHUB_TOKEN')), 'RESTORE_CREDENTIALS_REJECTED')
    return 'Docker --network none'
