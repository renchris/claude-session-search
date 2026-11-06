import contextlib
import io
import json
import unittest
from unittest import mock

from engine_loader import load_engine

engine = load_engine()


def run_parser(*argv):
    """Parse and validate. Returns (args or None, exit code or None, stdout, stderr)."""
    parser = engine.build_parser()
    out, err = io.StringIO(), io.StringIO()
    args = code = None
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            args = parser.parse_args(list(argv))
            engine.validate_args(parser, args)
        except SystemExit as caught:
            args, code = None, caught.code
    return args, code, out.getvalue(), err.getvalue()


class ParserTest(unittest.TestCase):
    def setUp(self):
        engine.WARNINGS.clear()
        self.addCleanup(engine.WARNINGS.clear)
        plain = engine.resolve_mode(environ={}, streams=(None, None, None))
        patcher = mock.patch.object(engine, "MODE", plain)
        patcher.start()
        self.addCleanup(patcher.stop)

    def assert_usage_error(self, argv, *fragments):
        args, code, out, err = run_parser(*argv)
        self.assertEqual((args, code, out), (None, 2, ""), argv)
        self.assertIn("See 'claude-search --help'.", err)
        for fragment in fragments:
            self.assertIn(fragment, err)
        return err

    def test_abbreviation_is_rejected_with_one_close_match(self):
        err = self.assert_usage_error(
            ["--deep", "q"], "--deep", "Did you mean --deep-search?"
        )
        self.assertTrue(err.startswith("claude-search: "))
        self.assertEqual(err.count("Did you mean"), 1)

    def test_typo_gets_a_hint_and_nonsense_gets_none(self):
        self.assert_usage_error(["--limt", "3", "q"], "Did you mean --limit?")
        self.assertNotIn("Did you mean", self.assert_usage_error(["--zzzzzz", "q"]))

    def test_hint_never_teaches_a_hidden_option(self):
        self.assertNotIn("Did you mean", self.assert_usage_error(["--formatt", "q"]))

    def test_usage_error_under_json_is_one_document_on_stderr(self):
        _, code, out, err = run_parser("--json", "--deep", "q")
        self.assertEqual((code, out), (2, ""))
        doc = json.loads(err)
        self.assertEqual(doc["reason"], "unknown_option")
        self.assertEqual(doc["status"], "action_required")
        self.assertEqual(len(err.strip().splitlines()), 1)

    def test_conflicts_are_usage_errors(self):
        for argv in (
            ["--stats", "--analytics"],
            ["--preview", "x", "--stats"],
            ["--resume-result", "1", "--stats"],
            ["--context-inject", "/d", "--preview", "x"],
            ["--stats", "q"],
            ["--analytics", "q"],
            ["--preview", "x", "q"],
            ["--context-inject", "/d", "q"],
            ["--fails", "q"],
            ["--explain", "--format=fzf", "q"],
            ["--limit", "0", "q"],
            ["--limit", "x", "q"],
            ["--min-msgs", "-1", "q"],
            ["--since", "3/1", "q"],
            ["--resume-result", "0"],
        ):
            self.assert_usage_error(argv)

    def test_conflicts_with_json_are_error_documents(self):
        for argv in (
            ["--explain", "--json", "q"],
            ["--json", "--context-inject", "/d"],
            ["--format=table", "--json", "q"],
            ["--format=json", "--json", "q"],
        ):
            _, code, _, err = run_parser(*argv)
            self.assertEqual(code, 2)
            self.assertEqual(json.loads(err)["reason"], "invalid_arguments")

    def test_every_problem_is_reported_at_once(self):
        self.assert_usage_error(
            ["--fails", "--explain", "--format=fzf", "q"], "--fails", "--explain"
        )

    def test_valid_mode_forms_stay_valid(self):
        for argv in (
            ["--resume-result", "2", "q"],
            ["--resume-result", "2"],
            ["--analytics", ""],  # the wrapper's final line passes an empty query
            ["--analytics", "--fails"],
            ["--context-inject", "/d"],
            ["--format=json", "--preview", "x"],
        ):
            args, code, _, _ = run_parser(*argv)
            self.assertIsNone(code, argv)
            self.assertIsNotNone(args)
        self.assertEqual(run_parser("--resume-result", "2", "q")[0].resume_result, 2)

    def test_limit_clamps_with_one_warning(self):
        args, code, _, err = run_parser("--limit", "500", "q")
        self.assertEqual((args.limit, code), (200, None))
        self.assertIn("--limit clamped to 200.", err)
        self.assertEqual(engine.WARNINGS[0]["reason"], "limit_clamped")
        self.assertEqual(run_parser("--limit", "200", "q")[0].limit, 200)

    def test_short_forms(self):
        args, _, _, err = run_parser(
            "-n", "3", "-p", "reso", "-s", "2026-03-01", "-u", "7d", "-d", "q"
        )
        self.assertEqual((args.limit, args.project, args.debug), (3, "reso", True))
        self.assertEqual(args.after, "2026-03-01T00:00:00+00:00")
        self.assertIsNotNone(args.before)
        self.assertEqual(err, "")

    def test_after_and_before_aliases_warn_once_and_keep_dest(self):
        args, _, _, err = run_parser(
            "--after", "2026-03-01", "--after", "2026-03-02", "q"
        )
        self.assertEqual(args.after, "2026-03-02T00:00:00+00:00")
        self.assertEqual(err.count("\n"), 1)
        self.assertIn("--after is deprecated. Use --since.", err)
        engine.WARNINGS.clear()
        args, _, _, err = run_parser("--after", "1d", "--before=2026-03-01", "q")
        self.assertIsNotNone(args.before)
        self.assertEqual(err.count("\n"), 1)
        self.assertIn("Use --since.", err)
        self.assertIn("Use --until.", err)
        self.assertEqual(engine.WARNINGS[0]["reason"], "deprecated")

    def test_format_warns_only_for_json(self):
        args, _, _, err = run_parser("--format", "json", "q")
        self.assertEqual((args.format, err.count("\n")), ("json", 1))
        self.assertIn("--format json is deprecated. Use --json.", err)
        for value in ("fzf", "table"):
            engine.WARNINGS.clear()
            args, _, _, err = run_parser(f"--format={value}", "q")
            self.assertEqual((args.format, err), (value, ""))

    def test_resume_path_never_warns(self):
        # The wrapper's 2>&1 capture would take a warning line as the session ID.
        args, code, _, err = run_parser(
            "--resume-result", "1", "--after", "1d", "--limit", "500", "q"
        )
        self.assertEqual((args.limit, code, err), (200, None, ""))

    def test_boolean_forms(self):
        for name, dest in (("explain", "explain"), ("deep-search", "deep_search")):
            for spelling, expected in (
                (f"--{name}", True),
                (f"--{name}=true", True),
                (f"--{name}=false", False),
                (f"--no-{name}", False),
            ):
                args = run_parser(spelling, "q", "r")[0]
                self.assertEqual(
                    (getattr(args, dest), args.query), (expected, ["q", "r"]), spelling
                )
            self.assertFalse(getattr(run_parser("q")[0], dest))
            self.assertEqual(run_parser(f"--{name}=maybe", "q")[1], 2)
            self.assertEqual(run_parser(f"--{name}", "q")[0].query, ["q"])
            self.assertTrue(getattr(run_parser("q", f"--{name}")[0], dest))

    def test_version(self):
        for flag in ("-v", "--version"):
            self.assertEqual(run_parser(flag)[1:], (0, f"{engine.VERSION}\n", ""))
        for argv in (["-v", "--json"], ["--json", "--version"]):
            _, code, out, err = run_parser(*argv)
            self.assertEqual(
                (code, json.loads(out), err), (0, {"version": engine.VERSION}, "")
            )
        self.assertIn("usage: claude-search", run_parser("-v", "--help")[2])
        self.assertEqual(run_parser("-v", "--", "--json")[2], f"{engine.VERSION}\n")

    def test_help_hides_internal_options(self):
        text = engine.build_parser().format_help()
        for hidden in (
            "--resume-result",
            "--context-inject",
            "--format",
            "--no-log",
            "--after",
            "--before",
            "=true",
            "=false",
        ):
            self.assertNotIn(hidden, text)
        for shown in (
            "--json",
            "--limit",
            "max: 200",
            "--since",
            "--until",
            "--no-explain",
            "--no-color",
        ):
            self.assertIn(shown, text)

    def test_non_interactive_sets_mode(self):
        stream = mock.Mock(isatty=lambda: True)
        streams = (stream, stream, stream)
        self.assertTrue(engine.resolve_mode(environ={}, streams=streams).interactive)
        mode = engine.resolve_mode(environ={}, streams=streams, non_interactive=True)
        self.assertFalse(mode.interactive)
        self.assertFalse(mode.tips)


if __name__ == "__main__":
    unittest.main()
