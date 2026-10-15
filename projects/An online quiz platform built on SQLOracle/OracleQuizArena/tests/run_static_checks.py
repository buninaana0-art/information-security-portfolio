

from __future__ import annotations

import ast
import io
import re
import tokenize
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "sql"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def public_procedures(text: str) -> set[str]:
    return {
        name.lower()
        for name in re.findall(
            r"^\s{4}PROCEDURE\s+([a-z_][a-z0-9_]*)\s*(?:\(|;|IS\b|AS\b)",
            text,
            re.I | re.M,
        )
    }


def procedure_signatures(text: str) -> dict[str, str]:


    signatures: dict[str, str] = {}
    pattern = re.compile(
        r"^ {4}PROCEDURE\s+([a-z_][a-z0-9_]*)\s*",
        re.I | re.M,
    )
    for match in pattern.finditer(text):
        name = match.group(1).lower()
        position = match.end()
        parameters = ""
        if position < len(text) and text[position] == "(":
            depth = 0
            quote = False
            cursor = position
            while cursor < len(text):
                char = text[cursor]
                if char == "'":
                    if quote and cursor + 1 < len(text) and text[cursor + 1] == "'":
                        cursor += 2
                        continue
                    quote = not quote
                elif not quote:
                    if char == "(":
                        depth += 1
                    elif char == ")":
                        depth -= 1
                        if depth == 0:
                            parameters = text[position + 1 : cursor]
                            break
                cursor += 1
            else:
                raise AssertionError(f"Unclosed parameter list for {name}")
        normalized = re.sub(r"\s+", " ", parameters.strip()).lower()
        signatures[name] = f"{name}({normalized})"
    return signatures


def main() -> None:
    schema = read(SQL / "01_schema.sql")
    spec = read(SQL / "03_package_spec.sql")
    body = read(SQL / "04_package_body.sql")
    seed = read(SQL / "05_seed.sql")
    installer = read(SQL / "install.sql")
    db_adapter = read(ROOT / "python" / "db.py")
    app = read(ROOT / "python" / "desktop_app.py")

    tables = re.findall(r"^CREATE TABLE\s+(\w+)", schema, re.I | re.M)
    expected_tables = {
        "qp_users", "qp_sessions", "qp_categories", "qp_topics",
        "qp_question_types", "qp_tests", "qp_test_topics", "qp_test_access",
        "qp_questions", "qp_answer_options", "qp_question_keys",
        "qp_test_rules", "qp_teams", "qp_team_members", "qp_attempts",
        "qp_attempt_questions", "qp_attempt_options", "qp_responses",
        "qp_badges", "qp_user_badges", "qp_rating_snapshots",
        "qp_certificates", "qp_audit_log",
    }
    actual_tables = {name.lower() for name in tables}
    assert actual_tables == expected_tables, (
        f"Schema table mismatch: missing={sorted(expected_tables - actual_tables)}, "
        f"extra={sorted(actual_tables - expected_tables)}"
    )
    assert len(tables) == len(set(map(str.lower, tables))), "Duplicate table name"

    normalized_schema = re.sub(r"\s+", " ", schema).lower()
    assert (
        "case when rating_type = 'user' then user_id end, "
        "case when rating_type = 'user' then period_code end"
    ) in normalized_schema, "User rating index must exclude TEAM rows completely"
    assert (
        "case when rating_type = 'team' then team_id end, "
        "case when rating_type = 'team' then period_code end"
    ) in normalized_schema, "Team rating index must exclude USER rows completely"

    spec_procs = public_procedures(spec)
    body_procs = public_procedures(body)
    missing = sorted(spec_procs - body_procs)
    assert not missing, f"Package body misses public procedures: {missing}"
    spec_signatures = procedure_signatures(spec)
    body_signatures = procedure_signatures(body)
    signature_mismatches = sorted(
        name
        for name, signature in spec_signatures.items()
        if body_signatures.get(name) != signature
    )
    assert not signature_mismatches, (
        "Package specification/body signature mismatch: "
        f"{signature_mismatches}"
    )

    required = {
        "register_user", "login", "login_oracle", "create_test", "add_question",
        "start_attempt", "get_next_question", "submit_answer",
        "finish_attempt", "calculate_result", "assign_badges",
        "update_rating", "generate_certificate", "show_statistics",
    }
    assert required <= spec_procs, f"Missing required API: {sorted(required - spec_procs)}"
    assert "candidate.login(username, password" in app
    assert "candidate.login_oracle" not in app
    assert "def login_oracle" not in db_adapter
    login_oracle_section = body.lower().split("procedure login_oracle(", 1)[1].split("end login_oracle;", 1)[0]
    assert "fail(-20081" in login_oracle_section
    assert "p_login is null or p_password is null" in body.lower()
    assert "v_password_hash := password_hash(p_password, v_salt)" in body.lower()
    assert "p_password <> p_password_repeat" in body.lower()
    assert "v_role not in ('participant', 'author')" in body.lower()
    assert "v_password_hash, v_role, 'active'" in body.lower()
    assert "password != password_repeat" not in app
    assert "where upper(oracle_username) = upper(trim(p_login))" in body.lower()

    type_codes = set(re.findall(r"VALUES\s*\(\d+,\s*'([A-Z_]+)'", seed, re.I))
    expected_types = {
        "SINGLE", "MULTIPLE", "TEXT", "TRUE_FALSE",
        "NUMBER", "ORDERING", "MATCHING",
    }
    assert expected_types <= {value.upper() for value in type_codes}
    seeded_questions = len(re.findall(r"INSERT\s+INTO\s+qp_questions\b", seed, re.I))
    assert seeded_questions == 20, f"Expected 20 demo questions, found {seeded_questions}"

    for filename in [
        "01_schema.sql", "03_package_spec.sql",
        "04_package_body.sql", "05_seed.sql", "06_demo_history.sql",
    ]:
        assert f"@@{filename}" in installer, f"Installer omits {filename}"

    university_launcher = read(ROOT / "INSTALL_UNIVERSITY_SERVER.cmd")
    assert "-UseExistingDatabase" in university_launcher
    assert "install_and_run.ps1" in university_launcher

    assert "qp_v_" not in body.lower(), "Package must query tables directly"
    ratings_body = body.lower()
    ratings_start = ratings_body.index("procedure rebuild_ratings_internal")
    ratings_end = ratings_body.index("procedure generate_certificate_internal", ratings_start)
    ratings_section = ratings_body[ratings_start:ratings_end]
    assert "dense_rank()" not in ratings_section, (
        "Oracle 12.2 cannot reliably combine analytic ranking with grouped inserts"
    )
    assert ratings_section.count("for r in (") == 2
    assert ratings_section.count("insert into qp_rating_snapshots") == 2
    for sql_file in (ROOT / "sql").glob("*.sql"):
        assert not re.search(r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?VIEW\b", sql_file.read_text(encoding="utf-8"), re.I), sql_file

    assert "score_response" not in app.lower()
    assert "standard_hash" not in app.lower()
    forbidden_client_logic = {
        "timer_seconds": "client-owned countdown",
        "_tick_timer": "client-owned timer decision",
        "float(raw)": "client-side numeric answer validation",
        'result.get("is_correct")': "client-side correctness decision",
        'result.get("passed_flag")': "client-side pass/fail decision",
        'row.get("is_correct")': "client-side feedback classification",
        'payload.get("seconds_left")': "client-side deadline handling",
        "int(difficulty.get())": "client-side difficulty validation",
        "float(points.get()": "client-side points validation",
        "float(pass_percent.get()": "client-side pass-percent validation",
    }
    for snippet, description in forbidden_client_logic.items():
        assert snippet not in app.lower(), f"Forbidden {description}: {snippet}"
    assert 'if not team_map:' not in app, "Client must not decide team-test eligibility"
    assert '"FINAL"' not in app and '"NONE"' not in app, (
        "Desktop feedback choices must use Oracle enum values"
    )

    body_lower = body.lower()
    empty_start = body_lower.index("procedure open_empty_question")
    next_start = body_lower.index("procedure get_next_question", empty_start)
    submit_start = body_lower.index("procedure submit_answer", next_start)
    empty_question = body_lower[empty_start:next_start]
    live_question = body_lower[next_start:submit_start]
    assert "v_q_deadline" not in empty_question
    assert "p_seconds_left" not in empty_question
    assert "cast(null as varchar2(100)) as timer_text" in empty_question
    assert "end as timer_text" in live_question
    finish_start = body_lower.index("procedure finish_attempt")
    calculate_start = body_lower.index("procedure calculate_result", finish_start)
    finish_section = body_lower[finish_start:calculate_start]
    assert "v_completed < v_target" not in finish_section
    assert "finalize_attempt_internal(p_attempt_id, 'completed', 'user_finish')" in finish_section
    certificate_start = body_lower.index("procedure generate_certificate_internal")
    recalculate_start = body_lower.index("procedure recalculate_result_internal", certificate_start)
    certificate_section = body_lower[certificate_start:recalculate_start]
    assert "v_percent < v_pass_percent" not in certificate_section
    assert "def _refresh_game_from_oracle" in app
    assert 'self.timer_label.configure(text=str(question["timer_text"]))' in app

    oracle_rule_markers = {
        "function score_response": "answer scoring",
        "procedure expire_due_state": "deadline enforcement",
        "current_difficulty = case": "adaptive difficulty",
        "finalize_attempt_internal": "attempt finalization",
        "assign_badges_internal": "badge assignment",
        "rebuild_ratings_internal": "rating calculation",
        "generate_certificate_internal": "certificate generation",
        "p_result_message := case v_correct": "feedback classification",
    }
    for marker, description in oracle_rule_markers.items():
        assert marker in body_lower, f"Oracle package misses {description}: {marker}"
    for type_code in expected_types:
        assert type_code in app, f"Desktop UI has no widget for {type_code}"

    called_procedures = {
        name.lower()
        for name in re.findall(
            r"['\"]quiz_platform\.([a-z_][a-z0-9_]*)['\"]",
            db_adapter,
            re.I,
        )
    }
    unknown_calls = sorted(called_procedures - spec_procs)
    assert not unknown_calls, f"Python calls unknown package procedures: {unknown_calls}"
    assert {"set_question_image", "set_option_image"} <= called_procedures

    python_trees: dict[str, ast.AST] = {}
    for python_file in (ROOT / "python").glob("*.py"):
        python_trees[python_file.name] = ast.parse(
            read(python_file), filename=str(python_file)
        )

    quiz_db = next(
        node
        for node in ast.walk(python_trees["db.py"])
        if isinstance(node, ast.ClassDef) and node.name == "QuizDB"
    )
    db_methods = {
        node.name for node in quiz_db.body if isinstance(node, ast.FunctionDef)
    }
    desktop_tree = python_trees["desktop_app.py"]
    app_db_calls = {
        node.func.attr
        for node in ast.walk(desktop_tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Attribute)
        and isinstance(node.func.value.value, ast.Name)
        and node.func.value.value.id == "self"
        and node.func.value.attr == "db"
    }
    assert app_db_calls <= db_methods, (
        f"Desktop UI calls missing QuizDB methods: {sorted(app_db_calls - db_methods)}"
    )

    for test_name in ["smoke_test.sql", "verify_install.sql", "full_regression.sql"]:
        test_text = read(ROOT / "tests" / test_name)
        assert "WHENEVER SQLERROR EXIT" in test_text
        if test_name != "verify_install.sql":
            assert "ROLLBACK" in test_text.upper()

    source_paths = [
        *ROOT.glob("*.py"), *ROOT.glob("python/*.py"), *ROOT.glob("tests/*.py")
    ]
    for source_path in source_paths:
        source = read(source_path)
        tokens = tokenize.generate_tokens(io.StringIO(source).readline)
        assert all(token.type != tokenize.COMMENT for token in tokens), source_path
        tree = ast.parse(source)
        documented_nodes = (
            ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef
        )
        assert all(
            ast.get_docstring(node, clean=False) is None
            for node in ast.walk(tree)
            if isinstance(node, documented_nodes)
        ), source_path
    for sql_path in [*SQL.glob("*.sql"), *ROOT.glob("tests/*.sql")]:
        source = read(sql_path)
        assert "--" not in source and "/*" not in source, sql_path
    for script_path in [*ROOT.glob("*.ps1"), *ROOT.glob("*.cmd")]:
        source = read(script_path)
        assert not re.search(r"(?im)^\s*(?:#|REM\b|::)", source), script_path
    assert (ROOT / "README.txt").is_file()
    assert (ROOT / "README_START_HERE.txt").is_file()
    assert not list(ROOT.glob("README*.md"))

    assert body.rstrip().endswith("SHOW ERRORS PACKAGE BODY quiz_platform")
    assert spec.rstrip().endswith("SHOW ERRORS PACKAGE quiz_platform")
    print("PASS: Python sources parse successfully.")
    print("PASS: exact 23-table schema, 20 demo questions and seven types are present.")
    print(
        f"PASS: all {len(spec_procs)} public package signatures match their bodies."
    )
    print(f"PASS: Python calls {len(called_procedures)} known package procedures only.")
    print("PASS: installer and three SQL verification scenarios are structurally complete.")
    print("PASS: code comments are absent and README files use TXT format.")


if __name__ == "__main__":
    main()
