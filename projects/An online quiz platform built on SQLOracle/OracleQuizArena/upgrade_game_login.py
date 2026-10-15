

from __future__ import annotations

import os
from pathlib import Path
import re
import sys

from dotenv import load_dotenv
import oracledb

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "python"))
from db import QuizDB

load_dotenv(ROOT / "python" / ".env")


def package_source(path: Path) -> str:
    source = path.read_text(encoding="utf-8")
    return re.split(r"(?m)^/\s*$", source, maxsplit=1)[0].strip()


def main() -> None:
    dsn = QuizDB.make_dsn(
        os.getenv("ORACLE_HOST", "127.0.0.1"),
        os.getenv("ORACLE_PORT", "1521"),
        os.getenv("ORACLE_DATABASE", "FREEPDB1"),
        os.getenv("ORACLE_CONNECT_MODE", "SERVICE"),
    )
    with oracledb.connect(
        user=os.environ["ORACLE_USER"],
        password=os.environ["ORACLE_PASSWORD"],
        dsn=dsn,
    ) as connection:
        with connection.cursor() as cursor:
            for filename in ("03_package_spec.sql", "04_package_body.sql"):
                cursor.execute(package_source(ROOT / "sql" / filename))
            cursor.execute(
                "SELECT object_type, status FROM user_objects "
                "WHERE object_name = 'QUIZ_PLATFORM' "
                "AND object_type IN ('PACKAGE', 'PACKAGE BODY')"
            )
            statuses = dict(cursor.fetchall())
            if statuses != {"PACKAGE": "VALID", "PACKAGE BODY": "VALID"}:
                cursor.execute(
                    "SELECT type, line, position, text FROM user_errors "
                    "WHERE name = 'QUIZ_PLATFORM' ORDER BY sequence"
                )
                errors = "\n".join(map(str, cursor.fetchall()))
                raise RuntimeError(f"QUIZ_PLATFORM is invalid: {statuses}\n{errors}")
    print("QUIZ_PLATFORM updated; existing data preserved.")


if __name__ == "__main__":
    main()
