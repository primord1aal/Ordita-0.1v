"""Read-only schema/data digests; no raw account/order data in receipts."""
import json
import re
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


AUTH_PROBE_ROWS = frozenset((
    'auth.users', 'auth.identities', 'auth.audit_log_entries', 'auth.refresh_tokens_id_seq',
))


def auth_probe_snapshot(db, since=None):
    """One read-only snapshot. Account emails and raw Auth rows stay in Postgres."""
    cutoff = 'statement_timestamp()'
    if since is not None:
        require(re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z', since),
                'Invalid Auth check time.')
        cutoff = f"timestamptz '{since}'"
    query = """
      with app_state(doc) as (""" + document_sql() + """),
      boundary(time) as (select """ + cutoff + """),
      test_accounts as (
        select u.id, r.role, lower(u.email) as email
        from auth.users u
        join public.orbita_user_roles r on r.user_id = u.id
        join public.orbita_account_access a on a.user_id = u.id
        where r.role in ('passenger','driver') and not a.is_blocked
          and u.deleted_at is null and u.email_confirmed_at is not null
          and u.email is not null and (u.banned_until is null or u.banned_until <= now())
      ), user_rows as (
        select case when u.id in (select id from test_accounts)
          then to_jsonb(u) - array['last_sign_in_at','updated_at'] else to_jsonb(u) end as row
        from auth.users u
      ), identity_rows as (
        select case when i.user_id in (select id from test_accounts)
          then to_jsonb(i) - array['last_sign_in_at','updated_at'] else to_jsonb(i) end as row
        from auth.identities i
      ), audit_rows as (
        select to_jsonb(a) as row from auth.audit_log_entries a
        where not coalesce(a.created_at >= (select time from boundary)
          and a.payload->>'action' in ('login','logout')
          and a.payload->>'actor_id' in (select id::text from test_accounts), false)
      )
      select jsonb_build_object(
        'document', doc,
        'state_sha256', encode(sha256(convert_to(doc::text,'UTF8')),'hex'),
        'cutoff', (select to_char(time at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from boundary),
        'account_count', (select count(*) from test_accounts),
        'email_hashes', (select jsonb_object_agg(role, encode(sha256(convert_to(email,'UTF8')),'hex')) from test_accounts),
        'users', (select encode(sha256(convert_to(coalesce(jsonb_agg(row order by row::text collate "C"),'[]')::text,'UTF8')),'hex') from user_rows),
        'identities', (select encode(sha256(convert_to(coalesce(jsonb_agg(row order by row::text collate "C"),'[]')::text,'UTF8')),'hex') from identity_rows),
        'audit', (select encode(sha256(convert_to(coalesce(jsonb_agg(row order by row::text collate "C"),'[]')::text,'UTF8')),'hex') from audit_rows),
        'refresh_sequence', (select jsonb_build_array(last_value, is_called) from auth.refresh_tokens_id_seq)
      ) from app_state
    """
    return json.loads(db.query("set local search_path='';set local timezone='UTC';" + query + ';'))


def validate_auth_probe_delta(before, after):
    def without_probe_rows(doc):
        rows = {key: value for key, value in doc['rows'].items() if key not in AUTH_PROBE_ROWS}
        return {**doc, 'rows': rows}

    require(without_probe_rows(before['document']) == without_probe_rows(after['document']),
            'State changed beyond the authorized Auth check.')
    require(all(before[key] == after[key] for key in ('account_count', 'email_hashes', 'users', 'identities', 'audit')),
            'Protected account data or prior audit records changed.')
    last_value, was_called = before['refresh_sequence']
    after_two_allocations = [last_value + (2 if was_called else 1), True]
    require(after['refresh_sequence'] in (before['refresh_sequence'], after_two_allocations),
            'Unexpected refresh token sequence change.')

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
