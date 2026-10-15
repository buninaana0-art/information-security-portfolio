\
\
\
\
\


from __future__ import annotations

from io import BytesIO
import json
import mimetypes
import os
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk
from typing import Any, Callable

from dotenv import load_dotenv
from PIL import Image, ImageTk

from db import QuizDB, QuizError


APP_DIR = Path(__file__).resolve().parent
load_dotenv(APP_DIR / ".env")

BG = "#0f1117"
PANEL = "#171a23"
CARD = "#20242f"
ENTRY = "#292e3b"
TEXT = "#f4f4f5"
MUTED = "#a6adbb"
ACCENT = "#ff4b55"
ACCENT_ACTIVE = "#ff6871"
SUCCESS = "#43c59e"
WARNING = "#f4b942"


def format_number(value: Any, digits: int = 2) -> str:
    if value is None:
        return "—"
    number = float(value)
    if number.is_integer():
        return str(int(number))
    return f"{number:.{digits}f}"


class ScrollFrame(tk.Frame):
    def __init__(self, master: tk.Misc, *, background: str = BG) -> None:
        super().__init__(master, bg=background)
        self.canvas = tk.Canvas(
            self, bg=background, highlightthickness=0, borderwidth=0
        )
        scrollbar = ttk.Scrollbar(self, orient="vertical", command=self.canvas.yview)
        self.inner = tk.Frame(self.canvas, bg=background)
        self.window_id = self.canvas.create_window(
            (0, 0), window=self.inner, anchor="nw"
        )
        self.canvas.configure(yscrollcommand=scrollbar.set)
        self.canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")
        self.inner.bind("<Configure>", self._sync_scrollregion)
        self.canvas.bind("<Configure>", self._sync_width)
        self.canvas.bind_all("<MouseWheel>", self._mousewheel)

    def _sync_scrollregion(self, _event: tk.Event[Any]) -> None:
        self.canvas.configure(scrollregion=self.canvas.bbox("all"))

    def _sync_width(self, event: tk.Event[Any]) -> None:
        self.canvas.itemconfigure(self.window_id, width=event.width)

    def _mousewheel(self, event: tk.Event[Any]) -> None:
        if self.winfo_exists() and self.winfo_viewable():
            self.canvas.yview_scroll(int(-event.delta / 120), "units")


class OracleQuizArena(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Oracle Quiz Arena")
        self.geometry("1160x760")
        self.minsize(960, 640)
        self.configure(bg=BG)
        self.protocol("WM_DELETE_WINDOW", self.close_application)

        self.db: QuizDB | None = None
        self.auth: dict[str, Any] | None = None
        self.session_token: str | None = None
        self.active_attempt_id: int | None = None
        self.current_payload: dict[str, Any] | None = None
        self.response_getter: Callable[[], dict[str, Any]] | None = None
        self.image_refs: list[ImageTk.PhotoImage] = []
        self.content: tk.Frame | None = None
        self.server_refresh_job: str | None = None

        self._configure_styles()
        self.show_login()

    def _configure_styles(self) -> None:
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure("TFrame", background=BG)
        style.configure("TLabel", background=BG, foreground=TEXT, font=("Segoe UI", 10))
        style.configure(
            "Title.TLabel", background=BG, foreground=TEXT,
            font=("Segoe UI Semibold", 25)
        )
        style.configure(
            "Heading.TLabel", background=BG, foreground=TEXT,
            font=("Segoe UI Semibold", 18)
        )
        style.configure(
            "Muted.TLabel", background=BG, foreground=MUTED,
            font=("Segoe UI", 10)
        )
        style.configure(
            "TEntry", fieldbackground=ENTRY, foreground=TEXT,
            insertcolor=TEXT, bordercolor="#3c4353", padding=8
        )
        style.configure(
            "TCombobox", fieldbackground=ENTRY, foreground=TEXT,
            background=ENTRY, arrowcolor=TEXT, padding=6
        )
        style.map(
            "TCombobox",
            fieldbackground=[("readonly", ENTRY)],
            foreground=[("readonly", TEXT)],
        )
        style.configure(
            "TButton", background="#303646", foreground=TEXT,
            padding=(12, 8), borderwidth=0, font=("Segoe UI Semibold", 10)
        )
        style.map("TButton", background=[("active", "#3d4558")])
        style.configure(
            "Accent.TButton", background=ACCENT, foreground="white",
            padding=(15, 9), font=("Segoe UI Semibold", 10)
        )
        style.map("Accent.TButton", background=[("active", ACCENT_ACTIVE)])
        style.configure(
            "Nav.TButton", background=PANEL, foreground=TEXT,
            anchor="w", padding=(16, 10), borderwidth=0
        )
        style.map("Nav.TButton", background=[("active", CARD)])
        style.configure(
            "Treeview", background=CARD, fieldbackground=CARD,
            foreground=TEXT, rowheight=30, borderwidth=0
        )
        style.configure(
            "Treeview.Heading", background="#303646", foreground=TEXT,
            font=("Segoe UI Semibold", 9), borderwidth=0
        )
        style.map("Treeview", background=[("selected", ACCENT)])
        style.configure("TNotebook", background=BG, borderwidth=0)
        style.configure(
            "TNotebook.Tab", background=CARD, foreground=TEXT, padding=(18, 8)
        )
        style.map("TNotebook.Tab", background=[("selected", ACCENT)])

    def _cancel_server_refresh(self) -> None:
        job = self.server_refresh_job
        self.server_refresh_job = None
        if job is not None:
            try:
                self.after_cancel(job)
            except tk.TclError:
                pass

    def _reset_window(self) -> None:
        self._cancel_server_refresh()
        self.image_refs.clear()
        for child in self.winfo_children():
            child.destroy()

    def _clear_content(self) -> tk.Frame:
        self._cancel_server_refresh()
        self.image_refs.clear()
        if self.content is None:
            raise RuntimeError("Main content is not initialized")
        for child in self.content.winfo_children():
            child.destroy()
        return self.content

    def _title(self, parent: tk.Misc, text: str, subtitle: str | None = None) -> None:
        ttk.Label(parent, text=text, style="Heading.TLabel").pack(anchor="w")
        if subtitle:
            ttk.Label(parent, text=subtitle, style="Muted.TLabel").pack(
                anchor="w", pady=(4, 18)
            )
        else:
            tk.Frame(parent, height=12, bg=BG).pack()

    def _show_error(self, exc: BaseException) -> None:
        messagebox.showerror("Oracle Quiz Arena", str(exc), parent=self)


    def show_login(self) -> None:
        self._reset_window()
        outer = tk.Frame(self, bg=BG)
        outer.pack(fill="both", expand=True)
        card = tk.Frame(
            outer, bg=PANEL, highlightthickness=1,
            highlightbackground="#333949", padx=38, pady=34
        )
        card.place(relx=0.5, rely=0.5, anchor="center", width=510)

        tk.Label(
            card, text="Oracle Quiz Arena", bg=PANEL, fg=TEXT,
            font=("Segoe UI Semibold", 27)
        ).pack(anchor="w")
        tk.Label(
            card,
            text="Войдите по логину и паролю игрока",
            bg=PANEL, fg=MUTED, font=("Segoe UI", 10)
        ).pack(anchor="w", pady=(4, 24))

        self.login_user = tk.StringVar(
            value=os.getenv("ORACLE_DEMO_USER", "QUIZ_STUDENT")
        )
        self.login_password = tk.StringVar()
        self.login_host = tk.StringVar(value=os.getenv("ORACLE_HOST", "127.0.0.1"))
        self.login_port = tk.StringVar(value=os.getenv("ORACLE_PORT", "1521"))
        self.login_database = tk.StringVar(
            value=os.getenv("ORACLE_DATABASE", "FREEPDB1")
        )
        self.login_mode = tk.StringVar(value=os.getenv("ORACLE_CONNECT_MODE", "SERVICE"))

        for label, variable, secret in [
            ("Логин игрока", self.login_user, False),
            ("Пароль игрока", self.login_password, True),
            ("Хост Oracle", self.login_host, False),
            ("Порт", self.login_port, False),
            ("SID / Service name", self.login_database, False),
        ]:
            tk.Label(
                card, text=label, bg=PANEL, fg=TEXT,
                font=("Segoe UI Semibold", 10)
            ).pack(anchor="w", pady=(0, 6))
            entry = ttk.Entry(card, textvariable=variable, show="•" if secret else "")
            entry.pack(fill="x", pady=(0, 16))
            if secret:
                self.password_entry = entry

        mode_row = tk.Frame(card, bg=PANEL)
        mode_row.pack(anchor="w", pady=(0, 12))
        for value, label in (("SERVICE", "Service name"), ("SID", "SID")):
            tk.Radiobutton(
                mode_row, text=label, value=value, variable=self.login_mode,
                bg=PANEL, fg=TEXT, selectcolor=ENTRY,
                activebackground=PANEL, activeforeground=TEXT,
            ).pack(side="left", padx=(0, 16))

        ttk.Button(
            card, text="Войти в игру", style="Accent.TButton",
            command=self._login_from_form
        ).pack(fill="x", pady=(4, 8))
        ttk.Button(
            card, text="Зарегистрироваться",
            command=self._register_from_form,
        ).pack(fill="x", pady=(0, 12))
        tk.Label(
            card, text="Создайте аккаунт через отдельную форму регистрации.",
            bg=PANEL, fg=MUTED, font=("Segoe UI", 9),
        ).pack(anchor="w", pady=(0, 10))
        tk.Label(
            card,
            text=(
                "Локально: QUIZ_STUDENT / Student123!\n"
                "QUIZ_AUTHOR / Author123! · QUIZ_ADMIN / Admin123!"
            ),
            bg=PANEL, fg=MUTED, justify="left", font=("Segoe UI", 9)
        ).pack(anchor="w")
        self.bind("<Return>", lambda _event: self._login_from_form())
        self.password_entry.focus_set()

    def _login_from_form(self) -> None:
        try:
            self.authenticate(
                self.login_user.get(), self.login_password.get(), self._form_dsn()
            )
        except Exception as exc:
            self._show_error(exc)

    def _form_dsn(self) -> str:
        return QuizDB.make_dsn(
            self.login_host.get(), self.login_port.get(),
            self.login_database.get(), self.login_mode.get(),
        )

    def _register_from_form(self) -> None:
        window, body = self._make_dialog("Регистрация профиля", 440)
        tk.Label(
            body,
            text="Создайте игровой логин и пароль. Email нужен только при регистрации.",
            bg=BG, fg=MUTED, wraplength=390, justify="left",
        ).pack(anchor="w", pady=(0, 12))
        username = tk.StringVar()
        display_name = tk.StringVar()
        email = tk.StringVar()
        password = tk.StringVar()
        password_repeat = tk.StringVar()
        role = tk.StringVar(value="PARTICIPANT")
        for label, variable, secret in (
            ("Логин игрока", username, False),
            ("Имя в игре", display_name, False),
            ("Email", email, False),
            ("Пароль", password, True),
            ("Повторите пароль", password_repeat, True),
        ):
            ttk.Label(body, text=label).pack(anchor="w", pady=(4, 4))
            ttk.Entry(
                body, textvariable=variable, show="•" if secret else "",
            ).pack(fill="x", pady=(0, 10))

        ttk.Label(body, text="Роль в игре").pack(anchor="w", pady=(4, 4))
        role_row = tk.Frame(body, bg=BG)
        role_row.pack(anchor="w", pady=(0, 10))
        for value, label in (("PARTICIPANT", "Участник"), ("AUTHOR", "Автор")):
            tk.Radiobutton(
                role_row, text=label, value=value, variable=role,
                bg=BG, fg=TEXT, selectcolor=ENTRY,
                activebackground=BG, activeforeground=TEXT,
            ).pack(side="left", padx=(0, 20))

        def register() -> None:
            try:
                self.register_player(
                    username.get(), password.get(), password_repeat.get(),
                    self._form_dsn(), display_name.get(), email.get(), role.get(),
                )
                if window.winfo_exists():
                    window.destroy()
            except Exception as exc:
                self._show_error(exc)

        ttk.Button(
            body, text="Зарегистрироваться", style="Accent.TButton",
            command=register,
        ).pack(anchor="e", pady=(10, 0))

    def register_player(
        self, username: str, password: str, password_repeat: str, dsn: str,
        display_name: str, email: str, role: str,
    ) -> None:
        candidate = QuizDB(
            user=os.environ["ORACLE_USER"],
            password=os.environ["ORACLE_PASSWORD"],
            dsn=dsn,
            schema=os.getenv("ORACLE_SCHEMA", "QUIZ_APP"),
            pool_min=1, pool_max=3,
        )
        try:
            candidate.register(
                display_name, email, password, password_repeat, username, role,
            )
        finally:
            candidate.close()
        self.authenticate(username, password, dsn)

    def authenticate(self, username: str, password: str, dsn: str) -> None:
        self.configure(cursor="watch")
        self.update_idletasks()
        candidate: QuizDB | None = None
        try:
            candidate = QuizDB(
                user=os.environ["ORACLE_USER"],
                password=os.environ["ORACLE_PASSWORD"], dsn=dsn,
                schema=os.getenv("ORACLE_SCHEMA", "QUIZ_APP"),
                pool_min=1, pool_max=3,
            )
            result = candidate.login(username, password, "Oracle Quiz Arena desktop")
            self.db = candidate
            self.session_token = result.token
            self.auth = {
                "user_id": result.user_id,
                "display_name": result.display_name,
                "role": result.role,
                "game_username": username,
            }
            self._build_main_shell()
            self.show_catalog()
        except Exception:
            if candidate is not None:
                try:
                    candidate.close()
                except Exception:
                    pass
            raise
        finally:
            self.configure(cursor="")

    def _build_main_shell(self) -> None:
        self.unbind("<Return>")
        self._reset_window()
        sidebar = tk.Frame(self, bg=PANEL, width=235, padx=18, pady=24)
        sidebar.pack(side="left", fill="y")
        sidebar.pack_propagate(False)
        self.content = tk.Frame(self, bg=BG, padx=28, pady=24)
        self.content.pack(side="right", fill="both", expand=True)

        tk.Label(
            sidebar, text="Oracle Quiz Arena", bg=PANEL, fg=TEXT,
            font=("Segoe UI Semibold", 17)
        ).pack(anchor="w")
        tk.Label(
            sidebar, text=str(self.auth["display_name"]), bg=PANEL, fg=TEXT,
            font=("Segoe UI Semibold", 11)
        ).pack(anchor="w", pady=(28, 2))
        tk.Label(
            sidebar,
            text=f"{self.auth['role']}\nЛогин: {self.auth['game_username']}",
            bg=PANEL, fg=MUTED, justify="left", font=("Segoe UI", 9)
        ).pack(anchor="w", pady=(0, 24))

        navigation = [
            ("Каталог", self.show_catalog),
            ("Мои результаты", self.show_attempts),
            ("Рейтинги", self.show_leaderboard),
            ("Достижения и команды", self.show_achievements),
        ]
        if self.auth["role"] in {"AUTHOR", "ADMIN"}:
            navigation.append(("Конструктор", self.show_authoring))
        for label, command in navigation:
            ttk.Button(sidebar, text=label, style="Nav.TButton", command=command).pack(
                fill="x", pady=3
            )
        ttk.Button(sidebar, text="Выйти", command=self.logout).pack(
            side="bottom", fill="x"
        )


    def show_catalog(self) -> None:
        parent = self._clear_content()
        self.active_attempt_id = None
        self._title(
            parent, "Каталог тестов",
            "Oracle выбирает вопросы, контролирует время и проверяет ответы."
        )
        try:
            tests = self.db.list_tests(self.session_token)
            teams = self.db.list_teams(self.session_token)
        except Exception as exc:
            self._show_error(exc)
            return
        if not tests:
            ttk.Label(parent, text="Доступных тестов пока нет.").pack(anchor="w")
            return

        scroll = ScrollFrame(parent)
        scroll.pack(fill="both", expand=True)
        team_map = {
            f"{row['team_name']} (#{int(row['team_id'])})": int(row["team_id"])
            for row in teams
        }
        for test in tests:
            card = tk.Frame(
                scroll.inner, bg=CARD, padx=20, pady=16,
                highlightthickness=1, highlightbackground="#343a49"
            )
            card.pack(fill="x", pady=(0, 12), padx=(0, 8))
            top = tk.Frame(card, bg=CARD)
            top.pack(fill="x")
            tk.Label(
                top, text=str(test["test_title"]), bg=CARD, fg=TEXT,
                font=("Segoe UI Semibold", 15)
            ).pack(side="left", anchor="w")
            tk.Label(
                top,
                text=f"Средний результат: {format_number(test.get('average_percent'), 1)}%",
                bg=CARD, fg=MUTED, font=("Segoe UI", 9)
            ).pack(side="right")
            tk.Label(
                card, text=str(test.get("description") or "Без описания"),
                bg=CARD, fg=TEXT, justify="left", wraplength=730,
                font=("Segoe UI", 10)
            ).pack(anchor="w", pady=(8, 6))
            flags = [str(test["category_name"])]
            if test.get("topics"):
                flags.append(str(test["topics"]))
            if test.get("adaptive_flag") == "Y":
                flags.append("адаптивный")
            if test.get("team_mode_flag") == "Y":
                flags.append("командный")
            tk.Label(
                card,
                text=" · ".join(flags) + f" · попыток: {int(test.get('my_attempts') or 0)}",
                bg=CARD, fg=MUTED, font=("Segoe UI", 9)
            ).pack(anchor="w", pady=(0, 10))

            controls = tk.Frame(card, bg=CARD)
            controls.pack(fill="x")
            team_var: tk.StringVar | None = None
            if test.get("team_mode_flag") == "Y":
                if team_map:
                    team_var = tk.StringVar(value=next(iter(team_map)))
                    ttk.Combobox(
                        controls, textvariable=team_var,
                        values=list(team_map), state="readonly", width=30
                    ).pack(side="left")
                else:
                    tk.Label(
                        controls,
                        text="У вас нет команды; решение о старте примет Oracle.",
                        bg=CARD, fg=WARNING
                    ).pack(side="left")
            test_id = int(test["test_id"])
            active_attempt_id = test.get("active_attempt_id")
            ttk.Button(
                controls,
                text=str(test["action_text"]),
                style="Accent.TButton",
                command=lambda t=test_id, v=team_var, a=active_attempt_id: (
                    self.resume_test(int(a)) if a is not None
                    else self.start_test(t, team_map.get(v.get()) if v else None)
                ),
            ).pack(side="right")

    def start_test(self, test_id: int, team_id: int | None) -> None:
        try:
            self.active_attempt_id = self.db.start_attempt(
                self.session_token, test_id, team_id
            )
            self.show_game()
        except Exception as exc:
            self._show_error(exc)

    def resume_test(self, attempt_id: int) -> None:
        self.active_attempt_id = attempt_id
        self.show_game()


    def show_game(self) -> None:
        if self.active_attempt_id is None:
            self.show_catalog()
            return
        try:
            payload = self.db.get_next_question(
                self.session_token, self.active_attempt_id
            )
        except Exception as exc:
            self._show_error(exc)
            self.show_catalog()
            return
        self.current_payload = payload
        if payload.get("state") != "QUESTION":
            self.show_result(self.active_attempt_id)
            return
        self._render_question(payload)

    def _schedule_server_refresh(self, delay_ms: int = 1000) -> None:
        self._cancel_server_refresh()
        self.server_refresh_job = self.after(delay_ms, self._refresh_game_from_oracle)

    def _refresh_game_from_oracle(self) -> None:
        self.server_refresh_job = None
        attempt_id = self.active_attempt_id
        previous = self.current_payload
        if self.db is None or self.session_token is None or attempt_id is None:
            return
        try:
            payload = self.db.get_next_question(self.session_token, attempt_id)
        except Exception:
            self._schedule_server_refresh(2000)
            return

        if payload.get("state") != "QUESTION":
            self.current_payload = payload
            self.show_result(attempt_id)
            return

        question = payload.get("question")
        previous_question = previous.get("question") if previous else None
        if (
            question is None
            or previous_question is None
            or question.get("attempt_question_id")
            != previous_question.get("attempt_question_id")
        ):
            self.current_payload = payload
            self._render_question(payload)
            return

        self.current_payload = payload
        if self.timer_label.winfo_exists():
            self.timer_label.configure(text=str(question["timer_text"]))
        self._schedule_server_refresh()

    def _render_question(self, payload: dict[str, Any]) -> None:
        parent = self._clear_content()
        question = payload["question"]
        options = payload["options"]
        self._title(parent, "Прохождение теста")

        header = tk.Frame(parent, bg=BG)
        header.pack(fill="x")
        tk.Label(
            header,
            text=(
                f"Вопрос {int(question['sequence_no'])} из "
                f"{int(question['target_question_count'])} · "
                f"сложность {int(question['difficulty_level'])} · "
                f"{format_number(question['points'])} балл(а)"
            ),
            bg=BG, fg=MUTED, font=("Segoe UI", 10)
        ).pack(side="left")
        self.timer_label = tk.Label(
            header, text=str(question["timer_text"]), bg=BG, fg=WARNING,
            font=("Segoe UI Semibold", 11)
        )
        self.timer_label.pack(side="right")

        card = tk.Frame(
            parent, bg=CARD, padx=24, pady=20,
            highlightthickness=1, highlightbackground="#343a49"
        )
        card.pack(fill="both", expand=True, pady=(14, 12))
        tk.Label(
            card, text=str(question["question_text"]), bg=CARD, fg=TEXT,
            justify="left", wraplength=800,
            font=("Segoe UI Semibold", 15)
        ).pack(anchor="w", pady=(0, 14))
        if question.get("image_data"):
            self._image_label(card, question["image_data"], max_size=(700, 230))

        answer_frame = tk.Frame(card, bg=CARD)
        answer_frame.pack(fill="both", expand=True)
        self.response_getter = self._build_answer_widget(
            answer_frame, str(question["type_code"]), options
        )

        controls = tk.Frame(parent, bg=BG)
        controls.pack(fill="x")
        ttk.Button(
            controls, text="Завершить попытку", command=self.finish_attempt
        ).pack(side="left")
        ttk.Button(
            controls, text="Ответить", style="Accent.TButton",
            command=self.submit_current_answer
        ).pack(side="right")


        self._schedule_server_refresh()

    def _build_answer_widget(
        self, parent: tk.Frame, type_code: str, options: list[dict[str, Any]]
    ) -> Callable[[], dict[str, Any]]:
        labels = {int(row["option_id"]): str(row["option_text"]) for row in options}
        if type_code in {"SINGLE", "TRUE_FALSE"}:
            selected = tk.IntVar(value=-1)
            for option in options:
                option_id = int(option["option_id"])
                row = tk.Frame(parent, bg=CARD)
                row.pack(fill="x", pady=4)
                tk.Radiobutton(
                    row, text=labels[option_id], variable=selected, value=option_id,
                    bg=CARD, fg=TEXT, activebackground=CARD, activeforeground=TEXT,
                    selectcolor=ENTRY, anchor="w", justify="left",
                    font=("Segoe UI", 11), wraplength=760
                ).pack(side="left", fill="x", expand=True)
                self._option_image(row, option)
            return lambda: {"option_ids": [selected.get()]}

        if type_code == "MULTIPLE":
            variables: dict[int, tk.BooleanVar] = {}
            for option in options:
                option_id = int(option["option_id"])
                variables[option_id] = tk.BooleanVar(value=False)
                row = tk.Frame(parent, bg=CARD)
                row.pack(fill="x", pady=4)
                tk.Checkbutton(
                    row, text=labels[option_id], variable=variables[option_id],
                    bg=CARD, fg=TEXT, activebackground=CARD, activeforeground=TEXT,
                    selectcolor=ENTRY, anchor="w", justify="left",
                    font=("Segoe UI", 11), wraplength=760
                ).pack(side="left", fill="x", expand=True)
                self._option_image(row, option)
            return lambda: {
                "option_ids": [key for key, value in variables.items() if value.get()]
            }

        if type_code == "TEXT":
            value = tk.StringVar()
            ttk.Entry(parent, textvariable=value).pack(fill="x", pady=8)
            return lambda: {"text": value.get()}

        if type_code == "NUMBER":
            value = tk.StringVar()
            ttk.Entry(parent, textvariable=value).pack(fill="x", pady=8)
            return lambda: {"number": value.get()}

        if type_code == "ORDERING":
            display = {
                f"{labels[key]}  [#{key}]": key for key in labels
            }
            selected: list[tk.StringVar] = []
            for position in range(1, len(options) + 1):
                row = tk.Frame(parent, bg=CARD)
                row.pack(fill="x", pady=4)
                tk.Label(
                    row, text=f"Позиция {position}", bg=CARD, fg=MUTED,
                    width=12, anchor="w"
                ).pack(side="left")
                variable = tk.StringVar()
                selected.append(variable)
                ttk.Combobox(
                    row, textvariable=variable, values=list(display),
                    state="readonly"
                ).pack(side="left", fill="x", expand=True)
            return lambda: {
                "option_ids": [display.get(v.get()) for v in selected]
            }

        if type_code == "MATCHING":
            values: list[tuple[int, tk.StringVar]] = []
            for option in options:
                option_id = int(option["option_id"])
                row = tk.Frame(parent, bg=CARD)
                row.pack(fill="x", pady=5)
                tk.Label(
                    row, text=labels[option_id], bg=CARD, fg=TEXT,
                    width=30, anchor="w", justify="left", wraplength=280
                ).pack(side="left")
                variable = tk.StringVar()
                values.append((option_id, variable))
                ttk.Entry(row, textvariable=variable).pack(
                    side="left", fill="x", expand=True, padx=(12, 0)
                )
            return lambda: {
                "pairs": [
                    {"option_id": option_id, "answer": variable.get()}
                    for option_id, variable in values
                ]
            }

        raise QuizError(f"Интерфейс не знает тип вопроса {type_code}.")

    def _image_label(
        self, parent: tk.Misc, data: bytes, *, max_size: tuple[int, int]
    ) -> None:
        try:
            image = Image.open(BytesIO(data))
            image.thumbnail(max_size, Image.Resampling.LANCZOS)
            photo = ImageTk.PhotoImage(image)
            self.image_refs.append(photo)
            tk.Label(parent, image=photo, bg=CARD).pack(anchor="w", pady=(0, 10))
        except Exception:
            tk.Label(
                parent, text="[Изображение не удалось отобразить]",
                bg=CARD, fg=WARNING
            ).pack(anchor="w")

    def _option_image(self, parent: tk.Misc, option: dict[str, Any]) -> None:
        if not option.get("image_data"):
            return
        try:
            image = Image.open(BytesIO(option["image_data"]))
            image.thumbnail((120, 70), Image.Resampling.LANCZOS)
            photo = ImageTk.PhotoImage(image)
            self.image_refs.append(photo)
            tk.Label(parent, image=photo, bg=CARD).pack(side="right", padx=8)
        except Exception:
            return

    def submit_current_answer(self) -> None:
        if not self.current_payload or not self.response_getter:
            return
        self._cancel_server_refresh()
        try:
            question = self.current_payload["question"]
            response = self.response_getter()
            result = self.db.submit_answer(
                self.session_token,
                self.active_attempt_id,
                int(question["question_id"]),
                json.dumps(response, ensure_ascii=False),
            )
            if result.get("message"):
                messagebox.showinfo(
                    "Результат ответа", str(result["message"]), parent=self
                )
            self.show_game()
        except Exception as exc:
            self._show_error(exc)
            self.show_game()

    def finish_attempt(self) -> None:
        self._cancel_server_refresh()
        if not messagebox.askyesno(
            "Завершить попытку", "Завершить тест досрочно?", parent=self
        ):
            self._schedule_server_refresh()
            return
        try:
            self.db.finish_attempt(self.session_token, self.active_attempt_id)
            self.show_result(self.active_attempt_id)
        except Exception as exc:
            self._show_error(exc)
            self._schedule_server_refresh()


    def show_result(self, attempt_id: int) -> None:
        parent = self._clear_content()
        self.active_attempt_id = attempt_id
        try:
            result = self.db.get_attempt_result(self.session_token, attempt_id)
            feedback = self.db.get_attempt_feedback(self.session_token, attempt_id)
        except Exception as exc:
            self._show_error(exc)
            return
        if not result:
            self._title(parent, "Результат не найден")
            return
        self._title(parent, str(result["test_title"]), "Результат попытки")
        metrics = tk.Frame(parent, bg=BG)
        metrics.pack(fill="x", pady=(0, 16))
        values = [
            ("Баллы", f"{format_number(result['score'])} / {format_number(result['max_score'])}"),
            ("Результат", f"{format_number(result['percent_score'])}%"),
            ("Правильные", f"{int(result['correct_count'])} / {int(result['target_question_count'])}"),
            ("Статус", str(result["attempt_status"])),
        ]
        for label, value in values:
            box = tk.Frame(metrics, bg=CARD, padx=14, pady=12)
            box.pack(side="left", fill="x", expand=True, padx=(0, 10))
            tk.Label(box, text=label, bg=CARD, fg=MUTED).pack(anchor="w")
            tk.Label(
                box, text=value, bg=CARD, fg=TEXT,
                font=("Segoe UI Semibold", 13)
            ).pack(anchor="w")

        outcome_colors = {"SUCCESS": SUCCESS, "WARNING": WARNING}
        tk.Label(
            parent,
            text=str(result["outcome_text"]),
            bg=BG, fg=outcome_colors.get(str(result["outcome_style"]), WARNING),
            font=("Segoe UI Semibold", 12)
        ).pack(anchor="w", pady=(0, 12))

        if feedback:
            tree = ttk.Treeview(
                parent, columns=("no", "result", "points", "question"),
                show="headings", height=12
            )
            for key, title, width in [
                ("no", "№", 45), ("result", "Ответ", 80),
                ("points", "Баллы", 90), ("question", "Вопрос", 590),
            ]:
                tree.heading(key, text=title)
                tree.column(key, width=width, anchor="w")
            for row in feedback:
                tree.insert(
                    "", "end",
                    values=(
                        int(row["sequence_no"]),
                        str(row["answer_result_text"]),
                        f"{format_number(row['points_awarded'])} / {format_number(row['max_points'])}",
                        str(row["question_text"]),
                    ),
                )
            tree.pack(fill="both", expand=True)

        controls = tk.Frame(parent, bg=BG)
        controls.pack(fill="x", pady=(14, 0))
        ttk.Button(controls, text="К каталогу", command=self.show_catalog).pack(side="left")
        if result.get("certificate_no"):
            ttk.Button(
                controls, text="Сохранить PDF-сертификат",
                style="Accent.TButton",
                command=lambda: self.save_certificate(attempt_id)
            ).pack(side="right")

    def save_certificate(self, attempt_id: int) -> None:
        try:
            file_name, _mime_type, data = self.db.get_certificate(
                self.session_token, attempt_id
            )
            path = filedialog.asksaveasfilename(
                parent=self, initialfile=file_name,
                defaultextension=".pdf", filetypes=[("PDF", "*.pdf")]
            )
            if path:
                Path(path).write_bytes(data)
                messagebox.showinfo("Сертификат", "PDF сохранён.", parent=self)
        except Exception as exc:
            self._show_error(exc)

    def show_attempts(self) -> None:
        parent = self._clear_content()
        self._title(parent, "Мои результаты", "Двойной щелчок открывает попытку.")
        try:
            attempts = self.db.get_my_attempts(self.session_token)
            comparison = self.db.get_comparison(self.session_token)
        except Exception as exc:
            self._show_error(exc)
            return
        tree = ttk.Treeview(
            parent, columns=("test", "status", "score", "date"),
            show="headings", height=10
        )
        for key, title, width in [
            ("test", "Тест", 460), ("status", "Статус", 130),
            ("score", "Результат", 110), ("date", "Начало", 170),
        ]:
            tree.heading(key, text=title)
            tree.column(key, width=width, anchor="w")
        for row in attempts:
            tree.insert(
                "", "end", iid=str(int(row["attempt_id"])),
                values=(
                    row["test_title"], row["attempt_status"],
                    f"{format_number(row['percent_score'])}%", row.get("started_at") or "",
                ),
            )
        tree.pack(fill="both", expand=True)
        tree.bind(
            "<Double-1>",
            lambda _event: self.show_result(int(tree.selection()[0]))
            if tree.selection() else None,
        )
        if comparison:
            ttk.Label(parent, text="Сравнение со средним", style="Heading.TLabel").pack(
                anchor="w", pady=(18, 8)
            )
            compare = ttk.Treeview(
                parent, columns=("test", "mine", "average", "difference", "rank"),
                show="headings", height=5
            )
            for key, title, width in [
                ("test", "Тест", 360), ("mine", "Мой %", 85),
                ("average", "Средний %", 95), ("difference", "Разница", 85),
                ("rank", "Место", 80),
            ]:
                compare.heading(key, text=title)
                compare.column(key, width=width, anchor="w")
            for row in comparison:
                compare.insert(
                    "", "end",
                    values=(
                        row["test_title"], format_number(row.get("user_percent")),
                        format_number(row.get("test_average_percent")),
                        format_number(row.get("difference_from_average")),
                        row.get("test_rank") or "—",
                    ),
                )
            compare.pack(fill="x")


    def show_leaderboard(self) -> None:
        parent = self._clear_content()
        self._title(parent, "Рейтинги")
        controls = tk.Frame(parent, bg=BG)
        controls.pack(fill="x", pady=(0, 12))
        rating_type = tk.StringVar(value="USER")
        period = tk.StringVar(value="ALL")
        ttk.Combobox(
            controls, textvariable=rating_type, values=["USER", "TEAM"],
            state="readonly", width=16
        ).pack(side="left", padx=(0, 10))
        ttk.Combobox(
            controls, textvariable=period, values=["WEEK", "MONTH", "ALL"],
            state="readonly", width=16
        ).pack(side="left")
        table_holder = tk.Frame(parent, bg=BG)
        table_holder.pack(fill="both", expand=True)

        def load() -> None:
            for child in table_holder.winfo_children():
                child.destroy()
            try:
                rows = self.db.get_leaderboard(
                    self.session_token, rating_type.get(), period.get()
                )
            except Exception as exc:
                self._show_error(exc)
                return
            tree = ttk.Treeview(
                table_holder, columns=("rank", "name", "score", "attempts"),
                show="headings"
            )
            for key, title, width in [
                ("rank", "Место", 80), ("name", "Участник / команда", 480),
                ("score", "Баллы", 130), ("attempts", "Попытки", 100),
            ]:
                tree.heading(key, text=title)
                tree.column(key, width=width, anchor="w")
            for row in rows:
                name = ("★ " if row.get("is_mine") == "Y" else "") + str(row["subject_name"])
                tree.insert(
                    "", "end",
                    values=(
                        int(row["rank_no"]), name,
                        format_number(row["total_score"]),
                        int(row["completed_attempts"]),
                    ),
                )
            tree.pack(fill="both", expand=True)

        ttk.Button(controls, text="Обновить", command=load).pack(side="left", padx=10)
        load()

    def show_achievements(self) -> None:
        parent = self._clear_content()
        self._title(parent, "Достижения и команды")
        notebook = ttk.Notebook(parent)
        notebook.pack(fill="both", expand=True)
        badge_tab = tk.Frame(notebook, bg=BG, padx=12, pady=12)
        team_tab = tk.Frame(notebook, bg=BG, padx=12, pady=12)
        notebook.add(badge_tab, text="Бейджи")
        notebook.add(team_tab, text="Команды")
        try:
            badges = self.db.get_badges(self.session_token)
            teams = self.db.list_teams(self.session_token)
        except Exception as exc:
            self._show_error(exc)
            return
        if not badges:
            ttk.Label(badge_tab, text="Завершайте тесты, чтобы получить бейджи.").pack(anchor="w")
        for badge in badges:
            card = tk.Frame(badge_tab, bg=CARD, padx=16, pady=12)
            card.pack(fill="x", pady=(0, 8))
            tk.Label(
                card, text="🏅 " + str(badge["badge_name"]), bg=CARD, fg=TEXT,
                font=("Segoe UI Semibold", 12)
            ).pack(anchor="w")
            tk.Label(
                card, text=str(badge.get("description") or ""), bg=CARD, fg=MUTED
            ).pack(anchor="w")

        tree = ttk.Treeview(
            team_tab, columns=("team", "role", "members", "code"),
            show="headings", height=9
        )
        for key, title, width in [
            ("team", "Команда", 330), ("role", "Роль", 120),
            ("members", "Участники", 100), ("code", "Код", 130),
        ]:
            tree.heading(key, text=title)
            tree.column(key, width=width, anchor="w")
        for row in teams:
            tree.insert(
                "", "end",
                values=(
                    row["team_name"], row.get("member_role") or "",
                    row.get("member_count") or "", row.get("join_code") or "",
                ),
            )
        tree.pack(fill="x")
        forms = tk.Frame(team_tab, bg=BG)
        forms.pack(fill="x", pady=(16, 0))
        team_name = tk.StringVar()
        join_code = tk.StringVar()
        ttk.Entry(forms, textvariable=team_name).pack(side="left", fill="x", expand=True)
        ttk.Button(
            forms, text="Создать команду",
            command=lambda: self._create_team(team_name.get())
        ).pack(side="left", padx=(8, 20))
        ttk.Entry(forms, textvariable=join_code, width=18).pack(side="left")
        ttk.Button(
            forms, text="Вступить по коду",
            command=lambda: self._join_team(join_code.get())
        ).pack(side="left", padx=8)

    def _create_team(self, name: str) -> None:
        try:
            _team_id, code = self.db.create_team(self.session_token, name)
            messagebox.showinfo(
                "Команда создана", f"Код вступления: {code}", parent=self
            )
            self.show_achievements()
        except Exception as exc:
            self._show_error(exc)

    def _join_team(self, code: str) -> None:
        try:
            self.db.join_team(self.session_token, code)
            self.show_achievements()
        except Exception as exc:
            self._show_error(exc)


    def show_authoring(self) -> None:
        parent = self._clear_content()
        self._title(
            parent,
            "Конструктор тестов",
            "Форма передаёт данные процедурам Oracle; правила и проверки выполняет QUIZ_PLATFORM.",
        )
        toolbar = tk.Frame(parent, bg=BG)
        toolbar.pack(fill="x", pady=(0, 12))
        ttk.Button(toolbar, text="Новый тест", style="Accent.TButton",
                   command=self._create_test_dialog).pack(side="left")
        ttk.Button(toolbar, text="Новая категория",
                   command=lambda: self._named_entity_dialog("category")).pack(
            side="left", padx=8
        )
        ttk.Button(toolbar, text="Новая тематика",
                   command=lambda: self._named_entity_dialog("topic")).pack(side="left")

        body = tk.PanedWindow(parent, orient="horizontal", bg=BG, sashwidth=5)
        body.pack(fill="both", expand=True)
        test_panel = tk.Frame(body, bg=BG)
        editor_panel = tk.Frame(body, bg=BG, padx=14)
        body.add(test_panel, minsize=330)
        body.add(editor_panel, minsize=520)

        tree = ttk.Treeview(
            test_panel, columns=("title", "status", "questions"),
            show="headings", selectmode="browse"
        )
        for key, title, width in [
            ("title", "Тест", 190), ("status", "Статус", 80),
            ("questions", "Вопросы", 70),
        ]:
            tree.heading(key, text=title)
            tree.column(key, width=width, anchor="w")
        try:
            tests = self.db.list_author_tests(self.session_token)
        except Exception as exc:
            self._show_error(exc)
            return
        for row in tests:
            tree.insert(
                "", "end", iid=str(int(row["test_id"])),
                values=(row["test_title"], row["test_status"],
                        int(row.get("bank_question_count") or 0)),
            )
        tree.pack(fill="both", expand=True)

        def select_test(_event: tk.Event[Any] | None = None) -> None:
            selected = tree.selection()
            if selected:
                self._render_test_editor(editor_panel, int(selected[0]))

        tree.bind("<<TreeviewSelect>>", select_test)
        if tree.get_children():
            first = tree.get_children()[0]
            tree.selection_set(first)
            tree.focus(first)
            select_test()
        else:
            ttk.Label(editor_panel, text="Создайте первый тест.").pack(anchor="w")

    def _render_test_editor(self, parent: tk.Frame, test_id: int) -> None:
        for child in parent.winfo_children():
            child.destroy()
        try:
            tests = self.db.list_author_tests(self.session_token)
            test = next(row for row in tests if int(row["test_id"]) == test_id)
            questions = self.db.list_test_questions(self.session_token, test_id)
            access = self.db.list_test_access(self.session_token, test_id)
        except Exception as exc:
            self._show_error(exc)
            return

        tk.Label(
            parent, text=str(test["test_title"]), bg=BG, fg=TEXT,
            font=("Segoe UI Semibold", 16)
        ).pack(anchor="w")
        ttk.Label(
            parent,
            text=(f"{test['test_status']} · {test['access_mode']} · "
                  f"проходной балл {format_number(test['pass_percent'])}%"),
            style="Muted.TLabel",
        ).pack(anchor="w", pady=(2, 10))

        toolbar = tk.Frame(parent, bg=BG)
        toolbar.pack(fill="x", pady=(0, 10))
        ttk.Button(toolbar, text="Добавить вопрос",
                   command=lambda: self._question_dialog(test_id)).pack(side="left")
        ttk.Button(toolbar, text="Тематика",
                   command=lambda: self._attach_topic_dialog(test_id)).pack(
            side="left", padx=5
        )
        ttk.Button(toolbar, text="Правило выборки",
                   command=lambda: self._rule_dialog(test_id)).pack(side="left")
        ttk.Button(
            toolbar, text="Опубликовать", style="Accent.TButton",
            command=lambda: self._publish_test(test_id)
        ).pack(side="right")

        question_tree = ttk.Treeview(
            parent,
            columns=("order", "type", "text", "level", "options", "keys"),
            show="headings", selectmode="browse", height=10,
        )
        for key, title, width in [
            ("order", "№", 42), ("type", "Тип", 90),
            ("text", "Текст вопроса", 330), ("level", "Сложность", 82),
            ("options", "Варианты", 68), ("keys", "Ключи", 55),
        ]:
            question_tree.heading(key, text=title)
            question_tree.column(key, width=width, anchor="w")
        for row in questions:
            question_tree.insert(
                "", "end", iid=str(int(row["question_id"])),
                values=(
                    int(row["display_order"]), row["type_code"],
                    row["question_text"], int(row["difficulty_level"]),
                    int(row["option_count"]), int(row["key_count"]),
                ),
            )
        question_tree.pack(fill="both", expand=True)

        action_bar = tk.Frame(parent, bg=BG)
        action_bar.pack(fill="x", pady=(8, 14))

        def selected_question() -> int | None:
            selected = question_tree.selection()
            if not selected:
                messagebox.showinfo(
                    "Конструктор", "Сначала выберите вопрос.", parent=self
                )
                return None
            return int(selected[0])

        def with_question(callback: Callable[[int], None]) -> None:
            question_id = selected_question()
            if question_id is not None:
                callback(question_id)

        ttk.Button(
            action_bar, text="Вариант ответа",
            command=lambda: with_question(self._option_dialog)
        ).pack(side="left")
        ttk.Button(
            action_bar, text="Ключ ответа",
            command=lambda: with_question(self._key_dialog)
        ).pack(side="left", padx=6)
        ttk.Button(
            action_bar, text="Изображение вопроса",
            command=lambda: with_question(self._question_image_dialog)
        ).pack(side="left")

        acl = tk.Frame(parent, bg=CARD, padx=12, pady=10)
        acl.pack(fill="x")
        tk.Label(
            acl, text="Доступ игроков", bg=CARD, fg=TEXT,
            font=("Segoe UI Semibold", 10)
        ).pack(side="left")
        names = ", ".join(str(row["oracle_username"]) for row in access) or "список пуст"
        tk.Label(acl, text=names, bg=CARD, fg=MUTED, font=("Segoe UI", 9)).pack(
            side="left", padx=12
        )
        ttk.Button(acl, text="Выдать", command=lambda: self._change_access(test_id, True)).pack(
            side="right"
        )
        ttk.Button(acl, text="Отозвать", command=lambda: self._change_access(test_id, False)).pack(
            side="right", padx=6
        )

    def _make_dialog(self, title: str, width: int = 520) -> tuple[tk.Toplevel, tk.Frame]:
        window = tk.Toplevel(self)
        window.title(title)
        window.configure(bg=BG)
        window.resizable(False, False)
        window.transient(self)
        body = tk.Frame(window, bg=BG, padx=22, pady=20)
        body.pack(fill="both", expand=True)
        x = self.winfo_rootx() + max(20, (self.winfo_width() - width) // 2)
        y = self.winfo_rooty() + 80
        window.geometry(f"{width}x200+{x}+{y}")
        def fit_dialog() -> None:
            window.update_idletasks()
            height = min(max(window.winfo_reqheight(), 200), 700)
            window.geometry(f"{width}x{height}+{x}+{y}")
        window.after_idle(fit_dialog)
        window.grab_set()
        return window, body

    @staticmethod
    def _optional_value(value: str) -> str | None:
        value = value.strip()
        return value or None

    def _form_row(
        self, parent: tk.Misc, label: str, variable: tk.Variable,
        *, values: list[str] | None = None, row: int,
    ) -> ttk.Widget:
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w", pady=5)
        if values is None:
            widget: ttk.Widget = ttk.Entry(parent, textvariable=variable)
        else:
            widget = ttk.Combobox(
                parent, textvariable=variable, values=values, state="readonly"
            )
        widget.grid(row=row, column=1, sticky="ew", padx=(14, 0), pady=5)
        return widget

    def _create_test_dialog(self) -> None:
        try:
            categories = self.db.list_categories()
        except Exception as exc:
            self._show_error(exc)
            return
        category_map = {
            str(row["category_name"]): int(row["category_id"]) for row in categories
        }
        window, body = self._make_dialog("Новый тест", 570)
        body.columnconfigure(1, weight=1)
        title = tk.StringVar()
        category = tk.StringVar(value=next(iter(category_map), ""))
        access_mode = tk.StringVar(value="PUBLIC")
        time_limit = tk.StringVar(value="30")
        question_count = tk.StringVar(value="10")
        pass_percent = tk.StringVar(value="60")
        feedback_mode = tk.StringVar(value="IMMEDIATE")
        max_attempts = tk.StringVar()
        show_answers = tk.BooleanVar(value=True)
        adaptive = tk.BooleanVar()
        team_mode = tk.BooleanVar()
        self._form_row(body, "Название", title, row=0)
        self._form_row(body, "Категория", category,
                       values=list(category_map), row=1)
        self._form_row(body, "Доступ", access_mode,
                       values=["PUBLIC", "RESTRICTED"], row=2)
        self._form_row(body, "Минут на тест", time_limit, row=3)
        self._form_row(body, "Число вопросов", question_count, row=4)
        self._form_row(body, "Проходной процент", pass_percent, row=5)
        self._form_row(body, "Обратная связь", feedback_mode,
                       values=["IMMEDIATE", "AFTER_TEST", "NEVER"], row=6)
        self._form_row(body, "Максимум попыток", max_attempts, row=7)
        ttk.Label(body, text="Описание").grid(row=8, column=0, sticky="nw", pady=5)
        description = tk.Text(
            body, height=3, bg=ENTRY, fg=TEXT, insertbackground=TEXT,
            relief="flat", wrap="word"
        )
        description.grid(row=8, column=1, sticky="ew", padx=(14, 0), pady=5)
        checks = tk.Frame(body, bg=BG)
        checks.grid(row=9, column=0, columnspan=2, sticky="w", pady=8)
        for text, variable in [
            ("Показывать верные ответы", show_answers),
            ("Адаптивный", adaptive), ("Командный", team_mode),
        ]:
            tk.Checkbutton(
                checks, text=text, variable=variable, bg=BG, fg=TEXT,
                activebackground=BG, activeforeground=TEXT,
                selectcolor=ENTRY
            ).pack(side="left", padx=(0, 12))

        def save() -> None:
            try:
                self.db.create_test(
                    self.session_token,
                    {
                        "title": title.get().strip(),
                        "description": description.get("1.0", "end").strip() or None,
                        "category_id": category_map[category.get()],
                        "access_mode": access_mode.get(),
                        "time_limit_minutes": self._optional_value(time_limit.get()),
                        "question_count": self._optional_value(question_count.get()),
                        "pass_percent": pass_percent.get(),
                        "feedback_mode": feedback_mode.get(),
                        "show_correct_answers": "Y" if show_answers.get() else "N",
                        "adaptive_flag": "Y" if adaptive.get() else "N",
                        "team_mode_flag": "Y" if team_mode.get() else "N",
                        "max_attempts": self._optional_value(max_attempts.get()),
                    },
                )
                window.destroy()
                self.show_authoring()
            except Exception as exc:
                self._show_error(exc)

        ttk.Button(body, text="Создать", style="Accent.TButton", command=save).grid(
            row=10, column=1, sticky="e", pady=(12, 0)
        )

    def _question_dialog(self, test_id: int) -> None:
        try:
            categories = self.db.list_categories()
            types = self.db.list_question_types()
            existing = self.db.list_test_questions(self.session_token, test_id)
        except Exception as exc:
            self._show_error(exc)
            return
        category_map = {
            str(row["category_name"]): int(row["category_id"]) for row in categories
        }
        type_codes = [str(row["type_code"]) for row in types]
        window, body = self._make_dialog("Новый вопрос", 620)
        body.columnconfigure(1, weight=1)
        type_code = tk.StringVar(value=type_codes[0] if type_codes else "SINGLE")
        category = tk.StringVar(value=next(iter(category_map), ""))
        difficulty = tk.StringVar(value="1")
        display_order = tk.StringVar(value=str(len(existing) + 1))
        points = tk.StringVar(value="1")
        time_limit = tk.StringVar()
        adaptive = tk.BooleanVar()
        self._form_row(body, "Тип", type_code, values=type_codes, row=0)
        self._form_row(body, "Категория", category,
                       values=list(category_map), row=1)
        self._form_row(body, "Сложность 1–5", difficulty, row=2)
        self._form_row(body, "Порядок", display_order, row=3)
        self._form_row(body, "Баллы", points, row=4)
        self._form_row(body, "Лимит, секунд", time_limit, row=5)
        ttk.Label(body, text="Вопрос").grid(row=6, column=0, sticky="nw", pady=5)
        question_text = tk.Text(
            body, height=4, bg=ENTRY, fg=TEXT, insertbackground=TEXT,
            relief="flat", wrap="word"
        )
        question_text.grid(row=6, column=1, sticky="ew", padx=(14, 0), pady=5)
        ttk.Label(body, text="Пояснение").grid(row=7, column=0, sticky="nw", pady=5)
        explanation = tk.Text(
            body, height=3, bg=ENTRY, fg=TEXT, insertbackground=TEXT,
            relief="flat", wrap="word"
        )
        explanation.grid(row=7, column=1, sticky="ew", padx=(14, 0), pady=5)
        tk.Checkbutton(
            body, text="Использовать в адаптивном выборе", variable=adaptive,
            bg=BG, fg=TEXT, activebackground=BG, activeforeground=TEXT,
            selectcolor=ENTRY
        ).grid(row=8, column=1, sticky="w", pady=6)

        def save() -> None:
            try:
                self.db.add_question(
                    self.session_token,
                    {
                        "test_id": test_id, "type_code": type_code.get(),
                        "category_id": category_map[category.get()],
                        "question_text": question_text.get("1.0", "end").strip(),
                        "difficulty_level": difficulty.get(),
                        "display_order": display_order.get(),
                        "points": points.get(),
                        "time_limit_seconds": self._optional_value(time_limit.get()),
                        "adaptive_flag": "Y" if adaptive.get() else "N",
                        "explanation": explanation.get("1.0", "end").strip() or None,
                    },
                )
                window.destroy()
                self.show_authoring()
            except Exception as exc:
                self._show_error(exc)

        ttk.Button(body, text="Добавить", style="Accent.TButton", command=save).grid(
            row=9, column=1, sticky="e", pady=(12, 0)
        )

    def _option_dialog(self, question_id: int) -> None:
        window, body = self._make_dialog("Вариант ответа", 560)
        body.columnconfigure(1, weight=1)
        option_text = tk.StringVar()
        display_order = tk.StringVar(value="1")
        correct_order = tk.StringVar()
        match_key = tk.StringVar()
        is_correct = tk.BooleanVar()
        self._form_row(body, "Текст", option_text, row=0)
        self._form_row(body, "Порядок отображения", display_order, row=1)
        self._form_row(body, "Правильный порядок", correct_order, row=2)
        self._form_row(body, "Ключ соответствия", match_key, row=3)
        tk.Checkbutton(
            body, text="Правильный вариант", variable=is_correct, bg=BG, fg=TEXT,
            activebackground=BG, activeforeground=TEXT, selectcolor=ENTRY
        ).grid(row=4, column=1, sticky="w", pady=6)
        image_path = tk.StringVar()
        ttk.Entry(body, textvariable=image_path, state="readonly").grid(
            row=5, column=1, sticky="ew", padx=(14, 0), pady=5
        )
        ttk.Button(
            body, text="Выбрать изображение",
            command=lambda: image_path.set(filedialog.askopenfilename(
                parent=window, filetypes=[("Изображения", "*.png *.jpg *.jpeg *.gif *.webp")]
            ))
        ).grid(row=5, column=0, sticky="w", pady=5)

        def save() -> None:
            try:
                option_id = self.db.add_option(
                    self.session_token,
                    {
                        "question_id": question_id,
                        "option_text": option_text.get().strip() or None,
                        "is_correct": "Y" if is_correct.get() else "N",
                        "display_order": display_order.get(),
                        "correct_order": self._optional_value(correct_order.get()),
                        "match_key": match_key.get().strip() or None,
                    },
                )
                if image_path.get():
                    self._set_option_image(option_id, Path(image_path.get()))
                window.destroy()
                self.show_authoring()
            except Exception as exc:
                self._show_error(exc)

        ttk.Button(body, text="Добавить", style="Accent.TButton", command=save).grid(
            row=6, column=1, sticky="e", pady=(12, 0)
        )

    def _key_dialog(self, question_id: int) -> None:
        window, body = self._make_dialog("Ключ ответа", 540)
        body.columnconfigure(1, weight=1)
        key_type = tk.StringVar(value="TEXT")
        accepted_text = tk.StringVar()
        numeric_value = tk.StringVar()
        tolerance = tk.StringVar(value="0")
        case_sensitive = tk.BooleanVar()
        self._form_row(body, "Тип ключа", key_type,
                       values=["TEXT", "NUMBER"], row=0)
        self._form_row(body, "Допустимый текст", accepted_text, row=1)
        self._form_row(body, "Число", numeric_value, row=2)
        self._form_row(body, "Допуск", tolerance, row=3)
        tk.Checkbutton(
            body, text="Учитывать регистр", variable=case_sensitive,
            bg=BG, fg=TEXT, activebackground=BG, activeforeground=TEXT,
            selectcolor=ENTRY
        ).grid(row=4, column=1, sticky="w", pady=6)

        def save() -> None:
            try:
                self.db.add_key(
                    self.session_token,
                    {
                        "question_id": question_id, "key_type": key_type.get(),
                        "accepted_text": accepted_text.get().strip() or None,
                        "numeric_value": self._optional_value(numeric_value.get()),
                        "numeric_tolerance": self._optional_value(tolerance.get()),
                        "case_sensitive_flag": "Y" if case_sensitive.get() else "N",
                    },
                )
                window.destroy()
                self.show_authoring()
            except Exception as exc:
                self._show_error(exc)

        ttk.Button(body, text="Добавить", style="Accent.TButton", command=save).grid(
            row=5, column=1, sticky="e", pady=(12, 0)
        )

    def _rule_dialog(self, test_id: int) -> None:
        try:
            categories = self.db.list_categories()
        except Exception as exc:
            self._show_error(exc)
            return
        category_map = {"Любая": None} | {
            str(row["category_name"]): int(row["category_id"]) for row in categories
        }
        window, body = self._make_dialog("Правило выборки", 500)
        body.columnconfigure(1, weight=1)
        category = tk.StringVar(value="Любая")
        difficulty = tk.StringVar()
        count = tk.StringVar(value="1")
        self._form_row(body, "Категория", category,
                       values=list(category_map), row=0)
        self._form_row(body, "Сложность 1–5", difficulty, row=1)
        self._form_row(body, "Число вопросов", count, row=2)

        def save() -> None:
            try:
                self.db.add_rule(
                    self.session_token,
                    {"test_id": test_id, "category_id": category_map[category.get()],
                     "difficulty_level": self._optional_value(difficulty.get()),
                     "question_count": count.get()},
                )
                window.destroy()
                self.show_authoring()
            except Exception as exc:
                self._show_error(exc)

        ttk.Button(body, text="Добавить", style="Accent.TButton", command=save).grid(
            row=3, column=1, sticky="e", pady=(12, 0)
        )

    def _attach_topic_dialog(self, test_id: int) -> None:
        try:
            topics = self.db.list_topics(self.session_token)
        except Exception as exc:
            self._show_error(exc)
            return
        topic_map = {
            str(row["topic_name"]): int(row["topic_id"]) for row in topics
        }
        if not topic_map:
            messagebox.showinfo(
                "Тематика", "Сначала создайте тематику.", parent=self
            )
            return
        name = simpledialog.askstring(
            "Тематика", "Введите название тематики:\n" + ", ".join(topic_map),
            parent=self,
        )
        if not name:
            return
        if name not in topic_map:
            self._show_error(QuizError("Такой тематики нет в списке."))
            return
        try:
            self.db.add_test_topic(self.session_token, test_id, topic_map[name])
            self.show_authoring()
        except Exception as exc:
            self._show_error(exc)

    def _named_entity_dialog(self, entity: str) -> None:
        label = "категории" if entity == "category" else "тематики"
        title = "Новая категория" if entity == "category" else "Новая тематика"
        name = simpledialog.askstring(
            title, f"Название {label}:", parent=self
        )
        if not name:
            return
        description = simpledialog.askstring(
            title, "Описание (необязательно):", parent=self
        ) or ""
        try:
            if entity == "category":
                self.db.create_category(self.session_token, name, description)
            else:
                self.db.create_topic(self.session_token, name, description)
            self.show_authoring()
        except Exception as exc:
            self._show_error(exc)

    def _publish_test(self, test_id: int) -> None:
        try:
            self.db.publish_test(self.session_token, test_id)
            messagebox.showinfo("Конструктор", "Тест опубликован.", parent=self)
            self.show_authoring()
        except Exception as exc:
            self._show_error(exc)

    def _change_access(self, test_id: int, grant: bool) -> None:
        username = simpledialog.askstring(
            "Доступ игроков", "Логин игрока:", parent=self
        )
        if not username:
            return
        try:
            if grant:
                self.db.grant_access(self.session_token, test_id, username)
            else:
                self.db.revoke_access(self.session_token, test_id, username)
            self.show_authoring()
        except Exception as exc:
            self._show_error(exc)

    def _question_image_dialog(self, question_id: int) -> None:
        filename = filedialog.askopenfilename(
            parent=self,
            filetypes=[("Изображения", "*.png *.jpg *.jpeg *.gif *.webp")],
        )
        if not filename:
            return
        try:
            path = Path(filename)
            mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
            self.db.set_question_image(
                self.session_token, question_id, path.name, mime_type, path.read_bytes()
            )
            self.show_authoring()
        except Exception as exc:
            self._show_error(exc)

    def _set_option_image(self, option_id: int, path: Path) -> None:
        mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.db.set_option_image(
            self.session_token, option_id, path.name, mime_type, path.read_bytes()
        )


    def logout(self) -> None:
        if self.db and self.session_token:
            try:
                self.db.logout(self.session_token)
            except Exception:
                pass
            try:
                self.db.close()
            except Exception:
                pass
        self.db = None
        self.auth = None
        self.session_token = None
        self.active_attempt_id = None
        self.show_login()

    def close_application(self) -> None:
        if self.db:
            try:
                if self.session_token:
                    self.db.logout(self.session_token)
            except Exception:
                pass
            try:
                self.db.close()
            except Exception:
                pass
        self.destroy()


def main() -> None:
    app = OracleQuizArena()
    app.mainloop()


if __name__ == "__main__":
    main()
