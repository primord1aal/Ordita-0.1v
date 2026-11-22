"""Read-only exact baseline and existing Auth/orders/dispatch fingerprints."""
from pathlib import Path
import hashlib
import json
from tools.orders_migration.catalog import (catalog_sql, row_hash_sql, history_sql,
    protected_digest_sql as auth_digest_sql, client_safe_sql, dependency_sql, reference,
    APP_REL, APP_FUNCTIONS, ORDER_FUNCTIONS)
from tools.orders_migration.host_rls import metadata_sql as host_rls_sql, validate as validate_host_rls
from .policy import require, history, LOCK

DISPATCH_REL=['dispatch_drivers','dispatch_offers','dispatch_queue']
DISPATCH_FUNCTIONS=['dispatch_allowed','dispatch_tick','dispatch_snapshot','orbita_dispatch']


def existing_catalog_sql():
    relations="('orbita_orders','dispatch_drivers','dispatch_offers','dispatch_queue')"
    functions="("+','.join("'"+x+"'" for x in ORDER_FUNCTIONS+DISPATCH_FUNCTIONS)+")"
    return """select jsonb_build_object('schemas','[]'::jsonb,
      'relations',(select coalesce(jsonb_agg(r order by r->>0,r->>1),'[]')
        from jsonb_array_elements(("""+catalog_sql()+""" )->'relations') r
        where r->>0 in ('public','orbita_mobile_private') and r->>1 in """+relations+"""),
      'functions',(select coalesce(jsonb_agg(f order by f->>0,f->>1,(f->>2) collate "C"),'[]')
        from jsonb_array_elements(("""+catalog_sql()+""" )->'functions') f
        where f->>0 in ('public','orbita_mobile_private') and f->>1 in """+functions+"))"


def existing_rows_sql():
    # Every pre-existing order, dispatcher row and queue sequence value is protected.
    return """select jsonb_build_object(
      'orders',(select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text collate "C"),'[]') from public.orbita_orders t),
      'drivers',(select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text collate "C"),'[]') from orbita_mobile_private.dispatch_drivers t),
      'offers',(select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text collate "C"),'[]') from orbita_mobile_private.dispatch_offers t),
      'queue',(select jsonb_build_object('last_value',last_value,'is_called',is_called) from orbita_mobile_private.dispatch_queue))"""


def existing_rows_hash_sql():
    return "select encode(sha256(convert_to(("+existing_rows_sql()+")::text,'UTF8')),'hex')"


def protected_digest_sql():
    return "select encode(sha256(convert_to(jsonb_build_object('auth',("+auth_digest_sql()+"),'existing_catalog',("+existing_catalog_sql()+"),'existing_rows',("+existing_rows_hash_sql()+"))::text,'UTF8')),'hex')"


def document_sql():
    return "select jsonb_build_object('catalog',("+catalog_sql()+"),'protected_catalog',("+catalog_sql(True)+"),'rows',("+row_hash_sql()+"),'history',("+history_sql()+"),'client_safe',("+client_safe_sql()+"),'dependency_ok',("+dependency_sql()+"),'host_rls',("+host_rls_sql()+"),'existing_rows_sha256',("+existing_rows_hash_sql()+"))"


def digest_sql():
    return "select encode(sha256(convert_to(("+document_sql()+")::text,'UTF8')),'hex')"


def capture(db):
    return json.loads(db.query("set local search_path='';set local timezone='UTC';"+document_sql()+';'))


def state_hash(db):
    return db.query("set local search_path='';set local timezone='UTC';"+digest_sql()+';')


def protected_hash(db):
    return db.query("set local search_path='';set local timezone='UTC';"+protected_digest_sql()+';')


def baseline_reference():
    raw=(Path(__file__).parent/'dispatch_reference.json').read_bytes()
    require(hashlib.sha256(raw).hexdigest()==LOCK['dispatch_catalog_sha256'],'Dispatcher reference changed.')
    return json.loads(raw)


def validate_before(doc):
    validate_host_rls(doc.get('host_rls'),reference('host_rls'))
    require(doc['history']==history(), 'Three exact applied migrations required; no repair.')
    require(doc['protected_catalog']==reference('auth'),'Protected Auth catalog drift.')
    actual={**doc['catalog'],'schemas':[]}
    actual['relations']=[r for r in actual['relations'] if r[0] in ('public','orbita_mobile_private')
                          and r[1] in ['orbita_orders']+DISPATCH_REL]
    actual['functions']=[f for f in actual['functions'] if f[0] in ('public','orbita_mobile_private')
                          and f[1] in ORDER_FUNCTIONS+DISPATCH_FUNCTIONS]
    require(actual==baseline_reference(),'Original orders/dispatcher catalog drift.')
    require(doc['client_safe'] is True and doc['dependency_ok'] is True,'Unsafe SQL roles/Auth dependencies.')
    require(all(r[1] in APP_REL+['orbita_orders']+DISPATCH_REL for r in doc['catalog']['relations']
       if r[0] in ('public','orbita_mobile_private')),'Unexpected application relation.')
    require(all(f[1] in APP_FUNCTIONS+ORDER_FUNCTIONS+DISPATCH_FUNCTIONS or f[:3]==['public','rls_auto_enable','']
       for f in doc['catalog']['functions'] if f[0] in ('public','orbita_mobile_private')),'Unexpected application function.')
