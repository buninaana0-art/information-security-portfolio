

DECLARE
    v_user_id NUMBER;
    v_token VARCHAR2(64);
    v_login VARCHAR2(64);
    v_password VARCHAR2(64);
    v_attempt NUMBER;
    v_question NUMBER;
    v_count NUMBER;
    v_step NUMBER;
    v_state VARCHAR2(20);
    v_seconds NUMBER;
    v_questions SYS_REFCURSOR;
    v_options SYS_REFCURSOR;
    v_ok CHAR(1);
    v_points NUMBER;
    v_feedback CLOB;
    v_correct CLOB;
    v_message CLOB;
    v_response VARCHAR2(4000);

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

    PROCEDURE next_question IS
    BEGIN
        quiz_platform.get_next_question(
            v_token, v_attempt, v_state, v_seconds, v_questions, v_options
        );
        CLOSE v_questions;
        CLOSE v_options;
        IF v_state = 'QUESTION' THEN
            SELECT question_id INTO v_question FROM qp_attempt_questions
             WHERE attempt_id = v_attempt AND question_status = 'ACTIVE';
        END IF;
    END;
BEGIN
    
    LOCK TABLE qp_users IN SHARE ROW EXCLUSIVE MODE NOWAIT;
    FOR player IN 1 .. 2 LOOP
        v_login := CASE player WHEN 1 THEN 'DEMO_ALICE' ELSE 'DEMO_BOB' END;
        v_password := CASE player WHEN 1 THEN 'DemoAlice123!' ELSE 'DemoBob123!' END;
        BEGIN
            SELECT user_id INTO v_user_id FROM qp_users WHERE oracle_username = v_login;
        EXCEPTION WHEN NO_DATA_FOUND THEN
            quiz_platform.register_user(
                CASE player WHEN 1 THEN 'Алиса — демо' ELSE 'Борис — демо' END,
                LOWER(v_login) || '@quiz.local', v_password, v_password,
                v_login, 'PARTICIPANT', v_user_id
            );
        END;

        SELECT COUNT(DISTINCT a.attempt_id) INTO v_count
          FROM qp_attempts a JOIN qp_audit_log l ON l.entity_id = a.attempt_id
         WHERE a.user_id = v_user_id AND l.event_code = 'DEMO_HISTORY_V1';
        IF v_count >= 12 THEN
            CONTINUE;
        END IF;

        MERGE INTO qp_test_access a
        USING (SELECT 2 test_id, v_login username FROM dual) x
        ON (a.test_id = x.test_id AND a.oracle_username = x.username)
        WHEN NOT MATCHED THEN INSERT (test_id, oracle_username, granted_by_user_id)
            VALUES (x.test_id, x.username, 2);
        MERGE INTO qp_team_members m
        USING (SELECT 1 team_id, v_user_id user_id FROM dual) x
        ON (m.team_id = x.team_id AND m.user_id = x.user_id)
        WHEN NOT MATCHED THEN INSERT (team_id, user_id, member_role)
            VALUES (x.team_id, x.user_id, 'MEMBER');

        v_token := RAWTOHEX(SYS_GUID()) || RAWTOHEX(SYS_GUID());
        INSERT INTO qp_sessions (session_token, user_id, expires_at, client_label)
        VALUES (v_token, v_user_id,
            SYS_EXTRACT_UTC(SYSTIMESTAMP) + INTERVAL '1' HOUR, 'DEMO_HISTORY_V1');

        FOR test_no IN 1 .. 3 LOOP
            FOR outcome IN 1 .. 4 LOOP
                SELECT COUNT(*) INTO v_count FROM qp_audit_log l
                JOIN qp_attempts a ON a.attempt_id = l.entity_id
                 WHERE l.event_code = 'DEMO_HISTORY_V1'
                   AND a.user_id = v_user_id AND a.test_id = test_no
                   AND l.details = 'OUTCOME_' || TO_CHAR(outcome);
                IF v_count = 0 THEN
                    quiz_platform.start_attempt(
                        v_token, test_no, CASE WHEN test_no = 3 THEN 1 END, v_attempt
                    );
                    v_step := 0;
                    LOOP
                        next_question;
                        EXIT WHEN v_state <> 'QUESTION';
                        v_step := v_step + 1;
                        v_response := CASE
                            WHEN outcome = 2 AND MOD(v_step, 2) = 0 THEN '{}'
                            ELSE correct_json(v_question) END;
                        quiz_platform.submit_answer(
                            v_token, v_attempt, v_question, TO_CLOB(v_response),
                            v_ok, v_points, v_feedback, v_correct, v_message, v_state
                        );
                        IF outcome = 3 THEN
                            quiz_platform.finish_attempt(v_token, v_attempt);
                            EXIT;
                        ELSIF outcome = 4 THEN
                            
                            UPDATE qp_attempts SET deadline_at =
                                SYS_EXTRACT_UTC(SYSTIMESTAMP) - INTERVAL '1' SECOND
                             WHERE attempt_id = v_attempt;
                            next_question;
                            EXIT;
                        END IF;
                        EXIT WHEN v_state <> 'IN_PROGRESS';
                    END LOOP;
                    INSERT INTO qp_audit_log (
                        user_id, event_code, entity_type, entity_id, details, oracle_session_user
                    ) VALUES (
                        v_user_id, 'DEMO_HISTORY_V1', 'ATTEMPT', v_attempt,
                        'OUTCOME_' || TO_CHAR(outcome), SYS_CONTEXT('USERENV', 'SESSION_USER')
                    );
                END IF;
            END LOOP;
        END LOOP;
        quiz_platform.logout(v_token);
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('PASS: demonstration history installed (12 games per demo player).');
END;
/
COMMIT;
