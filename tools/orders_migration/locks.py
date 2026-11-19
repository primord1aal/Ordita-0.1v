"""Bounded fixed-schema locks; no grants or mutations of managed Auth objects.

Supabase's postgres can only SELECT auth.schema_migrations. ACCESS SHARE on
that exact managed table prevents DDL/TRUNCATE; every row remains included in
the before/after and post-COMMIT protected fingerprints. Concurrent DML must
cause rollback or an unknown outcome requiring separately approved inspection.
All other relations retain SHARE ROW EXCLUSIVE. No arbitrary fallback exists.
"""


def lock_sql():
    return """SELECT pg_catalog.pg_advisory_xact_lock(76421,4);
DO $locks$ DECLARE r record; BEGIN
 FOR r IN SELECT c.oid,n.nspname,c.relname,c.relkind,pg_get_userbyid(c.relowner) AS owner
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('auth','public','orbita_mobile_private','supabase_migrations')
    AND c.relkind IN ('r','p') ORDER BY n.nspname,c.relname LOOP
  IF pg_catalog.has_table_privilege(current_user,r.oid,'MAINTAIN,UPDATE,DELETE,TRUNCATE') THEN
   EXECUTE format('LOCK TABLE %I.%I IN SHARE ROW EXCLUSIVE MODE',r.nspname,r.relname);
  ELSIF r.nspname='auth' AND r.relname='schema_migrations' AND r.relkind='r'
    AND r.owner='supabase_auth_admin' AND pg_catalog.has_table_privilege(current_user,r.oid,'SELECT') THEN
   EXECUTE 'LOCK TABLE auth.schema_migrations IN ACCESS SHARE MODE';
  ELSE
   RAISE EXCEPTION 'ORDERS_LOCK_PRIVILEGE_REQUIRED';
  END IF;
 END LOOP;
END $locks$;
"""
