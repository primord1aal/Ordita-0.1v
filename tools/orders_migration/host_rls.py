"""Metadata-only identity for the reviewed hosted RLS helper and linked trigger.

The saved read-only query selected events by evtfoid IN the single captured
function. That establishes the binding; no missing host metadata is guessed.
Runtime carries only the reviewed definition hash, never a callable replacement.
"""
from .admission import require


def metadata_sql():
    return """SELECT jsonb_build_object(
 'functions',(SELECT coalesce(jsonb_agg(jsonb_build_object(
  'schema',n.nspname,'name',p.proname,
  'identity_arguments',pg_get_function_identity_arguments(p.oid),
  'owner',pg_get_userbyid(p.proowner),'return_type',pg_get_function_result(p.oid),
  'security_definer',p.prosecdef,'config',p.proconfig,
  'definition_sha256',encode(sha256(convert_to(pg_get_functiondef(p.oid),'UTF8')),'hex'),
  'execute_acl',(SELECT coalesce(jsonb_agg(jsonb_build_array(
    CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
    pg_get_userbyid(a.grantor),a.privilege_type,a.is_grantable)
    ORDER BY a.grantee::regrole::text,a.privilege_type),'[]')
    FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a),
  'extension',(SELECT e.extname FROM pg_depend d JOIN pg_extension e ON e.oid=d.refobjid
    WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid
    AND d.refclassid='pg_extension'::regclass AND d.deptype='e')
 ) ORDER BY pg_get_function_identity_arguments(p.oid)),'[]')
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='rls_auto_enable'),
 'event_triggers',(SELECT coalesce(jsonb_agg(jsonb_build_object(
  'name',e.evtname,'owner',pg_get_userbyid(e.evtowner),'event',e.evtevent,
  'enabled',e.evtenabled,'tags',(SELECT array_agg(tag ORDER BY tag) FROM unnest(e.evttags) tag),
  'function_schema',n.nspname,'function_name',p.proname,
  'function_identity_arguments',pg_get_function_identity_arguments(p.oid)
 ) ORDER BY e.evtname),'[]')
 FROM pg_event_trigger e JOIN pg_proc p ON p.oid=e.evtfoid
 JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE e.evtname='ensure_rls' OR (n.nspname='public' AND p.proname='rls_auto_enable'))
)"""


def validate(document, expected):
    require(document == expected, 'Hosted RLS function/trigger identity differs from the reviewed reference.')


def restore_trigger_in_isolation(local, expected):
    """pg_dump --schema omits global event triggers; reconstruct only in owned sandbox."""
    import json
    require(local.network in ('none', 'native_test_unix_only'), 'Isolated RLS rehearsal required.')
    actual = json.loads(local.query(metadata_sql() + ';'))
    require(actual['functions'] == expected['functions'], 'Restored RLS function identity differs.')
    require(actual['event_triggers'] == [], 'Unexpected event trigger in empty restore sandbox.')
    local.psql("CREATE EVENT TRIGGER ensure_rls ON ddl_command_end "
               "WHEN TAG IN ('CREATE TABLE','CREATE TABLE AS','SELECT INTO') "
               "EXECUTE FUNCTION public.rls_auto_enable();")
    validate(json.loads(local.query(metadata_sql() + ';')), expected)
