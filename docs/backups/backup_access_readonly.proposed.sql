-- REVIEW ONLY. Do not run in the hosted project without separate permission.
-- Target must be selected manually in Dashboard: orbita-mobile-test / fjqghohhohgvwlmefdmo.
-- Only system catalogs and built-in privilege checks; no Auth/application rows or secrets.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path = pg_catalog;

SELECT current_database() AS database, current_user AS editor_role,
       current_setting('server_version_num') AS postgres_version,
       rolsuper, rolcreaterole, rolbypassrls,
       EXISTS (SELECT 1 FROM pg_roles WHERE rolname='orbita_backup_reader') AS reader_exists
FROM pg_roles WHERE rolname=current_user;

-- Four rows expected. USAGE does not imply USAGE WITH GRANT OPTION.
SELECT n.nspname AS schema, pg_get_userbyid(n.nspowner) AS owner,
       has_schema_privilege(current_user,n.oid,'USAGE') AS editor_usage,
       has_schema_privilege(current_user,n.oid,'USAGE WITH GRANT OPTION') AS editor_can_grant_usage,
       CASE WHEN r.oid IS NOT NULL THEN has_schema_privilege(r.oid,n.oid,'USAGE') END AS reader_usage
FROM pg_namespace n LEFT JOIN pg_roles r ON r.rolname='orbita_backup_reader'
WHERE n.nspname IN ('auth','public','orbita_mobile_private','supabase_migrations')
ORDER BY n.nspname;

-- No access to pg_authid/rolpassword. This is the role's own attributes only.
SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication,
       rolinherit, rolbypassrls, rolconnlimit,
       coalesce(rolconfig @> ARRAY['default_transaction_read_only=on'],false) AS default_read_only
FROM pg_roles WHERE rolname='orbita_backup_reader';
SELECT parent.rolname AS membership, m.inherit_option, m.set_option, m.admin_option
FROM pg_auth_members m JOIN pg_roles parent ON parent.oid=m.roleid
JOIN pg_roles child ON child.oid=m.member WHERE child.rolname='orbita_backup_reader';

-- Warned/no-op GRANTs must never be accepted as successful setup.
SELECT n.nspname AS schema, c.relname AS object, c.relkind,
       pg_get_userbyid(c.relowner) AS owner, c.relrowsecurity, c.relforcerowsecurity,
       CASE WHEN c.relkind='S' THEN has_sequence_privilege(current_user,c.oid,'SELECT WITH GRANT OPTION')
            ELSE has_table_privilege(current_user,c.oid,'SELECT WITH GRANT OPTION') END AS editor_can_grant_select,
       CASE WHEN r.oid IS NULL THEN NULL WHEN c.relkind='S' THEN has_sequence_privilege(r.oid,c.oid,'SELECT')
            ELSE has_table_privilege(r.oid,c.oid,'SELECT') END AS reader_select
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
LEFT JOIN pg_roles r ON r.rolname='orbita_backup_reader'
WHERE n.nspname IN ('auth','public','orbita_mobile_private','supabase_migrations')
AND c.relkind IN ('r','p','m','v','f','S') ORDER BY n.nspname,c.relname;

-- PUBLIC is grantee=0 in ACLs, not a role to remove from a membership list.
WITH public_acl AS (
 SELECT 'database'::text AS kind,d.datname::text AS object,a.privilege_type,a.is_grantable
 FROM pg_database d CROSS JOIN LATERAL aclexplode(coalesce(d.datacl,acldefault('d',d.datdba))) a
 WHERE d.datname=current_database() AND a.grantee=0
 UNION ALL
 SELECT 'schema',n.nspname,a.privilege_type,a.is_grantable
 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a
 WHERE left(n.nspname,3)<>'pg_' AND n.nspname<>'information_schema' AND a.grantee=0
 UNION ALL
 SELECT 'relation',format('%I.%I',n.nspname,c.relname),a.privilege_type,a.is_grantable
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,
   acldefault(CASE WHEN c.relkind='S' THEN 'S'::"char" ELSE 'r'::"char" END,c.relowner))) a
 WHERE left(n.nspname,3)<>'pg_' AND n.nspname<>'information_schema'
 AND c.relkind IN ('r','p','m','v','f','S') AND a.grantee=0
)
SELECT * FROM public_acl ORDER BY kind,object,privilege_type;

SELECT n.nspname AS schema, p.oid::regprocedure::text AS function,
       p.prosecdef AS security_definer, p.provolatile,
       (p.prorettype IN ('trigger'::regtype,'event_trigger'::regtype)) AS trigger_only,
       CASE WHEN r.oid IS NOT NULL THEN
         has_schema_privilege(r.oid,n.oid,'USAGE') AND has_function_privilege(r.oid,p.oid,'EXECUTE')
       END AS reader_can_call
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
LEFT JOIN pg_roles r ON r.rolname='orbita_backup_reader'
WHERE EXISTS (SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
              WHERE a.grantee=0 AND a.privilege_type='EXECUTE')
AND ((n.nspname<>'pg_catalog' AND (p.prosecdef OR p.provolatile='v'))
 OR (n.nspname='pg_catalog' AND p.proname IN
 ('lo_create','lo_creat','lo_from_bytea','lo_put','lo_unlink','lowrite','lo_import',
  'lo_export','lo_truncate','lo_truncate64')))
ORDER BY n.nspname,p.oid::regprocedure::text;

-- Future default grants also matter; this does not change any default ACL.
SELECT pg_get_userbyid(d.defaclrole) AS owner, n.nspname AS schema,
       d.defaclobjtype, a.privilege_type, a.is_grantable
FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
CROSS JOIN LATERAL aclexplode(d.defaclacl) a WHERE a.grantee=0;

SELECT e.extname,e.extversion,n.nspname AS schema
FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace ORDER BY e.extname;
ROLLBACK;
