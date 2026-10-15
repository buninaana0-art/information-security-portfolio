
from pathlib import Path
import sys
import uuid

from dotenv import dotenv_values
import oracledb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from installer_db import install_or_update, run_script
from report_queries_test import verify_reports


def main():
    password = dotenv_values(ROOT / '.local/oracle.env')['ORACLE_PWD']
    schema = 'QUIZ_INSTALL_TEST_' + uuid.uuid4().hex[:10].upper()
    temporary_password = 'Qt' + uuid.uuid4().hex
    dsn = '127.0.0.1:1521/FREEPDB1'
    created = False
    with oracledb.connect(user='system', password=password, dsn=dsn) as admin:
        try:
            with admin.cursor() as cursor:
                cursor.execute(f'CREATE USER {schema} IDENTIFIED BY "{temporary_password}" DEFAULT TABLESPACE quiz_data QUOTA 64M ON quiz_data')
                created = True
                cursor.execute(f'GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE, CREATE SEQUENCE TO {schema}')
            with oracledb.connect(user=schema, password=temporary_password, dsn=dsn) as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT COUNT(*) FROM session_privs WHERE privilege IN ('CREATE VIEW', 'CREATE ANY VIEW', 'CREATE MATERIALIZED VIEW')")
                    assert cursor.fetchone()[0] == 0, 'Test schema must have no view creation privileges'
                install_or_update(connection)

                def counts():
                    result = []
                    with connection.cursor() as cursor:
                        for table in ('qp_users', 'qp_attempts', 'qp_responses', 'qp_certificates', 'qp_sessions'):
                            cursor.execute(f'SELECT COUNT(*) FROM {table}')
                            result.append(cursor.fetchone()[0])
                    return result

                with connection.cursor() as cursor:
                    cursor.execute('SELECT COUNT(*) FROM user_views')
                    assert cursor.fetchone()[0] == 0, 'Fresh installation must create no views'
                before = counts()
                assert before[0] == 5 and before[1] == 24 and before[3] == 24, before
                install_or_update(connection)
                assert counts() == before, (before, counts())
                verify_reports(connection)
                run_script(connection, ROOT / 'tests/smoke_test.sql')
                run_script(connection, ROOT / 'tests/full_regression.sql')
                print('PASS: empty-schema installation without CREATE VIEW, 24 games, repeat without duplicates, full game regression.')
        finally:
            if created:
                with admin.cursor() as cursor:
                    cursor.execute(f'DROP USER {schema} CASCADE')


if __name__ == '__main__':
    main()
