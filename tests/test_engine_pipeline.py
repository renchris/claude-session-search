import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

from engine_loader import ENGINE_PATH, load_engine

engine = load_engine()

REPO = ENGINE_PATH.parent.parent
CACHE_NAME = ".last-search-results.json"


class RaisingConn:
    """Stands in for a connection whose every statement fails with one sqlite message."""

    def __init__(self, message: str) -> None:
        self.message = message

    def execute(self, *_args: Any) -> None:
        raise sqlite3.OperationalError(self.message)

    def close(self) -> None:
        pass


class PipelineCase(unittest.TestCase):
    """Each test gets its own copy of the demo DB, built once, and no route to the LLM fallback."""

    template_dir: tempfile.TemporaryDirectory
    template: Path

    @classmethod
    def setUpClass(cls) -> None:
        cls.template_dir = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.template_dir.cleanup)
        cls.template = Path(cls.template_dir.name) / "demo.db"
        subprocess.run(
            [
                sys.executable,
                str(REPO / "assets" / "demo" / "build_demo_db.py"),
                str(cls.template),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.db = self.dir / "session-index.db"
        shutil.copy(self.template, self.db)
        env = mock.patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("ANTHROPIC_API_KEY", None)
        warnings = mock.patch.object(engine, "WARNINGS", [])
        warnings.start()
        self.addCleanup(warnings.stop)
        self.pipeline = engine.QueryPipeline(self.db)
        self.addCleanup(self.pipeline.close)

    def sql(self, statement: str) -> None:
        conn = sqlite3.connect(self.db)
        try:
            conn.execute(statement)
            conn.commit()
        finally:
            conn.close()

    def with_failing_conn(self, message: str) -> None:
        self.pipeline.conn = RaisingConn(message)


class FailuresAreNotEmptyResults(PipelineCase):
    def test_broken_index_raises_not_empty(self) -> None:
        self.sql("DROP TABLE sessions_fts")
        with self.assertRaises(sqlite3.OperationalError) as caught:
            self.pipeline.search("rum")
        self.assertIn("sessions_fts", str(caught.exception))

    def test_fts_syntax_error_falls_through(self) -> None:
        self.assertIsInstance(self.pipeline.search('"rum'), list)

    def test_query_text_fts5_rejects_is_no_result_at_each_site(self) -> None:
        for query, message in (
            ('"rum', "unterminated string"),
            ("rum AND", "fts5: syntax error"),
            ("nope:rum", "no such column"),
            ("*rum", "unknown special query"),
        ):
            with self.subTest(message):
                self.assertEqual(self.pipeline._execute_query(query, 5, None, None), [])
                self.assertEqual(self.pipeline._count_fts_matches(query), 0)

    def test_punctuation_only_query_is_not_an_index_failure(self) -> None:
        # No word in it, so the text reaches FTS5 unchanged and is rejected as unterminated.
        self.assertEqual(self.pipeline.search('"'), [])

    def test_other_sqlite_errors_propagate_from_each_site(self) -> None:
        for message in (
            "database is locked",
            "disk I/O error",
            "no such table: sessions_fts",
        ):
            with self.subTest(message):
                self.with_failing_conn(message)
                with self.assertRaisesRegex(sqlite3.OperationalError, message):
                    self.pipeline._execute_query("rum", 5, None, None)
                with self.assertRaisesRegex(sqlite3.OperationalError, message):
                    self.pipeline._count_fts_matches("rum")

    def test_chunk_query_failure_propagates_after_the_probe(self) -> None:
        self.sql(
            "CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id, session_id, u, a, f, c)"
        )
        with self.assertRaisesRegex(sqlite3.OperationalError, "session_chunks"):
            self.pipeline._execute_chunk_query("rum", 5, None, None)

    def test_chunk_query_rejection_is_no_result(self) -> None:
        self.sql(
            "CREATE VIRTUAL TABLE chunks_fts USING fts5(chunk_id, session_id, u, a, f, c)"
        )
        self.sql(
            "CREATE TABLE session_chunks (chunk_id, session_id, start_turn, end_turn)"
        )
        self.assertEqual(self.pipeline._execute_chunk_query('"rum', 5, None, None), [])

    def test_only_a_missing_synonyms_table_means_no_synonyms(self) -> None:
        self.sql("DROP TABLE synonyms")
        self.assertEqual(engine.load_synonyms(self.pipeline._connect()), {})
        with self.assertRaisesRegex(sqlite3.OperationalError, "database is locked"):
            engine.load_synonyms(RaisingConn("database is locked"))

    def test_synonyms_table_loads(self) -> None:
        self.assertIn("rum", engine.load_synonyms(self.pipeline._connect()))


class DeepSearchWithoutChunks(PipelineCase):
    def run_deep(self, **mode: Any) -> tuple[list[dict], str]:
        err = io.StringIO()
        resolved = engine.resolve_mode(
            environ={}, streams=(io.StringIO(), err, err), **mode
        )
        with (
            mock.patch.object(engine, "MODE", resolved),
            contextlib.redirect_stderr(err),
        ):
            results = self.pipeline.search("rum", deep_search=True)
        return results, err.getvalue()

    def test_missing_chunk_index_says_how_to_build_it(self) -> None:
        results, stderr = self.run_deep()
        self.assertTrue(results, "the session search still answers")
        self.assertIn("Deep search unavailable: the chunk index isn't built.", stderr)
        self.assertIn(
            "Build it:\n    ~/.claude/bin/session-index-chunk.py --backfill\n", stderr
        )

    def test_json_mode_carries_it_in_the_warnings(self) -> None:
        results, stderr = self.run_deep(json_mode=True)
        self.assertTrue(results)
        self.assertEqual(stderr, "")
        self.assertEqual(len(engine.WARNINGS), 1)
        self.assertIn(
            "session-index-chunk.py --backfill", engine.WARNINGS[0]["message"]
        )

    def test_probe_failure_is_not_called_a_missing_index(self) -> None:
        self.with_failing_conn("database is locked")
        with self.assertRaisesRegex(sqlite3.OperationalError, "database is locked"):
            self.pipeline._execute_chunk_query("rum", 5, None, None)


class BeforeOnItsOwn(PipelineCase):
    def test_before_alone_is_an_upper_bound(self) -> None:
        self.assertEqual(self.pipeline.search("rum", date_before="2000-01-01"), [])

    def test_before_alone_keeps_what_is_older(self) -> None:
        everything = self.pipeline.search("rum")
        self.assertTrue(everything)
        self.assertEqual(
            self.pipeline.search("rum", date_before="2999-01-01"), everything
        )

    def test_after_alone_is_a_lower_bound(self) -> None:
        self.assertEqual(self.pipeline.search("rum", date_after="2999-01-01"), [])


class ResultCache(PipelineCase):
    def setUp(self) -> None:
        super().setUp()
        self.cache = self.dir / CACHE_NAME
        patcher = mock.patch.object(engine, "CACHE_PATH", self.cache)
        patcher.start()
        self.addCleanup(patcher.stop)

    def temp_files(self) -> list[str]:
        return [
            p.name
            for p in self.dir.iterdir()
            if p.name.startswith(f"{CACHE_NAME}.")
            or p.name.startswith(f".{CACHE_NAME}.")
        ]

    def test_cache_write_is_atomic(self) -> None:
        self.cache.write_text("old", encoding="utf-8")
        with mock.patch.object(engine.os, "replace", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                engine.atomic_write_text(self.cache, "new")
        self.assertEqual(self.cache.read_text(encoding="utf-8"), "old")
        self.assertEqual(self.temp_files(), [])

    def test_failed_save_warns_and_leaves_no_stale_list(self) -> None:
        self.cache.write_text('[{"session_id": "old"}]', encoding="utf-8")
        err = io.StringIO()
        with mock.patch.object(engine.os, "replace", side_effect=OSError("disk full")):
            with contextlib.redirect_stderr(err):
                engine._cache_results([{"session_id": "new"}])
        self.assertIn(
            f"Couldn't save results to ~/.claude/{CACHE_NAME}: disk full. "
            "claude-search --resume N may use an older search.",
            err.getvalue(),
        )
        self.assertFalse(self.cache.exists())
        self.assertEqual(self.temp_files(), [])

    def test_failed_unlink_after_a_failed_save_does_not_raise(self) -> None:
        with mock.patch.object(engine.os, "replace", side_effect=OSError("disk full")):
            with mock.patch.object(
                engine.Path, "unlink", side_effect=PermissionError("read-only")
            ):
                with contextlib.redirect_stderr(io.StringIO()):
                    engine._cache_results([{"session_id": "new"}])

    def test_round_trip(self) -> None:
        engine._cache_results([{"session_id": "s1", "summary": "café"}])
        self.assertEqual(engine._load_cached_results()[0]["summary"], "café")
        self.assertEqual(self.temp_files(), [])

    def test_missing_cache_is_no_results(self) -> None:
        self.assertEqual(engine._load_cached_results(), [])

    def test_corrupt_cache_is_reported(self) -> None:
        self.cache.write_text("{", encoding="utf-8")
        with self.assertRaises(engine.CliError) as caught:
            engine._load_cached_results()
        err = caught.exception
        self.assertEqual(err.code, 1)
        self.assertIn(f"~/.claude/{CACHE_NAME}", err.message)
        self.assertEqual(
            err.recovery, (("Run the search again:", 'claude-search "<QUERY>"'),)
        )

    def test_undecodable_or_wrong_shape_cache_is_reported(self) -> None:
        for content in (
            b"\xff\xfe[]",
            b'{"session_id": "s"}',
            b"[1]",
            b'[{"summary": "s"}]',
        ):
            with self.subTest(content):
                self.cache.write_bytes(content)
                with self.assertRaises(engine.CliError) as caught:
                    engine._load_cached_results()
                self.assertEqual(caught.exception.code, 1)

    def test_unreadable_cache_is_reported(self) -> None:
        self.cache.mkdir()
        with self.assertRaises(engine.CliError) as caught:
            engine._load_cached_results()
        self.assertEqual(caught.exception.code, 1)


class AnalyticsData(PipelineCase):
    def seed(self) -> None:
        self.pipeline.log_search("rum", 3, pipeline_ms=10)
        self.pipeline.log_search("rum", 3, pipeline_ms=30)
        self.pipeline.log_search("nothing here", 0, pipeline_ms=20)

    def test_data_is_counted(self) -> None:
        self.seed()
        data = self.pipeline.analytics_data()
        self.assertEqual(data["total"], 3)
        self.assertEqual(data["avg_latency_ms"], 20)
        self.assertEqual(data["zero_result_count"], 1)
        self.assertEqual(
            data["zero_result_queries"], [{"query": "nothing here", "count": 1}]
        )
        self.assertEqual(
            data["top_queries"][0], {"query": "rum", "count": 2, "avg_results": 3}
        )
        self.assertEqual(len(data["recent"]), 3)
        self.assertEqual(json.loads(json.dumps(data)), data)

    def test_fails_only_leaves_out_the_rest(self) -> None:
        self.seed()
        data = self.pipeline.analytics_data(True)
        self.assertEqual(data["zero_result_count"], 1)
        self.assertNotIn("top_queries", data)
        self.assertNotIn("recent", data)

    def test_no_history_is_a_document_of_zeros(self) -> None:
        data = self.pipeline.analytics_data()
        self.assertEqual(data["total"], 0)
        self.assertEqual(data["top_queries"], [])

    def test_rendering_reads_the_data(self) -> None:
        self.seed()
        out = io.StringIO()
        with (
            contextlib.redirect_stdout(out),
        ):
            self.pipeline._show_analytics()
        text = out.getvalue()
        for fragment in (
            "3 searches",
            "20.0ms",
            "33.3% (1/3)",
            "2×",
            "avg  3 results",
            "nothing here",
        ):
            self.assertIn(fragment, text)


class TranscriptRead(unittest.TestCase):
    SESSION = "abc-1"

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)

    def write_transcript(self, payload: bytes) -> None:
        folder = self.home / ".claude" / "projects" / "-p"
        folder.mkdir(parents=True)
        (folder / f"{self.SESSION}.jsonl").write_bytes(payload)

    @staticmethod
    def user_line(text: str) -> bytes:
        line = json.dumps(
            {"type": "user", "message": {"content": text}}, ensure_ascii=False
        )
        return line.encode("utf-8") + b"\n"

    def extract(self) -> list[str]:
        with mock.patch.object(engine.Path, "home", return_value=self.home):
            return engine._extract_last_messages(self.SESSION, "/p")

    def test_no_projects_dir_is_no_messages(self) -> None:
        self.assertEqual(self.extract(), [])

    def test_a_bad_byte_costs_only_that_byte(self) -> None:
        self.write_transcript(
            self.user_line("first message")
            + b'{"type":"user","message":{"content":"bad \xff byte here"}}\n'
        )
        self.assertEqual(self.extract(), ["first message", "bad � byte here"])

    def test_transcript_read_is_utf8_under_c_locale(self) -> None:
        self.write_transcript(self.user_line("café naïve"))
        script = (
            "import importlib.util, json, locale, sys\n"
            "spec = importlib.util.spec_from_file_location('engine', sys.argv[1])\n"
            "module = importlib.util.module_from_spec(spec)\n"
            "sys.modules['engine'] = module\n"
            "spec.loader.exec_module(module)\n"
            "print(json.dumps([locale.getpreferredencoding(False),\n"
            "                  module._extract_last_messages(sys.argv[2], '/p')]))\n"
        )
        # -I alone hides PYTHONUTF8=0, and the C locale then turns UTF-8 mode on by itself, which
        # would pass with no encoding= at all. -X reaches past -I.
        done = subprocess.run(
            [
                sys.executable,
                "-I",
                "-X",
                "utf8=0",
                "-c",
                script,
                str(ENGINE_PATH),
                self.SESSION,
            ],
            env={"HOME": str(self.home), "LC_ALL": "C", "PYTHONUTF8": "0"},
            capture_output=True,
            text=True,
            check=True,
        )
        preferred, messages = json.loads(done.stdout)
        self.assertNotIn(
            "utf", preferred.lower(), "the child must really be on a non-UTF-8 locale"
        )
        self.assertEqual(messages, ["café naïve"])


if __name__ == "__main__":
    unittest.main()
