"""Read-only schema/data digests; no raw account/order data in receipts."""
import json
from tools.orders_migration.catalog import (catalog_sql, row_hash_sql, history_sql, protected_digest_sql,
  client_safe_sql, dependency_sql, reference, APP_REL, ORDER_FUNCTIONS, APP_FUNCTIONS)
from tools.orders_migration.host_rls import metadata_sql as host_rls_sql, validate as validate_host_rls
from .policy import require, history

def orders_hash_sql(after=False):
    row="to_jsonb(o)-'driver_id'-'completed_at'" if after else 'to_jsonb(o)'
    return "select encode(sha256(convert_to(coalesce(jsonb_agg("+row+" order by o.id),'[]'::jsonb)::text,'UTF8')),'hex') from public.orbita_orders o"

def document_sql():
    return "select jsonb_build_object('catalog',("+catalog_sql()+"),'protected_catalog',("+catalog_sql(True)+"),'rows',("+row_hash_sql()+"),'history',("+history_sql()+"),'client_safe',("+client_safe_sql()+"),'dependency_ok',("+dependency_sql()+"),'host_rls',("+host_rls_sql()+"),'orders_rows_sha256',("+orders_hash_sql()+"))"

def digest_sql():
    return "select encode(sha256(convert_to(("+document_sql()+")::text,'UTF8')),'hex')"

def capture(db):
    return json.loads(db.query("set local search_path='';set local timezone='UTC';"+document_sql()+';'))

def state_hash(db):
    return db.query("set local search_path='';set local timezone='UTC';"+digest_sql()+';')

def protected_hash(db):
    return db.query("set local search_path='';set local timezone='UTC';"+protected_digest_sql()+';')

def validate_before(doc):
    validate_host_rls(doc.get('host_rls'),reference('host_rls'))
    require(doc['history']==history(), 'Two exact applied migrations required; no repair.')
    require(doc['protected_catalog']==reference('auth'),'Protected Auth catalog drift.')
    order_catalog={k:v for k,v in doc['catalog'].items()}
    # Compare exact original order table/RPC definitions, ACL, indexes, constraints.
    expected=reference('orders')
    order_catalog['schemas']=[]
    order_catalog['relations']=[r for r in order_catalog['relations'] if r[0:2]==['public','orbita_orders']]
    order_catalog['functions']=[f for f in order_catalog['functions'] if f[0] in ('public','orbita_mobile_private') and f[1] in ORDER_FUNCTIONS]
    require(order_catalog==expected,'Original orders catalog drift.')
    require(doc['client_safe'] is True and doc['dependency_ok'] is True,'Unsafe SQL roles/Auth dependencies.')
    require(all(r[1] in APP_REL+['orbita_orders'] for r in doc['catalog']['relations']
       if r[0] in ('public','orbita_mobile_private')),'Unexpected application relation.')
    require(all(f[1] in APP_FUNCTIONS+ORDER_FUNCTIONS or f[:3]==['public','rls_auto_enable','']
       for f in doc['catalog']['functions'] if f[0] in ('public','orbita_mobile_private')),'Unexpected application function.')
