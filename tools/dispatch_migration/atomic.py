"""Fixed bytes + history in one externally bounded transaction. No retry."""
from .policy import LOCK, require, sources, history, HEX64
from .state import digest_sql, protected_digest_sql, history_sql, orders_hash_sql
from tools.orders_migration.locks import lock_sql
import json

def literal(value):
    return "'"+value.replace("'","''")+"'"

def postflight_sql():
    return """select
      (select count(*)=2 and bool_and(c.relrowsecurity and pg_get_userbyid(c.relowner)='postgres')
       from pg_class c join pg_namespace n on n.oid=c.relnamespace
       where n.nspname='orbita_mobile_private' and c.relname in ('dispatch_drivers','dispatch_offers'))
      and to_regclass('orbita_mobile_private.dispatch_queue') is not null
      and (select count(*)=4 and bool_and(p.prosecdef and pg_get_userbyid(p.proowner)='postgres'
        and p.proconfig @> array['search_path=""']) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where (n.nspname='public' and p.proname='orbita_dispatch')
          or (n.nspname='orbita_mobile_private' and p.proname in ('dispatch_allowed','dispatch_tick','dispatch_snapshot')))
      and has_function_privilege('authenticated','public.orbita_dispatch(text,jsonb)','EXECUTE')
      and not has_function_privilege('anon','public.orbita_dispatch(text,jsonb)','EXECUTE')
      and not has_function_privilege('service_role','public.orbita_dispatch(text,jsonb)','EXECUTE')
      and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where n.nspname='orbita_mobile_private' and p.proname in ('dispatch_allowed','dispatch_tick','dispatch_snapshot')
          and (a.grantee=0 or a.grantee in (select oid from pg_roles where rolname in ('anon','authenticated','service_role'))))
      and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
        cross join lateral aclexplode(coalesce(c.relacl,acldefault(case when c.relkind='S' then 's'::"char" else 'r'::"char" end,c.relowner))) a
        where n.nspname='orbita_mobile_private' and c.relname in ('dispatch_drivers','dispatch_offers','dispatch_queue')
          and (a.grantee=0 or a.grantee in (select oid from pg_roles where rolname in ('anon','authenticated','service_role'))))
      and not exists(select 1 from pg_policy where polrelid in ('orbita_mobile_private.dispatch_drivers'::regclass,'orbita_mobile_private.dispatch_offers'::regclass))
      and (select count(*)=5 from pg_indexes where indexname in ('orbita_orders_one_active_passenger',
        'orbita_orders_one_active_driver','orbita_orders_dispatch_search','dispatch_one_offer_per_order','dispatch_one_offer_per_driver'))
"""

def body(root,expected_state):
    source=sources(root)[-1]
    require(HEX64.fullmatch(expected_state),'Preview state digest required.')
    delimiter=b'$orbita_fixed_dispatch_source$'
    require(delimiter not in source,'SQL delimiter collision.')
    before=lock_sql()+"""
SET LOCAL search_path=''; SET LOCAL timezone='UTC';
DO $pre$ BEGIN IF ("""+digest_sql()+") <> "+literal(expected_state)+" OR ("+history_sql()+") IS DISTINCT FROM "+literal(json.dumps(history()))+"::jsonb THEN RAISE EXCEPTION 'DISPATCH_BASELINE_CHANGED'; END IF; END $pre$;\n"
    before+="SELECT set_config('orbita.dispatch_protected',("+protected_digest_sql()+"),true);\n"
    before+="SELECT set_config('orbita.dispatch_orders',("+orders_hash_sql()+"),true);\n"
    record=(b"\nINSERT INTO supabase_migrations.schema_migrations(version,statements,name) VALUES ('"+
      LOCK['version'].encode()+b"',ARRAY["+delimiter+source+delimiter+b"],'"+LOCK['name'].encode()+b"');\n")
    after="""DO $post$ BEGIN IF ("""+protected_digest_sql()+") IS DISTINCT FROM current_setting('orbita.dispatch_protected') OR ("+orders_hash_sql(True)+") IS DISTINCT FROM current_setting('orbita.dispatch_orders') OR ("+history_sql()+") IS DISTINCT FROM "+literal(json.dumps(history(True)))+"::jsonb OR NOT ("+postflight_sql()+") THEN RAISE EXCEPTION 'DISPATCH_POSTFLIGHT_FAILED'; END IF; END $post$;"
    return before.encode()+source+record+after.encode()
