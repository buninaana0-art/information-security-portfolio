

from __future__ import annotations

from pathlib import Path
import sys
import os
import tkinter as tk
from tkinter import ttk
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from desktop_app import OracleQuizArena
from db import QuizDB, QuizError


def verify_connection_forms() -> None:
    service = QuizDB.make_dsn("db.example.edu", "1521", "UNIPDB", "SERVICE")
    sid = QuizDB.make_dsn("db.example.edu", "1521", "ORCL", "SID")
    assert "(HOST=db.example.edu)" in service
    assert "(SERVICE_NAME=UNIPDB)" in service
    assert "(SID=ORCL)" in sid
    try:
        QuizDB.make_dsn("db.example.edu", "invalid", "ORCL", "SID")
    except QuizError:
        pass
    else:
        raise AssertionError("Invalid Oracle port was accepted")

    app = OracleQuizArena()
    app.withdraw()
    try:
        app.login_host.set("db.example.edu")
        app.login_database.set("ORCL")
        app.login_mode.set("SID")
        assert "(SID=ORCL)" in app._form_dsn()
        app._register_from_form()
        dialogs = [child for child in app.winfo_children() if isinstance(child, tk.Toplevel)]
        assert len(dialogs) == 1
        fields = [
            child for container in dialogs[0].winfo_children()
            for child in container.winfo_children()
            if isinstance(child, ttk.Entry)
        ]
        assert len(fields) == 5
        assert fields[3].cget("show") and fields[4].cget("show")
        roles = [
            radio for container in dialogs[0].winfo_children()
            for child in container.winfo_children()
            if isinstance(child, tk.Frame)
            for radio in child.winfo_children()
            if isinstance(radio, tk.Radiobutton)
        ]
        assert {radio.cget("value") for radio in roles} == {"PARTICIPANT", "AUTHOR"}
        next(radio for radio in roles if radio.cget("value") == "AUTHOR").invoke()
        for field, value in zip(
            fields,
            ("NEW_PLAYER", "New Student", "new@example.edu",
             "player-password", "player-password"),
            strict=True,
        ):
            field.insert(0, value)
        submitted = []
        original_register_player = app.register_player
        app.register_player = lambda *args: submitted.append(args)
        buttons = [
            child for container in dialogs[0].winfo_children()
            for child in container.winfo_children()
            if isinstance(child, ttk.Button)
        ]
        buttons[0].invoke()
        assert submitted == [(
            "NEW_PLAYER", "player-password", "player-password", sid,
            "New Student", "new@example.edu", "AUTHOR",
        )]
        app.register_player = original_register_player

        class RegistrationDB:
            def __init__(self, **kwargs):
                assert kwargs["user"] == "QUIZ_APP"
                assert kwargs["dsn"] == sid

            def register(self, name, email, password, repeat, game_username, role):
                assert (name, email, password, repeat, game_username, role) == (
                    "New Student", "new@example.edu", "player-password",
                    "player-password", "NEW_PLAYER", "AUTHOR",
                )

            def close(self):
                pass

        called = []
        app.authenticate = lambda *args: called.append(args)
        with patch.dict(os.environ, {"ORACLE_USER": "QUIZ_APP", "ORACLE_PASSWORD": "db-password"}),\
             patch("desktop_app.QuizDB", RegistrationDB):
            app.register_player(
                "NEW_PLAYER", "player-password", "player-password", sid,
                "New Student", "new@example.edu", "AUTHOR",
            )
        assert called == [("NEW_PLAYER", "player-password", sid)]
    finally:
        app.destroy()


class TimerSnapshotDB:
    def get_next_question(self, _token: str, _attempt_id: int) -> dict:
        return {
            "state": "QUESTION",
            "question": {
                "attempt_question_id": 77,
                "timer_text": "Oracle timer snapshot: 9",
            },
            "options": [],
        }


def verify_server_timer_rendering() -> None:
    app = OracleQuizArena()
    app.withdraw()
    try:
        app.db = TimerSnapshotDB()
        app.session_token = "test-token"
        app.active_attempt_id = 55
        app.current_payload = {
            "state": "QUESTION",
            "question": {
                "attempt_question_id": 77,
                "timer_text": "Oracle timer snapshot: 10",
            },
            "options": [],
        }
        app.timer_label = tk.Label(app)
        scheduled: list[int] = []
        app._schedule_server_refresh = lambda delay_ms=1000: scheduled.append(delay_ms)
        app._refresh_game_from_oracle()
        assert app.timer_label.cget("text") == "Oracle timer snapshot: 9"
        assert scheduled == [1000]
    finally:
        app.db = None
        app.destroy()


def main() -> None:
    app = OracleQuizArena()
    app.withdraw()
    try:
        app.update_idletasks()
        assert app.title() == "Oracle Quiz Arena"
        app.authenticate(
            "QUIZ_STUDENT",
            "Student123!",
            "127.0.0.1:1521/FREEPDB1",
        )
        app.update_idletasks()
        assert app.auth is not None
        assert app.auth["game_username"] == "QUIZ_STUDENT"
        assert app.auth["role"] == "PARTICIPANT"
        assert app.content is not None
        assert app.content.winfo_children()
        app.logout()
        app.authenticate(
            "QUIZ_AUTHOR",
            "Author123!",
            "127.0.0.1:1521/FREEPDB1",
        )
        app.show_authoring()
        app.update_idletasks()
        assert app.auth is not None
        assert app.auth["role"] == "AUTHOR"
        assert app.content is not None
        assert app.content.winfo_children()
    finally:
        app.close_application()
    print(
        "PASS: native Tkinter renders catalog and constructor with shared Oracle login."
    )


if __name__ == "__main__":
    main()
