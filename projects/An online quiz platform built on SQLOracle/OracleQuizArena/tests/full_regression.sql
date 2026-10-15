SET SERVEROUTPUT ON
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK

DECLARE
    v_token           VARCHAR2(64);
    v_user_id         NUMBER;
    v_name            VARCHAR2(100);
    v_role            VARCHAR2(20);
    v_email           VARCHAR2(255);
    v_game_username   VARCHAR2(64);
    v_attempt_id      NUMBER;
    v_question_id     NUMBER;
    v_difficulty      NUMBER;
    v_state           VARCHAR2(20);
    v_status          VARCHAR2(20);
    v_reason          VARCHAR2(30);
    v_percent         NUMBER;
    v_score           NUMBER;
    v_max_score       NUMBER;
    v_count           NUMBER;
    v_expected_diff   NUMBER;
    v_team_id         NUMBER;
    v_join_code       VARCHAR2(20);
    v_pdf             BLOB;
    v_pdf_header      VARCHAR2(4);
    v_denied          BOOLEAN;

    PROCEDURE assert_true(p_condition IN BOOLEAN, p_message IN VARCHAR2) IS
    BEGIN
        IF p_condition IS NULL OR NOT p_condition THEN
            RAISE_APPLICATION_ERROR(-20880, p_message);
        END IF;
    END assert_true;

    FUNCTION correct_json(p_question_id IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_question_id
            WHEN 1   THEN '{"option_ids":[1]}'
            WHEN 2   THEN '{"option_ids":[5,6]}'
            WHEN 3   THEN '{"text":"dual"}'
            WHEN 4   THEN '{"option_ids":[9]}'
            WHEN 5   THEN '{"number":"42"}'
            WHEN 6   THEN '{"option_ids":[11,12,13,14,15]}'
            WHEN 7   THEN '{"pairs":[' ||
                          '{"option_id":16,"answer":"42"},' ||
                          '{"option_id":17,"answer":"Oracle"},' ||
                          '{"option_id":18,"answer":"2026-09-10"}]}'
            WHEN 101 THEN '{"option_ids":[101]}'
            WHEN 102 THEN '{"option_ids":[103]}'
            WHEN 103 THEN '{"text":"SQL%ROWCOUNT"}'
            WHEN 104 THEN '{"option_ids":[106,107]}'
            WHEN 105 THEN '{"option_ids":[109]}'
            WHEN 106 THEN '{"number":"1"}'
            WHEN 107 THEN '{"option_ids":[112]}'
            WHEN 108 THEN '{"text":"NO_DATA_FOUND"}'
            WHEN 109 THEN '{"option_ids":[113]}'
            WHEN 110 THEN '{"option_ids":[115]}'
            WHEN 201 THEN '{"option_ids":[201]}'
            WHEN 202 THEN '{"option_ids":[203]}'
            WHEN 203 THEN '{"number":"6"}'
            ELSE NULL
        END;
    END correct_json;

    PROCEDURE next_question(
        p_attempt_id  IN  NUMBER,
        p_state       OUT VARCHAR2,
        p_question_id OUT NUMBER,
        p_difficulty  OUT NUMBER
    ) IS
        v_seconds       NUMBER;
        v_question_cur  SYS_REFCURSOR;
        v_options_cur   SYS_REFCURSOR;
        v_aq_id         NUMBER;
        v_sequence_no   NUMBER;
        v_target_count  NUMBER;
        v_type_code     VARCHAR2(30);
        v_question_text CLOB;
        v_points        NUMBER;
        v_time_limit    NUMBER;
        v_image_data    BLOB;
        v_image_mime    VARCHAR2(100);
        v_image_name    VARCHAR2(255);
        v_timer_text    VARCHAR2(200);
    BEGIN
        p_question_id := NULL;
        p_difficulty := NULL;
        quiz_platform.get_next_question(
            v_token, p_attempt_id, p_state, v_seconds,
            v_question_cur, v_options_cur
        );

        IF p_state = 'QUESTION' THEN
            FETCH v_question_cur INTO
                p_question_id, v_aq_id, v_sequence_no, v_target_count,
                v_type_code, v_question_text, p_difficulty, v_points,
                v_time_limit, v_image_data, v_image_mime, v_image_name,
                v_timer_text;
            assert_true(v_question_cur%FOUND, 'Курсор QUESTION не вернул вопрос.');
        END IF;

        IF v_question_cur%ISOPEN THEN
            CLOSE v_question_cur;
        END IF;
        IF v_options_cur%ISOPEN THEN
            CLOSE v_options_cur;
        END IF;
    END next_question;

    PROCEDURE submit_correct(
        p_attempt_id  IN NUMBER,
        p_question_id IN NUMBER,
        p_state       OUT VARCHAR2
    ) IS
        v_json            VARCHAR2(4000);
        v_visible_ok      CHAR(1);
        v_visible_points  NUMBER;
        v_feedback        CLOB;
        v_correct_answer  CLOB;
        v_result_message  CLOB;
    BEGIN
        v_json := correct_json(p_question_id);
        assert_true(v_json IS NOT NULL, 'Нет тестового ответа для вопроса #' || p_question_id);
        quiz_platform.submit_answer(
            v_token, p_attempt_id, p_question_id, TO_CLOB(v_json),
            v_visible_ok, v_visible_points, v_feedback,
            v_correct_answer, v_result_message, p_state
        );
    END submit_correct;

    PROCEDURE assert_pdf(p_attempt_id IN NUMBER) IS
    BEGIN
        SELECT pdf_data
          INTO v_pdf
          FROM qp_certificates
         WHERE attempt_id = p_attempt_id;
        v_pdf_header := UTL_RAW.CAST_TO_VARCHAR2(DBMS_LOB.SUBSTR(v_pdf, 4, 1));
        assert_true(v_pdf_header = '%PDF', 'Сертификат не начинается с %PDF.');
    END assert_pdf;

    PROCEDURE feedback_count(
        p_attempt_id IN  NUMBER,
        p_count      OUT NUMBER
    ) IS
        v_cursor         SYS_REFCURSOR;
        v_sequence_no    NUMBER;
        v_question_id    NUMBER;
        v_question_text  VARCHAR2(1000);
        v_type_code      VARCHAR2(30);
        v_is_correct     CHAR(1);
        v_points         NUMBER;
        v_max_points     NUMBER;
        v_explanation    VARCHAR2(2000);
        v_correct_answer VARCHAR2(4000);
        v_answer_result_text VARCHAR2(20);
    BEGIN
        p_count := 0;
        quiz_platform.get_attempt_feedback(v_token, p_attempt_id, v_cursor);
        LOOP
            FETCH v_cursor INTO
                v_sequence_no, v_question_id, v_question_text, v_type_code,
                v_is_correct, v_points, v_max_points, v_explanation,
                v_correct_answer, v_answer_result_text;
            EXIT WHEN v_cursor%NOTFOUND;
            p_count := p_count + 1;
        END LOOP;
        CLOSE v_cursor;
    END feedback_count;
BEGIN
    v_email := 'regression-' || LOWER(SUBSTR(RAWTOHEX(SYS_GUID()), 1, 20)) ||
               '@quiz.local';
    v_game_username := 'REGRESSION_' || SUBSTR(RAWTOHEX(SYS_GUID()), 1, 20);
    quiz_platform.register_user(
        'Regression Test', v_email, 'Regression123!', 'Regression123!',
        v_game_username, 'PARTICIPANT', v_user_id
    );
    SELECT COUNT(*) INTO v_count FROM qp_users
     WHERE user_id = v_user_id
       AND email = v_email
       AND oracle_username = v_game_username
       AND LENGTH(password_salt) = 32
       AND LENGTH(password_hash) = 64
       AND password_hash <> 'Regression123!';
    assert_true(v_count = 1, 'Игровой логин, email или хеш пароля не сохранены.');
    v_denied := FALSE;
    BEGIN
        quiz_platform.login(
            v_game_username, 'wrong-password', 'SQL full regression',
            v_token, v_user_id, v_name, v_role
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -20019 THEN v_denied := TRUE; ELSE RAISE; END IF;
    END;
    assert_true(v_denied, 'Неверный игровой пароль принят.');
    v_denied := FALSE;
    BEGIN
        quiz_platform.login(
            v_email, 'Regression123!', 'SQL full regression',
            v_token, v_user_id, v_name, v_role
        );
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -20019 THEN v_denied := TRUE; ELSE RAISE; END IF;
    END;
    assert_true(v_denied, 'Email принят вместо игрового логина.');
    quiz_platform.login(
        v_game_username, 'Regression123!', 'SQL full regression',
        v_token, v_user_id, v_name, v_role
    );

    SAVEPOINT before_acl_test;
    DELETE FROM qp_test_access
     WHERE test_id = 2
       AND oracle_username = v_game_username;
    v_denied := FALSE;
    BEGIN
        quiz_platform.start_attempt(v_token, 2, NULL, v_attempt_id);
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE = -20049 THEN
                v_denied := TRUE;
            ELSE
                RAISE;
            END IF;
    END;
    assert_true(v_denied, 'Закрытый тест запустился без ACL.');
    ROLLBACK TO before_acl_test;
    INSERT INTO qp_test_access (
        test_id, oracle_username, granted_by_user_id
    ) VALUES (
        2, v_game_username, 2
    );

    quiz_platform.start_attempt(v_token, 1, NULL, v_attempt_id);
    FOR i IN 1 .. 7 LOOP
        next_question(v_attempt_id, v_state, v_question_id, v_difficulty);
        assert_true(v_state = 'QUESTION', 'Ожидался вопрос теста семи типов.');
        assert_true(v_question_id = i, 'Нарушен фиксированный порядок вопросов.');
        submit_correct(v_attempt_id, v_question_id, v_state);
    END LOOP;

    SELECT attempt_status, percent_score
      INTO v_status, v_percent
      FROM qp_attempts
     WHERE attempt_id = v_attempt_id;
    assert_true(v_status = 'COMPLETED' AND v_percent = 100,
                'Тест семи типов не завершён на 100%.');
    assert_pdf(v_attempt_id);
    feedback_count(v_attempt_id, v_count);
    assert_true(v_count = 7, 'Разбор попытки должен содержать семь вопросов.');

    SELECT COUNT(*)
      INTO v_count
      FROM qp_user_badges
     WHERE user_id = v_user_id;
    assert_true(v_count >= 4, 'Не назначены ожидаемые бейджи.');

    SELECT COUNT(*)
      INTO v_count
      FROM qp_rating_snapshots
     WHERE rating_type = 'USER'
       AND period_code = 'ALL'
       AND user_id = v_user_id;
    assert_true(v_count = 1, 'Пользователь не попал в общий рейтинг.');

    SELECT correct_count
      INTO v_count
      FROM (
                  SELECT
                      q.test_id,
                      t.test_title,
                      q.question_id,
                      q.display_order,
                      qt.type_code,
                      q.difficulty_level,
                      MAX(DBMS_LOB.SUBSTR(q.question_text, 500, 1)) AS question_text,
                      COUNT(aq.attempt_question_id) AS times_assigned,
                      COUNT(CASE WHEN aq.question_status IN ('ANSWERED', 'TIMED_OUT') THEN 1 END) AS answered_count,
                      COUNT(CASE WHEN aq.is_correct = 'Y' THEN 1 END) AS correct_count,
                      ROUND(
                          100 * COUNT(CASE WHEN aq.is_correct = 'Y' THEN 1 END)
                          / NULLIF(COUNT(CASE WHEN aq.question_status IN ('ANSWERED', 'TIMED_OUT') THEN 1 END), 0),
                          2
                      ) AS correct_percent,
                      ROUND(AVG(
                          CASE
                              WHEN aq.answered_at IS NOT NULL AND aq.assigned_at IS NOT NULL
                              THEN (CAST(aq.answered_at AS DATE) - CAST(aq.assigned_at AS DATE)) * 86400
                          END
                      ), 2) AS average_answer_seconds
                  FROM qp_questions q
                  JOIN qp_tests t ON t.test_id = q.test_id
                  JOIN qp_question_types qt ON qt.question_type_id = q.question_type_id
                  LEFT JOIN qp_attempt_questions aq ON aq.question_id = q.question_id
                  GROUP BY
                      q.test_id, t.test_title, q.question_id, q.display_order,
                      qt.type_code, q.difficulty_level
              )
     WHERE question_id = 1;
    assert_true(v_count >= 1, 'Статистика вопроса не обновилась.');

    quiz_platform.start_attempt(v_token, 2, NULL, v_attempt_id);
    FOR i IN 1 .. 5 LOOP
        next_question(v_attempt_id, v_state, v_question_id, v_difficulty);
        assert_true(v_state = 'QUESTION', 'Адаптивный тест не вернул вопрос.');
        IF i = 1 THEN
            assert_true(v_difficulty = 3, 'Адаптивный тест должен начинаться со сложности 3.');
        END IF;
        submit_correct(v_attempt_id, v_question_id, v_state);
        v_expected_diff := LEAST(5, 3 + i);
        SELECT current_difficulty
          INTO v_difficulty
          FROM qp_attempts
         WHERE attempt_id = v_attempt_id;
        assert_true(v_difficulty = v_expected_diff,
                    'Адаптивная сложность изменилась неверно.');
    END LOOP;

    SELECT attempt_status, percent_score, score, max_score
      INTO v_status, v_percent, v_score, v_max_score
      FROM qp_attempts
     WHERE attempt_id = v_attempt_id;
    assert_true(v_status = 'COMPLETED' AND v_percent = 100,
                'Адаптивная попытка не завершилась на 100%.');
    assert_true(v_score = v_max_score, 'Баллы адаптивного теста рассчитаны неверно.');
    assert_pdf(v_attempt_id);

    quiz_platform.create_team(
        v_token,
        'Regression ' || SUBSTR(RAWTOHEX(SYS_GUID()), 1, 12),
        v_team_id,
        v_join_code
    );
    quiz_platform.start_attempt(v_token, 3, v_team_id, v_attempt_id);
    FOR i IN 201 .. 203 LOOP
        next_question(v_attempt_id, v_state, v_question_id, v_difficulty);
        assert_true(v_question_id = i, 'Нарушен порядок командного теста.');
        submit_correct(v_attempt_id, v_question_id, v_state);
    END LOOP;

    SELECT attempt_status, percent_score
      INTO v_status, v_percent
      FROM qp_attempts
     WHERE attempt_id = v_attempt_id
       AND team_id = v_team_id;
    assert_true(v_status = 'COMPLETED' AND v_percent = 100,
                'Командная попытка рассчитана неверно.');

    SELECT COUNT(*)
      INTO v_count
      FROM qp_rating_snapshots
     WHERE rating_type = 'TEAM'
       AND period_code = 'ALL'
       AND team_id = v_team_id;
    assert_true(v_count = 1, 'Команда не попала в командный рейтинг.');

    quiz_platform.start_attempt(v_token, 1, NULL, v_attempt_id);
    next_question(v_attempt_id, v_state, v_question_id, v_difficulty);
    UPDATE qp_attempt_questions
       SET deadline_at = SYS_EXTRACT_UTC(SYSTIMESTAMP) - NUMTODSINTERVAL(1, 'SECOND')
     WHERE attempt_id = v_attempt_id
       AND question_status = 'ACTIVE';

    next_question(v_attempt_id, v_state, v_question_id, v_difficulty);
    assert_true(v_state = 'QUESTION' AND v_question_id = 2,
                'После тайм-аута вопроса не открыт следующий вопрос.');
    SELECT COUNT(*)
      INTO v_count
      FROM qp_attempt_questions
     WHERE attempt_id = v_attempt_id
       AND sequence_no = 1
       AND question_status = 'TIMED_OUT'
       AND is_correct = 'N';
    assert_true(v_count = 1, 'Таймер вопроса не зафиксирован в Oracle.');

    UPDATE qp_attempts
       SET deadline_at = SYS_EXTRACT_UTC(SYSTIMESTAMP) - NUMTODSINTERVAL(1, 'SECOND')
     WHERE attempt_id = v_attempt_id;
    next_question(v_attempt_id, v_state, v_question_id, v_difficulty);
    assert_true(v_state = 'TIMED_OUT', 'Таймер всего теста не завершил попытку.');

    SELECT attempt_status, finish_reason
      INTO v_status, v_reason
      FROM qp_attempts
     WHERE attempt_id = v_attempt_id;
    assert_true(v_status = 'TIMED_OUT' AND v_reason = 'TEST_TIMER',
                'Причина завершения по таймеру записана неверно.');

    quiz_platform.start_attempt(v_token, 1, NULL, v_attempt_id);
    next_question(v_attempt_id, v_state, v_question_id, v_difficulty);
    assert_true(v_state = 'QUESTION', 'Early-finish scenario did not open a question.');
    quiz_platform.finish_attempt(v_token, v_attempt_id);

    SELECT attempt_status, finish_reason
      INTO v_status, v_reason
      FROM qp_attempts
     WHERE attempt_id = v_attempt_id;
    assert_true(v_status = 'COMPLETED' AND v_reason = 'USER_FINISH',
                'Early finish did not finalize the attempt in Oracle.');

    SELECT COUNT(*)
      INTO v_count
      FROM qp_attempt_questions
     WHERE attempt_id = v_attempt_id
       AND question_status = 'TIMED_OUT'
       AND is_correct = 'N'
       AND points_awarded = 0;
    assert_true(v_count = 7, 'Early finish did not close all unanswered questions.');
    assert_pdf(v_attempt_id);

    DBMS_OUTPUT.PUT_LINE('PASS: ACL blocks unauthorized game accounts.');
    DBMS_OUTPUT.PUT_LINE('PASS: all seven question types, scoring, feedback data and PDF work.');
    DBMS_OUTPUT.PUT_LINE('PASS: adaptive difficulty changes inside Oracle.');
    DBMS_OUTPUT.PUT_LINE('PASS: badges, user/team ratings and mock team quiz work.');
    DBMS_OUTPUT.PUT_LINE('PASS: question and whole-test timers are enforced by Oracle.');
    DBMS_OUTPUT.PUT_LINE('PASS: early finish finalizes unanswered questions and creates PDF.');
    ROLLBACK;
END;
/

EXIT SUCCESS
