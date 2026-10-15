SET SERVEROUTPUT ON
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
    v_token          VARCHAR2(64);
    v_user_id        NUMBER;
    v_name           VARCHAR2(100);
    v_role           VARCHAR2(20);
    v_attempt_id     NUMBER;
    v_state          VARCHAR2(20);
    v_seconds        NUMBER;
    v_question_cur   SYS_REFCURSOR;
    v_options_cur    SYS_REFCURSOR;
    v_visible_ok     CHAR(1);
    v_visible_points NUMBER;
    v_feedback       CLOB;
    v_correct        CLOB;
    v_result_message CLOB;
    v_status         VARCHAR2(20);
    v_percent        NUMBER;
    v_pdf             BLOB;
    v_pdf_header      VARCHAR2(4);
    v_email           VARCHAR2(255);
    v_game_username   VARCHAR2(64);

    PROCEDURE activate_question IS
    BEGIN
        quiz_platform.get_next_question(
            v_token, v_attempt_id, v_state, v_seconds,
            v_question_cur, v_options_cur
        );
        IF v_state <> 'QUESTION' THEN
            RAISE_APPLICATION_ERROR(-20801, 'Expected QUESTION, got ' || v_state);
        END IF;
        CLOSE v_question_cur;
        CLOSE v_options_cur;
    END;

    PROCEDURE answer_question(p_question_id NUMBER, p_json VARCHAR2) IS
    BEGIN
        quiz_platform.submit_answer(
            v_token, v_attempt_id, p_question_id, TO_CLOB(p_json),
            v_visible_ok, v_visible_points, v_feedback, v_correct,
            v_result_message, v_state
        );
        IF v_visible_ok <> 'Y' THEN
            RAISE_APPLICATION_ERROR(-20802, 'Question ' || p_question_id || ' failed scoring.');
        END IF;
    END;
BEGIN

    v_email := 'smoke-' || LOWER(SUBSTR(RAWTOHEX(SYS_GUID()), 1, 20)) ||
               '@quiz.local';
    v_game_username := 'SMOKE_' || SUBSTR(RAWTOHEX(SYS_GUID()), 1, 20);
    quiz_platform.register_user(
        'Smoke Test', v_email, 'SmokeTest123!', 'SmokeTest123!',
        v_game_username, 'PARTICIPANT', v_user_id
    );
    quiz_platform.login(
        v_game_username, 'SmokeTest123!', 'SQL smoke test',
        v_token, v_user_id, v_name, v_role
    );
    quiz_platform.start_attempt(v_token, 1, NULL, v_attempt_id);

    activate_question;
    answer_question(1, '{"option_ids":[1]}');

    activate_question;
    answer_question(2, '{"option_ids":[5,6]}');

    activate_question;
    answer_question(3, '{"text":"dual"}');

    activate_question;
    answer_question(4, '{"option_ids":[9]}');

    activate_question;
    answer_question(5, '{"number":"42"}');

    activate_question;
    answer_question(6, '{"option_ids":[11,12,13,14,15]}');

    activate_question;
    answer_question(
        7,
        '{"pairs":[' ||
        '{"option_id":16,"answer":"42"},' ||
        '{"option_id":17,"answer":"Oracle"},' ||
        '{"option_id":18,"answer":"2026-09-10"}' ||
        ']}'
    );

    SELECT attempt_status, percent_score
      INTO v_status, v_percent
      FROM qp_attempts
     WHERE attempt_id = v_attempt_id;

    IF v_status <> 'COMPLETED' OR v_percent <> 100 THEN
        RAISE_APPLICATION_ERROR(
            -20803,
            'Expected completed 100%, got ' || v_status || ' / ' || v_percent
        );
    END IF;

    SELECT pdf_data INTO v_pdf
      FROM qp_certificates
     WHERE attempt_id = v_attempt_id;
    v_pdf_header := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(v_pdf, 4, 1));
    IF v_pdf_header <> '%PDF' THEN
        RAISE_APPLICATION_ERROR(-20804, 'Certificate is not a PDF.');
    END IF;

    DBMS_OUTPUT.PUT_LINE('PASS: all seven question types scored in Oracle.');
    DBMS_OUTPUT.PUT_LINE('PASS: result = 100%, badge/rating pipeline completed.');
    DBMS_OUTPUT.PUT_LINE('PASS: certificate PDF BLOB starts with %PDF.');
    ROLLBACK;
END;
/

EXIT SUCCESS
