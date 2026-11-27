"""One bounded transaction: exact fourth SQL and one history row, no retries."""
import json
from .policy import LOCK, require, sources, history, HEX64
from .state import FINGERPRINT_SETTINGS_SQL, digest_sql, protected_digest_sql, history_sql
from tools.orders_migration.locks import lock_sql


def literal(value):
    return "'"+value.replace("'","''")+"'"


def postflight_sql():
    return """select
      (select count(*)=1 and bool_and(c.relrowsecurity and pg_get_userbyid(c.relowner)='postgres')
       from pg_class c join pg_namespace n on n.oid=c.relnamespace
       where n.nspname='orbita_mobile_private' and c.relname='map_budget')
      and (select count(*)=1 and bool_and(p.prosecdef and pg_get_userbyid(p.proowner)='postgres'
        and p.proconfig @> array['search_path=""']) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname='orbita_map_budget'
          and pg_get_function_identity_arguments(p.oid)='p_user uuid, p_units integer')
      and has_function_privilege('service_role','public.orbita_map_budget(uuid,integer)','EXECUTE')
      and not has_function_privilege('authenticated','public.orbita_map_budget(uuid,integer)','EXECUTE')
      and not has_function_privilege('anon','public.orbita_map_budget(uuid,integer)','EXECUTE')
      and not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where n.nspname='public' and p.proname='orbita_map_budget' and a.grantee=0)
      and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
        cross join lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
        where n.nspname='orbita_mobile_private' and c.relname='map_budget'
          and (a.grantee=0 or a.grantee in (select oid from pg_roles where rolname in ('anon','authenticated','service_role'))))
      and not exists(select 1 from pg_policy where polrelid='orbita_mobile_private.map_budget'::regclass)
      and (select count(*)=1 from pg_indexes where schemaname='orbita_mobile_private' and indexname='orbita_map_budget_expiry')
      and not exists(select 1 from orbita_mobile_private.map_budget)
"""


def body(root,expected_state):
    source=sources(root)[-1]
    require(HEX64.fullmatch(expected_state),'Preview state digest required.')
    delimiter=b'$orbita_fixed_maps_source$'
    require(delimiter not in source,'SQL delimiter collision.')
    before=lock_sql()+'\n'+FINGERPRINT_SETTINGS_SQL+"""
DO $pre$ BEGIN IF ("""+digest_sql()+") <> "+literal(expected_state)+" OR ("+history_sql()+") IS DISTINCT FROM "+literal(json.dumps(history()))+"::jsonb THEN RAISE EXCEPTION 'MAPS_BASELINE_CHANGED'; END IF; END $pre$;\n"
    before+="SELECT set_config('orbita.maps_protected',("+protected_digest_sql()+"),true);\n"
    record=(b"\nINSERT INTO supabase_migrations.schema_migrations(version,statements,name) VALUES ('"+
      LOCK['version'].encode()+b"',ARRAY["+delimiter+source+delimiter+b"],'"+LOCK['name'].encode()+b"');\n")
    after="""DO $post$ BEGIN IF ("""+protected_digest_sql()+") IS DISTINCT FROM current_setting('orbita.maps_protected') OR ("+history_sql()+") IS DISTINCT FROM "+literal(json.dumps(history(True)))+"::jsonb OR NOT ("+postflight_sql()+") THEN RAISE EXCEPTION 'MAPS_POSTFLIGHT_FAILED'; END IF; END $post$;"
    return before.encode()+source+record+after.encode()
