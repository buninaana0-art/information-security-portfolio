CREATE OR REPLACE PACKAGE BODY quiz_platform AS
    c_session_hours CONSTANT PLS_INTEGER := 8;
    c_max_image_bytes CONSTANT PLS_INTEGER := 10 * 1024 * 1024;

    TYPE t_user_rec IS RECORD (
        user_id          qp_users.user_id%TYPE,
        oracle_username  qp_users.oracle_username%TYPE,
        display_name     qp_users.display_name%TYPE,
        user_role        qp_users.user_role%TYPE
    );

    PROCEDURE fail(p_code IN PLS_INTEGER, p_message IN VARCHAR2) IS
    BEGIN
        RAISE_APPLICATION_ERROR(p_code, p_message);
    END fail;

    FUNCTION norm_flag(p_value IN CHAR, p_default IN CHAR := 'N') RETURN CHAR IS
        v_value CHAR(1) := UPPER(SUBSTR(TRIM(NVL(p_value, p_default)), 1, 1));
    BEGIN
        IF v_value NOT IN ('Y', 'N') THEN
            fail(-20001, 'Логический параметр должен иметь значение Y или N.');
        END IF;
        RETURN v_value;
    END norm_flag;

    FUNCTION password_hash(
        p_password IN VARCHAR2,
        p_salt     IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_hash VARCHAR2(64);
    BEGIN
        SELECT RAWTOHEX(STANDARD_HASH(p_password || ':' || p_salt, 'SHA256'))
          INTO v_hash
          FROM dual;
        RETURN v_hash;
    END password_hash;

    PROCEDURE audit_event(
        p_user_id     IN NUMBER,
        p_event_code  IN VARCHAR2,
        p_entity_type IN VARCHAR2 DEFAULT NULL,
        p_entity_id   IN NUMBER DEFAULT NULL,
        p_details     IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        INSERT INTO qp_audit_log (
            user_id, event_code, entity_type, entity_id, details,
            oracle_session_user
        ) VALUES (
            p_user_id, p_event_code, p_entity_type, p_entity_id,
            SUBSTR(p_details, 1, 2000),
            SYS_CONTEXT('USERENV', 'SESSION_USER')
        );
    END audit_event;

    PROCEDURE require_session(
        p_session_token IN  VARCHAR2,
        p_allowed_roles IN  VARCHAR2,
        p_user          OUT t_user_rec
    ) IS
    BEGIN
        IF p_session_token IS NULL THEN
            fail(-20002, 'Требуется вход в систему.');
        END IF;

        SELECT u.user_id, u.oracle_username, u.display_name, u.user_role
          INTO p_user.user_id, p_user.oracle_username,
               p_user.display_name, p_user.user_role
          FROM qp_sessions s
          JOIN qp_users u ON u.user_id = s.user_id
         WHERE s.session_token = p_session_token
           AND s.revoked_flag = 'N'
           AND s.expires_at > SYS_EXTRACT_UTC(SYSTIMESTAMP)
           AND u.user_status = 'ACTIVE';

        IF p_allowed_roles IS NOT NULL
           AND INSTR(',' || UPPER(p_allowed_roles) || ',',
                     ',' || p_user.user_role || ',') = 0 THEN
            fail(-20003, 'Недостаточно прав для выполнения операции.');
        END IF;

        UPDATE qp_sessions
           SET last_seen_at = SYS_EXTRACT_UTC(SYSTIMESTAMP)
         WHERE session_token = p_session_token;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20004, 'Сессия не найдена, истекла или была завершена.');
    END require_session;

    PROCEDURE assert_test_owner(
        p_user               IN t_user_rec,
        p_test_id            IN NUMBER,
        p_draft_required     IN CHAR DEFAULT 'N'
    ) IS
        v_author_id qp_tests.author_user_id%TYPE;
        v_status    qp_tests.test_status%TYPE;
    BEGIN
        SELECT author_user_id, test_status
          INTO v_author_id, v_status
          FROM qp_tests
         WHERE test_id = p_test_id;

        IF p_user.user_role <> 'ADMIN' AND v_author_id <> p_user.user_id THEN
            fail(-20007, 'Изменять тест может только его автор или администратор.');
        END IF;
        IF p_draft_required = 'Y' AND v_status <> 'DRAFT' THEN
            fail(-20008, 'Изменение содержимого возможно только для черновика.');
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20009, 'Тест не найден.');
    END assert_test_owner;

    FUNCTION can_access_test(
        p_user_id IN NUMBER,
        p_test_id IN NUMBER
    ) RETURN CHAR IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO v_count
          FROM qp_tests t
          JOIN qp_users u ON u.user_id = p_user_id
         WHERE t.test_id = p_test_id
           AND (
                t.access_mode = 'PUBLIC'
                OR t.author_user_id = p_user_id
                OR u.user_role = 'ADMIN'
                OR EXISTS (
                    SELECT 1
                      FROM qp_test_access a
                     WHERE a.test_id = t.test_id
                       AND UPPER(a.oracle_username) = UPPER(u.oracle_username)
                )
           );
        RETURN CASE WHEN v_count > 0 THEN 'Y' ELSE 'N' END;
    END can_access_test;

    PROCEDURE assert_attempt_owner(
        p_user       IN t_user_rec,
        p_attempt_id IN NUMBER
    ) IS
        v_owner_id NUMBER;
    BEGIN
        SELECT user_id
          INTO v_owner_id
          FROM qp_attempts
         WHERE attempt_id = p_attempt_id;

        IF p_user.user_role <> 'ADMIN' AND v_owner_id <> p_user.user_id THEN
            fail(-20010, 'Попытка принадлежит другому пользователю.');
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20011, 'Попытка не найдена.');
    END assert_attempt_owner;

    FUNCTION question_type_code(p_question_id IN NUMBER) RETURN VARCHAR2 IS
        v_code qp_question_types.type_code%TYPE;
    BEGIN
        SELECT qt.type_code
          INTO v_code
          FROM qp_questions q
          JOIN qp_question_types qt
            ON qt.question_type_id = q.question_type_id
         WHERE q.question_id = p_question_id;
        RETURN v_code;
    END question_type_code;

    FUNCTION correct_answer_text(p_question_id IN NUMBER) RETURN CLOB IS
        v_code   VARCHAR2(30);
        v_answer VARCHAR2(32767);
    BEGIN
        v_code := question_type_code(p_question_id);

        IF v_code IN ('SINGLE', 'MULTIPLE', 'TRUE_FALSE') THEN
            SELECT LISTAGG(option_text, '; ') WITHIN GROUP (ORDER BY display_order)
              INTO v_answer
              FROM qp_answer_options
             WHERE question_id = p_question_id
               AND is_correct = 'Y';
        ELSIF v_code = 'ORDERING' THEN
            SELECT LISTAGG(option_text, ' -> ') WITHIN GROUP (ORDER BY correct_order)
              INTO v_answer
              FROM qp_answer_options
             WHERE question_id = p_question_id;
        ELSIF v_code = 'MATCHING' THEN
            SELECT LISTAGG(option_text || ' = ' || match_key, '; ')
                       WITHIN GROUP (ORDER BY display_order)
              INTO v_answer
              FROM qp_answer_options
             WHERE question_id = p_question_id;
        ELSIF v_code = 'NUMBER' THEN
            SELECT LISTAGG(TO_CHAR(numeric_value), ' / ')
                       WITHIN GROUP (ORDER BY key_id)
              INTO v_answer
              FROM qp_question_keys
             WHERE question_id = p_question_id
               AND key_type = 'NUMBER';
        ELSE
            SELECT LISTAGG(accepted_text, ' / ')
                       WITHIN GROUP (ORDER BY key_id)
              INTO v_answer
              FROM qp_question_keys
             WHERE question_id = p_question_id
               AND key_type IN ('TEXT', 'REGEX');
        END IF;

        RETURN TO_CLOB(NVL(v_answer, 'Ответ не задан'));
    END correct_answer_text;

    FUNCTION score_response(
        p_question_id   IN NUMBER,
        p_response_json IN CLOB
    ) RETURN CHAR IS
        v_code            VARCHAR2(30);
        v_json_ok         NUMBER;
        v_selected_count  NUMBER := 0;
        v_distinct_count  NUMBER := 0;
        v_expected_count  NUMBER := 0;
        v_invalid_count   NUMBER := 0;
        v_match_count     NUMBER := 0;
        v_text            VARCHAR2(1000);
        v_number          NUMBER;
    BEGIN
        SELECT CASE WHEN p_response_json IS JSON THEN 1 ELSE 0 END
          INTO v_json_ok
          FROM dual;
        IF v_json_ok = 0 THEN
            fail(-20012, 'Ответ должен быть корректным JSON-документом.');
        END IF;

        v_code := question_type_code(p_question_id);

        IF v_code IN ('SINGLE', 'TRUE_FALSE') THEN
            SELECT COUNT(*), COUNT(DISTINCT jt.option_id),
                   COUNT(CASE WHEN o.is_correct = 'Y' THEN 1 END),
                   COUNT(CASE WHEN o.option_id IS NULL THEN 1 END)
              INTO v_selected_count, v_distinct_count,
                   v_match_count, v_invalid_count
              FROM JSON_TABLE(
                       p_response_json,
                       '$.option_ids[*]'
                       COLUMNS (option_id NUMBER PATH '$')
                   ) jt
              LEFT JOIN qp_answer_options o
                ON o.option_id = jt.option_id
               AND o.question_id = p_question_id;

            RETURN CASE
                WHEN v_selected_count = 1
                 AND v_distinct_count = 1
                 AND v_match_count = 1
                 AND v_invalid_count = 0 THEN 'Y'
                ELSE 'N'
            END;

        ELSIF v_code = 'MULTIPLE' THEN
            SELECT COUNT(*), COUNT(DISTINCT option_id)
              INTO v_selected_count, v_distinct_count
              FROM JSON_TABLE(
                       p_response_json,
                       '$.option_ids[*]'
                       COLUMNS (option_id NUMBER PATH '$')
                   );

            SELECT COUNT(*)
              INTO v_expected_count
              FROM qp_answer_options
             WHERE question_id = p_question_id
               AND is_correct = 'Y';

            SELECT COUNT(*)
              INTO v_invalid_count
              FROM JSON_TABLE(
                       p_response_json,
                       '$.option_ids[*]'
                       COLUMNS (option_id NUMBER PATH '$')
                   ) jt
              LEFT JOIN qp_answer_options o
                ON o.option_id = jt.option_id
               AND o.question_id = p_question_id
             WHERE o.option_id IS NULL OR o.is_correct <> 'Y';

            RETURN CASE
                WHEN v_selected_count = v_distinct_count
                 AND v_distinct_count = v_expected_count
                 AND v_expected_count > 0
                 AND v_invalid_count = 0 THEN 'Y'
                ELSE 'N'
            END;

        ELSIF v_code = 'ORDERING' THEN
            SELECT COUNT(*)
              INTO v_expected_count
              FROM qp_answer_options
             WHERE question_id = p_question_id;

            SELECT COUNT(*), COUNT(DISTINCT jt.option_id),
                   COUNT(CASE
                       WHEN o.option_id IS NULL OR o.correct_order <> jt.position_no
                       THEN 1
                   END)
              INTO v_selected_count, v_distinct_count, v_invalid_count
              FROM JSON_TABLE(
                       p_response_json,
                       '$.option_ids[*]'
                       COLUMNS (
                           position_no FOR ORDINALITY,
                           option_id NUMBER PATH '$'
                       )
                   ) jt
              LEFT JOIN qp_answer_options o
                ON o.option_id = jt.option_id
               AND o.question_id = p_question_id;

            RETURN CASE
                WHEN v_selected_count = v_expected_count
                 AND v_distinct_count = v_expected_count
                 AND v_expected_count > 0
                 AND v_invalid_count = 0 THEN 'Y'
                ELSE 'N'
            END;

        ELSIF v_code = 'MATCHING' THEN
            SELECT COUNT(*)
              INTO v_expected_count
              FROM qp_answer_options
             WHERE question_id = p_question_id;

            SELECT COUNT(*), COUNT(DISTINCT jt.option_id),
                   COUNT(CASE
                       WHEN o.option_id IS NULL
                         OR o.match_key IS NULL
                         OR jt.answer_text IS NULL
                         OR LOWER(TRIM(o.match_key)) <> LOWER(TRIM(jt.answer_text))
                       THEN 1
                   END)
              INTO v_selected_count, v_distinct_count, v_invalid_count
              FROM JSON_TABLE(
                       p_response_json,
                       '$.pairs[*]'
                       COLUMNS (
                           option_id NUMBER PATH '$.option_id',
                           answer_text VARCHAR2(500) PATH '$.answer'
                       )
                   ) jt
              LEFT JOIN qp_answer_options o
                ON o.option_id = jt.option_id
               AND o.question_id = p_question_id;

            RETURN CASE
                WHEN v_selected_count = v_expected_count
                 AND v_distinct_count = v_expected_count
                 AND v_expected_count > 0
                 AND v_invalid_count = 0 THEN 'Y'
                ELSE 'N'
            END;

        ELSIF v_code = 'NUMBER' THEN
            SELECT JSON_VALUE(
                       p_response_json,
                       '$.number' RETURNING NUMBER NULL ON ERROR
                   )
              INTO v_number
              FROM dual;

            SELECT COUNT(*)
              INTO v_match_count
              FROM qp_question_keys
             WHERE question_id = p_question_id
               AND key_type = 'NUMBER'
               AND v_number IS NOT NULL
               AND ABS(v_number - numeric_value) <= NVL(numeric_tolerance, 0);

            RETURN CASE WHEN v_match_count > 0 THEN 'Y' ELSE 'N' END;

        ELSIF v_code = 'TEXT' THEN
            SELECT JSON_VALUE(
                       p_response_json,
                       '$.text' RETURNING VARCHAR2(1000) NULL ON ERROR
                   )
              INTO v_text
              FROM dual;

            IF v_text IS NULL THEN
                RETURN 'N';
            END IF;

            FOR k IN (
                SELECT key_type, accepted_text, case_sensitive_flag
                  FROM qp_question_keys
                 WHERE question_id = p_question_id
                   AND key_type IN ('TEXT', 'REGEX')
                 ORDER BY key_id
            ) LOOP
                IF k.key_type = 'TEXT' THEN
                    IF (k.case_sensitive_flag = 'Y' AND TRIM(v_text) = TRIM(k.accepted_text))
                       OR
                       (k.case_sensitive_flag = 'N'
                        AND LOWER(TRIM(v_text)) = LOWER(TRIM(k.accepted_text))) THEN
                        RETURN 'Y';
                    END IF;
                ELSIF REGEXP_LIKE(
                    TRIM(v_text), k.accepted_text,
                    CASE WHEN k.case_sensitive_flag = 'Y' THEN 'c' ELSE 'i' END
                ) THEN
                    RETURN 'Y';
                END IF;
            END LOOP;
            RETURN 'N';
        END IF;

        fail(-20013, 'Неподдерживаемый тип вопроса: ' || v_code);
        RETURN 'N';
    END score_response;

    FUNCTION pdf_ascii(p_text IN VARCHAR2) RETURN VARCHAR2 IS
        v_result VARCHAR2(32767) := '';
        v_char   VARCHAR2(4);
        v_piece  VARCHAR2(4);
    BEGIN
        IF p_text IS NULL THEN
            RETURN NULL;
        END IF;
        FOR i IN 1 .. LENGTH(p_text) LOOP
            v_char := SUBSTR(p_text, i, 1);
            v_piece := CASE v_char
                WHEN 'А' THEN 'A'  WHEN 'а' THEN 'a'
                WHEN 'Б' THEN 'B'  WHEN 'б' THEN 'b'
                WHEN 'В' THEN 'V'  WHEN 'в' THEN 'v'
                WHEN 'Г' THEN 'G'  WHEN 'г' THEN 'g'
                WHEN 'Д' THEN 'D'  WHEN 'д' THEN 'd'
                WHEN 'Е' THEN 'E'  WHEN 'е' THEN 'e'
                WHEN 'Ё' THEN 'Yo' WHEN 'ё' THEN 'yo'
                WHEN 'Ж' THEN 'Zh' WHEN 'ж' THEN 'zh'
                WHEN 'З' THEN 'Z'  WHEN 'з' THEN 'z'
                WHEN 'И' THEN 'I'  WHEN 'и' THEN 'i'
                WHEN 'Й' THEN 'Y'  WHEN 'й' THEN 'y'
                WHEN 'К' THEN 'K'  WHEN 'к' THEN 'k'
                WHEN 'Л' THEN 'L'  WHEN 'л' THEN 'l'
                WHEN 'М' THEN 'M'  WHEN 'м' THEN 'm'
                WHEN 'Н' THEN 'N'  WHEN 'н' THEN 'n'
                WHEN 'О' THEN 'O'  WHEN 'о' THEN 'o'
                WHEN 'П' THEN 'P'  WHEN 'п' THEN 'p'
                WHEN 'Р' THEN 'R'  WHEN 'р' THEN 'r'
                WHEN 'С' THEN 'S'  WHEN 'с' THEN 's'
                WHEN 'Т' THEN 'T'  WHEN 'т' THEN 't'
                WHEN 'У' THEN 'U'  WHEN 'у' THEN 'u'
                WHEN 'Ф' THEN 'F'  WHEN 'ф' THEN 'f'
                WHEN 'Х' THEN 'Kh' WHEN 'х' THEN 'kh'
                WHEN 'Ц' THEN 'Ts' WHEN 'ц' THEN 'ts'
                WHEN 'Ч' THEN 'Ch' WHEN 'ч' THEN 'ch'
                WHEN 'Ш' THEN 'Sh' WHEN 'ш' THEN 'sh'
                WHEN 'Щ' THEN 'Sch' WHEN 'щ' THEN 'sch'
                WHEN 'Ъ' THEN ''   WHEN 'ъ' THEN ''
                WHEN 'Ы' THEN 'Y'  WHEN 'ы' THEN 'y'
                WHEN 'Ь' THEN ''   WHEN 'ь' THEN ''
                WHEN 'Э' THEN 'E'  WHEN 'э' THEN 'e'
                WHEN 'Ю' THEN 'Yu' WHEN 'ю' THEN 'yu'
                WHEN 'Я' THEN 'Ya' WHEN 'я' THEN 'ya'
                ELSE v_char
            END;
            v_result := v_result || v_piece;
        END LOOP;

        v_result := REPLACE(v_result, '\', '\\');
        v_result := REPLACE(v_result, '(', '\(');
        v_result := REPLACE(v_result, ')', '\)');
        RETURN REGEXP_REPLACE(v_result, '[^[:print:]]', '?');
    END pdf_ascii;

    FUNCTION make_certificate_pdf(
        p_certificate_no IN VARCHAR2,
        p_user_name      IN VARCHAR2,
        p_test_title     IN VARCHAR2,
        p_score          IN NUMBER,
        p_max_score      IN NUMBER,
        p_percent        IN NUMBER,
        p_issued_at      IN TIMESTAMP
    ) RETURN BLOB IS
        v_pdf       CLOB;
        v_stream    VARCHAR2(32767);
        v_blob      BLOB;
        v_dest_off  INTEGER := 1;
        v_src_off   INTEGER := 1;
        v_context   INTEGER := 0;
        v_warning   INTEGER;
        v_xref      PLS_INTEGER;
        v_off1      PLS_INTEGER;
        v_off2      PLS_INTEGER;
        v_off3      PLS_INTEGER;
        v_off4      PLS_INTEGER;
        v_off5      PLS_INTEGER;

        PROCEDURE app(p_value IN VARCHAR2) IS
        BEGIN
            DBMS_LOB.WRITEAPPEND(v_pdf, LENGTH(p_value), p_value);
        END;

        FUNCTION xref_line(p_offset IN PLS_INTEGER) RETURN VARCHAR2 IS
        BEGIN
            RETURN LPAD(p_offset, 10, '0') || ' 00000 n ' || CHR(10);
        END;
    BEGIN
        v_stream :=
            'BT /F1 26 Tf 155 750 Td (QUIZ RESULT CERTIFICATE) Tj ET' || CHR(10) ||
            'BT /F1 14 Tf 72 700 Td (This certifies that) Tj ET' || CHR(10) ||
            'BT /F1 20 Tf 72 660 Td (' || pdf_ascii(SUBSTR(p_user_name, 1, 52)) || ') Tj ET' || CHR(10) ||
            'BT /F1 14 Tf 72 620 Td (completed the quiz) Tj ET' || CHR(10) ||
            'BT /F1 18 Tf 72 580 Td (' || pdf_ascii(SUBSTR(p_test_title, 1, 58)) || ') Tj ET' || CHR(10) ||
            'BT /F1 14 Tf 72 530 Td (Score: ' || TO_CHAR(p_score) || ' / ' ||
                TO_CHAR(p_max_score) || '  -  ' || TO_CHAR(p_percent, 'FM990D00',
                    'NLS_NUMERIC_CHARACTERS=''.,''') || '%) Tj ET' || CHR(10) ||
            'BT /F1 12 Tf 72 485 Td (Certificate: ' || pdf_ascii(p_certificate_no) || ') Tj ET' || CHR(10) ||
            'BT /F1 12 Tf 72 455 Td (Issued: ' ||
                TO_CHAR(p_issued_at, 'YYYY-MM-DD HH24:MI:SS') || ' UTC) Tj ET' || CHR(10) ||
            '0.2 w 72 430 m 523 430 l S' || CHR(10) ||
            'BT /F1 9 Tf 72 405 Td (Generated by Oracle PL/SQL Quiz Platform) Tj ET';

        DBMS_LOB.CREATETEMPORARY(v_pdf, TRUE);
        app('%PDF-1.4' || CHR(10) || '%OracleQuiz' || CHR(10));

        v_off1 := DBMS_LOB.GETLENGTH(v_pdf);
        app('1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj' || CHR(10));
        v_off2 := DBMS_LOB.GETLENGTH(v_pdf);
        app('2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj' || CHR(10));
        v_off3 := DBMS_LOB.GETLENGTH(v_pdf);
        app('3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' ||
            '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >> endobj' || CHR(10));
        v_off4 := DBMS_LOB.GETLENGTH(v_pdf);
        app('4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj' || CHR(10));
        v_off5 := DBMS_LOB.GETLENGTH(v_pdf);
        app('5 0 obj << /Length ' || LENGTHB(v_stream) || ' >> stream' || CHR(10) ||
            v_stream || CHR(10) || 'endstream endobj' || CHR(10));

        v_xref := DBMS_LOB.GETLENGTH(v_pdf);
        app('xref' || CHR(10) || '0 6' || CHR(10));
        app('0000000000 65535 f ' || CHR(10));
        app(xref_line(v_off1));
        app(xref_line(v_off2));
        app(xref_line(v_off3));
        app(xref_line(v_off4));
        app(xref_line(v_off5));
        app('trailer << /Size 6 /Root 1 0 R >>' || CHR(10) ||
            'startxref' || CHR(10) || v_xref || CHR(10) || '%%EOF' || CHR(10));

        DBMS_LOB.CREATETEMPORARY(v_blob, TRUE);
        DBMS_LOB.CONVERTTOBLOB(
            dest_lob     => v_blob,
            src_clob     => v_pdf,
            amount       => DBMS_LOB.LOBMAXSIZE,
            dest_offset  => v_dest_off,
            src_offset   => v_src_off,
            blob_csid    => NLS_CHARSET_ID('AL32UTF8'),
            lang_context => v_context,
            warning      => v_warning
        );
        DBMS_LOB.FREETEMPORARY(v_pdf);
        RETURN v_blob;
    END make_certificate_pdf;

    PROCEDURE assign_badges_internal(p_attempt_id IN NUMBER) IS
        v_user_id       NUMBER;
        v_percent       NUMBER;
        v_started_at    TIMESTAMP;
        v_finished_at   TIMESTAMP;
        v_pass_percent  NUMBER;
        v_attempts      NUMBER;
        v_tests         NUMBER;
        v_elapsed       NUMBER;
        v_eligible      CHAR(1);
    BEGIN
        SELECT a.user_id, a.percent_score, a.started_at, a.finished_at,
               t.pass_percent
          INTO v_user_id, v_percent, v_started_at, v_finished_at,
               v_pass_percent
          FROM qp_attempts a
          JOIN qp_tests t ON t.test_id = a.test_id
         WHERE a.attempt_id = p_attempt_id
           AND a.attempt_status IN ('COMPLETED', 'TIMED_OUT');

        SELECT COUNT(*), COUNT(DISTINCT test_id)
          INTO v_attempts, v_tests
          FROM qp_attempts
         WHERE user_id = v_user_id
           AND attempt_status IN ('COMPLETED', 'TIMED_OUT');

        v_elapsed := (CAST(v_finished_at AS DATE) - CAST(v_started_at AS DATE)) * 86400;

        FOR b IN (
            SELECT badge_id, rule_code, threshold_value
              FROM qp_badges
             WHERE active_flag = 'Y'
             ORDER BY badge_id
        ) LOOP
            v_eligible := CASE b.rule_code
                WHEN 'FIRST_ATTEMPT' THEN CASE WHEN v_attempts = 1 THEN 'Y' ELSE 'N' END
                WHEN 'PERFECT_SCORE' THEN CASE WHEN v_percent = 100 THEN 'Y' ELSE 'N' END
                WHEN 'SCORE_AT_LEAST' THEN CASE WHEN v_percent >= NVL(b.threshold_value, 0) THEN 'Y' ELSE 'N' END
                WHEN 'TESTS_COMPLETED' THEN CASE WHEN v_tests >= NVL(b.threshold_value, 1) THEN 'Y' ELSE 'N' END
                WHEN 'FAST_FINISH' THEN CASE
                    WHEN v_percent >= v_pass_percent
                     AND v_elapsed <= NVL(b.threshold_value, 300) THEN 'Y'
                    ELSE 'N'
                END
                ELSE 'N'
            END;

            IF v_eligible = 'Y' THEN
                INSERT INTO qp_user_badges (user_id, badge_id, attempt_id)
                SELECT v_user_id, b.badge_id, p_attempt_id
                  FROM dual
                 WHERE NOT EXISTS (
                     SELECT 1
                       FROM qp_user_badges ub
                      WHERE ub.user_id = v_user_id
                        AND ub.badge_id = b.badge_id
                 );
            END IF;
        END LOOP;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            NULL;
    END assign_badges_internal;

    PROCEDURE rebuild_ratings_internal(p_period_code IN VARCHAR2) IS
        v_period           VARCHAR2(10) := UPPER(TRIM(p_period_code));
        v_from             TIMESTAMP;
        v_rank             PLS_INTEGER := 0;
        v_previous_score   NUMBER;
        v_previous_percent NUMBER;
    BEGIN
        IF v_period NOT IN ('WEEK', 'MONTH', 'ALL') THEN
            fail(-20014, 'Период рейтинга: WEEK, MONTH или ALL.');
        END IF;

        v_from := CASE v_period
            WHEN 'WEEK' THEN CAST(TRUNC(SYSDATE, 'IW') AS TIMESTAMP)
            WHEN 'MONTH' THEN CAST(TRUNC(SYSDATE, 'MM') AS TIMESTAMP)
            ELSE NULL
        END;

        DELETE FROM qp_rating_snapshots WHERE period_code = v_period;

        FOR r IN (
            SELECT user_id,
                   SUM(score) AS total_score,
                   COUNT(*) AS completed_attempts,
                   AVG(percent_score) AS average_percent
              FROM qp_attempts
             WHERE attempt_status IN ('COMPLETED', 'TIMED_OUT')
               AND (v_from IS NULL OR finished_at >= v_from)
             GROUP BY user_id
             ORDER BY total_score DESC, average_percent DESC
        ) LOOP
            IF v_rank = 0
               OR r.total_score <> v_previous_score
               OR r.average_percent <> v_previous_percent THEN
                v_rank := v_rank + 1;
            END IF;
            INSERT INTO qp_rating_snapshots (
                rating_type, user_id, team_id, period_code, total_score,
                completed_attempts, rank_no, calculated_at
            ) VALUES (
                'USER', r.user_id, NULL, v_period, r.total_score,
                r.completed_attempts, v_rank, SYS_EXTRACT_UTC(SYSTIMESTAMP)
            );
            v_previous_score := r.total_score;
            v_previous_percent := r.average_percent;
        END LOOP;

        v_rank := 0;
        v_previous_score := NULL;
        v_previous_percent := NULL;
        FOR r IN (
            SELECT team_id,
                   SUM(score) AS total_score,
                   COUNT(*) AS completed_attempts,
                   AVG(percent_score) AS average_percent
              FROM qp_attempts
             WHERE attempt_status IN ('COMPLETED', 'TIMED_OUT')
               AND team_id IS NOT NULL
               AND (v_from IS NULL OR finished_at >= v_from)
             GROUP BY team_id
             ORDER BY total_score DESC, average_percent DESC
        ) LOOP
            IF v_rank = 0
               OR r.total_score <> v_previous_score
               OR r.average_percent <> v_previous_percent THEN
                v_rank := v_rank + 1;
            END IF;
            INSERT INTO qp_rating_snapshots (
                rating_type, user_id, team_id, period_code, total_score,
                completed_attempts, rank_no, calculated_at
            ) VALUES (
                'TEAM', NULL, r.team_id, v_period, r.total_score,
                r.completed_attempts, v_rank, SYS_EXTRACT_UTC(SYSTIMESTAMP)
            );
            v_previous_score := r.total_score;
            v_previous_percent := r.average_percent;
        END LOOP;
    END rebuild_ratings_internal;

    PROCEDURE generate_certificate_internal(p_attempt_id IN NUMBER) IS
        v_user_name      VARCHAR2(100);
        v_test_title     VARCHAR2(255);
        v_score          NUMBER;
        v_max_score      NUMBER;
        v_percent        NUMBER;
        v_finished_at    TIMESTAMP;
        v_existing       NUMBER;
        v_certificate_no VARCHAR2(64);
        v_token          VARCHAR2(64);
        v_pdf             BLOB;
    BEGIN
        SELECT u.display_name, t.test_title, a.score, a.max_score,
               a.percent_score, a.finished_at
          INTO v_user_name, v_test_title, v_score, v_max_score,
               v_percent, v_finished_at
          FROM qp_attempts a
          JOIN qp_users u ON u.user_id = a.user_id
          JOIN qp_tests t ON t.test_id = a.test_id
         WHERE a.attempt_id = p_attempt_id
           AND a.attempt_status IN ('COMPLETED', 'TIMED_OUT');

        SELECT COUNT(*)
          INTO v_existing
          FROM qp_certificates
         WHERE attempt_id = p_attempt_id;
        IF v_existing > 0 THEN
            RETURN;
        END IF;

        v_certificate_no := 'QP-' || TO_CHAR(SYSDATE, 'YYYY') || '-' ||
                            LPAD(p_attempt_id, 8, '0') || '-' ||
                            SUBSTR(RAWTOHEX(SYS_GUID()), 1, 8);
        v_token := RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID());
        v_pdf := make_certificate_pdf(
            v_certificate_no, v_user_name, v_test_title,
            v_score, v_max_score, v_percent, NVL(v_finished_at, SYS_EXTRACT_UTC(SYSTIMESTAMP))
        );

        INSERT INTO qp_certificates (
            attempt_id, certificate_no, issued_at, verification_token,
            pdf_data, mime_type, file_name
        ) VALUES (
            p_attempt_id, v_certificate_no, SYS_EXTRACT_UTC(SYSTIMESTAMP), v_token,
            v_pdf, 'application/pdf', v_certificate_no || '.pdf'
        );
        IF DBMS_LOB.ISTEMPORARY(v_pdf) = 1 THEN
            DBMS_LOB.FREETEMPORARY(v_pdf);
        END IF;
    END generate_certificate_internal;

    PROCEDURE recalculate_result_internal(p_attempt_id IN NUMBER) IS
        v_score          NUMBER;
        v_max_score      NUMBER;
        v_correct        NUMBER;
        v_selected       NUMBER;
        v_target         NUMBER;
        v_adaptive       CHAR(1);
        v_test_id        NUMBER;
        v_average_points NUMBER;
    BEGIN
        SELECT a.target_question_count, t.adaptive_flag, a.test_id
          INTO v_target, v_adaptive, v_test_id
          FROM qp_attempts a
          JOIN qp_tests t ON t.test_id = a.test_id
         WHERE a.attempt_id = p_attempt_id;

        SELECT NVL(SUM(aq.points_awarded), 0),
               NVL(SUM(q.points), 0),
               COUNT(CASE WHEN aq.is_correct = 'Y' THEN 1 END),
               COUNT(*)
          INTO v_score, v_max_score, v_correct, v_selected
          FROM qp_attempt_questions aq
          JOIN qp_questions q ON q.question_id = aq.question_id
         WHERE aq.attempt_id = p_attempt_id;

        IF v_adaptive = 'Y' AND v_selected < v_target THEN
            SELECT NVL(AVG(points), 1)
              INTO v_average_points
              FROM qp_questions
             WHERE test_id = v_test_id
               AND active_flag = 'Y'
               AND adaptive_flag = 'Y';
            v_max_score := v_max_score + (v_target - v_selected) * v_average_points;
        END IF;

        UPDATE qp_attempts
           SET score = v_score,
               max_score = v_max_score,
               percent_score = CASE
                   WHEN v_max_score = 0 THEN 0
                   ELSE ROUND(v_score / v_max_score * 100, 2)
               END,
               correct_count = v_correct
         WHERE attempt_id = p_attempt_id;
    END recalculate_result_internal;

    PROCEDURE finalize_attempt_internal(
        p_attempt_id IN NUMBER,
        p_status     IN VARCHAR2,
        p_reason     IN VARCHAR2
    ) IS
        v_user_id NUMBER;
    BEGIN
        UPDATE qp_attempt_questions
           SET question_status = 'TIMED_OUT',
               answered_at = NVL(answered_at, SYS_EXTRACT_UTC(SYSTIMESTAMP)),
               is_correct = NVL(is_correct, 'N'),
               points_awarded = NVL(points_awarded, 0)
         WHERE attempt_id = p_attempt_id
           AND question_status IN ('PENDING', 'ACTIVE');

        UPDATE qp_attempts
           SET attempt_status = p_status,
               finished_at = NVL(finished_at, SYS_EXTRACT_UTC(SYSTIMESTAMP)),
               finish_reason = p_reason
         WHERE attempt_id = p_attempt_id
           AND attempt_status = 'IN_PROGRESS';

        IF SQL%ROWCOUNT = 0 THEN
            RETURN;
        END IF;

        SELECT user_id INTO v_user_id
          FROM qp_attempts
         WHERE attempt_id = p_attempt_id;

        recalculate_result_internal(p_attempt_id);
        assign_badges_internal(p_attempt_id);
        generate_certificate_internal(p_attempt_id);
        rebuild_ratings_internal('ALL');
        rebuild_ratings_internal('WEEK');
        rebuild_ratings_internal('MONTH');
        audit_event(v_user_id, 'ATTEMPT_FINISHED', 'ATTEMPT', p_attempt_id, p_reason);
    END finalize_attempt_internal;

    PROCEDURE expire_due_state(p_attempt_id IN NUMBER) IS
        v_status        VARCHAR2(20);
        v_deadline      TIMESTAMP;
        v_adaptive      CHAR(1);
        v_question_rows NUMBER;
    BEGIN
        SELECT a.attempt_status, a.deadline_at, t.adaptive_flag
          INTO v_status, v_deadline, v_adaptive
          FROM qp_attempts a
          JOIN qp_tests t ON t.test_id = a.test_id
         WHERE a.attempt_id = p_attempt_id
         FOR UPDATE OF a.attempt_status;

        IF v_status <> 'IN_PROGRESS' THEN
            RETURN;
        END IF;

        IF v_deadline IS NOT NULL AND v_deadline <= SYS_EXTRACT_UTC(SYSTIMESTAMP) THEN
            finalize_attempt_internal(p_attempt_id, 'TIMED_OUT', 'TEST_TIMER');
            RETURN;
        END IF;

        UPDATE qp_attempt_questions
           SET question_status = 'TIMED_OUT',
               answered_at = SYS_EXTRACT_UTC(SYSTIMESTAMP),
               is_correct = 'N',
               points_awarded = 0
         WHERE attempt_id = p_attempt_id
           AND question_status = 'ACTIVE'
           AND deadline_at IS NOT NULL
           AND deadline_at <= SYS_EXTRACT_UTC(SYSTIMESTAMP);
        v_question_rows := SQL%ROWCOUNT;

        IF v_question_rows > 0 AND v_adaptive = 'Y' THEN
            UPDATE qp_attempts
               SET current_difficulty = GREATEST(1, current_difficulty - 1)
             WHERE attempt_id = p_attempt_id;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20011, 'Попытка не найдена.');
    END expire_due_state;

    PROCEDURE info IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('Oracle Quiz Platform');
        DBMS_OUTPUT.PUT_LINE('1. register_user / login');
        DBMS_OUTPUT.PUT_LINE('2. create_test / add_question / publish_test');
        DBMS_OUTPUT.PUT_LINE('3. start_attempt / get_next_question / submit_answer');
        DBMS_OUTPUT.PUT_LINE('4. get_attempt_result / show_statistics / get_leaderboard');
        DBMS_OUTPUT.PUT_LINE('Вся проверка, таймеры, адаптация и выдача PDF выполняются в Oracle.');
    END info;

    PROCEDURE register_user(
        p_display_name     IN  VARCHAR2,
        p_email            IN  VARCHAR2,
        p_password         IN  VARCHAR2,
        p_password_repeat  IN  VARCHAR2,
        p_game_username    IN  VARCHAR2,
        p_user_role        IN  VARCHAR2,
        p_user_id          OUT NUMBER
    ) IS
        v_salt          VARCHAR2(32);
        v_password_hash VARCHAR2(64);
        v_email         VARCHAR2(255) := LOWER(TRIM(p_email));
        v_account_key   VARCHAR2(128) := UPPER(TRIM(p_game_username));
        v_role          VARCHAR2(20) := UPPER(TRIM(p_user_role));
    BEGIN
        IF p_display_name IS NULL OR LENGTH(TRIM(p_display_name)) < 2 THEN
            fail(-20015, 'Имя должно содержать не менее двух символов.');
        END IF;
        IF v_email IS NULL OR NOT REGEXP_LIKE(v_email, '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') THEN
            fail(-20016, 'Укажите корректный адрес электронной почты.');
        END IF;
        IF p_password IS NULL OR LENGTH(p_password) < 8 THEN
            fail(-20017, 'Пароль должен содержать не менее восьми символов.');
        END IF;
        IF p_password_repeat IS NULL OR p_password <> p_password_repeat THEN
            fail(-20065, 'Пароли не совпадают.');
        END IF;
        IF v_account_key IS NULL OR
           (LENGTH(TRIM(p_game_username)) > 64 OR
            NOT REGEXP_LIKE(v_account_key, '^[A-Z][A-Z0-9_]{2,63}$')) THEN
            fail(-20064, 'Логин: 3–64 латинские буквы, цифры или подчёркивания; первый символ — буква.');
        END IF;
        IF v_role IS NULL OR v_role NOT IN ('PARTICIPANT', 'AUTHOR') THEN
            fail(-20082, 'При регистрации выберите роль участника или автора.');
        END IF;
        v_salt := RAWTOHEX(SYS_GUID());
        v_password_hash := password_hash(p_password, v_salt);
        INSERT INTO qp_users (
            oracle_username, display_name, email, password_salt,
            password_hash, user_role, user_status
        ) VALUES (
            v_account_key, TRIM(p_display_name), v_email, v_salt,
            v_password_hash, v_role, 'ACTIVE'
        ) RETURNING user_id INTO p_user_id;

        audit_event(p_user_id, 'USER_REGISTERED', 'USER', p_user_id, v_email);
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            fail(-20018, 'Логин или email уже зарегистрирован.');
    END register_user;

    PROCEDURE login(
        p_login            IN  VARCHAR2,
        p_password         IN  VARCHAR2,
        p_client_label     IN  VARCHAR2 DEFAULT NULL,
        p_session_token    OUT VARCHAR2,
        p_user_id          OUT NUMBER,
        p_display_name     OUT VARCHAR2,
        p_user_role        OUT VARCHAR2
    ) IS
        v_salt       VARCHAR2(32);
        v_hash       VARCHAR2(64);
        v_saved_hash VARCHAR2(64);
        v_status     VARCHAR2(20);
    BEGIN
        IF p_login IS NULL OR p_password IS NULL THEN
            fail(-20019, 'Неверный логин или пароль.');
        END IF;
        SELECT user_id, display_name, user_role, user_status,
               password_salt, password_hash
          INTO p_user_id, p_display_name, p_user_role, v_status,
               v_salt, v_saved_hash
          FROM qp_users
         WHERE UPPER(oracle_username) = UPPER(TRIM(p_login));

        v_hash := password_hash(p_password, v_salt);
        IF v_hash <> v_saved_hash THEN
            fail(-20019, 'Неверный логин или пароль.');
        END IF;
        IF v_status <> 'ACTIVE' THEN
            fail(-20020, 'Учетная запись заблокирована.');
        END IF;

        UPDATE qp_sessions
           SET revoked_flag = 'Y'
         WHERE user_id = p_user_id
           AND revoked_flag = 'N';

        p_session_token := RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID());
        INSERT INTO qp_sessions (
            session_token, user_id, expires_at, client_label
        ) VALUES (
            p_session_token, p_user_id,
            SYS_EXTRACT_UTC(SYSTIMESTAMP) + NUMTODSINTERVAL(c_session_hours, 'HOUR'),
            SUBSTR(p_client_label, 1, 255)
        );
        audit_event(p_user_id, 'LOGIN', 'USER', p_user_id, p_client_label);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20019, 'Неверный логин или пароль.');
    END login;

    PROCEDURE login_oracle(
        p_client_label     IN  VARCHAR2 DEFAULT NULL,
        p_session_token    OUT VARCHAR2,
        p_user_id          OUT NUMBER,
        p_display_name     OUT VARCHAR2,
        p_user_role        OUT VARCHAR2
    ) IS
    BEGIN
        fail(-20081, 'Use a game login and password.');
    END login_oracle;

    PROCEDURE logout(p_session_token IN VARCHAR2) IS
        v_user_id NUMBER;
    BEGIN
        SELECT user_id INTO v_user_id
          FROM qp_sessions
         WHERE session_token = p_session_token;

        UPDATE qp_sessions
           SET revoked_flag = 'Y', last_seen_at = SYS_EXTRACT_UTC(SYSTIMESTAMP)
         WHERE session_token = p_session_token;
        audit_event(v_user_id, 'LOGOUT', 'USER', v_user_id, NULL);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN NULL;
    END logout;

    PROCEDURE create_category(
        p_session_token    IN  VARCHAR2,
        p_category_name    IN  VARCHAR2,
        p_description      IN  VARCHAR2 DEFAULT NULL,
        p_category_id      OUT NUMBER
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        IF TRIM(p_category_name) IS NULL THEN
            fail(-20021, 'Название категории не может быть пустым.');
        END IF;

        INSERT INTO qp_categories (category_name, description)
        VALUES (TRIM(p_category_name), p_description)
        RETURNING category_id INTO p_category_id;
        audit_event(v_user.user_id, 'CATEGORY_CREATED', 'CATEGORY', p_category_id, p_category_name);
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            fail(-20022, 'Категория с таким названием уже существует.');
    END create_category;

    PROCEDURE create_topic(
        p_session_token    IN  VARCHAR2,
        p_topic_name       IN  VARCHAR2,
        p_description      IN  VARCHAR2 DEFAULT NULL,
        p_topic_id         OUT NUMBER
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        IF TRIM(p_topic_name) IS NULL THEN
            fail(-20023, 'Название тематики не может быть пустым.');
        END IF;

        INSERT INTO qp_topics (owner_user_id, topic_name, description)
        VALUES (v_user.user_id, TRIM(p_topic_name), p_description)
        RETURNING topic_id INTO p_topic_id;
        audit_event(v_user.user_id, 'TOPIC_CREATED', 'TOPIC', p_topic_id, p_topic_name);
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            fail(-20024, 'Такая тематика уже создана.');
    END create_topic;

    PROCEDURE create_test(
        p_session_token        IN  VARCHAR2,
        p_title                IN  VARCHAR2,
        p_description          IN  VARCHAR2,
        p_primary_category_id  IN  NUMBER,
        p_access_mode          IN  VARCHAR2 DEFAULT 'PUBLIC',
        p_time_limit_minutes   IN  NUMBER DEFAULT NULL,
        p_question_count       IN  NUMBER DEFAULT NULL,
        p_pass_percent         IN  NUMBER DEFAULT 60,
        p_feedback_mode        IN  VARCHAR2 DEFAULT 'AFTER_TEST',
        p_show_correct_answers IN  CHAR DEFAULT 'Y',
        p_adaptive_flag        IN  CHAR DEFAULT 'N',
        p_team_mode_flag       IN  CHAR DEFAULT 'N',
        p_max_attempts         IN  NUMBER DEFAULT NULL,
        p_test_id              OUT NUMBER
    ) IS
        v_user           t_user_rec;
        v_access         VARCHAR2(20) := UPPER(TRIM(p_access_mode));
        v_feedback       VARCHAR2(20) := UPPER(TRIM(p_feedback_mode));
        v_category_count NUMBER;
        v_show_correct   CHAR(1);
        v_adaptive       CHAR(1);
        v_team_mode      CHAR(1);
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        IF TRIM(p_title) IS NULL THEN
            fail(-20025, 'Название теста не может быть пустым.');
        END IF;
        IF v_access IS NULL OR v_access NOT IN ('PUBLIC', 'RESTRICTED') THEN
            fail(-20026, 'Режим доступа: PUBLIC или RESTRICTED.');
        END IF;
        IF v_feedback IS NULL OR v_feedback NOT IN ('IMMEDIATE', 'AFTER_TEST', 'NEVER') THEN
            fail(-20027, 'Режим обратной связи: IMMEDIATE, AFTER_TEST или NEVER.');
        END IF;

        SELECT COUNT(*)
          INTO v_category_count
          FROM qp_categories
         WHERE category_id = p_primary_category_id;
        IF v_category_count = 0 THEN
            fail(-20028, 'Категория не найдена.');
        END IF;
        IF p_time_limit_minutes IS NOT NULL AND p_time_limit_minutes <= 0 THEN
            fail(-20065, 'Лимит времени теста должен быть положительным.');
        END IF;
        IF p_question_count IS NOT NULL AND p_question_count <= 0 THEN
            fail(-20066, 'Количество вопросов должно быть положительным.');
        END IF;
        IF p_pass_percent IS NULL OR p_pass_percent < 0 OR p_pass_percent > 100 THEN
            fail(-20067, 'Проходной процент должен находиться в диапазоне от 0 до 100.');
        END IF;
        IF p_max_attempts IS NOT NULL AND p_max_attempts <= 0 THEN
            fail(-20068, 'Лимит попыток должен быть положительным.');
        END IF;

        v_show_correct := norm_flag(p_show_correct_answers, 'Y');
        v_adaptive := norm_flag(p_adaptive_flag);
        v_team_mode := norm_flag(p_team_mode_flag);

        INSERT INTO qp_tests (
            author_user_id, primary_category_id, test_title, description,
            access_mode, time_limit_minutes, question_count, pass_percent,
            feedback_mode, show_correct_answers, adaptive_flag,
            team_mode_flag, max_attempts, test_status
        ) VALUES (
            v_user.user_id, p_primary_category_id, TRIM(p_title), p_description,
            v_access, p_time_limit_minutes, p_question_count, p_pass_percent,
            v_feedback, v_show_correct,
            v_adaptive, v_team_mode,
            p_max_attempts, 'DRAFT'
        ) RETURNING test_id INTO p_test_id;
        audit_event(v_user.user_id, 'TEST_CREATED', 'TEST', p_test_id, p_title);
    END create_test;

    PROCEDURE add_test_topic(
        p_session_token IN VARCHAR2,
        p_test_id       IN NUMBER,
        p_topic_id      IN NUMBER
    ) IS
        v_user  t_user_rec;
        v_owner NUMBER;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'Y');

        SELECT owner_user_id INTO v_owner
          FROM qp_topics
         WHERE topic_id = p_topic_id;
        IF v_user.user_role <> 'ADMIN' AND v_owner <> v_user.user_id THEN
            fail(-20029, 'Нельзя использовать чужую пользовательскую тематику.');
        END IF;

        INSERT INTO qp_test_topics (test_id, topic_id)
        VALUES (p_test_id, p_topic_id);
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN NULL;
        WHEN NO_DATA_FOUND THEN fail(-20030, 'Тематика не найдена.');
    END add_test_topic;

    PROCEDURE add_question(
        p_session_token       IN  VARCHAR2,
        p_test_id             IN  NUMBER,
        p_type_code           IN  VARCHAR2,
        p_category_id         IN  NUMBER,
        p_question_text       IN  CLOB,
        p_difficulty_level    IN  NUMBER DEFAULT 3,
        p_display_order       IN  NUMBER,
        p_points              IN  NUMBER DEFAULT 1,
        p_time_limit_seconds  IN  NUMBER DEFAULT NULL,
        p_adaptive_flag       IN  CHAR DEFAULT 'Y',
        p_explanation         IN  CLOB DEFAULT NULL,
        p_question_id         OUT NUMBER
    ) IS
        v_user           t_user_rec;
        v_type_id        NUMBER;
        v_category_count NUMBER;
        v_adaptive       CHAR(1);
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'Y');
        IF p_question_text IS NULL OR DBMS_LOB.GETLENGTH(p_question_text) = 0 THEN
            fail(-20031, 'Текст вопроса не может быть пустым.');
        END IF;

        SELECT question_type_id INTO v_type_id
          FROM qp_question_types
         WHERE type_code = UPPER(TRIM(p_type_code));

        SELECT COUNT(*)
          INTO v_category_count
          FROM qp_categories
         WHERE category_id = p_category_id;
        IF v_category_count = 0 THEN
            fail(-20028, 'Категория не найдена.');
        END IF;
        IF p_difficulty_level IS NULL OR p_difficulty_level NOT BETWEEN 1 AND 5 THEN
            fail(-20069, 'Сложность вопроса должна находиться в диапазоне от 1 до 5.');
        END IF;
        IF p_display_order IS NULL OR p_display_order <= 0 THEN
            fail(-20070, 'Порядковый номер вопроса должен быть положительным.');
        END IF;
        IF p_points IS NULL OR p_points <= 0 THEN
            fail(-20071, 'Количество баллов должно быть положительным.');
        END IF;
        IF p_time_limit_seconds IS NOT NULL AND p_time_limit_seconds <= 0 THEN
            fail(-20072, 'Лимит времени вопроса должен быть положительным.');
        END IF;

        v_adaptive := norm_flag(p_adaptive_flag, 'Y');

        INSERT INTO qp_questions (
            test_id, question_type_id, category_id, question_text,
            difficulty_level, display_order, points, time_limit_seconds,
            adaptive_flag, explanation
        ) VALUES (
            p_test_id, v_type_id, p_category_id, p_question_text,
            p_difficulty_level, p_display_order, p_points,
            p_time_limit_seconds, v_adaptive,
            p_explanation
        ) RETURNING question_id INTO p_question_id;
        audit_event(v_user.user_id, 'QUESTION_CREATED', 'QUESTION', p_question_id, NULL);
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            fail(-20032, 'Порядковый номер вопроса уже занят в этом тесте.');
        WHEN NO_DATA_FOUND THEN
            fail(-20033, 'Тип вопроса не найден.');
    END add_question;

    PROCEDURE add_answer_option(
        p_session_token     IN  VARCHAR2,
        p_question_id       IN  NUMBER,
        p_option_text       IN  VARCHAR2,
        p_is_correct        IN  CHAR DEFAULT 'N',
        p_display_order     IN  NUMBER,
        p_correct_order     IN  NUMBER DEFAULT NULL,
        p_match_key         IN  VARCHAR2 DEFAULT NULL,
        p_option_id         OUT NUMBER
    ) IS
        v_user       t_user_rec;
        v_test_id    NUMBER;
        v_is_correct CHAR(1);
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        SELECT test_id INTO v_test_id
          FROM qp_questions
         WHERE question_id = p_question_id;
        assert_test_owner(v_user, v_test_id, 'Y');
        IF TRIM(p_option_text) IS NULL THEN
            fail(-20034, 'Текст варианта не может быть пустым.');
        END IF;
        IF p_display_order IS NULL OR p_display_order <= 0 THEN
            fail(-20079, 'Порядковый номер варианта должен быть положительным.');
        END IF;
        IF p_correct_order IS NOT NULL AND p_correct_order <= 0 THEN
            fail(-20080, 'Правильная позиция должна быть положительной.');
        END IF;

        v_is_correct := norm_flag(p_is_correct);

        INSERT INTO qp_answer_options (
            question_id, option_text, is_correct, display_order,
            correct_order, match_key
        ) VALUES (
            p_question_id, TRIM(p_option_text), v_is_correct,
            p_display_order, p_correct_order, p_match_key
        ) RETURNING option_id INTO p_option_id;
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            fail(-20035, 'Порядковый номер варианта уже занят.');
        WHEN NO_DATA_FOUND THEN
            fail(-20036, 'Вопрос не найден.');
    END add_answer_option;

    PROCEDURE add_question_key(
        p_session_token       IN  VARCHAR2,
        p_question_id         IN  NUMBER,
        p_key_type            IN  VARCHAR2,
        p_accepted_text       IN  VARCHAR2 DEFAULT NULL,
        p_numeric_value       IN  NUMBER DEFAULT NULL,
        p_numeric_tolerance   IN  NUMBER DEFAULT 0,
        p_case_sensitive_flag IN  CHAR DEFAULT 'N',
        p_key_id              OUT NUMBER
    ) IS
        v_user     t_user_rec;
        v_test_id  NUMBER;
        v_type     VARCHAR2(20) := UPPER(TRIM(p_key_type));
        v_case_sensitive CHAR(1);
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        SELECT test_id INTO v_test_id
          FROM qp_questions
         WHERE question_id = p_question_id;
        assert_test_owner(v_user, v_test_id, 'Y');

        IF v_type IS NULL OR v_type NOT IN ('TEXT', 'REGEX', 'NUMBER') THEN
            fail(-20073, 'Тип ключа: TEXT, REGEX или NUMBER.');
        END IF;
        IF v_type IN ('TEXT', 'REGEX') AND TRIM(p_accepted_text) IS NULL THEN
            fail(-20074, 'Для текстового ключа требуется непустой эталон.');
        END IF;
        IF v_type = 'NUMBER' AND p_numeric_value IS NULL THEN
            fail(-20075, 'Для числового ключа требуется число.');
        END IF;
        IF v_type = 'NUMBER' AND NVL(p_numeric_tolerance, 0) < 0 THEN
            fail(-20076, 'Числовая погрешность не может быть отрицательной.');
        END IF;

        v_case_sensitive := norm_flag(p_case_sensitive_flag);

        INSERT INTO qp_question_keys (
            question_id, key_type, accepted_text, numeric_value,
            numeric_tolerance, case_sensitive_flag
        ) VALUES (
            p_question_id, v_type,
            CASE WHEN v_type IN ('TEXT', 'REGEX') THEN p_accepted_text END,
            CASE WHEN v_type = 'NUMBER' THEN p_numeric_value END,
            CASE WHEN v_type = 'NUMBER' THEN NVL(p_numeric_tolerance, 0) ELSE NULL END,
            v_case_sensitive
        ) RETURNING key_id INTO p_key_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20036, 'Вопрос не найден.');
    END add_question_key;

    PROCEDURE add_generation_rule(
        p_session_token    IN  VARCHAR2,
        p_test_id          IN  NUMBER,
        p_category_id      IN  NUMBER DEFAULT NULL,
        p_difficulty_level IN  NUMBER DEFAULT NULL,
        p_question_count   IN  NUMBER,
        p_rule_id          OUT NUMBER
    ) IS
        v_user           t_user_rec;
        v_category_count NUMBER;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'Y');
        IF p_category_id IS NOT NULL THEN
            SELECT COUNT(*)
              INTO v_category_count
              FROM qp_categories
             WHERE category_id = p_category_id;
            IF v_category_count = 0 THEN
                fail(-20028, 'Категория не найдена.');
            END IF;
        END IF;
        IF p_difficulty_level IS NOT NULL
           AND p_difficulty_level NOT BETWEEN 1 AND 5 THEN
            fail(-20081, 'Сложность правила должна находиться в диапазоне от 1 до 5.');
        END IF;
        IF p_question_count IS NULL OR p_question_count <= 0 THEN
            fail(-20082, 'Количество вопросов в правиле должно быть положительным.');
        END IF;
        INSERT INTO qp_test_rules (
            test_id, category_id, difficulty_level, question_count
        ) VALUES (
            p_test_id, p_category_id, p_difficulty_level, p_question_count
        ) RETURNING rule_id INTO p_rule_id;
    END add_generation_rule;

    PROCEDURE set_question_image(
        p_session_token IN VARCHAR2,
        p_question_id   IN NUMBER,
        p_file_name     IN VARCHAR2,
        p_mime_type     IN VARCHAR2,
        p_image_data    IN BLOB
    ) IS
        v_user    t_user_rec;
        v_test_id NUMBER;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        SELECT test_id INTO v_test_id FROM qp_questions WHERE question_id = p_question_id;
        assert_test_owner(v_user, v_test_id, 'Y');

        IF p_image_data IS NULL OR DBMS_LOB.GETLENGTH(p_image_data) = 0 THEN
            fail(-20037, 'Файл изображения пуст.');
        END IF;
        IF TRIM(p_file_name) IS NULL THEN
            fail(-20077, 'Не указано имя файла изображения.');
        END IF;
        IF TRIM(p_mime_type) IS NULL THEN
            fail(-20083, 'Не указан MIME-тип изображения.');
        END IF;
        IF DBMS_LOB.GETLENGTH(p_image_data) > c_max_image_bytes THEN
            fail(-20038, 'Размер изображения превышает 10 МБ.');
        END IF;
        IF LOWER(p_mime_type) NOT IN ('image/png', 'image/jpeg', 'image/gif', 'image/webp') THEN
            fail(-20039, 'Допустимы PNG, JPEG, GIF и WebP.');
        END IF;

        UPDATE qp_questions
           SET image_data = p_image_data,
               image_mime_type = LOWER(p_mime_type),
               image_file_name = SUBSTR(p_file_name, 1, 255)
         WHERE question_id = p_question_id;
    END set_question_image;

    PROCEDURE set_option_image(
        p_session_token IN VARCHAR2,
        p_option_id     IN NUMBER,
        p_file_name     IN VARCHAR2,
        p_mime_type     IN VARCHAR2,
        p_image_data    IN BLOB
    ) IS
        v_user    t_user_rec;
        v_test_id NUMBER;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        SELECT q.test_id INTO v_test_id
          FROM qp_answer_options o
          JOIN qp_questions q ON q.question_id = o.question_id
         WHERE o.option_id = p_option_id;
        assert_test_owner(v_user, v_test_id, 'Y');

        IF p_image_data IS NULL OR DBMS_LOB.GETLENGTH(p_image_data) = 0 THEN
            fail(-20037, 'Файл изображения пуст.');
        END IF;
        IF TRIM(p_file_name) IS NULL THEN
            fail(-20077, 'Не указано имя файла изображения.');
        END IF;
        IF TRIM(p_mime_type) IS NULL THEN
            fail(-20083, 'Не указан MIME-тип изображения.');
        END IF;
        IF DBMS_LOB.GETLENGTH(p_image_data) > c_max_image_bytes THEN
            fail(-20038, 'Размер изображения превышает 10 МБ.');
        END IF;
        IF LOWER(p_mime_type) NOT IN ('image/png', 'image/jpeg', 'image/gif', 'image/webp') THEN
            fail(-20039, 'Допустимы PNG, JPEG, GIF и WebP.');
        END IF;

        UPDATE qp_answer_options
           SET image_data = p_image_data,
               image_mime_type = LOWER(p_mime_type),
               image_file_name = SUBSTR(p_file_name, 1, 255)
         WHERE option_id = p_option_id;
    END set_option_image;

    PROCEDURE publish_test(
        p_session_token IN VARCHAR2,
        p_test_id       IN NUMBER
    ) IS
        v_user            t_user_rec;
        v_question_count  NUMBER;
        v_bad_count       NUMBER;
        v_rule_shortage   NUMBER;
        v_target_count    NUMBER;
        v_adaptive        CHAR(1);
        v_rule_count      NUMBER;
        v_rule_target     NUMBER;
        v_eligible_count  NUMBER;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'Y');

        SELECT COUNT(*) INTO v_question_count
          FROM qp_questions
         WHERE test_id = p_test_id AND active_flag = 'Y';
        IF v_question_count = 0 THEN
            fail(-20040, 'Нельзя опубликовать тест без вопросов.');
        END IF;

        SELECT COUNT(*)
          INTO v_bad_count
          FROM qp_questions q
          JOIN qp_question_types qt ON qt.question_type_id = q.question_type_id
         WHERE q.test_id = p_test_id
           AND q.active_flag = 'Y'
           AND (
               (qt.type_code IN ('SINGLE', 'TRUE_FALSE') AND
                    ((SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id) < 2
                     OR
                     (SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id AND o.is_correct = 'Y') <> 1))
               OR
               (qt.type_code = 'MULTIPLE' AND
                    ((SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id) < 2
                     OR
                     (SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id AND o.is_correct = 'Y') < 1))
               OR
               (qt.type_code = 'ORDERING' AND
                    ((SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id) < 2
                     OR
                     (SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id AND o.correct_order IS NULL) > 0
                     OR
                     (SELECT MIN(o.correct_order) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id) <> 1
                     OR
                     (SELECT MAX(o.correct_order) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id) <>
                     (SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id)))
               OR
               (qt.type_code = 'MATCHING' AND
                    ((SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id) < 2
                     OR
                     (SELECT COUNT(*) FROM qp_answer_options o
                       WHERE o.question_id = q.question_id
                         AND TRIM(o.match_key) IS NULL) > 0))
               OR
               (qt.type_code = 'TEXT' AND
                    (SELECT COUNT(*) FROM qp_question_keys k
                      WHERE k.question_id = q.question_id
                        AND k.key_type IN ('TEXT', 'REGEX')) = 0)
               OR
               (qt.type_code = 'NUMBER' AND
                    (SELECT COUNT(*) FROM qp_question_keys k
                      WHERE k.question_id = q.question_id
                        AND k.key_type = 'NUMBER') = 0)
           );
        IF v_bad_count > 0 THEN
            fail(-20041, 'Есть вопросы без полного набора правильных ответов или ключей.');
        END IF;

        SELECT COUNT(*)
          INTO v_rule_shortage
          FROM qp_test_rules r
         WHERE r.test_id = p_test_id
           AND r.question_count > (
               SELECT COUNT(*)
                 FROM qp_questions q
                WHERE q.test_id = r.test_id
                  AND q.active_flag = 'Y'
                  AND (r.category_id IS NULL OR q.category_id = r.category_id)
                  AND (r.difficulty_level IS NULL OR q.difficulty_level = r.difficulty_level)
           );
        IF v_rule_shortage > 0 THEN
            fail(-20042, 'Банк вопросов не покрывает одно или несколько правил генерации.');
        END IF;

        SELECT question_count, adaptive_flag
          INTO v_target_count, v_adaptive
          FROM qp_tests WHERE test_id = p_test_id;

        SELECT COUNT(*), NVL(SUM(question_count), 0)
          INTO v_rule_count, v_rule_target
          FROM qp_test_rules
         WHERE test_id = p_test_id;

        IF v_adaptive = 'N'
           AND v_rule_count > 0
           AND v_target_count IS NOT NULL
           AND v_target_count <> v_rule_target THEN
            fail(-20078, 'Для теста с правилами число вопросов должно совпадать с суммой правил.');
        END IF;

        SELECT COUNT(*)
          INTO v_eligible_count
          FROM qp_questions q
         WHERE q.test_id = p_test_id
           AND q.active_flag = 'Y'
           AND (v_adaptive = 'N' OR q.adaptive_flag = 'Y')
           AND (
               v_adaptive = 'N'
               OR v_rule_count = 0
               OR EXISTS (
                   SELECT 1
                     FROM qp_test_rules r
                    WHERE r.test_id = p_test_id
                      AND (r.category_id IS NULL OR r.category_id = q.category_id)
                      AND (r.difficulty_level IS NULL OR r.difficulty_level = q.difficulty_level)
               )
           );

        IF v_adaptive = 'Y' THEN
            v_target_count := NVL(
                v_target_count,
                CASE WHEN v_rule_target > 0 THEN v_rule_target ELSE v_eligible_count END
            );
        ELSIF v_rule_count > 0 THEN
            v_target_count := v_rule_target;
        ELSE
            v_target_count := NVL(v_target_count, v_eligible_count);
        END IF;

        IF v_target_count > v_eligible_count THEN
            fail(-20043, 'Запрошено больше вопросов, чем есть в активном банке.');
        END IF;

        UPDATE qp_tests
           SET test_status = 'PUBLISHED', published_at = SYS_EXTRACT_UTC(SYSTIMESTAMP)
         WHERE test_id = p_test_id;
        audit_event(v_user.user_id, 'TEST_PUBLISHED', 'TEST', p_test_id, NULL);
    END publish_test;

    PROCEDURE grant_test_access(
        p_session_token   IN VARCHAR2,
        p_test_id         IN NUMBER,
        p_game_username IN VARCHAR2
    ) IS
        v_user t_user_rec;
        v_name VARCHAR2(128) := UPPER(TRIM(p_game_username));
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'N');
        SELECT UPPER(oracle_username) INTO v_name
          FROM qp_users
         WHERE UPPER(oracle_username) = v_name;

        MERGE INTO qp_test_access a
        USING (SELECT p_test_id test_id, v_name oracle_username FROM dual) x
           ON (a.test_id = x.test_id AND a.oracle_username = x.oracle_username)
        WHEN NOT MATCHED THEN
            INSERT (test_id, oracle_username, granted_by_user_id)
            VALUES (x.test_id, x.oracle_username, v_user.user_id);
        audit_event(v_user.user_id, 'TEST_ACCESS_GRANTED', 'TEST', p_test_id, v_name);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20006, '????? ? ????? ??????? ?? ???????????????.');
    END grant_test_access;

    PROCEDURE revoke_test_access(
        p_session_token   IN VARCHAR2,
        p_test_id         IN NUMBER,
        p_game_username IN VARCHAR2
    ) IS
        v_user t_user_rec;
        v_name VARCHAR2(128) := UPPER(TRIM(p_game_username));
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'N');
        DELETE FROM qp_test_access
         WHERE test_id = p_test_id
           AND oracle_username = v_name;
        audit_event(v_user.user_id, 'TEST_ACCESS_REVOKED', 'TEST', p_test_id, v_name);
    END revoke_test_access;

    PROCEDURE create_team(
        p_session_token IN  VARCHAR2,
        p_team_name     IN  VARCHAR2,
        p_team_id       OUT NUMBER,
        p_join_code     OUT VARCHAR2
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        IF TRIM(p_team_name) IS NULL THEN
            fail(-20044, 'Название команды не может быть пустым.');
        END IF;

        p_join_code := SUBSTR(RAWTOHEX(SYS_GUID()), 1, 8);
        INSERT INTO qp_teams (owner_user_id, team_name, join_code)
        VALUES (v_user.user_id, TRIM(p_team_name), p_join_code)
        RETURNING team_id INTO p_team_id;

        INSERT INTO qp_team_members (team_id, user_id, member_role)
        VALUES (p_team_id, v_user.user_id, 'CAPTAIN');
        audit_event(v_user.user_id, 'TEAM_CREATED', 'TEAM', p_team_id, p_team_name);
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            fail(-20045, 'Команда с таким названием уже существует.');
    END create_team;

    PROCEDURE join_team(
        p_session_token IN VARCHAR2,
        p_join_code     IN VARCHAR2
    ) IS
        v_user    t_user_rec;
        v_team_id NUMBER;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        SELECT team_id INTO v_team_id
          FROM qp_teams
         WHERE join_code = UPPER(TRIM(p_join_code))
           AND active_flag = 'Y';

        INSERT INTO qp_team_members (team_id, user_id, member_role)
        VALUES (v_team_id, v_user.user_id, 'MEMBER');
        audit_event(v_user.user_id, 'TEAM_JOINED', 'TEAM', v_team_id, NULL);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN fail(-20046, 'Команда с таким кодом не найдена.');
        WHEN DUP_VAL_ON_INDEX THEN fail(-20047, 'Пользователь уже состоит в этой команде.');
    END join_team;

    PROCEDURE start_attempt(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_team_id       IN  NUMBER DEFAULT NULL,
        p_attempt_id    OUT NUMBER
    ) IS
        v_user            t_user_rec;
        v_status          VARCHAR2(20);
        v_adaptive        CHAR(1);
        v_team_mode       CHAR(1);
        v_time_limit      NUMBER;
        v_test_target     NUMBER;
        v_max_attempts    NUMBER;
        v_attempt_count   NUMBER;
        v_active_count    NUMBER;
        v_bank_count      NUMBER;
        v_rule_count      NUMBER;
        v_target          NUMBER := 0;
        v_sequence        NUMBER := 0;
        v_inserted        NUMBER;
        v_max_score       NUMBER := 0;
    BEGIN
        require_session(p_session_token, NULL, v_user);

        SELECT test_status, adaptive_flag, team_mode_flag,
               time_limit_minutes, question_count, max_attempts
          INTO v_status, v_adaptive, v_team_mode,
               v_time_limit, v_test_target, v_max_attempts
          FROM qp_tests
         WHERE test_id = p_test_id;

        IF v_status <> 'PUBLISHED' THEN
            fail(-20048, 'Доступно прохождение только опубликованных тестов.');
        END IF;
        IF can_access_test(v_user.user_id, p_test_id) <> 'Y' THEN
            fail(-20049, 'Ваш игровой логин отсутствует в списке доступа.');
        END IF;

        SELECT COUNT(*) INTO v_active_count
          FROM qp_attempts
         WHERE user_id = v_user.user_id
           AND test_id = p_test_id
           AND attempt_status = 'IN_PROGRESS';
        IF v_active_count > 0 THEN
            fail(-20050, 'По этому тесту уже есть незавершенная попытка.');
        END IF;

        SELECT COUNT(*) INTO v_attempt_count
          FROM qp_attempts
         WHERE user_id = v_user.user_id
           AND test_id = p_test_id
           AND attempt_status IN ('COMPLETED', 'TIMED_OUT');
        IF v_max_attempts IS NOT NULL AND v_attempt_count >= v_max_attempts THEN
            fail(-20051, 'Исчерпан лимит попыток для этого теста.');
        END IF;

        IF v_team_mode = 'Y' THEN
            IF p_team_id IS NULL THEN
                fail(-20052, 'Для командного теста необходимо выбрать команду.');
            END IF;
            SELECT COUNT(*) INTO v_active_count
              FROM qp_team_members tm
              JOIN qp_teams t ON t.team_id = tm.team_id
             WHERE tm.team_id = p_team_id
               AND tm.user_id = v_user.user_id
               AND t.active_flag = 'Y';
            IF v_active_count = 0 THEN
                fail(-20053, 'Пользователь не состоит в выбранной команде.');
            END IF;
        ELSIF p_team_id IS NOT NULL THEN
            fail(-20054, 'Индивидуальная попытка не должна содержать команду.');
        END IF;

        SELECT COUNT(*), NVL(SUM(question_count), 0)
          INTO v_rule_count, v_target
          FROM qp_test_rules
         WHERE test_id = p_test_id;

        SELECT COUNT(*) INTO v_bank_count
          FROM qp_questions q
         WHERE q.test_id = p_test_id
           AND q.active_flag = 'Y'
           AND (v_adaptive = 'N' OR q.adaptive_flag = 'Y')
           AND (
               v_adaptive = 'N'
               OR v_rule_count = 0
               OR EXISTS (
                   SELECT 1
                     FROM qp_test_rules r
                    WHERE r.test_id = p_test_id
                      AND (r.category_id IS NULL OR r.category_id = q.category_id)
                      AND (r.difficulty_level IS NULL OR r.difficulty_level = q.difficulty_level)
               )
           );

        IF v_adaptive = 'Y' THEN
            v_target := NVL(v_test_target,
                            CASE WHEN v_target > 0 THEN v_target ELSE v_bank_count END);
        ELSIF v_rule_count = 0 THEN
            v_target := NVL(v_test_target, v_bank_count);
        END IF;

        IF v_target <= 0 OR v_bank_count <= 0 THEN
            fail(-20055, 'В тесте нет доступных вопросов.');
        END IF;
        IF v_target > v_bank_count THEN
            fail(-20043, 'Запрошено больше вопросов, чем есть в активном банке.');
        END IF;

        INSERT INTO qp_attempts (
            user_id, test_id, team_id, attempt_status, started_at,
            deadline_at, target_question_count, current_difficulty
        ) VALUES (
            v_user.user_id, p_test_id, p_team_id, 'IN_PROGRESS', SYS_EXTRACT_UTC(SYSTIMESTAMP),
            CASE WHEN v_time_limit IS NOT NULL
                 THEN SYS_EXTRACT_UTC(SYSTIMESTAMP) + NUMTODSINTERVAL(v_time_limit, 'MINUTE')
            END,
            v_target, 3
        ) RETURNING attempt_id INTO p_attempt_id;

        IF v_adaptive = 'N' THEN
            IF v_rule_count > 0 THEN
                FOR r IN (
                    SELECT rule_id, category_id, difficulty_level, question_count
                      FROM qp_test_rules
                     WHERE test_id = p_test_id
                     ORDER BY rule_id
                ) LOOP
                    INSERT INTO qp_attempt_questions (
                        attempt_id, question_id, sequence_no, question_status
                    )
                    SELECT p_attempt_id, question_id, v_sequence + random_no, 'PENDING'
                      FROM (
                          SELECT q.question_id,
                                 ROW_NUMBER() OVER (ORDER BY DBMS_RANDOM.VALUE) AS random_no
                            FROM qp_questions q
                           WHERE q.test_id = p_test_id
                             AND q.active_flag = 'Y'
                             AND (r.category_id IS NULL OR q.category_id = r.category_id)
                             AND (r.difficulty_level IS NULL OR q.difficulty_level = r.difficulty_level)
                             AND NOT EXISTS (
                                 SELECT 1
                                   FROM qp_attempt_questions aq
                                  WHERE aq.attempt_id = p_attempt_id
                                    AND aq.question_id = q.question_id
                             )
                      )
                     WHERE random_no <= r.question_count;

                    v_inserted := SQL%ROWCOUNT;
                    IF v_inserted < r.question_count THEN
                        fail(-20056, 'Недостаточно уникальных вопросов для правила #' || r.rule_id || '.');
                    END IF;
                    v_sequence := v_sequence + v_inserted;
                END LOOP;
            ELSE
                INSERT INTO qp_attempt_questions (
                    attempt_id, question_id, sequence_no, question_status
                )
                SELECT p_attempt_id, question_id, sequence_no, 'PENDING'
                  FROM (
                      SELECT q.question_id,
                             ROW_NUMBER() OVER (ORDER BY q.display_order) AS sequence_no
                        FROM qp_questions q
                       WHERE q.test_id = p_test_id
                         AND q.active_flag = 'Y'
                  )
                 WHERE sequence_no <= v_target;
            END IF;

            SELECT COUNT(*), NVL(SUM(q.points), 0)
              INTO v_inserted, v_max_score
              FROM qp_attempt_questions aq
              JOIN qp_questions q ON q.question_id = aq.question_id
             WHERE aq.attempt_id = p_attempt_id;

            UPDATE qp_attempts
               SET target_question_count = v_inserted,
                   max_score = v_max_score
             WHERE attempt_id = p_attempt_id;
        END IF;

        audit_event(v_user.user_id, 'ATTEMPT_STARTED', 'ATTEMPT', p_attempt_id,
                    'test_id=' || p_test_id);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20009, 'Тест не найден.');
    END start_attempt;

    PROCEDURE open_empty_question(
        p_question OUT SYS_REFCURSOR,
        p_options  OUT SYS_REFCURSOR
    ) IS
    BEGIN
        OPEN p_question FOR
            SELECT q.question_id, aq.attempt_question_id, aq.sequence_no,
                   a.target_question_count, qt.type_code, q.question_text,
                   q.difficulty_level, q.points, q.time_limit_seconds,
                   q.image_data, q.image_mime_type, q.image_file_name,
                   CAST(NULL AS VARCHAR2(100)) AS timer_text
              FROM qp_questions q
              JOIN qp_question_types qt ON qt.question_type_id = q.question_type_id
              JOIN qp_attempt_questions aq ON aq.question_id = q.question_id
              JOIN qp_attempts a ON a.attempt_id = aq.attempt_id
             WHERE 1 = 0;

        OPEN p_options FOR
            SELECT o.option_id, o.option_text, ao.shown_order,
                   o.image_data, o.image_mime_type, o.image_file_name
              FROM qp_answer_options o
              JOIN qp_attempt_options ao ON ao.option_id = o.option_id
             WHERE 1 = 0;
    END open_empty_question;

    PROCEDURE get_next_question(
        p_session_token  IN  VARCHAR2,
        p_attempt_id     IN  NUMBER,
        p_attempt_state  OUT VARCHAR2,
        p_seconds_left   OUT NUMBER,
        p_question       OUT SYS_REFCURSOR,
        p_options        OUT SYS_REFCURSOR
    ) IS
        v_user            t_user_rec;
        v_status          VARCHAR2(20);
        v_adaptive        CHAR(1);
        v_test_id         NUMBER;
        v_target          NUMBER;
        v_current_diff    NUMBER;
        v_attempt_deadline TIMESTAMP;
        v_completed       NUMBER;
        v_question_id     NUMBER;
        v_aq_id           NUMBER;
        v_sequence        NUMBER;
        v_q_seconds       NUMBER;
        v_q_deadline      TIMESTAMP;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        expire_due_state(p_attempt_id);

        SELECT a.attempt_status, t.adaptive_flag, a.test_id,
               a.target_question_count, a.current_difficulty, a.deadline_at
          INTO v_status, v_adaptive, v_test_id,
               v_target, v_current_diff, v_attempt_deadline
          FROM qp_attempts a
          JOIN qp_tests t ON t.test_id = a.test_id
         WHERE a.attempt_id = p_attempt_id;

        IF v_status <> 'IN_PROGRESS' THEN
            p_attempt_state := v_status;
            p_seconds_left := 0;
            open_empty_question(p_question, p_options);
            RETURN;
        END IF;

        BEGIN
            SELECT aq.attempt_question_id, aq.question_id, aq.sequence_no,
                   q.time_limit_seconds, aq.deadline_at
              INTO v_aq_id, v_question_id, v_sequence,
                   v_q_seconds, v_q_deadline
              FROM qp_attempt_questions aq
              JOIN qp_questions q ON q.question_id = aq.question_id
             WHERE aq.attempt_id = p_attempt_id
               AND aq.question_status = 'ACTIVE';
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                SELECT COUNT(*) INTO v_completed
                  FROM qp_attempt_questions
                 WHERE attempt_id = p_attempt_id
                   AND question_status IN ('ANSWERED', 'TIMED_OUT');

                IF v_completed >= v_target THEN
                    finalize_attempt_internal(p_attempt_id, 'COMPLETED', 'ALL_QUESTIONS_ANSWERED');
                    p_attempt_state := 'COMPLETED';
                    p_seconds_left := 0;
                    open_empty_question(p_question, p_options);
                    RETURN;
                END IF;

                IF v_adaptive = 'Y' THEN
                    BEGIN
                        SELECT question_id
                          INTO v_question_id
                          FROM (
                              SELECT q.question_id
                                FROM qp_questions q
                               WHERE q.test_id = v_test_id
                                 AND q.active_flag = 'Y'
                                 AND q.adaptive_flag = 'Y'
                                 AND NOT EXISTS (
                                     SELECT 1
                                       FROM qp_attempt_questions aq
                                      WHERE aq.attempt_id = p_attempt_id
                                        AND aq.question_id = q.question_id
                                 )
                                 AND (
                                     NOT EXISTS (
                                         SELECT 1 FROM qp_test_rules r0
                                          WHERE r0.test_id = v_test_id
                                     )
                                     OR EXISTS (
                                         SELECT 1
                                           FROM qp_test_rules r
                                          WHERE r.test_id = v_test_id
                                            AND (r.category_id IS NULL OR r.category_id = q.category_id)
                                            AND (r.difficulty_level IS NULL OR r.difficulty_level = q.difficulty_level)
                                     )
                                 )
                               ORDER BY ABS(q.difficulty_level - v_current_diff),
                                        DBMS_RANDOM.VALUE
                          )
                         WHERE ROWNUM = 1;
                    EXCEPTION
                        WHEN NO_DATA_FOUND THEN
                            finalize_attempt_internal(p_attempt_id, 'COMPLETED', 'QUESTION_BANK_EXHAUSTED');
                            p_attempt_state := 'COMPLETED';
                            p_seconds_left := 0;
                            open_empty_question(p_question, p_options);
                            RETURN;
                    END;

                    v_sequence := v_completed + 1;
                    INSERT INTO qp_attempt_questions (
                        attempt_id, question_id, sequence_no, question_status
                    ) VALUES (
                        p_attempt_id, v_question_id, v_sequence, 'PENDING'
                    ) RETURNING attempt_question_id INTO v_aq_id;
                ELSE
                    SELECT attempt_question_id, question_id, sequence_no
                      INTO v_aq_id, v_question_id, v_sequence
                      FROM (
                          SELECT attempt_question_id, question_id, sequence_no
                            FROM qp_attempt_questions
                           WHERE attempt_id = p_attempt_id
                             AND question_status = 'PENDING'
                           ORDER BY sequence_no
                      )
                     WHERE ROWNUM = 1;
                END IF;

                SELECT time_limit_seconds INTO v_q_seconds
                  FROM qp_questions
                 WHERE question_id = v_question_id;

                v_q_deadline := CASE
                    WHEN v_q_seconds IS NULL THEN v_attempt_deadline
                    WHEN v_attempt_deadline IS NULL THEN
                        SYS_EXTRACT_UTC(SYSTIMESTAMP) + NUMTODSINTERVAL(v_q_seconds, 'SECOND')
                    ELSE LEAST(
                        v_attempt_deadline,
                        SYS_EXTRACT_UTC(SYSTIMESTAMP) + NUMTODSINTERVAL(v_q_seconds, 'SECOND')
                    )
                END;

                UPDATE qp_attempt_questions
                   SET question_status = 'ACTIVE',
                       assigned_at = SYS_EXTRACT_UTC(SYSTIMESTAMP),
                       deadline_at = v_q_deadline
                 WHERE attempt_question_id = v_aq_id;

                INSERT INTO qp_attempt_options (
                    attempt_question_id, option_id, shown_order
                )
                SELECT v_aq_id, option_id,
                       ROW_NUMBER() OVER (ORDER BY DBMS_RANDOM.VALUE)
                  FROM qp_answer_options
                 WHERE question_id = v_question_id;
        END;

        p_attempt_state := 'QUESTION';
        IF v_q_deadline IS NULL THEN
            p_seconds_left := NULL;
        ELSE
            p_seconds_left := GREATEST(
                0,
                FLOOR((CAST(v_q_deadline AS DATE) - CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE)) * 86400)
            );
        END IF;

        OPEN p_question FOR
            SELECT q.question_id, aq.attempt_question_id, aq.sequence_no,
                   a.target_question_count, qt.type_code, q.question_text,
                   q.difficulty_level, q.points, q.time_limit_seconds,
                   q.image_data, q.image_mime_type, q.image_file_name,
                   CASE
                       WHEN v_q_deadline IS NULL THEN 'Без отдельного таймера'
                       ELSE 'Осталось по данным Oracle: ' ||
                            TO_CHAR(p_seconds_left) || ' сек.'
                   END AS timer_text
              FROM qp_attempt_questions aq
              JOIN qp_attempts a ON a.attempt_id = aq.attempt_id
              JOIN qp_questions q ON q.question_id = aq.question_id
              JOIN qp_question_types qt ON qt.question_type_id = q.question_type_id
             WHERE aq.attempt_question_id = v_aq_id;

        OPEN p_options FOR
            SELECT o.option_id, o.option_text, ao.shown_order,
                   o.image_data, o.image_mime_type, o.image_file_name
              FROM qp_attempt_options ao
              JOIN qp_answer_options o ON o.option_id = ao.option_id
             WHERE ao.attempt_question_id = v_aq_id
             ORDER BY ao.shown_order;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20057, 'Не найден следующий вопрос; проверьте структуру теста.');
    END get_next_question;

    PROCEDURE submit_answer(
        p_session_token       IN  VARCHAR2,
        p_attempt_id          IN  NUMBER,
        p_question_id         IN  NUMBER,
        p_response_json       IN  CLOB,
        p_visible_is_correct  OUT CHAR,
        p_visible_points      OUT NUMBER,
        p_feedback_text       OUT CLOB,
        p_correct_answer      OUT CLOB,
        p_result_message      OUT CLOB,
        p_attempt_state       OUT VARCHAR2
    ) IS
        v_user          t_user_rec;
        v_aq_id         NUMBER;
        v_points        NUMBER;
        v_correct       CHAR(1);
        v_feedback_mode VARCHAR2(20);
        v_show_correct  CHAR(1);
        v_adaptive      CHAR(1);
        v_explanation   CLOB;
        v_target        NUMBER;
        v_completed     NUMBER;
        v_status        VARCHAR2(20);
    BEGIN
        p_visible_is_correct := NULL;
        p_visible_points := NULL;
        p_feedback_text := NULL;
        p_correct_answer := NULL;
        p_result_message := NULL;

        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        expire_due_state(p_attempt_id);

        SELECT aq.attempt_question_id, q.points, t.feedback_mode,
               t.show_correct_answers, t.adaptive_flag, q.explanation,
               a.target_question_count, a.attempt_status
          INTO v_aq_id, v_points, v_feedback_mode,
               v_show_correct, v_adaptive, v_explanation,
               v_target, v_status
          FROM qp_attempt_questions aq
          JOIN qp_attempts a ON a.attempt_id = aq.attempt_id
          JOIN qp_tests t ON t.test_id = a.test_id
          JOIN qp_questions q ON q.question_id = aq.question_id
         WHERE aq.attempt_id = p_attempt_id
           AND aq.question_id = p_question_id
           AND aq.question_status = 'ACTIVE';

        IF v_status <> 'IN_PROGRESS' THEN
            fail(-20058, 'Попытка уже завершена.');
        END IF;

        v_correct := score_response(p_question_id, p_response_json);
        v_points := CASE WHEN v_correct = 'Y' THEN v_points ELSE 0 END;

        BEGIN
            INSERT INTO qp_responses (attempt_question_id, response_json)
            VALUES (v_aq_id, p_response_json);
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                fail(-20060, 'Ответ на этот вопрос уже сохранен.');
        END;

        UPDATE qp_attempt_questions
           SET question_status = 'ANSWERED',
               answered_at = SYS_EXTRACT_UTC(SYSTIMESTAMP),
               is_correct = v_correct,
               points_awarded = v_points
         WHERE attempt_question_id = v_aq_id;

        IF v_adaptive = 'Y' THEN
            UPDATE qp_attempts
               SET current_difficulty = CASE
                   WHEN v_correct = 'Y' THEN LEAST(5, current_difficulty + 1)
                   ELSE GREATEST(1, current_difficulty - 1)
               END
             WHERE attempt_id = p_attempt_id;
        END IF;

        SELECT COUNT(*) INTO v_completed
          FROM qp_attempt_questions
         WHERE attempt_id = p_attempt_id
           AND question_status IN ('ANSWERED', 'TIMED_OUT');

        IF v_completed >= v_target THEN
            finalize_attempt_internal(p_attempt_id, 'COMPLETED', 'ALL_QUESTIONS_ANSWERED');
            p_attempt_state := 'COMPLETED';
        ELSE
            p_attempt_state := 'IN_PROGRESS';
        END IF;

        IF v_feedback_mode = 'IMMEDIATE'
           OR (v_feedback_mode = 'AFTER_TEST' AND p_attempt_state = 'COMPLETED') THEN
            p_visible_is_correct := v_correct;
            p_visible_points := v_points;
            p_feedback_text := v_explanation;
            IF v_show_correct = 'Y' THEN
                p_correct_answer := correct_answer_text(p_question_id);
            END IF;

            p_result_message := CASE v_correct
                WHEN 'Y' THEN TO_CLOB(
                    'Ответ верный. Баллы: ' ||
                    TO_CHAR(v_points, 'FM999999990D99', 'NLS_NUMERIC_CHARACTERS=''.,''')
                )
                ELSE TO_CLOB('Ответ неверный.')
            END;
            IF p_feedback_text IS NOT NULL THEN
                p_result_message := p_result_message || CHR(10) || CHR(10) ||
                                    p_feedback_text;
            END IF;
            IF p_correct_answer IS NOT NULL THEN
                p_result_message := p_result_message || CHR(10) || CHR(10) ||
                                    'Правильный ответ: ' || p_correct_answer;
            END IF;
        END IF;

        audit_event(v_user.user_id, 'ANSWER_SUBMITTED', 'QUESTION', p_question_id,
                    'attempt_id=' || p_attempt_id);
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20059, 'Вопрос не активен: он уже отвечен либо истек таймер.');
    END submit_answer;

    PROCEDURE finish_attempt(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    ) IS
        v_user      t_user_rec;
        v_status    VARCHAR2(20);
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        expire_due_state(p_attempt_id);

        SELECT attempt_status
          INTO v_status
          FROM qp_attempts
         WHERE attempt_id = p_attempt_id;
        IF v_status <> 'IN_PROGRESS' THEN
            RETURN;
        END IF;

        finalize_attempt_internal(p_attempt_id, 'COMPLETED', 'USER_FINISH');
    END finish_attempt;

    PROCEDURE calculate_result(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        recalculate_result_internal(p_attempt_id);
    END calculate_result;

    PROCEDURE assign_badges(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        assign_badges_internal(p_attempt_id);
    END assign_badges;

    PROCEDURE update_rating(
        p_session_token IN VARCHAR2,
        p_period_code   IN VARCHAR2 DEFAULT 'ALL'
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, 'ADMIN', v_user);
        rebuild_ratings_internal(UPPER(TRIM(p_period_code)));
        audit_event(v_user.user_id, 'RATINGS_REBUILT', 'RATING', NULL, p_period_code);
    END update_rating;

    PROCEDURE generate_certificate(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        generate_certificate_internal(p_attempt_id);
    END generate_certificate;

    PROCEDURE list_tests(
        p_session_token IN  VARCHAR2,
        p_tests         OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        OPEN p_tests FOR
            SELECT c.test_id, c.test_title, c.description, c.author_name,
                   c.category_name, c.topics, c.time_limit_minutes,
                   c.question_count, c.bank_question_count, c.pass_percent,
                   c.feedback_mode, c.adaptive_flag, c.team_mode_flag,
                   c.access_mode, c.completed_attempts, c.average_percent,
                   (SELECT COUNT(*)
                      FROM qp_attempts a
                     WHERE a.test_id = c.test_id
                       AND a.user_id = v_user.user_id
                       AND a.attempt_status IN ('COMPLETED', 'TIMED_OUT')) AS my_attempts,
                   (SELECT MAX(a.attempt_id)
                      FROM qp_attempts a
                     WHERE a.test_id = c.test_id
                       AND a.user_id = v_user.user_id
                       AND a.attempt_status = 'IN_PROGRESS') AS active_attempt_id,
                   CASE WHEN EXISTS (
                       SELECT 1
                         FROM qp_attempts a
                        WHERE a.test_id = c.test_id
                          AND a.user_id = v_user.user_id
                          AND a.attempt_status = 'IN_PROGRESS'
                   ) THEN 'Продолжить' ELSE 'Начать' END AS action_text
              FROM (
                  SELECT
                      t.test_id,
                      t.author_user_id,
                      u.display_name AS author_name,
                      t.primary_category_id,
                      c.category_name,
                      t.test_title,
                      t.description,
                      t.test_status,
                      t.access_mode,
                      t.time_limit_minutes,
                      t.question_count,
                      t.pass_percent,
                      t.feedback_mode,
                      t.show_correct_answers,
                      t.adaptive_flag,
                      t.team_mode_flag,
                      t.max_attempts,
                      t.created_at,
                      t.published_at,
                      COUNT(DISTINCT q.question_id) AS bank_question_count,
                      COUNT(DISTINCT CASE WHEN a.attempt_status IN ('COMPLETED', 'TIMED_OUT')
                                          THEN a.attempt_id END) AS completed_attempts,
                      ROUND(AVG(CASE WHEN a.attempt_status IN ('COMPLETED', 'TIMED_OUT')
                                     THEN a.percent_score END), 2) AS average_percent,
                      (
                          SELECT LISTAGG(tp.topic_name, ', ') WITHIN GROUP (ORDER BY tp.topic_name)
                            FROM qp_test_topics tt
                            JOIN qp_topics tp ON tp.topic_id = tt.topic_id
                           WHERE tt.test_id = t.test_id
                      ) AS topics
                  FROM qp_tests t
                  JOIN qp_users u ON u.user_id = t.author_user_id
                  JOIN qp_categories c ON c.category_id = t.primary_category_id
                  LEFT JOIN qp_questions q
                         ON q.test_id = t.test_id
                        AND q.active_flag = 'Y'
                  LEFT JOIN qp_attempts a ON a.test_id = t.test_id
                  GROUP BY
                      t.test_id, t.author_user_id, u.display_name, t.primary_category_id,
                      c.category_name, t.test_title, t.description, t.test_status,
                      t.access_mode, t.time_limit_minutes, t.question_count,
                      t.pass_percent, t.feedback_mode, t.show_correct_answers,
                      t.adaptive_flag, t.team_mode_flag, t.max_attempts,
                      t.created_at, t.published_at
              ) c
              JOIN qp_tests t ON t.test_id = c.test_id
              JOIN qp_users u ON u.user_id = v_user.user_id
             WHERE c.test_status = 'PUBLISHED'
               AND (
                   t.access_mode = 'PUBLIC'
                   OR t.author_user_id = v_user.user_id
                   OR u.user_role = 'ADMIN'
                   OR EXISTS (
                       SELECT 1
                         FROM qp_test_access a
                        WHERE a.test_id = t.test_id
                          AND UPPER(a.oracle_username) = UPPER(u.oracle_username)
                   )
               )
             ORDER BY c.test_title;
    END list_tests;

    PROCEDURE list_categories(p_categories OUT SYS_REFCURSOR) IS
    BEGIN
        OPEN p_categories FOR
            SELECT category_id, category_name, description
              FROM qp_categories
             ORDER BY category_name;
    END list_categories;

    PROCEDURE list_question_types(p_types OUT SYS_REFCURSOR) IS
    BEGIN
        OPEN p_types FOR
            SELECT question_type_id, type_code, type_name, description
              FROM qp_question_types
             ORDER BY question_type_id;
    END list_question_types;

    PROCEDURE list_topics(
        p_session_token IN  VARCHAR2,
        p_topics        OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        OPEN p_topics FOR
            SELECT t.topic_id, t.topic_name, t.description,
                   u.display_name AS owner_name,
                   COUNT(tt.test_id) AS test_count
              FROM qp_topics t
              JOIN qp_users u ON u.user_id = t.owner_user_id
              LEFT JOIN qp_test_topics tt ON tt.topic_id = t.topic_id
             WHERE t.owner_user_id = v_user.user_id
                OR v_user.user_role = 'ADMIN'
             GROUP BY t.topic_id, t.topic_name, t.description, u.display_name
             ORDER BY t.topic_name;
    END list_topics;

    PROCEDURE list_author_tests(
        p_session_token IN  VARCHAR2,
        p_tests         OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        OPEN p_tests FOR
            SELECT c.test_id, c.test_title, c.description, c.test_status,
                   c.category_name, c.topics, c.access_mode,
                   c.time_limit_minutes, c.question_count,
                   c.pass_percent, c.feedback_mode,
                   c.show_correct_answers, c.adaptive_flag,
                   c.team_mode_flag, c.max_attempts,
                   c.bank_question_count, c.completed_attempts,
                   c.average_percent, c.created_at, c.published_at
              FROM (
                  SELECT
                      t.test_id,
                      t.author_user_id,
                      u.display_name AS author_name,
                      t.primary_category_id,
                      c.category_name,
                      t.test_title,
                      t.description,
                      t.test_status,
                      t.access_mode,
                      t.time_limit_minutes,
                      t.question_count,
                      t.pass_percent,
                      t.feedback_mode,
                      t.show_correct_answers,
                      t.adaptive_flag,
                      t.team_mode_flag,
                      t.max_attempts,
                      t.created_at,
                      t.published_at,
                      COUNT(DISTINCT q.question_id) AS bank_question_count,
                      COUNT(DISTINCT CASE WHEN a.attempt_status IN ('COMPLETED', 'TIMED_OUT')
                                          THEN a.attempt_id END) AS completed_attempts,
                      ROUND(AVG(CASE WHEN a.attempt_status IN ('COMPLETED', 'TIMED_OUT')
                                     THEN a.percent_score END), 2) AS average_percent,
                      (
                          SELECT LISTAGG(tp.topic_name, ', ') WITHIN GROUP (ORDER BY tp.topic_name)
                            FROM qp_test_topics tt
                            JOIN qp_topics tp ON tp.topic_id = tt.topic_id
                           WHERE tt.test_id = t.test_id
                      ) AS topics
                  FROM qp_tests t
                  JOIN qp_users u ON u.user_id = t.author_user_id
                  JOIN qp_categories c ON c.category_id = t.primary_category_id
                  LEFT JOIN qp_questions q
                         ON q.test_id = t.test_id
                        AND q.active_flag = 'Y'
                  LEFT JOIN qp_attempts a ON a.test_id = t.test_id
                  GROUP BY
                      t.test_id, t.author_user_id, u.display_name, t.primary_category_id,
                      c.category_name, t.test_title, t.description, t.test_status,
                      t.access_mode, t.time_limit_minutes, t.question_count,
                      t.pass_percent, t.feedback_mode, t.show_correct_answers,
                      t.adaptive_flag, t.team_mode_flag, t.max_attempts,
                      t.created_at, t.published_at
              ) c
             WHERE c.author_user_id = v_user.user_id
                OR v_user.user_role = 'ADMIN'
             ORDER BY c.created_at DESC;
    END list_author_tests;

    PROCEDURE list_test_questions(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_questions     OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'N');
        OPEN p_questions FOR
            SELECT q.question_id, q.display_order, qt.type_code,
                   DBMS_LOB.SUBSTR(q.question_text, 1000, 1) AS question_text,
                   c.category_name, q.difficulty_level, q.points,
                   q.time_limit_seconds, q.adaptive_flag, q.active_flag,
                   CASE WHEN q.image_data IS NULL THEN 'N' ELSE 'Y' END AS has_image,
                   (SELECT COUNT(*) FROM qp_answer_options o
                     WHERE o.question_id = q.question_id) AS option_count,
                   (SELECT COUNT(*) FROM qp_question_keys k
                     WHERE k.question_id = q.question_id) AS key_count
              FROM qp_questions q
              JOIN qp_question_types qt ON qt.question_type_id = q.question_type_id
              JOIN qp_categories c ON c.category_id = q.category_id
             WHERE q.test_id = p_test_id
             ORDER BY q.display_order;
    END list_test_questions;

    PROCEDURE list_test_access(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_access        OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'N');
        OPEN p_access FOR
            SELECT a.oracle_username, u.display_name AS granted_by,
                   a.granted_at
              FROM qp_test_access a
              JOIN qp_users u ON u.user_id = a.granted_by_user_id
             WHERE a.test_id = p_test_id
             ORDER BY a.oracle_username;
    END list_test_access;

    PROCEDURE get_my_attempts(
        p_session_token IN  VARCHAR2,
        p_attempts      OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        OPEN p_attempts FOR
            SELECT attempt_id, test_id, test_title, team_name,
                   attempt_status, started_at, finished_at,
                   score, max_score, percent_score, correct_count,
                   target_question_count, passed_flag, finish_reason,
                   certificate_no
              FROM (
                  SELECT
                      a.attempt_id,
                      a.user_id,
                      u.display_name,
                      a.test_id,
                      t.test_title,
                      a.team_id,
                      tm.team_name,
                      a.attempt_status,
                      a.started_at,
                      a.finished_at,
                      a.score,
                      a.max_score,
                      a.percent_score,
                      a.correct_count,
                      a.target_question_count,
                      CASE WHEN a.percent_score >= t.pass_percent THEN 'Y' ELSE 'N' END AS passed_flag,
                      a.finish_reason,
                      c.certificate_no,
                      c.issued_at AS certificate_issued_at
                  FROM qp_attempts a
                  JOIN qp_users u ON u.user_id = a.user_id
                  JOIN qp_tests t ON t.test_id = a.test_id
                  LEFT JOIN qp_teams tm ON tm.team_id = a.team_id
                  LEFT JOIN qp_certificates c ON c.attempt_id = a.attempt_id
              )
             WHERE user_id = v_user.user_id
                OR v_user.user_role = 'ADMIN'
             ORDER BY started_at DESC;
    END get_my_attempts;

    PROCEDURE get_attempt_result(
        p_session_token IN  VARCHAR2,
        p_attempt_id    IN  NUMBER,
        p_result        OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        expire_due_state(p_attempt_id);
        BEGIN
            generate_certificate_internal(p_attempt_id);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN NULL;
        END;
        OPEN p_result FOR
            SELECT attempt_id, test_id, test_title, display_name,
                   team_name, attempt_status, started_at, finished_at,
                   score, max_score, percent_score, correct_count,
                   target_question_count, passed_flag, finish_reason,
                   certificate_no, certificate_issued_at,
                   CASE passed_flag
                       WHEN 'Y' THEN 'Тест пройден'
                       ELSE 'Проходной порог не достигнут'
                   END AS outcome_text,
                   CASE passed_flag
                       WHEN 'Y' THEN 'SUCCESS'
                       ELSE 'WARNING'
                   END AS outcome_style
              FROM (
                  SELECT
                      a.attempt_id,
                      a.user_id,
                      u.display_name,
                      a.test_id,
                      t.test_title,
                      a.team_id,
                      tm.team_name,
                      a.attempt_status,
                      a.started_at,
                      a.finished_at,
                      a.score,
                      a.max_score,
                      a.percent_score,
                      a.correct_count,
                      a.target_question_count,
                      CASE WHEN a.percent_score >= t.pass_percent THEN 'Y' ELSE 'N' END AS passed_flag,
                      a.finish_reason,
                      c.certificate_no,
                      c.issued_at AS certificate_issued_at
                  FROM qp_attempts a
                  JOIN qp_users u ON u.user_id = a.user_id
                  JOIN qp_tests t ON t.test_id = a.test_id
                  LEFT JOIN qp_teams tm ON tm.team_id = a.team_id
                  LEFT JOIN qp_certificates c ON c.attempt_id = a.attempt_id
              )
             WHERE attempt_id = p_attempt_id;
    END get_attempt_result;

    PROCEDURE get_attempt_feedback(
        p_session_token IN  VARCHAR2,
        p_attempt_id    IN  NUMBER,
        p_feedback      OUT SYS_REFCURSOR
    ) IS
        v_user          t_user_rec;
        v_status        VARCHAR2(20);
        v_feedback_mode VARCHAR2(20);
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        expire_due_state(p_attempt_id);

        SELECT a.attempt_status, t.feedback_mode
          INTO v_status, v_feedback_mode
          FROM qp_attempts a
          JOIN qp_tests t ON t.test_id = a.test_id
         WHERE a.attempt_id = p_attempt_id;

        IF v_status = 'IN_PROGRESS' OR v_feedback_mode = 'NEVER' THEN
            OPEN p_feedback FOR
                SELECT aq.sequence_no, q.question_id,
                       DBMS_LOB.SUBSTR(q.question_text, 1000, 1) AS question_text,
                       qt.type_code, aq.is_correct, aq.points_awarded,
                       q.points AS max_points, DBMS_LOB.SUBSTR(q.explanation, 2000, 1) AS explanation,
                       CAST(NULL AS VARCHAR2(4000)) AS correct_answer,
                       CAST(NULL AS VARCHAR2(20)) AS answer_result_text
                  FROM qp_attempt_questions aq
                  JOIN qp_questions q ON q.question_id = aq.question_id
                  JOIN qp_question_types qt ON qt.question_type_id = q.question_type_id
                 WHERE 1 = 0;
            RETURN;
        END IF;

        OPEN p_feedback FOR
            SELECT aq.sequence_no, q.question_id,
                   DBMS_LOB.SUBSTR(q.question_text, 1000, 1) AS question_text,
                   qt.type_code, aq.is_correct, aq.points_awarded,
                   q.points AS max_points,
                   DBMS_LOB.SUBSTR(q.explanation, 2000, 1) AS explanation,
                   CASE
                       WHEN t.show_correct_answers = 'N' THEN NULL
                       WHEN qt.type_code IN ('SINGLE', 'MULTIPLE', 'TRUE_FALSE') THEN
                           (SELECT LISTAGG(o.option_text, '; ')
                                      WITHIN GROUP (ORDER BY o.display_order)
                              FROM qp_answer_options o
                             WHERE o.question_id = q.question_id
                               AND o.is_correct = 'Y')
                       WHEN qt.type_code = 'ORDERING' THEN
                           (SELECT LISTAGG(o.option_text, ' -> ')
                                      WITHIN GROUP (ORDER BY o.correct_order)
                              FROM qp_answer_options o
                             WHERE o.question_id = q.question_id)
                       WHEN qt.type_code = 'MATCHING' THEN
                           (SELECT LISTAGG(o.option_text || ' = ' || o.match_key, '; ')
                                      WITHIN GROUP (ORDER BY o.display_order)
                              FROM qp_answer_options o
                             WHERE o.question_id = q.question_id)
                       WHEN qt.type_code = 'NUMBER' THEN
                           (SELECT LISTAGG(TO_CHAR(k.numeric_value), ' / ')
                                      WITHIN GROUP (ORDER BY k.key_id)
                              FROM qp_question_keys k
                             WHERE k.question_id = q.question_id
                               AND k.key_type = 'NUMBER')
                       ELSE
                           (SELECT LISTAGG(k.accepted_text, ' / ')
                                      WITHIN GROUP (ORDER BY k.key_id)
                              FROM qp_question_keys k
                             WHERE k.question_id = q.question_id
                               AND k.key_type IN ('TEXT', 'REGEX'))
                   END AS correct_answer,
                   CASE aq.is_correct
                       WHEN 'Y' THEN 'Верно'
                       WHEN 'N' THEN 'Неверно'
                       ELSE 'Нет ответа'
                   END AS answer_result_text
              FROM qp_attempt_questions aq
              JOIN qp_attempts a ON a.attempt_id = aq.attempt_id
              JOIN qp_tests t ON t.test_id = a.test_id
              JOIN qp_questions q ON q.question_id = aq.question_id
              JOIN qp_question_types qt ON qt.question_type_id = q.question_type_id
             WHERE aq.attempt_id = p_attempt_id
             ORDER BY aq.sequence_no;
    END get_attempt_feedback;

    PROCEDURE show_statistics(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_statistics    OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, 'AUTHOR,ADMIN', v_user);
        assert_test_owner(v_user, p_test_id, 'N');
        OPEN p_statistics FOR
            SELECT question_id, display_order, type_code, difficulty_level,
                   question_text, times_assigned, answered_count,
                   correct_count, correct_percent, average_answer_seconds
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
             WHERE test_id = p_test_id
             ORDER BY display_order;
    END show_statistics;

    PROCEDURE get_user_comparison(
        p_session_token IN  VARCHAR2,
        p_comparison    OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        OPEN p_comparison FOR
            SELECT attempt_id, test_id, test_title, user_percent,
                   test_average_percent, difference_from_average,
                   test_rank, participants_count, finished_at
              FROM (
                  SELECT
                      a.attempt_id,
                      a.user_id,
                      u.display_name,
                      a.test_id,
                      t.test_title,
                      a.percent_score AS user_percent,
                      ROUND(AVG(a.percent_score) OVER (PARTITION BY a.test_id), 2) AS test_average_percent,
                      ROUND(
                          a.percent_score - AVG(a.percent_score) OVER (PARTITION BY a.test_id),
                          2
                      ) AS difference_from_average,
                      DENSE_RANK() OVER (
                          PARTITION BY a.test_id
                          ORDER BY a.percent_score DESC, a.finished_at ASC
                      ) AS test_rank,
                      COUNT(*) OVER (PARTITION BY a.test_id) AS participants_count,
                      a.finished_at
                  FROM qp_attempts a
                  JOIN qp_users u ON u.user_id = a.user_id
                  JOIN qp_tests t ON t.test_id = a.test_id
                  WHERE a.attempt_status IN ('COMPLETED', 'TIMED_OUT')
              )
             WHERE user_id = v_user.user_id
             ORDER BY finished_at DESC;
    END get_user_comparison;

    PROCEDURE get_leaderboard(
        p_session_token IN  VARCHAR2,
        p_rating_type   IN  VARCHAR2 DEFAULT 'USER',
        p_period_code   IN  VARCHAR2 DEFAULT 'ALL',
        p_leaderboard   OUT SYS_REFCURSOR
    ) IS
        v_user   t_user_rec;
        v_type   VARCHAR2(10) := UPPER(TRIM(p_rating_type));
        v_period VARCHAR2(10) := UPPER(TRIM(p_period_code));
        v_count  NUMBER;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        IF v_type NOT IN ('USER', 'TEAM') THEN
            fail(-20062, 'Тип рейтинга: USER или TEAM.');
        END IF;
        IF v_period NOT IN ('WEEK', 'MONTH', 'ALL') THEN
            fail(-20014, 'Период рейтинга: WEEK, MONTH или ALL.');
        END IF;

        SELECT COUNT(*) INTO v_count
          FROM qp_rating_snapshots
         WHERE rating_type = v_type
           AND period_code = v_period;
        IF v_count = 0 THEN
            rebuild_ratings_internal(v_period);
        END IF;

        OPEN p_leaderboard FOR
            SELECT r.rank_no, r.rating_type, r.period_code,
                   CASE WHEN r.rating_type = 'USER' THEN u.display_name
                        ELSE t.team_name END AS subject_name,
                   r.total_score, r.completed_attempts, r.calculated_at,
                   CASE
                       WHEN r.user_id = v_user.user_id THEN 'Y'
                       WHEN r.team_id IN (
                           SELECT tm.team_id FROM qp_team_members tm
                            WHERE tm.user_id = v_user.user_id
                       ) THEN 'Y'
                       ELSE 'N'
                   END AS is_mine
              FROM qp_rating_snapshots r
              LEFT JOIN qp_users u ON u.user_id = r.user_id
              LEFT JOIN qp_teams t ON t.team_id = r.team_id
             WHERE r.rating_type = v_type
               AND r.period_code = v_period
             ORDER BY r.rank_no, subject_name;
    END get_leaderboard;

    PROCEDURE get_my_badges(
        p_session_token IN  VARCHAR2,
        p_badges        OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        OPEN p_badges FOR
            SELECT b.badge_code, b.badge_name, b.description,
                   ub.awarded_at, ub.attempt_id
              FROM qp_user_badges ub
              JOIN qp_badges b ON b.badge_id = ub.badge_id
             WHERE ub.user_id = v_user.user_id
             ORDER BY ub.awarded_at DESC;
    END get_my_badges;

    PROCEDURE list_teams(
        p_session_token IN  VARCHAR2,
        p_teams         OUT SYS_REFCURSOR
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        OPEN p_teams FOR
            SELECT t.team_id, t.team_name, t.join_code,
                   tm.member_role, t.created_at,
                   (SELECT COUNT(*) FROM qp_team_members x
                     WHERE x.team_id = t.team_id) AS member_count
              FROM qp_teams t
              JOIN qp_team_members tm
                ON tm.team_id = t.team_id
               AND tm.user_id = v_user.user_id
             WHERE t.active_flag = 'Y'
             ORDER BY t.team_name;
    END list_teams;

    PROCEDURE get_certificate(
        p_session_token IN  VARCHAR2,
        p_attempt_id    IN  NUMBER,
        p_file_name     OUT VARCHAR2,
        p_mime_type     OUT VARCHAR2,
        p_pdf_data      OUT BLOB
    ) IS
        v_user t_user_rec;
    BEGIN
        require_session(p_session_token, NULL, v_user);
        assert_attempt_owner(v_user, p_attempt_id);
        SELECT file_name, mime_type, pdf_data
          INTO p_file_name, p_mime_type, p_pdf_data
          FROM qp_certificates
         WHERE attempt_id = p_attempt_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            fail(-20063, 'Сертификат для этой попытки не сформирован.');
    END get_certificate;

END quiz_platform;
/

SHOW ERRORS PACKAGE BODY quiz_platform
