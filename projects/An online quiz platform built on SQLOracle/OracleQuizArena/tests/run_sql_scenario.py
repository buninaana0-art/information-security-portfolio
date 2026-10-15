

from __future__ import annotations

import os
from pathlib import Path
import re
import sys

from dotenv import load_dotenv
import oracledb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))
from db import QuizDB

load_dotenv(ROOT / "python" / ".env")


def main() -> None:
    name = sys.argv[1]
    if name not in {"smoke_test.sql", "full_regression.sql"}:
        raise ValueError("Use smoke_test.sql or full_regression.sql")
    source = (ROOT / "tests" / name).read_text(encoding="utf-8")
    block = re.search(r"(?ms)^DECLARE\b.*?^/\s*$", source)
    if block is None:
        raise ValueError("SQL scenario has no anonymous PL/SQL block")
    sql = re.sub(r"(?m)^/\s*$", "", block.group()).strip()
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
        try:
            with connection.cursor() as cursor:
                cursor.callproc("DBMS_OUTPUT.ENABLE", [None])
                cursor.execute(sql)
                line = cursor.var(str, size=32767)
                status = cursor.var(oracledb.DB_TYPE_NUMBER)
                while True:
                    cursor.callproc("DBMS_OUTPUT.GET_LINE", [line, status])
                    if int(status.getvalue()) != 0:
                        break
                    print(line.getvalue())
        finally:
            connection.rollback()


if __name__ == "__main__":
    main()
