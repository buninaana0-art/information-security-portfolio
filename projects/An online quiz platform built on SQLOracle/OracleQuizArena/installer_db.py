
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent


def statements(source: str):

    buffer = ""
    quote = None
    block_comment = False
    plsql = False
    for line in source.splitlines(keepends=True):
        stripped = line.strip()
        if not buffer.strip() and not block_comment:
            if not stripped or stripped.startswith("--"):
                continue
            if re.match(r"(?i)^(SET|WHENEVER|PROMPT|SHOW|EXIT)\b", stripped):
                continue
            if stripped.startswith("@@"):
                yield "include", stripped[2:]
                continue
            plsql = bool(re.match(
                r"(?i)^(DECLARE|BEGIN|CREATE\s+OR\s+REPLACE\s+PACKAGE)\b", stripped
            ))
        if plsql:
            if stripped == "/":
                yield "sql", buffer.strip()
                buffer = ""
                plsql = False
            else:
                buffer += line
            continue
        i = 0
        while i < len(line):
            char = line[i]
            pair = line[i:i + 2]
            if block_comment:
                if pair == "*/":
                    block_comment = False
                    i += 2
                else:
                    i += 1
                continue
            if quote:
                buffer += char
                if char == quote:
                    if i + 1 < len(line) and line[i + 1] == quote:
                        buffer += quote
                        i += 1
                    else:
                        quote = None
            elif pair == "--":
                buffer += "\n"
                break
            elif pair == "/*":
                block_comment = True
                buffer += " "
                i += 1
            elif char in ("'", '"'):
                quote = char
                buffer += char
            elif char == ";":
                if buffer.strip():
                    yield "sql", buffer.strip()
                buffer = ""
            else:
                buffer += char
            i += 1
    if buffer.strip() or quote or block_comment or plsql:
        raise ValueError("Unterminated SQL statement or PL/SQL block")


def run_script(connection, path: Path) -> None:
    path = path.resolve()
    if not path.is_relative_to(ROOT):
        raise ValueError("Installer scripts must stay inside the project")
    print(f"SQL: {path.relative_to(ROOT)}", flush=True)
    with connection.cursor() as cursor:
        for kind, command in statements(path.read_text(encoding="utf-8-sig")):
            if kind == "include":
                run_script(connection, path.parent / command)
            else:
                cursor.execute(command)


def check_package(connection) -> None:
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT type, line, position, text FROM user_errors "
            "WHERE name = 'QUIZ_PLATFORM' ORDER BY sequence"
        )
        errors = cursor.fetchall()
        if errors:
            raise RuntimeError(f"QUIZ_PLATFORM compilation errors: {errors}")
        cursor.execute("SELECT COUNT(*) FROM user_objects WHERE object_name = "
                       "'QUIZ_PLATFORM' AND status = 'VALID' "
                       "AND object_type IN ('PACKAGE', 'PACKAGE BODY')")
        if cursor.fetchone()[0] != 2:
            raise RuntimeError("QUIZ_PLATFORM package is missing or invalid")


def install_or_update(connection) -> None:
    try:
        major_version = int(str(connection.version).split('.', 1)[0])
    except (TypeError, ValueError) as exc:
        raise RuntimeError(
            f"Could not determine Oracle Database version: {connection.version!r}"
        ) from exc
    if major_version < 12:
        raise RuntimeError(
            f"Oracle Database 12c or newer is required; connected version is "
            f"{connection.version}. No schema changes were made."
        )
    with connection.cursor() as cursor:
        cursor.execute("SELECT COUNT(*) FROM user_tables WHERE table_name LIKE 'QP\\_%' ESCAPE '\\'")
        count = cursor.fetchone()[0]
    if count == 0:
        run_script(connection, ROOT / "sql/install.sql")
    elif count == 23:

        for name in ("03_package_spec.sql", "04_package_body.sql"):
            run_script(connection, ROOT / "sql" / name)
        check_package(connection)
        run_script(connection, ROOT / "tests/verify_install.sql")
        run_script(connection, ROOT / "sql/06_demo_history.sql")
    else:
        raise RuntimeError(
            f"Found an incomplete schema ({count}/23 QP tables). "
            "No tables were deleted. Restore the schema or use an empty schema."
        )
    check_package(connection)
    run_script(connection, ROOT / "tests/verify_install.sql")
    run_script(connection, ROOT / "tests/verify_demo_history.sql")
    connection.commit()
