#!/usr/bin/env python3
"""
Claude Session Search Engine — Full-text search over session index.

Usage:
    session-search.py "query"                    # Search, show ranked results
    session-search.py --json "query"             # One JSON document: {"sessions": [...], ...}
    session-search.py --format=fzf "query"       # fzf-compatible output
    session-search.py --format=json "query"      # Deprecated: use --json. Prints a bare JSON array
    session-search.py --since 2026-03-01 "query"  # Date filter: ISO 8601 or relative (7d, 12h)
    session-search.py --until 2026-04-01 "query"  # Same forms as --since
    session-search.py --no-llm "query"           # Never send the query to the Anthropic API
    session-search.py --project "reso" "query"   # Project filter
    session-search.py "@reso bottle service"     # Inline @project shortcut
    session-search.py "#auth debugging"          # Inline #tag filter
    session-search.py "@reso #bugfix login"      # Combined @project + #tag
    session-search.py --preview SESSION_ID       # Preview a session
    session-search.py --context-inject CWD       # SessionStart context line
    session-search.py --stats                    # Index statistics
    session-search.py --limit N "query"          # Limit results (default 10)
    session-search.py --explain "query"          # Show match explanation per result
    session-search.py --analytics                # Show search log statistics
    session-search.py --analytics --fails        # Show only zero-result queries
"""

import argparse
import itertools
import json
import math
import os
import re
import shlex
import shutil
import signal
import sqlite3
import sys
import tempfile
import threading
import time
import traceback
import unicodedata
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn, Optional, TextIO

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

DB_PATH = Path.home() / ".claude" / "session-index.db"
CACHE_PATH = Path.home() / ".claude" / ".last-search-results.json"

# ─── CLI contract layer: begin ───

VERSION = "0.1.0"
ENV = "SESSION_SEARCH_"
LIMIT_CAP = 200
REASONS = frozenset(
    {
        "invalid_arguments",
        "unknown_option",
        "missing_query",
        "not_found",
        "api_error",
        "spawn_failed",
        "invalid_config",
        "partial_failure",
        "internal_error",
        "canceled",
        "deprecated",
        "limit_clamped",
    }
)
ISSUES_URL = "https://github.com/renchris/claude-session-search/issues"

# One entry per reason warned about this run. warn() dedupes on it; JSON documents carry it.
WARNINGS: list[dict[str, str]] = []

_CLEAR_LINE = "\r\033[K"
_SPINNER_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


@dataclass(frozen=True)
class Mode:
    stdin_tty: bool
    stdout_tty: bool
    stderr_tty: bool
    color_out: bool
    color_err: bool
    ci: bool
    agent: bool
    interactive: bool
    json: bool
    tips: bool
    debug: bool
    accessible: bool
    picker: bool


def _isatty(stream: Optional[TextIO]) -> bool:
    # A closed or missing std stream (hooks may run with fds closed) is simply not a terminal.
    try:
        return stream is not None and stream.isatty()
    except (ValueError, OSError):
        return False


def resolve_mode(
    no_color: bool = False,
    json_mode: bool = False,
    debug: bool = False,
    environ: Mapping[str, str] = os.environ,
    streams: tuple[Optional[TextIO], Optional[TextIO], Optional[TextIO]] = (
        sys.stdin,
        sys.stdout,
        sys.stderr,
    ),
    non_interactive: bool = False,
) -> Mode:
    stdin_tty, stdout_tty, stderr_tty = (_isatty(stream) for stream in streams)
    picker = environ.get("__SESSION_SEARCH_PICKER") == "1"

    def color(tty: bool) -> bool:
        if no_color or environ.get("NO_COLOR"):
            return False
        force = environ.get("FORCE_COLOR")
        if force:
            return force != "0"
        return picker or (tty and environ.get("TERM") != "dumb")

    ci = bool(environ.get("CI"))
    agent = bool(environ.get("CLAUDECODE"))
    interactive = (
        stdin_tty
        and stderr_tty
        and not ci
        and not agent
        and not json_mode
        and not non_interactive
    )
    return Mode(
        stdin_tty=stdin_tty,
        stdout_tty=stdout_tty,
        stderr_tty=stderr_tty,
        color_out=color(stdout_tty),
        color_err=color(stderr_tty),
        ci=ci,
        agent=agent,
        interactive=interactive,
        json=json_mode,
        tips=interactive
        and stdout_tty
        and not json_mode
        and not environ.get(f"{ENV}GUIDANCE_DISABLED"),
        debug=debug or bool(environ.get(f"{ENV}DEBUG")),
        accessible=environ.get(f"{ENV}ACCESSIBLE") == "1",
        picker=picker,
    )


MODE: Mode = resolve_mode()


@dataclass(frozen=True)
class Theme:
    heading: str = ""
    accent: str = ""
    success: str = ""
    warn: str = ""
    muted: str = ""
    ident: str = ""
    match_on: str = ""
    match_off: str = ""
    reset: str = ""
    H: str = "─"
    V: str = "│"
    TL: str = "╭"
    TR: str = "╮"
    BL: str = "╰"
    BR: str = "╯"
    ML: str = "├"
    MR: str = "┤"
    THIN_V: str = "│"
    BULLET: str = "•"
    ARROW: str = "→"


_ROLES = {
    "heading": "\033[1m",
    "accent": "\033[36m",
    "success": "\033[32m",
    "warn": "\033[33m",
    "muted": "\033[2m",
    "ident": "\033[35m",
    "match_on": "\033[1;33m",
    "match_off": "\033[0m",
    "reset": "\033[0m",
}
_ACCESSIBLE_GLYPHS = {
    "H": "-",
    "V": "|",
    "TL": "+",
    "TR": "+",
    "BL": "+",
    "BR": "+",
    "ML": "+",
    "MR": "+",
    "THIN_V": "|",
    "BULLET": "-",
    "ARROW": "to",
}


def _theme_for(mode: Mode, stream: str) -> Theme:
    color, tty = (
        (mode.color_out, mode.stdout_tty)
        if stream == "out"
        else (mode.color_err, mode.stderr_tty)
    )
    if not color:
        roles: dict[str, str] = {}
    elif tty or mode.picker:
        roles = _ROLES
    else:
        # Forced colour on plain output tints only the Warning:/Error: prefixes.
        roles = {"warn": _ROLES["warn"], "reset": _ROLES["reset"]}
    return Theme(**roles, **(_ACCESSIBLE_GLYPHS if mode.accessible else {}))


def theme(stream: str = "out") -> Theme:
    return _theme_for(MODE, stream)


_ESCAPE_SEQUENCE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"  # CSI
    r"|\x1b[\]PX^_].*?(?:\x07|\x1b\\|\Z)"  # OSC, DCS, SOS, PM, APC
    r"|\x1b[ -/]*[0-~]",  # any other escape sequence
    re.DOTALL,
)
_WHITESPACE_TO_SPACE = str.maketrans("\t\n\r", "   ")


def sanitize_display(s: str, keep_hl: bool = False) -> str:
    if s.isprintable():
        return s
    kept = []
    for ch in _ESCAPE_SEQUENCE.sub("", s).translate(_WHITESPACE_TO_SPACE):
        code = ord(ch)
        if code < 0x20 or 0x7F <= code <= 0x9F:
            if keep_hl and ch in "\x02\x03":
                kept.append(ch)
        elif unicodedata.category(ch) != "Cf":
            kept.append(ch)
    return "".join(kept)


def plural(n: int, one: str, many: Optional[str] = None) -> str:
    return f"{n} {one if n == 1 else (many or one + 's')}"


def _rich_err(mode: Mode) -> bool:
    return mode.stderr_tty and mode.color_err and not mode.accessible


def _check_reason(reason: str) -> None:
    if reason not in REASONS:
        raise ValueError(f"reason {reason!r} is not in REASONS")


def warn(reason: str, message: str) -> None:
    _check_reason(reason)
    if any(entry["reason"] == reason for entry in WARNINGS):
        return
    WARNINGS.append({"reason": reason, "message": message})
    if MODE.json:
        return
    t = theme("err")
    prefix = "!" if _rich_err(MODE) else "Warning:"
    print(f"{t.warn}{prefix}{t.reset} {sanitize_display(message)}", file=sys.stderr)


class CliError(Exception):
    def __init__(
        self,
        message: str,
        *,
        code: int = 1,
        reason: str = "internal_error",
        recovery: tuple[tuple[str, str], ...] = (),
        status: str = "error",
        data: Any = None,
        retryable: Optional[bool] = None,
    ) -> None:
        super().__init__(message)
        _check_reason(reason)
        self.message = message
        self.code = code
        self.reason = reason
        self.recovery = tuple(recovery)[:2]
        self.status = status
        self.data = data
        self.retryable = retryable


def usage_error(message: str) -> CliError:
    return CliError(
        message,
        code=2,
        reason="invalid_arguments",
        status="action_required",
        recovery=(("See help:", "claude-search --help"),),
    )


def _next_entry(command: str) -> dict[str, Any]:
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    # argv runs without a shell, so nothing else would expand a leading ~.
    return {"command": command, "argv": [os.path.expanduser(word) for word in words]}


def _print_human_error(
    headline: str,
    recovery: tuple[tuple[str, str], ...],
    mode: Mode,
    rows: tuple[str, ...] = (),
) -> None:
    t = _theme_for(mode, "err")
    prefix = "✗" if _rich_err(mode) else "Error:"
    print(f"{t.warn}{prefix}{t.reset} {sanitize_display(headline)}", file=sys.stderr)
    for row in rows:
        print(row, file=sys.stderr)
    for instruction, command in recovery:
        print(file=sys.stderr)
        print(sanitize_display(instruction.rstrip(":")) + ":", file=sys.stderr)
        print(f"    {sanitize_display(command)}", file=sys.stderr)


def render_error(err: CliError, mode: Mode) -> None:
    if not mode.json:
        _print_human_error(err.message, err.recovery, mode)
        return
    doc: dict[str, Any] = {
        "status": err.status,
        "reason": err.reason,
        "message": err.message,
        "next": [_next_entry(command) for _, command in err.recovery],
    }
    if err.data is not None:
        doc["data"] = err.data
    if err.retryable is not None:
        doc["retryable"] = err.retryable
    if WARNINGS:
        doc["warnings"] = WARNINGS
    print(json.dumps(doc, separators=(",", ":"), default=str), file=sys.stderr)


def _report_bug(exc: Exception) -> None:
    if MODE.debug:
        traceback.print_exception(type(exc), exc, exc.__traceback__, file=sys.stderr)
    frames = traceback.extract_tb(exc.__traceback__)
    # Type and basename only: the exception's message can hold argv or path text.
    location = (
        f"{os.path.basename(frames[-1].filename)}:{frames[-1].lineno}"
        if frames
        else "unknown"
    )
    error_type = type(exc).__name__
    python = ".".join(str(part) for part in sys.version_info[:3])
    headline = (
        "Unexpected error in claude-search. This is a bug in claude-session-search."
    )
    if MODE.json:
        data = {
            "error": error_type,
            "location": location,
            "version": VERSION,
            "python": python,
            "platform": sys.platform,
            "report": ISSUES_URL,
        }
        render_error(CliError(headline, data=data), MODE)
        return
    rows = (
        f"Error:   {error_type} at {location}",
        f"Version: claude-search {VERSION}, Python {python}, {sys.platform}",
    )
    _print_human_error(headline, (("Report it:", ISSUES_URL),), MODE, rows)


def run_cli(main_fn: Callable[[], Optional[int]]) -> NoReturn:
    try:
        sys.exit(main_fn() or 0)
    except CliError as err:
        render_error(err, MODE)
        sys.exit(err.code)
    except KeyboardInterrupt:
        if MODE.json:
            render_error(
                CliError(
                    "Canceled.", code=130, reason="canceled", data={"remote": "none"}
                ),
                MODE,
            )
        else:
            if _spinner_allowed(MODE):
                sys.stderr.write(_CLEAR_LINE)
            print("Canceled.", file=sys.stderr)
        sys.exit(130)
    except sqlite3.Error as exc:
        render_error(
            CliError(
                f"Search index error: {type(exc).__name__} in ~/.claude/session-index.db.",
                recovery=(("Rebuild it:", "~/.claude/bin/session-index-backfill.sh"),),
            ),
            MODE,
        )
        sys.exit(1)
    except Exception as exc:
        _report_bug(exc)
        sys.exit(1)


def emit_json(doc: Any, stream: Optional[TextIO] = None) -> None:
    target = sys.stdout if stream is None else stream
    if MODE.json and WARNINGS and isinstance(doc, dict) and "warnings" not in doc:
        doc = {**doc, "warnings": WARNINGS}
    if _isatty(target):
        text = json.dumps(doc, indent=2, default=str)
    else:
        text = json.dumps(doc, separators=(",", ":"), default=str)
    target.write(text + "\n")


def atomic_write_text(path: Path, text: str) -> None:
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _spinner_allowed(mode: Mode) -> bool:
    return mode.interactive and mode.color_err and not mode.json


@contextmanager
def spinner(label: str, mode: Mode) -> Iterator[None]:
    if not _spinner_allowed(mode):
        yield
        return
    stream = sys.stderr
    if mode.accessible:
        print(label, file=stream, flush=True)
        yield
        return

    stop = threading.Event()

    def animate() -> None:
        for frame in itertools.cycle(_SPINNER_FRAMES):
            stream.write(f"\r{frame} {label}")
            stream.flush()
            if stop.wait(0.1):
                return

    thread = threading.Thread(target=animate, daemon=True)
    thread.start()
    try:
        yield
    finally:
        stop.set()
        try:
            thread.join(1.0)
        finally:
            stream.write(_CLEAR_LINE)
            stream.flush()


def _whole_number(s: str, minimum: int) -> int:
    if not re.fullmatch(r"[0-9]+", s) or int(s) < minimum:
        raise argparse.ArgumentTypeError(f"must be a whole number of {minimum} or more")
    return int(s)


def positive_int(s: str) -> int:
    return _whole_number(s, 1)


def nonneg_int(s: str) -> int:
    return _whole_number(s, 0)


def parse_time(s: str) -> str:
    try:
        relative = re.fullmatch(r"([0-9]+)([dhm]?)", s)
        if relative:
            unit = {"": "days", "d": "days", "h": "hours", "m": "minutes"}[relative[2]]
            moment = datetime.now(timezone.utc) - timedelta(**{unit: int(relative[1])})
        else:
            # Python 3.10's fromisoformat does not accept a trailing Z.
            parsed = datetime.fromisoformat(s[:-1] + "+00:00" if s.endswith("Z") else s)
            if parsed.tzinfo is None:
                moment = parsed.replace(tzinfo=timezone.utc)
            else:
                moment = parsed.astimezone(timezone.utc)
        return moment.isoformat()
    except (ValueError, OverflowError) as exc:
        raise argparse.ArgumentTypeError(
            "Times use ISO 8601 (2026-03-01) or a relative value (7d, 12h)."
        ) from exc


class _CliParser(argparse.ArgumentParser):
    _option_tokens: list[str] = []

    def parse_known_args(
        self, args: Any = None, namespace: Any = None
    ) -> tuple[Any, list[str]]:
        argv = sys.argv[1:] if args is None else list(args)
        self._option_tokens = argv[: argv.index("--")] if "--" in argv else argv
        return super().parse_known_args(argv, namespace)

    def _close_match(self, message: str) -> Optional[str]:
        if not message.startswith("unrecognized arguments:"):
            return None
        import difflib  # Only the error path needs it; the SessionStart hook pays for every import.

        declared = [
            option
            for action in self._actions
            if action.help is not argparse.SUPPRESS
            for option in action.option_strings
            if option.startswith("--")
        ]
        for token in re.findall(r"--[A-Za-z0-9-]+", message):
            # A prefix is the likeliest intent, and difflib alone ranks --help above --deep-search for --deep.
            matches = [option for option in declared if option.startswith(token)]
            matches = matches or difflib.get_close_matches(token, declared, n=1)
            if matches:
                return matches[0]
        return None

    def error(self, message: str) -> NoReturn:
        match = self._close_match(message)
        hint = f" Did you mean {match}?" if match else ""
        if "--json" in self._option_tokens:
            reason = (
                "unknown_option"
                if message.startswith("unrecognized arguments:")
                else "invalid_arguments"
            )
            err = usage_error(f"{message.rstrip('.')}.{hint}")
            err.reason = reason
            render_error(err, resolve_mode(json_mode=True))
            sys.exit(2)
        print(f"{self.prog}: {message}", file=sys.stderr)
        if match:
            print(hint.strip(), file=sys.stderr)
        print(f"See '{self.prog} --help'.", file=sys.stderr)
        sys.exit(2)


class _NotedStore(argparse.Action):
    """Store a value and record the spelling used, for options validate_args reacts to."""

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: Any,
        option_string: Optional[str] = None,
    ) -> None:
        setattr(namespace, self.dest, values)
        namespace.noted = [*namespace.noted, option_string]


class _BoolFlag(argparse.Action):
    """Backs --x, --no-x, --x=true and --x=false.

    Each is a literal option string with nargs=0. A value-taking action (nargs="?") would swallow
    the query in `--explain "some words"`.
    """

    def __init__(self, option_strings: list[str], dest: str, **kwargs: Any) -> None:
        super().__init__(option_strings, dest, nargs=0, **kwargs)

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: Any,
        option_string: Optional[str] = None,
    ) -> None:
        spelling = option_string or ""
        off = spelling.startswith("--no-") or spelling.endswith("=false")
        setattr(namespace, self.dest, not off)


class _Version(argparse.Action):
    def __init__(self, option_strings: list[str], dest: str, **kwargs: Any) -> None:
        super().__init__(
            option_strings, dest=argparse.SUPPRESS, default=argparse.SUPPRESS, nargs=0, **kwargs
        )

    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: Any,
        option_string: Optional[str] = None,
    ) -> None:
        tokens = getattr(parser, "_option_tokens", [])
        if "-h" in tokens or "--help" in tokens:
            parser.print_help()
        elif "--json" in tokens:
            emit_json({"version": VERSION})
        else:
            print(VERSION)
        parser.exit(0)


def _add_bool(parser: argparse.ArgumentParser, name: str, help_text: str) -> None:
    dest = name.replace("-", "_")
    parser.add_argument(
        f"--{name}", f"--no-{name}", action=_BoolFlag, dest=dest, default=False, help=help_text
    )
    parser.add_argument(
        f"--{name}=true",
        f"--{name}=false",
        action=_BoolFlag,
        dest=dest,
        default=False,
        help=argparse.SUPPRESS,
    )


def build_parser() -> argparse.ArgumentParser:
    hidden = argparse.SUPPRESS
    parser = _CliParser(
        prog="claude-search",
        allow_abbrev=False,
        description="Search your Claude Code sessions.",
    )
    parser.set_defaults(noted=[])
    add = parser.add_argument
    add("query", nargs="*", metavar="<QUERY>", help="Words to search for.")
    add("--json", action="store_true", help="Print one JSON document.")
    add(
        "--format",
        action=_NotedStore,
        choices=["table", "fzf", "json"],
        default="table",
        help=hidden,
    )
    add(
        "-n",
        "--limit",
        type=positive_int,
        default=10,
        metavar="<NUMBER>",
        help=f"Results to show (default: 10, max: {LIMIT_CAP}, ordered by relevance).",
    )
    add("-p", "--project", metavar="<NAME>", help="Only sessions from this project.")
    add(
        "-s",
        "--since",
        dest="after",
        type=parse_time,
        metavar="<TIME>",
        help="Only sessions after this time: ISO 8601 or relative (7d, 12h). "
        "Default: all history. An ISO value with no offset is UTC.",
    )
    add(
        "-u",
        "--until",
        dest="before",
        type=parse_time,
        metavar="<TIME>",
        help="Only sessions before this time. Same forms as --since.",
    )
    add("--after", action=_NotedStore, type=parse_time, help=hidden)
    add("--before", action=_NotedStore, type=parse_time, help=hidden)
    add(
        "--min-msgs",
        type=nonneg_int,
        default=0,
        metavar="<NUMBER>",
        help="Only sessions with at least this many messages (default: 0).",
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--resume-result", type=positive_int, metavar="<NUMBER>", help=hidden)
    modes.add_argument("--preview", metavar="<SESSION>", help="Show one session.")
    modes.add_argument("--context-inject", metavar="<DIR>", help=hidden)
    modes.add_argument("--stats", action="store_true", help="Show index statistics.")
    modes.add_argument("--analytics", action="store_true", help="Show search log statistics.")
    add("--fails", action="store_true", help="With --analytics, show only zero-result queries.")
    _add_bool(parser, "explain", "Show why each result matched.")
    _add_bool(parser, "deep-search", "Also search inside session chunks.")
    add("--no-llm", action="store_true", help="Never send the query to the Anthropic API.")
    add("--no-log", action="store_true", help=hidden)
    add("-d", "--debug", action="store_true", help="Print debug details on stderr.")
    add("--non-interactive", action="store_true", help="Never prompt.")
    add("--no-color", action="store_true", help="Turn off color.")
    add("-v", "--version", action=_Version, help="Print the version and exit.")
    return parser


def validate_args(parser: argparse.ArgumentParser, args: argparse.Namespace) -> None:
    active_modes = [
        name
        for name, active in (
            ("--stats", args.stats),
            ("--analytics", args.analytics),
            ("--preview", args.preview is not None),
            ("--context-inject", args.context_inject is not None),
        )
        if active
    ]
    problems = []
    # any(), not truth of the list: an empty "" word is no query, as in --analytics "".
    if active_modes and any(args.query):
        problems.append(f"{active_modes[0]} takes no query.")
    if args.fails and not args.analytics:
        problems.append("--fails needs --analytics.")
    if args.explain and args.json:
        problems.append("--explain can't be used with --json.")
    elif args.explain and args.format != "table":
        problems.append(f"--explain can't be used with --format {args.format}.")
    if args.json and "--format" in args.noted:
        problems.append("--json can't be used with --format.")
    if args.json and args.context_inject is not None:
        problems.append("--json can't be used with --context-inject.")
    if problems:
        parser.error(" ".join(problems))

    clamped = args.limit > LIMIT_CAP
    if clamped:
        args.limit = LIMIT_CAP
    deprecated = []
    if args.format == "json":
        deprecated.append("--format json is deprecated. Use --json.")
    for alias, replacement in (("--after", "--since"), ("--before", "--until")):
        if alias in args.noted:
            deprecated.append(f"{alias} is deprecated. Use {replacement}.")
    # One line: warn() keeps one entry per reason, so separate calls would lose the later aliases.
    if deprecated:
        warn("deprecated", " ".join(deprecated))
    if clamped:
        warn("limit_clamped", f"--limit clamped to {LIMIT_CAP}.")


# ─── CLI contract layer: end ───

# ─── Stopwords ───────────────────────────────────────────

STOP_WORDS = frozenset({
    "the", "a", "an", "is", "are", "was", "were", "and", "or", "but",
    "in", "on", "at", "to", "for", "of", "with", "by", "it", "its",
    "i", "we", "my", "our", "that", "this", "those", "these",
    "session", "claude", "where", "which", "how", "when", "what",
    "did", "do", "does", "have", "has", "had", "can", "could",
    "about", "just", "some", "any", "all", "also", "there", "here",
})
# Keep domain-relevant words even if commonly stop-word-like
KEEP_WORDS = frozenset({"not", "without", "no", "from", "after", "before", "during"})
# Short function words that add noise when split from hyphenated compounds
# e.g. "slide-out" → keep "slide", drop "out"; "check-in" → keep "check", drop "in"
# These are already in STOP_WORDS or are noise only as hyphen fragments
HYPHEN_FRAGMENT_STOPS = STOP_WORDS | {"out", "up", "off", "re", "pre", "non", "sub", "un", "co"}

# ─── Verb Expansions ────────────────────────────────────────
# Common action verbs expanded to related technical terms.
# Applied after tokenization, before synonym lookup.

VERB_EXPANSIONS: dict[str, list[str]] = {
    "debug": ["error", "fix", "trace", "bug"],
    "fix": ["bug", "error", "patch", "repair"],
    "upload": ["file", "import", "add", "create"],
    "implement": ["build", "create", "add", "feature"],
    "refactor": ["cleanup", "restructure", "reorganize"],
    "migrate": ["migration", "schema", "database", "drizzle"],
    "deploy": ["deployment", "amplify", "fly", "production"],
    "monitor": ["rum", "cloudwatch", "latency", "metrics"],
    "configure": ["config", "setup", "settings", "env"],
    "optimize": ["performance", "speed", "latency", "cache"],
    "test": ["spec", "smoke", "testing", "coverage"],
    "review": ["audit", "check", "inspect", "verify"],
}

# ─── Temporal Extraction ──────────────────────────────────

TEMPORAL_PATTERNS = [
    (r"\byesterday\b", lambda: (datetime.now(timezone.utc) - timedelta(days=1), datetime.now(timezone.utc))),
    (r"\btoday\b", lambda: (datetime.now(timezone.utc).replace(hour=0, minute=0, second=0), datetime.now(timezone.utc))),
    (r"\blast\s+(\d+)\s+days?\b", lambda m: (datetime.now(timezone.utc) - timedelta(days=int(m.group(1))), datetime.now(timezone.utc))),
    (r"\blast\s+week\b", lambda: (datetime.now(timezone.utc) - timedelta(days=7), datetime.now(timezone.utc))),
    (r"\blast\s+(\d+)\s+weeks?\b", lambda m: (datetime.now(timezone.utc) - timedelta(weeks=int(m.group(1))), datetime.now(timezone.utc))),
    (r"\blast\s+month\b", lambda: (datetime.now(timezone.utc) - timedelta(days=30), datetime.now(timezone.utc))),
    (r"\blast\s+(\d+)\s+months?\b", lambda m: (datetime.now(timezone.utc) - timedelta(days=30 * int(m.group(1))), datetime.now(timezone.utc))),
    (r"\bthis\s+week\b", lambda: (datetime.now(timezone.utc) - timedelta(days=datetime.now(timezone.utc).weekday()), datetime.now(timezone.utc))),
]

MONTH_NAMES = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6,
    "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "september": 9,
    "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
}

def extract_temporal(text):
    """Extract date range from query, return (cleaned_text, date_range_or_None)."""
    for pattern, factory in TEMPORAL_PATTERNS:
        m = re.search(pattern, text, re.IGNORECASE)
        if m:
            cleaned = re.sub(pattern, "", text, flags=re.IGNORECASE).strip()
            try:
                if m.lastindex:
                    date_range = factory(m)
                else:
                    date_range = factory()
                return cleaned, date_range
            except Exception:
                pass

    # "march 1" or "mar 8" style
    m = re.search(r"\b(" + "|".join(MONTH_NAMES.keys()) + r")\s+(\d{1,2})\b", text, re.IGNORECASE)
    if m:
        month = MONTH_NAMES[m.group(1).lower()]
        day = int(m.group(2))
        year = datetime.now().year
        try:
            start = datetime(year, month, day, tzinfo=timezone.utc)
            end = start + timedelta(days=1)
            cleaned = text[:m.start()] + text[m.end():]
            return cleaned.strip(), (start, end)
        except ValueError:
            pass

    # ISO date: 2026-03-01
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", text)
    if m:
        try:
            start = datetime.fromisoformat(m.group(1)).replace(tzinfo=timezone.utc)
            end = start + timedelta(days=1)
            cleaned = text[:m.start()] + text[m.end():]
            return cleaned.strip(), (start, end)
        except ValueError:
            pass

    return text, None


# ─── Synonym Expansion ────────────────────────────────────

def load_synonyms(conn):
    """Load synonyms from DB into dict: term → [expansions]."""
    try:
        rows = conn.execute("SELECT term, expansion FROM synonyms").fetchall()
        syns = {}
        for term, expansion in rows:
            syns.setdefault(term.lower(), []).append(expansion.lower())
        return syns
    except sqlite3.OperationalError as e:
        if "no such table: synonyms" in str(e):
            return {}
        raise


def _warn_no_chunk_index() -> None:
    headline = "Deep search unavailable: the chunk index isn't built."
    build = "~/.claude/bin/session-index-chunk.py --backfill"
    if MODE.json:
        warn("not_found", f"{headline} Build it: {build}")
        return
    # A spinner frame may be on the line already; its next one lands below the warning.
    if _spinner_allowed(MODE):
        sys.stderr.write(_CLEAR_LINE)
    warn("not_found", headline)
    print(f"Build it:\n    {build}", file=sys.stderr)


def _is_fts_query_error(exc: sqlite3.Error) -> bool:
    """True when FTS5 rejected the query text, so the next strategy may still match.

    Any other error means the index itself is unusable. FTS5 words its "unterminated string"
    and "unknown special query" rejections without its fts5: prefix.
    """
    message = str(exc)
    return message.startswith("fts5") or any(
        text in message
        for text in ("syntax error", "no such column", "unterminated string", "unknown special query")
    )


def expand_synonyms(tokens, synonym_map):
    """Expand tokens using synonym map. Returns expanded token list."""
    expanded = []
    i = 0
    while i < len(tokens):
        # Try 2-token phrases first (e.g., "floor plan")
        if i + 1 < len(tokens):
            bigram = f"{tokens[i]} {tokens[i+1]}"
            if bigram in synonym_map:
                expanded.append(bigram)
                expanded.extend(synonym_map[bigram])
                i += 2
                continue
        # Single token
        token = tokens[i]
        expanded.append(token)
        if token in synonym_map:
            expanded.extend(synonym_map[token])
        i += 1
    return list(dict.fromkeys(expanded))  # dedupe, preserve order


# ─── Fuzzy Correction ────────────────────────────────────

def fuzzy_correct(tokens, known_terms):
    """Correct tokens using fuzzy matching. Graceful if rapidfuzz not installed."""
    try:
        from rapidfuzz import fuzz, process
    except ImportError:
        return tokens

    corrected = []
    for token in tokens:
        if token in known_terms or len(token) < 4:
            corrected.append(token)
            continue
        threshold = 75 if len(token) <= 8 else 65
        match = process.extractOne(token, known_terms, scorer=fuzz.ratio, score_cutoff=threshold)
        if match:
            corrected.append(match[0])
        else:
            corrected.append(token)
    return corrected


# ─── FTS5 Query Builder ──────────────────────────────────

def build_fts5_query(tokens):
    """Build FTS5 MATCH query from tokens."""
    if not tokens:
        return None
    # Escape FTS5 special chars
    safe = []
    for t in tokens:
        t = t.replace('"', '""')
        if " " in t:
            safe.append(f'"{t}"')
        else:
            safe.append(t)
    return " OR ".join(safe)


# ─── Recency Boost ───────────────────────────────────────

def recency_score(created_at_str, half_life_days=30, amplitude=0.3):
    """Gaussian recency: gentle tiebreaker, not dominant signal."""
    try:
        created = datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
        days_old = max(0, (datetime.now(timezone.utc) - created).days)
        return 1.0 + amplitude * math.exp(-0.5 * (days_old / half_life_days) ** 2)
    except Exception:
        return 1.0


# ─── Query Pipeline ──────────────────────────────────────

class QueryPipeline:
    def __init__(self, db_path=DB_PATH):
        self.db_path = db_path
        self.conn = None

    def _connect(self):
        if self.conn is None:
            self.conn = sqlite3.connect(str(self.db_path), timeout=5)
            self.conn.row_factory = sqlite3.Row
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.execute("PRAGMA synchronous=NORMAL")
            self.conn.execute("PRAGMA cache_size=-65536")
            self.conn.execute("PRAGMA mmap_size=268435456")
            self.conn.execute("PRAGMA temp_store=MEMORY")
        return self.conn

    def _check_index_freshness(self):
        """Auto-trigger incremental backfill if index is stale (>7 days)."""
        try:
            row = self.conn.execute(
                "SELECT value FROM meta WHERE key = 'last_backfill'"
            ).fetchone()
            if row:
                last = datetime.fromisoformat(row[0].replace('Z', '+00:00'))
                age = datetime.now(timezone.utc) - last
                if age < timedelta(days=7):
                    return  # Fresh enough

            # Index is stale — run quick backfill in background
            import subprocess
            repo_dir = os.environ.get("SESSION_SEARCH_REPO", "")
            if not repo_dir:
                # Try to find repo from script location
                script_dir = Path(__file__).resolve().parent
                repo_dir = str(script_dir.parent)

            backfill = Path(repo_dir) / "scripts" / "session-index-backfill.sh"
            if backfill.exists():
                subprocess.Popen(
                    ["bash", str(backfill), "--since", "7", "--quiet"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,  # Detach from parent
                )
        except Exception:
            pass  # Never let freshness check break search

    @staticmethod
    def _parse_inline_syntax(query: str) -> tuple[str, str | None, list[str]]:
        """Parse @project and #tag shortcuts from query.

        Returns: (clean_query, project_filter, tag_filters)

        Examples:
            "@reso bottle service" -> ("bottle service", "reso", [])
            "#auth debugging"      -> ("debugging", None, ["auth"])
            "@reso #bugfix login"  -> ("login", "reso", ["bugfix"])
        """
        project: str | None = None
        tags: list[str] = []
        for match in re.finditer(r'@([\w-]+)', query):
            project = match.group(1)
        for match in re.finditer(r'#([\w-]+)', query):
            tags.append(match.group(1))
        # Remove @project and #tag tokens from query
        clean = re.sub(r'[@#][\w-]+', '', query).strip()
        # Collapse multiple spaces
        clean = re.sub(r'\s+', ' ', clean)
        return clean, project, tags

    def search(self, raw_query, limit=10, project_filter=None, date_after=None, date_before=None, min_messages=0, deep_search=False):
        conn = self._connect()
        self._check_index_freshness()
        synonyms = load_synonyms(conn)
        known_terms = set(synonyms.keys())
        # Add all expansion values too
        for exps in synonyms.values():
            known_terms.update(exps)

        # 0. Parse inline @project #tag syntax
        query_text, inline_project, inline_tags = self._parse_inline_syntax(raw_query)
        if inline_project and not project_filter:
            project_filter = inline_project

        # 1. Normalize
        normalized = query_text.strip().lower()

        # 2. Temporal extraction
        text, auto_date_range = extract_temporal(normalized)

        # CLI date flags override auto-extracted
        if date_after or date_before:
            start = datetime.min.replace(tzinfo=timezone.utc)
            end = datetime.now(timezone.utc)
            if date_after:
                start = datetime.fromisoformat(date_after).replace(tzinfo=timezone.utc)
            if date_before:
                end = datetime.fromisoformat(date_before).replace(tzinfo=timezone.utc)
            auto_date_range = (start, end)

        # 3. Tokenize
        # First extract compound terms (for synonym lookup), then split hyphens for FTS5
        # FTS5 unicode61 tokenizer treats hyphens as separators
        compound_tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', text)
        if not compound_tokens:
            compound_tokens = re.findall(r'\S+', text)

        # 3a. Stopword filtering (before synonym expansion)
        effective_stops = STOP_WORDS - KEEP_WORDS
        compound_tokens = [t for t in compound_tokens if t not in effective_stops]
        if not compound_tokens:
            # If all tokens were stopwords, use original (fallback)
            compound_tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', text)

        # 3b. Verb expansion (add search-relevant terms for action verbs)
        verb_expanded = []
        for t in compound_tokens:
            verb_expanded.append(t)
            if t in VERB_EXPANSIONS:
                verb_expanded.extend(VERB_EXPANSIONS[t])
        compound_tokens = list(dict.fromkeys(verb_expanded))

        # 3c. Inject inline #tags as search tokens
        if inline_tags:
            compound_tokens.extend(inline_tags)

        # 4. Synonym expansion (uses compound tokens like "slide-out" for lookup)
        expanded = expand_synonyms(compound_tokens, synonyms)

        # Split hyphens for FTS5 compatibility (FTS5 unicode61 treats - as separator;
        # FTS5 query parser treats - as NOT operator). After synonym expansion is done.
        tokens = []
        for t in expanded:
            if "-" in t:
                parts = [p for p in t.split("-") if p]
                # Add a quoted adjacency phrase so FTS5 matches the compound term
                # e.g. "slide-out" → "slide out" (phrase) + "slide" (individual)
                if len(parts) >= 2:
                    tokens.append(" ".join(parts))  # quoted phrase added later
                # Add individual parts, but skip noise fragments (e.g. "out" from "slide-out")
                for p in parts:
                    if p not in HYPHEN_FRAGMENT_STOPS or len(parts) == 1:
                        tokens.append(p)
            else:
                tokens.append(t)
        tokens = list(dict.fromkeys(tokens))  # dedupe, preserve order

        # 5. Fuzzy correction (only for unknown terms)
        corrected = fuzzy_correct(tokens, known_terms)

        # Store original query tokens (pre-expansion) for NEAR matching.
        # Split hyphens here too — FTS5 treats "-" as NOT operator in queries.
        # Convert compound terms to quoted adjacency phrases (e.g. "slide-out" → '"slide out"')
        near_tokens = []
        for t in compound_tokens:
            if t in effective_stops:
                continue
            if "-" in t:
                parts = [p for p in t.split("-") if p]
                if len(parts) >= 2:
                    # Use quoted phrase so NEAR matches the compound as a unit
                    near_tokens.append('"' + " ".join(parts) + '"')
                elif parts:
                    near_tokens.extend(parts)
            else:
                near_tokens.append(t)
        self._original_tokens = near_tokens[:6]

        # Store final tokens for --explain
        self._final_tokens = corrected

        # 6. Progressive search
        results = self._progressive_search(corrected, limit, project_filter, auto_date_range, min_messages)

        # 6a. LLM expansion fallback on sparse results
        if len(results) < 3:
            llm_results = self._llm_expand_query(raw_query, limit, project_filter, auto_date_range, min_messages)
            if llm_results:
                # Merge via RRF
                results = self._reciprocal_rank_fusion([results, llm_results])[:limit * 2]
                self._last_strategy = getattr(self, '_last_strategy', 'none') + " + LLM expansion"

        # 6c. Deep search: also query chunks_fts
        if deep_search:
            chunk_fts_query = build_fts5_query(corrected) if corrected else None
            if chunk_fts_query:
                chunk_results = self._execute_chunk_query(
                    chunk_fts_query, limit, project_filter, auto_date_range
                )
                if chunk_results:
                    results = self._reciprocal_rank_fusion([results, chunk_results])[:limit * 2]
                    self._last_strategy = getattr(self, '_last_strategy', 'none') + " + deep"

        # 7. Normalize BM25 scores and apply additive scoring
        if results:
            bm25_scores = [abs(r.get("bm25", 0)) for r in results]
            min_bm25, max_bm25 = min(bm25_scores), max(bm25_scores)
            bm25_range = max_bm25 - min_bm25 if max_bm25 != min_bm25 else 1.0

            for r in results:
                # Normalize BM25 to [0, 1]
                norm_bm25 = (abs(r.get("bm25", 0)) - min_bm25) / bm25_range

                # Recency: Gaussian decay, [1.0, 1.3]
                recency = recency_score(r["created_at"])
                norm_recency = (recency - 1.0) / 0.3  # normalize to [0, 1]

                # Depth: sweet spot 10-100 messages, diminishing after 200
                msgs = max(r["message_count"], 1)
                if msgs < 5:
                    depth = 0.5 + 0.1 * msgs
                elif msgs <= 200:
                    depth = 1.0 + 0.3 * math.log10(msgs / 5)
                else:
                    depth = 1.48 - 0.1 * math.log10(msgs / 200)
                norm_depth = min(1.0, (depth - 0.5) / 1.0)

                # Additive final score
                r["recency"] = recency  # keep for display
                r["depth"] = depth
                r["final_score"] = (
                    0.60 * norm_bm25
                    + 0.15 * norm_recency
                    + 0.10 * norm_depth
                    + 0.15 * norm_bm25 * norm_recency  # interaction term: relevant + recent
                )
        results.sort(key=lambda r: r["final_score"], reverse=True)

        # 8. Post-filter by #tag (must appear in tags column, case-insensitive)
        if inline_tags:
            def _has_all_tags(result):
                tags_str = (result.get("tags") or "").lower()
                tag_list = [t.strip() for t in tags_str.split(",") if t.strip()]
                return all(
                    any(tag.lower() in stored for stored in tag_list)
                    for tag in inline_tags
                )
            results = [r for r in results if _has_all_tags(r)]

        return results[:limit]

    def _progressive_search(self, tokens, limit, project_filter, date_range, min_messages=0):
        """Try increasingly broad queries until we get results."""
        # Build NEAR strategy from original (pre-expansion) tokens
        orig = getattr(self, '_original_tokens', tokens[:4])

        # Pre-build NEAR query: quote each term for FTS5 NEAR syntax
        # e.g. NEAR("soketi" "oregon", 5) — terms within 5 words of each other
        if len(orig) > 1:
            _quoted = []
            for tok in orig:
                _quoted.append(tok if tok.startswith('"') else f'"{tok}"')
            _near_query = "NEAR({}, 5)".format(" ".join(_quoted))
        else:
            _near_query = None

        strategy_names = [
            "NEAR proximity",
            "AND phrase",
            "OR match",
            "Core terms only",
            "Prefix match",
        ]

        strategies = [
            # 0. NEAR proximity match (original terms within 5 words of each other)
            lambda t: _near_query,
            # 1. AND match on user's original terms only (not synonym expansions)
            # orig tokens may be pre-quoted (e.g. '"slide out"') from hyphen compounds
            lambda t: " AND ".join(tok if tok.startswith('"') else (f'"{tok}"' if " " in tok else tok) for tok in orig) if orig else None,
            # 2. OR match
            lambda t: build_fts5_query(t),
            # 3. Core terms only (drop expansions, keep first N originals)
            lambda t: build_fts5_query(t[:max(2, len(t) // 2)]),
            # 4. Prefix match on each term
            lambda t: " OR ".join(f"{tok}*" for tok in t if " " not in tok),
        ]

        best_results = []
        best_strategy = None
        for i, strategy in enumerate(strategies):
            fts_query = strategy(tokens)
            if not fts_query:
                continue
            results = self._execute_query(fts_query, limit * 2, project_filter, date_range, min_messages)
            if results:
                if len(results) >= 3:
                    self._last_strategy = strategy_names[i]
                    return results  # Sufficient results, stop here
                # Sparse results — keep but try broader strategies
                if len(results) > len(best_results):
                    best_results = results
                    best_strategy = strategy_names[i]
        self._last_strategy = best_strategy or "none"
        return best_results

    def _execute_query(self, fts_query, limit, project_filter, date_range, min_messages=0):
        conn = self._connect()
        # Standalone FTS5 table — join on session_id column
        # BM25 weights (11 columns):
        #   session_id(0), summary(12), first_prompt(3), tags(5), keywords(3),
        #   project_name(0.5), context_text(2.5), assistant_text(1.5), files_changed(3.5),
        #   commands_run(1), search_aliases(8)
        sql = """
            SELECT s.session_id, s.project_path, s.project_name, s.summary,
                   s.first_prompt, s.context_text, s.git_branch, s.created_at,
                   s.modified_at, s.message_count, s.tags, s.keywords, s.source,
                   bm25(sessions_fts, 0.0, 12.0, 3.0, 5.0, 3.0, 0.5, 2.5, 1.5, 3.5, 1.0, 8.0) AS bm25_score,
                   highlight(sessions_fts, 1, '\x02', '\x03') AS summary_hl,
                   highlight(sessions_fts, 6, '\x02', '\x03') AS context_hl,
                   highlight(sessions_fts, 7, '\x02', '\x03') AS assistant_hl,
                   highlight(sessions_fts, 10, '\x02', '\x03') AS aliases_hl,
                   snippet(sessions_fts, 1, '\x02', '\x03', '...', 24) AS summary_snip,
                   snippet(sessions_fts, 2, '\x02', '\x03', '...', 24) AS prompt_snip,
                   snippet(sessions_fts, 6, '\x02', '\x03', '...', 24) AS context_snip,
                   snippet(sessions_fts, 7, '\x02', '\x03', '...', 24) AS assistant_snip,
                   snippet(sessions_fts, 10, '\x02', '\x03', '...', 24) AS aliases_snip
            FROM sessions_fts
            JOIN sessions s ON s.session_id = sessions_fts.session_id
            WHERE sessions_fts MATCH ?
        """
        params = [fts_query]

        if project_filter:
            sql += " AND s.project_name LIKE ?"
            params.append(f"%{project_filter}%")

        if date_range:
            start, end = date_range
            sql += " AND s.created_at >= ? AND s.created_at <= ?"
            params.append(start.strftime("%Y-%m-%dT%H:%M:%SZ"))
            params.append(end.strftime("%Y-%m-%dT%H:%M:%SZ"))

        if min_messages and min_messages > 0:
            sql += " AND s.message_count >= ?"
            params.append(min_messages)

        sql += " ORDER BY bm25_score LIMIT ?"
        params.append(limit)

        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as e:
            if _is_fts_query_error(e):
                return []
            raise

        results = []
        for row in rows:
            results.append({
                "session_id": row["session_id"],
                "project_path": row["project_path"],
                "project_name": row["project_name"],
                "summary": row["summary"],
                "first_prompt": row["first_prompt"],
                "context_text": row["context_text"],
                "git_branch": row["git_branch"],
                "created_at": row["created_at"],
                "modified_at": row["modified_at"],
                "message_count": row["message_count"],
                "tags": row["tags"],
                "keywords": row["keywords"],
                "source": row["source"],
                "bm25": abs(row["bm25_score"]),  # BM25 returns negative scores
                "summary_hl": row["summary_hl"] if "summary_hl" in row.keys() else "",
                "context_hl": row["context_hl"] if "context_hl" in row.keys() else "",
                "assistant_hl": row["assistant_hl"] if "assistant_hl" in row.keys() else "",
                "aliases_hl": row["aliases_hl"] if "aliases_hl" in row.keys() else "",
                "summary_snip": row["summary_snip"] if "summary_snip" in row.keys() else "",
                "prompt_snip": row["prompt_snip"] if "prompt_snip" in row.keys() else "",
                "context_snip": row["context_snip"] if "context_snip" in row.keys() else "",
                "assistant_snip": row["assistant_snip"] if "assistant_snip" in row.keys() else "",
                "aliases_snip": row["aliases_snip"] if "aliases_snip" in row.keys() else "",
            })
        return results

    def _execute_chunk_query(self, fts_query, limit, project_filter, date_range):
        """Search chunks_fts and return session-level results with chunk context."""
        conn = self._connect()
        try:
            conn.execute("SELECT 1 FROM chunks_fts LIMIT 0")
        except sqlite3.OperationalError as e:
            if "no such table" not in str(e):
                raise
            _warn_no_chunk_index()
            return []

        sql = """
            SELECT c.chunk_id, c.session_id, c.start_turn, c.end_turn,
                   s.project_path, s.project_name, s.summary, s.first_prompt,
                   s.context_text, s.git_branch, s.created_at, s.modified_at,
                   s.message_count, s.tags, s.keywords, s.source,
                   bm25(chunks_fts, 0.0, 0.0, 3.0, 1.5, 3.5, 1.0) AS chunk_bm25,
                   snippet(chunks_fts, 2, '\x02', '\x03', '...', 24) AS chunk_user_snip,
                   snippet(chunks_fts, 3, '\x02', '\x03', '...', 24) AS chunk_asst_snip
            FROM chunks_fts
            JOIN session_chunks c ON c.chunk_id = chunks_fts.chunk_id
            JOIN sessions s ON s.session_id = c.session_id
            WHERE chunks_fts MATCH ?
        """
        params = [fts_query]

        if project_filter:
            sql += " AND s.project_name LIKE ?"
            params.append(f"%{project_filter}%")

        if date_range:
            start, end = date_range
            sql += " AND s.created_at >= ? AND s.created_at <= ?"
            params.append(start.strftime("%Y-%m-%dT%H:%M:%SZ"))
            params.append(end.strftime("%Y-%m-%dT%H:%M:%SZ"))

        sql += " ORDER BY chunk_bm25 LIMIT ?"
        params.append(limit * 3)

        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as e:
            if _is_fts_query_error(e):
                return []
            raise

        # Deduplicate: keep best chunk per session_id
        seen = {}
        for row in rows:
            sid = row["session_id"]
            if sid not in seen:
                seen[sid] = {
                    "session_id": sid,
                    "project_path": row["project_path"],
                    "project_name": row["project_name"],
                    "summary": row["summary"],
                    "first_prompt": row["first_prompt"],
                    "context_text": row["context_text"],
                    "git_branch": row["git_branch"],
                    "created_at": row["created_at"],
                    "modified_at": row["modified_at"],
                    "message_count": row["message_count"],
                    "tags": row["tags"],
                    "keywords": row["keywords"],
                    "source": row["source"],
                    "bm25": abs(row["chunk_bm25"]),
                    "summary_hl": "", "context_hl": "", "assistant_hl": "", "aliases_hl": "",
                    "summary_snip": "", "prompt_snip": "",
                    "context_snip": row["chunk_user_snip"] or "",
                    "assistant_snip": row["chunk_asst_snip"] or "",
                    "aliases_snip": "",
                    "chunk_context": f"turns {row['start_turn']}-{row['end_turn']}",
                }
        return list(seen.values())[:limit]

    def _llm_expand_query(self, raw_query, limit, project_filter, date_range, min_messages):
        """Fallback: ask Haiku to rewrite query into keyword variants."""
        api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if not api_key:
            return []

        prompt = (
            f"Rewrite this session search query as 4 lines of keywords "
            f"(5-7 terms each). Each line should capture a different "
            f"interpretation. Terms only, no explanation.\n\n"
            f"Query: {raw_query}"
        )
        text = ""

        # Try anthropic SDK first, fall back to urllib
        try:
            deps_path = os.environ.get("SESSION_SEARCH_PYTHON_DEPS", "")
            if deps_path and os.path.isdir(deps_path):
                sys.path.insert(0, deps_path)
            import anthropic
            client = anthropic.Anthropic(api_key=api_key)
            msg = client.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=150,
                messages=[{"role": "user", "content": prompt}],
            )
            text = msg.content[0].text.strip()
        except Exception:
            # Fall back to urllib
            try:
                import urllib.request
                req_data = json.dumps({
                    "model": "claude-haiku-4-5-20251001",
                    "max_tokens": 150,
                    "messages": [{"role": "user", "content": prompt}]
                }).encode()
                req = urllib.request.Request(
                    "https://api.anthropic.com/v1/messages",
                    data=req_data,
                    headers={
                        "x-api-key": api_key,
                        "anthropic-version": "2023-06-01",
                        "content-type": "application/json",
                    },
                )
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = json.loads(resp.read())
                text = data["content"][0]["text"].strip()
            except Exception:
                return []

        if not text:
            return []

        # Parse interpretations and search each
        interpretations = [line.strip() for line in text.split("\n") if line.strip()][:4]
        all_results: list[list[dict]] = []
        for interp in interpretations:
            interp = interp.lstrip("0123456789.-) ")
            if not interp:
                continue
            itokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', interp.lower())
            if not itokens:
                continue
            fts_q = build_fts5_query(itokens)
            if fts_q:
                try:
                    results = self._execute_query(fts_q, limit, project_filter, date_range, min_messages)
                    all_results.append(results)
                except Exception:
                    continue

        if all_results:
            return self._reciprocal_rank_fusion(all_results)
        return []

    @staticmethod
    def _reciprocal_rank_fusion(ranked_lists, k=60):
        """Merge multiple ranked lists via Reciprocal Rank Fusion."""
        scores = {}
        for ranking in ranked_lists:
            for rank, result in enumerate(ranking, 1):
                sid = result["session_id"]
                if sid not in scores:
                    scores[sid] = {"result": result, "rrf": 0}
                scores[sid]["rrf"] += 1.0 / (k + rank)
        fused = sorted(scores.values(), key=lambda x: x["rrf"], reverse=True)
        return [item["result"] for item in fused]

    def _count_fts_matches(self, fts_query: str) -> int:
        """Count how many sessions match an FTS5 query."""
        try:
            cursor = self._connect().execute(
                "SELECT COUNT(*) FROM sessions_fts WHERE sessions_fts MATCH ?",
                (fts_query,)
            )
            return cursor.fetchone()[0]
        except sqlite3.OperationalError as e:
            if _is_fts_query_error(e):
                return 0
            raise

    def suggest_alternatives(self, raw_query, limit=4):
        """When search fails, suggest queries that would return results."""
        tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', raw_query.lower())
        effective_stops = STOP_WORDS - KEEP_WORDS
        tokens = [t for t in tokens if t not in effective_stops]
        suggestions: list[tuple[str, int]] = []

        # Try each token individually
        for token in tokens:
            try:
                count = self._count_fts_matches(token)
                if count > 0:
                    suggestions.append((token, count))
            except Exception:
                pass

        # Try dropping one term at a time (if 3+ tokens)
        if len(tokens) >= 3:
            for i in range(len(tokens)):
                subset = tokens[:i] + tokens[i + 1:]
                query = " ".join(subset)
                try:
                    count = self._count_fts_matches(" OR ".join(subset))
                    if count > 0:
                        suggestions.append((query, count))
                except Exception:
                    pass

        # Deduplicate and sort by result count
        seen: set[str] = set()
        unique: list[tuple[str, int]] = []
        for query, count in sorted(suggestions, key=lambda x: -x[1]):
            if query not in seen:
                seen.add(query)
                unique.append((query, count))

        return unique[:limit]

    def preview(self, session_id):
        conn = self._connect()
        row = conn.execute(
            "SELECT * FROM sessions WHERE session_id = ?", (session_id,)
        ).fetchone()
        if not row:
            return None
        return dict(row)

    def stats(self):
        conn = self._connect()
        total = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
        tagged = conn.execute("SELECT COUNT(*) FROM sessions WHERE tagged_at IS NOT NULL").fetchone()[0]
        projects = conn.execute("SELECT COUNT(DISTINCT project_name) FROM sessions").fetchone()[0]
        last = conn.execute("SELECT MAX(indexed_at) FROM sessions").fetchone()[0]
        by_source = conn.execute(
            "SELECT source, COUNT(*) as c FROM sessions GROUP BY source ORDER BY c DESC"
        ).fetchall()
        by_project = conn.execute(
            "SELECT project_name, COUNT(*) as c FROM sessions GROUP BY project_name ORDER BY c DESC LIMIT 10"
        ).fetchall()
        return {
            "total": total,
            "tagged": tagged,
            "projects": projects,
            "last_indexed": last,
            "by_source": [(r[0], r[1]) for r in by_source],
            "by_project": [(r[0], r[1]) for r in by_project],
        }

    def context_inject(self, cwd):
        """Generate compact context string for SessionStart hook."""
        conn = self._connect()
        total = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
        if total == 0:
            return ""

        # Get project name from cwd
        project_name = os.path.basename(cwd) if cwd else ""

        # Recent sessions for this project
        rows = conn.execute("""
            SELECT summary, created_at, tags FROM sessions
            WHERE project_name LIKE ?
            ORDER BY modified_at DESC LIMIT 3
        """, (f"%{project_name}%" if project_name else "%",)).fetchall()

        if not rows:
            return f"Session index: {total} sessions. Search: claude-search \"query\""

        parts = []
        now = datetime.now(timezone.utc)
        for row in rows:
            summary = row[0][:60] if row[0] else "(no summary)"
            created = row[1]
            tags = row[2]

            # Relative time
            try:
                dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                delta = now - dt
                if delta.days == 0:
                    age = "today"
                elif delta.days == 1:
                    age = "1d"
                elif delta.days < 7:
                    age = f"{delta.days}d"
                elif delta.days < 30:
                    age = f"{delta.days // 7}w"
                else:
                    age = f"{delta.days // 30}mo"
            except Exception:
                age = "?"

            tag_str = f" (#{tags.split(',')[0].strip()})" if tags else ""
            parts.append(f"[{age}] {summary}{tag_str}")

        recent_str = " | ".join(parts)
        return f"Session index: {total} sessions. Recent: {recent_str}\nSearch: claude-search \"query\""

    def log_search(self, query, result_count, selected_id=None, selected_rank=None, pipeline_ms=None):
        conn = self._connect()
        conn.execute(
            "INSERT INTO search_log (query, result_count, selected_id, selected_rank, pipeline_ms) VALUES (?, ?, ?, ?, ?)",
            (query, result_count, selected_id, selected_rank, pipeline_ms)
        )
        conn.commit()

    def _explain_match(self, result, tokens, raw_query):
        """Explain why a result matched the query. Returns list of lines (no prefix)."""
        color = _use_color()
        R = "\033[0m" if color else ""
        CYAN = "\033[36m" if color else ""
        YELLOW = "\033[33m" if color else ""
        DIM = "\033[2m" if color else ""

        explanations = []

        # Check which columns contain query terms — group by token
        columns = {
            'summary': result.get('summary', ''),
            'first_prompt': result.get('first_prompt', ''),
            'tags': result.get('tags', ''),
            'keywords': result.get('keywords', ''),
            'context_text': result.get('context_text', ''),
            'assistant_text': result.get('assistant_hl', ''),
            'files_changed': result.get('files_changed', ''),
            'commands_run': result.get('commands_run', ''),
            'search_aliases': result.get('aliases_hl', ''),
        }

        for token in tokens:
            matching_cols = [col for col, text in columns.items() if text and token.lower() in text.lower()]
            if matching_cols:
                cols_str = f"{CYAN}{', '.join(matching_cols)}{R}"
                explanations.append(f"'{token}' \u2192 {cols_str}")

        # Combine BM25 + strategy on one line
        parts = []
        strategy = getattr(self, '_last_strategy', None)
        if strategy:
            parts.append(f"Strategy: {strategy}")
        if 'bm25' in result:
            parts.append(f"BM25: {YELLOW}{result['bm25']:.2f}{R}")
        if parts:
            joined = ' \u00b7 '.join(parts)
            explanations.append(f"{DIM}{joined}{R}")

        # Show synonym/verb expansions
        effective_stops = STOP_WORDS - KEEP_WORDS
        raw_tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', raw_query.lower())
        raw_tokens = [t for t in raw_tokens if t not in effective_stops]
        expanded_only = [t for t in tokens if t not in raw_tokens]
        if expanded_only:
            explanations.append(f"Expanded: {DIM}{', '.join(expanded_only[:10])}{R}")

        return '\n'.join(explanations)

    def reset_dedup(self):
        """Reset description deduplication tracking for a new search."""
        self._seen_descriptions = set()

    def build_deduped_description(self, r):
        """Build description with deduplication — if the same text was already
        shown for a previous result, try alternative sources."""
        if not hasattr(self, '_seen_descriptions'):
            self._seen_descriptions = set()

        desc = _build_description(r)
        desc_hash = hash(desc[:200])

        if desc_hash in self._seen_descriptions:
            # Try alternative sources in priority order
            alternatives = [
                (r.get('summary') or '').strip(),
                (r.get('assistant_hl') or '').strip()[:200],
                (r.get('first_prompt') or '').strip()[:200],
                (r.get('context_text') or '').strip()[:200],
            ]
            for alt in alternatives:
                if alt and len(alt) >= 8 and hash(alt[:200]) not in self._seen_descriptions:
                    desc = alt
                    desc_hash = hash(desc[:200])
                    break

        self._seen_descriptions.add(desc_hash)
        return desc

    def analytics_data(self, fails_only: bool = False) -> dict[str, Any]:
        """Search log statistics. fails_only leaves out top_queries and recent."""
        conn = self._connect()
        total = conn.execute("SELECT COUNT(*) FROM search_log").fetchone()[0]
        avg_latency = conn.execute("SELECT AVG(pipeline_ms) FROM search_log").fetchone()[0]
        zero_results = conn.execute(
            "SELECT query, COUNT(*) as cnt FROM search_log WHERE result_count = 0 "
            "GROUP BY query ORDER BY cnt DESC LIMIT 20"
        ).fetchall()
        zero_count = conn.execute(
            "SELECT COUNT(*) FROM search_log WHERE result_count = 0"
        ).fetchone()[0]
        data: dict[str, Any] = {
            "total": total,
            "avg_latency_ms": avg_latency,
            "zero_result_count": zero_count,
            "zero_result_pct": (zero_count / total * 100) if total else 0,
            "zero_result_queries": [{"query": r[0], "count": r[1]} for r in zero_results],
        }
        if fails_only:
            return data

        top_queries = conn.execute(
            "SELECT query, COUNT(*) as cnt, AVG(result_count) as avg_results "
            "FROM search_log GROUP BY query ORDER BY cnt DESC LIMIT 15"
        ).fetchall()
        recent = conn.execute(
            "SELECT query, result_count, pipeline_ms, created_at "
            "FROM search_log ORDER BY created_at DESC LIMIT 10"
        ).fetchall()
        data["top_queries"] = [
            {"query": r[0], "count": r[1], "avg_results": r[2]} for r in top_queries
        ]
        data["recent"] = [
            {"query": r[0], "result_count": r[1], "pipeline_ms": r[2], "created_at": r[3]}
            for r in recent
        ]
        return data

    def _show_analytics(self, fails_only=False):
        """Show search log statistics with box-drawing layout."""
        data = self.analytics_data(fails_only)
        color = _use_color()
        R = "\033[0m" if color else ""
        BOLD = "\033[1m" if color else ""
        DIM = "\033[2m" if color else ""
        WHITE = "\033[38;5;255m" if color else ""
        CYAN = "\033[36m" if color else ""
        YELLOW = "\033[33m" if color else ""

        H = "\u2500"  # ─
        TL, TR, BL, BR = "\u256d", "\u256e", "\u2570", "\u256f"
        V = "\u2502"  # │
        ML, MR = "\u251c", "\u2524"  # ├ ┤

        tw = _get_term_width()
        bw = min(56, tw - 4)  # box width

        total = data["total"]

        if total == 0:
            print(f"\n  {DIM}No search history yet.{R}\n")
            return

        avg_latency = data["avg_latency_ms"]
        zero_results = data["zero_result_queries"]
        zero_count = data["zero_result_count"]
        zero_pct = data["zero_result_pct"]

        if fails_only:
            print()
            print(f"  {BOLD}{WHITE}Zero-Result Queries{R}  {DIM}({len(zero_results)} unique){R}")
            print(f"  {DIM}{H * bw}{R}")
            for row in zero_results:
                print(f"   {YELLOW}{row['count']:>3}\u00d7{R}  {row['query']}")
            print()
            return

        top_queries = data["top_queries"]
        recent = data["recent"]

        # ─── Summary Box ─────────────────────────────────
        title = "Search Analytics"
        total_str = f"{total} searches"
        inner = bw - 2
        spacing = inner - len(title) - len(total_str)
        print()
        print(f"  {DIM}{TL}{H * bw}{TR}{R}")
        print(f"  {DIM}{V}{R} {BOLD}{WHITE}{title}{R}{' ' * max(1, spacing)}{DIM}{total_str}{R} {DIM}{V}{R}")
        print(f"  {DIM}{ML}{H * bw}{MR}{R}")

        # Avg latency row
        latency_label = "Avg latency"
        latency_val = f"{avg_latency:.1f}ms"
        lat_space = inner - len(latency_label) - len(latency_val)
        print(f"  {DIM}{V}{R} {DIM}{latency_label}{R}{' ' * max(1, lat_space)}{CYAN}{latency_val}{R} {DIM}{V}{R}")

        # Zero-result row
        zr_label = "Zero-result"
        zr_val = f"{zero_pct:.1f}% ({zero_count}/{total})"
        zr_space = inner - len(zr_label) - len(zr_val)
        zr_color = YELLOW if zero_pct > 10 else DIM
        print(f"  {DIM}{V}{R} {DIM}{zr_label}{R}{' ' * max(1, zr_space)}{zr_color}{zr_val}{R} {DIM}{V}{R}")
        print(f"  {DIM}{BL}{H * bw}{BR}{R}")

        # ─── Top Queries ─────────────────────────────────
        print()
        print(f"  {BOLD}{WHITE}Top Queries{R}")
        print(f"  {DIM}{H * bw}{R}")
        for row in top_queries:
            count_str = f"{row['count']:>3}\u00d7"
            avg_str = f"avg {row['avg_results']:>2.0f} results"
            query_w = bw - len(count_str) - len(avg_str) - 4
            query_display = row["query"][:query_w].ljust(query_w)
            print(f"   {YELLOW}{count_str}{R}  {query_display}  {DIM}{avg_str}{R}")

        # ─── Failed Queries ──────────────────────────────
        if zero_results:
            print()
            print(f"  {BOLD}{WHITE}Failed Queries{R}  {DIM}(tuning targets){R}")
            print(f"  {DIM}{H * bw}{R}")
            for row in zero_results[:10]:
                print(f"   {YELLOW}{row['count']:>3}\u00d7{R}  {row['query']}")

        # ─── Recent Searches ─────────────────────────────
        print()
        print(f"  {BOLD}{WHITE}Recent Searches{R}")
        print(f"  {DIM}{H * bw}{R}")
        for row in recent:
            ts = row["created_at"]
            # Show just date portion for compactness
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                ts_short = dt.strftime("%m/%d %H:%M")
            except Exception:
                ts_short = ts[:16]
            res_str = f"{row['result_count']:>2} res"
            ms_str = f"{row['pipeline_ms']:>.0f}ms"
            meta = f"{res_str}  {ms_str}"
            query_w = bw - len(ts_short) - len(meta) - 4
            query_display = row["query"][:query_w].ljust(query_w)
            print(f"   {DIM}{ts_short}{R}  {query_display}{DIM}{meta}{R}")

        print()

    def close(self):
        if self.conn:
            self.conn.close()
            self.conn = None


# ─── Output Formatters ───────────────────────────────────

def format_relative_time(created_at, compact=False):
    try:
        dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        if compact:
            if delta.days == 0:
                hours = delta.seconds // 3600
                return f"{hours}h" if hours else f"{delta.seconds // 60}m"
            elif delta.days < 7:
                return f"{delta.days}d"
            elif delta.days < 30:
                return f"{delta.days // 7}w"
            elif delta.days < 365:
                return f"{delta.days // 30}mo"
            else:
                return f"{delta.days // 365}y"
        else:
            if delta.days == 0:
                hours = delta.seconds // 3600
                if hours == 0:
                    return f"{delta.seconds // 60}m ago"
                return f"{hours}h ago"
            elif delta.days == 1:
                return "yesterday"
            elif delta.days < 7:
                return f"{delta.days}d ago"
            elif delta.days < 30:
                return f"{delta.days // 7}w ago"
            else:
                return f"{delta.days // 30}mo ago"
    except Exception:
        return "?"


def _use_color():
    """Check if ANSI colors should be used. Disabled for pipes or explicit NO_COLOR."""
    return (sys.stdout.isatty()
            and not os.environ.get("NO_COLOR")
            and os.environ.get("TERM") != "dumb")


def _smart_truncate(text, max_len):
    """Truncate at word boundary with ellipsis."""
    if len(text) <= max_len:
        return text
    truncated = text[:max_len - 1].rsplit(" ", 1)[0]
    return truncated + "\u2026"


def _wrap_lines(text, width, max_lines=3):
    """Word-wrap text into up to max_lines lines. Returns list of strings."""
    text = " ".join(text.replace("\n", " ").split()).strip()
    lines = []
    while text and len(lines) < max_lines:
        if len(text) <= width:
            lines.append(text)
            text = ""
            break
        break_at = text[:width].rfind(" ")
        if break_at <= 0:
            break_at = width
        lines.append(text[:break_at].rstrip())
        text = text[break_at:].strip()
    # If text remains after max_lines, truncate last line
    if text and lines:
        last = lines[-1]
        if len(last) + len(text) + 1 > width:
            lines[-1] = _smart_truncate(last + " " + text, width)
    return lines if lines else [""]


def _truncate_tags(tags_str, max_len):
    """Truncate tags at complete tag boundaries with +N overflow."""
    if not tags_str:
        return ""
    # Normalize: always use ", " separator
    tags_str = ", ".join(t.strip() for t in tags_str.split(","))
    if len(tags_str) <= max_len:
        return tags_str
    tags = [t.strip() for t in tags_str.split(",")]
    result = []
    length = 0
    for tag in tags:
        needed = len(tag) + (2 if result else 0)
        if length + needed > max_len - 4:
            remaining = len(tags) - len(result)
            if remaining > 0:
                result.append(f"+{remaining}")
            break
        result.append(tag)
        length += needed
    return ", ".join(result)


def _build_description(r):
    """Build the best available description from session data.

    Priority: summary > cleaned context_text > first_prompt.
    Returns a single cleaned string suitable for multi-line wrapping.
    """
    summary = (r.get("summary") or "").strip()
    context = (r.get("context_text") or "").strip()
    first_prompt = (r.get("first_prompt") or "").strip()

    # Prefixes that add no information
    noise_prefixes = [
        "Implement the following plan:",
        "Implement the following plan: ",
        "/compact",
        "[Pasted text #1",
        "Wrote 1 memory",
        "Wrote 2 memories",
        "Wrote 3 memories",
    ]
    # Noise fragments that can appear anywhere at the start
    noise_patterns = [
        r'^\(ctrl\+o to expand\)\s*',
        r'^⏺\s*',
        r'^\[Pasted text #\d+ \+\d+ lines\]\s*',
    ]

    def clean_text(text):
        """Strip noise prefixes, markdown formatting, and normalize whitespace."""
        for prefix in noise_prefixes:
            if text.startswith(prefix):
                text = text[len(prefix):].strip()
                # After stripping, if it starts with a markdown header or bullet, strip that too
                text = re.sub(r'^#+\s+', '', text)
                text = re.sub(r'^[-*]\s+', '', text)
        for pat in noise_patterns:
            text = re.sub(pat, '', text)
        # Strip markdown bold/italic markers
        text = re.sub(r'\*{1,2}([^*]+)\*{1,2}', r'\1', text)
        # Strip markdown backticks
        text = text.replace('`', '')
        # Collapse whitespace
        text = " ".join(text.split())
        return text

    def is_useful(text):
        """Check if text provides meaningful session identification."""
        if not text or len(text) < 8:
            return False
        # Single-word commands or dots are not useful
        if text in (".", "..", "yes", "no", "ok", "commit this", "push", "No prompt"):
            return False
        if text.startswith("[Pasted text"):
            return False
        return True

    # 1. Summary is best (Claude-generated session description)
    if is_useful(summary):
        return summary

    # 2. Context text (first user messages from transcript — rich but needs cleaning)
    if context and len(context) > 30:
        cleaned = clean_text(context)
        if is_useful(cleaned):
            return cleaned

    # 3. First prompt (often garbage but sometimes useful)
    if is_useful(first_prompt):
        cleaned = clean_text(first_prompt)
        if is_useful(cleaned):
            return cleaned

    # 4. Assistant text (Claude's responses — outcomes, explanations)
    assistant = (r.get("assistant_hl") or r.get("assistant_text") or "").strip()
    if assistant and len(assistant) > 30:
        cleaned = clean_text(assistant)
        if is_useful(cleaned):
            return cleaned[:300]

    return "(no description)"


def _visible_len(text):
    """Return visible length of text, stripping ANSI escape codes."""
    return len(re.sub(r'\033\[[0-9;]*m', '', text))


def _pad_visible(text, width, align='left'):
    """Pad text to fixed visible width, accounting for ANSI escape codes."""
    pad = width - _visible_len(text)
    if pad <= 0:
        return text
    if align == 'right':
        return ' ' * pad + text
    return text + ' ' * pad


def _render_highlights(text, bold_start="\033[1;36m", bold_end="\033[0m"):
    """Convert \\x02...\\x03 FTS5 highlight markers to ANSI bold+cyan."""
    return text.replace("\x02", bold_start).replace("\x03", bold_end)


def _extract_highlight_snippet_legacy(text, max_len=100):
    """Extract a snippet around the first FTS5 highlight marker (legacy).

    Returns a plain string with \\x02/\\x03 markers preserved (caller renders ANSI).
    Returns empty string if no highlight markers found.
    """
    if not text or "\x02" not in text:
        return ""
    # Find position of first highlight marker
    marker_pos = text.index("\x02")
    # Strip markers for length calculation
    plain = text.replace("\x02", "").replace("\x03", "")
    # Find corresponding position in plain text
    plain_pos = len(text[:marker_pos].replace("\x02", "").replace("\x03", ""))
    # Calculate window around the match
    half = max_len // 2
    start = max(0, plain_pos - half)
    end = min(len(plain), plain_pos + half)
    snippet = plain[start:end].strip()
    # Truncation indicators
    prefix = "..." if start > 0 else ""
    suffix = "..." if end < len(plain) else ""
    snippet_with_ellipsis = f"{prefix}{snippet}{suffix}"
    # Re-apply highlight markers by finding the matched terms in the original
    # and doing case-insensitive replacement on the snippet
    terms = list({m.group(1) for m in re.finditer(r'\x02([^\x03]+)\x03', text)})
    for term in terms:
        pattern = re.compile(re.escape(term), re.IGNORECASE)
        snippet_with_ellipsis = pattern.sub(f"\x02{term}\x03", snippet_with_ellipsis)
    return snippet_with_ellipsis


def _score_and_select_snippets(result, max_snippets=2, max_len=100):
    """Score snippet candidates from FTS5 snippet() and return the best ones.

    Scores by: highlight marker density x source priority.
    Returns list of snippet strings with \\x02/\\x03 markers preserved.
    """
    SOURCE_PRIORITY = {
        'context_snip': 4,
        'assistant_snip': 3,
        'prompt_snip': 2,
        'aliases_snip': 1,
        'summary_snip': 0,  # summary already shown as description
    }
    candidates = []
    for key, priority in SOURCE_PRIORITY.items():
        snip = result.get(key, '')
        if not snip or '\x02' not in snip:
            continue
        # Score: highlight count x priority / text length
        hl_count = snip.count('\x02')
        plain_len = max(1, len(snip.replace('\x02', '').replace('\x03', '')))
        density = hl_count / plain_len
        score = density * (priority + 1)  # +1 so priority 0 still contributes
        # Truncate to max_len
        plain = snip.replace('\x02', '').replace('\x03', '')
        if len(plain) > max_len:
            snip = snip[:max_len + snip[:max_len].count('\x02') * 2 + snip[:max_len].count('\x03') * 2]
        candidates.append((score, key, snip))

    # Sort by score descending
    candidates.sort(key=lambda x: x[0], reverse=True)

    # Deduplicate: skip if >50% plain text overlap with already selected
    selected = []
    for score, key, snip in candidates:
        if len(selected) >= max_snippets:
            break
        plain = snip.replace('\x02', '').replace('\x03', '').lower()
        is_redundant = False
        for _, _, prev_snip in selected:
            prev_plain = prev_snip.replace('\x02', '').replace('\x03', '').lower()
            # Simple overlap check: shared words / total words
            words_a = set(plain.split())
            words_b = set(prev_plain.split())
            if words_a and words_b:
                overlap = len(words_a & words_b) / max(len(words_a), len(words_b))
                if overlap > 0.5:
                    is_redundant = True
                    break
        if not is_redundant:
            selected.append((score, key, snip))

    return [snip for _, _, snip in selected]


def _get_term_width():
    """Get terminal width, capped at 120. Fallback 80 for non-TTY."""
    try:
        tw = shutil.get_terminal_size().columns
    except (AttributeError, ValueError, OSError):
        tw = 80
    return min(tw, 120)


def _box_line(left, fill, right, width, dim="", reset=""):
    """Build a box-drawing line: left + fill*width + right."""
    return f"{dim}{left}{fill * width}{right}{reset}"


def format_table(results, elapsed_ms=0, pipeline=None, raw_query=None, explain=False, tokens=None):
    color = _use_color()
    R = "\033[0m" if color else ""
    BOLD = "\033[1m" if color else ""
    DIM = "\033[2m" if color else ""
    GREEN = "\033[32m" if color else ""
    CYAN = "\033[36m" if color else ""
    YELLOW = "\033[33m" if color else ""
    BLUE = "\033[38;5;33m" if color else ""
    MAGENTA = "\033[35m" if color else ""
    DIM_MAGENTA = "\033[2;35m" if color else ""
    WHITE = "\033[38;5;255m" if color else ""
    GRAY = "\033[90m" if color else ""
    BOLD_CYAN = "\033[1;36m" if color else ""

    H = "\u2500"  # horizontal: ─
    TL, TR, BL, BR = "\u256d", "\u256e", "\u2570", "\u256f"  # ╭╮╰╯
    V = "\u2502"  # │
    ML, MR = "\u251c", "\u2524"  # ├ ┤
    THIN_V = "\u250a"  # thin vertical: ┊

    tw = _get_term_width()
    cw = tw - 4  # content width (2 indent + 2 margin)

    if not results:
        # ─── Zero-Result Empty State ──────────────────────
        display_query = raw_query or "query"
        label = f'No results for "{display_query}"'
        box_inner = max(len(label) + 4, 48)
        print()
        print(f"  {DIM}{TL}{H * box_inner}{TR}{R}")
        print(f"  {DIM}{V}{R}  {YELLOW}{label}{R}{' ' * (box_inner - len(label) - 2)}{DIM}{V}{R}")
        print(f"  {DIM}{BL}{H * box_inner}{BR}{R}")

        if pipeline and raw_query:
            suggestions = pipeline.suggest_alternatives(raw_query)
            if suggestions:
                print(f"\n  {DIM}No results. Try:{R}")
                for query, count in suggestions:
                    print(f"    {CYAN}claude-search \"{query}\"{R}  {DIM}({count} results){R}")
            else:
                print(f"\n  {DIM}Suggestions:{R}")
            print(f"    {GREEN}\u2192{R} Use {CYAN}@project{R} to filter by project")
            print(f"    {GREEN}\u2192{R} Use {MAGENTA}#tag{R} to filter by tag")
        print()
        return

    # ─── Column Grid ──────────────────────────────────────
    # Fixed gutter: rank(2, right-aligned) + gap(2) = 4 chars
    # Content area: cw - 4 = description and metadata width
    GUTTER = 4        # rank + gap
    content = cw - GUTTER  # available for description/metadata

    # Metadata fixed columns (within content area, indented by GUTTER)
    COL_AGE  = 4      # "2d", "1w", "12mo" — right-aligned
    COL_MSGS = 9      # "  83 msgs", "2.4k msgs" — right-aligned number + " msgs"
    COL_SID  = 8      # "e6f2a0ee" — right-aligned at line end
    SEP_W    = 3      # " · " separator between columns (visible rhythm)
    # Tags fill remaining: content - age - sep - msgs - sep - sid
    # Session ID is right-aligned to terminal edge (no trailing separator)
    COL_TAGS = content - COL_AGE - SEP_W - COL_MSGS - SEP_W - COL_SID

    # ─── Header Card ──────────────────────────────────────
    title_text = "Session Search"
    meta_text = f"{len(results)} result{'s' if len(results) != 1 else ''} \u00b7 {elapsed_ms}ms"
    inner = cw - 2  # inside box padding
    spacing = inner - len(title_text) - len(meta_text)
    print()
    print(f"  {_box_line(TL, H, TR, cw, DIM, R)}")
    print(f"  {DIM}{V}{R} {BOLD}{WHITE}{title_text}{R}{' ' * max(1, spacing)}{DIM}{meta_text}{R} {DIM}{V}{R}")
    print(f"  {_box_line(BL, H, BR, cw, DIM, R)}")

    # ─── Result Rows ──────────────────────────────────────
    for i, r in enumerate(results, 1):
        age = format_relative_time(r["created_at"], compact=True)
        msgs = r["message_count"]
        sid = r["session_id"]
        is_legacy = sid.startswith("legacy-")
        short_id = "*" if is_legacy else sid[:8]
        tags_raw = r.get("tags", "")
        branch = (r.get("git_branch") or "").strip()

        # Build smart description with deduplication
        if pipeline:
            desc_raw = pipeline.build_deduped_description(r)
        else:
            desc_raw = _build_description(r)
        # Check if FTS5 highlight markers are available (keep raw \x02/\x03 for now)
        has_highlights = False
        if r.get("summary_hl") and "\x02" in r.get("summary_hl", ""):
            desc_raw = r["summary_hl"]
            has_highlights = True

        # Format message count (right-aligned number within COL_MSGS)
        if msgs >= 1000:
            msgs_num = f"{msgs / 1000:.1f}k"
        else:
            msgs_num = str(msgs)

        # Wrap description using raw markers (1 byte each, same visual width as nothing)
        # Strip markers for wrapping, then re-apply after
        desc_plain = desc_raw.replace("\x02", "").replace("\x03", "") if has_highlights else desc_raw
        desc_lines = _wrap_lines(desc_plain, content, max_lines=5)

        # Re-apply highlights to wrapped lines if present
        if has_highlights and color:
            HL_ON = "\033[1;36m"   # bold+cyan
            # Context-aware restore: \033[0m (full reset) clobbers surrounding
            # BOLD+WHITE on line 1 and DIM on continuation lines. Instead, reset
            # highlight attrs (bold+cyan) then re-apply the line style.
            HL_OFF_BOLD_WHITE = "\033[22;39;1;97m"  # end hl attrs, restore bold+bright-white
            HL_OFF_DIM = "\033[22;39;2m"            # end hl attrs, restore dim
            # Re-match highlight spans from original text onto wrapped lines
            # Simple approach: apply highlights per-line by finding matching terms
            highlighted_lines = []
            hl_text = r["summary_hl"]
            hl_terms = list({m.group(1) for m in re.finditer(r'\x02([^\x03]+)\x03', hl_text)})
            for line_idx, line in enumerate(desc_lines):
                hl_off = HL_OFF_BOLD_WHITE if line_idx == 0 else HL_OFF_DIM
                for term in hl_terms:
                    # Case-insensitive replacement preserving case
                    pattern = re.compile(re.escape(term), re.IGNORECASE)
                    line = pattern.sub(f"{HL_ON}{term}{hl_off}", line)
                highlighted_lines.append(line)
            desc_lines = highlighted_lines

        # Rank gutter: right-aligned number in 2 chars + 2-space gap
        rank_str = f"{i:>2}"

        # Line 1: rank + first description line (bold white)
        print(f"  {BOLD}{CYAN}{rank_str}{R}  {BOLD}{WHITE}{desc_lines[0]}{R}")

        # Lines 2+: continuation (indented to content column, dim for hierarchy)
        for line in desc_lines[1:]:
            print(f"  {' ' * GUTTER}{DIM}{line}{R}")

        # ─── Metadata (fixed-width columns) ───────────────
        # Age column (right-aligned in fixed width, dim)
        age_col = _pad_visible(f"{DIM}{age}{R}", COL_AGE, 'right')

        # Msgs column (right-aligned number + " msgs", bold cyan if >= 100)
        if msgs >= 100:
            msgs_col = _pad_visible(
                f"{BOLD_CYAN}{msgs_num}{R}{DIM} msgs{R}", COL_MSGS, 'right'
            )
        else:
            msgs_col = _pad_visible(f"{DIM}{msgs_num} msgs{R}", COL_MSGS, 'right')

        # Tags column (left-aligned, truncated to fit, magenta for differentiation)
        if branch and branch not in ("main", "master"):
            tag_parts = branch
            if tags_raw:
                tag_parts += f", {tags_raw}"
        else:
            tag_parts = tags_raw
        tags_display = _truncate_tags(tag_parts, COL_TAGS) if tag_parts else ""

        # Session ID column (right-aligned to terminal edge, cyan for actionable)
        sid_col = _pad_visible(f"{CYAN}{short_id}{R}", COL_SID, 'right')

        # Build metadata line: age · msgs · tags (right-aligned sid at edge)
        sep = f" {DIM}\u00b7{R} "
        if tags_display:
            tags_col = f"{MAGENTA}{tags_display}{R}"
            # Calculate padding to right-align session ID to terminal edge
            meta_left = f"{age_col}{sep}{msgs_col}{sep}{tags_col}"
            meta_left_vis = _visible_len(meta_left)
            sid_pad = content - meta_left_vis - COL_SID
            print(f"  {' ' * GUTTER}{meta_left}{' ' * max(1, sid_pad)}{sid_col}")
        else:
            meta_left = f"{age_col}{sep}{msgs_col}"
            meta_left_vis = _visible_len(meta_left)
            sid_pad = content - meta_left_vis - COL_SID
            print(f"  {' ' * GUTTER}{meta_left}{' ' * max(1, sid_pad)}{sid_col}")

        # ─── Ranked Snippets (best 1-2 from all content columns) ─────
        if color:
            HL_SNIPPET_ON = "\033[1;36m"   # bold+cyan
            HL_SNIPPET_OFF = "\033[0;90m"  # reset to gray (snippet text is dim)
            snippets = _score_and_select_snippets(r, max_snippets=2, max_len=content - 8)
            for snip_text in snippets:
                rendered = snip_text.replace("\x02", HL_SNIPPET_ON).replace("\x03", HL_SNIPPET_OFF)
                print(f"  {' ' * GUTTER}{GRAY}{THIN_V} {rendered}{R}")

        # A workflow result is a file, not a resumable session: show where it is.
        wf_path = workflow_result_path(sid)
        if wf_path:
            print(f"  {' ' * GUTTER}{GRAY}{THIN_V} workflow result: {wf_path}{R}")

        # Show chunk context indicator if result came from deep search
        if r.get("chunk_context"):
            chunk_info = r["chunk_context"]
            if color:
                print(f"  {' ' * GUTTER}{GRAY}{THIN_V} [{chunk_info}]{R}")

        # Explain match (if --explain flag is active)
        if explain and pipeline and raw_query and tokens:
            explanation = pipeline._explain_match(r, tokens, raw_query)
            if explanation:
                for exp_line in explanation.split('\n'):
                    print(f"  {' ' * GUTTER}{GRAY}{THIN_V}{R} {GRAY}{exp_line.strip()}{R}")

        # Separator (skip after last result)
        if i < len(results):
            print(f"  {DIM}{H * cw}{R}")

    # ─── Footer Card ──────────────────────────────────────
    print(f"  {_box_line(TL, H, TR, cw, DIM, R)}")
    footer_text = f"claude-search --resume N  \u00b7  --fzf for interactive"
    print(f"  {DIM}{V}{R} {GREEN}\u25cf{R}  {DIM}{footer_text}{R}{' ' * max(0, inner - len(footer_text) - 3)} {DIM}{V}{R}")
    print(f"  {_box_line(BL, H, BR, cw, DIM, R)}")
    print()


def format_fzf(results):
    """Tab-delimited output for fzf with ANSI colors."""
    for r in results:
        age = format_relative_time(r["created_at"])
        proj = r["project_name"][:20]
        desc = _build_description(r)[:70]
        branch = (r["git_branch"] or "")[:12]
        tags = r.get("tags", "")[:30]
        # session_id is last field (hidden, used for --preview)
        print(f"\033[33m{age:<8}\033[0m \033[35m{proj:<20}\033[0m {desc:<70} \033[32m{branch:<12}\033[0m {tags}\t{r['session_id']}")


def format_json(results):
    for r in results:
        wf = workflow_result_path(r.get("session_id", ""))
        if wf:
            r["workflow_path"] = wf
    print(json.dumps(results, indent=2, default=str))


_SESSION_FIELDS = (
    "session_id",
    "project_name",
    "project_path",
    "git_branch",
    "created_at",
    "modified_at",
    "message_count",
    "summary",
)
_HIGHLIGHT_MARKS = str.maketrans("", "", "\x02\x03")


def _without_marks(value: Any) -> Any:
    return value.translate(_HIGHLIGHT_MARKS) if isinstance(value, str) else value


def public_session(row: Mapping[str, Any]) -> dict[str, Any]:
    """A session's fixed fields in a --json document, whichever query produced the row."""
    session = {field: _without_marks(row.get(field)) for field in _SESSION_FIELDS}
    tags = _without_marks(row.get("tags")) or ""
    session["tags"] = [tag.strip() for tag in tags.split(",") if tag.strip()]
    session["workflow_path"] = workflow_result_path(row.get("session_id") or "")
    return session


def public_result(r: Mapping[str, Any], rank: int) -> dict[str, Any]:
    return {"rank": rank, **public_session(r), "score": r.get("final_score")}


def _resolved_line(pipeline: "QueryPipeline", row: Mapping[str, Any], n: int) -> str:
    sid = row["session_id"]
    # The result cache holds no project, and this line must not cost the caller its resume.
    if "project_name" not in row:
        try:
            row = pipeline.preview(sid) or row
        except sqlite3.Error:
            pass
    summary = " ".join(str(row.get("summary") or row.get("first_prompt") or "(no summary)").split())
    project = row.get("project_name") or "unknown project"
    return sanitize_display(f"Resolved #{n}: {summary[:80]} ({project}, {sid})")


def workflow_result_path(session_id: str) -> Optional[str]:
    """JSON path of a workflow result row (`wf_…`), or None for an ordinary session.

    A workflow result is indexed as its own row but is not a Claude session, so it cannot be
    resumed: the file itself is what a hit points at. The sweep records it in file_tracking.
    """
    if not session_id.startswith("wf_"):
        return None
    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
        try:
            row = conn.execute(
                "SELECT file_path FROM file_tracking WHERE session_id = ? LIMIT 1", (session_id,)
            ).fetchone()
        finally:
            conn.close()
        if row and row[0]:
            return str(row[0])
    except sqlite3.Error:
        pass
    for cfg in sorted(Path.home().glob(".claude*/projects")):
        for hit in cfg.glob(f"*/*/workflows/{session_id}.json"):
            return str(hit)
    return None


def _extract_last_messages(session_id, project_path, count=3):
    """Extract last N user messages from transcript JSONL file."""
    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.is_dir():
        return []
    # Encode project path: /Users/foo/bar → -Users-foo-bar
    if project_path and project_path != "unknown":
        encoded = project_path.replace("/", "-")
        if not encoded.startswith("-"):
            encoded = "-" + encoded
        transcript = projects_dir / encoded / f"{session_id}.jsonl"
    else:
        transcript = None

    # Try encoded path, then scan all project dirs
    paths_to_try = []
    if transcript and transcript.exists():
        paths_to_try.append(transcript)
    else:
        for d in projects_dir.iterdir():
            candidate = d / f"{session_id}.jsonl"
            if candidate.exists():
                paths_to_try.append(candidate)
                break

    if not paths_to_try:
        return []

    msgs = []
    try:
        with open(paths_to_try[0], encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                    if d.get("type") != "user":
                        continue
                    content = d.get("message", {}).get("content", "")
                    if isinstance(content, list):
                        text = " ".join(
                            c.get("text", "") for c in content
                            if isinstance(c, dict) and c.get("type") == "text"
                        )
                    else:
                        text = str(content)
                    text = text.strip()
                    if not text or len(text) < 8:
                        continue
                    if text.startswith("<") or text.startswith("<!--"):
                        continue
                    msgs.append(text[:300])
                except Exception:
                    pass
    except OSError:
        pass

    return msgs[-count:] if msgs else []


def format_preview(session):
    # ─── Compact metadata header ─────────────────────────
    age = format_relative_time(session['created_at'], compact=True)
    msgs = session['message_count']
    sid = session['session_id'][:8]
    branch = (session.get('git_branch') or '').strip()
    proj = session['project_name'][:30]

    print(f"\033[1;33m{proj}\033[0m  \033[2m{age} \u00b7 {msgs} msgs \u00b7 {sid}\033[0m")
    if branch and branch not in ("main", "master"):
        print(f"\033[2;32m{branch}\033[0m")
    if session.get("tags"):
        tags_display = ", ".join(t.strip() for t in session['tags'].split(',')[:5])
        print(f"\033[2;35m{tags_display}\033[0m")

    wf_path = workflow_result_path(session["session_id"])
    if wf_path:
        print(f"\033[1;36mWorkflow result\033[0m (not a resumable session): {wf_path}")

    # ─── Description (no pre-wrapping — let fzf handle it) ─
    desc = _build_description(session)
    if desc and desc != "(no description)":
        print()
        print(f"\033[1;33mAbout\033[0m:")
        # Print full description up to 800 chars, fzf wraps to pane width
        print(f"  {desc[:800]}")

    # ─── Conversation Timeline (from transcript) ─────────
    last_msgs = _extract_last_messages(
        session["session_id"], session.get("project_path", ""), count=7
    )
    if last_msgs:
        print()
        print(f"\033[1;35mRecent Messages\033[0m:")
        for i, msg in enumerate(last_msgs, 1):
            clean = " ".join(msg.split())[:250]
            print(f"  \033[2m{i}.\033[0m {clean}")
    elif session.get("first_prompt"):
        fp = " ".join(session["first_prompt"].split())[:250]
        if len(fp) > 10:
            print()
            print(f"\033[1;35mFirst Message\033[0m:")
            print(f"  {fp}")


# ─── Result Caching ──────────────────────────────────────

def _cache_results(results):
    """Cache search results for --resume without repeating query."""
    text = json.dumps(
        [{"session_id": r["session_id"], "summary": r.get("summary", ""),
          "first_prompt": r.get("first_prompt", ""), "message_count": r.get("message_count", 0)}
         for r in results],
        default=str
    )
    try:
        atomic_write_text(CACHE_PATH, text)
    except OSError as err:
        warn(
            "partial_failure",
            f"Couldn't save results to ~/.claude/.last-search-results.json: {err}. "
            "claude-search --resume N may use an older search.",
        )
        # A result number must not resolve against a list the user no longer sees. In a directory
        # that refuses the write, this refuses too, which is the warning's "may".
        try:
            CACHE_PATH.unlink(missing_ok=True)
        except OSError:
            pass


def _cache_read_error(detail: object) -> CliError:
    return CliError(
        f"Can't read the result cache at ~/.claude/.last-search-results.json: {detail}.",
        recovery=(("Run the search again:", 'claude-search "<QUERY>"'),),
    )


def _load_cached_results():
    """Load cached results from last search. No file means no earlier search, which is not an error."""
    try:
        results = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []
    # ValueError: both JSONDecodeError and UnicodeDecodeError.
    except (OSError, ValueError) as err:
        raise _cache_read_error(err) from err
    if not isinstance(results, list) or not all(
        isinstance(r, dict) and isinstance(r.get("session_id"), str) for r in results
    ):
        raise _cache_read_error("it isn't a list of results")
    return results


# ─── CLI ──────────────────────────────────────────────────

def main():
    global MODE
    parser = build_parser()
    args = parser.parse_args()
    MODE = resolve_mode(
        no_color=args.no_color,
        json_mode=args.json,
        debug=args.debug,
        non_interactive=args.non_interactive,
    )
    validate_args(parser, args)

    if not DB_PATH.exists():
        raise CliError(
            "Can't search: no index at ~/.claude/session-index.db.",
            reason="not_found",
            status="action_required",
            recovery=(("Build it:", "~/.claude/bin/session-index-backfill.sh"),),
        )

    pipeline = QueryPipeline()

    try:
        if args.stats:
            s = pipeline.stats()
            if args.json:
                emit_json({"stats": s})
                return
            color = _use_color()
            R = "\033[0m" if color else ""
            BOLD = "\033[1m" if color else ""
            DIM = "\033[2m" if color else ""
            WHITE = "\033[38;5;255m" if color else ""
            CYAN = "\033[36m" if color else ""

            _H = "\u2500"
            _TL, _TR, _BL, _BR = "\u256d", "\u256e", "\u2570", "\u256f"
            _V = "\u2502"
            _ML, _MR = "\u251c", "\u2524"

            bw = 52
            inner = bw - 2
            print()
            print(f"  {DIM}{_TL}{_H * bw}{_TR}{R}")
            title = "Session Index"
            total_str = f"{s['total']} sessions"
            sp = inner - len(title) - len(total_str)
            print(f"  {DIM}{_V}{R} {BOLD}{WHITE}{title}{R}{' ' * max(1, sp)}{CYAN}{total_str}{R} {DIM}{_V}{R}")
            print(f"  {DIM}{_ML}{_H * bw}{_MR}{R}")

            rows = [
                ("Tagged", str(s['tagged'])),
                ("Projects", str(s['projects'])),
                ("Last indexed", s['last_indexed'] or "never"),
            ]
            for label, val in rows:
                sp = inner - len(label) - len(val)
                print(f"  {DIM}{_V}{R} {DIM}{label}{R}{' ' * max(1, sp)}{val} {DIM}{_V}{R}")
            print(f"  {DIM}{_BL}{_H * bw}{_BR}{R}")

            print()
            print(f"  {BOLD}{WHITE}By Source{R}")
            print(f"  {DIM}{_H * bw}{R}")
            for src, cnt in s["by_source"]:
                print(f"   {src:<20} {DIM}{cnt}{R}")

            print()
            print(f"  {BOLD}{WHITE}Top Projects{R}")
            print(f"  {DIM}{_H * bw}{R}")
            for proj, cnt in s["by_project"]:
                print(f"   {proj:<35} {DIM}{cnt}{R}")
            print()
            return

        if args.analytics:
            if args.json:
                emit_json({"analytics": pipeline.analytics_data(args.fails)})
                return
            pipeline._show_analytics(fails_only=args.fails)
            return

        if args.context_inject:
            result = pipeline.context_inject(args.context_inject)
            print(result)
            return

        if args.preview:
            session = pipeline.preview(args.preview)
            if session is None:
                raise CliError(
                    f"Couldn't find session {sanitize_display(args.preview)}.",
                    reason="not_found",
                    recovery=(("Find its ID:", 'claude-search "<QUERY>"'),),
                )
            if args.json:
                emit_json(
                    {
                        "session": {
                            **public_session(session),
                            "first_prompt": _without_marks(session.get("first_prompt")),
                        }
                    }
                )
            elif args.format == "json":
                print(json.dumps(session, default=str))
            else:
                format_preview(session)
            return

        query = " ".join(args.query)

        # --resume-result N: resume a result by number
        if args.resume_result is not None:
            n = args.resume_result
            if query:
                # Run search first, then resume result N
                results = pipeline.search(
                    query, limit=args.limit, project_filter=args.project,
                    date_after=args.after, date_before=args.before,
                    min_messages=args.min_msgs,
                    deep_search=args.deep_search,
                )
                _cache_results(results)
            else:
                # Use cached results from last search
                results = _load_cached_results()

            if not results:
                if query:
                    raise CliError(f'No sessions match "{query}".', reason="not_found")
                raise CliError(
                    "No cached results to resume.",
                    code=2,
                    reason="missing_query",
                    status="action_required",
                    recovery=(
                        ("Search first:", 'claude-search "<QUERY>"'),
                        ("Then resume by number:", "claude-search --resume 1"),
                    ),
                )
            if n > len(results):
                raise CliError(
                    f"Result #{n} is out of range: the last search returned "
                    f"{plural(len(results), 'result')}.",
                    code=2,
                    reason="invalid_arguments",
                    status="action_required",
                    recovery=(("Pick one in range:", "claude-search --resume 1"),),
                )
            sid = results[n - 1]["session_id"]
            if sid.startswith("legacy-"):
                raise CliError(
                    f"Result #{n} is a legacy session and cannot be resumed.", reason="not_found"
                )
            wf_path = workflow_result_path(sid)
            if wf_path or sid.startswith("wf_"):
                refusal = f"Result #{n} is a workflow result, not a session: {wf_path or sid}"
                if args.json:
                    raise CliError(refusal, reason="not_found")
                # tests/workflow-index-test.sh compares this line exactly, so it takes no "Error:" prefix.
                print(sanitize_display(refusal), file=sys.stderr)
                sys.exit(1)
            if args.json:
                emit_json({"session": {"session_id": sid, "rank": n}})
                return
            print(_resolved_line(pipeline, results[n - 1], n), file=sys.stderr)
            # Output the session ID for the bash wrapper to exec
            print(sid)
            return

        if not query:
            parser.error("missing search query")

        t0 = time.monotonic()
        with spinner("Searching…", MODE):
            results = pipeline.search(
                query,
                limit=args.limit,
                project_filter=args.project,
                date_after=args.after,
                date_before=args.before,
                min_messages=args.min_msgs,
                deep_search=args.deep_search,
            )
        elapsed_ms = int((time.monotonic() - t0) * 1000)

        pipeline.log_search(query, len(results), pipeline_ms=elapsed_ms)
        _cache_results(results)

        # Reset dedup tracking before rendering
        pipeline.reset_dedup()

        if args.json:
            emit_json(
                {
                    "sessions": [public_result(r, rank=i) for i, r in enumerate(results, 1)],
                    "pagination": {"next": None},
                }
            )
        elif args.format == "fzf":
            format_fzf(results)
        elif args.format == "json":
            format_json(results)
        else:
            final_tokens = getattr(pipeline, '_final_tokens', [])
            format_table(results, elapsed_ms, pipeline=pipeline, raw_query=query,
                         explain=args.explain, tokens=final_tokens)

    finally:
        pipeline.close()


if __name__ == "__main__":
    run_cli(main)
