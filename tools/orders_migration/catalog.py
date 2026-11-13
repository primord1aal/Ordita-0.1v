"""Portable catalog and row fingerprints: SELECT only, no raw rows leave Postgres."""
import hashlib
import json
from .admission import LOCK, require

APP_REL = ['orbita_profiles', 'orbita_user_roles', 'orbita_account_access', 'orbita_access_audit',
           'orbita_access_audit_id_seq', 'access_mutex']
APP_FUNCTIONS = ['orbita_get_access', 'lock_access', 'active_admins', 'guard_access', 'audit_change',
                 'protect_audit', 'deny_truncate', 'admin_access']
ORDER_FUNCTIONS = ['orbita_create_order', 'orbita_get_order', 'orbita_get_current_order', 'orbita_cancel_order',
                   'order_point', 'order_session_uid', 'order_envelope']

def quoted(values):
    return ','.join("'" + v.replace("'", "''") + "'" for v in values)

def acl_sql(expr, default):
    return "(select coalesce(jsonb_agg(jsonb_build_array(case when qacl.grantee=0 then 'PUBLIC' else pg_get_userbyid(qacl.grantee) end,pg_get_userbyid(qacl.grantor),qacl.privilege_type,qacl.is_grantable) order by qacl.grantee::regrole::text,qacl.grantor::regrole::text,qacl.privilege_type),'[]') from aclexplode(nullif(coalesce(" + expr + ',' + default + "),'{}'::aclitem[])) qacl)"

def catalog_sql(app_only=False, orders_only=False, auth_only=False):
    rel_filter = "n.nspname in ('public','orbita_mobile_private','auth','supabase_migrations')"
    fun_filter = rel_filter
    if app_only:
        rel_filter = "n.nspname in ('public','orbita_mobile_private') and c.relname in (" + quoted(APP_REL) + ')'
        fun_filter = "n.nspname in ('public','orbita_mobile_private') and p.proname in (" + quoted(APP_FUNCTIONS) + ')'
    if orders_only:
        rel_filter = "n.nspname='public' and c.relname='orbita_orders'"
        fun_filter = "n.nspname in ('public','orbita_mobile_private') and p.proname in (" + quoted(ORDER_FUNCTIONS) + ')'
    if auth_only:
        rel_filter = "n.nspname='auth'"
        fun_filter = rel_filter
    # Semantic ACLs/names/definitions rather than OIDs or ACL storage order rather than OIDs: equal after pg_restore.
    schema_filter = "nspname='orbita_mobile_private'" if app_only else ("false" if orders_only else ("nspname='auth'" if auth_only else "nspname in ('auth','public','orbita_mobile_private','supabase_migrations')"))
    return """select jsonb_build_object(
      'schemas',(select coalesce(jsonb_agg(jsonb_build_array(nspname,pg_get_userbyid(nspowner),""" + acl_sql('nspacl',"acldefault('n',nspowner)") + """) order by nspname),'[]') from pg_namespace where """ + schema_filter + """),
      'relations' ,(select coalesce(jsonb_agg(jsonb_build_array(n.nspname,c.relname,c.relkind,
        pg_get_userbyid(c.relowner),""" + acl_sql('c.relacl',"case when c.relkind='S' then acldefault('s',c.relowner) else acldefault('r',c.relowner) end") + """,c.relrowsecurity,c.relforcerowsecurity,
        (select jsonb_agg(jsonb_build_array(a.attname,format_type(a.atttypid,a.atttypmod),a.attnotnull,
          pg_get_expr(d.adbin,d.adrelid),""" + acl_sql('a.attacl',"NULL::aclitem[]") + """) order by a.attnum) from pg_attribute a left join pg_attrdef d
          on d.adrelid=a.attrelid and d.adnum=a.attnum where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped),
        (select jsonb_agg(pg_get_constraintdef(x.oid,true) order by x.conname) from pg_constraint x where x.conrelid=c.oid),
        (select jsonb_agg(pg_get_indexdef(i.indexrelid) order by i.indexrelid::regclass::text) from pg_index i where i.indrelid=c.oid),
        (select jsonb_agg(pg_get_triggerdef(t.oid,true) order by t.tgname) from pg_trigger t where t.tgrelid=c.oid and not t.tgisinternal),
        (select jsonb_agg(jsonb_build_array(pol.polname,pol.polcmd,pol.polpermissive,
          (select array_agg(case when r=0 then 'PUBLIC' else pg_get_userbyid(r) end order by r::regrole::text) from unnest(pol.polroles) r),
          pg_get_expr(pol.polqual,pol.polrelid),pg_get_expr(pol.polwithcheck,pol.polrelid)) order by pol.polname)
          from pg_policy pol where pol.polrelid=c.oid)) order by n.nspname,c.relname),'[]')
        from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p','S','v','m') and """ + rel_filter + """),
      'functions',(select coalesce(jsonb_agg(jsonb_build_array(n.nspname,p.proname,
        pg_get_function_identity_arguments(p.oid),pg_get_functiondef(p.oid),pg_get_userbyid(p.proowner),""" + acl_sql('p.proacl',"acldefault('f',p.proowner)") + """)
        order by n.nspname,p.proname,pg_get_function_identity_arguments(p.oid)),'[]')
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace where p.prokind in ('f','p') and """ + fun_filter + ') )'

def row_hash_sql():
    return """select coalesce(jsonb_object_agg(n.nspname||'.'||c.relname,
      encode(sha256(convert_to(query_to_xml(format(
        case when c.relkind='S' then 'select jsonb_build_object(''last_value'',last_value,''is_called'',is_called) as state from %I.%I'
        else 'select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text collate "C"),''[]''::jsonb) as rows from %I.%I t' end,
        n.nspname,c.relname),true,false,'')::text,'UTF8')),'hex') order by n.nspname,c.relname),'{}')
      from pg_class c join pg_namespace n on n.oid=c.relnamespace where
      (n.nspname='auth' or (n.nspname='public' and c.relname in (""" + quoted(APP_REL) + """))
      or (n.nspname='orbita_mobile_private' and c.relname='access_mutex')) and c.relkind in ('r','p','S')"""

def history_sql():
    return """select coalesce(jsonb_agg(jsonb_build_object('version',version,'name',name,
      'entries',cardinality(statements),'sha256',encode(sha256(convert_to(array_to_string(statements,''),'UTF8')),'hex'))
      order by version),'[]') from supabase_migrations.schema_migrations"""

def client_safe_sql():
    return """select count(*)=2 and bool_and(not rolsuper and not rolbypassrls and not rolcreaterole and not rolcreatedb
      and not exists(select 1 from pg_auth_members m where m.member=r.oid))
      from pg_roles r where rolname in ('anon','authenticated')"""


def dependency_sql():
    return """select exists(select 1 from pg_proc where oid=to_regprocedure('auth.uid()') and prorettype='uuid'::regtype)
      and exists(select 1 from pg_proc where oid=to_regprocedure('auth.jwt()') and prorettype='jsonb'::regtype)
      and (select count(*)=3 from pg_attribute where attrelid='auth.sessions'::regclass and not attisdropped
        and ((attname in ('id','user_id') and atttypid='uuid'::regtype)
          or (attname='not_after' and atttypid='timestamptz'::regtype)))"""


def document_sql():
    return 'select jsonb_build_object(\'catalog\',(' + catalog_sql() + "),'protected_catalog',(" + catalog_sql(True) + "),'rows',(" + row_hash_sql() + "),'history',(" + history_sql() + "),'client_safe',(" + client_safe_sql() + "),'dependency_ok',(" + dependency_sql() + '))'

def digest_sql():
    return "select encode(sha256(convert_to((" + document_sql() + ")::text,'UTF8')),'hex')"

def protected_digest_sql():
    return "select encode(sha256(convert_to(jsonb_build_object('auth_catalog',(" + catalog_sql(auth_only=True) + "),'catalog',(" + catalog_sql(True) + "),'rows',(" + row_hash_sql() + "))::text,'UTF8')),'hex')"

def capture(db):
    raw = db.query("set local search_path=''; set local timezone='UTC';" + document_sql() + ';')
    doc = json.loads(raw)
    return doc

def validate_before(doc):
    require(doc['history'] == [{'version': LOCK['first_version'], 'name': LOCK['first_name'], 'entries': 1,
                               'sha256': LOCK['first_sha256']}], 'First history content differs; no repair.')
    require(doc['protected_catalog'] == reference('auth'),
            'Auth definitions/ACL/RLS/triggers differ from the pinned reference.')
    require(all(row[1] in APP_REL for row in doc['catalog']['relations'] if row[0] in ('public','orbita_mobile_private'))
            and all(row[1] in APP_FUNCTIONS for row in doc['catalog']['functions'] if row[0] in ('public','orbita_mobile_private')), 'Unexpected application objects.')
    hist=[row for row in doc['catalog']['relations'] if row[0]=='supabase_migrations']
    require(len(hist)==1 and hist[0][1]=='schema_migrations' and hist[0][3]=='postgres'
            and [[c[0],c[1]] for c in hist[0][7]]==[['version','text'],['statements','text[]'],['name','text']]
            and not any(a[0] in ('PUBLIC','anon','authenticated','service_role') for a in hist[0][4]),
            'History structure/owner/client grants differ.')
    require(doc['dependency_ok'] is True, 'Auth dependency signatures/types differ.')
    require(doc['client_safe'] is True, 'Client SQL roles have unexpected authority.')
    require(not any(row[1] == 'orbita_orders' for row in doc['catalog']['relations'])
            and not any(row[1] in ORDER_FUNCTIONS for row in doc['catalog']['functions']), 'Order objects already exist.')

def state_hash(db):
    return db.query("set local search_path=''; set local timezone='UTC';" + digest_sql() + ';')

def protected_hash(db):
    return db.query("set local search_path=''; set local timezone='UTC';" + protected_digest_sql() + ';')


def reference(kind):
    from pathlib import Path
    path = Path(__file__).parent / (kind + '_reference.json')
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == LOCK[kind + '_catalog_sha256'], 'Reference checksum changed.')
    return json.loads(raw)
