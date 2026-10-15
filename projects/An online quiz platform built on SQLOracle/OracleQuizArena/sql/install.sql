SET DEFINE OFF
SET SERVEROUTPUT ON
SET VERIFY OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

PROMPT [1/5] Creating tables and constraints...
@@01_schema.sql

PROMPT [2/5] Creating package specification...
@@03_package_spec.sql

PROMPT [3/5] Creating package body...
@@04_package_body.sql

PROMPT [4/5] Loading reference and demonstration data...
@@05_seed.sql

DECLARE
    v_errors NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO v_errors
      FROM user_errors
     WHERE name = 'QUIZ_PLATFORM'
       AND type IN ('PACKAGE', 'PACKAGE BODY');

    IF v_errors > 0 THEN
        RAISE_APPLICATION_ERROR(-20999, 'QUIZ_PLATFORM compiled with errors. Query USER_ERRORS.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('QUIZ_PLATFORM compiled successfully.');
END;
/

PROMPT [5/5] Creating demonstration game history...
@@06_demo_history.sql
@@../tests/verify_demo_history.sql

PROMPT Oracle Quiz Platform installed successfully with demonstration game history.

COMMIT;
EXIT SUCCESS
