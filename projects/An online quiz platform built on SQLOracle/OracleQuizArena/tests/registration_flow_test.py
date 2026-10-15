

from __future__ import annotations

import os
from pathlib import Path
import sys
import uuid

from dotenv import load_dotenv
import oracledb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
from db import QuizDB

load_dotenv(ROOT / "python" / ".env")


def main() -> None:
    dsn = QuizDB.make_dsn(
        os.getenv("ORACLE_HOST", "127.0.0.1"),
        os.getenv("ORACLE_PORT", "1521"),
        os.getenv("ORACLE_DATABASE", "FREEPDB1"),
        os.getenv("ORACLE_CONNECT_MODE", "SERVICE"),
    )
    username = "TEST_" + uuid.uuid4().hex[:20].upper()
    email = f"{username.lower()}@quiz.local"
    password = "TestPassword123!"
    with oracledb.connect(
        user=os.environ["ORACLE_USER"],
        password=os.environ["ORACLE_PASSWORD"],
        dsn=dsn,
    ) as connection:
        try:
            with connection.cursor() as cursor:
                user_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                try:
                    cursor.callproc(
                        "quiz_platform.register_user",
                        ["Test Player", email, password, "different-password",
                         username, "PARTICIPANT", user_id],
                    )
                except oracledb.DatabaseError as exc:
                    assert exc.args[0].code == 20065
                else:
                    raise AssertionError("Oracle accepted mismatched registration passwords")
                cursor.callproc(
                    "quiz_platform.register_user",
                    ["Test Player", email, password, password,
                     username, "PARTICIPANT", user_id],
                )
                cursor.execute(
                    "SELECT oracle_username, email, password_salt, password_hash "
                    "FROM qp_users WHERE user_id = :id",
                    id=user_id.getvalue(),
                )
                saved_username, saved_email, salt, digest = cursor.fetchone()
                assert saved_username == username and saved_email == email
                assert len(salt) == 32 and len(digest) == 64
                assert password != digest

                def login(
                    name: str, candidate_password: str,
                    expected_id: int, expected_role: str,
                ) -> str:
                    token = cursor.var(str, size=64)
                    result_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                    display_name = cursor.var(str, size=100)
                    role = cursor.var(str, size=20)
                    cursor.callproc(
                        "quiz_platform.login",
                        [name, candidate_password, "registration test", token,
                         result_id, display_name, role],
                    )
                    assert int(result_id.getvalue()) == expected_id
                    assert role.getvalue() == expected_role
                    return token.getvalue()

                for name, candidate_password in (
                    (username, "wrong-password"),
                    (email, password),
                ):
                    try:
                        login(name, candidate_password, int(user_id.getvalue()), "PARTICIPANT")
                    except oracledb.DatabaseError as exc:
                        assert exc.args[0].code == 20019
                    else:
                        raise AssertionError("Oracle accepted invalid game credentials")

                assert len(login(
                    username, password, int(user_id.getvalue()), "PARTICIPANT",
                )) == 64

                author_name = "AUTHOR_" + uuid.uuid4().hex[:20].upper()
                author_email = f"{author_name.lower()}@quiz.local"
                author_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                try:
                    cursor.callproc(
                        "quiz_platform.register_user",
                        ["Test Author", author_email, password, password,
                         author_name, "ADMIN", author_id],
                    )
                except oracledb.DatabaseError as exc:
                    assert exc.args[0].code == 20082
                else:
                    raise AssertionError("Oracle allowed public admin registration")

                cursor.callproc(
                    "quiz_platform.register_user",
                    ["Test Author", author_email, password, password,
                     author_name, "AUTHOR", author_id],
                )
                author_token = login(
                    author_name, password, int(author_id.getvalue()), "AUTHOR",
                )
                cursor.execute("SELECT MIN(category_id) FROM qp_categories")
                category_id = cursor.fetchone()[0]
                test_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.create_test",
                    [author_token, "Author Registration Test", None, category_id,
                     "PUBLIC", None, None, 60, "AFTER_TEST", "Y", "N", "N",
                     None, test_id],
                )
                cursor.execute(
                    "SELECT author_user_id, test_status FROM qp_tests WHERE test_id = :id",
                    id=test_id.getvalue(),
                )
                assert cursor.fetchone() == (int(author_id.getvalue()), "DRAFT")
        finally:
            connection.rollback()
    print("PASS: Oracle rejects mismatched passwords and stores username, email, salt and hash.")
    print("PASS: login accepts game username/password, rejects wrong password and email.")
    print("PASS: a newly registered author can create a draft test; admin signup is blocked.")


if __name__ == "__main__":
    main()
