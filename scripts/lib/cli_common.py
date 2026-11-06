#!/usr/bin/env python3
"""CLI contract shared by the maintenance scripts.

The engine keeps its own copy because bin/session-search.py must stay one copyable
file; tests/test_scripts_common.py holds the two equal. Scripts load this module with
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib")).

backfill.sh runs `python3 cli_common.py parse-time VALUE [--min-days N]`, so shell and
Python share one time grammar.
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import traceback
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, NoReturn, Optional, TextIO

ISSUES_URL = "https://github.com/renchris/claude-session-search/issues"
_RECOVERY_REBUILD = (("Rebuild it:", "~/.claude/bin/session-index-backfill.sh"),)
_TINT = "\033[33m"
_RESET = "\033[0m"
# name -> (rich, plain). Plain warnings and errors keep their R205 prefixes.
_GLYPHS = {
    "success": ("✓", "Done:"),
    "warning": ("!", "Warning:"),
    "error": ("✗", "Error:"),
    "ellipsis": ("…", "..."),
}


def _read_version() -> str:
    # A copied module has no VERSION beside it, and a failed import here would be hidden
    # by install.sh's `2>/dev/null || true`, so a missing file is never fatal.
    try:
        path = Path(__file__).resolve().parents[2] / "VERSION"
        return path.read_text(encoding="utf-8").strip() or "unknown"
    except (OSError, IndexError, UnicodeDecodeError):
        return "unknown"


VERSION = _read_version()


def parse_time(value: str, min_days: Optional[int] = None) -> float:
    try:
        relative = re.fullmatch(r"([0-9]+)([dhm]?)", value)
        if relative:
            unit = {"": "days", "d": "days", "h": "hours", "m": "minutes"}[relative[2]]
            amount = int(relative[1])
            # Only a count of days has a floor: backfill passes --min-days 1 and still
            # accepts 12h and ISO dates.
            if min_days is not None and unit == "days" and amount < min_days:
                raise argparse.ArgumentTypeError(
                    f"The window must be at least {plural(min_days, 'day')}."
                )
            moment = datetime.now(timezone.utc) - timedelta(**{unit: amount})
        else:
            # Python 3.10's fromisoformat does not accept a trailing Z.
            text = value[:-1] + "+00:00" if value.endswith("Z") else value
            parsed = datetime.fromisoformat(text)
            if parsed.tzinfo is None:
                moment = parsed.replace(tzinfo=timezone.utc)
            else:
                moment = parsed.astimezone(timezone.utc)
        return moment.timestamp()
    except (ValueError, OverflowError) as exc:
        raise argparse.ArgumentTypeError(
            "Times use ISO 8601 (2026-03-01) or a relative value (7d, 12h)."
        ) from exc


_ESCAPE_SEQUENCE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"  # CSI
    r"|\x1b[\]PX^_].*?(?:\x07|\x1b\\|\Z)"  # OSC, DCS, SOS, PM, APC
    r"|\x1b[ -/]*[0-~]",  # any other escape sequence
    re.DOTALL,
)
_WHITESPACE_TO_SPACE = str.maketrans("\t\n\r", "   ")


def sanitize_display(s: str) -> str:
    if s.isprintable():
        return s
    kept = []
    for ch in _ESCAPE_SEQUENCE.sub("", s).translate(_WHITESPACE_TO_SPACE):
        code = ord(ch)
        is_control = code < 0x20 or 0x7F <= code <= 0x9F
        if not is_control and unicodedata.category(ch) != "Cf":
            kept.append(ch)
    return "".join(kept)


def plural(n: int, one: str, many: Optional[str] = None) -> str:
    return f"{n} {one if n == 1 else (many or one + 's')}"


def fmt_duration(seconds: float) -> str:
    seconds = max(seconds, 0.0)
    # Each branch tests the rounded value, so 0.9996 reads 1.0s and 59.96 reads 1m 0s.
    millis = round(seconds * 1000)
    if millis < 1000:
        return f"{millis}ms"
    tenths = round(seconds * 10)
    if tenths < 600:
        return f"{tenths / 10:.1f}s"
    minutes, secs = divmod(round(seconds), 60)
    if minutes < 60:
        return f"{minutes}m {secs}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes}m {secs}s"


def _isatty(stream: Optional[TextIO]) -> bool:
    # A closed or missing std stream (hooks may run with fds closed) is simply not a terminal.
    try:
        return stream is not None and stream.isatty()
    except (ValueError, OSError):
        return False


@dataclass(frozen=True)
class Style:
    colour: bool
    rich: bool


def resolve_style(stream: Optional[TextIO], no_color: bool = False) -> Style:
    env = os.environ
    tty = _isatty(stream) and env.get("TERM") != "dumb"
    # __SESSION_SEARCH_NO_COLOR is how --no-color reaches child scripts and run_cli's
    # error path, which never sees the parsed flag.
    if no_color or env.get("__SESSION_SEARCH_NO_COLOR") == "1" or env.get("NO_COLOR"):
        colour = False
    elif env.get("FORCE_COLOR"):
        colour = env["FORCE_COLOR"] != "0"
    else:
        colour = tty
    # Colour never decides rich: NO_COLOR keeps the layout, forced colour on a pipe adds none.
    return Style(
        colour=colour, rich=tty and env.get("SESSION_SEARCH_ACCESSIBLE") != "1"
    )


def glyph(name: str, style: Style) -> str:
    rich, plain = _GLYPHS[name]
    return rich if style.rich else plain


class CliError(Exception):
    def __init__(
        self,
        message: str,
        *,
        code: int = 1,
        rows: tuple[str, ...] = (),
        recovery: tuple[tuple[str, str], ...] = (),
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.rows = tuple(rows)
        self.recovery = tuple(recovery)[:2]


def _write_err(text: str) -> None:
    try:
        sys.stderr.write(text)
        sys.stderr.flush()
    except (OSError, ValueError, AttributeError):
        pass  # A closed stderr must not change the exit code.


def _print_error(
    headline: str,
    rows: tuple[str, ...] = (),
    recovery: tuple[tuple[str, str], ...] = (),
) -> None:
    style = resolve_style(sys.stderr)
    prefix = glyph("error", style)
    if style.colour:
        prefix = f"{_TINT}{prefix}{_RESET}"
    lines = [f"{prefix} {sanitize_display(headline)}"]
    lines += [sanitize_display(row) for row in rows]
    for instruction, command in recovery:
        lines += [
            "",
            sanitize_display(instruction.rstrip(":")) + ":",
            f"    {sanitize_display(command)}",
        ]
    _write_err("\n".join(lines) + "\n")


def _report_bug(exc: Exception, prog: str) -> None:
    if os.environ.get("SESSION_SEARCH_DEBUG"):
        _write_err("".join(traceback.format_exception(exc)))
    frames = traceback.extract_tb(exc.__traceback__)
    # Type and basename only: the exception's message can hold argv or path text.
    location = (
        f"{os.path.basename(frames[-1].filename)}:{frames[-1].lineno}"
        if frames
        else "unknown"
    )
    python = ".".join(str(part) for part in sys.version_info[:3])
    _print_error(
        f"Unexpected error in {prog}. This is a bug in claude-session-search.",
        rows=(
            f"Error:   {type(exc).__name__} at {location}",
            f"Version: {prog} {VERSION}, Python {python}, {sys.platform}",
        ),
        recovery=(("Report it:", ISSUES_URL),),
    )


def detach_stdout() -> None:
    """Point stdout at devnull, so the exit-time flush cannot turn the outcome into 120."""
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, sys.stdout.fileno())
    except (OSError, ValueError, AttributeError):
        pass  # stdout has no descriptor, so no exit-time flush can fail.
    finally:
        os.close(devnull)


def _run_main(main_fn: Callable[[], Optional[int]], prog: str) -> Any:
    try:
        return main_fn() or 0
    except SystemExit as exc:
        return exc.code
    except BrokenPipeError:
        # main_fn computed no outcome: a read lost its reader, which is a quiet success.
        # A command that mutates guards its own prints, so it returns its real code.
        return 0
    except CliError as err:
        _print_error(err.message, err.rows, err.recovery)
        return err.code
    except KeyboardInterrupt:
        _write_err("Canceled.\n")
        return 130
    except sqlite3.Error as exc:
        db_path = Path.home() / ".claude" / "session-index.db"
        _print_error(
            f"Could not read session index {db_path}: {exc}",
            recovery=_RECOVERY_REBUILD,
        )
        return 1
    except Exception as exc:
        _report_bug(exc, prog)
        return 1


def run_cli(main_fn: Callable[[], Optional[int]], prog: str) -> NoReturn:
    code = _run_main(main_fn, prog)
    # Flush here on every path: a failure at interpreter exit overrides any code with 120.
    try:
        sys.stdout.flush()
    except OSError:
        detach_stdout()
    except (ValueError, AttributeError):
        pass  # stdout is closed or absent.
    sys.exit(code)


def emit_json(doc: Any) -> None:
    if _isatty(sys.stdout):
        text = json.dumps(doc, indent=2, default=str)
    else:
        text = json.dumps(doc, separators=(",", ":"), default=str)
    sys.stdout.write(text + "\n")


def _whole_days(value: str) -> int:
    if not re.fullmatch(r"[0-9]+", value):
        raise argparse.ArgumentTypeError("must be a whole number of days")
    return int(value)


def _main() -> int:
    parser = argparse.ArgumentParser(
        prog="cli_common.py", description="Shared CLI helpers for shell scripts."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    parse = commands.add_parser(
        "parse-time", help="Print a time value as a whole epoch."
    )
    parse.add_argument("value", metavar="VALUE")
    parse.add_argument("--min-days", type=_whole_days, metavar="N")
    args = parser.parse_args()
    try:
        epoch = parse_time(args.value, args.min_days)
    except argparse.ArgumentTypeError as exc:
        raise CliError(str(exc), code=2) from exc
    print(int(epoch))
    return 0


if __name__ == "__main__":
    run_cli(_main, "cli_common.py")
