import argparse
import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from engine_loader import load_engine

REPO = Path(__file__).resolve().parent.parent
LIB = REPO / "scripts" / "lib"
MODULE = LIB / "cli_common.py"
sys.path.insert(0, str(LIB))

import cli_common  # noqa: E402


class FakeStream(io.StringIO):
    def __init__(self, tty=False):
        super().__init__()
        self.tty = tty

    def isatty(self):
        return self.tty


def clean_env(**extra):
    drop = ("CI", "CLAUDECODE", "NO_COLOR", "FORCE_COLOR", "TERM", "PYTHONPATH")
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in drop and not key.lstrip("_").startswith("SESSION_SEARCH_")
    }
    return {**env, "PYTHONDONTWRITEBYTECODE": "1", **extra}


def style_under(env, tty, **kwargs):
    with mock.patch.dict(os.environ, clean_env(**{"TERM": "xterm", **env}), clear=True):
        return cli_common.resolve_style(FakeStream(tty), **kwargs)


def run_inline(main_fn, env=None):
    out, err = FakeStream(), FakeStream()
    with (
        mock.patch.dict(os.environ, clean_env(**(env or {})), clear=True),
        contextlib.redirect_stdout(out),
        contextlib.redirect_stderr(err),
    ):
        try:
            cli_common.run_cli(main_fn, "tool")
        except SystemExit as exc:
            return exc.code, out.getvalue(), err.getvalue()
    raise AssertionError("run_cli returned instead of exiting")


def raising(exc):
    def main():
        raise exc

    return main


def run_with_closed_stdout(body):
    code = f"import sys; sys.path.insert(0, {str(LIB)!r}); import cli_common\n{body}"
    read_end, write_end = os.pipe()
    os.close(read_end)
    try:
        return subprocess.run(
            [sys.executable, "-c", code],
            stdout=write_end,
            stderr=subprocess.PIPE,
            env=clean_env(),
            text=True,
            timeout=30,
        )
    finally:
        os.close(write_end)


class ParseTimeTest(unittest.TestCase):
    def test_parse_time_table(self):
        for good in ("7", "7d", "12h", "30m", "2026-03-01", "2026-03-01T00:00:00Z"):
            with self.subTest(good=good):
                self.assertIsInstance(cli_common.parse_time(good), float)
        for bad in ("abc", "1.5", "", "99999999999", "-3", "7w"):
            with self.subTest(bad=bad), self.assertRaises(argparse.ArgumentTypeError):
                cli_common.parse_time(bad)
        for below in ("0", "0d"):
            with (
                self.subTest(below=below),
                self.assertRaises(argparse.ArgumentTypeError),
            ):
                cli_common.parse_time(below, min_days=1)

    def test_min_days_bounds_only_day_counts(self):
        for value in ("1", "1d", "12h", "2026-03-01"):
            with self.subTest(value=value):
                cli_common.parse_time(value, min_days=1)

    def test_relative_values_count_back_from_now(self):
        for value, seconds in (
            ("7", 604800),
            ("7d", 604800),
            ("12h", 43200),
            ("30m", 1800),
        ):
            with self.subTest(value=value):
                self.assertAlmostEqual(
                    cli_common.parse_time(value), time.time() - seconds, delta=5
                )

    def test_naive_iso_is_utc(self):
        expected = datetime(2026, 3, 1, tzinfo=timezone.utc).timestamp()
        self.assertEqual(cli_common.parse_time("2026-03-01"), expected)
        self.assertEqual(cli_common.parse_time("2026-03-01T00:00:00"), expected)
        self.assertEqual(cli_common.parse_time("2026-03-01T01:00:00+01:00"), expected)

    def test_parse_time_cli_entry(self):
        def run(*args):
            return subprocess.run(
                [sys.executable, str(MODULE), "parse-time", *args],
                capture_output=True,
                text=True,
                env=clean_env(),
                timeout=30,
            )

        good = run("2026-03-01")
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(good.stdout, f"{int(cli_common.parse_time('2026-03-01'))}\n")
        self.assertEqual(run("12h", "--min-days", "1").returncode, 0)
        for args in (
            ("abc",),
            ("",),
            ("0", "--min-days", "1"),
            ("7", "--min-days", "x"),
        ):
            with self.subTest(args=args):
                bad = run(*args)
                self.assertEqual(bad.returncode, 2)
                self.assertEqual(bad.stdout, "")
                self.assertNotIn("Traceback", bad.stderr)


class EngineParityTest(unittest.TestCase):
    def test_parity_with_engine(self):
        engine = load_engine()

        def instant(value):
            return datetime.fromisoformat(engine.parse_time(value)).timestamp()

        for value in (
            "2026-03-01",
            "2026-03-01T00:00:00Z",
            "2026-03-01T09:30:00+05:30",
        ):
            with self.subTest(value=value):
                self.assertEqual(cli_common.parse_time(value), instant(value))
        for value in ("7", "007", "100000", "7d", "12h", "30m"):
            with self.subTest(value=value):
                self.assertAlmostEqual(
                    cli_common.parse_time(value), instant(value), delta=5
                )
        for value in ("abc", "1.5", "", "99999999999", "-3", "7w", "Z"):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    engine.parse_time(value)
                with self.assertRaises(argparse.ArgumentTypeError):
                    cli_common.parse_time(value)
        samples = (
            "plain",
            "tab\tnew\nret\r",
            "\x1b[31mred\x1b[0m",
            "\x1b]0;title\x07after",
            "\x1b]8;;http://x\x1b\\link",
            "\x02hl\x03",
            "\x9bc1\x7f",
            "a​b‮c",
            "café ✓",
            "",
        )
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertEqual(
                    cli_common.sanitize_display(sample), engine.sanitize_display(sample)
                )
        for args in ((1, "file"), (2, "file"), (0, "entry", "entries")):
            self.assertEqual(cli_common.plural(*args), engine.plural(*args))

    def test_version_file_matches_engine(self):
        self.assertEqual((REPO / "VERSION").read_text().strip(), load_engine().VERSION)
        self.assertEqual(cli_common.VERSION, load_engine().VERSION)


class FormatTest(unittest.TestCase):
    def test_fmt_duration(self):
        table = (
            (-1, "0ms"),
            (0.042, "42ms"),
            (0.9996, "1.0s"),
            (3.4, "3.4s"),
            (59.96, "1m 0s"),
            (130, "2m 10s"),
            (3725, "1h 2m 5s"),
        )
        for seconds, expected in table:
            with self.subTest(seconds=seconds):
                self.assertEqual(cli_common.fmt_duration(seconds), expected)

    def test_emit_json_indents_only_on_a_tty(self):
        for tty, expected in ((True, '{\n  "a": 1\n}\n'), (False, '{"a":1}\n')):
            out = FakeStream(tty)
            with contextlib.redirect_stdout(out):
                cli_common.emit_json({"a": 1})
            self.assertEqual(out.getvalue(), expected)
            self.assertEqual(json.loads(out.getvalue()), {"a": 1})


class StyleTest(unittest.TestCase):
    def test_style_precedence(self):
        table = (
            # env, tty, kwargs, colour, rich
            ({}, True, {}, True, True),
            ({}, False, {}, False, False),
            ({"TERM": "dumb"}, True, {}, False, False),
            ({"NO_COLOR": "1"}, True, {}, False, True),
            ({"NO_COLOR": ""}, True, {}, True, True),
            ({"FORCE_COLOR": "1"}, False, {}, True, False),
            ({"FORCE_COLOR": "1", "TERM": "dumb"}, True, {}, True, False),
            ({"FORCE_COLOR": "0"}, True, {}, False, True),
            ({"FORCE_COLOR": ""}, False, {}, False, False),
            ({"NO_COLOR": "1", "FORCE_COLOR": "1"}, False, {}, False, False),
            ({"FORCE_COLOR": "1"}, True, {"no_color": True}, False, True),
            (
                {"__SESSION_SEARCH_NO_COLOR": "1", "FORCE_COLOR": "1"},
                True,
                {},
                False,
                True,
            ),
            ({"SESSION_SEARCH_ACCESSIBLE": "1"}, True, {}, True, False),
        )
        for env, tty, kwargs, colour, rich in table:
            with self.subTest(env=env, tty=tty, kwargs=kwargs):
                style = style_under(env, tty, **kwargs)
                self.assertEqual((style.colour, style.rich), (colour, rich))

    def test_style_resolves_per_stream(self):
        with mock.patch.dict(os.environ, clean_env(TERM="xterm"), clear=True):
            self.assertTrue(cli_common.resolve_style(FakeStream(True)).rich)
            self.assertFalse(cli_common.resolve_style(FakeStream(False)).rich)
            self.assertFalse(cli_common.resolve_style(None).rich)
            closed = FakeStream(True)
            closed.isatty = mock.Mock(side_effect=ValueError)
            self.assertFalse(cli_common.resolve_style(closed).colour)

    def test_glyph_follows_rich_not_colour(self):
        rich = cli_common.Style(colour=False, rich=True)
        plain = cli_common.Style(colour=True, rich=False)
        table = (
            ("success", "✓", "Done:"),
            ("warning", "!", "Warning:"),
            ("error", "✗", "Error:"),
        )
        for name, on, off in table:
            self.assertEqual(cli_common.glyph(name, rich), on)
            self.assertEqual(cli_common.glyph(name, plain), off)


class RunCliTest(unittest.TestCase):
    def test_returned_code_is_the_exit_code(self):
        self.assertEqual(run_inline(lambda: 3)[0], 3)
        self.assertEqual(run_inline(lambda: None)[0], 0)
        self.assertEqual(run_inline(raising(SystemExit(2)))[0], 2)

    def test_cli_error_layout(self):
        err = cli_common.CliError(
            "Bad \x1b[31mthing\nhere",
            code=4,
            rows=("Path: /x",),
            recovery=(("Fix it", "tool --fix"),),
        )
        code, _, stderr = run_inline(raising(err))
        self.assertEqual(code, 4)
        self.assertEqual(
            stderr, "Error: Bad thing here\nPath: /x\n\nFix it:\n    tool --fix\n"
        )

    def test_forced_colour_tints_only_the_prefix(self):
        err = cli_common.CliError("Bad")
        _, _, stderr = run_inline(raising(err), {"FORCE_COLOR": "1"})
        self.assertEqual(stderr, "\033[33mError:\033[0m Bad\n")

    def test_internal_error_has_no_input_text(self):
        marker = "SECRET-MARKER-/Users/someone/token"
        code, stdout, stderr = run_inline(raising(ValueError(marker)))
        self.assertEqual(code, 1)
        self.assertEqual(stdout, "")
        self.assertNotIn(marker, stderr)
        self.assertNotIn("Traceback", stderr)
        lines = stderr.splitlines()
        self.assertEqual(
            lines[0],
            "Error: Unexpected error in tool. This is a bug in claude-session-search.",
        )
        self.assertRegex(
            lines[1], r"^Error:   ValueError at test_scripts_common\.py:\d+$"
        )
        self.assertTrue(
            lines[2].startswith(f"Version: tool {cli_common.VERSION}, Python ")
        )
        self.assertEqual(lines[-1], f"    {cli_common.ISSUES_URL}")

    def test_debug_env_shows_the_traceback(self):
        _, _, stderr = run_inline(
            raising(ValueError("x")), {"SESSION_SEARCH_DEBUG": "1"}
        )
        self.assertIn("Traceback", stderr)

    def test_keyboard_interrupt_exits_130(self):
        code, _, stderr = run_inline(raising(KeyboardInterrupt()))
        self.assertEqual(code, 130)
        self.assertEqual(stderr, "Canceled.\n")

    def test_sqlite_error_names_the_db(self):
        with tempfile.TemporaryDirectory() as home:
            code, _, stderr = run_inline(
                raising(sqlite3.OperationalError("no such table: sessions")),
                {"HOME": home},
            )
        self.assertEqual(code, 1)
        self.assertEqual(
            stderr.splitlines()[0],
            f"Error: Could not read session index {home}/.claude/session-index.db:"
            " no such table: sessions",
        )
        self.assertIn("session-index-backfill.sh", stderr)
        self.assertNotIn("Traceback", stderr)

    def test_closed_stderr_keeps_the_code(self):
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                f"import sys; sys.path.insert(0, {str(LIB)!r}); import cli_common\n"
                "sys.stderr.close()\n"
                "def main(): raise cli_common.CliError('x', code=4)\n"
                "cli_common.run_cli(main, 'tool')\n",
            ],
            capture_output=True,
            env=clean_env(),
            timeout=30,
        )
        self.assertEqual(result.returncode, 4)

    def test_broken_pipe_keeps_the_real_outcome(self):
        table = (
            ("returned code", "return 3", 3, ""),
            ("sys.exit", "sys.exit(2)", 2, ""),
            (
                "cli error",
                "raise cli_common.CliError('Bad', code=4)",
                4,
                "Error: Bad\n",
            ),
            ("read mid-stream", "sys.stdout.flush()", 0, ""),
        )
        for name, tail, code, stderr in table:
            with self.subTest(name=name):
                result = run_with_closed_stdout(
                    "def main():\n"
                    "    print('row')\n"
                    f"    {tail}\n"
                    "cli_common.run_cli(main, 'tool')\n"
                )
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(result.stderr, stderr)


class LoadingTest(unittest.TestCase):
    def test_import_has_no_side_effect(self):
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                "import signal, sys\n"
                f"sys.path.insert(0, {str(LIB)!r})\n"
                "before = signal.getsignal(signal.SIGPIPE)\n"
                "import cli_common\n"
                "assert signal.getsignal(signal.SIGPIPE) == before\n",
            ],
            capture_output=True,
            text=True,
            env=clean_env(),
            timeout=30,
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_import_through_a_symlink(self):
        tool = (
            "import sys\n"
            "from pathlib import Path\n"
            'sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))\n'
            "import cli_common\n"
            "print(cli_common.VERSION)\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            (root / "repo" / "scripts" / "lib").mkdir(parents=True)
            (root / "bin").mkdir()
            (root / "repo" / "VERSION").write_text("9.9.9\n")
            shutil.copy(MODULE, root / "repo" / "scripts" / "lib" / "cli_common.py")
            (root / "repo" / "scripts" / "tool.py").write_text(tool)
            (root / "bin" / "tool.py").symlink_to(root / "repo" / "scripts" / "tool.py")
            (root / "bin" / "cli_common.py").symlink_to(MODULE)

            through_tool = subprocess.run(
                [sys.executable, str(root / "bin" / "tool.py")],
                capture_output=True,
                text=True,
                env=clean_env(),
                timeout=30,
            )
            self.assertEqual(through_tool.stdout, "9.9.9\n", through_tool.stderr)

            # The module itself symlinked: VERSION still resolves from its real path.
            through_module = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    f"import sys; sys.path.insert(0, {str(root / 'bin')!r}); import cli_common\n"
                    "print(cli_common.VERSION)\n",
                ],
                capture_output=True,
                text=True,
                env=clean_env(),
                timeout=30,
            )
            self.assertEqual(through_module.stdout, f"{cli_common.VERSION}\n")

    def test_missing_version_file_is_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            for place in (Path(tmp) / "a" / "b" / "c", Path(tmp)):
                place.mkdir(parents=True, exist_ok=True)
                shutil.copy(MODULE, place / "cli_common.py")
                result = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        f"import sys; sys.path.insert(0, {str(place)!r}); import cli_common\n"
                        "print(cli_common.VERSION)\n",
                    ],
                    capture_output=True,
                    text=True,
                    env=clean_env(),
                    timeout=30,
                )
                self.assertEqual(result.stdout, "unknown\n", result.stderr)


if __name__ == "__main__":
    unittest.main()
