"""Encrypted scoped backup, exact logical restore and first→second rehearsal."""
from pathlib import Path
import hashlib
import json
import tarfile
import io
from .admission import LOCK, require
from .catalog import capture, state_hash, protected_hash, validate_before
from .atomic import body
from .local import Docker
from backup import crypt_file  # existing AES256/passphrase-fd implementation, unchanged

LIMIT = 64 * 1024 * 1024

def role_names(db):
    return json.loads(db.query("select json_agg(rolname order by rolname) from pg_roles;"))

def create(db, root, temporary, output, passphrase, factory=Docker):
    require(passphrase != getattr(db,'password',None),'Backup phrase must differ from DB password.')
    temporary=Path(temporary);output=Path(output);output.mkdir(mode=0o700,parents=True,exist_ok=True)
    before=capture(db);validate_before(before)
    before_hash=state_hash(db);protected=protected_hash(db)
    roles=role_names(db)
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
    crypt_file(payload,encrypted,passphrase,temporary/'gpg')
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
    local=factory(temporary)
    try:
        # Empty disposable cluster only; no cloud secrets are forwarded.
        existing=role_names(local)
        for role in roles:
            require(isinstance(role,str) and 0 < len(role) <= 63,'Unexpected SQL role name.')
            if role not in existing:
                local.psql('create role "'+role.replace('"','""')+'" nologin nosuperuser nobypassrls;')
        local.psql('drop schema public cascade;')
        local.load(decrypted)
        # pg_dump treats public's initdb ACL as implicit. Restore its full effective
        # namespace ACL from the encrypted manifest before comparing all metadata.
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
        require(capture(local)==before and state_hash(local)==before_hash,
                'Logical schema/ACL/rows/history did not restore exactly.')
        local.execute(body(root,before_hash))
        require(protected_hash(local)==protected,'Rehearsal changed protected Auth state.')
        after=capture(local)
        require([r['version'] for r in after['history']]==[LOCK['first_version'],LOCK['version']],
                'Rehearsal history differs.')
        require(capture(db)==before and state_hash(db)==before_hash,'Source changed during snapshot/rehearsal.')
        return {'encrypted_sha256':hashlib.sha256(encrypted.read_bytes()).hexdigest(),
                'decryption_checked':True,'restore_checked':True,'rehearsal_checked':True,
                'network':local.network,'scope':LOCK['schemas'],'full_project_restore_proven':False,
                'excluded':['cluster passwords/memberships/settings','Storage files/other schemas','Auth HTTP/JWT signature'],
                'before_versions':[LOCK['first_version']],'after_versions':[LOCK['first_version'],LOCK['version']]}
    finally:
        local.close()
        for path in [dump,decrypted,payload,verified]:
            if path.exists():path.unlink()
