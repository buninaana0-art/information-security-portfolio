\
\
\
\
\


from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from decimal import Decimal
import re
from typing import Any, Iterator

import oracledb


class QuizError(RuntimeError):
    pass


def _friendly_error(exc: BaseException) -> QuizError:
    if isinstance(exc, oracledb.DatabaseError) and exc.args:
        detail = exc.args[0]
        code = getattr(detail, "code", None)
        friendly = {
            1017: "Неверное имя пользователя или пароль Oracle.",
            12154: "Oracle не смог разрешить строку подключения.",
            12514: "Listener Oracle не знает указанный сервис.",
            12541: "Listener Oracle недоступен по указанному адресу.",
            28000: "Учетная запись Oracle заблокирована.",
            28001: "Срок действия пароля Oracle истек.",
        }
        if code in friendly:
            return QuizError(friendly[code])
        message = getattr(detail, "message", str(detail)).strip()
        if message.startswith("ORA-20") and ": " in message:
            message = message.split(": ", 1)[1]
            message = message.split("\nORA-", 1)[0]
        return QuizError(message)
    return QuizError(str(exc))


def _identifier(value: str) -> str:
    identifier = value.strip().upper()
    if not re.fullmatch(r"[A-Z][A-Z0-9_$#]{0,127}", identifier):
        raise QuizError("Некорректное имя схемы Oracle.")
    return identifier


def _value(value: Any) -> Any:
    if isinstance(value, oracledb.LOB):
        return value.read()
    if isinstance(value, Decimal):
        return float(value)
    return value


def _rows(ref_cursor: oracledb.Cursor) -> list[dict[str, Any]]:
    try:
        columns = [item[0].lower() for item in ref_cursor.description or []]
        return [
            {name: _value(value) for name, value in zip(columns, row, strict=True)}
            for row in ref_cursor
        ]
    finally:
        ref_cursor.close()


@dataclass(frozen=True)
class LoginResult:
    token: str
    user_id: int
    display_name: str
    role: str


class QuizDB:
    @staticmethod
    def make_dsn(host: str, port: str, database: str, mode: str) -> str:

        host = host.strip()
        database = database.strip()
        if not host or not database:
            raise QuizError("Укажите хост и SID или имя сервиса Oracle.")
        try:
            port_number = int(port.strip())
        except ValueError as exc:
            raise QuizError("Порт Oracle должен быть числом.") from exc
        if not 1 <= port_number <= 65535:
            raise QuizError("Порт Oracle должен быть от 1 до 65535.")
        if mode == "SID":
            return oracledb.makedsn(host, port_number, sid=database)
        if mode == "SERVICE":
            return oracledb.makedsn(host, port_number, service_name=database)
        raise QuizError("Выберите SID или Service name.")

    def __init__(
        self,
        *,
        user: str,
        password: str,
        dsn: str,
        schema: str = "QUIZ_APP",
        pool_min: int = 1,
        pool_max: int = 5,
    ) -> None:
        self.schema = _identifier(schema)
        try:
            self.pool = oracledb.create_pool(
                user=user,
                password=password,
                dsn=dsn,
                min=pool_min,
                max=pool_max,
                increment=1,
                getmode=oracledb.POOL_GETMODE_WAIT,
            )
        except Exception as exc:
            raise _friendly_error(exc) from exc

    @contextmanager
    def _connection(self) -> Iterator[oracledb.Connection]:
        connection: oracledb.Connection | None = None
        try:
            connection = self.pool.acquire()
            with connection.cursor() as cursor:
                cursor.execute(f"ALTER SESSION SET CURRENT_SCHEMA = {self.schema}")
            yield connection
            connection.commit()
        except Exception as exc:
            if connection is not None:
                try:
                    connection.rollback()
                except Exception:
                    pass
            raise _friendly_error(exc) from exc
        finally:
            if connection is not None:
                connection.close()

    def close(self) -> None:
        self.pool.close(force=True)

    @staticmethod
    def _clob_var(cursor: oracledb.Cursor) -> oracledb.Var:
        return cursor.var(oracledb.DB_TYPE_CLOB)

    def _fetch(self, procedure: str, args: list[Any]) -> list[dict[str, Any]]:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                out_cursor = connection.cursor()
                try:
                    cursor.callproc(procedure, [*args, out_cursor])
                    return _rows(out_cursor)
                finally:
                    try:
                        out_cursor.close()
                    except oracledb.Error:
                        pass


    def register(
        self,
        display_name: str,
        email: str,
        password: str,
        password_repeat: str,
        game_username: str,
        user_role: str,
    ) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                user_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.register_user",
                    [display_name, email, password, password_repeat,
                     game_username, user_role, user_id],
                )
                return int(user_id.getvalue())

    def login(self, game_username: str, password: str, client_label: str) -> LoginResult:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                token = cursor.var(str, size=64)
                user_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                display_name = cursor.var(str, size=100)
                role = cursor.var(str, size=20)
                cursor.callproc(
                    "quiz_platform.login",
                    [
                        game_username,
                        password,
                        client_label,
                        token,
                        user_id,
                        display_name,
                        role,
                    ],
                )
                return LoginResult(
                    token=str(token.getvalue()),
                    user_id=int(user_id.getvalue()),
                    display_name=str(display_name.getvalue()),
                    role=str(role.getvalue()),
                )

    def logout(self, token: str) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                cursor.callproc("quiz_platform.logout", [token])


    def list_tests(self, token: str) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_tests", [token])

    def list_categories(self) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_categories", [])

    def list_question_types(self) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_question_types", [])

    def list_topics(self, token: str) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_topics", [token])

    def list_author_tests(self, token: str) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_author_tests", [token])

    def list_test_questions(self, token: str, test_id: int) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_test_questions", [token, test_id])

    def list_test_access(self, token: str, test_id: int) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_test_access", [token, test_id])

    def get_my_attempts(self, token: str) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.get_my_attempts", [token])

    def get_attempt_result(self, token: str, attempt_id: int) -> dict[str, Any] | None:
        rows = self._fetch("quiz_platform.get_attempt_result", [token, attempt_id])
        return rows[0] if rows else None

    def get_attempt_feedback(self, token: str, attempt_id: int) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.get_attempt_feedback", [token, attempt_id])

    def get_statistics(self, token: str, test_id: int) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.show_statistics", [token, test_id])

    def get_comparison(self, token: str) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.get_user_comparison", [token])

    def get_leaderboard(
        self, token: str, rating_type: str, period_code: str
    ) -> list[dict[str, Any]]:
        return self._fetch(
            "quiz_platform.get_leaderboard", [token, rating_type, period_code]
        )

    def get_badges(self, token: str) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.get_my_badges", [token])

    def list_teams(self, token: str) -> list[dict[str, Any]]:
        return self._fetch("quiz_platform.list_teams", [token])


    def start_attempt(self, token: str, test_id: int, team_id: int | None) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                attempt_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.start_attempt",
                    [token, test_id, team_id, attempt_id],
                )
                return int(attempt_id.getvalue())

    def get_next_question(self, token: str, attempt_id: int) -> dict[str, Any]:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                state = cursor.var(str, size=20)
                seconds = cursor.var(oracledb.DB_TYPE_NUMBER)
                question_cur = connection.cursor()
                options_cur = connection.cursor()
                try:
                    cursor.callproc(
                        "quiz_platform.get_next_question",
                        [token, attempt_id, state, seconds, question_cur, options_cur],
                    )
                    questions = _rows(question_cur)
                    options = _rows(options_cur)
                finally:
                    for ref_cursor in (question_cur, options_cur):
                        try:
                            ref_cursor.close()
                        except oracledb.Error:
                            pass
                return {
                    "state": state.getvalue(),
                    "question": questions[0] if questions else None,
                    "options": options,
                }

    def submit_answer(
        self,
        token: str,
        attempt_id: int,
        question_id: int,
        response_json: str,
    ) -> dict[str, Any]:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                response_lob = cursor.var(oracledb.DB_TYPE_CLOB)
                response_lob.setvalue(0, response_json)
                visible_ok = cursor.var(str, size=1)
                visible_points = cursor.var(oracledb.DB_TYPE_NUMBER)
                feedback = self._clob_var(cursor)
                correct = self._clob_var(cursor)
                message = self._clob_var(cursor)
                state = cursor.var(str, size=20)
                cursor.callproc(
                    "quiz_platform.submit_answer",
                    [
                        token,
                        attempt_id,
                        question_id,
                        response_lob,
                        visible_ok,
                        visible_points,
                        feedback,
                        correct,
                        message,
                        state,
                    ],
                )
                return {
                    "message": _value(message.getvalue()),
                    "state": state.getvalue(),
                }

    def finish_attempt(self, token: str, attempt_id: int) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                cursor.callproc("quiz_platform.finish_attempt", [token, attempt_id])

    def get_certificate(self, token: str, attempt_id: int) -> tuple[str, str, bytes]:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                file_name = cursor.var(str, size=255)
                mime_type = cursor.var(str, size=100)
                pdf_data = cursor.var(oracledb.DB_TYPE_BLOB)
                cursor.callproc(
                    "quiz_platform.get_certificate",
                    [token, attempt_id, file_name, mime_type, pdf_data],
                )
                return (
                    str(file_name.getvalue()),
                    str(mime_type.getvalue()),
                    bytes(_value(pdf_data.getvalue())),
                )


    def create_category(self, token: str, name: str, description: str) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                category_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.create_category",
                    [token, name, description or None, category_id],
                )
                return int(category_id.getvalue())

    def create_topic(self, token: str, name: str, description: str) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                topic_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.create_topic",
                    [token, name, description or None, topic_id],
                )
                return int(topic_id.getvalue())

    def create_test(self, token: str, data: dict[str, Any]) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                test_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.create_test",
                    [
                        token,
                        data["title"],
                        data.get("description"),
                        data["category_id"],
                        data["access_mode"],
                        data.get("time_limit_minutes"),
                        data.get("question_count"),
                        data["pass_percent"],
                        data["feedback_mode"],
                        data["show_correct_answers"],
                        data["adaptive_flag"],
                        data["team_mode_flag"],
                        data.get("max_attempts"),
                        test_id,
                    ],
                )
                return int(test_id.getvalue())

    def add_test_topic(self, token: str, test_id: int, topic_id: int) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                cursor.callproc(
                    "quiz_platform.add_test_topic", [token, test_id, topic_id]
                )

    def add_question(self, token: str, data: dict[str, Any]) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                question_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.add_question",
                    [
                        token,
                        data["test_id"],
                        data["type_code"],
                        data["category_id"],
                        data["question_text"],
                        data["difficulty_level"],
                        data["display_order"],
                        data["points"],
                        data.get("time_limit_seconds"),
                        data["adaptive_flag"],
                        data.get("explanation"),
                        question_id,
                    ],
                )
                return int(question_id.getvalue())

    def add_option(self, token: str, data: dict[str, Any]) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                option_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.add_answer_option",
                    [
                        token,
                        data["question_id"],
                        data["option_text"],
                        data["is_correct"],
                        data["display_order"],
                        data.get("correct_order"),
                        data.get("match_key"),
                        option_id,
                    ],
                )
                return int(option_id.getvalue())

    def add_key(self, token: str, data: dict[str, Any]) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                key_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.add_question_key",
                    [
                        token,
                        data["question_id"],
                        data["key_type"],
                        data.get("accepted_text"),
                        data.get("numeric_value"),
                        data.get("numeric_tolerance", 0),
                        data.get("case_sensitive_flag", "N"),
                        key_id,
                    ],
                )
                return int(key_id.getvalue())

    def add_rule(self, token: str, data: dict[str, Any]) -> int:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                rule_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                cursor.callproc(
                    "quiz_platform.add_generation_rule",
                    [
                        token,
                        data["test_id"],
                        data.get("category_id"),
                        data.get("difficulty_level"),
                        data["question_count"],
                        rule_id,
                    ],
                )
                return int(rule_id.getvalue())

    def set_question_image(
        self,
        token: str,
        question_id: int,
        file_name: str,
        mime_type: str,
        image_data: bytes,
    ) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                blob = cursor.var(oracledb.DB_TYPE_BLOB)
                blob.setvalue(0, image_data)
                cursor.callproc(
                    "quiz_platform.set_question_image",
                    [token, question_id, file_name, mime_type, blob],
                )

    def set_option_image(
        self,
        token: str,
        option_id: int,
        file_name: str,
        mime_type: str,
        image_data: bytes,
    ) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                blob = cursor.var(oracledb.DB_TYPE_BLOB)
                blob.setvalue(0, image_data)
                cursor.callproc(
                    "quiz_platform.set_option_image",
                    [token, option_id, file_name, mime_type, blob],
                )

    def publish_test(self, token: str, test_id: int) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                cursor.callproc("quiz_platform.publish_test", [token, test_id])

    def grant_access(self, token: str, test_id: int, game_username: str) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                cursor.callproc(
                    "quiz_platform.grant_test_access",
                    [token, test_id, game_username],
                )

    def revoke_access(self, token: str, test_id: int, game_username: str) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                cursor.callproc(
                    "quiz_platform.revoke_test_access",
                    [token, test_id, game_username],
                )


    def create_team(self, token: str, team_name: str) -> tuple[int, str]:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                team_id = cursor.var(oracledb.DB_TYPE_NUMBER)
                join_code = cursor.var(str, size=20)
                cursor.callproc(
                    "quiz_platform.create_team",
                    [token, team_name, team_id, join_code],
                )
                return int(team_id.getvalue()), str(join_code.getvalue())

    def join_team(self, token: str, join_code: str) -> None:
        with self._connection() as connection:
            with connection.cursor() as cursor:
                cursor.callproc("quiz_platform.join_team", [token, join_code])
