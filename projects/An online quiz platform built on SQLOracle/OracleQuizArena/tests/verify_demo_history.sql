SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK
DECLARE
    v_count NUMBER;
    v_players NUMBER := 0;
BEGIN
    FOR u IN (SELECT user_id FROM qp_users
               WHERE oracle_username IN ('DEMO_ALICE', 'DEMO_BOB')) LOOP
        v_players := v_players + 1;
        SELECT COUNT(*) INTO v_count FROM qp_attempts a
         WHERE a.user_id = u.user_id AND a.attempt_status IN ('COMPLETED', 'TIMED_OUT')
           AND EXISTS (SELECT 1 FROM qp_audit_log l WHERE l.entity_id = a.attempt_id
                        AND l.event_code = 'DEMO_HISTORY_V1');
        IF v_count <> 12 THEN
            RAISE_APPLICATION_ERROR(-20892, 'Expected 12 saved demo games per player');
        END IF;
        SELECT COUNT(DISTINCT a.test_id) INTO v_count FROM qp_attempts a
         WHERE a.user_id = u.user_id AND a.test_id IN (1, 2, 3);
        IF v_count <> 3 THEN
            RAISE_APPLICATION_ERROR(-20893, 'Demo history must cover all three game modes');
        END IF;
        SELECT COUNT(DISTINCT q.question_type_id) INTO v_count
          FROM qp_attempts a JOIN qp_attempt_questions aq ON aq.attempt_id = a.attempt_id
          JOIN qp_questions q ON q.question_id = aq.question_id
          JOIN qp_responses r ON r.attempt_question_id = aq.attempt_question_id
         WHERE a.user_id = u.user_id;
        IF v_count <> 7 THEN
            RAISE_APPLICATION_ERROR(-20894, 'Demo history must contain responses to all 7 types');
        END IF;
        SELECT COUNT(*) INTO v_count FROM qp_attempts a
         JOIN qp_certificates c ON c.attempt_id = a.attempt_id
         WHERE a.user_id = u.user_id
           AND DBMS_LOB.GETLENGTH(c.pdf_data) > 0
           AND EXISTS (SELECT 1 FROM qp_audit_log l WHERE l.entity_id = a.attempt_id
                        AND l.event_code = 'DEMO_HISTORY_V1');
        IF v_count <> 12 THEN
            RAISE_APPLICATION_ERROR(-20895, 'Each saved demo game must have a PDF certificate');
        END IF;
    END LOOP;
    IF v_players <> 2 THEN
        RAISE_APPLICATION_ERROR(-20896, 'Both demo players must exist');
    END IF;
    DBMS_OUTPUT.PUT_LINE('PASS: two demo players, 24 games, 3 modes, 7 types and 24 PDFs.');
END;
/
