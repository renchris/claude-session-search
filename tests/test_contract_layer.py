import argparse
import contextlib
import io
import json
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from engine_loader import load_engine

engine = load_engine()


class FakeStream(io.StringIO):
    def __init__(self, tty=False):
        super().__init__()
        self.tty = tty

    def isatty(self):
        return self.tty


def resolve(env=None, tty=False, **kwargs):
    streams = (FakeStream(tty), FakeStream(tty), FakeStream(tty))
    return engine.resolve_mode(environ=env or {}, streams=streams, **kwargs)


def stderr_of(fn, mode, tty=False):
    err = FakeStream(tty)
    with mock.patch.object(engine, "MODE", mode), contextlib.redirect_stderr(err):
        fn()
    return err.getvalue()


def run_cli(main_fn, mode):
    err = FakeStream()
    with mock.patch.object(engine, "MODE", mode), contextlib.redirect_stderr(err):
        with unittest.TestCase().assertRaises(SystemExit) as caught:
            engine.run_cli(main_fn)
    return caught.exception.code, err.getvalue()


def raiser(exc):
    def main():
        raise exc

    return main


class ContractLayerTest(unittest.TestCase):
    def setUp(self):
        engine.WARNINGS.clear()
        self.addCleanup(engine.WARNINGS.clear)

    def test_color_precedence(self):
        cases = [
            ({}, True, {}, True),
            ({}, False, {}, False),
            ({}, True, {"no_color": True}, False),
            ({"FORCE_COLOR": "1"}, True, {"no_color": True}, False),
            ({"NO_COLOR": "1", "FORCE_COLOR": "1"}, True, {}, False),
            ({"NO_COLOR": ""}, True, {}, True),
            ({"FORCE_COLOR": "0"}, True, {}, False),
            ({"FORCE_COLOR": "0", "__SESSION_SEARCH_PICKER": "1"}, False, {}, False),
            ({"FORCE_COLOR": "1"}, False, {}, True),
            ({"FORCE_COLOR": "1", "TERM": "dumb"}, True, {}, True),
            ({"TERM": "dumb"}, True, {}, False),
            ({"__SESSION_SEARCH_PICKER": "1"}, False, {}, True),
            ({"NO_COLOR": "1", "__SESSION_SEARCH_PICKER": "1"}, False, {}, False),
        ]
        for env, tty, kwargs, expected in cases:
            with self.subTest(env=env, tty=tty, kwargs=kwargs):
                mode = resolve(env, tty, **kwargs)
                self.assertEqual((mode.color_out, mode.color_err), (expected, expected))

    def test_color_is_decided_per_stream(self):
        streams = (FakeStream(True), FakeStream(False), FakeStream(True))
        mode = engine.resolve_mode(environ={}, streams=streams)
        self.assertEqual((mode.color_out, mode.color_err), (False, True))

    def test_interactive_and_tips(self):
        self.assertTrue(resolve({}, True).interactive)
        self.assertFalse(resolve({}, False).interactive)
        self.assertFalse(resolve({"CI": "1"}, True).interactive)
        self.assertFalse(resolve({}, True, json_mode=True).interactive)
        agent = resolve({"CLAUDECODE": "1"}, True)
        self.assertTrue(agent.agent)
        self.assertFalse(agent.interactive)
        self.assertTrue(resolve({}, True).tips)
        self.assertFalse(resolve({}, True, json_mode=True).tips)
        self.assertFalse(resolve({"SESSION_SEARCH_GUIDANCE_DISABLED": "1"}, True).tips)

    def test_closed_stream_is_not_a_tty(self):
        closed = FakeStream(True)
        closed.close()
        closed.isatty = io.StringIO.isatty.__get__(closed)
        mode = engine.resolve_mode(environ={}, streams=(None, closed, FakeStream(True)))
        self.assertEqual(
            (mode.stdin_tty, mode.stdout_tty, mode.stderr_tty), (False, False, True)
        )

    def test_accessible_debug_and_picker_flags(self):
        self.assertTrue(resolve({"SESSION_SEARCH_ACCESSIBLE": "1"}).accessible)
        self.assertFalse(resolve({"SESSION_SEARCH_ACCESSIBLE": "0"}).accessible)
        self.assertTrue(resolve({"SESSION_SEARCH_DEBUG": "1"}).debug)
        self.assertTrue(resolve(debug=True).debug)
        self.assertTrue(resolve({"__SESSION_SEARCH_PICKER": "1"}).picker)

    def test_theme_roles_follow_mode(self):
        with mock.patch.object(engine, "MODE", resolve({}, False)):
            self.assertEqual(engine.theme("out").heading, "")
            self.assertEqual(engine.theme("out").H, "─")
        with mock.patch.object(engine, "MODE", resolve({}, True)):
            self.assertEqual(engine.theme("err").warn, "\033[33m")
        with mock.patch.object(
            engine, "MODE", resolve({"__SESSION_SEARCH_PICKER": "1"}, False)
        ):
            self.assertEqual(engine.theme("out").accent, "\033[36m")
        with mock.patch.object(engine, "MODE", resolve({"FORCE_COLOR": "1"}, False)):
            forced = engine.theme("err")
            self.assertEqual((forced.warn, forced.accent), ("\033[33m", ""))
        with mock.patch.object(
            engine, "MODE", resolve({"SESSION_SEARCH_ACCESSIBLE": "1"}, True)
        ):
            self.assertEqual(engine.theme("out").ARROW, "to")

    def test_sanitize_display(self):
        cases = {
            "\x1b[31mred\x1b[0m": "red",
            "\x1b]0;title\x07x": "x",
            "\x1b]8;;http://a\x1b\\x": "x",
            "\x1bcx": "x",
            "a\x01\x7f\x85\x9bb": "ab",
            "a‮b​c": "abc",
            "a\tb\nc\rd": "a b c d",
            "\x02hit\x03": "hit",
            "plain": "plain",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(engine.sanitize_display(raw), expected)
        self.assertEqual(
            engine.sanitize_display("\x02hit\x03\x01", keep_hl=True), "\x02hit\x03"
        )

    def test_plural(self):
        self.assertEqual(engine.plural(1, "result"), "1 result")
        self.assertEqual(engine.plural(0, "result"), "0 results")
        self.assertEqual(engine.plural(2, "match", "matches"), "2 matches")

    def test_warn_prints_once_per_reason(self):
        def twice():
            engine.warn("limit_clamped", "Limit lowered.")
            engine.warn("limit_clamped", "Limit lowered again.")

        self.assertEqual(
            stderr_of(twice, resolve({}, False)), "Warning: Limit lowered.\n"
        )
        engine.WARNINGS.clear()
        self.assertEqual(stderr_of(twice, resolve({}, True)).count("!"), 1)

    def test_warn_with_json_goes_to_the_document(self):
        mode = resolve(json_mode=True)
        self.assertEqual(stderr_of(lambda: engine.warn("deprecated", "Old."), mode), "")
        out = FakeStream()
        with mock.patch.object(engine, "MODE", mode):
            engine.emit_json({"a": 1}, out)
            engine.emit_json([1], out)
        first, second = out.getvalue().splitlines()
        self.assertEqual(
            json.loads(first)["warnings"], [{"reason": "deprecated", "message": "Old."}]
        )
        self.assertEqual(second, "[1]")

    def test_cli_error_rejects_unknown_reason_and_caps_recovery(self):
        with self.assertRaises(ValueError):
            engine.CliError("x", reason="nope")
        pairs = (("A:", "a"), ("B:", "b"), ("C:", "c"))
        self.assertEqual(len(engine.CliError("x", recovery=pairs).recovery), 2)

    def test_render_error_human_layout(self):
        err = engine.usage_error("Bad \x1b[31mflag.")
        self.assertEqual(err.code, 2)
        printed = stderr_of(lambda: engine.render_error(err, resolve()), resolve())
        self.assertEqual(
            printed, "Error: Bad flag.\n\nSee help:\n    claude-search --help\n"
        )

    def test_render_error_json_is_one_line_with_next_objects(self):
        mode = resolve(json_mode=True)
        engine.WARNINGS.append({"reason": "deprecated", "message": "Old."})
        printed = stderr_of(
            lambda: engine.render_error(engine.usage_error("Bad."), mode), mode
        )
        self.assertEqual(printed.count("\n"), 1)
        doc = json.loads(printed)
        self.assertEqual(doc["status"], "action_required")
        self.assertEqual(doc["reason"], "invalid_arguments")
        self.assertEqual(
            doc["next"],
            [{"command": "claude-search --help", "argv": ["claude-search", "--help"]}],
        )
        self.assertEqual(doc["warnings"][0]["reason"], "deprecated")
        self.assertNotIn("data", doc)
        self.assertNotIn("retryable", doc)

    def test_run_cli_maps_return_and_cli_error(self):
        self.assertEqual(run_cli(lambda: None, resolve())[0], 0)
        self.assertEqual(run_cli(lambda: 3, resolve())[0], 3)
        code, printed = run_cli(raiser(engine.usage_error("Bad.")), resolve())
        self.assertEqual(code, 2)
        self.assertIn("Error: Bad.", printed)

    def test_run_cli_keyboard_interrupt(self):
        self.assertEqual(
            run_cli(raiser(KeyboardInterrupt()), resolve()), (130, "Canceled.\n")
        )
        code, printed = run_cli(raiser(KeyboardInterrupt()), resolve(json_mode=True))
        doc = json.loads(printed)
        self.assertEqual(
            (code, doc["reason"], doc["data"]["remote"]), (130, "canceled", "none")
        )

    def test_run_cli_sqlite_error(self):
        code, printed = run_cli(
            raiser(sqlite3.OperationalError("secret query")), resolve()
        )
        self.assertEqual(code, 1)
        self.assertIn(
            "Search index error: OperationalError in ~/.claude/session-index.db.",
            printed,
        )
        self.assertIn(
            "Rebuild it:\n    ~/.claude/bin/session-index-backfill.sh", printed
        )
        self.assertNotIn("secret", printed)

    def test_run_cli_unexpected_error_hides_input(self):
        code, printed = run_cli(raiser(ValueError("secret /private/input")), resolve())
        self.assertEqual(code, 1)
        self.assertIn(
            "Unexpected error in claude-search. This is a bug in claude-session-search.",
            printed,
        )
        self.assertIn("Error:   ValueError at test_contract_layer.py:", printed)
        self.assertIn(f"Version: claude-search {engine.VERSION}", printed)
        self.assertIn(engine.ISSUES_URL, printed)
        self.assertNotIn("secret", printed)
        self.assertNotIn("Traceback", printed)

    def test_run_cli_unexpected_error_traceback_only_with_debug(self):
        _, printed = run_cli(raiser(ValueError("boom")), resolve(debug=True))
        self.assertIn("Traceback", printed)

    def test_run_cli_unexpected_error_json_is_the_last_line(self):
        _, printed = run_cli(raiser(ValueError("secret")), resolve(json_mode=True))
        doc = json.loads(printed)
        self.assertEqual(
            (doc["reason"], doc["data"]["error"]), ("internal_error", "ValueError")
        )
        self.assertNotIn("secret", printed)

    def test_emit_json_indent_follows_tty(self):
        tty, pipe = FakeStream(True), FakeStream(False)
        with mock.patch.object(engine, "MODE", resolve()):
            engine.emit_json({"a": Path("x")}, tty)
            engine.emit_json({"a": 1, "b": 2}, pipe)
        self.assertEqual(tty.getvalue(), '{\n  "a": "x"\n}\n')
        self.assertEqual(pipe.getvalue(), '{"a":1,"b":2}\n')

    def test_atomic_write_text_replaces_the_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "out.json"
            target.write_text("old", encoding="utf-8")
            engine.atomic_write_text(target, "new ✓")
            self.assertEqual(target.read_text(encoding="utf-8"), "new ✓")
            self.assertEqual(os.listdir(tmp), ["out.json"])

    def test_atomic_write_text_leaves_no_temp_file_on_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "out.json"
            target.write_text("old", encoding="utf-8")
            with mock.patch.object(engine.os, "replace", side_effect=OSError("disk")):
                with self.assertRaises(OSError):
                    engine.atomic_write_text(target, "new")
            with self.assertRaises(UnicodeEncodeError):
                engine.atomic_write_text(target, "\udc80")
            self.assertEqual(os.listdir(tmp), ["out.json"])
            self.assertEqual(target.read_text(encoding="utf-8"), "old")

    def test_spinner_writes_only_to_stderr(self):
        out, err = FakeStream(True), FakeStream(True)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with engine.spinner("Working", resolve({}, True)):
                pass
        self.assertEqual(out.getvalue(), "")
        self.assertIn("Working", err.getvalue())
        self.assertTrue(err.getvalue().endswith("\r\033[K"))

    def test_spinner_is_silent_without_a_color_tty(self):
        err = FakeStream()
        with contextlib.redirect_stderr(err):
            with engine.spinner("Working", resolve({}, False)):
                pass
        self.assertEqual(err.getvalue(), "")

    def test_spinner_is_silent_unless_interactive_and_colored(self):
        cases = [
            resolve({"CI": "1"}, True),
            resolve({"CLAUDECODE": "1"}, True),
            resolve({"NO_COLOR": "1"}, True),
            resolve({}, True, json_mode=True),
        ]
        for mode in cases:
            with self.subTest(mode=mode):
                err = FakeStream(True)
                with contextlib.redirect_stderr(err):
                    with engine.spinner("Working", mode):
                        pass
                self.assertEqual(err.getvalue(), "")

    def test_spinner_clears_on_keyboard_interrupt(self):
        err = FakeStream(True)
        with contextlib.redirect_stderr(err), self.assertRaises(KeyboardInterrupt):
            with engine.spinner("Working", resolve({}, True)):
                raise KeyboardInterrupt
        self.assertTrue(err.getvalue().endswith("\r\033[K"))

    def test_spinner_accessible_prints_one_plain_line(self):
        err = FakeStream(True)
        with contextlib.redirect_stderr(err):
            with engine.spinner(
                "Working", resolve({"SESSION_SEARCH_ACCESSIBLE": "1"}, True)
            ):
                pass
        self.assertEqual(err.getvalue(), "Working\n")

    def test_positive_int(self):
        self.assertEqual(engine.positive_int("1"), 1)
        for bad in ("0", "-1", "abc", "1.5", "", "1_000"):
            with (
                self.subTest(bad=bad),
                self.assertRaises(argparse.ArgumentTypeError) as caught,
            ):
                engine.positive_int(bad)
            self.assertEqual(
                str(caught.exception), "must be a whole number of 1 or more"
            )

    def test_nonneg_int(self):
        self.assertEqual(engine.nonneg_int("0"), 0)
        for bad in ("-1", "abc", ""):
            with self.subTest(bad=bad), self.assertRaises(argparse.ArgumentTypeError):
                engine.nonneg_int(bad)

    def test_parse_time_relative(self):
        cases = {
            "7": timedelta(days=7),
            "7d": timedelta(days=7),
            "12h": timedelta(hours=12),
            "30m": timedelta(minutes=30),
        }
        for raw, delta in cases.items():
            with self.subTest(raw=raw):
                moment = datetime.fromisoformat(engine.parse_time(raw))
                self.assertEqual(moment.utcoffset(), timedelta(0))
                self.assertLess(
                    abs(datetime.now(timezone.utc) - delta - moment),
                    timedelta(seconds=30),
                )

    def test_parse_time_iso(self):
        cases = {
            "2026-03-01": "2026-03-01T00:00:00+00:00",
            "2026-03-01T10:00:00": "2026-03-01T10:00:00+00:00",
            "2026-03-01T10:00:00Z": "2026-03-01T10:00:00+00:00",
            "2026-03-01T10:00:00+02:00": "2026-03-01T08:00:00+00:00",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(engine.parse_time(raw), expected)

    def test_parse_time_rejects(self):
        for bad in ("abc", "1.5", "", "-7", "99999999999999d", "7w"):
            with (
                self.subTest(bad=bad),
                self.assertRaises(argparse.ArgumentTypeError) as caught,
            ):
                engine.parse_time(bad)
            self.assertIn("ISO 8601", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
