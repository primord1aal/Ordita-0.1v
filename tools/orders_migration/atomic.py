"""One transaction: fixed candidate + exact second history row, no retry/repair."""
import json
import re
from .admission import LOCK, require, sources
from .catalog import catalog_sql, history_sql, digest_sql, protected_digest_sql, reference

def literal(value):
    return "'" + value.replace("'", "''") + "'"

def body(root, expected_state):
    _, source = sources(root)
    require(re.fullmatch('[a-f0-9]{64}', expected_state) is not None, 'Preview state digest required.')
    auth_ref = literal(json.dumps(reference('auth'), ensure_ascii=False)) + '::jsonb'
    order_ref = literal(json.dumps(reference('orders'), ensure_ascii=False)) + '::jsonb'
    first = {'version': LOCK['first_version'], 'name': LOCK['first_name'], 'entries': 1, 'sha256': LOCK['first_sha256']}
    second = {'version': LOCK['version'], 'name': LOCK['name'], 'entries': 1, 'sha256': LOCK['sha256']}
    history_before = literal(json.dumps([first])) + '::jsonb'
    history_after = literal(json.dumps([first, second])) + '::jsonb'
    delimiter = '$orbita_fixed_orders_source$'
    require(delimiter.encode() not in source, 'History source delimiter collision.')
    before = """select pg_catalog.pg_advisory_xact_lock(76421,4);
DO $locks$ DECLARE r record; BEGIN
  FOR r IN SELECT n.nspname,c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname IN ('auth','public','orbita_mobile_private','supabase_migrations') AND c.relkind IN ('r','p')
    ORDER BY n.nspname,c.relname LOOP
    EXECUTE format('LOCK TABLE %I.%I IN SHARE ROW EXCLUSIVE MODE',r.nspname,r.relname);
  END LOOP;
END $locks$;
SET LOCAL search_path=''; SET LOCAL timezone='UTC';
DO $guard$ BEGIN
  IF (""" + catalog_sql(True) + ') IS DISTINCT FROM ' + auth_ref + "\n OR (" + history_sql() + ') IS DISTINCT FROM ' + history_before + "\n OR (" + digest_sql() + ') <> ' + literal(expected_state) + """
  THEN RAISE EXCEPTION 'ORDERS_BASELINE_CHANGED'; END IF;
END $guard$;
SELECT pg_catalog.set_config('orbita.orders_protected',(""" + protected_digest_sql() + "),true);\n"
    history = "\nINSERT INTO supabase_migrations.schema_migrations(version,statements,name) VALUES (" + literal(LOCK['version']) + ',ARRAY[' + delimiter + source.decode() + delimiter + '],' + literal(LOCK['name']) + ');\n'
    after = """DO $post$ BEGIN
 IF (""" + protected_digest_sql() + ") IS DISTINCT FROM pg_catalog.current_setting('orbita.orders_protected')\n OR (" + catalog_sql(True) + ') IS DISTINCT FROM ' + auth_ref + '\n OR (' + catalog_sql(orders_only=True) + ') IS DISTINCT FROM ' + order_ref + '\n OR (' + history_sql() + ') IS DISTINCT FROM ' + history_after + """
 OR EXISTS(SELECT 1 FROM public.orbita_orders)
 THEN RAISE EXCEPTION 'ORDERS_POSTFLIGHT_FAILED'; END IF;
END $post$;
"""
    return before.encode() + source + history.encode() + after.encode()
