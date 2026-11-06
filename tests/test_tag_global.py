"""Global options and machine output of scripts/session-index-tag.py.

Always against a sandbox HOME. No test reaches the network: urlopen and the SDK are patched,
and the key is a marker.
"""

import fcntl
import json
import re
import signal
import sqlite3
import sys
import unittest
import warnings
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_tag_cli import (  # noqa: E402
    MARKER_KEY,
    REPO,
    SCRIPT,
    InProcessTestCase,
    api_reply,
    tag,
)
from test_tag_runs import NO_MATCH, ScriptCase  # noqa: E402

VERSION = (REPO / "VERSION").read_text(encoding="utf-8").strip()
EMPTY_SUMMARY = {"succeeded": 0, "failed": 0, "skipped": 0, "unknown": 0}
TINT = "\033[33m"


def summary(**counts):
    return {**EMPTY_SUMMARY, **counts}


class QuietInProcessTestCase(InProcessTestCase):
    def run_entry(self, *args, **kwargs):
        # main holds its lock file until the process exits, and the warning would land in
        # the stderr these tests compare.
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", ResourceWarning)
            return super().run_entry(*args, **kwargs)


class VersionTests(ScriptCase):
    def test_version_needs_no_db_and_prints_only_the_version(self):
        for flag in ("-v", "--version"):
            result = self.run_script(flag)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, VERSION + "\n")
            self.assertEqual(result.stderr, "")
        self.assertFalse(self.db.exists())
        self.assertFalse((self.claude / "session-index.lock").exists())

    def test_version_with_json_is_a_document(self):
        result = self.run_script("--version", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"version": VERSION})
        self.assertEqual(result.stderr, "")

    def test_help_wins_over_version(self):
        for argv in (("--help", "--version"), ("--version", "--help")):
            result = self.run_script(*argv)
            self.assertEqual(result.returncode, 0)
            self.assertIn("usage:", result.stdout)
            self.assertNotEqual(result.stdout.strip(), VERSION)

    def test_version_reads_the_file_through_the_installed_symlink(self):
        link = self.claude / "bin" / "session-index-tag.py"
        link.parent.mkdir()
        link.symlink_to(SCRIPT)
        result = self.run_script("--version", script=link)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, VERSION + "\n")


class HelpTests(ScriptCase):
    def test_the_exit_codes_block_still_parses(self):
        help_text = self.run_script("--help").stdout
        block = help_text.split("Exit codes:\n", 1)[1]
        rows = re.findall(r"^  (\d+)\s+(\S.*)$", block, re.M)
        self.assertEqual([code for code, _ in rows], ["0", "1", "2", "130"])
        # Everything else in the block continues the row above it.
        continuations = [
            line
            for line in block.splitlines()
            if line and not re.match(r"^  \d+\s", line)
        ]
        self.assertEqual(len(continuations), 1)
        self.assertTrue(continuations[0].startswith("       --json only:"))
        one_at = block.index("  1    ")
        self.assertLess(one_at, block.index(continuations[0]))
        self.assertLess(block.index(continuations[0]), block.index("  2    "))

    def test_non_interactive_changes_nothing(self):
        self.seed_sessions(2)
        plain = self.run_script("--dry-run")
        accepted = self.run_script("--dry-run", "--non-interactive")
        self.assertEqual(accepted.returncode, plain.returncode)
        self.assertEqual(accepted.stdout, plain.stdout)
        self.assertEqual(accepted.stderr, plain.stderr)

    def test_abbreviations_stay_off(self):
        self.assertEqual(self.run_script("--d").returncode, 2)
        self.assertEqual(self.run_script("--js").returncode, 2)


class NoColorTests(ScriptCase):
    def test_no_color_removes_colour_and_keeps_the_dashboard_on_a_terminal(self):
        self.seed_sessions(2)
        code, out, _ = self.run_on_pty("--regex-only", "--no-color")
        self.assertEqual(code, 0)
        self.assertIn("\x1b[?25l", out)
        for colour in (tag.BOLD, tag.DIM, tag.GREEN, tag.RED, tag.CYAN):
            self.assertNotIn(colour, out)
        self.assertIn("Tagged", out)

    def test_no_color_beats_forced_colour(self):
        self.seed_sessions(2)
        forced = self.run_script("--regex-only", "--limit", "1", FORCE_COLOR="1")
        self.assertIn(tag.BOLD, forced.stdout)
        result = self.run_script(
            "--regex-only", "--limit", "1", "--no-color", FORCE_COLOR="1"
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("Regex-only", result.stdout)
        self.assertNotIn("\x1b[", result.stdout)

    def test_no_color_reaches_the_error_path_run_cli_prints(self):
        self.seed_sessions(1)
        with open(self.claude / "session-index.lock", "w") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            tinted = self.run_script("--regex-only", FORCE_COLOR="1")
            plain = self.run_script("--regex-only", "--no-color", FORCE_COLOR="1")
        self.assertEqual(tinted.returncode, 1)
        self.assertIn(TINT, tinted.stderr)
        self.assertEqual(plain.returncode, 1)
        self.assertNotIn("\x1b[", plain.stderr)
        self.assertIn("Another session-index process", plain.stderr)


class JsonScriptTests(ScriptCase):
    def assert_one_error_line(self, result, reason, status="error"):
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
        doc = json.loads(result.stderr)
        self.assertEqual(doc["status"], status)
        self.assertEqual(doc["reason"], reason)
        self.assertTrue(doc["message"])
        self.assertIsInstance(doc["next"], list)
        return doc

    def test_json_is_one_document_on_a_tty(self):
        self.seed_sessions(2)
        code, out, err = self.run_on_pty("--regex-only", "--json")
        self.assertEqual(code, 0)
        self.assertNotIn("\x1b", out)
        doc = json.loads(out)
        self.assertEqual(doc["summary"], summary(succeeded=2))
        self.assertEqual(
            doc["results"],
            [
                {"id": "sid-2", "outcome": "tagged"},
                {"id": "sid-1", "outcome": "tagged"},
            ],
        )
        self.assertIn('\n  "results"', out)
        self.assertEqual(err, "")

    def test_json_is_one_line_on_a_pipe_and_persists(self):
        self.seed_sessions(1)
        result = self.run_script("--regex-only", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertEqual(json.loads(result.stdout)["summary"], summary(succeeded=1))
        self.assertEqual(self.count_untagged(), 0)

    def test_json_with_no_rows_is_empty_results_exit_0(self):
        self.seed({"tagged_at": "2026-01-01T00:00:00Z"})
        for argv in (("--regex-only", "--json"), ("--dry-run", "--json")):
            result = self.run_script(*argv)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(
                json.loads(result.stdout), {"results": [], "summary": EMPTY_SUMMARY}
            )
            self.assertEqual(result.stderr, "")

    def test_json_pre_work_failure_is_one_stderr_line(self):
        doc = self.assert_one_error_line(
            self.run_script("--json"), "not_found", "action_required"
        )
        self.assertEqual(doc["next"][0]["argv"][0][0], "/")

    def test_a_held_lock_under_json_is_one_stderr_line(self):
        self.seed_sessions(1)
        with open(self.claude / "session-index.lock", "w") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX)
            result = self.run_script("--regex-only", "--json")
        doc = self.assert_one_error_line(result, "lock_held")
        self.assertIn("--json", doc["next"][0]["argv"])

    def test_retag_with_no_key_under_json_is_one_stderr_line(self):
        self.seed_sessions(1)
        self.assert_one_error_line(
            self.run_script("--retag-summaries", "--json"),
            "invalid_config",
            "action_required",
        )

    def test_a_file_that_is_no_database_under_json_is_one_stderr_line(self):
        self.db.write_bytes(b"this is not a database, not even close" * 50)
        result = self.run_script("--regex-only", "--json")
        doc = self.assert_one_error_line(result, "internal_error")
        self.assertIn("session-index-backfill.sh", doc["next"][0]["command"])
        self.assertNotIn("Traceback", result.stderr)

    def test_no_match_and_empty_text_are_skips_that_recur_and_exit_0(self):
        self.seed(
            {"session_id": "tagged", "modified_at": "2026-01-03"},
            {
                "session_id": "none",
                "first_prompt": NO_MATCH,
                "modified_at": "2026-01-02",
            },
            {"session_id": "blank", "first_prompt": "", "modified_at": "2026-01-01"},
        )
        result = self.run_script("--regex-only", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "results": [
                    {"id": "tagged", "outcome": "tagged"},
                    {"id": "none", "outcome": "skipped", "error": "no_match"},
                    {"id": "blank", "outcome": "skipped", "error": "empty_text"},
                ],
                "summary": summary(succeeded=1, skipped=2),
            },
        )
        self.assertEqual(result.stderr, "")
        # They stay selectable, so the next run sees them again and must still exit 0.
        again = self.run_script("--regex-only", "--json")
        self.assertEqual(again.returncode, 0)
        self.assertEqual(json.loads(again.stdout)["summary"], summary(skipped=2))

    def test_a_capped_batch_says_nothing_beyond_the_document(self):
        self.seed_sessions(2)
        result = self.run_script("--regex-only", "--limit", "1", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(json.loads(result.stdout)["results"]), 1)
        self.assertEqual(result.stderr, "")

    def test_a_dry_run_plans_writes_nothing_and_fails_nothing(self):
        self.seed(
            {"session_id": "sid-1", "modified_at": "2026-01-02"},
            {
                "session_id": "sid-2",
                "first_prompt": NO_MATCH,
                "modified_at": "2026-01-01",
            },
        )
        result = self.run_script("--dry-run", "--json")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "results": [
                    {"id": "sid-1", "outcome": "planned"},
                    {"id": "sid-2", "outcome": "skipped", "error": "no_match"},
                ],
                "summary": summary(succeeded=1, skipped=1),
            },
        )
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.count_untagged(), 2)
        self.assertFalse((self.claude / "session-index.lock").exists())

    def test_json_runs_through_the_installed_symlink(self):
        self.seed_sessions(1)
        link = self.claude / "bin" / "session-index-tag.py"
        link.parent.mkdir()
        link.symlink_to(SCRIPT)
        result = self.run_script("--regex-only", "--json", script=link)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["summary"], summary(succeeded=1))


class JsonInProcessTests(QuietInProcessTestCase):
    def seed_two(self, second_prompt="fix the login bug in the react component"):
        self.seed(
            {"session_id": "new", "modified_at": "2026-01-02"},
            {
                "session_id": "old",
                "first_prompt": second_prompt,
                "modified_at": "2026-01-01",
            },
        )

    def fail_begin(self):
        real_connect = sqlite3.connect

        class FailingBegin(sqlite3.Connection):
            def execute(self, sql, *args):
                if sql == "BEGIN IMMEDIATE":
                    raise sqlite3.OperationalError("database is locked")
                return super().execute(sql, *args)

        self.patch(
            tag.sqlite3,
            "connect",
            lambda path: real_connect(path, factory=FailingBegin),
        )

    def test_json_blanks_every_cursor_and_style_constant(self):
        self.patch(tag, "SHOW_CURSOR", "\033[?25h")
        self.patch(tag, "HIDE_CURSOR", "\033[?25l")
        self.patch(tag, "BOLD", "\033[1m")
        self.seed()
        code, out, _ = self.run_entry("--regex-only", "--json")
        self.assertEqual(code, 0)
        self.assertNotIn("\x1b", out)
        self.assertEqual((tag.SHOW_CURSOR, tag.HIDE_CURSOR, tag.BOLD), ("", "", ""))

    def test_a_write_failure_prints_the_partial_result_and_no_error_document(self):
        self.seed_two(second_prompt=NO_MATCH)
        self.fail_begin()
        code, out, err = self.run_entry("--regex-only", "--json")
        self.assertEqual(code, 1)
        self.assertEqual(err, "")
        doc = json.loads(out)
        self.assertEqual(
            doc["results"],
            [
                {"id": "new", "outcome": "skipped", "error": "write_failed"},
                {"id": "old", "outcome": "skipped", "error": "no_match"},
            ],
        )
        self.assertEqual(doc["summary"], summary(failed=1, skipped=1))
        self.assertEqual(doc["warnings"][0]["reason"], "not_persisted")
        self.assertIn("database is locked", doc["warnings"][0]["message"])
        self.assertIn("safe to retry", doc["warnings"][0]["message"])

    def test_haiku_rows_follow_the_selection_order(self):
        self.seed_two()
        self.patch(tag, "urlopen", api_reply(tags=["a-tag"], summary="A summary"))
        code, out, err = self.run_entry("--json", key=MARKER_KEY)
        self.assertEqual(code, 0)
        self.assertEqual(
            [row["id"] for row in json.loads(out)["results"]], ["new", "old"]
        )
        self.assertIn("api.anthropic.com", err)
        self.assertNotIn(MARKER_KEY, err + out)

    def test_an_api_failure_with_no_regex_match_counts_as_failed(self):
        self.seed({"first_prompt": NO_MATCH})
        self.patch(tag, "urlopen", mock.Mock(side_effect=OSError("down")))
        code, out, _ = self.run_entry("--json", key=MARKER_KEY)
        self.assertEqual(code, 1)
        doc = json.loads(out)
        self.assertEqual(
            doc["results"],
            [{"id": "sid-1", "outcome": "skipped", "error": "api_error"}],
        )
        self.assertEqual(doc["summary"], summary(failed=1))

    def test_the_same_api_failure_exits_0_without_json(self):
        self.seed({"first_prompt": NO_MATCH})
        self.patch(tag, "urlopen", mock.Mock(side_effect=OSError("down")))
        code, _, _ = self.run_entry("--quiet", key=MARKER_KEY)
        self.assertEqual(code, 0)

    def test_sessions_the_deadline_cut_are_unknown_and_exit_1(self):
        self.seed_two()
        self.patch(tag, "TOTAL_API_BUDGET_S", -1)
        self.patch(tag, "urlopen", mock.Mock(side_effect=AssertionError))
        code, out, _ = self.run_entry("--json", key=MARKER_KEY)
        self.assertEqual(code, 1)
        doc = json.loads(out)
        self.assertEqual(doc["summary"], summary(unknown=2))
        self.assertEqual({row["error"] for row in doc["results"]}, {"deadline"})

    def test_a_retag_with_no_summary_is_not_reported_as_tagged(self):
        self.seed()
        self.patch(tag, "urlopen", api_reply(tags=["a-tag"], summary=""))
        code, out, _ = self.run_entry("--retag-summaries", "--json", key=MARKER_KEY)
        self.assertEqual(code, 1)
        doc = json.loads(out)
        self.assertEqual(doc["results"][0]["outcome"], "skipped")
        self.assertEqual(doc["results"][0]["error"], "no_summary")
        self.assertEqual(doc["summary"], summary(failed=1))

    def test_a_retag_dry_run_plans_all_but_the_empty_text(self):
        self.seed(
            {
                "session_id": "text",
                "first_prompt": NO_MATCH,
                "modified_at": "2026-01-02",
            },
            {"session_id": "blank", "first_prompt": "", "modified_at": "2026-01-01"},
        )
        code, out, _ = self.run_entry(
            "--dry-run", "--retag-summaries", "--json", key=MARKER_KEY
        )
        self.assertEqual(code, 0)
        self.assertEqual(
            json.loads(out),
            {
                "results": [
                    {"id": "text", "outcome": "planned"},
                    {"id": "blank", "outcome": "skipped", "error": "empty_text"},
                ],
                "summary": summary(succeeded=1, skipped=1),
            },
        )

    def test_a_bug_under_json_is_one_line_with_no_input_text(self):
        self.seed()
        self.patch(tag, "_selection", mock.Mock(side_effect=RuntimeError("input-text")))
        code, out, err = self.run_entry("--regex-only", "--json")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertEqual(len(err.splitlines()), 1, err)
        doc = json.loads(err)
        self.assertEqual(doc["reason"], "internal_error")
        self.assertEqual(doc["data"]["error"], "RuntimeError")
        self.assertNotIn("input-text", err)

    def test_an_interrupt_under_json_is_one_line_and_exits_130(self):
        self.seed()
        self.patch(tag, "_selection", mock.Mock(side_effect=KeyboardInterrupt))
        code, out, err = self.run_entry("--regex-only", "--json")
        self.assertEqual(code, 130)
        self.assertEqual(out, "")
        self.assertEqual(json.loads(err)["reason"], "canceled")


class JsonSignalTests(QuietInProcessTestCase):
    def test_a_signal_during_the_work_is_one_line_and_exits_1(self):
        def deliver(*_args):
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

        self.seed()
        self.patch(tag, "_selection", deliver)
        code, out, err = self.run_entry("--regex-only", "--json")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertEqual(json.loads(err)["reason"], "canceled")


class DebugTests(QuietInProcessTestCase):
    def setUp(self):
        super().setUp()
        self.seed()
        self.patch(tag, "_selection", mock.Mock(side_effect=RuntimeError("boom")))

    def test_no_traceback_without_debug(self):
        code, _, err = self.run_entry("--regex-only")
        self.assertEqual(code, 1)
        self.assertNotIn("Traceback", err)
        self.assertIn("Unexpected error in session-index-tag.py", err)

    def assert_traceback_before_report(self, flag):
        code, _, err = self.run_entry("--regex-only", flag)
        self.assertEqual(code, 1)
        self.assertIn("Traceback", err)
        self.assertLess(
            err.index("Traceback"),
            err.index("Unexpected error in session-index-tag.py"),
        )

    def test_short_debug_shows_the_traceback_before_the_report(self):
        self.assert_traceback_before_report("-d")

    def test_long_debug_shows_the_traceback_before_the_report(self):
        self.assert_traceback_before_report("--debug")

    def test_debug_under_json_keeps_the_last_line_a_document(self):
        code, out, err = self.run_entry("--regex-only", "--json", "--debug")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("Traceback", err)
        self.assertEqual(
            json.loads(err.splitlines()[-1])["data"]["error"], "RuntimeError"
        )


if __name__ == "__main__":
    unittest.main()
