

from __future__ import annotations

import os
from pathlib import Path
import sys

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
load_dotenv(ROOT / "python" / ".env")

from db import QuizDB, QuizError


def main() -> None:
    database = QuizDB(
        user=os.environ["ORACLE_USER"],
        password=os.environ["ORACLE_PASSWORD"],
        dsn=QuizDB.make_dsn(
            os.getenv("ORACLE_HOST", "127.0.0.1"),
            os.getenv("ORACLE_PORT", "1521"),
            os.getenv("ORACLE_DATABASE", "FREEPDB1"),
            os.getenv("ORACLE_CONNECT_MODE", "SERVICE"),
        ),
        schema=os.getenv("ORACLE_SCHEMA", "QUIZ_APP"),
        pool_max=2,
    )
    try:
        try:
            database.login("QUIZ_STUDENT", "definitely-wrong", "Invalid game password")
        except QuizError:
            pass
        else:
            raise AssertionError("Game login accepted an invalid password")

        login = database.login("QUIZ_STUDENT", "Student123!", "Game auth test")
        assert login.role == "PARTICIPANT"
        assert len(database.list_tests(login.token)) == 3
        database.logout(login.token)
    finally:
        database.close()

    print("PASS: wrong game password rejected by Oracle package.")
    print("PASS: shared connection opens QUIZ_STUDENT game session.")


if __name__ == "__main__":
    main()
