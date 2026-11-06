"""CLI contract of scripts/session-index-chunk.py, always against a sandbox HOME."""

import contextlib
import importlib.util
import io
import json
import os
import re
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "session-index-chunk.py"
MODULE_NAME = "session_index_chunk_under_test"

SID_A = "aaaaaaaa-0000-4000-8000-000000000001"
SID_B = "bbbbbbbb-0000-4000-8000-000000000002"


def load_module():
    if MODULE_NAME in sys.modules:
        return sys.modules[MODULE_NAME]
    spec = importlib.util.spec_from_file_location(MODULE_NAME, SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[MODULE_NAME] = module
    spec.loader.exec_module(module)
    return module


chunk = load_module()


def turn_lines(turns=6, text="hello there, this is turn"):
    lines = []
    for i in range(turns):
        lines.append(
            json.dumps({"type": "user", "message": {"content": f"{text} {i}"}})
        )
        lines.append(
            json.dumps(
                {
                    "type": "assistant",
                    "message": {"content": [{"type": "text", "text": f"reply {i}"}]},
                }
            )
        )
    return lines


class Sandbox(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.claude = self.home / ".claude"
        self.claude.mkdir()
        self.projects = self.claude / "projects"
        self.project = self.projects / "proj"
        self.project.mkdir(parents=True)
        self.db = self.claude / "session-index.db"
        with contextlib.closing(sqlite3.connect(self.db)) as conn:
            conn.execute("CREATE TABLE sessions (session_id TEXT)")
            conn.commit()

    def env(self, **extra):
        drop = ("CI", "CLAUDECODE", "NO_COLOR", "FORCE_COLOR", "TERM", "PYTHONPATH")
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in drop and not key.lstrip("_").startswith("SESSION_SEARCH_")
        }
        return {
            **env,
            "HOME": str(self.home),
            "PYTHONDONTWRITEBYTECODE": "1",
            **extra,
        }

    def run_script(self, *args, env=None, script=SCRIPT, **kwargs):
        kwargs.setdefault("stdout", subprocess.PIPE)
        return subprocess.run(
            [sys.executable, str(script), *args],
            env=self.env(**(env or {})),
            cwd=self.home,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
            **kwargs,
        )

    def call_main(self, *args, patches=None, env=None):
        """Run main() through run_cli in this process, for faults a subprocess can't inject."""
        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.dict(os.environ, self.env(**(env or {})), clear=True),
            mock.patch.object(sys, "argv", [chunk.PROG, *args]),
            mock.patch.object(chunk, "DB_PATH", self.db),
            mock.patch.object(chunk, "PROJECTS_DIR", self.projects),
            mock.patch.multiple(chunk, **(patches or {})),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
            self.assertRaises(SystemExit) as caught,
        ):
            chunk.cli_common.run_cli(chunk.main, chunk.PROG)
        return caught.exception.code, out.getvalue(), err.getvalue()

    def flat(self, sid, lines=None):
        path = self.project / f"{sid}.jsonl"
        path.write_text("\n".join(turn_lines() if lines is None else lines) + "\n")
        return path

    def nested(self, sid, lines=None):
        path = self.project / sid / "transcript.jsonl"
        path.parent.mkdir()
        path.write_text("\n".join(turn_lines() if lines is None else lines) + "\n")
        return path

    def rows(self, sid=None):
        with contextlib.closing(sqlite3.connect(self.db)) as conn:
            tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master")}
            if "session_chunks" not in tables:
                return []
            query = "SELECT chunk_id, user_text FROM session_chunks"
            params = ()
            if sid:
                query += " WHERE session_id = ?"
                params = (sid,)
            return conn.execute(query + " ORDER BY chunk_id", params).fetchall()

    def fts_rows(self, sid):
        with contextlib.closing(sqlite3.connect(self.db)) as conn:
            return conn.execute(
                "SELECT chunk_id FROM chunks_fts WHERE session_id = ?", (sid,)
            ).fetchall()


class SessionIdValidation(Sandbox):
    def test_bad_session_id_exits_2_and_adds_no_rows(self):
        before = self.db.read_bytes()
        for bad in ("not-a-uuid", "../../evil", SID_A + "\n", SID_A.upper()):
            with self.subTest(bad=bad):
                path = self.flat("placeholder")
                result = self.run_script(bad, "--transcript", str(path))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("session ID", result.stderr)
                self.assertEqual(self.db.read_bytes(), before)

    def test_bad_session_id_is_checked_before_the_database(self):
        self.db.unlink()
        result = self.run_script("nope", "--transcript", "x.jsonl")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Database not found", result.stderr)

    def test_id_and_transcript_name_must_agree(self):
        before = self.db.read_bytes()
        flat = self.flat(SID_B)
        nested = self.nested(SID_B)
        other = self.home / "notes.txt"
        other.write_text("x")
        for path in (flat, nested, other):
            with self.subTest(path=path):
                result = self.run_script(SID_A, "--transcript", str(path))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(SID_A, result.stderr)
                self.assertIn(path.name, result.stderr)
                self.assertEqual(self.db.read_bytes(), before)

    def test_both_valid_layouts_chunk(self):
        flat = self.flat(SID_A)
        nested = self.nested(SID_B)
        self.assertEqual(
            self.run_script(SID_A, "--transcript", str(flat)).returncode, 0
        )
        self.assertEqual(
            self.run_script(SID_B, "--transcript", str(nested)).returncode, 0
        )
        self.assertTrue(self.rows(SID_A))
        self.assertTrue(self.rows(SID_B))

    def test_the_name_check_does_not_resolve_symlinks(self):
        target = self.flat(SID_B)
        link = self.home / f"{SID_A}.jsonl"
        link.symlink_to(target)
        self.assertEqual(
            self.run_script(SID_A, "--transcript", str(link)).returncode, 0
        )
        self.assertTrue(self.rows(SID_A))


class PerItemFailures(Sandbox):
    def test_one_unreadable_transcript_does_not_stop_the_batch(self):
        # A directory is unreadable as a file for every user, root included.
        (self.project / f"{SID_A}.jsonl").mkdir()
        self.flat(SID_B)
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{SID_A}.jsonl", result.stderr)
        self.assertTrue(self.rows(SID_B))
        self.assertEqual(result.stdout, "Chunked 1 sessions -> 2 chunks\n")
        self.assertIn("1 succeeded, 0 skipped, 1 failed", result.stderr)

    def test_one_unreadable_transcript_fails_the_single_form_without_a_line(self):
        path = self.project / f"{SID_A}.jsonl"
        path.mkdir()
        result = self.run_script(SID_A, "--transcript", str(path))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn(path.name, result.stderr)

    def test_a_non_object_json_line_is_counted_not_fatal(self):
        self.flat(SID_A, ["[1, 2]", "42", "{broken", *turn_lines()])
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.rows(SID_A))
        self.assertIn("3 malformed lines", result.stderr)

    def test_a_wrongly_shaped_record_fails_that_session_only(self):
        bad = {"type": "assistant", "message": "not an object"}
        self.flat(SID_A, [*turn_lines(), json.dumps(bad)])
        self.flat(SID_B)
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.rows(SID_A), [])
        self.assertTrue(self.rows(SID_B))
        self.assertIn(f"{SID_A}.jsonl", result.stderr)

    def test_failure_rolls_back_so_old_chunks_stay(self):
        path = self.flat(SID_A)
        good = self.flat(SID_B)
        self.assertEqual(self.run_script("--backfill").returncode, 0)
        old_rows, old_fts = self.rows(SID_A), self.fts_rows(SID_A)
        self.assertTrue(old_rows)

        # json.loads yields a lone surrogate, which SQLite refuses at the INSERT, after the
        # DELETE. A good session right behind it would commit a delete nothing rolled back.
        self.flat(SID_A, turn_lines(text="lone surrogate \ud800 here"))
        ordered = [(SID_A, path), (SID_B, good)]
        code, _, err = self.call_main(
            "--backfill", patches={"_discover": lambda cutoff, stats: ordered}
        )
        self.assertEqual(code, 1, err)
        self.assertIn(path.name, err)
        self.assertEqual(self.rows(SID_A), old_rows)
        self.assertEqual(self.fts_rows(SID_A), old_fts)

    def test_a_database_error_stops_the_batch_and_reports_the_rest(self):
        ordered = [
            (SID_A, self.flat(SID_A)),
            (SID_B, self.flat(SID_B)),
        ]
        store = mock.Mock(side_effect=sqlite3.OperationalError("database is locked"))
        code, out, err = self.call_main(
            "--backfill",
            patches={"_discover": lambda cutoff, stats: ordered, "store_chunks": store},
        )
        self.assertEqual(code, 1)
        self.assertEqual(store.call_count, 1)
        self.assertIn("0 succeeded, 0 skipped, 1 failed, 1 not attempted", err)
        self.assertIn("re-running is safe", err)
        self.assertEqual(out, "Chunked 0 sessions -> 0 chunks\n")

    def test_missing_projects_dir_exits_0(self):
        self.project.rmdir()
        self.projects.rmdir()
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("projects dir not found: nothing to chunk", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_short_session_stays_exit_0(self):
        self.flat(SID_A, turn_lines(turns=chunk.MIN_TURNS - 1))
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rows(SID_A), [])
        self.assertIn("0 succeeded, 1 skipped, 0 failed", result.stderr)

    def test_oversize_transcript_stays_exit_0(self):
        path = self.project / f"{SID_A}.jsonl"
        with path.open("wb") as handle:
            handle.truncate(chunk.MAX_TRANSCRIPT_BYTES + 1)
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 succeeded, 1 skipped, 0 failed", result.stderr)

    def test_truncation_at_max_chunks_stays_exit_0(self):
        self.flat(SID_A, turn_lines(turns=chunk.MAX_CHUNKS * chunk.STRIDE + 20))
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.rows(SID_A)), chunk.MAX_CHUNKS)
        self.assertIn("1 truncated session", result.stderr)

    def test_transcript_reads_as_utf_8_under_lc_all_c(self):
        lines = [
            json.dumps(
                {"type": "user", "message": {"content": f"café turn {i:04}"}},
                ensure_ascii=False,
            )
            for i in range(6)
        ]
        path = self.project / f"{SID_A}.jsonl"
        data = "\n".join(lines).encode("utf-8")
        path.write_bytes(data + b"\n\xff\xfe not utf-8 at all\n")
        result = self.run_script(
            SID_A,
            "--transcript",
            str(path),
            env={"LC_ALL": "C", "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("café", self.rows(SID_A)[0][1])

    def test_internal_error_shows_no_traceback(self):
        boom = mock.Mock(side_effect=RuntimeError("boom"))
        code, _, err = self.call_main("--backfill", patches={"backfill": boom})
        self.assertEqual(code, 1)
        self.assertNotIn("Traceback", err)
        self.assertIn("RuntimeError", err)

    def test_debug_shows_the_traceback(self):
        boom = mock.Mock(side_effect=RuntimeError("boom"))
        code, _, err = self.call_main(
            "--backfill", "--debug", patches={"backfill": boom}
        )
        self.assertEqual(code, 1)
        self.assertIn("Traceback", err)

    def test_corrupt_database_exits_1_without_a_traceback(self):
        self.db.write_bytes(b"this is not a database, " * 100)
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)

    def _run_with_closed_stdout(self, *args):
        read_end, write_end = os.pipe()
        os.close(read_end)
        try:
            return self.run_script(*args, stdout=write_end)
        finally:
            os.close(write_end)

    def test_a_closed_stdout_keeps_a_successful_outcome(self):
        self.flat(SID_A)
        result = self._run_with_closed_stdout("--backfill")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertTrue(self.rows(SID_A))

    def test_a_closed_stdout_keeps_a_failed_outcome(self):
        (self.project / f"{SID_A}.jsonl").mkdir()
        result = self._run_with_closed_stdout("--backfill")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)


class ParserAndHelp(Sandbox):
    def test_abbreviations_are_rejected(self):
        self.assertEqual(self.run_script("--back").returncode, 2)

    def test_session_and_transcript_option_work_in_either_order(self):
        path = self.flat(SID_A)
        first = self.run_script(SID_A, "--transcript", str(path))
        second = self.run_script("--transcript", str(path), SID_A)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout, f"Generated 2 chunks for {SID_A}\n")
        self.assertEqual(second.stdout, first.stdout)
        self.assertNotIn("deprecated", first.stderr)

    def test_both_transcript_forms_exit_2(self):
        path = self.flat(SID_A)
        result = self.run_script(SID_A, str(path), "--transcript", str(path))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.rows(), [])

    def test_the_positional_transcript_warns_once(self):
        path = self.flat(SID_A)
        result = self.run_script(SID_A, str(path))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr.count("deprecated"), 1)
        self.assertIn("Warning:", result.stderr)
        self.assertIn("--transcript", result.stderr)
        self.assertEqual(result.stdout, f"Generated 2 chunks for {SID_A}\n")

    def test_every_help_example_parses(self):
        parser = chunk.build_parser()
        examples = [
            line.strip()
            for line in parser.format_help().splitlines()
            if line.strip().startswith(chunk.PROG + " ")
        ]
        self.assertEqual(len(examples), 2)
        for example in examples:
            with self.subTest(example=example):
                args = parser.parse_args(shlex.split(example)[1:])
                chunk.validate_args(parser, args)

    def test_help_states_the_limits_from_the_constants(self):
        text = self.run_script("--help").stdout
        self.assertIn("52.4 MB", text)
        self.assertIn(f"under {chunk.MIN_TURNS} turns", text)
        self.assertIn(f"at most {chunk.MAX_CHUNKS} chunks", text)
        self.assertIn("~/.claude/session-index.db", text)

    def test_exit_codes_block_lists_only_codes_the_script_produces(self):
        result = self.run_script("--help")
        self.assertEqual(result.returncode, 0)
        block = result.stdout.split("Exit codes:\n", 1)[1]
        named = {int(code) for code in re.findall(r"^\s+(\d+)\s", block, re.M)}
        self.assertEqual(named, {0, 1, 2, 130})

        self.assertEqual(self.run_script("--backfill").returncode, 0)
        self.assertEqual(self.run_script().returncode, 1)
        self.assertEqual(self.run_script("--nope").returncode, 2)
        interrupt = mock.Mock(side_effect=KeyboardInterrupt)
        code, _, _ = self.call_main("--backfill", patches={"backfill": interrupt})
        self.assertEqual(code, 130)

        self.db.unlink()
        self.assertEqual(self.run_script("--backfill").returncode, 1)


class SinceValue(Sandbox):
    def setUp(self):
        super().setUp()
        old = self.flat(SID_A)
        self.flat(SID_B)
        stamp = (datetime.now(timezone.utc) - timedelta(days=30)).timestamp()
        os.utime(old, (stamp, stamp))

    def chunked_ids(self, *args):
        result = self.run_script("--backfill", "--json", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {row["id"] for row in json.loads(result.stdout)["results"]}

    def test_whole_days_relative_and_iso_values(self):
        week_ago = datetime.now(timezone.utc) - timedelta(days=7)
        for value in (
            "7",
            "7d",
            "12h",
            week_ago.strftime("%Y-%m-%dT%H:%M:%SZ"),
            week_ago.strftime("%Y-%m-%dT%H:%M:%S"),
        ):
            with self.subTest(value=value):
                self.assertEqual(self.chunked_ids("--since", value), {SID_B})
                self.assertEqual(self.chunked_ids("-s", value), {SID_B})

    def test_a_naive_iso_value_reads_as_utc(self):
        expected = datetime(2026, 3, 1, 12, tzinfo=timezone.utc).timestamp()
        self.assertEqual(chunk._since_cutoff("2026-03-01T12:00:00"), expected)
        self.assertEqual(chunk._since_cutoff("2026-03-01T12:00:00Z"), expected)

    def test_garbage_exits_2(self):
        for value in ("soon", "7x", ""):
            with self.subTest(value=value):
                result = self.run_script("--backfill", "--since", value)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.rows(), [])

    def test_0_stays_no_cutoff_until_c8(self):
        self.assertEqual(self.chunked_ids("--since", "0"), {SID_A, SID_B})

    def test_a_negative_count_stays_a_future_cutoff_until_c8(self):
        self.assertEqual(self.chunked_ids("--since", "-3"), set())

    def test_backfills_call_shape_keeps_its_line_and_exit(self):
        result = self.run_script("--backfill", "--since", "7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Chunked 1 sessions -> 2 chunks\n")


class GlobalOptions(Sandbox):
    def test_json_one_session_is_one_document(self):
        path = self.flat(SID_A)
        result = self.run_script(SID_A, "--transcript", str(path), "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {"session": {"session_id": SID_A, "chunks": 2}, "outcome": "chunked"},
        )

    def test_json_one_session_reports_a_skip_and_a_failure(self):
        short = self.flat(SID_A, turn_lines(turns=1))
        skipped = self.run_script(SID_A, "--transcript", str(short), "--json")
        self.assertEqual(skipped.returncode, 0)
        doc = json.loads(skipped.stdout)
        self.assertEqual(doc["outcome"], "unchanged")
        self.assertEqual(doc["reason"], "short")

        broken = self.project / f"{SID_B}.jsonl"
        broken.mkdir()
        failed = self.run_script(SID_B, "--transcript", str(broken), "--json")
        self.assertEqual(failed.returncode, 1)
        doc = json.loads(failed.stdout)
        self.assertEqual(doc["outcome"], "failed")
        self.assertIn("error", doc)

    def test_json_backfill_is_a_results_and_summary_document(self):
        self.flat(SID_A)
        (self.project / f"{SID_B}.jsonl").write_text("{}\n")
        result = self.run_script("--backfill", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        doc = json.loads(result.stdout)
        self.assertEqual(
            doc["summary"], {"succeeded": 1, "failed": 0, "skipped": 1, "unknown": 0}
        )
        outcomes = {row["id"]: row["outcome"] for row in doc["results"]}
        self.assertEqual(outcomes, {SID_A: "chunked", SID_B: "skipped"})
        self.assertNotIn("succeeded,", result.stderr)

    def test_version_needs_no_db(self):
        self.db.unlink()
        result = self.run_script("--version")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, chunk.cli_common.VERSION + "\n")
        self.assertEqual(self.run_script("-v").stdout, result.stdout)
        as_json = self.run_script("--version", "--json")
        self.assertEqual(
            json.loads(as_json.stdout), {"version": chunk.cli_common.VERSION}
        )
        self.assertFalse(self.db.exists())

    def test_help_wins_over_version(self):
        for args in (("--help", "--version"), ("--version", "--help")):
            with self.subTest(args=args):
                result = self.run_script(*args)
                self.assertEqual(result.returncode, 0)
                self.assertIn("usage:", result.stdout)

    def test_the_symlinked_script_finds_the_shared_module(self):
        link = self.home / "session-index-chunk.py"
        link.symlink_to(SCRIPT)
        result = self.run_script("--version", script=link)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, chunk.cli_common.VERSION + "\n")

    def test_the_target_line_goes_to_stderr_only(self):
        path = self.flat(SID_A)
        everything = self.run_script("--backfill")
        self.assertEqual(everything.stdout, "Chunked 1 sessions -> 2 chunks\n")
        self.assertIn(
            f"session-index-chunk: rewriting chunks in {self.db}; "
            f"scope: all sessions under {self.projects}",
            everything.stderr,
        )
        windowed = self.run_script("--backfill", "--since", "2026-03-01T00:00:00Z")
        self.assertIn("changed since 2026-03-01T00:00:00Z", windowed.stderr)
        one = self.run_script(SID_A, "--transcript", str(path))
        self.assertEqual(one.stdout, f"Generated 2 chunks for {SID_A}\n")
        self.assertIn(f"scope: session {SID_A}", one.stderr)

    def test_bare_invocation_shows_help_with_no_db_write(self):
        before = self.db.read_bytes()
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage:", result.stdout)
        self.assertNotIn("rewriting chunks", result.stderr)
        self.assertEqual(self.db.read_bytes(), before)

    def test_missing_db_still_exits_1_with_its_message(self):
        self.db.unlink()
        result = self.run_script("--backfill")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Database not found: {self.db}", result.stderr)
        self.assertFalse(self.db.exists())

    def test_no_color_is_accepted_and_reaches_the_error_path(self):
        self.flat(SID_A)
        self.assertEqual(self.run_script("--backfill", "--no-color").returncode, 0)
        boom = mock.Mock(side_effect=RuntimeError("boom"))
        forced = {"FORCE_COLOR": "1"}
        _, _, tinted = self.call_main(
            "--backfill", patches={"backfill": boom}, env=forced
        )
        self.assertIn("\033[", tinted)
        _, _, plain = self.call_main(
            "--backfill", "--no-color", patches={"backfill": boom}, env=forced
        )
        self.assertNotIn("\033[", plain)


if __name__ == "__main__":
    unittest.main()
