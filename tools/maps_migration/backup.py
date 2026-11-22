"""Encrypted scoped backup, exact logical restore and three→four rehearsal."""
from pathlib import Path
from enum import Enum, auto
import hashlib
import json
import tarfile
import io
from .policy import LOCK, require, versions
from .state import capture, state_hash, protected_hash, validate_before
from .atomic import body
from tools.orders_migration.local import Docker
from tools.orders_migration.host_rls import restore_trigger_in_isolation
from backup import crypt_file  # existing AES256/passphrase-fd implementation, unchanged

LIMIT = 64 * 1024 * 1024

class PreviewPhase(Enum):
    SOURCE_CATALOG = auto()
    SOURCE_BASELINE = auto()
    SOURCE_FINGERPRINT = auto()
    BACKUP_BASELINE = auto()
    SOURCE_DUMP = auto()
    ENCRYPT = auto()
    VERIFY_CIPHERTEXT = auto()
    RESTORE_START = auto()
    RESTORE_ROLES = auto()
    RESTORE_DUMP = auto()
    RESTORE_TRIGGER = auto()
    RESTORE_SCHEMA_ACL = auto()
    COMPARE_RESTORE = auto()
    RESTORED_SCHEMAS = auto()
    RESTORED_RELATIONS = auto()
    RESTORED_FUNCTIONS = auto()
    RESTORED_PROTECTED_CATALOG = auto()
    RESTORED_ROWS_OR_SEQUENCES = auto()
    RESTORED_HISTORY = auto()
    RESTORED_ROLE_SAFETY = auto()
    RESTORED_DEPENDENCIES = auto()
    RESTORED_HOST_RLS = auto()
    RESTORED_STATE_HASH = auto()
    REHEARSE_MAPS = auto()
    CHECK_REHEARSAL = auto()
    RECHECK_SOURCE = auto()
    WRITE_RECEIPT = auto()


def ignore_phase(phase):
    pass


def role_names(db):
    return json.loads(db.query("select json_agg(rolname order by rolname) from pg_roles;"))

def compare_restore(expected, actual, on_phase):
    """Only the fixed section name may leave the private comparison."""
    for key, phase in (('schemas', PreviewPhase.RESTORED_SCHEMAS),
                       ('relations', PreviewPhase.RESTORED_RELATIONS),
                       ('functions', PreviewPhase.RESTORED_FUNCTIONS)):
        on_phase(phase)
        require(actual['catalog'][key] == expected['catalog'][key], 'Restored catalog differs.')
    for key, phase in (('protected_catalog', PreviewPhase.RESTORED_PROTECTED_CATALOG),
                       ('rows', PreviewPhase.RESTORED_ROWS_OR_SEQUENCES),
                       ('history', PreviewPhase.RESTORED_HISTORY),
                       ('client_safe', PreviewPhase.RESTORED_ROLE_SAFETY),
                       ('dependency_ok', PreviewPhase.RESTORED_DEPENDENCIES),
                       ('host_rls', PreviewPhase.RESTORED_HOST_RLS)):
        on_phase(phase)
        require(actual[key] == expected[key], 'Restored state differs.')
    # Includes additional keys even if no specific phase exists for them yet.
    on_phase(PreviewPhase.COMPARE_RESTORE)
    require(actual == expected, 'Restored document differs.')


def create(db, root, temporary, output, passphrase, factory=Docker, *, on_phase=ignore_phase):
    on_phase(PreviewPhase.BACKUP_BASELINE)
    require(passphrase != getattr(db,'password',None),'Backup phrase must differ from DB password.')
    temporary=Path(temporary);temporary.mkdir(mode=0o700,parents=True,exist_ok=True);output=Path(output);output.mkdir(mode=0o700,parents=True,exist_ok=True)
    before=capture(db);validate_before(before)
    before_hash=state_hash(db);protected=protected_hash(db)
    roles=role_names(db)
    on_phase(PreviewPhase.SOURCE_DUMP)
    dump=temporary/'before.dump';dump.write_bytes(db.dump(LOCK['schemas']));dump.chmod(0o600)
    require(dump.stat().st_size < LIMIT,'Scoped backup exceeds reviewed limit.')
    payload=temporary/'payload.tar';verified=temporary/'verified.tar';decrypted=temporary/'verified.dump'
    manifest={'project_ref':LOCK['project_ref'],'sql_sha256':LOCK['sha256'],'before':before,
              'roles_names_only':roles,'dump_sha256':hashlib.sha256(dump.read_bytes()).hexdigest()}
    with tarfile.open(payload,'w') as archive:
        archive.add(dump,arcname='before.dump')
        raw=json.dumps(manifest,ensure_ascii=False).encode();entry=tarfile.TarInfo('manifest.json');entry.size=len(raw)
        archive.addfile(entry,io.BytesIO(raw))
    require(payload.stat().st_size < LIMIT,'Backup archive exceeds reviewed limit.')
    encrypted=output/'snapshot.tar.gpg'
    on_phase(PreviewPhase.ENCRYPT)
    crypt_file(payload,encrypted,passphrase,temporary/'gpg')
    on_phase(PreviewPhase.VERIFY_CIPHERTEXT)
    crypt_file(encrypted,verified,passphrase,temporary/'gpg',True)
    require(hashlib.sha256(payload.read_bytes()).digest()==hashlib.sha256(verified.read_bytes()).digest(),
            'Backup decryption differs.')
    with tarfile.open(verified) as archive:
        require(archive.getnames()==['before.dump','manifest.json'] and all(
            item.isfile() and item.size < LIMIT for item in archive.getmembers()),'Unexpected backup payload.')
        restored_manifest=json.loads(archive.extractfile('manifest.json').read())
        require(restored_manifest==manifest,'Backup manifest differs.')
        decrypted.write_bytes(archive.extractfile('before.dump').read());decrypted.chmod(0o600)
    require(hashlib.sha256(decrypted.read_bytes()).hexdigest()==manifest['dump_sha256'],'Dump checksum differs.')
    on_phase(PreviewPhase.RESTORE_START)
    local=factory(temporary)
    try:
        # Empty disposable cluster only; no cloud secrets are forwarded.
        on_phase(PreviewPhase.RESTORE_ROLES)
        existing=role_names(local)
        for role in roles:
            require(isinstance(role,str) and 0 < len(role) <= 63,'Unexpected SQL role name.')
            if role not in existing:
                local.psql('create role "'+role.replace('"','""')+'" nologin nosuperuser nobypassrls;')
        local.psql('drop schema public cascade;')
        on_phase(PreviewPhase.RESTORE_DUMP)
        local.load(decrypted)
        on_phase(PreviewPhase.RESTORE_TRIGGER)
        restore_trigger_in_isolation(local, manifest['before']['host_rls'])
        # pg_dump treats public's initdb ACL as implicit. Restore its full effective
        # namespace ACL from the encrypted manifest before comparing all metadata.
        on_phase(PreviewPhase.RESTORE_SCHEMA_ACL)
        for name,owner,acl in manifest['before']['catalog']['schemas']:
            ident='"'+name.replace('"','""')+'"'
            actual=json.loads(local.query("select coalesce(json_agg(distinct case when a.grantee=0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end),'[]') from pg_namespace n cross join lateral aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a where n.nspname='"+name.replace("'","''")+"';"))
            for grantee in actual:
                target='PUBLIC' if grantee=='PUBLIC' else '"'+grantee.replace('"','""')+'"'
                local.psql('revoke all on schema '+ident+' from '+target+';')
            for grantee,grantor,privilege,grantable in acl:
                require(grantor==owner and privilege in ('USAGE','CREATE'),'Unreviewed namespace grantor/privilege.')
                target='PUBLIC' if grantee=='PUBLIC' else '"'+grantee.replace('"','""')+'"'
                local.psql('grant '+privilege+' on schema '+ident+' to '+target+(' with grant option' if grantable else '')+';')
        on_phase(PreviewPhase.COMPARE_RESTORE)
        compare_restore(before, capture(local), on_phase)
        on_phase(PreviewPhase.RESTORED_STATE_HASH)
        require(state_hash(local)==before_hash, 'Restored state hash differs.')
        on_phase(PreviewPhase.REHEARSE_MAPS)
        local.execute(body(root,before_hash))
        on_phase(PreviewPhase.CHECK_REHEARSAL)
        require(protected_hash(local)==protected,'Rehearsal changed protected Auth state.')
        after=capture(local)
        require([r['version'] for r in after['history']]==versions()+[LOCK['version']],
                'Rehearsal history differs.')
        on_phase(PreviewPhase.RECHECK_SOURCE)
        require(capture(db)==before and state_hash(db)==before_hash,'Source changed during snapshot/rehearsal.')
        return {'encrypted_sha256':hashlib.sha256(encrypted.read_bytes()).hexdigest(),
                'decryption_checked':True,'restore_checked':True,'rehearsal_checked':True,
                'network':local.network,'scope':LOCK['schemas'],'full_project_restore_proven':False,
                'excluded':['cluster passwords/memberships/settings','Storage files/other schemas','Auth HTTP/JWT signature'],
                'before_versions':versions(),'after_versions':versions()+[LOCK['version']]}
    finally:
        local.close()
        for path in [dump,decrypted,payload,verified]:
            if path.exists():path.unlink()
