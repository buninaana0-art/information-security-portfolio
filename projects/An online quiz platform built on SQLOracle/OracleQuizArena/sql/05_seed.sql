

INSERT INTO qp_question_types (question_type_id, type_code, type_name, description)
VALUES (1, 'SINGLE', 'Один вариант', 'Выбор ровно одного варианта.');
INSERT INTO qp_question_types (question_type_id, type_code, type_name, description)
VALUES (2, 'MULTIPLE', 'Несколько вариантов', 'Выбор полного множества правильных вариантов.');
INSERT INTO qp_question_types (question_type_id, type_code, type_name, description)
VALUES (3, 'TEXT', 'Текстовый ответ', 'Сравнение с текстовым или регулярным эталоном.');
INSERT INTO qp_question_types (question_type_id, type_code, type_name, description)
VALUES (4, 'TRUE_FALSE', 'Верно или неверно', 'Бинарный вариант ответа.');
INSERT INTO qp_question_types (question_type_id, type_code, type_name, description)
VALUES (5, 'NUMBER', 'Числовой ответ', 'Число с настраиваемой допустимой погрешностью.');
INSERT INTO qp_question_types (question_type_id, type_code, type_name, description)
VALUES (6, 'ORDERING', 'Упорядочивание', 'Размещение элементов в правильной последовательности.');
INSERT INTO qp_question_types (question_type_id, type_code, type_name, description)
VALUES (7, 'MATCHING', 'Сопоставление', 'Сопоставление каждого элемента с текстовым значением.');

INSERT INTO qp_categories (category_id, category_name, description)
VALUES (1, 'Oracle SQL', 'SQL и объекты реляционной схемы Oracle.');
INSERT INTO qp_categories (category_id, category_name, description)
VALUES (2, 'PL/SQL', 'Процедуры, функции, пакеты и обработка исключений.');
INSERT INTO qp_categories (category_id, category_name, description)
VALUES (3, 'Базы данных', 'Общие понятия проектирования и транзакций.');
INSERT INTO qp_categories (category_id, category_name, description)
VALUES (4, 'Развлекательные квизы', 'Неформальные командные игры.');

INSERT INTO qp_users (
    user_id, oracle_username, display_name, email, password_salt,
    password_hash, user_role, user_status
) VALUES (
    1, 'QUIZ_ADMIN', 'Администратор', 'admin@quiz.local',
    '11111111111111111111111111111111',
    RAWTOHEX(STANDARD_HASH(
        'Admin123!:11111111111111111111111111111111', 'SHA256'
    )),
    'ADMIN', 'ACTIVE'
);

INSERT INTO qp_users (
    user_id, oracle_username, display_name, email, password_salt,
    password_hash, user_role, user_status
) VALUES (
    2, 'QUIZ_AUTHOR', 'Автор демонстрационного квиза', 'author@quiz.local',
    '22222222222222222222222222222222',
    RAWTOHEX(STANDARD_HASH(
        'Author123!:22222222222222222222222222222222', 'SHA256'
    )),
    'AUTHOR', 'ACTIVE'
);

INSERT INTO qp_users (
    user_id, oracle_username, display_name, email, password_salt,
    password_hash, user_role, user_status
) VALUES (
    3, 'QUIZ_STUDENT', 'Студент', 'student@quiz.local',
    '33333333333333333333333333333333',
    RAWTOHEX(STANDARD_HASH(
        'Student123!:33333333333333333333333333333333', 'SHA256'
    )),
    'PARTICIPANT', 'ACTIVE'
);

INSERT INTO qp_topics (topic_id, owner_user_id, topic_name, description)
VALUES (1, 2, 'Учебные тесты', 'Контроль знаний по дисциплине.');
INSERT INTO qp_topics (topic_id, owner_user_id, topic_name, description)
VALUES (2, 2, 'Oracle', 'Тесты по Oracle Database и PL/SQL.');
INSERT INTO qp_topics (topic_id, owner_user_id, topic_name, description)
VALUES (3, 2, 'Командные игры', 'Квизы для командного режима.');

INSERT INTO qp_badges (
    badge_id, badge_code, badge_name, description, rule_code, threshold_value
) VALUES (
    1, 'FIRST_STEP', 'Первый шаг', 'Завершить первую попытку.', 'FIRST_ATTEMPT', 1
);
INSERT INTO qp_badges (
    badge_id, badge_code, badge_name, description, rule_code, threshold_value
) VALUES (
    2, 'PERFECT', 'Без единой ошибки', 'Набрать 100 процентов.', 'PERFECT_SCORE', 100
);
INSERT INTO qp_badges (
    badge_id, badge_code, badge_name, description, rule_code, threshold_value
) VALUES (
    3, 'EXCELLENT', 'Отличный результат', 'Набрать не менее 90 процентов.', 'SCORE_AT_LEAST', 90
);
INSERT INTO qp_badges (
    badge_id, badge_code, badge_name, description, rule_code, threshold_value
) VALUES (
    4, 'EXPLORER', 'Исследователь', 'Завершить три разных теста.', 'TESTS_COMPLETED', 3
);
INSERT INTO qp_badges (
    badge_id, badge_code, badge_name, description, rule_code, threshold_value
) VALUES (
    5, 'SPRINTER', 'Спринтер', 'Завершить попытку не более чем за 180 секунд.', 'FAST_FINISH', 180
);

INSERT INTO qp_tests (
    test_id, author_user_id, primary_category_id, test_title, description,
    test_status, access_mode, time_limit_minutes, question_count,
    pass_percent, feedback_mode, show_correct_answers, adaptive_flag,
    team_mode_flag, max_attempts, published_at
) VALUES (
    1, 2, 1, 'Oracle и PL/SQL: семь форматов',
    'Демонстрационный тест показывает все типы вопросов и таймеры.',
    'PUBLISHED', 'PUBLIC', 20, 7, 60, 'IMMEDIATE', 'Y', 'N', 'N', NULL,
    SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_test_topics (test_id, topic_id) VALUES (1, 1);
INSERT INTO qp_test_topics (test_id, topic_id) VALUES (1, 2);

INSERT INTO qp_questions (
    question_id, test_id, question_type_id, category_id, question_text,
    difficulty_level, display_order, points, time_limit_seconds,
    adaptive_flag, explanation
) VALUES (
    1, 1, 1, 1, 'Какое предложение используется для чтения строк из таблицы?',
    1, 1, 1, 45, 'Y', 'SELECT формирует результирующий набор запроса.'
);
INSERT INTO qp_answer_options (option_id, question_id, option_text, is_correct, display_order)
VALUES (1, 1, 'SELECT', 'Y', 1);
INSERT INTO qp_answer_options (option_id, question_id, option_text, is_correct, display_order)
VALUES (2, 1, 'GRANT', 'N', 2);
INSERT INTO qp_answer_options (option_id, question_id, option_text, is_correct, display_order)
VALUES (3, 1, 'COMMIT', 'N', 3);
INSERT INTO qp_answer_options (option_id, question_id, option_text, is_correct, display_order)
VALUES (4, 1, 'ALTER', 'N', 4);

INSERT INTO qp_questions (
    question_id, test_id, question_type_id, category_id, question_text,
    difficulty_level, display_order, points, time_limit_seconds,
    adaptive_flag, explanation
) VALUES (
    2, 1, 2, 2, 'Какие именованные программные модули существуют в PL/SQL?',
    2, 2, 2, 60, 'Y', 'К именованным подпрограммам относятся процедуры и функции.'
);
INSERT INTO qp_answer_options VALUES (5, 2, 'Процедура', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (6, 2, 'Функция', 'Y', 2, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (7, 2, 'Табличное пространство', 'N', 3, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (8, 2, 'Индекс', 'N', 4, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions (
    question_id, test_id, question_type_id, category_id, question_text,
    difficulty_level, display_order, points, time_limit_seconds,
    adaptive_flag, explanation
) VALUES (
    3, 1, 3, 1, 'Введите имя системной однострочной таблицы Oracle.',
    2, 3, 2, 45, 'Y', 'DUAL применяется, когда запросу не нужна прикладная таблица.'
);
INSERT INTO qp_question_keys (
    key_id, question_id, key_type, accepted_text, case_sensitive_flag
) VALUES (1, 3, 'TEXT', 'DUAL', 'N');

INSERT INTO qp_questions (
    question_id, test_id, question_type_id, category_id, question_text,
    difficulty_level, display_order, points, time_limit_seconds,
    adaptive_flag, explanation
) VALUES (
    4, 1, 4, 3, 'COMMIT завершает текущую транзакцию и фиксирует изменения.',
    1, 4, 1, 30, 'Y', 'COMMIT делает изменения текущей транзакции постоянными.'
);
INSERT INTO qp_answer_options VALUES (9, 4, 'Верно', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (10, 4, 'Неверно', 'N', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions (
    question_id, test_id, question_type_id, category_id, question_text,
    difficulty_level, display_order, points, time_limit_seconds,
    adaptive_flag, explanation
) VALUES (
    5, 1, 5, 3, 'Сколько строк содержит декартово произведение таблиц из 6 и 7 строк?',
    2, 5, 2, 45, 'Y', 'Для декартова произведения мощности перемножаются: 6 × 7 = 42.'
);
INSERT INTO qp_question_keys (
    key_id, question_id, key_type, numeric_value, numeric_tolerance,
    case_sensitive_flag
) VALUES (2, 5, 'NUMBER', 42, 0, 'N');

INSERT INTO qp_questions (
    question_id, test_id, question_type_id, category_id, question_text,
    difficulty_level, display_order, points, time_limit_seconds,
    adaptive_flag, explanation
) VALUES (
    6, 1, 6, 1, 'Расположите части запроса в логическом порядке обработки Oracle.',
    4, 6, 3, 90, 'Y', 'Сначала формируется источник, затем фильтрация, группировка, проекция и сортировка.'
);
INSERT INTO qp_answer_options VALUES (11, 6, 'FROM', 'N', 1, 1, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (12, 6, 'WHERE', 'N', 2, 2, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (13, 6, 'GROUP BY', 'N', 3, 3, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (14, 6, 'SELECT', 'N', 4, 4, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (15, 6, 'ORDER BY', 'N', 5, 5, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions (
    question_id, test_id, question_type_id, category_id, question_text,
    difficulty_level, display_order, points, time_limit_seconds,
    adaptive_flag, explanation
) VALUES (
    7, 1, 7, 1, 'Сопоставьте тип Oracle с примером значения.',
    3, 7, 3, 90, 'Y', 'NUMBER хранит числа, VARCHAR2 строки, DATE даты.'
);
INSERT INTO qp_answer_options VALUES (16, 7, 'NUMBER', 'N', 1, NULL, '42', NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (17, 7, 'VARCHAR2', 'N', 2, NULL, 'Oracle', NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (18, 7, 'DATE', 'N', 3, NULL, '2026-09-10', NULL, NULL, NULL);

INSERT INTO qp_tests (
    test_id, author_user_id, primary_category_id, test_title, description,
    test_status, access_mode, time_limit_minutes, question_count,
    pass_percent, feedback_mode, show_correct_answers, adaptive_flag,
    team_mode_flag, max_attempts, published_at
) VALUES (
    2, 2, 2, 'Адаптивный PL/SQL',
    'После правильного ответа сложность повышается, после ошибки снижается.',
    'PUBLISHED', 'RESTRICTED', 10, 5, 70, 'AFTER_TEST', 'Y', 'Y', 'N', 5,
    SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_test_topics (test_id, topic_id) VALUES (2, 1);
INSERT INTO qp_test_topics (test_id, topic_id) VALUES (2, 2);
INSERT INTO qp_test_access (test_id, oracle_username, granted_by_user_id)
VALUES (2, 'QUIZ_STUDENT', 2);

INSERT INTO qp_questions VALUES (
    101, 2, 4, 2, 'PL/SQL является процедурным расширением SQL.', 1, 1, 1,
    35, 'Y', 'PL/SQL добавляет блоки, переменные, ветвления и исключения.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (101, 101, 'Верно', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (102, 101, 'Неверно', 'N', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    102, 2, 1, 2, 'Какое слово начинает секцию обработки исключений?', 2, 2, 1,
    40, 'Y', 'Секция начинается ключевым словом EXCEPTION.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (103, 102, 'EXCEPTION', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (104, 102, 'ERROR', 'N', 2, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (105, 102, 'CATCH', 'N', 3, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    103, 2, 3, 2, 'Как называется атрибут курсора с числом обработанных строк?', 3, 3, 2,
    50, 'Y', 'SQL%ROWCOUNT содержит число строк последнего SQL-оператора.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_question_keys VALUES (101, 103, 'TEXT', 'SQL%ROWCOUNT', NULL, NULL, 'N');

INSERT INTO qp_questions VALUES (
    104, 2, 2, 2, 'Какие параметры подпрограммы могут возвращать значение?', 4, 4, 2,
    55, 'Y', 'Режимы OUT и IN OUT передают значение вызывающему коду.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (106, 104, 'OUT', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (107, 104, 'IN OUT', 'Y', 2, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (108, 104, 'IN', 'N', 3, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    105, 2, 1, 2, 'Какой механизм позволяет скрыть реализацию пакета?', 5, 5, 3,
    60, 'Y', 'Спецификация публикует интерфейс, тело пакета скрывает реализацию.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (109, 105, 'Разделение на спецификацию и тело', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (110, 105, 'Только синоним', 'N', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    106, 2, 5, 2, 'Сколько обязательных секций BEGIN содержит простой PL/SQL-блок?',
    1, 6, 1, 35, 'Y', 'Исполняемая секция BEGIN обязательна и одна.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_question_keys VALUES (102, 106, 'NUMBER', NULL, 1, 0, 'N');

INSERT INTO qp_questions VALUES (
    107, 2, 4, 2, 'Процедура обязана возвращать значение оператором RETURN.',
    2, 7, 1, 35, 'Y', 'В отличие от функции, процедура не обязана возвращать значение.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (111, 107, 'Верно', 'N', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (112, 107, 'Неверно', 'Y', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    108, 2, 3, 2, 'Введите имя стандартного исключения отсутствия строки.',
    3, 8, 2, 50, 'Y', 'SELECT INTO без строк вызывает NO_DATA_FOUND.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_question_keys VALUES (103, 108, 'TEXT', 'NO_DATA_FOUND', NULL, NULL, 'N');

INSERT INTO qp_questions VALUES (
    109, 2, 1, 2, 'Какая директива делает транзакцию подпрограммы независимой?',
    4, 9, 2, 55, 'Y', 'PRAGMA AUTONOMOUS_TRANSACTION создаёт автономную транзакцию.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (113, 109, 'PRAGMA AUTONOMOUS_TRANSACTION', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (114, 109, 'AUTHID CURRENT_USER', 'N', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    110, 2, 1, 2, 'Что кэширует результат детерминированной функции между вызовами?',
    5, 10, 3, 60, 'Y', 'RESULT_CACHE сохраняет результаты для повторного использования.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (115, 110, 'RESULT_CACHE', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (116, 110, 'PIPELINED', 'N', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_test_rules (rule_id, test_id, category_id, difficulty_level, question_count)
VALUES (1, 2, 2, NULL, 10);

INSERT INTO qp_tests (
    test_id, author_user_id, primary_category_id, test_title, description,
    test_status, access_mode, time_limit_minutes, question_count,
    pass_percent, feedback_mode, show_correct_answers, adaptive_flag,
    team_mode_flag, max_attempts, published_at
) VALUES (
    3, 2, 4, 'Командный блиц',
    'Мок-реализация командного квиза: попытка привязывается к команде и влияет на командный рейтинг.',
    'PUBLISHED', 'PUBLIC', 5, 3, 50, 'AFTER_TEST', 'Y', 'N', 'Y', NULL,
    SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_test_topics (test_id, topic_id) VALUES (3, 3);

INSERT INTO qp_questions VALUES (
    201, 3, 1, 4, 'Сколько байт в одном килобайте по двоичной системе?',
    1, 1, 1, 30, 'Y', 'В двоичном исчислении килобайт равен 1024 байтам.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (201, 201, '1024', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (202, 201, '1000', 'N', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    202, 3, 4, 4, 'Oracle Database является реляционной СУБД.',
    1, 2, 1, 30, 'Y', 'Oracle Database поддерживает реляционную модель данных.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_answer_options VALUES (203, 202, 'Верно', 'Y', 1, NULL, NULL, NULL, NULL, NULL);
INSERT INTO qp_answer_options VALUES (204, 202, 'Неверно', 'N', 2, NULL, NULL, NULL, NULL, NULL);

INSERT INTO qp_questions VALUES (
    203, 3, 5, 4, 'Сколько букв в слове ORACLE?',
    1, 3, 1, 30, 'Y', 'В слове ORACLE шесть букв.',
    NULL, NULL, NULL, 'Y', SYS_EXTRACT_UTC(SYSTIMESTAMP)
);
INSERT INTO qp_question_keys VALUES (201, 203, 'NUMBER', NULL, 6, 0, 'N');

INSERT INTO qp_teams (team_id, owner_user_id, team_name, join_code)
VALUES (1, 3, 'Команда SQL', 'SQL2026A');
INSERT INTO qp_team_members (team_id, user_id, member_role)
VALUES (1, 3, 'CAPTAIN');

COMMIT;
