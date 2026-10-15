
import oracledb


def verify_reports(connection):
    def login(username, password):
        with connection.cursor() as cursor:
            token = cursor.var(str, size=64)
            user_id = cursor.var(oracledb.DB_TYPE_NUMBER)
            name = cursor.var(str, size=100)
            role = cursor.var(str, size=20)
            cursor.callproc('quiz_platform.login',
                            [username, password, 'Report regression', token, user_id, name, role])
            return token.getvalue()

    def fetch(procedure, *args):
        with connection.cursor() as cursor, connection.cursor() as result:
            cursor.callproc('quiz_platform.' + procedure, [*args, result])
            columns = [column[0].lower() for column in result.description]
            return [dict(zip(columns, row)) for row in result.fetchall()]

    try:
        player = login('DEMO_ALICE', 'DemoAlice123!')
        catalog = fetch('list_tests', player)
        assert len(catalog) == 3
        assert all(row['completed_attempts'] == 8 for row in catalog)
        attempts = fetch('get_my_attempts', player)
        assert len(attempts) == 12
        assert all(row['certificate_no'] for row in attempts)
        result = fetch('get_attempt_result', player, attempts[0]['attempt_id'])
        assert len(result) == 1
        assert result[0]['percent_score'] == attempts[0]['percent_score']
        comparison = fetch('get_user_comparison', player)
        assert len(comparison) == 12

        assert all(row['participants_count'] == 8 for row in comparison)
        with connection.cursor() as cursor:
            cursor.execute('SELECT test_id, ROUND(AVG(percent_score), 2) FROM qp_attempts '
                           "WHERE attempt_status IN ('COMPLETED', 'TIMED_OUT') GROUP BY test_id")
            averages = dict(cursor.fetchall())
        assert all(row['test_average_percent'] == averages[row['test_id']] for row in comparison)

        author = login('QUIZ_AUTHOR', 'Author123!')
        assert len(fetch('list_author_tests', author)) == 3
        statistics = fetch('show_statistics', author, 1)
        assert len(statistics) == 7
        first = next(row for row in statistics if row['question_id'] == 1)
        with connection.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) FROM qp_attempt_questions WHERE question_id = 1 AND is_correct = 'Y'")
            assert first['correct_count'] == cursor.fetchone()[0]
        print('PASS: catalog, author catalog, attempts, results, statistics and comparison without views.')
    finally:
        connection.rollback()
