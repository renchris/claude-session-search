"""Run reporting of scripts/session-index-tag.py: dry run, API bounds, capped batches, styling.

Always against a sandbox HOME. No test reaches the network: urlopen and the SDK are patched,
and the key is a marker or unset.
"""

import contextlib
import email.message
import fcntl
import io
import itertools
import os
import pty
import re
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_tag_cli import (  # noqa: E402
    MARKER_KEY,
    SCRIPT,
    InProcessTestCase,
    SandboxTestCase,
    api_reply,
    cli_common,
    tag,
)

STYLE_VARS = (
    "NO_COLOR",
    "FORCE_COLOR",
    "SESSION_SEARCH_ACCESSIBLE",
    "__SESSION_SEARCH_NO_COLOR",
    "COLUMNS",
)
NO_MATCH = "qqqqqqqqqqqqqqqqqqqq"
DISCLOSURE = (
    "Sending session summaries and first prompts to api.anthropic.com (Claude Haiku) "
    "because ANTHROPIC_API_KEY is set. Pass --regex-only to stay local."
)
RICH_CODES = ("\x1b[?25l", "\x1b[?25h", "\x1b[J", "\x1b[8A")
COLOUR_CODES = (tag.BOLD, tag.DIM, tag.GREEN, tag.RED, tag.CYAN)
FAKE_UUID = "0123abcd-0123-4abc-8def-0123456789ab"


def http_error(code, retry_after=None):
    headers = email.message.Message()
    if retry_after is not None:
        headers["Retry-After"] = retry_after
    return HTTPError(
        "https://api.anthropic.com/v1/messages", code, "no", headers, io.BytesIO(b"")
    )


def good_response():
    return api_reply(tags=["a-tag"], summary="A summary").return_value


class ScriptCase(SandboxTestCase):
    def child_env(self, **extra):
        env = super().child_env()
        for name in STYLE_VARS:
            env.pop(name, None)
        env.update(extra)
        return env

    def seed_sessions(self, count):
        self.seed(
            *(
                {"session_id": f"sid-{i}", "modified_at": f"2026-01-{i:02d}"}
                for i in range(1, count + 1)
            )
        )

    def count_untagged(self):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(
                "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NULL"
            ).fetchone()[0]
        finally:
            conn.close()

    def run_on_pty(self, *args, **env):
        """Runs the script with a real terminal on stdout. Returns (code, stdout, stderr)."""
        master, slave = pty.openpty()
        child_env = self.child_env(**{"TERM": "xterm", "COLUMNS": "80", **env})
        with tempfile.TemporaryFile() as err:
            process = subprocess.Popen(
                [sys.executable, str(SCRIPT), *args],
                stdin=subprocess.DEVNULL,
                stdout=slave,
                stderr=err,
                env=child_env,
            )
            os.close(slave)
            chunks = []
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError:  # Linux reports the closed side as EIO, macOS as EOF.
                    break
                if not chunk:
                    break
                chunks.append(chunk)
            os.close(master)
            code = process.wait(timeout=120)
            err.seek(0)
            stderr = err.read().decode()
        return code, b"".join(chunks).decode().replace("\r\n", "\n"), stderr


class DryRunTests(ScriptCase, InProcessTestCase):
    def assert_no_write(self):
        self.assertEqual(self.count_untagged(), 1)
        self.assertFalse(tag.LOG_PATH.exists())

    def test_dry_run_with_a_key_says_regex_preview_and_makes_no_api_call(self):
        self.seed()
        with mock.patch.object(tag, "urlopen", side_effect=AssertionError) as urlopen:
            code, out, err = self.run_entry("--dry-run", key=MARKER_KEY)
        self.assertEqual(code, 0)
        urlopen.assert_not_called()
        self.assertIn("Mode: Regex preview (no API calls)", err)
        self.assertIn(
            "A real run would use Haiku; tags, summaries and aliases will differ.", err
        )
        self.assertNotIn("Haiku + Regex", out + err)
        self.assert_no_write()

    def test_the_real_run_warning_needs_a_key_and_no_regex_only(self):
        self.seed()
        _, _, without_key = self.run_entry("--dry-run")
        self.assertIn("Mode: Regex preview", without_key)
        self.assertNotIn("A real run", without_key)
        _, _, regex_only = self.run_entry("--dry-run", "--regex-only", key=MARKER_KEY)
        self.assertNotIn("A real run", regex_only)

    def test_retag_summaries_dry_run_with_no_key_still_exits_1(self):
        self.seed()
        code, out, err = self.run_entry("--retag-summaries", "--dry-run")
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("--retag-summaries requires Haiku API", err)

    def test_retag_summaries_dry_run_rows_name_the_request(self):
        self.seed(
            {"session_id": "sid-1"},
            {"session_id": "sid-2", "first_prompt": ""},
        )
        with mock.patch.object(tag, "urlopen", side_effect=AssertionError) as urlopen:
            code, out, err = self.run_entry(
                "--retag-summaries", "--dry-run", key=MARKER_KEY
            )
        self.assertEqual(code, 0)
        urlopen.assert_not_called()
        self.assertEqual(
            sorted(out.splitlines()),
            ["sid-1\twould request summary via Haiku", "sid-2\t-\tskip"],
        )
        self.assertIn(
            "Preview: 1 would request a summary, 1 no text; nothing written", err
        )
        self.assertNotIn(DISCLOSURE, err)


class PipedDryRunTests(ScriptCase):
    def test_piped_dry_run_lists_one_row_per_session(self):
        self.seed(
            {"session_id": "sid-1", "modified_at": "2026-01-02"},
            {
                "session_id": "sid-2",
                "modified_at": "2026-01-01",
                "first_prompt": NO_MATCH,
            },
        )
        tags = ",".join(tag.regex_tag("fix the login bug in the react component"))
        for env in ({}, {"FORCE_COLOR": "1"}):
            with self.subTest(env=env):
                result = self.run_script("--dry-run", **env)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(
                    result.stdout, f"sid-1\t{tags}\tregex\nsid-2\t-\tskip\n"
                )
                self.assertIn(
                    "Preview: 1 would be tagged, 1 no match; nothing written",
                    result.stderr,
                )
                self.assertNotIn("Done", result.stderr)
                self.assertNotIn("tagged=", result.stderr)

    def test_quiet_dry_run_stays_silent(self):
        self.seed()
        result = self.run_script("--dry-run", "--quiet")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_nothing_to_tag_leaves_stdout_empty(self):
        self.seed()
        self.assertEqual(self.run_script("--regex-only", "--quiet").returncode, 0)
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Nothing to tag.", result.stderr)

    def test_a_reader_that_goes_away_ends_a_dry_run_with_exit_0(self):
        # More rows than a pipe buffers, so the write really fails mid-run.
        self.seed(
            *(
                {"session_id": f"{FAKE_UUID}-{i}", "modified_at": f"{i:06d}"}
                for i in range(3000)
            )
        )
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--dry-run", "--limit", "3000"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=self.child_env(),
        )
        self.assertIn(FAKE_UUID, process.stdout.readline().decode())
        process.stdout.close()
        self.assertEqual(process.wait(timeout=120), 0)

    def test_dry_run_writes_no_log_line_and_does_not_take_the_lock(self):
        self.seed()
        lock_path = self.claude / "session-index.lock"
        with open(lock_path, "w") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.claude / "logs" / "session-index.log").exists())
        self.assertEqual(self.count_untagged(), 1)

    def test_dry_run_leaves_no_lock_file_and_no_wal_switch(self):
        self.seed()
        self.assertEqual(self.run_script("--dry-run").returncode, 0)
        self.assertFalse((self.claude / "session-index.lock").exists())
        conn = sqlite3.connect(self.db)
        try:
            mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(mode, "delete")

    def test_dry_run_never_says_tagged(self):
        self.seed()
        piped = self.run_script("--dry-run")
        self.assertNotIn("Tagged", piped.stdout + piped.stderr)
        _, out, err = self.run_on_pty("--dry-run")
        self.assertNotIn("Tagged", out + err)
        self.assertNotIn("Tagging", out + err)
        for code in RICH_CODES:
            self.assertNotIn(code, out)


class RealRunTests(ScriptCase):
    def test_real_run_output_is_unchanged(self):
        self.seed()
        result = self.run_script("--regex-only")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        banner, summary = result.stdout.rsplit("\n\n", 1)
        rule = "─" * 50
        self.assertEqual(
            banner,
            "\n"
            f"  ╭{rule}╮\n"
            f"  │  Session Tagger{' ' * 26}1 queued  │\n"
            f"  ╰{rule}╯\n"
            "\n"
            "  Mode: Regex-only  (no API key set)",
        )
        self.assertRegex(
            summary,
            r"\ATagged 1 of 1 session in [0-9.]+m?s: "
            r"tagged=1 failed=0 regex=1 haiku=0 summaries=\+0\n\Z",
        )
        self.assertIsNotNone(self.row()["tagged_at"])
        log = (self.claude / "logs" / "session-index.log").read_text()
        self.assertRegex(
            log,
            r"Tagging complete: 1 tagged, 0 failed, 0 summaries added "
            r"\([0-9.]+s\) \[regex=1 haiku=0\] \n\Z",
        )

    def test_failures_line_stays_on_a_piped_run(self):
        self.seed({"first_prompt": NO_MATCH})
        result = self.run_script("--regex-only")
        self.assertRegex(
            result.stdout,
            r"Tagged 0 of 1 session in [^:]+: tagged=0 failed=1 regex=0 haiku=0 "
            r"summaries=\+0\nFailures: no_match=1\n\Z",
        )


class ApiBoundTests(ScriptCase, InProcessTestCase):
    def test_sdk_client_is_bounded(self):
        client = mock.Mock()
        client.messages.create.return_value.content = [
            types.SimpleNamespace(text='{"tags": ["a-tag"]}')
        ]
        fake = types.SimpleNamespace(Anthropic=mock.Mock(return_value=client))
        with mock.patch.dict(sys.modules, {"anthropic": fake}):
            tag._haiku_call_sdk("sum", "prompt", "acme", MARKER_KEY)
        fake.Anthropic.assert_called_once_with(
            api_key=MARKER_KEY, timeout=30.0, max_retries=2
        )

    def test_deadline_skips_without_tagging(self):
        self.seed()
        self.patch(tag, "TOTAL_API_BUDGET_S", -1)
        with mock.patch.object(tag, "urlopen", side_effect=AssertionError) as urlopen:
            code, out, err = self.run_entry(key=MARKER_KEY)
        self.assertEqual(code, 0)
        urlopen.assert_not_called()
        row = self.row()
        self.assertIsNone(row["tagged_at"])
        self.assertEqual(row["tags"], "")
        self.assertIn("Failures: deadline=1", out)
        self.assertIn(
            "Processed 0 of 1 untagged sessions. 1 still untagged "
            "(0 failed, 1 not attempted).",
            err,
        )

    def test_a_session_past_the_deadline_is_not_sent_to_regex(self):
        row = {"session_id": "sid-1", "first_prompt": "fix the login bug"}
        result = tag.process_session(row, MARKER_KEY, False, time.monotonic() - 1)
        self.assertEqual(
            (result.tags, result.method, result.error_category, result.success),
            ([], "skip", "deadline", False),
        )

    def call_urllib(self, urlopen, **kwargs):
        with (
            mock.patch.object(tag, "urlopen", urlopen),
            mock.patch.object(tag.time, "sleep") as sleep,
        ):
            result = tag.haiku_tag("sum", "prompt", "acme", MARKER_KEY, **kwargs)
        return result[2], sleep

    def test_urllib_retries_429_honouring_retry_after(self):
        urlopen = mock.Mock(
            side_effect=[http_error(429, "7"), http_error(529, "2"), good_response()]
        )
        on_retry = mock.Mock()
        reason, sleep = self.call_urllib(urlopen, on_retry=on_retry)
        self.assertEqual(reason, "haiku")
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual([c.args[0] for c in sleep.call_args_list], [7.0, 2.0])
        self.assertEqual(on_retry.call_count, 2)

    def test_retry_after_is_capped_and_a_bad_value_backs_off(self):
        for header, low, high in (
            ("900", 60.0, 60.0),
            ("soon", 1.0, 2.0),
            ("nan", 1.0, 2.0),
            ("-3", 1.0, 2.0),
            (None, 1.0, 2.0),
        ):
            with self.subTest(header=header):
                urlopen = mock.Mock(
                    side_effect=[http_error(429, header), good_response()]
                )
                _, sleep = self.call_urllib(urlopen)
                self.assertTrue(low <= sleep.call_args.args[0] <= high)

    def test_retries_stop_after_two(self):
        urlopen = mock.Mock(side_effect=http_error(429, "0"))
        reason, sleep = self.call_urllib(urlopen)
        self.assertEqual(reason, "api_rate_limited")
        self.assertEqual(urlopen.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_a_retry_never_waits_past_the_deadline(self):
        urlopen = mock.Mock(side_effect=http_error(429, "30"))
        reason, sleep = self.call_urllib(urlopen, deadline=time.monotonic() + 1)
        self.assertEqual(reason, "api_rate_limited")
        urlopen.assert_called_once()
        sleep.assert_not_called()

    def test_urllib_does_not_retry_500(self):
        for code, expected in (
            (500, "api_error"),
            (401, "api_auth"),
            (403, "api_auth"),
        ):
            with self.subTest(code=code):
                urlopen = mock.Mock(side_effect=http_error(code))
                reason, sleep = self.call_urllib(urlopen)
                self.assertEqual(reason, expected)
                urlopen.assert_called_once()
                sleep.assert_not_called()

    def test_sdk_status_errors_map_the_same_way(self):
        for status, expected in (
            (429, "api_rate_limited"),
            (401, "api_auth"),
            (500, "api_error"),
        ):
            with self.subTest(status=status):
                exc = RuntimeError("sdk")
                exc.status_code = status
                self.patch(tag, "_has_anthropic_sdk", lambda: True)
                with mock.patch.object(tag, "_haiku_call_sdk", side_effect=exc):
                    result = tag.haiku_tag("sum", "prompt", "acme", MARKER_KEY)
                self.assertEqual(result[2], expected)

    def rate_limited_then_fine(self):
        calls = itertools.count()

        def urlopen(*_args, **_kwargs):
            if next(calls) < 2:
                raise http_error(429, "0")
            return good_response()

        return urlopen

    def test_the_retry_note_prints_once(self):
        self.seed_sessions(2)
        with mock.patch.object(tag, "urlopen", self.rate_limited_then_fine()):
            code, _, err = self.run_entry(key=MARKER_KEY)
        self.assertEqual(code, 0)
        self.assertEqual(err.count("Retrying automatically…"), 1)

    def test_quiet_has_no_retry_note(self):
        self.seed_sessions(2)
        with mock.patch.object(tag, "urlopen", self.rate_limited_then_fine()):
            code, _, err = self.run_entry("--quiet", key=MARKER_KEY)
        self.assertEqual(code, 0)
        self.assertNotIn("Retrying", err)

    def test_fallback_reason_is_counted(self):
        self.seed()
        with mock.patch.object(tag, "urlopen", side_effect=http_error(401)):
            code, out, err = self.run_entry(key=MARKER_KEY)
        self.assertEqual(code, 0)
        self.assertIsNotNone(self.row()["tagged_at"])
        self.assertIn("tagged=1 failed=0 regex=1", out)
        self.assertIn(
            "1 session fell back to regex after an API failure: api_auth=1", err
        )
        self.assertIn("fallback: api_auth=1", tag.LOG_PATH.read_text())

    def test_a_failure_with_no_regex_match_keeps_its_reason(self):
        self.seed({"first_prompt": NO_MATCH})
        with mock.patch.object(tag, "urlopen", side_effect=http_error(500)):
            _, out, err = self.run_entry(key=MARKER_KEY)
        self.assertIn("Failures: api_error=1", out)
        self.assertIn("api_error=1", err)

    def test_the_dashboard_counts_a_fallback_even_when_regex_succeeded(self):
        board = tag.Dashboard(2, True)
        board.update("sid-1", "regex", "a", True, "api_error")
        board.update("sid-2", "regex", "a", True)
        self.assertEqual(board.error_count, 1)


class CappedBatchTests(ScriptCase, InProcessTestCase):
    def test_retag_keeps_its_flag_and_group_in_the_next_step(self):
        self.seed_sessions(3)
        with mock.patch.object(tag, "urlopen", api_reply(tags=["a-tag"], summary="S")):
            code, _, err = self.run_entry(
                "--retag-summaries", "--limit", "1", key=MARKER_KEY
            )
        self.assertEqual(code, 0)
        self.assertIn(
            "Processed 1 of 3 sessions with no summary. 2 still without one "
            "(0 failed, 2 not attempted).",
            err,
        )
        self.assertIn(
            f"    {shlex.join(['python3', str(SCRIPT), '--retag-summaries', '--limit', '2'])}\n",
            err,
        )

    def test_a_retag_success_with_no_summary_is_not_called_not_attempted(self):
        self.seed_sessions(3)
        with mock.patch.object(tag, "urlopen", api_reply(tags=["a-tag"])):
            _, _, err = self.run_entry(
                "--retag-summaries", "--limit", "1", key=MARKER_KEY
            )
        self.assertIn("3 still without one (1 failed, 2 not attempted).", err)


class CappedScriptTests(ScriptCase):
    def rerun_line(self, stderr):
        return stderr.splitlines()[-1]

    def test_a_capped_run_prints_the_remainder_and_an_exact_command(self):
        self.seed_sessions(5)
        result = self.run_script("--regex-only", "--limit", "2")
        self.assertEqual(result.returncode, 0)
        self.assertIn("2 of 5 queued", result.stdout)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "Processed 2 of 5 untagged sessions. 3 still untagged "
                "(0 failed, 3 not attempted).",
                f"    python3 {SCRIPT} --regex-only --limit 3",
            ],
        )

    def test_failed_rows_are_counted_from_the_database(self):
        self.seed(
            {
                "session_id": "sid-1",
                "modified_at": "2026-01-03",
                "first_prompt": NO_MATCH,
            },
            {"session_id": "sid-2", "modified_at": "2026-01-02"},
            {"session_id": "sid-3", "modified_at": "2026-01-01"},
        )
        result = self.run_script("--regex-only", "--limit", "2")
        self.assertIn(
            "Processed 2 of 3 untagged sessions. 2 still untagged "
            "(1 failed, 1 not attempted).",
            result.stderr,
        )
        self.assertTrue(self.rerun_line(result.stderr).endswith("--limit 2"))

    def test_an_uncapped_run_prints_no_rerun_line(self):
        self.seed_sessions(2)
        result = self.run_script("--regex-only", "--limit", "2")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertIn("2 queued", result.stdout)
        self.assertNotIn(" of 2 queued", result.stdout)

    def test_quiet_stays_silent_on_a_capped_run(self):
        self.seed_sessions(5)
        result = self.run_script("--regex-only", "--limit", "2", "--quiet")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_the_rerun_command_parses(self):
        self.seed(
            *(
                {
                    "session_id": f"sid-{i}",
                    "project_name": "two words",
                    "modified_at": f"2026-01-0{i}",
                }
                for i in range(1, 4)
            )
        )
        result = self.run_script(
            "--project", "two words", "--regex-only", "--limit", "1"
        )
        argv = shlex.split(self.rerun_line(result.stderr))
        self.assertEqual(argv[:2], ["python3", str(SCRIPT.resolve())])
        args = tag.build_parser().parse_args(argv[2:])
        self.assertEqual(args.project, "two words")
        self.assertTrue(args.regex_only)
        self.assertEqual(args.limit, 2)

    def test_the_rerun_command_finishes_the_work(self):
        self.seed_sessions(5)
        result = self.run_script("--regex-only", "--limit", "2")
        argv = shlex.split(self.rerun_line(result.stderr))
        again = subprocess.run(
            [sys.executable, *argv[1:]],
            capture_output=True,
            text=True,
            timeout=120,
            stdin=subprocess.DEVNULL,
            env=self.child_env(),
        )
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(again.stderr, "")
        self.assertEqual(self.count_untagged(), 0)

    def test_a_capped_dry_run_says_previewed_and_drops_the_flag(self):
        self.seed_sessions(3)
        result = self.run_script("--dry-run", "--regex-only", "--limit", "1")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertIn(
            "Previewed 1 of 3 untagged sessions. 3 still untagged "
            "(0 failed, 3 not attempted).",
            result.stderr,
        )
        line = self.rerun_line(result.stderr)
        self.assertNotIn("--dry-run", line)
        self.assertTrue(line.endswith("--limit 3"))


class StyleTests(ScriptCase):
    def test_no_color_removes_colour_not_the_dashboard(self):
        self.seed()
        code, out, _ = self.run_on_pty("--regex-only", NO_COLOR="1")
        self.assertEqual(code, 0)
        self.assertIn("Tagging", out)
        self.assertIn(tag.HIDE_CURSOR, out)
        self.assertIn(tag.SHOW_CURSOR, out)
        for colour in COLOUR_CODES:
            self.assertNotIn(colour, out)

    def test_a_terminal_gets_colour_and_the_dashboard(self):
        self.seed()
        code, out, _ = self.run_on_pty("--regex-only")
        self.assertEqual(code, 0)
        self.assertIn("Tagging", out)
        self.assertIn(tag.GREEN, out)
        self.assertIn(
            "\x1b[7A\x1b[J", out
        )  # finalize clears the block before the summary
        self.assertRegex(out, r"Tagged 1 of 1 session in ")
        self.assertIn("  Mode            ", tag._ANSI_RE.sub("", out))

    def test_term_dumb_has_no_cursor_codes(self):
        self.seed()
        code, out, _ = self.run_on_pty("--regex-only", TERM="dumb")
        self.assertEqual(code, 0)
        self.assertNotIn("\x1b", out)
        self.assertNotIn("Tagging", out)
        self.assertRegex(out, r"Tagged 1 of 1 session in [^:]+: tagged=1")

    def test_force_color_never_starts_the_dashboard_in_a_pipe(self):
        self.seed()
        result = self.run_script("--regex-only", FORCE_COLOR="1")
        self.assertEqual(result.returncode, 0)
        self.assertIn(tag.BOLD, result.stdout)
        self.assertNotIn("Tagging", result.stdout)
        self.assertNotIn(tag.HIDE_CURSOR, result.stdout)
        self.assertRegex(result.stdout, r"Tagged 1 of 1 session in [^:]+: tagged=1")

    def test_accessible_mode_gets_the_plain_layout(self):
        self.seed()
        code, out, _ = self.run_on_pty("--regex-only", SESSION_SEARCH_ACCESSIBLE="1")
        self.assertEqual(code, 0)
        self.assertNotIn(tag.HIDE_CURSOR, out)
        self.assertRegex(out, r"Tagged 1 of 1 session in [^:]+: tagged=1")

    def test_no_bright_black_is_ever_written(self):
        self.seed()
        _, out, _ = self.run_on_pty("--regex-only")
        self.assertNotIn("\x1b[90m", out)

    def test_no_color_works_though_constants_load_early(self):
        with (
            mock.patch.object(tag, "IS_TTY", True),
            mock.patch.dict(os.environ, {"TERM": "xterm", "FORCE_COLOR": "1"}),
        ):
            flagged = tag.stdout_palette(no_color=True)
            default = tag.stdout_palette()
        self.assertEqual(flagged.bold + flagged.green + flagged.reset, "")
        self.assertTrue(flagged.rich)
        self.assertEqual(default.bold, tag.BOLD)

    def test_no_color_reaches_a_palette_for_stderr_too(self):
        with mock.patch.dict(os.environ, {"FORCE_COLOR": "1"}):
            self.assertEqual(tag.stderr_palette(no_color=True).bold, "")

    def test_rich_mode_rows_share_the_gutter(self):
        lines = self.summary(1, 0, rich=True, colour=False).splitlines()
        self.assertEqual(lines[0], "")
        self.assertTrue(lines[1].startswith("✓ Tagged 1 of 1 session in "))
        for line, label in zip(
            lines[2:], ("Tagged", "Failed", "Method", "Failures", "Summaries")
        ):
            self.assertTrue(line.startswith(f"  {label:<16}"), line)
            self.assertNotEqual(line[16:18].strip(), label)

    def summary(self, tagged, failed, rich=True, colour=True, elapsed=1.0, **kwargs):
        out = io.StringIO()
        palette = tag.Palette(cli_common.Style(colour=colour, rich=rich))
        with contextlib.redirect_stdout(out):
            tag.print_summary_box(
                elapsed,
                tagged,
                failed,
                tagged + failed,
                0,
                tagged,
                kwargs.pop("summaries", 0),
                {"no_match": failed} if failed else {},
                palette=palette,
                **kwargs,
            )
        return out.getvalue()

    def test_failures_remove_the_green_outcome(self):
        self.assertIn(tag.GREEN, self.summary(1, 0))
        with_failure = self.summary(1, 1)
        self.assertNotIn(tag.GREEN, with_failure)
        self.assertIn("! ", tag._ANSI_RE.sub("", with_failure))

    def test_a_retag_that_added_nothing_is_not_green(self):
        self.assertNotIn(tag.GREEN, self.summary(1, 0, retag_summaries=True))
        self.assertIn(tag.GREEN, self.summary(1, 0, retag_summaries=True, summaries=1))

    def test_outcome_per_mode_and_fmt_duration(self):
        plain = {"rich": False, "colour": False, "elapsed": 243.0}
        self.assertTrue(
            self.summary(80, 20, **plain).startswith(
                "Tagged 80 of 100 sessions in 4m 3s: tagged=80 failed=20 "
            )
        )
        self.assertTrue(
            self.summary(1, 0, retag_summaries=True, summaries=1, **plain).startswith(
                "Added 1 summary in 4m 3s: "
            )
        )
        self.assertTrue(
            self.summary(3, 0, retag_summaries=True, summaries=2, **plain).startswith(
                "Added 2 summaries in 4m 3s: "
            )
        )


class DashboardFitTests(InProcessTestCase):
    def drawn_lines(self, sid, tags, columns, total=1):
        self.patch(tag, "IS_TTY", True)
        out = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"COLUMNS": str(columns), "TERM": "xterm"}),
            contextlib.redirect_stdout(out),
        ):
            board = tag.Dashboard(total, False)
            for _ in range(total):
                board.update(sid, "regex", tags, True)
        return out.getvalue()

    def current_line(self, text):
        return next(
            tag._ANSI_RE.sub("", line)
            for line in text.splitlines()
            if "Current:" in line
        )

    def test_a_long_id_is_never_cut_at_80_columns(self):
        line = self.current_line(self.drawn_lines(FAKE_UUID, "tag," * 40, 80))
        self.assertIn(FAKE_UUID, line)
        self.assertLessEqual(len(line), 80)
        self.assertTrue(line.endswith("…"))
        self.assertIn("[regex] → tag,", line)

    def test_short_tags_are_not_shortened(self):
        line = self.current_line(self.drawn_lines(FAKE_UUID, "a-tag,b-tag", 80))
        self.assertTrue(line.endswith("→ a-tag,b-tag"))

    def test_when_the_id_alone_fits_tags_and_method_go(self):
        line = self.current_line(self.drawn_lines(FAKE_UUID, "tag," * 40, 50))
        self.assertEqual(line, f"  Current: {FAKE_UUID}")

    def test_an_id_wider_than_the_terminal_stays_whole(self):
        long_id = "x" * 100
        line = self.current_line(self.drawn_lines(long_id, "a-tag", 80))
        self.assertEqual(line, f"  Current: {long_id}")

    def test_a_wrapped_line_counts_in_the_cursor_climb(self):
        text = self.drawn_lines("x" * 70, "a-tag", 60, total=2)
        self.assertIn("\x1b[8A", text)
        self.assertNotIn("\x1b[7A", text)

    def test_the_block_climbs_its_own_height_when_nothing_wraps(self):
        self.assertIn("\x1b[7A", self.drawn_lines(FAKE_UUID, "a-tag", 80, total=2))

    def test_eta_goes_through_fmt_duration(self):
        self.patch(tag, "IS_TTY", True)
        out = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"COLUMNS": "80", "TERM": "xterm"}),
            contextlib.redirect_stdout(out),
        ):
            board = tag.Dashboard(100, False)
            board.start_time = time.monotonic() - 3.0
            board.update("sid-1", "regex", "a", True)
        self.assertRegex(out.getvalue(), r"ETA ~\d+m \d+s")


class DisclosureTests(ScriptCase, InProcessTestCase):
    def run_with_reply(self, *args):
        self.seed()
        with mock.patch.object(tag, "urlopen", api_reply(tags=["a-tag"])) as urlopen:
            result = self.run_entry(*args, key=MARKER_KEY)
        return (*result, urlopen)

    def test_a_key_and_quiet_still_disclose_on_stderr(self):
        code, out, err, _ = self.run_with_reply("--quiet")
        self.assertEqual(code, 0)
        self.assertEqual(out, "")
        # startswith: a lock file left by an earlier in-process run may warn when collected.
        self.assertTrue(err.startswith(f"{DISCLOSURE}\n"), err)
        self.assertEqual(err.count(DISCLOSURE), 1)
        self.assertIsNotNone(self.row()["tagged_at"])

    def test_the_disclosure_comes_before_any_send(self):
        self.seed()
        written = io.StringIO()

        def urlopen(*_args, **_kwargs):
            written.write(sys.stderr.getvalue())
            return good_response()

        with mock.patch.object(tag, "urlopen", urlopen):
            self.run_entry("--quiet", key=MARKER_KEY)
        self.assertIn(DISCLOSURE, written.getvalue())

    def test_regex_only_does_not_disclose(self):
        code, _, err, urlopen = self.run_with_reply("--regex-only")
        self.assertEqual(code, 0)
        self.assertNotIn("api.anthropic.com", err)
        urlopen.assert_not_called()

    def test_dry_run_does_not_disclose(self):
        code, _, err, urlopen = self.run_with_reply("--dry-run")
        self.assertEqual(code, 0)
        self.assertNotIn("api.anthropic.com", err)
        urlopen.assert_not_called()

    def test_no_key_does_not_disclose(self):
        self.seed()
        code, _, err = self.run_entry()
        self.assertEqual(code, 0)
        self.assertNotIn("api.anthropic.com", err)

    def test_nothing_to_send_does_not_disclose(self):
        code, _, err = self.run_entry_on_empty_batch()
        self.assertEqual(code, 0)
        self.assertNotIn("api.anthropic.com", err)

    def run_entry_on_empty_batch(self):
        self.seed()
        self.run_entry("--regex-only", "--quiet")
        return self.run_entry(key=MARKER_KEY)


class SymlinkTests(ScriptCase):
    def link(self):
        bin_dir = self.claude / "bin"
        bin_dir.mkdir()
        path = bin_dir / "session-index-tag.py"
        path.symlink_to(SCRIPT)
        return path

    def test_install_argv_stays_silent_through_the_symlink(self):
        self.seed()
        result = self.run_script(
            "--regex-only", "--limit", "1000", "--quiet", script=self.link()
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assertIsNotNone(self.row()["tagged_at"])

    def test_the_reporting_paths_run_through_the_symlink(self):
        self.seed_sessions(3)
        link = self.link()
        preview = self.run_script("--dry-run", "--limit", "1", script=link)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(len(preview.stdout.splitlines()), 1)
        real = self.run_script("--regex-only", "--limit", "1", script=link)
        self.assertEqual(real.returncode, 0, real.stderr)
        # The next step names the real file, since the link is only an install detail.
        self.assertIn(f"python3 {SCRIPT.resolve()} --regex-only --limit 2", real.stderr)
        self.assertNotRegex(real.stderr, re.escape(str(link)))


if __name__ == "__main__":
    unittest.main()
