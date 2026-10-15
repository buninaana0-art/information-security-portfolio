

SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

@@03_package_spec.sql
@@04_package_body.sql

DECLARE
    v_count NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_count
      FROM user_objects
     WHERE object_name = 'QUIZ_PLATFORM'
       AND object_type IN ('PACKAGE', 'PACKAGE BODY')
       AND status = 'VALID';
    IF v_count <> 2 THEN
        RAISE_APPLICATION_ERROR(-20990, 'QUIZ_PLATFORM package is invalid after upgrade');
    END IF;
END;
/

PROMPT Game-login package upgrade complete.
