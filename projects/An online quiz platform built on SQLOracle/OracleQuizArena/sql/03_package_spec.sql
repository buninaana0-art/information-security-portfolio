CREATE OR REPLACE PACKAGE quiz_platform AS

    PROCEDURE info;

    PROCEDURE register_user(
        p_display_name     IN  VARCHAR2,
        p_email            IN  VARCHAR2,
        p_password         IN  VARCHAR2,
        p_password_repeat  IN  VARCHAR2,
        p_game_username    IN  VARCHAR2,
        p_user_role        IN  VARCHAR2,
        p_user_id          OUT NUMBER
    );

    PROCEDURE login(
        p_login            IN  VARCHAR2,
        p_password         IN  VARCHAR2,
        p_client_label     IN  VARCHAR2 DEFAULT NULL,
        p_session_token    OUT VARCHAR2,
        p_user_id          OUT NUMBER,
        p_display_name     OUT VARCHAR2,
        p_user_role        OUT VARCHAR2
    );

    PROCEDURE login_oracle(
        p_client_label     IN  VARCHAR2 DEFAULT NULL,
        p_session_token    OUT VARCHAR2,
        p_user_id          OUT NUMBER,
        p_display_name     OUT VARCHAR2,
        p_user_role        OUT VARCHAR2
    );

    PROCEDURE logout(p_session_token IN VARCHAR2);

    PROCEDURE create_category(
        p_session_token    IN  VARCHAR2,
        p_category_name    IN  VARCHAR2,
        p_description      IN  VARCHAR2 DEFAULT NULL,
        p_category_id      OUT NUMBER
    );

    PROCEDURE create_topic(
        p_session_token    IN  VARCHAR2,
        p_topic_name       IN  VARCHAR2,
        p_description      IN  VARCHAR2 DEFAULT NULL,
        p_topic_id         OUT NUMBER
    );

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
    );

    PROCEDURE add_test_topic(
        p_session_token    IN VARCHAR2,
        p_test_id          IN NUMBER,
        p_topic_id         IN NUMBER
    );

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
    );

    PROCEDURE add_answer_option(
        p_session_token     IN  VARCHAR2,
        p_question_id       IN  NUMBER,
        p_option_text       IN  VARCHAR2,
        p_is_correct        IN  CHAR DEFAULT 'N',
        p_display_order     IN  NUMBER,
        p_correct_order     IN  NUMBER DEFAULT NULL,
        p_match_key         IN  VARCHAR2 DEFAULT NULL,
        p_option_id         OUT NUMBER
    );

    PROCEDURE add_question_key(
        p_session_token       IN  VARCHAR2,
        p_question_id         IN  NUMBER,
        p_key_type            IN  VARCHAR2,
        p_accepted_text       IN  VARCHAR2 DEFAULT NULL,
        p_numeric_value       IN  NUMBER DEFAULT NULL,
        p_numeric_tolerance   IN  NUMBER DEFAULT 0,
        p_case_sensitive_flag IN  CHAR DEFAULT 'N',
        p_key_id              OUT NUMBER
    );

    PROCEDURE add_generation_rule(
        p_session_token    IN  VARCHAR2,
        p_test_id          IN  NUMBER,
        p_category_id      IN  NUMBER DEFAULT NULL,
        p_difficulty_level IN  NUMBER DEFAULT NULL,
        p_question_count   IN  NUMBER,
        p_rule_id          OUT NUMBER
    );

    PROCEDURE set_question_image(
        p_session_token IN VARCHAR2,
        p_question_id   IN NUMBER,
        p_file_name     IN VARCHAR2,
        p_mime_type     IN VARCHAR2,
        p_image_data    IN BLOB
    );

    PROCEDURE set_option_image(
        p_session_token IN VARCHAR2,
        p_option_id     IN NUMBER,
        p_file_name     IN VARCHAR2,
        p_mime_type     IN VARCHAR2,
        p_image_data    IN BLOB
    );

    PROCEDURE publish_test(
        p_session_token IN VARCHAR2,
        p_test_id       IN NUMBER
    );

    PROCEDURE grant_test_access(
        p_session_token   IN VARCHAR2,
        p_test_id         IN NUMBER,
        p_game_username IN VARCHAR2
    );

    PROCEDURE revoke_test_access(
        p_session_token   IN VARCHAR2,
        p_test_id         IN NUMBER,
        p_game_username IN VARCHAR2
    );

    PROCEDURE create_team(
        p_session_token IN  VARCHAR2,
        p_team_name     IN  VARCHAR2,
        p_team_id       OUT NUMBER,
        p_join_code     OUT VARCHAR2
    );

    PROCEDURE join_team(
        p_session_token IN VARCHAR2,
        p_join_code     IN VARCHAR2
    );

    PROCEDURE start_attempt(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_team_id       IN  NUMBER DEFAULT NULL,
        p_attempt_id    OUT NUMBER
    );

    PROCEDURE get_next_question(
        p_session_token  IN  VARCHAR2,
        p_attempt_id     IN  NUMBER,
        p_attempt_state  OUT VARCHAR2,
        p_seconds_left   OUT NUMBER,
        p_question       OUT SYS_REFCURSOR,
        p_options        OUT SYS_REFCURSOR
    );

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
    );

    PROCEDURE finish_attempt(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    );

    PROCEDURE calculate_result(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    );

    PROCEDURE assign_badges(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    );

    PROCEDURE update_rating(
        p_session_token IN VARCHAR2,
        p_period_code   IN VARCHAR2 DEFAULT 'ALL'
    );

    PROCEDURE generate_certificate(
        p_session_token IN VARCHAR2,
        p_attempt_id    IN NUMBER
    );

    PROCEDURE list_tests(
        p_session_token IN  VARCHAR2,
        p_tests         OUT SYS_REFCURSOR
    );

    PROCEDURE list_categories(p_categories OUT SYS_REFCURSOR);
    PROCEDURE list_question_types(p_types OUT SYS_REFCURSOR);

    PROCEDURE list_topics(
        p_session_token IN  VARCHAR2,
        p_topics        OUT SYS_REFCURSOR
    );

    PROCEDURE list_author_tests(
        p_session_token IN  VARCHAR2,
        p_tests         OUT SYS_REFCURSOR
    );

    PROCEDURE list_test_questions(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_questions     OUT SYS_REFCURSOR
    );

    PROCEDURE list_test_access(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_access        OUT SYS_REFCURSOR
    );

    PROCEDURE get_my_attempts(
        p_session_token IN  VARCHAR2,
        p_attempts      OUT SYS_REFCURSOR
    );

    PROCEDURE get_attempt_result(
        p_session_token IN  VARCHAR2,
        p_attempt_id    IN  NUMBER,
        p_result        OUT SYS_REFCURSOR
    );

    PROCEDURE get_attempt_feedback(
        p_session_token IN  VARCHAR2,
        p_attempt_id    IN  NUMBER,
        p_feedback      OUT SYS_REFCURSOR
    );

    PROCEDURE show_statistics(
        p_session_token IN  VARCHAR2,
        p_test_id       IN  NUMBER,
        p_statistics    OUT SYS_REFCURSOR
    );

    PROCEDURE get_user_comparison(
        p_session_token IN  VARCHAR2,
        p_comparison    OUT SYS_REFCURSOR
    );

    PROCEDURE get_leaderboard(
        p_session_token IN  VARCHAR2,
        p_rating_type   IN  VARCHAR2 DEFAULT 'USER',
        p_period_code   IN  VARCHAR2 DEFAULT 'ALL',
        p_leaderboard   OUT SYS_REFCURSOR
    );

    PROCEDURE get_my_badges(
        p_session_token IN  VARCHAR2,
        p_badges        OUT SYS_REFCURSOR
    );

    PROCEDURE list_teams(
        p_session_token IN  VARCHAR2,
        p_teams         OUT SYS_REFCURSOR
    );

    PROCEDURE get_certificate(
        p_session_token IN  VARCHAR2,
        p_attempt_id    IN  NUMBER,
        p_file_name     OUT VARCHAR2,
        p_mime_type     OUT VARCHAR2,
        p_pdf_data      OUT BLOB
    );
END quiz_platform;
/

SHOW ERRORS PACKAGE quiz_platform
