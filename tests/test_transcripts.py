"""What people see, at 40, 80 and 120 columns, rich and plain, with long and Unicode values.

Each view runs once per width and mode against a sandbox HOME, with stdout and stderr captured apart:
in rich mode each stream has its own pty, so neither is merged into the other. A captured run is
replayed through a small terminal, so a transcript is what stays on the screen.

Goldens in tests/golden/ are the replay with no line wrap, normalized and reviewed by hand. To rewrite
them after an intended change: TRANSCRIPTS_UPDATE=1 python3 -m unittest tests/test_transcripts.py

KNOWN_WIDTH_FAILURES lists cases that break a rule today, in code outside this test: the assertions
stay as the rule states them, and the comparison is exact, so a new failure and a fixed one both go
red, and a fix has to remove its entry. It is a temporary list, not a waiver of the rule. A line long
only because of a path is not one of them: that token is asserted whole instead.
"""

import fcntl
import json
import os
import re
import select
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

REPO = Path(__file__).resolve().parent.parent
GOLDEN = REPO / "tests" / "golden"
ENGINE = REPO / "bin" / "session-search.py"
TAGGER = REPO / "scripts" / "session-index-tag.py"
WIDTHS = (40, 80, 120)
MODES = ("rich", "plain")
GOLDEN_VIEWS = ("table", "preview", "tagger", "installer")
VIEWS = GOLDEN_VIEWS + ("stats", "analytics")

UNICODE_ID = "3f2b8c1e-9a47-4d6b-8e21-7c5a9f0d1e34"
LONG_ID = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
QUERY = "zephyr"

ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
PATH_TOKEN = re.compile(r"(?<!\S)[!-~]*/[!-~]*(?!\S)")


# Temporary: plan line 1076 puts the fix in the code, and a follow-up unit empties this. Each entry is
# check, view, widths, modes, and where the cause is. "fit": every line fits the width, a path in it
# not counting (R211, R212). "box": rows of one box are one width. "frame": no spinner frame stays on
# the screen.
_WIDTH_FAILURE_SITES: tuple[
    tuple[str, str, tuple[int, ...], tuple[str, ...], str], ...
] = (
    (
        "fit",
        "table",
        (40, 80),
        MODES,
        "bin/session-search.py:281 counts CJK as one column",
    ),
    (
        "fit",
        "preview",
        WIDTHS,
        MODES,
        "bin/session-search.py:2613 neither wraps nor shortens",
    ),
    ("fit", "stats", (40,), MODES, "bin/session-search.py:2738 fixed width of 52"),
    (
        "fit",
        "analytics",
        (40,),
        MODES,
        "bin/session-search.py:281 counts CJK as one column",
    ),
    (
        "fit",
        "tagger",
        (40,),
        MODES,
        "scripts/session-index-tag.py:696 banner, :512 bars, :767 summary",
    ),
    (
        "fit",
        "tagger",
        (80,),
        MODES,
        "scripts/session-index-tag.py:855 one 82-column line",
    ),
    (
        "fit",
        "installer",
        (40,),
        MODES,
        "scripts/lib/progress-ui.sh:179 box; install.sh:171 rows, :561, :582",
    ),
    (
        "box",
        "tagger",
        WIDTHS,
        MODES,
        "scripts/session-index-tag.py:709 banner row 2 wider than its border",
    ),
    (
        "frame",
        "installer",
        (40,),
        ("rich",),
        "install.sh:171 a wrapped row; `\\r` and erase-line cannot clear it",
    ),
)
KNOWN_WIDTH_FAILURES = {
    (check, view, width, mode)
    for check, view, widths, modes, _site in _WIDTH_FAILURE_SITES
    for width in widths
    for mode in modes
}


def known(check: str) -> set[tuple[str, int, str]]:
    return {case[1:] for case in KNOWN_WIDTH_FAILURES if case[0] == check}


@dataclass
class Run:
    code: int
    stdout: str
    stderr: str


def display_width(text: str) -> int:
    width = 0
    for char in text:
        if unicodedata.combining(char) or unicodedata.category(char) in (
            "Cf",
            "Mn",
            "Me",
        ):
            continue
        width += 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
    return width


def replay(raw: str, width: int) -> list[str]:
    """What a terminal of this width holds at the end, with its soft-wrapped rows joined again.

    A redraw counts the rows it wrapped, so the replay has to wrap too. Joining them keeps a golden
    from depending on how long this checkout's path is. A frame a redraw could not clear joins the
    line that follows it, and that is visible in the result.
    """
    rows: list[list[str]] = [[]]
    soft: set[int] = set()
    row = col = 0

    def line() -> list[str]:
        while len(rows) <= row:
            rows.append([])
        return rows[row]

    pos = 0
    while pos < len(raw):
        match = ESCAPE.match(raw, pos)
        if match:
            pos = match.end()
            seq = match.group()
            if not seq.startswith("\x1b["):
                continue
            final, params = seq[-1], seq[2:-1]
            count = int(params) if params.isdigit() else 1
            if final == "A":
                row = max(0, row - count)
            elif final == "B":
                row += count
            elif final == "C":
                col += count
            elif final == "D":
                col = max(0, col - count)
            elif final == "K":
                del line()[col:]
            elif final == "J":
                del line()[col:]
                del rows[row + 1 :]
                soft = {index for index in soft if index <= row}
            continue
        char = raw[pos]
        pos += 1
        if char == "\r":
            col = 0
        elif char == "\n":
            row += 1
            line()
            soft.discard(row)
        elif char == "\b":
            col = max(0, col - 1)
        elif char >= " ":
            cells = display_width(char)
            if col + cells > width:
                row += 1
                col = 0
                soft.add(row)
            cur = line()
            cur.extend(" " * (col + cells - len(cur)))
            cur[col] = char
            for extra in range(1, cells):
                cur[col + extra] = ""
            col += cells
    lines: list[str] = []
    for index, cells in enumerate(rows):
        if index in soft and lines:
            lines[-1] += "".join(cells)
        else:
            lines.append("".join(cells))
    return [text.rstrip() for text in lines]


def capture(
    argv: list[str], env: dict[str, str], width: int, mode: str, cwd: Path
) -> Run:
    env = {**env, "COLUMNS": str(width)}
    if mode == "plain":
        done = subprocess.run(
            argv,
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=300,
        )
        return Run(
            done.returncode,
            done.stdout.decode("utf-8", "replace"),
            done.stderr.decode("utf-8", "replace"),
        )

    masters, slaves = [], []
    for _ in range(2):
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, width, 0, 0))
        masters.append(master)
        slaves.append(slave)
    proc = subprocess.Popen(
        argv,
        env=env,
        cwd=cwd,
        stdin=slaves[0],
        stdout=slaves[0],
        stderr=slaves[1],
        start_new_session=True,
    )
    for slave in slaves:
        os.close(slave)
    chunks: dict[int, list[bytes]] = {fd: [] for fd in masters}
    open_fds, deadline = list(masters), time.time() + 300
    while open_fds and time.time() < deadline:
        ready, _, _ = select.select(open_fds, [], [], 0.1)
        for fd in ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b""
            if data:
                chunks[fd].append(data)
            else:
                open_fds.remove(fd)
    if open_fds:
        proc.kill()
    code = proc.wait()
    for fd in masters:
        os.close(fd)
    out, err = (b"".join(chunks[fd]).decode("utf-8", "replace") for fd in masters)
    return Run(code, out, err)


def normalize(text: str, home: Path) -> str:
    text = text.replace(str(home), "<HOME>").replace(str(REPO), "<REPO>")
    text = re.sub(r"settings\.json\.bak\.\w+", "settings.json.bak.<X>", text)
    text = re.sub(f"[{SPINNER}]", "*", text)
    # A duration, and the padding that makes room for its digits.
    text = re.sub(r"~?(?<!\()\b\d+(?:\.\d+)?(?:ms|s)\b", "<t>", text)
    out = []
    for row in text.split("\n"):
        if "<t>" in row:
            row = re.sub(r" {2,}", "  ", row)
        # What pip has installed differs by machine; these lines are optional and fixed in the source.
        if row.startswith("    pip install ") or row.strip() == "Optional:":
            continue
        out.append(row)
    return "\n".join(out)


class Sandbox:
    """A base HOME with the demo DB and the long and Unicode rows, plus a fast copy of the installer."""

    def __init__(self) -> None:
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix="css-transcripts.")))
        self.base = self.root / "base"
        claude = self.base / ".claude"
        claude.mkdir(parents=True)
        db = claude / "session-index.db"
        subprocess.run(
            [sys.executable, str(REPO / "assets/demo/build_demo_db.py"), str(db)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        self._seed(db)
        (claude / "bin").mkdir()
        (claude / "hooks" / "lib").mkdir(parents=True)
        (claude / "settings.json").write_text(
            json.dumps({"model": "opus", "hooks": {}}), encoding="utf-8"
        )
        (self.base / "Library" / "LaunchAgents").mkdir(parents=True)
        (self.base / ".zshrc").write_text("export EDITOR=vi\n", encoding="utf-8")

        self.path = self._tools()
        self.repo = self._fast_repo()
        self.env = {
            "HOME": str(self.base),
            "PATH": self.path,
            "TERM": "xterm-256color",
            "PYTHONUTF8": "1",
            "STUB_UNAME": "Darwin",
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def close(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def fresh_home(self, name: str) -> Path:
        home = self.root / name
        shutil.copytree(self.base, home, symlinks=True)
        return home

    @staticmethod
    def _seed(db: Path) -> None:
        conn = sqlite3.connect(db)
        conn.row_factory = sqlite3.Row
        template = dict(conn.execute("SELECT * FROM sessions LIMIT 1").fetchone())
        rows = {
            UNICODE_ID: {
                "project_name": "プロジェクト-zephyr",
                "project_path": "/Users/dev/code/プロジェクト-zephyr",
                "git_branch": "feature/ünï-cödé-zephyr",
                "summary": "日本語のセッション zephyr 名前が長い値でも折り返されることを確認する: café déjà vu 🚀",
                "first_prompt": "zephyr の表示を 40 桁で確認する 🚀",
                "tags": "",
                "tagged_at": None,
                "keywords": "zephyr",
            },
            LONG_ID: {
                "project_name": "a-project-name-that-goes-on-and-on-and-on-zephyr-service",
                "project_path": "/Users/dev/code/a/deeply/nested/path/that/goes/on/and/on/a-project-name-zephyr-service",
                "git_branch": "feature/a-branch-name-that-is-much-longer-than-any-column-could-hold-zephyr",
                "summary": "A long zephyr summary that goes on well past any width a terminal column could give it, so it has to wrap or shorten and never run into the next column of the row",
                "first_prompt": "Please fix the zephyr parser bug that fails on long inputs, and keep every session ID intact",
                "tags": "migration, database, deployment, observability, performance",
                "keywords": "zephyr",
            },
        }
        for sid, fields in rows.items():
            row = {**template, **fields, "session_id": sid}
            names = ", ".join(row)
            marks = ", ".join("?" for _ in row)
            conn.execute(
                f"INSERT INTO sessions ({names}) VALUES ({marks})", list(row.values())
            )
            conn.execute(
                "INSERT INTO sessions_fts (session_id, summary, first_prompt, tags, keywords, project_name)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                [
                    sid,
                    row["summary"],
                    row["first_prompt"],
                    row["tags"],
                    row["keywords"],
                    row["project_name"],
                ],
            )
            encoded = str(row["project_path"]).replace("/", "-")
            transcript = db.parent / "projects" / encoded / f"{sid}.jsonl"
            transcript.parent.mkdir(parents=True, exist_ok=True)
            messages = [
                row["first_prompt"],
                f"{row['summary']} {row['summary']}",
                "zephyr 短いメッセージ",
            ]
            transcript.write_text(
                "".join(
                    json.dumps({"type": "user", "message": {"content": text}}) + "\n"
                    for text in messages
                ),
                encoding="utf-8",
            )
        for query in (
            "zephyr",
            "a very long search query that goes on and on and on past the width",
            "日本語の検索",
        ):
            conn.execute(
                "INSERT INTO search_log (query, result_count, pipeline_ms, created_at)"
                " VALUES (?, 2, 3, '2026-01-02 03:04:05')",
                [query],
            )
        conn.commit()
        conn.close()

    def _tools(self) -> str:
        stubs = self.root / "stubs"
        tools = self.root / "tools"
        stubs.mkdir()
        tools.mkdir()
        for name in ("python3", "jq", "sqlite3", "awk"):
            found = shutil.which(name)
            if found is None:
                raise RuntimeError(f"{name} not found")
            (tools / name).symlink_to(found)
        # launchctl acts on the user's domain, not on HOME. fzf: a stub, so its hint stays out.
        for name, body in (
            ("launchctl", ""),
            ("fzf", ""),
            (
                "uname",
                'case "${1:-}" in "" | -s) echo "$STUB_UNAME"; exit 0 ;; esac\nPATH=/usr/bin:/bin exec uname "$@"\n',
            ),
        ):
            stub = stubs / name
            stub.write_text(f"#!/bin/bash\n{body}", encoding="utf-8")
            stub.chmod(0o755)
        return f"{stubs}:{tools}:/usr/bin:/bin"

    def _fast_repo(self) -> Path:
        fast = self.root / "repo"
        (fast / "scripts").mkdir(parents=True)
        for name in ("install.sh", "VERSION"):
            shutil.copy2(REPO / name, fast / name)
        for name in ("hooks", "bin", "config"):
            shutil.copytree(REPO / name, fast / name)
        shutil.copytree(REPO / "scripts" / "lib", fast / "scripts" / "lib")
        shutil.copy2(REPO / "scripts" / "session-index-chunk.py", fast / "scripts")
        backfill = fast / "scripts" / "session-index-backfill.sh"
        backfill.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        backfill.chmod(0o755)
        (fast / "scripts" / "session-index-tag.py").write_text(
            "import sys\nsys.exit(0)\n", encoding="utf-8"
        )
        return fast


class Transcripts(unittest.TestCase):
    sandbox: Sandbox
    runs: dict[tuple[str, int, str], Run]
    homes: dict[tuple[str, int, str], Path]

    @classmethod
    def setUpClass(cls) -> None:
        cls.sandbox = Sandbox()
        cls.addClassCleanup(cls.sandbox.close)
        cls.runs, cls.homes = {}, {}
        for view in VIEWS:
            for width in WIDTHS:
                for mode in MODES:
                    cls.runs[(view, width, mode)] = cls._run_view(view, width, mode)

    @classmethod
    def _run_view(cls, view: str, width: int, mode: str) -> Run:
        box = cls.sandbox
        python = sys.executable
        commands = {
            "table": [python, str(ENGINE), "--no-log", QUERY],
            "preview": [python, str(ENGINE), "--preview", UNICODE_ID],
            "stats": [python, str(ENGINE), "--stats"],
            "analytics": [python, str(ENGINE), "--analytics"],
            "tagger": [python, str(TAGGER), "--regex-only", "--limit", "3"],
            "installer": [str(box.repo / "install.sh")],
        }
        home = box.fresh_home(f"{view}-{width}-{mode}")
        cls.homes[(view, width, mode)] = home
        if view == "tagger":
            conn = sqlite3.connect(home / ".claude" / "session-index.db")
            conn.execute("UPDATE sessions SET tags = '', tagged_at = NULL")
            conn.commit()
            conn.close()
        return capture(
            commands[view], {**box.env, "HOME": str(home)}, width, mode, box.root
        )

    def screen(self, key: tuple[str, int, str], stream: str) -> list[str]:
        raw = getattr(self.runs[key], stream)
        return raw.split("\n") if key[2] == "plain" else replay(raw, key[1])

    def each(self, views: tuple[str, ...] = VIEWS) -> Iterator[tuple[str, int, str]]:
        for view in views:
            for width in WIDTHS:
                for mode in MODES:
                    yield (view, width, mode)

    def test_every_view_exits_0(self) -> None:
        for key in self.each():
            with self.subTest(key=key):
                run = self.runs[key]
                self.assertEqual(run.code, 0, run.stdout + run.stderr)

    def test_ids_and_paths_stay_whole(self) -> None:
        wanted = {
            "table": [UNICODE_ID[:8], LONG_ID[:8]],
            "preview": [UNICODE_ID[:8]],
        }
        for key in self.each(("table", "preview")):
            with self.subTest(key=key):
                rows = self.screen(key, "stdout")
                for token in wanted[key[0]]:
                    self.assertTrue(
                        any(
                            re.search(rf"(?<![0-9a-f]){token}(?![0-9a-f])", row)
                            for row in rows
                        ),
                        token,
                    )
        for key in self.each(("tagger",)):
            with self.subTest(key=key):
                self.assertTrue(
                    any(
                        f"{TAGGER} --regex-only" in row
                        for row in self.screen(key, "stderr")
                    )
                )
        for key in self.each(("installer",)):
            with self.subTest(key=key):
                rows = self.screen(key, "stdout")
                self.assertIn("    claude-search <QUERY>", rows)
                self.assertIn('    export PATH="$HOME/.claude/bin:$PATH"', rows)
                self.assertTrue(
                    any(
                        str(self.homes[key] / ".claude" / "settings.json.bak.") in row
                        for row in rows
                    )
                )

    def test_full_ids_in_tsv_and_dry_run_at_every_width(self) -> None:
        box = self.sandbox
        for width in WIDTHS:
            with self.subTest(width=width):
                done = capture(
                    [sys.executable, str(ENGINE), "--no-log", "--format=fzf", QUERY],
                    box.env,
                    width,
                    "plain",
                    box.root,
                )
                self.assertEqual(
                    {row.rsplit("\t", 1)[-1] for row in done.stdout.splitlines()},
                    {UNICODE_ID, LONG_ID},
                )
                done = capture(
                    [sys.executable, str(TAGGER), "--dry-run", "--limit", "20"],
                    box.env,
                    width,
                    "plain",
                    box.root,
                )
                self.assertEqual(done.code, 0, done.stderr)
                self.assertIn(
                    UNICODE_ID, {row.split("\t")[0] for row in done.stdout.splitlines()}
                )

    def _over_width(self, row: str, width: int) -> bool:
        # A path is never broken and the terminal soft-wraps it (R212), so it does not count, whatever
        # this checkout's path is. The words around it do.
        return display_width(PATH_TOKEN.sub("", row).rstrip()) > width

    def test_lines_fit_the_width(self) -> None:
        offending = set()
        detail = []
        for key in self.each():
            for stream in ("stdout", "stderr"):
                for row in self.screen(key, stream):
                    if self._over_width(row, key[1]):
                        offending.add(key)
                        detail.append(
                            f"{key} {stream} {display_width(row)}: {row[:70]}"
                        )
        self.assertEqual(offending, known("fit"), "\n".join(detail[:40]))

    def test_rows_of_a_box_are_one_width(self) -> None:
        offending = set()
        detail = []
        for key in self.each():
            for stream in ("stdout", "stderr"):
                widths: list[int] = []
                for row in self.screen(key, stream) + [""]:
                    if row.lstrip()[:1] in ("╭", "│", "├", "╰") and row.lstrip():
                        widths.append(display_width(row))
                        continue
                    if len(set(widths)) > 1:
                        offending.add(key)
                        detail.append(f"{key} {stream}: {sorted(set(widths))}")
                    widths = []
        self.assertEqual(offending, known("box"), "\n".join(detail[:40]))

    def test_no_redraw_leaves_a_frame_behind(self) -> None:
        offending = set()
        detail = []
        for key in self.each():
            if key[2] != "rich":
                continue
            for stream in ("stdout", "stderr"):
                for row in self.screen(key, stream):
                    if any(glyph in row for glyph in SPINNER):
                        offending.add(key)
                        detail.append(f"{key} {stream}: {row[:70]}")
        self.assertEqual(offending, known("frame"), "\n".join(detail[:40]))

    def test_each_stream_holds_its_own(self) -> None:
        in_stdout = {
            "table": "Session Search",
            "preview": "Recent Messages:",
            "stats": "Session Index",
            "analytics": "Search Analytics",
            "tagger": "Tagged ",
            "installer": "Search your sessions:",
        }
        in_stderr = {"tagger": "untagged sessions"}
        for key in self.each():
            with self.subTest(key=key):
                run = self.runs[key]
                stdout, stderr = ESCAPE.sub("", run.stdout), ESCAPE.sub("", run.stderr)
                self.assertIn(in_stdout[key[0]], stdout)
                self.assertNotIn(in_stdout[key[0]], stderr)
                if key[0] in in_stderr:
                    self.assertIn(in_stderr[key[0]], stderr)
                    self.assertNotIn(in_stderr[key[0]], stdout)
                if key[2] == "plain":
                    self.assertNotIn("\x1b", run.stdout)
                    self.assertNotIn("\x1b", run.stderr)
                    if key[0] != "tagger":
                        self.assertEqual(run.stderr, "")

    def test_goldens(self) -> None:
        update = bool(os.environ.get("TRANSCRIPTS_UPDATE"))
        for key in self.each(GOLDEN_VIEWS):
            with self.subTest(key=key):
                sections = []
                for stream in ("stdout", "stderr"):
                    body = normalize(
                        "\n".join(self.screen(key, stream)), self.homes[key]
                    ).rstrip()
                    sections.append(f"--- {stream} ---\n{body}\n")
                text = "".join(sections)
                path = GOLDEN / "{}.{}.{}.txt".format(*key)
                if update:
                    GOLDEN.mkdir(exist_ok=True)
                    path.write_text(text, encoding="utf-8")
                self.assertEqual(text, path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
