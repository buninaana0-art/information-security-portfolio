SET SERVEROUTPUT ON
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
    v_count NUMBER;

    PROCEDURE assert_equal(
        p_actual   IN NUMBER,
        p_expected IN NUMBER,
        p_message  IN VARCHAR2
    ) IS
    BEGIN
        IF p_actual <> p_expected THEN
            RAISE_APPLICATION_ERROR(
                -20890,
                p_message || ': ожидалось ' || p_expected || ', получено ' || p_actual
            );
        END IF;
    END assert_equal;
BEGIN
    IF DBMS_DB_VERSION.VERSION < 12 THEN
        RAISE_APPLICATION_ERROR(-20891, 'Требуется Oracle Database 12c или новее.');
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM user_tables
     WHERE table_name LIKE 'QP\_%' ESCAPE '\';
    assert_equal(v_count, 23, 'Количество таблиц QP_*');

    SELECT COUNT(*)
      INTO v_count
      FROM user_dependencies
     WHERE name = 'QUIZ_PLATFORM' AND referenced_type = 'VIEW';
    assert_equal(v_count, 0, 'Зависимости QUIZ_PLATFORM от представлений');

    SELECT COUNT(*)
      INTO v_count
      FROM user_errors
     WHERE name = 'QUIZ_PLATFORM'
       AND type IN ('PACKAGE', 'PACKAGE BODY');
    assert_equal(v_count, 0, 'Ошибки компиляции QUIZ_PLATFORM');

    SELECT COUNT(*)
      INTO v_count
      FROM user_objects
     WHERE status <> 'VALID'
       AND object_name = 'QUIZ_PLATFORM';
    assert_equal(v_count, 0, 'Невалидные объекты API и отчётов');

    SELECT COUNT(*)
      INTO v_count
      FROM user_procedures
     WHERE object_name = 'QUIZ_PLATFORM'
       AND procedure_name IS NOT NULL;
    assert_equal(v_count, 44, 'Количество публичных процедур пакета');

    SELECT COUNT(*) INTO v_count FROM qp_question_types;
    assert_equal(v_count, 7, 'Количество типов вопросов');

    SELECT COUNT(*) INTO v_count FROM qp_tests WHERE test_id IN (1, 2, 3);
    assert_equal(v_count, 3, 'Количество демонстрационных тестов');

    SELECT COUNT(*) INTO v_count FROM qp_questions WHERE test_id IN (1, 2, 3);
    assert_equal(v_count, 20, 'Количество демонстрационных вопросов');

    DBMS_OUTPUT.PUT_LINE('PASS: Oracle version is supported.');
    DBMS_OUTPUT.PUT_LINE('PASS: 23 tables and QUIZ_PLATFORM are VALID; no view dependencies.');
    DBMS_OUTPUT.PUT_LINE('PASS: 44 API procedures and all demo data are installed.');
END;
/

EXIT SUCCESS
