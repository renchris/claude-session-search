---
status: in-progress
---

# Remediation plan: claude-session-search (CLI design guidelines, vendor-neutral)

> Status 2026-11-07: Waves A and B landed (record in §8). Open: Wave C decisions (§4, all filed) and the width follow-up unit (§8.3).

Inputs: 25 verified findings (unit `claude-search`; verifier dropped none; none Vercel-specific), /tmp/cli-bp/checklist.md, /tmp/cli-bp/guidelines.md.
Method: static reading only. No CLI under audit was executed. Line numbers are from `main` @ b765dda.
Round 2 inputs: 58 further verified findings (unit `css-scripts`: install.sh, uninstall.sh, session-index-backfill.sh, session-index-chunk.py, session-index-tag.py, session-index-tag.sh, and one scope-wide test finding; none Vercel-specific) and /tmp/cli-bp/critic2.json. Text added or changed in round 2 is marked "(Round 2)", and §7 lists every change. Round 2 method: the same static reading, plus `bash -n`, `shellcheck`, `ruff --no-cache`, Python `ast.parse` and read-only `git show origin/main:<file>`. Nothing was written to any repo.

---

## 1. Header

**Repo:** /Users/chrisren/Development/claude-session-search (origin github.com/renchris/claude-session-search), branch `main` @ b765dda.

**CLIs covered**
- `claude-search`: bash wrapper, `bin/claude-search` (169 lines). It owns `--fzf` and `--resume` and hand-parses argv at :29-56.
- `session-search.py`: argparse engine, `bin/session-search.py` (1926 lines). Parser at :1760-1776, dispatch in `main()` at :1759-1922.
- Both are installed as symlinks into `~/.claude/bin` (install.sh:147-148). ci.yml:21, demo.yml:57 and assets/demo/build.sh:16-17 copy exactly these two files.
- Also touched: `scripts/session-index-backfill.sh` (one opt-in flag) and `assets/demo/fzf-demo.tape` (one hidden setup line).
- (Round 2) Maintenance CLIs, all reachable by users and all now in scope:
  - `install.sh` (321 lines) and `uninstall.sh` (109): run from the checkout, no argv handling today.
  - `scripts/session-index-backfill.sh` (676): symlinked to `~/.claude/bin` (install.sh:150), hand-parsed options at :19-26.
  - `scripts/session-index-chunk.py` (289): symlinked (install.sh:151), argparse at :245-250.
  - `scripts/session-index-tag.py` (1075): symlinked (install.sh:149), argparse at :675-710.
  - `scripts/session-index-tag.sh` (15): a pass-through wrapper, taught by README.md:277 and :280, not on PATH.
  - Shared by them: `scripts/lib/progress-ui.sh` (346; install.sh:26, backfill:13) and `hooks/lib/session-index-helpers.sh` (608; backfill:12 and the hooks).
- (Round 2) Still out of scope: the hooks themselves, because their stdin JSON contract belongs to Claude Code. They appear below only as callers.

**Repo rules found**
- No `CLAUDE.md`, `.claude/CLAUDE.md` or `.claude/rules/` exist (checked with `ls`).
- `.claude/settings.local.json` holds only allow rules. Nothing in the repo blocks the changes below.
- Conventions inferred from `git log`: conventional-commit subjects (`feat:`, `fix:`, `ci:`, `docs:`, `chore:`), direct commits to `main`, no merge commits.
- (Round 2) Rechecked with `git ls-files`: no CLAUDE.md, AGENTS.md or rules file is tracked, and there is no package.json, pyproject or node_modules step, so this plan has no install gate to keep or drop. The only documented constraint found for the scripts is the installer's "idempotent, safe to re-run" claim (install.sh:4, README.md:79).

**Dirty state** (`git status --porcelain` at plan time): `?? .venv/` and `?? docs/`.
- Both are untracked. Do not touch them or stage them.
- `docs/` is untracked as a whole, so verdict suggestions to edit `docs/SESSION_RESUME_UX_DESIGN.md` are dropped (see §5).
- Stage explicit paths only. Never `git add -A` or `git add .`.
- (Round 2) Local `main` is 4 commits behind `origin/main` (measured: `git status --branch`). Landing flow step 0 handles that.
- (Round 2) `scripts/__pycache__/` holds `.pyc` files from the round 2 verifiers' `py_compile` runs. The path is gitignored (.gitignore:6) and harmless.

**Invariants every unit must keep** (from the verdicts' caller census)
1. `session-search.py --context-inject <DIR>` stdout stays one string with exit 0. Two hooks pass it through `jq -Rs` without parsing it: hooks/session-index-start.sh:23 here, and claude-infrastructure/hooks/session-index-start.sh:46.
2. `--resume-result N` stdout stays exactly one bare session-ID line. The wrapper captures it.
3. `--format=fzf` rows keep `session_id` as the last tab-separated field. bin/claude-search:125, :128, :129 and :141 depend on it.
4. `--format json` output stays byte-identical (bare array, `indent=2`) until C1's removal step. (Round 2) On `origin/main` that array already carries `workflow_path` on `wf_` rows, so "byte-identical" means relative to that. C1's deprecation warning goes to stderr and does not touch this stdout.
5. The command name `claude-search` stays, and `claude-search '<nouns>' --deep-search` must keep searching.
   - claude-infrastructure/hooks/lib/episodic_cue.sh:162 emits that command.
   - scripts/episodic-cue-outcome.py:83 and :105 substring-match on it.
6. `bin/claude-search` must keep running on `#!/bin/bash`, which is bash 3.2 on macOS.
   - Keep the `${ARR[@]+"${ARR[@]}"}` form for possibly-empty arrays under `set -u`.
   - Do not use `mapfile`, associative arrays or `${v,,}`.
   - `printf -v` and `%q` are fine.
7. New environment variables use the existing `SESSION_SEARCH_` prefix (SESSION_SEARCH_REPO and SESSION_SEARCH_PYTHON_DEPS already exist): `SESSION_SEARCH_DEBUG`, `SESSION_SEARCH_GUIDANCE_DISABLED` (Round 2: replaces `SESSION_SEARCH_NO_TIPS`, because R238 and Reference C name it), `SESSION_SEARCH_ACCESSIBLE` (Round 2: R080, R121), `SESSION_SEARCH_NO_LLM`, `SESSION_SEARCH_FZF_LLM`. Some verdicts proposed `CLAUDE_SEARCH_*` or `CLAUDE_SESSION_SEARCH_*`; that is normalized here for R009. (Round 2) Internal variables use `__SESSION_SEARCH_` and never appear in help (R079): `__SESSION_SEARCH_PICKER`, `__SESSION_SEARCH_NO_COLOR`, `__SESSION_SEARCH_PARSE_ONLY`.
8. Python floor is already 3.10, because session-search.py:277 evaluates PEP 604 `str | None` at def time. Local interpreter is 3.11.4 (measured with `python3 --version`). (Round 2) README.md:93 still says 3.8; U7 corrects it.
9. (Round 2) `scripts/session-index-backfill.sh --quiet` and `--since 7 --quiet` keep parsing and keep exit 0 on success.
   - Callers: install.sh:214 (bare, under `set -euo pipefail` at :5), bin/session-search.py:268 (detached, both streams to DEVNULL), config/com.claude.session-search-backfill.plist:11 (`2>&1 | head -50 >> log`) and claude-infrastructure/launchd/com.claude.session-search-backfill.plist:11 (records `verdict=ok|FAILED rc=N`, exits with rc).
   - Non-TTY output must stay under those plists' 50 lines (about 17 today, estimated by counting the header, phases and summary), because the repo plist's `head` would close the pipe and SIGPIPE would kill the run before `last_backfill` is written.
10. (Round 2) `session-index-chunk.py --backfill [--since <whole days>]` keeps exit 0 for skips. Caller: backfill :648 and :650, bare under `set -e` (:8) with stderr discarded.
11. (Round 2) `session-index-tag.py --regex-only --limit 1000 --quiet` stays valid. Caller: install.sh:217 (`2>/dev/null || true`), which also hides an ImportError, so any new import is tested through the `~/.claude/bin` symlink.
12. (Round 2) Bare `./install.sh`, `git pull && ./install.sh` (README.md:103) and bare `./uninstall.sh` stay non-interactive and exit 0 on a clean machine.
13. (Round 2) The lock file path `~/.claude/session-index.lock` stays shared: helpers:62 and tag.py:736. The session-end and sweep hooks skip while it is held (hooks/session-index-end.sh:30-33, hooks/session-index-sweep.sh:25-28). A live machine's hooks use claude-infrastructure's copy of the helpers, which locks with `mkdir` and refuses on timeout (claude-infrastructure/hooks/lib/session-index-helpers.sh:158-190), so this repo cannot change the lock primitive alone (C10).
14. (Round 2) `session-index.db` survives uninstall (uninstall.sh:3, :107; README.md:103). Tests assert it stays.
15. (Round 2) Once `origin/main` is merged, `wf_*` rows are not resumable: `--resume-result` refuses them (origin/main bin/session-search.py:1915-1918) and fzf Enter previews them (origin/main bin/claude-search:143-146). Every resume row below keeps that.

**Gates** (run from the repo root; exact commands)
- **G1** `for f in bin/claude-search tests/smoke-test.sh scripts/session-index-backfill.sh; do bash -n "$f" || exit 1; done`
  - (Round 2) Add `install.sh uninstall.sh scripts/session-index-tag.sh scripts/lib/progress-ui.sh hooks/lib/session-index-helpers.sh`, and `scripts/lib/cli-common.sh scripts/lib/settings-edit.sh` once U11a lands. All pass `bash -n` at baseline (measured).
- **G2** `python3 -m py_compile bin/session-search.py`
  - (Round 2) Add `scripts/session-index-tag.py scripts/session-index-chunk.py`, and `scripts/lib/cli_common.py` once U11b lands.
- **G3** `shellcheck bin/claude-search tests/smoke-test.sh tests/helpers.bash`. New or rewritten files must be clean.
  - Baseline measured with `shellcheck -f gcc <f> | wc -l`: bin/claude-search 0, tests/smoke-test.sh 1.
  - For `scripts/session-index-backfill.sh` (baseline 20, measured the same way) the gate is no increase.
  - (Round 2) More baselines, measured the same way, gate is no increase: install.sh 3, uninstall.sh 0, scripts/session-index-tag.sh 0, scripts/lib/progress-ui.sh 7, hooks/lib/session-index-helpers.sh 22. The new `scripts/lib/*.sh` and `tests/*.bash` files must be clean.
- **G4** `ruff check --no-cache --select E9,F63,F7,F82 bin/session-search.py tests/`. Clean at baseline (measured).
  - Full `ruff check --no-cache bin/session-search.py` reports 8 pre-existing findings (measured). That count must not grow.
  - The repo has no ruff config. Always pass `--no-cache` so nothing is written into the repo.
  - (Round 2) Add `scripts/session-index-tag.py scripts/session-index-chunk.py scripts/lib/cli_common.py` to the select run, clean at baseline (measured). Full runs report 2 on tag.py and 0 on chunk.py (measured). Those counts must not grow.
- **G5** `python3 -m unittest discover -s tests -p 'test_*.py' -v`. Stdlib only, and the tests are pytest-compatible.
- **G6** `bats tests/`. Local bats is 1.13.0 (measured); `run --separate-stderr` needs 1.5 or later. CI installs bats from apt.
- **G7** Smoke test.
  - **Until U2 lands**, run it only in a sandbox HOME:
    `T=$(mktemp -d) && mkdir -p "$T/.claude/bin" "$T/.claude/hooks" && cp bin/session-search.py bin/claude-search "$T/.claude/bin/" && cp -R hooks/. "$T/.claude/hooks/" && python3 assets/demo/build_demo_db.py "$T/.claude/session-index.db" && HOME="$T" bash tests/smoke-test.sh`
  - Warning: plain `bash tests/smoke-test.sh` inserts and then deletes a row in the real `~/.claude/session-index.db` (smoke-test.sh:8, :51-54, :71).
  - After U2: `bash tests/smoke-test.sh`, which isolates itself.
  - (Round 2) After step 0 also run `bash tests/workflow-index-test.sh` (from `origin/main`; hermetic, scratch HOME). The smoke test leaves more behind than the warning above says: smoke-test.sh:59 writes a row with session_id `x` that is never deleted, :71 leaves an orphan FTS row because `sessions_fts` has no triggers, and :46 can spawn a real backfill on a stale index. U2's self-isolation cures all three.
- **G8** CI `ci.yml` job `smoke-test` must be green on the PR. After U2 the job also runs G5 and G6.
  - (Round 2) CI runs on ubuntu-latest, so script tests stub `launchctl` and exercise the GNU `date` and `stat` branches. The BSD branches run only locally on macOS, so an implementer on either OS must run G6 before pushing, and B16.4's tests must pass on both.
- **G9** Optional locally: `./assets/demo/build.sh` (vhs and fzf are installed, measured with `command -v`). After merge, demo.yml re-renders `assets/fzf-demo.gif` and pushes a bot commit.

**Landing flow**
0. (Round 2) Run `git pull --ff-only` on `main` first. Every line number here is from b765dda, and `origin/main` is 4 commits ahead. Rows stay valid after applying this map (measured: `git show origin/main:<file>` plus `grep -n`):

   | File | Shift from b765dda to origin/main |
   |---|---|
   | bin/session-search.py | +1 from :35; +6 from :1591 (format_fzf :1615 is :1621); +36 from :1631 (format_preview :1687 is :1723); +40 from :1734 (main :1759 is :1799, `--resume-result` :1850 is :1890); +44 after :1874 |
   | bin/claude-search | +5 after :141 |
   | scripts/session-index-backfill.sh | +41 after :522 (Phase 7 :648 is :689, summary :667 is :708, meta :674 is :715). New Phase 4b has two more `stat -f` sites, at :539 and :550 |
   | hooks/lib/session-index-helpers.sh | init_db :116 is :181; +54 from :240 (upsert is :294); +128 from :533 (rebuild_fts :548 is :676). The lock functions at :65-110 did not move |
   | hooks/session-index-sweep.sh, tests/workflow-index-test.sh | sweep gains 50 lines; the test is new and hermetic |

   These upstream commits also change what the plan must do:
   - 5811933 and 87fd9e7 already fixed the unlocked migration heredoc that the "migrates before locking" finding describes, so B16.1 drops that part.
   - 5ec4365 added `wf_*` rows, which changes B3.4, B3.5, B6.5 and B6.6.
   - `tests/workflow-index-test.sh` joins G7. ci.yml did not change upstream, so U2 adds it to CI.
1. Create a branch from `main` (e.g. `git switch -c cli-contract`).
   - No repo rule requires PRs.
   - A PR is recommended because ci.yml runs on `pull_request`.
   - demo.yml runs on every push to `main` that touches `bin/**` or `assets/demo/**`, and commits a regenerated GIF back to `main`. Landing as one merge avoids one GIF regeneration and bot commit per unit.
2. Make one commit per implementer unit, in the step order in §6. Use a conventional subject (e.g. `fix(cli): ...`, `feat(cli): ...`, `test: ...`) and stage explicit paths.
3. Run G1-G7 per commit. Push the branch, open the PR, wait for CI green, then merge.
4. After merge, wait for demo.yml's `chore: regenerate fzf demo GIF [skip ci]` commit, then `git pull --ff-only`.
5. Wave C items land only after the operator records each decision (§4). C1's decision is needed before U3's JSON arms.
6. (Round 2) The installed launchd job is a copy. After any merge that changes `config/*.plist` the running job changes only on the next `./install.sh`, and on a machine managed by claude-infrastructure migration 0025 owns that copy (C18).

---

## 2. Wave A: shared code

### Shared causes (3 or more findings each)

| Cause | Evidence | Findings fixed centrally |
|---|---|---|
| S1: two option tables | Wrapper case loop at bin/claude-search:29-56 versus argparse at bin/session-search.py:1760-1776 | `--json` broken; `--analytics` unreachable; usage on stdout with exit 0; hand-rolled argv; help drift; no validation; modes as flags (7) |
| S2: no typed error or exit mapping | `main()` has only `try/finally` (:1784-1922) | swallowed resume errors (engine side); tracebacks; wrong exit codes and streams; failures shown as empty; unvalidated options; error copy (6) |
| S3: no mode resolution or theme | `isatty` at :1145 and :1884; palettes re-declared at :900, :981, :1408, :1788; 44 raw `\033[` literals (measured: `grep -n '\\033\[' bin/session-search.py \| wc -l`); hard-coded escapes in format_fzf :1624 and format_preview :1699-1729 | stdout carries chrome; no sanitizing; colour handling; piped table (4) |
| S4: no JSON writer | only `format_json` (:1627-1628) | `--json`; Ctrl-O preview JSON; machine-output envelope (3) |
| S5: no atomic state write | `CACHE_PATH.write_text` at :1737 | cache torn by fzf reloads; corrupt cache read as empty (2) |
| Test gap | smoke-test.sh:16 discards both streams | the tests finding, plus R390/R395 for every new contract |
| (Round 2) S6: no argv parser in the shell entry points | install.sh and uninstall.sh read no argv (`grep -nE '\$@\|\$#\|getopts'`: no top-level hit); backfill.sh:19-26 has no help, `--` or `--x=v` | `--help` runs the install; `--help` runs the uninstall; backfill help and exit codes; `--since` parsing; no preview on either script; missing global options on three scripts (9) |
| (Round 2) S7: failures masked, then exit 0 | `2>/dev/null \|\| true` and `\|\| echo 0` at install.sh:217-223, backfill.sh:115, :128, :145, :252, uninstall.sh:88, :96; `main()` in tag.py never exits nonzero | false "Ready"; false "Uninstall complete."; read failures shown as empty; tagger exits 0 after failures; chunk reports success on a missing file (5) |
| (Round 2) S8: settings.json edited twice, two ways | install.sh:172-196 and uninstall.sh:44-74 | both RMW findings (2), and neither lock works unless both take it |
| (Round 2) S9: human output on stdout in every script | `echo` and `printf` with no `>&2` in install.sh, uninstall.sh, progress-ui.sh, chunk.py:240 and :280, tag.py | the five stream findings (5) |
| (Round 2) S10: no shared mode, colour or glyph helper for scripts | `[ -t 1 ]` at progress-ui.sh:15; separate theme at tag.py:40-51; fixed glyphs at uninstall.sh:19-21 | colour and glyph findings on install, uninstall, backfill and tag; error copy on install (5) |
| (Round 2) S11: no version source | `git tag` empty; no VERSION, pyproject or `__version__` (`grep`) | `--version` on install, uninstall, backfill, chunk and tag, plus U1a's literal (6) |
| (Round 2) S12: no top-level handler in the Python scripts | chunk.py:288-289 and tag.py:1074-1075 call `main()` bare | chunk batch abort; tag tracebacks; tag Ctrl+C (3) |

### The shared module

**Location:** `bin/session-search.py`, a new section inserted after `CACHE_PATH` (current line 39). It is delimited by two marker comments:
- `# ─── CLI contract layer: begin ───`
- `# ─── CLI contract layer: end ───`

**Why a section in the existing file rather than a new file:** the product deploys as a single file.
- install.sh:147 symlinks exactly that file.
- ci.yml:21, demo.yml:57 and build.sh:16 copy exactly that file.
- A new module would need edits to 5 deployment files (install.sh, uninstall.sh, ci.yml, demo.yml, build.sh), and copy-based installs that miss it would break.

The markers make "enforce the rules in shared code" testable. U5's source-lint test asserts that `isatty(`, `NO_COLOR`, `FORCE_COLOR`, `CI` and raw `\033[`/`\x1b[` appear only between them (R116, R199, R412).

**API (U1a, estimated about 280 code lines and 130 test lines):**
```python
VERSION = "0.1.0"            # no version source exists (grep finds none; no git tags); operator may pick another (Round 2: C15)
ENV = "SESSION_SEARCH_"
LIMIT_CAP = 200
REASONS = {...}              # (Round 2) the one registry of snake_case reasons, from Reference J and K (R255, R264):
                             # invalid_arguments, unknown_option, missing_query, not_found, api_error, spawn_failed,
                             # invalid_config, partial_failure, internal_error, canceled, deprecated, limit_clamped

@dataclass(frozen=True)
class Mode:                  # resolved once per process
    stdin_tty: bool; stdout_tty: bool; stderr_tty: bool
    color_out: bool; color_err: bool
    ci: bool; agent: bool    # agent = CLAUDECODE set (Claude Code harness env)
    interactive: bool        # stdin_tty and stderr_tty and not ci and not agent   (R113)
    json: bool
    tips: bool               # interactive and stdout_tty and not json and not $SESSION_SEARCH_GUIDANCE_DISABLED (Round 2: R238)
    debug: bool              # --debug or $SESSION_SEARCH_DEBUG
    accessible: bool         # (Round 2) $SESSION_SEARCH_ACCESSIBLE=1: one plain line per phase, glyphs become words (R080, R121)
    picker: bool             # (Round 2) internal $__SESSION_SEARCH_PICKER=1, set only by the wrapper's fzf binds (R079)

def resolve_mode(no_color=False, json_mode=False, debug=False, environ=os.environ,
                 streams=(sys.stdin, sys.stdout, sys.stderr)) -> Mode
    # colour precedence, decided separately for stdout and stderr (Round 2: `--color` removed; R206 lists no such option):
    #   --no-color > NO_COLOR (non-empty) > FORCE_COLOR ("0" means off) > picker
    #   > stream.isatty() and TERM != "dumb"                                  (R199, R206)
    # FORCE_COLOR outside the picker tints only the Warning:/Error: prefixes in plain output (R208).
    # The picker feed and its preview pane are the one styled non-TTY output: fzf --ansi renders them.
MODE: Mode                   # module global; resolve_mode() default until main() re-resolves after parse

class Theme:                 # semantic roles; every role is "" when disabled; basic 16 colours only (1, 2, 31-36, 90)
    heading, accent, success, warn, muted, ident, match_on, match_off, reset
    H, V, TL, TR, BL, BR, ML, MR, THIN_V, BULLET, ARROW               # glyphs, declared once
def theme(stream="out") -> Theme

def sanitize_display(s, keep_hl=False) -> str
    # strip CSI/OSC/other ESC sequences, C0 controls (keep \x02/\x03 when keep_hl), DEL, C1 \x80-\x9f,
    # and unicodedata.category == "Cf" (bidi overrides, zero-width); \t \n \r -> " "      (R359)
def plural(n, one, many=None) -> str                                  # "1 result", "2 results" (R217)
def warn(reason, message) -> None                                     # (Round 2) "! <message>" rich, "Warning: <message>" plain, stderr;
                                                                      # with --json it goes in the document's warnings array instead;
                                                                      # each reason prints once per run (R205, R307, R308, R309)

class CliError(Exception):
    def __init__(self, message, *, code=1, reason="internal_error", recovery=(), status="error", data=None, retryable=None): ...
    # recovery: up to 2 (instruction, command) pairs, likeliest first; reason must be in REASONS (Round 2: R255)
def usage_error(message) -> CliError                                  # code=2, reason="invalid_arguments", status="action_required",
                                                                      # recovery=(("See help:", "claude-search --help"),) (Round 2: R254)
def render_error(err: CliError, mode: Mode) -> None
    # human: one headline line; blank line; "<Instruction>:" then the command indented 4 spaces (R275, R280)
    # json:  exactly one line on stderr, always last:
    #        {"status":..,"reason":..,"message":..,"next":[{"command":..,"argv":[..]}],"data"?:..,"retryable"?:..}
    #        (R253; Round 2: `next` entries are objects per R249 and R257; optional fields appear only when they apply, R250, R258, R259, R261)
def run_cli(main_fn) -> "NoReturn"
    # CliError          -> render_error, exit err.code
    # KeyboardInterrupt -> clear spinner line; "Canceled." on stderr; exit 130   (R335, R337)
    #                      (Round 2) with --json: one error document instead, reason "canceled", data.remote "none" (R262)
    # sqlite3.Error     -> "Search index error: <Type> in ~/.claude/session-index.db." + recovery
    #                      ("Rebuild it:" ~/.claude/bin/session-index-backfill.sh), exit 1
    # Exception         -> "Unexpected error in claude-search. This is a bug in claude-session-search."
    #                      + Error row (type, file:line) + Version row (VERSION, python, platform)
    #                      + https://github.com/renchris/claude-session-search/issues;
    #                      no argv/path/message text; traceback only when MODE.debug; exit 1  (R283, R295)
def emit_json(doc, stream=None) -> None    # indent=2 when the stream is a TTY, else compact; default=str (R251)
def atomic_write_text(path, text) -> None  # mkstemp(dir=path.parent, prefix="."+path.name+"."), utf-8,
                                           # flush+fsync, os.replace; unlink temp and re-raise on failure (R351, R348)
@contextmanager
def spinner(label, mode)                   # stderr only, only when mode.stderr_tty and mode.color_err;
                                           # always clears with "\r\033[K", including on KeyboardInterrupt (R177, R328)
def positive_int(s) -> int                 # ArgumentTypeError("must be a whole number of 1 or more")
def nonneg_int(s) -> int
def parse_time(s) -> str                   # (Round 2: replaces iso_date, because <TIME> means ISO 8601 or relative in R436 and R443)
                                           # accepts a bare integer (days), 7d, 12h, 30m, or ISO 8601; an ISO value with no offset reads as UTC;
                                           # returns an ISO 8601 UTC string for the existing fromisoformat at :321 and :324;
                                           # ArgumentTypeError("Times use ISO 8601 (2026-03-01) or a relative value (7d, 12h).")
```

**Single option table (U1b, estimated about 120 code lines and 70 test lines), placed in the same section.** It replaces :1760-1776, and `if __name__ == "__main__": main()` at :1925-1926 becomes `run_cli(main)`.
```python
def build_parser() -> argparse.ArgumentParser:
    # ArgumentParser(prog="claude-search", allow_abbrev=False, description="Search your Claude Code sessions.")  (R065)
    # .error() override: "claude-search: <msg>" + at most one difflib close match among declared long
    #   options + "See 'claude-search --help'." on stderr, exit 2                       (R055, R304, R337)
    # query                      nargs="*", metavar="<QUERY>"
    # --json                     store_true                                                    (R243, R438)
    # --format {table,fzf,json}  hidden (Round 2). `json` is a deprecated alias: it prints one warning, reason "deprecated",
    #                            "--format json is deprecated. Use --json." on stderr (R050, R308, R385). `table` is the default.
    #                            `fzf` is the picker's internal feed; see "Recorded conflicts" in §4 (R438)
    # -n, --limit <NUMBER>       positive_int, default 10; help "default: 10, max: 200, ordered by relevance" (R344; Round 2: -n, R444)
    # -p, --project <NAME>       (Round 2: -p, Reference G)
    # -s, --since <TIME>         dest=after,  type=parse_time. Help states the default window (all history) and the timezone
    #                            (an ISO value with no offset is UTC) (R443; Round 2: short form and wording)
    # -u, --until <TIME>         dest=before, type=parse_time
    # --after, --before          (Round 2) hidden deprecated aliases of the two above. Each prints one warning naming its replacement
    #                            (R050, R385). Old inputs keep working, so `--after 2026-03-01` still parses
    # --min-msgs <NUMBER>        nonneg_int, default 0
    # mutually exclusive mode group: --resume-result <NUMBER> (positive_int), --preview <SESSION>,
    #                    --context-inject <DIR>, --stats, --analytics                        (R070)
    # --fails
    # --explain / --no-explain, --deep-search / --no-deep-search   (R068; Round 2: a small custom action, because
    #                            BooleanOptionalAction rejects the `--explain=true` and `--explain=false` forms R068 requires)
    # --no-llm, --no-log, -d/--debug, --non-interactive (Round 2: accepted, R062; the engine has no prompts, so it only sets Mode)
    # --no-color                 store_true (Round 2: replaces --color {auto,always,never}, R062, R206)
    # -v, --version  custom action: prints VERSION, or {"version": ...} when --json was given; exit 0  (R086)
    # help=argparse.SUPPRESS for internal flags: --resume-result, --context-inject, --format, --no-log, --after, --before
    # (Round 2) R062's --cwd, --local-config, --scope and --token are N/A: the engine reads no cwd config, has no project config,
    #           no context and no token option. --global-config is C16.
def validate_args(parser, args) -> None    # runs before the DB is opened (R302, R064)
    # a mode flag together with a query -> usage error; --fails without --analytics; --explain with --json or
    # --format other than table; --json with --format; --json with --context-inject;
    # --limit > 200 -> clamp, then warn("limit_clamped", "--limit clamped to 200.")  (Round 2: R344, R309, Reference K)
```

**Companion shared test helper (U2): `tests/helpers.bash`.** The guide's shared-code table asks for "a test helper asserting one stdout document and a clean stderr".
- `sandbox_setup` does the following:
  - Saves `REAL_HOME`, then `export HOME=$(mktemp -d "${TMPDIR:-/tmp}/css-test.XXXXXX")`.
  - Copies the repo's `bin/session-search.py` and `bin/claude-search` to `$HOME/.claude/bin/`, and `hooks/.` to `$HOME/.claude/hooks/`.
  - Runs `python3 "$REPO/assets/demo/build_demo_db.py" "$HOME/.claude/session-index.db"`. That DB seeds `last_backfill`, so no spawn happens.
  - Builds `$HOME/tools`, a directory of symlinks to python3, jq, sqlite3 and awk. PATH is set to `$HOME/stubs:$HOME/.claude/bin:$HOME/tools:/usr/bin:/bin`, so tests control which commands exist (fzf on macOS sits in /opt/homebrew/bin next to jq).
  - Writes stubs `claude`, `fzf`, `pbcopy` and `open`. Each appends its NUL-separated argv to `$HOME/calls/<name>`. The `fzf` stub honours `FZF_OUT` and `FZF_RC`, and with `FZF_RUN_RELOAD=<q>` it runs its own `change:reload:` command through `bash -c` with `{q}` replaced.
- `sandbox_teardown`: `case "$HOME" in */css-test.*) rm -rf "${HOME:?}";; esac; export HOME="$REAL_HOME"`.
- `use_stub_engine`: swaps in an engine script that logs argv and honours `STUB_OUT`, `STUB_ERR` and `STUB_RC`.
- `calls <name>`: prints the recorded argv for a stub.
- `assert_one_json_doc`: stdout is exactly one line and `jq -e .` parses it.
- `assert_no_ansi`: no ESC byte in the output.
- `run_in_pty`: `python3 -I -c 'import os,pty,sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@"`. Portable on macOS and Linux; the two streams are merged.

### (Round 2) Shared layer for the maintenance scripts

**Why not reuse the engine's contract section:** the engine must stay one copyable file (ci.yml:21, demo.yml:57, build.sh:16), and the scripts need shell helpers as well as Python ones. So the scripts get their own two small modules under `scripts/lib/`, and a parity test keeps the Python grammar and sanitizer equal to the engine's. This is a recorded exception to "one module" (R116, R408, R412, R422): each language and deployment form has one module, and the lints below enforce that.

**U11a (estimated about 200 code lines and 150 test lines): `scripts/lib/cli-common.sh`, `scripts/lib/settings-edit.sh`, `tests/helpers_scripts.bash`, `tests/scripts_lib.bats`.**
```bash
# scripts/lib/cli-common.sh. Bash 3.2. Sourcing it has no side effects: no trap, no exec, no write.
css_version REPO_DIR               # first line of REPO_DIR/VERSION, else "unknown"
css_parse_args PROG SPEC... -- "$@"
    # SPEC is "long|short|kind|VAR", kind is bool or value. Handles --name value, --name=value, -x value and "--".
    # Unknown option: css_usage_fail with at most one close match. Extra positional: css_usage_fail.
    # __SESSION_SEARCH_PARSE_ONLY=1 exits 0 right after a clean parse, before any effect (R100).   (R063-R066, R304)
css_usage_fail PROG MESSAGE        # "PROG: MESSAGE", then "See 'PROG --help'.", on stderr; exit 2  (R055, R337)
css_rich FD                        # [ -t FD ] and TERM is not dumb. Gates cursor control and redraw (R115, R207)
css_color_enabled FD               # __SESSION_SEARCH_NO_COLOR > non-empty NO_COLOR > FORCE_COLOR (0 is off) > css_rich FD (R206)
css_interactive                    # [ -t 0 ], [ -t 2 ], no CI, no CLAUDECODE, no --non-interactive  (R113, R117)
css_guidance_on                    # css_interactive and SESSION_SEARCH_GUIDANCE_DISABLED unset      (R238, R240)
css_fail HEADLINE [INSTR CMD...]   # stderr, R276/R280 layout: rich "✗ HEADLINE", plain "Error: HEADLINE"; blank line;
                                   # "INSTR:"; each CMD indented 4 spaces; exit 1. A headline-only call must not abort at `shift 2` under set -e
css_warn TEXT                      # stderr: rich "! TEXT", plain "Warning: TEXT"                    (R205, R307)
css_json_error REASON MESSAGE      # one line on stderr, built with jq when present, printf fallback  (R253)

# scripts/lib/settings-edit.sh. Used by install.sh and uninstall.sh, so the lock binds both (cause S8).
css_settings_validate FILE         # jq empty; prints "<path>: <jq error with line and column>"; never writes (R138, R303)
css_settings_patch FILE FILTER     # one read-modify-write, in this order:
    # 1. target=realpath via `python3 -c os.path.realpath` (BSD `readlink -f` can't be assumed)
    # 2. mkdir "$target.lock.d", bounded wait; timeout returns 1 and writes nothing (`flock` is absent on macOS, measured)
    # 3. record `cksum`; bak=$(mktemp "$target.bak.XXXXXX"); cp -p to it. Never overwrite a good backup with a broken file
    # 4. tmp=$(mktemp "$(dirname "$target")/.settings.json.XXXXXX"); cp -p first, because mktemp creates 0600 (measured)
    # 5. one jq pass into tmp with an explicit `if !`, never `&& mv` (a failed left side of && does not trip errexit, measured)
    # 6. jq empty tmp; compare cksum again, because Claude Code won't take this lock; changed means retry a bounded number of times, then fail
    # 7. mv tmp target. Remove tmp and the lock on every return path
    # It sets no trap. progress-ui.sh:346 owns EXIT, and replacing that trap is the defect in B16.3.
```
- `tests/helpers_scripts.bash`: `script_sandbox_setup` builds on U2's `sandbox_setup`, so U11a lands after U2. Requirements come from the scope-wide test finding, read from the code:
  - A logging `launchctl` stub first on PATH. launchctl acts on the user's domain, not on `$HOME`, so a temp HOME on a Mac could otherwise reload real jobs.
  - `$HOME/Library/LaunchAgents` created, because install.sh:257 has no mkdir. One case omits it on purpose (B14.4).
  - A seeded `settings.json` with one unrelated hook, and a seeded `.zshrc`. Without them install.sh:204 and :234 skip their steps.
  - `ANTHROPIC_API_KEY` unset (tag.py:753, session-search.py:673).
  - A `uname` stub that can answer `Linux` or `Darwin`.
  - `assert_tree_unchanged`: `find "$HOME" -type f -exec cksum {} +` before and after.
- Tests in `tests/scripts_lib.bats`:
  - `"parser handles --x=v, --x v, -x v and --"`.
  - `"unknown option exits 2 with one close match and no effect"`.
  - `"colour precedence follows R206"`: a table of `--no-color`, `NO_COLOR`, `FORCE_COLOR=0`, `FORCE_COLOR=1`, `TERM=dumb`.
  - `"css_interactive is false under CI and CLAUDECODE"` (`run_in_pty`).
  - `"settings patch keeps a symlink, the file mode and unrelated keys"`.
  - `"settings patch on a failing filter leaves no temp file and exits 1"`.
  - `"settings patch aborts when the file changes while patching"`.
  - `"TTY checks live only in cli-common.sh"`: `grep -nE '\[ -t [012] \]'` over install.sh, uninstall.sh, backfill.sh and progress-ui.sh finds nothing (R408). bin/claude-search is exempt because it deploys as one copied file.
  - `"no raw colour escapes outside progress-ui.sh"`: `grep -n '\\033\['` over install.sh, uninstall.sh and backfill.sh finds nothing (R199, R412).

**U11b (estimated about 170 code lines and 100 test lines): `scripts/lib/cli_common.py`, `VERSION`, `tests/test_scripts_common.py`.** `VERSION` holds `0.1.0`, the same as U1a's literal (C15). Copy-based deployments have no VERSION file, so the engine keeps its constant and a test keeps the two equal. U11b lands after U1a, because its parity test loads the engine through `tests/engine_loader.py`.
```python
# Loaded by tag.py and chunk.py with sys.path.insert(0, str(Path(__file__).resolve().parent / "lib")), so the ~/.claude/bin symlink works.
VERSION                                    # read once from Path(__file__).resolve().parents[2] / "VERSION"
def parse_time(value, min_days=None) -> float   # epoch. Bare integer means days; 7d, 12h, 30m; ISO 8601; no offset means UTC. Same grammar as the engine (R443)
                                           # Overflow, garbage or below min_days raise ArgumentTypeError
def sanitize_display(s) -> str             # same contract as the engine's (R359)
def plural(n, one, many=None) -> str       # R217
def fmt_duration(seconds) -> str           # 42ms, 3.4s, 2m 10s (R214)
def resolve_style(stream, no_color=False) -> Style   # R206 precedence per stream; colour and rich are separate fields (R115, R207, R208)
def glyph(name, style) -> str              # one set: ✓ ! ✗ when rich; words when plain (R182, R186, R205)
class CliError(Exception); def run_cli(main_fn, prog) -> "NoReturn"
    # CliError -> R276 layout, its code. BrokenPipeError -> detach stdout, keep the real outcome (R341).
    # KeyboardInterrupt -> 130. sqlite3.Error -> one line naming the DB, exit 1.
    # Exception -> "Unexpected error in <prog>. This is a bug in claude-session-search." with Error row (type, file:line),
    # Version row and https://github.com/renchris/claude-session-search/issues; never str(e), argv or paths (R283, R295, R305)
def emit_json(doc) -> None                 # indent=2 on a TTY, compact otherwise (R251)
# `python3 cli_common.py parse-time VALUE [--min-days N]` prints the epoch, or exits 2. backfill.sh uses this, so shell and Python share one grammar.
```
- Tests:
  - `test_parse_time_table`: `7` `7d` `12h` `2026-03-01` `2026-03-01T00:00:00Z` pass; `abc` `1.5` `""` `99999999999` raise; `0` raises with `min_days=1`.
  - `test_naive_iso_is_utc`.
  - `test_parity_with_engine`: load the engine via `tests/engine_loader.py` and compare `parse_time` and `sanitize_display` over the same inputs.
  - `test_version_file_matches_engine`.
  - `test_internal_error_has_no_input_text`: an exception whose message holds a marker string; the marker is absent from stderr.
  - `test_keyboard_interrupt_exits_130`.
  - `test_style_precedence`.

---

## 3. Wave B: compatible fixes, grouped by file

These are compatible per the verifier's caller census. Several of them change exit codes or streams, but the census found no consumer of the old behaviour. Each is listed again in U7's README "Behavior changes" note.

Rule IDs refer to /tmp/cli-bp/checklist.md.

### U3: `bin/session-search.py` main dispatch, errors, exit codes, JSON (after U1b)
Also owns `tests/engine_cli.bats` and `tests/smoke-test.sh:46`. Tests call the real engine in the sandbox with `python3 "$HOME/.claude/bin/session-search.py"`.

- **B3.1 Missing index** (R004, R275, R280)
  - Site: :1779-1780.
  - Change: `raise CliError("Can't search: no index at ~/.claude/session-index.db.", recovery=(("Build it:", "~/.claude/bin/session-index-backfill.sh"),))`, exit 1. That path is the symlink from install.sh:150.
  - Test `@test "missing index names the file and the build command"`: remove the sandbox DB. Expect status 1, empty stdout, stderr containing `session-index.db`, and a line matching `^    .*session-index-backfill\.sh$`.
  - (Round 2) Order: this recovery command, and `run_cli`'s `Rebuild it:` line, die at backfill:13 when run through the symlink until B12.1 lands. U12 therefore lands before U3 (R053). The same holds for B4.1's `~/.claude/bin/session-index-chunk.py --backfill`: that entry has a shebang and an exec bit (install.sh:158) and works through the symlink (read from the code), but its traceback on a missing projects dir is B17.2.
- **B3.2 Missing query** (R337, R016)
  - Site: :1879-1881 (`parser.print_help(); sys.exit(1)`).
  - Change: `parser.error("missing search query")`, which exits 2 and writes only to stderr.
  - Test `@test "missing query is a usage error on stderr"`: run `--limit 3`. Expect status 2, empty stdout, and stderr containing `missing search query` and `claude-search --help`.
  - Test `@test "empty fzf feed prints no help rows"`: run `--format=fzf` with no query. Expect empty stdout and status 2.
- **B3.3 Preview of an unknown session** (R016, R194, R275)
  - Site: :1842-1845 and :1688-1690.
  - Change: in `main`, when `pipeline.preview(id)` returns `None`, raise `CliError(f"Couldn't find session {sanitize_display(id)}.", recovery=(("Find its ID:", 'claude-search "<QUERY>"'),))` with exit 1. Delete the `if not session` branch in `format_preview`.
  - Test `@test "unknown session preview fails on stderr"`: expect status 1, empty stdout, and stderr `Couldn't find session nope.`
  - Test `@test "known session preview exits 0"`: the ID comes from `sqlite3 "$HOME/.claude/session-index.db" 'select session_id from sessions limit 1'`.
- **B3.4 Resume outcomes** (R337, R275, R004, R001)
  - Site: :1850-1877.
  - Changes:
    - No query and no cache: `CliError` code 2, `No cached results to resume.`, recovery `Search first:` / `claude-search "<QUERY>"` and `Then resume by number:` / `claude-search --resume 1`.
    - Query given but nothing matched: code 1, `No sessions match "<q>".`
    - N out of range: code 2, `Result #N is out of range: the last search returned M results.`, recovery `Pick one in range:` / `claude-search --resume 1`.
    - Legacy session: keep code 1.
    - (Round 2) `wf_*` row: keep code 1 and the file path, from origin/main :1915-1918 (invariant 15).
    - On success: write `Resolved #N: <summary> (<project>, <full id>)` (sanitized) to stderr, then only the ID to stdout (invariant 2).
  - Tests:
    - `@test "resume out of range exits 2 with a runnable next command"` (`--resume-result 999 migration`). (Round 2) Also asserts empty stdout: the identifier prints only on exit 0 (R176). The same assertion goes on the two tests below it and on every other failing `--resume-result` case.
    - `@test "resume with no cache exits 2"`.
    - `@test "resume prints the target on stderr and only the ID on stdout"`: stdout is one line matching `^[A-Za-z0-9_-]+$`, and stderr contains `#1`.
    - (Round 2) `@test "resume refuses a workflow result"`: seed a `wf_` row. Status 1, empty stdout, stderr names the file.
- **B3.5 `--json` arms** (R243, R248, R251, R253, R438, R009). Shape is gated on C1 (§4); the rest of U3 may land without it.
  - Search (:1912-1919): `if args.json: emit_json({"sessions": [public_result(r, rank=i) ...], "pagination": {"next": None}})`, otherwise unchanged. `--format json` stays `format_json` (invariant 4). (Round 2) `pagination` is required by R248. `next` is always null because the engine has no paging (R345 is N/A).
  - `public_result` has fixed fields: `rank, session_id, project_name, project_path, git_branch, created_at, modified_at, message_count, summary, tags (list), score`. It drops `*_hl`, `*_snip`, `bm25`, `recency` and `depth`, and strips `\x02`/`\x03` from strings.
  - (Round 2) Add `workflow_path` to those fields, null on ordinary sessions, from origin/main :1635-1638 (R250). Keys stay snake_case because they mirror the table's columns (R246 says mirror the data model; camelCase is the guide's own model). `--fields` (R252) and a declared result schema (R247, R106) wait for C20.
  - Stats (:1785): `{"stats": s}`.
  - Preview: `{"session": {...}}`.
  - Legacy `--format=json --preview`: one flat `json.dumps(row)` object. This repairs today's Ctrl-O during the deprecation window (finding "Ctrl-O cannot work").
  - Resume-result: `{"session": {"session_id": sid, "rank": n}}`.
  - Errors: one line on stderr via `run_cli`.
  - Tests:
    - `@test "--json search prints one compact document"`: `assert_one_json_doc`; `jq -e '.sessions|type=="array"'`; no `\x02` byte; `assert_no_ansi`; `jq -e '.sessions[0]|has("bm25")|not'`.
    - `@test "--format json keeps the legacy array"`: `jq -e 'type=="array"'` and more than 1 line.
    - `@test "--json failure writes one error line to stderr"` (`--json --preview nope`): status 1, empty stdout, stderr is one line, and `jq -e '.status=="error" and (.reason|length>0)'`.
    - `@test "--json --preview and --json --stats print one document"`.
    - `@test "--format=json --preview has project_path"`.
- **B3.6 Validation before side effects** (R064, R065, R070, R302, R344). The checks come from U1b; U3 proves they run before the DB is touched.
  - Test `@test "invalid input fails before a search is logged"`: count `search_log` rows. Then each of `--after 3/1 q`, `--limit 0 q`, `--deep q`, `--stats q`, `--fails q` and `--explain --json q` must exit 2. Afterwards the row count is unchanged and `~/.claude/.last-search-results.json` does not exist.
  - Test `@test "--limit 500 is clamped with a warning"`: status 0, stderr contains `clamped to 200`.
  - (Round 2) Test `@test "--json --limit 500 reports limit_clamped in the document"`: stderr empty, `jq -e '.warnings[0].reason=="limit_clamped"'` (R244, R309, R396).
  - (Round 2) Test `@test "--after still works and warns once"`: `--after 2026-03-01 --before 2026-04-01 q` exits 0 with one warning per alias naming `--since` and `--until` (R308, R385, R402).
  - (Round 2) Test `@test "--since accepts ISO and relative values"`: `--since 7d q`, `--since 2026-03-01 q` and `-s 7 q` exit 0; `--since abc q` exits 2 (R443).
  - (Round 2) Test `@test "--format json warns once on stderr and keeps stdout"`: stderr names `--json`, stdout still parses as a bare array (R050, invariant 4).
- **B3.7 Spinner** (R016, R177, R328)
  - Site: :1884-1887 and :1902-1904.
  - Change: wrap the search call in `with spinner("Searching…", MODE):`. The helper test lives in U1a (`test_spinner_writes_only_to_stderr`).
- **B3.8 Engine docstring** (R023, R053)
  - Site: :3-21.
  - Change: document `--json`, `--since/--until` and `--no-llm`, and mark `--format=json` as deprecated.
- **B3.9 Smoke caller migration** (C1 caller)
  - Site: tests/smoke-test.sh:46.
  - Change: `check "Search returns JSON" bash -c 'python3 "$1" --json session --limit 1 | jq -e ".sessions|length==1"' _ "$SEARCH_PY"`.

### U4: `bin/session-search.py` pipeline correctness, plus `scripts/session-index-backfill.sh` (after U3)
Also owns `tests/test_engine_pipeline.py` and `tests/backfill.bats`. (Round 2) Also owns `hooks/lib/session-index-helpers.sh:85-100`, for the trylock fix in B4.6.

- **B4.1 Failures are not empty results** (R017, R194, R275, R138)
  - Sites :567-570 (`_execute_query`) and :637-640 (`_execute_chunk_query`): change to `except sqlite3.OperationalError as e: if _is_fts_query_error(e): return []; raise`. The check matches messages starting `fts5:` or containing `syntax error` or `no such column`, which is the intended fall-through to the next strategy.
  - :762-769 `_count_fts_matches`: the same narrow catch, replacing `except Exception`.
  - :144-151 `load_synonyms`: only `no such table: synonyms` returns `{}`.
  - :604-607 chunks probe: keep returning `[]`. When `--deep-search` is set, write `Deep search unavailable: the chunk index isn't built.` and `Build it:` / `    ~/.claude/bin/session-index-chunk.py --backfill` (install.sh:151) to stderr.
  - Everything else propagates to `run_cli`, which exits 1 naming the DB.
  - Tests:
    - `test_broken_index_raises_not_empty`: a sandbox DB copy with the `sessions_fts` virtual table deleted makes `search()` raise.
    - bats `@test "broken index fails with exit 1 naming the DB"`: status 1, stderr contains `session-index.db`, empty stdout.
    - `test_fts_syntax_error_falls_through`: the query `"rum` with an unbalanced quote returns a list and does not raise.
- **B4.2 `--before` on its own** (R013)
  - Site: :320-325.
  - Change: `start = fromisoformat(after) if after else datetime.min.replace(tzinfo=utc)`; `end = fromisoformat(before) if before else now`; set `auto_date_range` when either is given.
  - Test `test_before_alone_is_an_upper_bound`: `search(..., date_before="2000-01-01") == []` on the demo DB.
  - Test bats `@test "--before alone narrows results"`: `jq -e '.sessions|length==0'`.
- **B4.3 Result cache** (R351, R348, R138, R275)
  - Site :1734-1744: write with `atomic_write_text`. On `OSError`, warn on stderr: `Couldn't save results to ~/.claude/.last-search-results.json: <err>. claude-search --resume N may use an older search.` Then `CACHE_PATH.unlink(missing_ok=True)`.
  - Site :1747-1754: a missing file returns `[]`. `JSONDecodeError` or `OSError` raises `CliError("Can't read the result cache at ~/.claude/.last-search-results.json: <err>.", recovery=(("Run the search again:", 'claude-search "<QUERY>"'),))` with exit 1. Read with `encoding="utf-8"`.
  - Test `test_cache_write_is_atomic`: monkeypatch `os.replace` to raise. Old content is intact and no `.last-search-results.json.*` temp file remains.
  - Test `test_corrupt_cache_is_reported`: write `{`. Expect `CliError` with code 1 naming the path.
- **B4.4 Analytics data and rendering split** (R243)
  - Site: :977-1100.
  - Change: add `analytics_data(fails_only) -> dict`. `_show_analytics` renders that dict, with the rendering lines unchanged until U5. In `main` at :1833, `--json` calls `emit_json({"analytics": data})`.
  - Test bats `@test "--json --analytics prints one document"`: `jq -e '.analytics'`.
- **B4.5 Transcript read** (R348, R283)
  - Site :1648: add `if not projects_dir.is_dir(): return []`.
  - Site :1659: open with `encoding="utf-8", errors="replace"`, and narrow the outer except to `OSError`.
  - Test `test_transcript_read_is_utf8_under_c_locale`: run a subprocess with `LC_ALL=C PYTHONUTF8=0 python3 -I` on a transcript containing `café naïve`. The message must be returned.
- **B4.6 `--if-idle` for the auto-spawn** (R019, R364), needed by B5.6
  - Site scripts/session-index-backfill.sh:19-24: add `--if-idle) IF_IDLE=true; shift ;;`. Today unknown flags exit 1 at :24.
  - Site :50-52: `if $IF_IDLE; then session_index_trylock || { session_index_log "Backfill skipped: index busy"; exit 0; }; else session_index_lock; fi`. This uses hooks/lib/session-index-helpers.sh:85.
  - Test `@test "backfill --if-idle exits 0 when the lock is held"`: hold the lock with `flock` if available, otherwise `mkdir "$HOME/.claude/session-index.lock.d"`. Expect status 0 and the log line `Backfill skipped`.
  - (Round 2) Site change: U12 moves the parser, so the new option is one more entry in the `css_parse_args` table, not a `case` arm at :19-24. `--if-idle` joins backfill's help.
  - (Round 2) Plan bug: as written this test fails on CI. `session_index_trylock` (helpers:88-98) treats "flock says held" the same as "flock absent" and falls through to `mkdir`, which succeeds, so `--if-idle` would not skip on any host that has `flock`. ubuntu-latest has it. Fix in U4: pick the primitive with `command -v flock`, and return 1 when `flock -n` fails on a host that has it. The hooks' documented intent is to skip while the lock is held (session-index-end.sh:30, session-index-sweep.sh:25), so they gain correct behaviour with no contract change. U4 therefore also owns `hooks/lib/session-index-helpers.sh` in step B2.
  - (Round 2) `flock`-absent hosts stay on `mkdir` here. C10 owns the later change of primitive.

### U5: `bin/session-search.py` presentation and side effects (after U4)
Also owns `tests/test_engine_output.py`.

- **B5.1 Theme adoption** (R199, R203, R204, R206, R209, R412, R116)
  - Replace the palettes at :900-903, :981-986, :1408-1419 and :1788-1792, and the glyph sets at :988-991, :1421-1425 and :1794-1797, with `t = theme("out")` roles.
  - format_fzf (:1624) and format_preview (:1699-1729) also use `theme("out")`. Piped output and `NO_COLOR` then drop the codes. (Round 2) U6 sets the internal `__SESSION_SEARCH_PICKER=1` on its fzf commands so the picker keeps its colours, in place of the removed `--color=always`.
  - Colour mapping: `38;5;255` becomes bold or the default colour; `38;5;33` becomes `34`.
  - `No results. Try:` and `Suggestions:` (:1443, :1447) are no longer faint.
  - Delete `_use_color` (:1143-1147).
  - Tests:
    - `test_no_ansi_or_tty_checks_outside_contract_layer`: a source lint. The regex `\\033\[|\\x1b\[|isatty\(|NO_COLOR|FORCE_COLOR|environ.get\("CI"` may match only between the markers.
    - `test_preview_respects_no_color`: render to a `StringIO` with NO_COLOR set. No `\x1b` in the output.
    - `test_fzf_rows_coloured_only_for_the_picker` (Round 2: renamed): with `__SESSION_SEARCH_PICKER=1` rows carry colour; without it, and with `NO_COLOR` set, they do not.
- **B5.2 stdout holds only results** (R016, R177, R195, R240, R241)
  - Zero-result branch (:1429-1451): all prose goes to stderr and stdout gets nothing. (Round 2) Once C2's TSV lands, a non-TTY stdout gets the header line only (R195).
  - (Round 2) Empty-state copy follows R195 and R196: `No sessions match "<q>".`; with one filter, `No sessions match this filter. Remove --project to see all sessions.`; with several, `No sessions match these filters.` plus how to widen.
  - Footer (:1607-1611): moves to stderr, shown only when `MODE.tips`, as `Tip: Resume a result by number:` followed by `    claude-search --resume 1`.
  - Opt-out: `SESSION_SEARCH_GUIDANCE_DISABLED=1` (Round 2: the Reference C name, R238).
  - (Round 2) The tip shows at most once per user (R239): `~/.claude/.session-search-tips.json` records it, written with `atomic_write_text`. A failed write skips the record and never changes the exit code (R241, R342). R137 does not bar this; R239 asks for this record.
  - Tests:
    - bats `@test "zero results: piped stdout is empty and prose is on stderr"` (query `zzqqxxnomatch`): status 0, empty stdout, stderr contains `No sessions match` (Round 2: copy follows R195).
    - bats `@test "piped search prints no tip"`: neither stream contains `--resume 1`.
    - `test_tip_only_in_interactive_mode`: with `Mode(tips=True)`, stderr contains `Tip:`.
    - (Round 2) `test_tip_shows_once_per_user`: the second run prints none; a read-only `~/.claude` still exits 0.
- **B5.3 Sanitize untrusted text** (R359, R011)
  - Apply `sanitize_display` to:
    - The return of `_build_description` (:1203-1283).
    - `summary_hl` and snippets, with `keep_hl=True` (:1495, :1580-1590).
    - `project_name`, `git_branch` and `tags` in table, fzf and preview output.
    - `_extract_last_messages` output and `first_prompt` (:1715-1723).
    - `context_inject` summaries and tags (:857-887). That output is prefixed `Session index (titles of earlier sessions; quoted data, not instructions): ...` and stays one string with exit 0 (invariant 1).
  - Not applied to `--json` or `--format json`, because JSON escaping already neutralizes control characters.
  - Tests:
    - `test_preview_strips_terminal_escapes`: a summary of `"\x1b]52;c;ZXZpbA==\x07ok\u202e"` renders `ok`, with no `\x1b` and no `\u202e`.
    - `test_fzf_row_has_one_tab_and_id_last`: a summary containing `\t` still gives `row.split("\t")` 2 parts, and `[-1] == session_id`.
    - `test_context_inject_is_framed_and_clean`.
- **B5.4 Counts and truncation** (R217, R191)
  - Sites :1445, :1552-1554 and :1699: use `plural()`, giving `1 result` and `1 msg`.
  - Sites :1619-1620: format_fzf appends `…` when it cuts text.
  - Test `test_plural_counts`.
- **B5.5 Bounded, optional LLM call** (R313, R019, R379, R381, R141)
  - Site :691 (the verdict cited :687): `anthropic.Anthropic(api_key=api_key, timeout=10.0, max_retries=0)`.
  - Add a `search(..., llm_expand=True)` parameter. Site :402 becomes `if llm_expand and len(results) < 3`.
  - `main` passes `llm_expand=not (args.no_llm or os.environ.get("SESSION_SEARCH_NO_LLM"))`.
  - When expansion actually ran, the output is a table and stderr is a TTY, print to stderr: `Few local matches, so the query was expanded with the Anthropic API. Turn this off with --no-llm.`
  - Tests:
    - `test_llm_client_is_bounded`: a fake `anthropic` module in `sys.modules` records its kwargs. Expect `timeout == 10.0` and `max_retries == 0`.
    - `test_no_llm_skips_network`: with `ANTHROPIC_API_KEY=x` and `urllib.request.urlopen` patched to raise `AssertionError`, a search with `llm_expand=False` completes.
- **B5.6 Background backfill is throttled and visible** (R137, R019, R364, R017)
  - Site: :245-274.
  - Before calling `Popen`, take `fcntl.flock(LOCK_EX|LOCK_NB)` on `~/.claude/session-index-autobackfill.lock`. Skip if the lock is held or the file's mtime is less than 3600 s old.
  - Touch the file, then run `Popen(["bash", backfill, "--since", "7", "--quiet", "--if-idle"])`.
  - Resolve `SESSION_SEARCH_REPO` with `Path(...).resolve()` and require `backfill.is_file()`.
  - For table output with a TTY stderr, print to stderr: `The index is more than 7 days old; refreshing it in the background.`
  - Site :1906: `if not args.no_log: pipeline.log_search(...)`.
  - Tests:
    - `test_autobackfill_spawns_at_most_once_per_hour`: patch `subprocess.Popen`, delete the meta row, run 3 searches. Expect 1 call whose argv contains `--if-idle`.
    - `test_no_log_skips_search_log`.

### U6: `bin/claude-search`, `assets/demo/fzf-demo.tape`, `tests/wrapper.bats`
Develop after U2 against the stub engine. Land after U3, since it needs `--json`, `--no-log` and `--json --preview` from the engine, and `__SESSION_SEARCH_PICKER` support (Round 2: replaces `--color`).

- **B6.1 One parse table** (R063, R064, R066, R055, R304, R070, R009)
  - Site: replace :23-58.
  - Arms of the single `case` loop:
    - `-h|--help` anywhere prints usage, exit 0.
    - `help` as the only argument prints usage, exit 0.
    - `--version` runs `exec python3 "$SEARCH_PY" --version`.
    - `--fzf` sets the mode.
    - `--resume <v>` and `--resume=<v>` set the resume value.
    - `--json`, `--stats` and `--analytics` record the mode and are forwarded.
    - `--preview` and `--context-inject` record the mode and are forwarded with their value.
    - `--after`, `--before`, `--since`, `--until`, `--project`, `--limit`, `--min-msgs` and `--format` are forwarded as a pair, with (Round 2) `-s`, `-u`, `-p` and `-n`. The `--x=v` form is forwarded as one token.
    - (Round 2) `--no-color`, `--non-interactive` and `-d`/`--debug` are forwarded alone. `-v` is the same arm as `--version`.
    - `--` makes the rest query words.
    - Any other `-*` is forwarded as-is, and argparse rejects unknown options with exit 2.
    - Anything else is a query word.
  - `need_value`: `[ $# -ge 2 ] || usage_fail "Missing value for $1."`, which prints `claude-search: Missing value for --resume.` and `See 'claude-search --help'.` to stderr and exits 2.
  - Conflict checks run before any work, exit 2 and name both tokens:
    - `--fzf` with `--resume`, `--json`, `--stats`, `--analytics`, `--preview` or `--context-inject`.
    - `--resume` with `--json`, `--stats`, `--analytics`, `--preview` or `--context-inject`.
  - Tests:
    - `"trailing --resume is a usage error"`: status 2, stderr `Missing value for --resume`, empty stdout, no engine call.
    - `"--resume=3 resumes result 3"`: the stub engine prints a UUID, and `calls claude` is `--resume <uuid>`.
    - `"-- ends option parsing"`: the engine argv ends with `--`, `--help`.
    - `"unknown option exits 2 even without a query"`: real engine, `claude-search --bogus` gives 2 and stderr mentions `--bogus`.
    - `"--fzf with --json is a usage error"`.
    - `"--resume with --stats is a usage error"`.
- **B6.2 Dispatch through the engine** (R023, R053, R243, R003, R339, R360)
  - Delete :87-108 (the stats, preview and JSON special cases, each with `exit 0`) and :150-169.
  - The default path becomes `exec python3 "$SEARCH_PY" ${FWD[@]+"${FWD[@]}"} -- ${QUERY_PARTS[@]+"${QUERY_PARTS[@]}"}`, so the engine's exit code passes through.
  - A bare `claude-search` prints usage with exit 0.
  - Tests:
    - `"--json forwards and prints one JSON document"` (real engine, `jq -e '.sessions'`).
    - `"--analytics runs without a query"`: status 0 and stdout lacks `Usage:`.
    - `"--analytics --fails runs without a query"`.
    - `"engine exit code passes through"`: `STUB_RC=2` gives 2.
- **B6.3 Help** (R012, R081, R083, R087, R089, R436, R023)
  - Add a `usage()` function containing:
    - `Usage: claude-search [options] <QUERY>...` and the summary `Search your Claude Code sessions and resume one.`
    - Options in alphabetical order with value hints and defaults: `--analytics`, `-d, --debug`, `--deep-search`, `--explain`, `--fails`, `--fzf`, `-h, --help`, `--json`, `-n, --limit <NUMBER>` (default: 10, max: 200), `--min-msgs <NUMBER>` (default: 0), `--no-color`, `--no-llm`, `--non-interactive`, `--preview <SESSION>`, `-p, --project <NAME>`, `--resume <SESSION>`, `-s, --since <TIME>`, `--stats`, `-u, --until <TIME>`, `-v, --version`.
      - (Round 2) Removed from the list: `--color`, which no longer exists, and the deprecated `--after` and `--before`, which are hidden (R050).
      - (Round 2) `<NUMBER|SESSION>` and `<auto|always|never>` are not in R436's allowed list, and R434 bans either-or hints. `<SESSION>` is the noun, and Notes defines its forms (R040).
    - Three examples taken from the header comment at :5-12. (Round 2) Long options only (R099), placeholders `<QUERY>` and `<SESSION>` only (R102), one real action each (R101), no `--after` or removed spelling.
    - The note "`claude-search -- help` searches for the word help".
    - (Round 2) Sections in order: Usage and summary, Arguments, Options, Examples, Notes, Learn more (R087, R092). Notes covers only material behaviour:
      - `<SESSION>` is a result number from the last search or a full session ID (R040).
      - Results go to stdout; everything else goes to stderr.
      - A search writes `search_log` and `~/.claude/.last-search-results.json`, and may start a background refresh of a stale index.
      - Few local matches can send the query to api.anthropic.com when `ANTHROPIC_API_KEY` is set; `--no-llm` or `SESSION_SEARCH_NO_LLM=1` stops that.
      - `SESSION_SEARCH_GUIDANCE_DISABLED`, `SESSION_SEARCH_DEBUG`, `SESSION_SEARCH_ACCESSIBLE`: precedence and empty-value behaviour (R079).
    - (Round 2) Learn more names https://github.com/renchris/claude-session-search. Layout follows R094, and no help line exceeds 80 columns (R095). R088 is N/A until C4, because there is no Commands section. R096 means no generic overview and no "run --help" hint.
  - Help is handled before the engine-installed check.
  - (Round 2) Recorded conflict: R087 asks for help generated from metadata, but R012 needs this help with no engine installed, and metadata lives in the engine. So the wrapper's help stays hand-written, and the drift check below keeps it honest (R422).
  - Tests:
    - `"--help works without the engine installed"`: remove the engine. Status 0, stdout contains `Usage: claude-search`.
    - `"help word shows help; -- help searches"`.
    - `"--help wins over other options"`: `--stats --help` gives 0 and no engine call.
    - `"help lists every visible engine option"`: a drift check. Take each long option from `python3 bin/session-search.py --help | grep -oE -- '--[a-z-]+'` and `grep -qF` it in the wrapper's help.
    - (Round 2) `"every help example parses"` (R100, R393): for each 4-space-indented `claude-search ...` line under `Examples:`, substitute `<QUERY>` with `q`, `<SESSION>` with a UUID and `<NUMBER>` with `1`. Run it through the wrapper with the stub engine, stub `claude` and stub `fzf`, so nothing live runs. Expect status 0. Feed the same argv to `build_parser().parse_args` and `validate_args` through `tests/engine_loader.py`.
    - (Round 2) `"help sections are in order and fit 80 columns"` (R095, R393).
- **B6.4 Engine-missing message** (R004, R280, R361)
  - Site: :15-21, moved after help handling.
  - Message: `Can't run claude-search: engine not found at ~/.claude/bin/session-search.py.`, a blank line, `Install it:`, then `    bash <repo>/install.sh`. `<repo>` comes from `readlink "$0"` when the script is a symlink; otherwise print the literal `/path/to/claude-session-search`.
  - Exit 1 (Round 2: corrected from 2). In R361 and Reference J, `missing_command` (exit 2) is a Usage class for a child the user was supposed to name; a hard-coded dependency that can't start is `spawn_failed` (exit 1). The round 2 findings on tag.sh and the backfill prerequisites read it the same way, so all of this repo's missing-dependency exits now agree.
  - Test `"missing engine names the install command"`.
- **B6.5 Resume** (R275, R003, R339, R001, R016, R043)
  - Site: :62-85.
  - When the value matches the UUID grammar, do an exact lookup with `python3 "$SEARCH_PY" --json --preview "$v" >/dev/null || exit $?`.
  - Otherwise: `SESSION_ID=$(python3 "$SEARCH_PY" --resume-result "$v" ${FWD...} -- ${QUERY_PARTS...}) || exit $?`, with no `2>&1`.
  - Validate the result with `case "$SESSION_ID" in ''|*[!A-Za-z0-9_-]*) error; exit 1;; esac`.
  - If `claude` is missing, exit 1 (Round 2: same correction as B6.4).
  - (Round 2) A `wf_*` ID never reaches `claude --resume` (invariant 15). The engine already refuses it on the numbered path, and the UUID path can't match it.
  - Print `Resuming session <id>` to stderr, then `exec claude --resume "$SESSION_ID"`.
  - Tests:
    - `"engine error on resume reaches stderr with its exit code"`: stub with `STUB_RC=2` and `STUB_ERR='Result #9 is out of range'`. Status 2, stderr contains the message, no claude call.
    - `"malformed session ID is refused"`: the stub prints `a b`. Status 1, no claude call.
    - `"Resuming line goes to stderr"`.
    - `"--resume <uuid> resumes that exact session"`.
    - `"--resume <unknown uuid> fails"`: status 1, no claude call.
- **B6.6 fzf mode** (R071, R360, R003, R337, R339, R017, R014, R113, R361)
  - Site: :110-148.
  - Missing fzf: exit 1 (Round 2: same correction as B6.4) with `--fzf needs fzf.`, a blank line, `Install it:` / `    brew install fzf`, and the plain-search alternative.
  - Interactivity gate: require `[ -t 0 ] && [ -t 2 ] && [ -z "${CI:-}" ] && [ -z "${CLAUDECODE:-}" ]`, and no `--non-interactive` (Round 2: a detected agent is non-interactive under R113 and R117). Otherwise exit 2 with `claude-search: --fzf needs an interactive terminal.` and `Search without the picker:` / `    claude-search "<QUERY>"`.
    - R113 includes CI. assets/demo/fzf-demo.tape:15-23 therefore gains hidden `Type "unset CI"` + `Enter` lines in the same commit, because demo.yml:61 runs vhs where `CI=true`.
    - (Round 2) `SESSION_SEARCH_ACCESSIBLE=1` also refuses the picker with the same message, because an arrow-key list is not usable there (R121). The plain search stays the alternative.
  - Quoting: `printf -v SP_Q '%q' "$SEARCH_PY"`, and `[ ${#FWD[@]} -gt 0 ] && printf -v ARGS_Q '%q ' "${FWD[@]}"`. Run as `SHELL=/bin/bash __SESSION_SEARCH_PICKER=1 fzf ...` (Round 2: fzf's child commands inherit the variable, so no bind needs `--color`).
  - Initial list:
    - With a non-empty query, run the engine with `__SESSION_SEARCH_PICKER=1` and `--format=fzf` into a `mktemp` file, leaving stderr visible. If it fails, exit with its code before fzf starts.
    - With an empty query, start fzf on empty input without calling the engine. B3.2 makes an empty query exit 2, so calling it would fail.
  - Binds:
    - preview: `python3 $SP_Q --preview {-1}`.
    - reload: `change:reload:python3 $SP_Q --format=fzf --no-log ${ARGS_Q}-- {q} 2>/dev/null || true`.
    - ctrl-o: `execute(p=$(python3 $SP_Q --json --preview {-1} 2>/dev/null | jq -r '.session.project_path // empty'); [ -n "$p" ] && open "$p")`.
    - header: `Enter: resume | Ctrl-Y: copy ID | Ctrl-O: open project`.
    - `--expect=ctrl-y` replaces the `execute-silent(...)+abort` bind at :128.
  - Result handling, with `rc=0; OUT=$(fzf ... <"$TMP") || rc=$?`:
    - rc 0 and key `ctrl-y`: pbcopy the ID, print `Copied session ID <id>` to stderr, exit 0.
    - rc 0 otherwise: resume through the B6.5 path. (Round 2) A selected `wf_*` row previews instead and exits 0, keeping origin/main bin/claude-search:143-146.
    - rc 1: `No session selected.` on stderr, exit 0.
    - rc 130: `Canceled.` on stderr, exit 130.
    - any other rc: exit with it.
    - rc 0 with an empty selection: exit 1.
  - Tests (`run_in_pty` with stub fzf):
    - `"fzf: project with spaces and ; reaches the engine as one argument"`: `FZF_RUN_RELOAD=x`. The engine argv contains `--project` followed by `a b; touch X`, and `X` does not exist.
    - `"fzf: Esc exits 130 and says Canceled"`.
    - `"fzf: no match exits 0"`.
    - `"fzf: ctrl-y copies the ID and exits 0"`: the pbcopy stub got the ID, and claude was not called.
    - `"fzf: engine failure stops before fzf starts"`.
    - `"fzf: refuses without a terminal"`: plain `run` gives 2.
    - `"fzf: refuses under CI"`.
    - (Round 2) `"fzf: refuses under CLAUDECODE"`.
    - (Round 2) `"fzf: a wf_ selection previews and does not call claude"`.
    - `"fzf: missing fzf exits 1 with the install command"` (Round 2: exit code corrected).
    - `"fzf: empty query opens the picker without calling the engine"`.
    - `"demo tape unsets CI"`: `grep -q 'unset CI' assets/demo/fzf-demo.tape`.
- **B6.7 Header comment** (R023)
  - Site: :1-12.
  - Change: correct the examples (`--json` now works, add `--analytics`, add `--since`).

### U7: `README.md` and `tests/docs.bats` (alongside U5; land last in Wave B)

- **Flag table** (:345-357, R023, R053):
  - `--resume <SESSION>` (Round 2: R434).
  - `-s, --since` and `-u, --until <TIME>` (Round 2: `--after` and `--before` are not taught, R047, R049; one line says they still work and warn), with an upper bound now working on its own.
  - `--json` with the envelope and its fields (C1); note that `--format json` is deprecated.
  - New rows: `--no-llm`, `--no-color`, `-v, --version`, `-h/--help` and `--fails` (Round 2: `--color` removed).
- **Hero sample** (:16-31): drop the footer box, because the tip is now interactive-only and on stderr.
- **Privacy note** (:37): mention `--no-llm` and `SESSION_SEARCH_NO_LLM`, plus the fzf behaviour decided in C5.
- **New "Exit codes" table:** 0 success or empty result; 1 failure, including a missing dependency (Round 2: moved from 2, see B6.4); 2 usage error or missing input; 130 canceled.
- **New "Behavior changes" list:**
  - Usage errors now exit 2 on stderr.
  - Preview of an unknown ID exits 1.
  - `--deep`-style abbreviations are rejected.
  - `claude-search help` shows help; use `claude-search -- help` to search for the word.
  - Cancelling the picker exits 130.
  - `--fzf` refuses non-interactive and CI runs.
  - Zero-result prose and tips now go to stderr.
- **Tests:**
  - `@test "README flag table lists every visible engine option"`.
  - `@test "README examples parse"` (R393): for each `claude-search ...` line in fenced bash blocks, every `--option` must be in the parser's option set. The examples are not run.
- **(Round 2) Additions.** U7 stays the only owner of `README.md` in Wave B and lands last, so nothing is taught before its parser ships (R053).
  - Wording (R060): the table heading "Flag" (:344) and "Flag-style" (:115) become "Option".
  - Stale counts (finding "stale description", R023): "3-phase" at :85, :241 and :379 becomes "7-phase".
  - Python floor: :93 says `python3 ≥ 3.8`; it becomes 3.10 (invariant 8). Linux: `launchd` jobs are macOS-only (:88) and on other hosts the installer now says so (B14.4).
  - Tagger examples at :277 and :280 (finding "entry point taught differs", R047, R356): teach `session-index-tag.py`, which is what install.sh:149 puts on PATH, and which the docstring and :380 already teach. Do not add a third name. Keep `scripts/session-index-tag.sh` working but unlisted. Replace the inline `ANTHROPIC_API_KEY=sk-... ` example with a key read from a secret manager, then the command on its own line:
    - `export ANTHROPIC_API_KEY="$(<your secret manager's read command>)"`
    - `session-index-tag.py`
  - Privacy note (:37): add that the tagger sends summaries and a prompt prefix to api.anthropic.com only when a key is set, and that `--regex-only` stays local (C12).
  - Installer details (:79, :83-89): add `./install.sh --help` and `./uninstall.sh --help` once B14.1 and B15.1 ship. Add `./uninstall.sh --dry-run` once B15.4 ships. "Idempotent, safe to re-run" stays until C9 and then describes the consent gate.
  - New "Glossary" (R423, R424, R046, R428): session (identity: full session ID, the `<SESSION>` hint; banned synonyms: conversation, chat, as nouns in copy), result (a ranked row of a search), index (`session-index.db`), transcript, chunk, tag, workflow result (`wf_*`, not resumable). Output labels an ID as `Session ID`. README prose stays free to say "conversation" where it means the transcript's content, as at :64, but CLI copy doesn't.
  - New "Environment variables" table (R079): each `SESSION_SEARCH_*` variable with precedence, empty-value behaviour and persistence. `__SESSION_SEARCH_*` stay undocumented.
  - "Exit codes" table: add a row per maintenance script once the C6 and C8 decisions land.
  - Tests:
    - `@test "README teaches no inline API key"`: no `ANTHROPIC_API_KEY=sk` in the file.
    - `@test "README teaches session-index-tag.py, not the .sh wrapper"`.
    - `@test "README has no Flag heading and no 3-phase claim"`.
    - `@test "README script examples parse"`: `./install.sh`, `./uninstall.sh` and `session-index-*` lines run with `__SESSION_SEARCH_PARSE_ONLY=1`, or through the Python parser for the `.py` files (R100, R393).
    - `@test "every SESSION_SEARCH_ variable the code reads is in the README table"`: `grep -rhoE 'SESSION_SEARCH_[A-Z_]+'` over bin, scripts and hooks, minus SESSION_SEARCH_REPO and SESSION_SEARCH_PYTHON_DEPS, which the helpers set themselves (R079).

### U12: `scripts/session-index-backfill.sh` entry and parser (Round 2; after U11a and U11b; lands before U3)
Also owns `config/com.claude.session-search-backfill.plist` and `tests/backfill_cli.bats`.

Callers for all U12 and U16 rows (measured: `grep -rnI session-index-backfill`): invariant 9. No caller parses output. `tests/` and `.github/` have no reference. Hint strings only at bin/session-search.py:1779, scripts/session-index-tag.py:716 and README.md:337.

- **B12.1 The PATH-installed entry cannot start** (R006, R003, R275, R053; severity high)
  - Sites: :10-13; install.sh:150; config plist:11. Latent behind line 13: :626, :644, :655. The real R053 hook is the recovery text at bin/session-search.py:1779 and scripts/session-index-tag.py:716, because that name on PATH is the symlink that dies.
  - Evidence: `$0` is not resolved and `~/.claude/bin/lib` does not exist (measured: `ls`). `~/.claude/logs/backfill-scheduled.log` holds this exact error 24 times (measured: `awk`). This machine hides it because the installed plist calls `readlink -f`.
  - Change: replace :10-11 with a `readlink` loop that handles relative links and chains. Do not use `readlink -f` (older macOS) and do not copy helpers:12, which is a single non-looping readlink. Then, before :12-13, check each required file and fail by name, keeping rc=1 so the infra `verdict=` line and install.sh's `set -e` see today's code: `session-index-backfill: cannot find <file> (resolved repo: <dir>). Re-run install.sh from the claude-session-search checkout.` The optional-file branches for Phases 6 and 7 stay as they are.
  - Callers: the real-path callers get the same directories as before. The symlink path goes from always rc=1 to working.
  - Tests: `"backfill runs through a symlink"` (status 0, stderr has no `No such file`); `"backfill runs through a chained symlink"`; `"a missing required file is named and exits 1"`.
- **B12.2 No help, and usage errors exit 1** (R012, R081, R083, R087, R055, R084, R304, R337, R060; severity high)
  - Sites: :3-7, :12-13, :19-26.
  - Change:
    - A `-h`, `--help`, or first-argument `help` scan runs before any `source`, so help wins over other validation. Usage goes to stdout, exit 0, with Usage, Options, Examples and Notes. The comment at :3-7 becomes a pointer to it, so `--quiet` has one honest description.
    - `css_parse_args` replaces :19-26. `--` and `--name=value` work. An unknown option prints `Unknown option <x>. Run session-index-backfill.sh --help.` and exits 2. Leftover positionals exit 2. The sources at :12-13 move below the parse, since parsing uses no library symbol (`grep`), but cli-common.sh is sourced first.
    - Exit 1 stays for missing sqlite3 and jq (:39-44): those are operational. Add python3 to that check, because B12.3 and Phase 7 need it.
    - `--quiet` stays accepted because all three callers pass it. Help says it has no effect until C14 decides.
  - Callers: only invocations that already failed change.
  - Tests: `"--help works with no DB and no libraries loaded"`; `"help word shows help"`; `"--bogus exits 2 naming the option"`; `"--bogus --help prints help"`; `"every backfill help example parses"` (R100: `__SESSION_SEARCH_PARSE_ONLY=1`, so nothing runs).
- **B12.3 `--since` is unvalidated, spliced into SQL, falls back to a full run, and takes only bare days** (R071, R074, R013, R066, R069, R443; severities medium and low)
  - Sites: :6-7, :23, :32, :34, :86, :164, :478, :488, :538, :550, :648.
  - Change: one parse after the option loop and before `session_index_init_db` (:48):
    - Accept `-s, --since <TIME>` and `--since=<TIME>`: a bare integer means days, 1 to 36500; `7d`, `12h`; ISO 8601, with no offset meaning UTC. The value goes through `python3 "$SCRIPT_DIR/lib/cli_common.py" parse-time "$v" --min-days 1`.
    - Refuse empty, `0`, negatives, `1.5`, `abc` and a missing value with exit 2: `session-index-backfill.sh: invalid --since 'abc': whole days 1-36500, a relative value (7d, 12h), or ISO 8601.`
    - Derive three values: integer `SINCE_EPOCH`, `SINCE_FILTER="AND modified_at > datetime($SINCE_EPOCH,'unixepoch')"` and `SINCE_LABEL` for :86 (today's `${SINCE_DAYS}d` would print `7dd`). An integer epoch closes the splice at :32.
    - Remove `|| echo 0` at :34. A regex alone does not close it: `--since 99999999999` passes `^[1-9][0-9]*$` and `date` still fails, giving epoch 0 (measured by the verifier).
    - Phase 7 (:648) passes whole days rounded up. session-index-chunk.py's `type=int` parser stays valid at every step, and rounding up only chunks a superset.
    - Help states the default window (all history) and the timezone.
  - Callers: `--since 7` from bin/session-search.py:268 behaves the same. `--since 0` is newly refused, and no caller passes it.
  - Tests: `"--since accepts 7, 36500, 7d and an ISO date"`; `"--since refuses 0, 100000, 007, abc, empty, 1.5 and -3 with exit 2"`; `"invalid --since leaves no DB behind"`; `"--since 7d hands the chunk script a whole number of days"` (stub chunk script logs argv); `"--since with no value exits 2, not 127"`.
- **B12.4 Repo plist masks the exit code** (finding "PATH-installed entry", step 4; R003, R339; decision C18)
  - Site: config/com.claude.session-search-backfill.plist:11, which ends `| head -50 >> log`. launchd sees head's status.
  - Change, if C18 picks option A: port claude-infrastructure/launchd/com.claude.session-search-backfill.plist:11 byte for byte (the `readlink -f`, temp file, `verdict=` form). install.sh:257 copies the repo plist over the installed one and migration 0025 `--verify` compares against the infra copy, so any other content makes the two repos conflict.
  - Test: `"repo plist does not pipe the script into head"`, and `"repo plist parses"` with `python3 -I -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))'`.

### U13: `scripts/lib/progress-ui.sh` (Round 2; after U11a; before U14)
Also owns `tests/progress_ui.bats`. Callers: sourced only by install.sh:26 and backfill:13. Its `$(...)`-captured helpers (`_ui_spin`, `_ui_bar`, `_ui_eta`, `_ui_elapsed`, `_ui_now`) must keep printing to stdout. No caller parses its output, and `grep -F '[ok]'` across the repo finds nothing outside install.sh.

- **B13.1 Colour and rich are separate decisions** (R206, R115, R199, R207, R208, finding "color and glyph rules")
  - Sites: :15, :19-36.
  - Change: `_UI_IS_TTY` stays "stdout is a rich terminal" via `css_rich 1`, and keeps gating redraw, cursor and boxes. `_B _D _R _G _RD _Y _C` come from `css_color_enabled 1`. `_CL _UP _SAVE _RESTORE _HIDE _SHOW` stay tied to `_UI_IS_TTY`, so `NO_COLOR` removes only colour on a TTY (R207). Add a stderr set (`_E_RD _E_C _E_R` from `css_color_enabled 2`) for the styled `>&2` lines in install.sh until C7 collapses the two streams. Forced colour on a pipe never turns on rich rendering. `--no-color` reaches this file as the exported internal `__SESSION_SEARCH_NO_COLOR=1`, which also carries to the child at install.sh:214.
  - Tests: `"NO_COLOR drops colour but keeps cursor control on a TTY"` (`run_in_pty`); `"TERM=dumb drops both"`; `"FORCE_COLOR on a pipe adds no cursor codes"`; `"./install.sh 2>err.log writes no escape codes to the file"` (the R115 check).
- **B13.2 Plain rows use words** (R205, R186, R182; findings on install.sh glyphs and backfill streams)
  - Sites: :154, :220, :234, :245, :258, :273.
  - Change: in plain mode `$label: done, $detail (${elapsed}s)`, `$label: skipped ($reason)`, `$id: ok ...`, `Error: $id ...`, at column 0. Rich branches keep `✓` and `○`. One output line per row, so `head -50` still holds.
  - Test: `"plain rows carry no glyph and start at column 0"`; `"one line per row"`.
- **B13.3 Non-TTY phase starts** (R328; finding "no target shown, no preview, and stale description")
  - Sites: :190, :206.
  - Change: an unconditional line would break invariant 9, because `ui_phase_active` runs inside per-item loops. Print one line per label: add `_UI_PHASE_LINES=false` and `_UI_LAST_PHASE=""`, dedupe on the label (Phase 6 calls `ui_phase_active_simple` twice with different details). Only backfill sets it true, and only when not `--quiet`, so all automated callers stay byte-identical.
  - Test: `"100 ui_phase_active calls print one line"`; `"quiet leaves phase lines off"`.
- **B13.4 Header comment** (R023): :9-10 claims all functions degrade to clean plain text. Correct it. It also names `lib/progress-ui.sh` relative to `$0`, which is the B12.1 defect.

### U14: `install.sh` compatible fixes (Round 2; after U13)
Also owns `tests/install.bats`.

Callers for all U14, U15 and U22 rows (measured: `grep -rnI 'install\.sh'` across the repo, including untracked dirs): no caller runs the installer programmatically, passes arguments, parses output or branches on its exit code. README.md:75 and :103 are human instructions, and `git pull && ./install.sh` has nothing chained after it. bin/claude-search:19, scripts/session-index-tag.sh:11 and scripts/session-index-tag.py:703 are hint text. ci.yml:19-23 and demo.yml:56-58 bootstrap with `cp`. `grep` of sibling repos for `claude-session-search/install.sh` found citations only. Invariant 12 is the one constraint.

- **B14.1 `--help`, or any argument, runs the full install** (R012, R064, R081, R083, R055, R086; severity high)
  - Sites: install.sh:5 (no argv handling), then the mutations at :141, :172, :214, :235, :257. :106 is only a timer.
  - Change:
    - Help scan right after :5, before `$HOME` is read at :8, so an unset HOME can't abort help under `set -u` (the trap R083 names). It runs ahead of the `source` at :26, the prerequisite exits at :94 and :101, and all mutation.
    - After :7, source cli-common.sh and call `css_parse_args` with `-v/--version`, `--json`, `--no-color`, `--non-interactive`. The options from C9 join this table only when C9 ships (R053).
    - `--version` prints `css_version` and exits 0; with `--json`, `{"version":"..."}` through `printf`, because jq has not been checked yet. `--help` wins when both are given.
    - Unknown options and any positional exit 2 with a help pointer: `./install.sh --bogus --help` prints help and exits 0, and `./install.sh --bogus` exits 2.
    - The bare path is unchanged: the loops iterate zero times under `set -u`.
  - Tests: `"--help changes nothing"` (`assert_tree_unchanged`, launchctl stub log empty, status 0, stdout has `Usage:`); `"--help works with HOME unset"`; `"--bogus exits 2 and changes nothing"`; `"--bogus --help prints help"`; `"help word shows help"`; `"--version prints only the version"`; `"--version --json is one document"`; `"bare install runs and exits 0"`; `"every install help example parses"` (R100: `__SESSION_SEARCH_PARSE_ONLY=1`).
- **B14.2 settings.json read-modify-write** (R138, R303, R275, R351, R319, R368, R366; severity medium)
  - Sites: :172-196.
  - Change, staying inside Step 2 so step order and exit 1 are unchanged:
    - First `css_settings_validate`, before any backup. On failure print `settings.json is not valid JSON: <path>: <jq error>` and `Fix that line, then re-run ./install.sh. The file was not changed.`, then exit 1. No restore and no backup on this path, because today's line 172 overwrites the good `.bak` with the broken file.
    - Probes keep their errors and tolerate commandless hooks: `select((.command // "") | test("session-index-end"))`. Check shape with `jq -e` and name the key path and expected type when it fails. Today, valid JSON of the wrong shape reports success with nothing written, and one commandless hook appends a duplicate entry on every run.
    - Write only when a hook is missing, with one `css_settings_patch` filter that adds whichever hooks are absent. No backup when nothing changes, because the script is documented as idempotent.
    - The "corrupted during patching" message stays only for a failure that happened during patching. Report the backup path. Tell the user the file was reformatted, because a byte-preserving JSON edit is not practical in shell (R366 residual).
  - Tests: `"broken settings exits 1 with line, column and path and writes nothing"` (cmp bytes; no new `.bak`); `"wrong shape exits 1 naming the key path"`; `"a commandless hook does not cause a duplicate"`; `"symlinked settings.json stays a symlink"`; `"mode 644 is kept"`; `"a second run writes no backup"`.
- **B14.3 FTS rebuild drops `search_aliases`** (R420, R017; severity medium)
  - Sites: :220, against the 11-column writers at helpers:316, helpers:551 and tag.py:1014-1018.
  - Change: a bare `session_index_rebuild_fts` would abort under `set -e`, because install.sh sources only progress-ui.sh. Use a subshell and report without aborting:
    - `if ! ( source "$REPO_DIR/hooks/lib/session-index-helpers.sh" && session_index_rebuild_fts ) >/dev/null; then FTS_NOTE=" (search index rebuild failed; rerun scripts/session-index-backfill.sh)"; fi`
    - :226 appends `${FTS_NOTE}`. stderr stays visible. Exit 0 and the later steps are unchanged on the failure path. Keep a rebuild here: it repairs a non-fatal tag.py FTS failure (tag.py:1024-1025) that would otherwise wait for the weekly job.
  - Tests: `"re-running install keeps aliases searchable"`: seed `search_aliases`, run install, then `sessions_fts MATCH` on the alias returns 1. `"install.sh has no INSERT INTO sessions_fts"`: one owner for the column list.
- **B14.4 Scheduler step aborts on hosts the prerequisite step supports** (R006, R007, R275; severity medium)
  - Sites: :245-274, :299. The abort site is `cp` at :257 and :264: the `launchctl` lines already have `|| true`, which is why `mkdir` alone would print a false "registered" on Linux.
  - Change:
    - Branch on `[ "$(uname -s)" = Darwin ]`.
    - Darwin: `mkdir -p "$HOME/Library/LaunchAgents"`, then guard each `cp` with `if ! cp ...`. On failure show the fail glyph, print the destination, what already applied and the retry command `./install.sh` to stderr, and exit 1.
    - Other hosts: no `~/Library`, no `launchctl`. `Scheduler  skipped: launchd is macOS-only`, plus a line saying the sweep and weekly backfill are not scheduled and that `~/.claude/bin/session-index-backfill.sh --quiet` runs the backfill by hand. Do not suggest scheduling the sweep: session-index-sweep.sh:51-52 and :142-143 use BSD `stat -f` with no fallback. Exit 0, matching the existing "plist not found, skipped" at :273 (C6 question b).
    - :299: pick the fzf hint with the same brew, apt-get, dnf cascade as :84-92, with no `=` before the description, because :307-308 split on it.
  - Callers: uninstall.sh:84-85, :88 and :96 keep working, since nothing is created under `~/Library` on Linux.
  - Tests: `"Linux skips the scheduler by name and exits 0"` (uname stub, no `Library` dir, launchctl log empty); `"Darwin creates a missing LaunchAgents dir"`; `"a failed cp exits 1 naming the destination and the retry command"`; `"fzf hint follows the package manager"`.
- **B14.5 Colour and glyph rules** (R203, R115, R199, R205, R412; severity low; also B13.1, B13.2)
  - Sites: :32-41, :47, :85, :87, :89, :91, :120.
  - Change:
    - :85, :87 and :89 are complete runnable commands: cyan at normal weight on stderr (R201, not "normal foreground"). :91 is prose: normal foreground. Leave :305 and :309 faint: that section is truly optional metadata (R203).
    - :120 `printf "\033[5A"` becomes a library helper `ui_cursor_up 5`. Delete the strip at :47, because every label is a plain literal.
    - Move the `_INST_SYM_*` set into progress-ui.sh's one glyph set. Plain rows read `Symlinks: hooks + bin linked`. Failures start `Error:`.
  - Tests: `"recovery commands are not faint"` (no `\033[2m` on a line with `brew install`); `"plain mode has no [ok] markers"`; the lint in `tests/scripts_lib.bats` covers raw escapes.
- **B14.6 Error copy and next steps** (R004, R276, R280, R105; severity low. R185 is refuted for `Ready`; see §5)
  - Sites: :21-22, :83-92, :97-99, :193-194, :204, :207, :234-240, :280-283.
  - Change, all through `css_fail`, keeping streams and exit codes:
    - :21-22: inline before anything can be sourced: `Can't load <path>. The file is missing.`, then `Restore it:` / `    git -C <REPO_DIR> restore scripts/lib/progress-ui.sh`.
    - :83-92: `Can't install. Missing <list>.` with the existing per-package-manager command, then `<REPO_DIR>/install.sh`.
    - :97-99: capture stderr instead of `2>/dev/null`, so the cause isn't guessed. `Can't create an FTS5 table with <command -v sqlite3>.` with the captured message as a detail row. On brew: `brew install sqlite`, then `PATH="$(brew --prefix sqlite)/bin:$PATH" <REPO_DIR>/install.sh`. (Homebrew's sqlite being keg-only is from knowledge, not checked in this run.)
    - :204, :207: the Settings row is not done when no file exists, so it does not take the default `✓`. Recovery prints after the summary, because the TTY roadmap redraws in place: `Hooks aren't registered. Create settings.json, then rerun:` / `    printf '{}\n' > ~/.claude/settings.json` / `    <REPO_DIR>/install.sh`. The exit code for this case moves to 1 under C6.
    - :234-240: three states, because "already in .bashrc" is false when the file doesn't exist: `already in`, `added to`, and `no shell config found` with the exact export line. Do not create the file: line 14 falls back to .bashrc even for a zsh user.
    - :280-283: title `Installed`, or `Partial` under C6, per R033 and R187. Drop the "Search" pair from this one call, leaving the helper alone (backfill:667 shares it). After the box print `Search your sessions:` / `    claude-search <QUERY>`. When `~/.claude/bin` is not on the current `$PATH` (test with `case ":$PATH:"`, not "was PATH added", which misses a rerun in the same old shell) first print `Add claude-search to this shell:` / `    export PATH="$HOME/.claude/bin:$PATH"`.
  - Tests: `"missing prerequisite names the command and exits 1"`; `"no settings.json prints the printf recovery"`; `"missing rc file does not claim already in"`; `"success ends with claude-search <QUERY> on its own line"`; `"PATH note appears only when bin is not on PATH"`.
- **B14.7 Global options and machine output, part 1** (R062, R086, R243; severity low; part 2 is C16)
  - Sites: :8, :13, and the parser from B14.1.
  - Change:
    - `--no-color`: exports `__SESSION_SEARCH_NO_COLOR=1` before `source` at :26. `--non-interactive`: accepted, documented as having no effect until C9 adds a prompt.
    - `--json`: `exec 3>&1 1>&2` before the source, force `_UI_IS_TTY=false`, and print one document to fd 3 at the end, built with `jq -n`: `{"installation": {"sessions":..,"tagged":..,"settings":..,"path":..,"scheduler":..,"claude_dir":..}, "outcome": "installed"}` (R248). Failures at :23, :83-94, :99-101 and :195, and a `set -e` abort at :214, go through an EXIT handler that chains `_ui_cleanup` (progress-ui.sh:346) instead of replacing it, and write one `css_json_error` line.
    - stdout without `--json` is unchanged here. C7 moves it.
    - R173 records a known deviation: an installer has no noun identity to print.
    - N/A under R062: `--cwd`, `--local-config`, `--scope`, `--token`, `--debug`. The script has no cwd use, project config, context, credential or diagnostics.
  - Tests: `"--json stdout is exactly one document, stderr holds the steps"`; `"--json failure writes nothing to stdout and one error line to stderr"`; `"--no-color has no colour but keeps layout"`; `"--json keeps the cursor-restore trap"`.

### U15: `uninstall.sh` compatible fixes (Round 2; after U11a)
Also owns `tests/uninstall.bats`.

Callers (measured: case-insensitive `grep` for `uninstall` across the repo): only README.md:103 (bare `./uninstall.sh`) and :384 (a file tree). CI and tests never invoke it. Invariants 12 and 14.

- **B15.1 `--help`, or any argument, performs the uninstall** (R012, R064, R081, R083, R055; severity high)
  - Sites: :4, :11, :18, :56, :89, :97.
  - Change: insert between :4 and :6, because :6 reads `$HOME` under `set -u`. Help scan first (`-h`, `--help`, first-argument `help`), printing to stdout with exit 0. Then `css_parse_args` for `--dry-run`, `-v/--version`, `--json`, `--no-color`, `--non-interactive`. Anything else exits 2 with a help pointer. Add `REPO_DIR` for the libraries. Do not add a `--yes` requirement: README.md:103 documents the bare form, and removal here is R146's ordinary tier (explicit, reversible through install.sh, DB kept).
  - Tests: `"--help removes nothing"` (`assert_tree_unchanged`); `"--help works with HOME unset"`; `"--bogus exits 2 and removes nothing"`; `"every uninstall help example parses"` (R100).
- **B15.2 Links install added stay behind** (compatible part of finding "says Uninstall complete", R420; severity high. The exit code part is C6)
  - Sites: uninstall.sh:35-36 against install.sh:149-151 and :161.
  - Change: add `remove_symlink` for `session-index-tag.py`, `session-index-backfill.sh` and `session-index-chunk.py`, and remove `$BIN_DIR/__pycache__/session-search.*.pyc`. A regular file at those paths stays `Skipped`, because install.sh:132-133 never overwrites one, so it isn't ours.
  - Test: `"uninstall removes every link install created"`: run install then uninstall in the sandbox; `find "$HOME/.claude/bin" -type l` is empty of this repo's links; an unrelated link stays.
- **B15.3 settings.json edit** (R351, R319, R368, R366, R138; severity medium)
  - Sites: :44, :47, :50, :56, :58, :61, :67, :69-74.
  - Change:
    - Validate in this step, not at the top. On failure print `ERROR: <path> is not valid JSON; left unchanged` to stderr, set `status=1`, skip the edit and continue, or the LaunchAgents stay loaded.
    - Check first whether an edit is needed: `jq -e` for any matching command. If none, print `- no hook entries in settings.json` and write nothing.
    - Do both removals in one `css_settings_patch` pass. The filter never creates keys and tolerates commandless hooks, unlike :53 and :64 today, where one prompt-type hook makes `test` fail and the script then prints a false `✓ Hook entries removed`.
    - `def strip($k;$p): if (.hooks?|type)=="object" and (.hooks[$k]|type)=="array" then .hooks[$k] |= map(if (.hooks|type)=="array" then (.hooks |= map(select((((.command?)|strings|test($p))//false)|not))) | select(.hooks|length>0) else . end) else . end; strip("SessionEnd";"session-index-end") | strip("SessionStart";"session-index-start")`
    - Remove the restore at :69-74, since nothing reaches the target unvalidated. Keep the stdout lines. `Uninstall complete.` prints only when `status=0`; otherwise `Uninstall incomplete: fix <path>, then re-run ./uninstall.sh` on stderr with exit 1. That exit changes only paths that exit 0 today after a failure.
    - Backups are unique files, so an uninstall after an install keeps the pre-install backup. Today :44 and install.sh:172 overwrite the same `.bak`.
  - Tests: `"absent keys are not created"` (`{"model":"x"}` stays that exact object, no write); `"a prompt-type sibling survives"`; `"symlink and mode are kept"`; `"invalid JSON exits 1 with bytes unchanged and plists still removed"`; `"a rerun adds no backup"`.
- **B15.4 Preview and safe delete command** (R001, R103, R105, R004; severity low. R325 is not violated and R002 is weak; see §5)
  - Sites: :11, :108.
  - Change: `--dry-run` from B15.1 prints the plan to stdout and exits 0 before any `rm`, `cp`, `mktemp`, `mv`, `jq` write or `launchctl`. A real run prints the same plan to stderr first, one target per line: every link from :28-36 and B15.2, `$SETTINGS` (hook entries, backup), both plists (unload and delete), and the DB as kept. Replace :108 with a label and one indented, quoted command:
    - `DB="$CLAUDE_DIR/session-index.db"`
    - `echo "To delete it:"`
    - `printf '  rm -f %q %q %q\n' "$DB" "$DB-wal" "$DB-shm"`
    - WAL mode is set at bin/session-search.py:238, helpers:161 and tag.py:769, and all three files exist on this machine (measured: `ls`). Keep :107, which is a correct receipt.
  - Tests: `"--dry-run changes nothing and lists every target"`; `"delete hint quotes a HOME with a space and names -wal and -shm"`; `"plan prints before the first removal"`.
- **B15.5 Global options and machine output** (R062, R086, R243; severity low; config-dir part is C16)
  - Sites: :6-8 and the parser.
  - Change: `-v/--version` through `css_version`. `--json`: one jq-built document on stdout with progress on stderr, R248's bulk shape: `{"results":[{"id":<path>,"outcome":"removed"|"skipped"|"not_found"}],"summary":{...}}`. Report real outcomes, not messages: a failed jq at :50-56 would otherwise be reported as removed. Accept `--no-color` and `--non-interactive`, which have nothing to govern yet. `--cwd`, `--local-config`, `--scope`, `--token` are N/A.
  - Tests: `"--json is one document with one row per target"`; `"--version needs no HOME"`.

### U16: `scripts/session-index-backfill.sh` pipeline (Round 2; after U4, which also owns these files in B2)
Also owns `hooks/lib/session-index-helpers.sh` and `tests/backfill_pipeline.bats`. Callers: as U12.

- **B16.1 Raw `sqlite3` bypasses the busy-timeout wrapper** (R313, R314; severity medium. R019 and R015 are weak; see §5)
  - Sites: helpers:30-32 states the MUST. Raw lines: :59, :252, :454, :478, :481, :506, :537, :603, :630, :636, :638, :660, :661, :674.
  - Change:
    - Move the 11 argv sites to `session_index_sql`, keeping each site's `2>/dev/null || echo ...` until C6. :652 already sets `.timeout`. :549 needs `-separator`, which the wrapper can't pass, so it becomes `sqlite3 -separator $'\t' "$SESSION_INDEX_DB" ".timeout $SESSION_INDEX_BUSY_TIMEOUT" "SELECT ..."`, a recorded exception to helpers:30.
    - The 3 heredoc sites (:481, :506, :603) keep stdin and gain a `.timeout $SESSION_INDEX_BUSY_TIMEOUT` first line, the form `origin/main`'s migration uses. This departs from the verdict on purpose: the wrapper's stdin mode re-passes the SQL as one argument, and Linux caps a single argument at 128 KiB. A worst-case row is about 160 KB (estimated by arithmetic on the caps at helpers:499, :514, :522-523, with the SQL repeating each field in its `CASE`). That is rare, but a failure here would be new.
    - Swap :48 and :52, so `init_db` runs under the lock. `session_index_lock` needs only `$HOME/.claude`. Merge with B4.6's `--if-idle` branch.
    - Dropped as already done on `origin/main` (5811933): the migration heredoc's `.bail` and the failed-probe handling.
  - Test: `"every sqlite3 call in backfill sets a timeout"`: a static check that lists raw calls and allows only :549's form and the three `.timeout` heredocs. `"init_db runs after the lock"`.
- **B16.2 The wrapper alone does not cure the logged failures** (R313, R314, R316)
  - Evidence: all 5 failures in `backfill-scheduled.log` read `Error: stepping, database is locked (5)`, rc=5 (measured: `grep`). The verifier's probe shows that text comes only from argv mode, which `session_index_sql` already uses with a 5000 ms timeout. So those failures passed through the wrapper. What held the lock for more than 5 s was not identified.
  - Change: before the source at :12, `export SESSION_INDEX_BUSY_TIMEOUT="${SESSION_INDEX_BUSY_TIMEOUT:-60000}"` (60000 is an unmeasured suggestion). Add a bounded backoff retry on rc=5 around `session_index_upsert`, `session_index_load_synonyms` and `session_index_rebuild_fts`, printing `Retrying automatically…` once on stderr when not quiet. Exit nonzero when the budget is spent, so verdict lines stay truthful. Wrap the DELETE and INSERT at helpers:550-552 in BEGIN and COMMIT, so a failed INSERT can't leave an empty index.
  - Test: `"a locked DB retries, then exits nonzero"`, using `SESSION_INDEX_BUSY_TIMEOUT=10` and a held write lock via a Python child; `"a failed rebuild leaves the old index"`.
- **B16.3 Lock trap replaces the cursor cleanup, and temp files leak** (R335, R416; severity medium)
  - Sites: :52, :95, :132, :221, :304, :548, :665; progress-ui.sh:346; helpers:82.
  - Change, in this script only, because the hooks and install.sh depend on the helpers' and library's traps. Immediately after the lock, the only place that can win over helpers:82:
    - `TMPFILE=""; _P5_TMP=""; _BF_CHILD=""`
    - `_backfill_cleanup() { [ -n "${_BF_CHILD:-}" ] && kill "$_BF_CHILD" 2>/dev/null || true; _ui_cleanup; rm -f "${TMPFILE:-}" "${_P5_TMP:-}" 2>/dev/null || true; session_index_unlock; }`
    - `_backfill_on_signal() { trap - INT TERM HUP; exit "$1"; }`
    - `trap '_backfill_cleanup' EXIT; trap '_backfill_on_signal 130' INT; trap '_backfill_on_signal 143' TERM; trap '_backfill_on_signal 129' HUP`
    - Do not trap PIPE (plist :11). The `:-` guards are needed under `set -u`, because `--enrich-only` never sets TMPFILE. The EXIT handler calls no `exit`, so the status survives (R342).
    - Phase 7 (:649-653) runs in the background with `wait`, so a TERM isn't deferred until the child returns (measured on a toy model: 6 s to exit with a trap and a foreground child, 0 s without the trap). `session-index-chunk.py` reads no stdin.
  - Callers: on a signal, callers see the same 130, 143, 129 as before.
  - Tests: `"SIGINT exits 130, restores the cursor, removes temp files and unlocks"`; the same for TERM (143) and HUP (129); `"TERM during Phase 7 exits promptly and leaves no child"` (R364); `"a set -e failure keeps its status"`.
- **B16.4 BSD-only `date` and `stat`** (R006, R017; severity low, wider than filed)
  - Sites: :163, :266, :359, :366, :494, :498, and origin/main's :539 and :550. Lines 266, 359, 366 and 498 are not gated on `--since`, so the default path also writes wrong data on GNU. :498 would store a multi-line filesystem dump in `created_at`.
  - Change: add helpers to hooks/lib/session-index-helpers.sh that pick the dialect once at load with `date --version` and `stat --version` (both rc=1 on BSD, measured). Do not chain `stat -f ... || stat -c ...`: GNU `stat -f` prints before failing.
    - :163: `TZ=UTC date -jf` on BSD and `date -u -d` on GNU, because `modified` values are UTC (the `--since` grammar finding, step 5). This is a small correction on macOS, not a byte-identical port.
    - :266, :359, :366: `date -u -d "@$e"` on GNU.
    - :494: `stat -c %Y` on GNU.
    - :498: stays byte-identical on macOS, and its GNU branch keeps the same local-time-labelled-Z form. The mislabel itself is a separate defect, recorded and not changed here.
    - R017: a failed conversion no longer reads as epoch 0 meaning "old". Keep the row when the time is unknown (writes are repeatable: helpers:285 `ON CONFLICT`, Phase 4 `INSERT OR IGNORE`), with at most one stderr warning per run, so `head -50` isn't exhausted.
  - Not in this unit: session-index-sweep.sh:51, :52, :86, :142, :143, :167 and helpers:472 have the same pattern. Flagged for the hooks' own audit, because a hooks change is out of scope.
  - Fail-early option rejected: on Linux it turns a backfill that exits 0 into a nonzero exit at install.sh:214 after hooks and settings have run, and makes session-search.py:268 respawn a failing job on every search of a stale index, since `last_backfill` is never stamped.
  - Tests: `"--since keeps recent Phase 1 rows on this host's date dialect"`; `"transcript mtime is one ISO line"`; `"unknown time keeps the row and warns once"`.
- **B16.5 No target shown, and stale description** (R001, R023; severity low; `--dry-run` is C21)
  - Sites: :2, :3-7, :94.
  - Change: before `session_index_init_db`, `[ "$QUIET" = "true" ] || echo "Session index: $SESSION_INDEX_DB" >&2`. :94 is too late, because init and the lock have run by then. :2 reads "Idempotent backfill, run at install, weekly by launchd, and on stale index". Stream routing and exit codes are unchanged. Phase-start lines are B13.3, and README's "3-phase" is U7.
  - Test: `"not quiet names the DB on stderr first"`; `"--quiet output is byte-identical"`.
- **B16.6 Keep errors visible** (the "keep errors" half of the `--quiet` finding; R017, R275)
  - Site: fatal steps with `2>/dev/null` under `set -e`: :636, :648, :650, :660, :661.
  - Change: `trap 'rc=$?; echo "error: backfill failed at line $LINENO (exit $rc)" >&2' ERR`. It only adds stderr and must not call `exit`. It applies whatever C14 decides, and the plist's `2>&1` captures it.
  - Test: `"a failing Phase 7 names the line and keeps the exit code"`.
- **B16.7 Global options and machine output** (R062, R086, R243; severity low; config-dir part is C16)
  - Sites: :19, helpers:6, helpers:8.
  - Change: `-v/--version` before any source (the version comes from `$REPO_DIR/VERSION`, now correct after B12.1). `--no-color`. `--json`: `exec 3>&1 1>&2` before the source of progress-ui.sh, so its TTY check sees stderr, then one jq-built document on fd 3 from the existing counters (`phase1_count`, `phase2_count`, `phase2_skip`, `phase3_count`, `phase4_enriched`, `phase4_inserted`, `phase4_skipped`, Phase 5 counts, `_fts_count`, `_chunk_count`, `total`, `untagged`). On failure the EXIT handler from B16.3 writes `ok:false` with the last phase and keeps rc. `--json` does not imply `--quiet`. Keep `exit 1` for unknown options out of this row: B12.2 owns it.
  - Tests: `"--json stdout is one document with phase counts"`; `"--json on failure has an error document and the original rc"`; `"default output is unchanged"`.

### U17: `scripts/session-index-chunk.py` compatible fixes (Round 2; after U11b)
Also owns `tests/test_chunk_cli.py`. Load the module through importlib and call `main()` with a sandbox HOME.

Callers for U17 and U23's chunk rows (measured: `grep -rnE 'session-index-chunk|session_index_chunk'`, 7 hits): one executing caller, backfill :648 and :650, invariant 10. install.sh:151 and :158 only link and chmod. README.md:381 is a tree. The positional form has no caller. Line 240's text has no parser: backfill reads the count from SQLite at :652. `~/.claude/bin/session-index-chunk.py` is user-reachable, so unseen manual use can't be ruled out.

- **B17.1 Session ID is not validated in single-session mode** (R071, R013; severity medium by finding, low by verifier. R043 is dropped; see §5)
  - Sites: :153-154, :210, :225, :246, :279.
  - Change: module constant `SESSION_ID_RE`, used at :210 and :225. Right after `parse_args` (:250), and only in the positional form, before the DB check and DDL at :252-274: `SESSION_ID_RE.fullmatch(args.session_id)` or `parser.error`, which exits 2. `re.match` with `$` accepts a trailing newline. Then compare with the transcript path without resolving symlinks: the ID must be `p.stem` for `{sid}.jsonl`, or `p.parent.name` for `transcript.jsonl`; a mismatch calls `parser.error` naming both. Do not check the `sessions` table: backfill chunks transcripts without consulting it, and rows become searchable once sessions has the ID (bin/session-search.py:619-620). The file-name check blocks both harms.
  - Measured context: 0 of 282 chunked IDs are orphans, 1577 of 13070 session IDs are not UUIDs (`legacy-*`, `wf_*`), and backfill skips those too.
  - Tests: `"bad session ID exits 2 and adds no rows"`; `"ID and transcript name must agree"`; `"both valid layouts chunk"`.
- **B17.2 No top-level handling; per-item failures abort the batch** (R283, R295, R318, R335, R341, R348, R017; severity medium)
  - Sites: :37, :44-45, :139, :186, :203, :215, :235, :240, :256, :288-289.
  - Change:
    - :37: `open(path, 'r', encoding='utf-8', errors='replace')`.
    - Counters: succeeded, skipped_short, skipped_oversize, failed, malformed_lines, truncated_sessions. The short-session case at :109 stays a skip, not an error.
    - Wrap :215 and :235 in a helper. Catch per-file `(OSError, ValueError, AttributeError, TypeError)`, because valid JSON of a non-object shape crashes `.get` at :47, :83, :93. `conn.rollback()` is mandatory: `store_chunks` deletes before inserting and commits only at :177, so the next session's commit would otherwise persist a half-written delete. Name the file on stderr and continue.
    - `sqlite3.Error` is batch-fatal: roll back, stop, report the remainder as not attempted. Otherwise a locked DB costs the 5 s busy timeout once per remaining session.
    - Stdout line `Chunked N sessions -> M chunks` is unchanged until C7. A stderr summary adds succeeded, skipped, failed, not attempted, and: not atomic, each session commits separately, re-running is safe.
    - Exit 1 only when `failed > 0` or the batch stopped early, which already exits 1 today through the uncaught exception. Skips, malformed lines and `MAX_CHUNKS` truncation stay exit 0, or a routine long session would abort backfill and install under `set -e` (invariant 10).
    - Missing `PROJECTS_DIR` at :203: `projects dir not found: nothing to chunk` on stderr, exit 0. Today that traceback kills install Step 3 on a machine with no `~/.claude/projects`.
    - `main()` runs through `cli_common.run_cli`, with connect, PRAGMA and DDL (:256-274) inside it. BrokenPipe on the prints at :240 and :280 keeps the computed outcome, because this command mutates (R341).
  - Decision C17: whether backfill propagates this partial outcome.
  - Tests: `"one unreadable transcript does not stop the batch"`, and it exits 1 with the file named; `"a non-object JSON line is counted, not fatal"`; `"failure rolls back, so old chunks stay"`; `"missing projects dir exits 0"`; `"short session stays exit 0"`; `"transcript reads as UTF-8 under LC_ALL=C"`; `"internal error shows no traceback"`.
- **B17.3 Parser and help** (R065, R028, R067, R087, R091, R092, R436; severity low. R029 and R023 are dropped; see §5)
  - Sites: :5, :7, :245-249.
  - Change: `ArgumentParser(allow_abbrev=False, formatter_class=RawDescriptionHelpFormatter, epilog=...)`.
    - Add `--transcript <FILE>` with its own dest. A shared dest loses the value when the empty `?` positional overwrites it (measured on a stand-in parser).
    - Keep the positional visible (R023), as `legacy_transcript` with `metavar='transcript'` and help "Deprecated: use --transcript". Using it prints one warning (R050, R308). Passing both forms is `parser.error`. Use `metavar='session'` for the first positional (R434: the noun, not `session-id`).
    - `--since` `metavar='<NUMBER>'` until B17.4.
    - Epilog: Examples (two distinct jobs) and Notes: writes `~/.claude/session-index.db` and creates its tables if missing; exits 1 if that DB does not exist; a transcript over 52.4 MB or under `MIN_TURNS` (5) turns yields 0 chunks; at most `MAX_CHUNKS` (50) chunks per session. Sizes use decimal units (R218): 52428800 bytes is 52.4 MB, not "50 MB". Build numbers from the constants. Don't put a bare `%` in an epilog.
    - Keep the prints at :240 and :280, the help path at :282-283 until C8, and the full names backfill passes.
  - Tests: `"--back is rejected"`; `"S --transcript T and --transcript T S both work"`; `"both transcript forms exit 2"`; `"the positional transcript warns once"`; `"every chunk help example parses"` (R100: `shlex.split` each Examples line, then `parser.parse_args`, no DB touched).
- **B17.4 `--since` takes a time value** (R443, R436; severity low)
  - Sites: :7, :194, :200-201, :249, :277.
  - Change: `-s, --since <TIME>` through `cli_common.parse_time`, `metavar='<TIME>'`, help stating the default window (all sessions) and timezone. `backfill(conn, cutoff=None)` replaces `since_days`, and the timedelta at :200-201 goes. An ISO value with no offset reads as UTC, not local as the finding proposed: the engine (:321), the backfill grammar and the stored times all use UTC. Until C8, keep `0` as no cutoff and negatives as they are, because finding "conflicting inputs" makes those refusals a breaking change. The chain session-search.py:268 to backfill to :648 still passes a whole number.
  - Tests: `"--since 7, 7d, an ISO value with Z and a naive ISO value"`; `"garbage exits 2"`; `"0 stays no cutoff until C8"`.
- **B17.5 No target shown, and missing global options** (R001, R062, R086, R243; severity low. R325 and R073 constrain the fix rather than being violated; see §5)
  - Sites: :18-19, :153-154, :250, :277.
  - Change, all additive:
    - Move the bare-invocation help branch (:281-283, still exit 1 until C8) above `sqlite3.connect` at :256, so a preview doesn't fire on it.
    - Stderr only, after the DB check and before :256: `session-index-chunk: rewriting chunks in <DB_PATH>; scope: all sessions under <PROJECTS_DIR>` (or the time window, or one session). No new stdout lines.
    - `--json`: R248's bulk shape for backfill, `{"results":[...],"summary":{"succeeded","failed","skipped","unknown"}}`, and `{"session":{"session_id":..,"chunks":n},"outcome":"chunked"}` for one session. Keys are snake_case, as in B3.5. Human lines are suppressed. backfill never passes it.
    - `-v/--version` through `cli_common.VERSION`; `--help` wins.
    - `--no-color`: accept; the script emits no colour today. `-d/--debug`: traceback through `run_cli`.
    - Config dir is C16. `--dry-run` is C21. Do not read `CLAUDE_CONFIG_DIR`: backfill hardcodes `~/.claude` (helpers:6, :8), so honouring it here alone could exit 1 on "Database not found" and abort the whole backfill.
  - Tests: `"--json one session is one document"`; `"--json backfill is a results and summary document"`; `"--version needs no DB"`; `"the target line goes to stderr only"`; `"bare invocation shows help with no DB write"`.

### U18: `scripts/session-index-tag.py` safety and correctness, plus `scripts/session-index-tag.sh` (Round 2; after U11a and U11b)
Also owns `tests/test_tag_cli.py` and `tests/tag_wrapper.bats`.

Callers for all tagger rows (measured: `grep -rn session-index-tag` across the repo, plus `~/.claude/hooks`, `settings.json`, `~/Library/LaunchAgents` and crontab): install.sh:217 (invariant 11, never reaches the API path, ignores exit code) and scripts/session-index-tag.sh:15 (`exec` pass-through). install.sh:149 and :156 only link and chmod. README.md:277 and :280 are human examples. docs/TAG_EXTRACTION_PIPELINE_DESIGN.md:674 and :688 use `--quick-tag` and `--full-pipeline`, which don't exist, and `docs/` is untracked. Nothing parses output or branches on exit code. The strings `Done in`, `tagged=`, `Tagging complete` and `Mode:` have no reader.

- **B18.1 Prints part of the API key** (R018, R355; severity high by finding; the verifier judges medium, since `sk-ant-api03-` is 13 of the 14 characters, but any other key format shows up to 14 real characters)
  - Sites: :483-486. Gated only by `--quiet` at :846, with no TTY check, so it also reaches pipes and logs.
  - Change: delete the comment at :483 and `masked` at :484. :486 becomes `print(f"\n  Mode: {BOLD}Haiku + Regex{RESET}  ({sdk_label}, key: {DIM}ANTHROPIC_API_KEY{RESET})")`. That is the only key source (:753). Keep the `api_key` parameter, because :480 and :482 test it.
  - Test: `test_banner_never_prints_key_material`: with a marker key, no 4-character substring of its secret part appears on either stream, in any mode, including `print_summary_box` and errors (R399).
- **B18.2 Raw tracebacks, and post-work failures change the exit code** (R283, R295, R341, R342, R348; severity medium. R138 is dropped; see §5)
  - Sites: :116-121, :767-830, :925, :994, :1024, :1051, :1065, :1074-1075.
  - Change, keeping stdout strings and the existing exit 0, 1, 2 paths:
    - `log()` becomes best-effort: `try/except OSError`, `encoding="utf-8"`. So :995 still prints its stderr message, :1024 stays non-fatal, and :1065 can't turn a commit into exit 1.
    - :994: `if conn.in_transaction:` then ROLLBACK inside its own `try/except sqlite3.Error`. A failed BEGIN IMMEDIATE leaves no transaction, so today the handler itself raises and the message never prints.
    - `_detach_stdout()` (`os.dup2` of devnull). Wrap the banner (:844) and summary (:1051) in `try/except BrokenPipeError`, then flush under the same guard at the end of main. The batch write still finishes and the process exits with its real outcome instead of 120. Do not use `signal(SIGPIPE, SIG_DFL)`: R341 allows that only for reads.
    - `cli_common.run_cli` at :1074: `sqlite3.Error` becomes `Could not read session index <DB_PATH>: <e>` with recovery naming `session-index-backfill.sh`, exit 1. `Exception` becomes the R295 block. Both restore the cursor first, because HIDE_CURSOR at :855 otherwise stays active. KeyboardInterrupt in the window after :1037-1038 exits 130. Signals during work are C8.
  - Decision C15 supplies the Version row. Exit effect: uncaught exceptions were already exit 1. Only a closed stdout after a commit changes, from 120 to 0, and no caller observes it.
  - Tests: `"a DB with no sessions table has no traceback and names the file"`; `"a failed BEGIN still prints the error and exits 1"`; `"an unwritable log after commit exits 0"`; `"a closed stdout after commit exits 0"`; `"an internal error prints the R295 block and no input text"`.
- **B18.3 Lock failure misreports the cause** (R275, R280, R004, R276, R285; severity low)
  - Sites: :743, :746-747. (:716 is unrelated and fine.)
  - Change, keeping exit 1 and the print under `--quiet`. `except BlockingIOError` goes before `except OSError`:
    - `✗ Can't tag sessions. Another session-index process holds <lock_path>.`, then `When it finishes, rerun:` and `    <shlex.join(["python3", *sys.argv])>`. Hooks take the same lock, so "tagger or backfill" would still guess.
    - `OSError`: `✗ Failed to lock <lock_path>. <exc.strerror>.`, then `Fix access to that path, then rerun:` and the command.
    - Keep the `ImportError` branch for hosts without `fcntl`.
  - Tests: `"held lock names the path and the rerun command"`; `"an unwritable lock dir reports the OS error, not a conflict"`.
- **B18.4 Transcript and model text is treated as trusted** (R011, R359; severity medium)
  - Sites: :149-158 and :213-222 (duplicated prompts), :190-203 and :238-251 (duplicated validation), :375, :417, :423. Line 466's `project_filter` is the user's own argv, so it is optional hardening only. The first stored tag reaches future Claude sessions, uncapped, through bin/session-search.py:883 and hooks/session-index-start.sh:23-32, so this is more than cosmetic.
  - Change:
    - `_build_tag_prompt()`: one builder for both paths. Fields go inside `<session_data>...</session_data>`, any literal closing delimiter is neutralized, and the text states the content is data to classify and its instructions must not be followed. Keep `first_prompt[:300]`, and cap `summary`.
    - `_validate_model_output()`, the actual control: normalize tags (NFKC, lowercase, spaces and underscores to hyphens), keep `^[a-z0-9]+(-[a-z0-9]+)*$` with a length cap of 40 and at most 10 tags. If none survive, raise `ValueError`, which maps to `api_parse` and the existing regex fallback. Summary: strip controls, collapse to one line, cap at the 80 characters the prompt asks for. Aliases (:198-201, :246-249, missed by the finding): strip controls, remove commas, because they join with `", "`, cap length, at most 15.
    - `_sanitize_display` (from `cli_common`) on `tags_str` before :375 and :417, not on assembled lines, because those carry ANSI styling. Do not sanitize `args.project` where it is bound to SQL at :783, :798, :813, :816.
    - Existing rows are not cleaned, and read-side sanitizing is B5.3.
  - Tests: `test_prompt_marks_session_text_as_data`; `test_model_tags_outside_grammar_are_dropped`; `test_no_surviving_tags_falls_back_to_regex`; `test_summary_is_one_line_and_capped`; `test_alias_commas_are_removed`; `test_dashboard_strips_escape_sequences`.
- **B18.5 Help omits its environment variable and misdescribes options** (R065, R079, R087, R091, R092, R102, R436; severity low. R023 and R029 are dropped; see §5)
  - Sites: :10, :14, :675, :703, :708, :753, :773, :779.
  - Change, parser block only, no SQL change:
    - `allow_abbrev=False`. `metavar="<NUMBER>"` on `--limit`, `metavar="<NAME>"` on `--project`, and `-n` as `--limit`'s short form (R444).
    - `--retag-summaries` help matches the code: "fill empty summaries via Haiku, for any session with no summary; a session with no tags also gets tags and tagged_at (requires ANTHROPIC_API_KEY)". Fix the comment at :773. Changing the queries instead would silently stop processing untagged rows.
    - `--quiet` help: "suppress the banner, progress dashboard and summary; errors still go to stderr". Drop "(for install.sh)". Align :14. Keep the option: invariant 11.
    - Epilog with `RawDescriptionHelpFormatter`: 1-3 Examples, such as `session-index-tag.py --project acme --dry-run` and `session-index-tag.py --regex-only --limit 50`; Notes: `ANTHROPIC_API_KEY` enables Haiku tagging; if unset or empty the tagger falls back to regex only and `--retag-summaries` exits 1; `--regex-only` ignores it; it is read from the environment only and never stored; `--dry-run` makes no API calls and writes no tags.
    - :10 uses `acme`, not the real `reso-management` (R102).
    - :480 `--regex-only flag` becomes `--regex-only option` (R060).
  - Test: `"--dry is rejected"`; `"help names ANTHROPIC_API_KEY"`; `"every tag help example parses"` (R100: `shlex.split`, then `parser.parse_args`); `"install.sh's argv still parses"`.
- **B18.6 SDK import runs before `--help`** (R379, R380; severity low. R012 is weak; see §5)
  - Sites: :254-261, :274, :485, with `parse_args` at :710. Importing the SDK alone took 636 ms, then 300 ms (measured by the verifier, two runs), over R380's 200 ms.
  - Change: not `find_spec`, which regresses the fallback. A broken SDK would set the flag true, line 210 would raise, and `except Exception` at :282 would turn every session into `api_error`. Delete :254-261 and add a memoized `_has_anthropic_sdk()` that really imports inside `try/except Exception`. Call it at :274 before the `try`, and at :485. Line 210 stays. A non-ImportError from the SDK now falls back to urllib instead of crashing at startup, and no caller depends on that crash.
  - Test: `"--help does not import anthropic"` (`sys.modules` check after a `--help` run); `"--regex-only does not import anthropic"`; `"a broken anthropic module falls back to urllib"`.
- **B18.7 `session-index-tag.sh` comment and recovery** (R047, R237, R275, R276, R361; severity low. R023 is mis-cited and R356 is README-only, so see U7)
  - Sites: scripts/session-index-tag.sh:3, :9-11, :15. install.sh:149 is the PATH name; U7 teaches it.
  - Change:
    - :3 says "All flags are forwarded; see session-index-tag.py --help", so the list can't drift again.
    - Missing script: check `git -C "$REPO_DIR" ls-files --error-unmatch scripts/session-index-tag.py`. If tracked: `Restore it:` / `    git -C <REPO_DIR> restore scripts/session-index-tag.py`. Otherwise `Clone a fresh copy:` / `    git clone https://github.com/renchris/claude-session-search.git`. Today's "run install.sh" is false: `symlink_file` only links, so a missing file gets a dangling link.
    - No python3: `Cannot start tagger: python3 not found`, `Install Python 3, then re-run:`, exit 1 (`spawn_failed`). `missing_command` doesn't apply to a hard-coded child.
    - `exec python3 "$PYTHON_SCRIPT" "$@"` stays, so argv and exit code pass through (R360, R362). Output goes through `css_fail`, so plain mode gets `Error:`. If cli-common.sh is itself missing, one plain `Error:` line with the same recovery.
    - Known limit: on macOS `/usr/bin/python3` can be an Xcode stub that satisfies `command -v`.
  - Tests (`tests/tag_wrapper.bats`): `"child exit code passes through"` (stub python3 exits 42, R400); `"argv with spaces passes through"`; `"missing script offers git restore"`; `"no git offers clone"`; `"no python3 exits 1 with a named failure"`.

### U19: `scripts/session-index-tag.py` run reporting (Round 2; after U18)
Also owns `tests/test_tag_runs.py`. Callers: as U18. Every change is scoped so that `--regex-only --limit 1000 --quiet` and all exit codes stay as they are.

- **B19.1 `--dry-run` does not preview the real run** (R325, R006, R017, R441; severity medium. R437 is a looser fit than R441)
  - Sites: :398, :482, :486, :517-524, :736-749, :758, :769, :870-881, :1065, :1069.
  - Change, all under `args.dry_run`, so non-dry-run stdout, stderr and exits stay byte-identical:
    - Banner: `Mode: Regex preview (no API calls)`. If a key is set and `--regex-only` is absent, add `A real run would use Haiku; tags, summaries and aliases will differ.` No "Haiku + Regex" line.
    - One uncoloured row per session on stdout, TTY or pipe: `<session_id>\t<comma-tags or ->\t<method>`, with banner and summary on stderr, so stdout is rows only. `--quiet --dry-run` stays silent. Today no lasting list exists in any mode: the TTY dashboard shows one throttled item and finalize erases it.
    - Summary: `Preview: N would be tagged, M no match; nothing written`, never `Done` or `tagged=`.
    - Wrap the lock block (:736-749) in `if not args.dry_run`, and guard PRAGMA WAL (:769) and `log()` (:1065). Keep `busy_timeout` (:770), which is connection-scoped. The exclusive lock is the most consequential residue: a dry run can make session-index-end.sh skip indexing today.
    - Keep the key check at :758 and its exit 1. Not the finding's "drop the key requirement": R325 says `--dry-run` still validates, and a real `--retag-summaries` without a key fails.
    - `--retag-summaries --dry-run` rows read `<session_id>\twould request summary via Haiku`.
  - Exit change: a dry run under lock contention goes from 1 to 0. No caller depends on it.
  - Tests: `"--dry-run with a key says regex preview and makes no API call"` (urllib patched to raise); `"piped --dry-run lists one row per session"`; `"--dry-run writes no log line and does not take the lock"` (hold the lock; status 0); `"--retag-summaries --dry-run with no key still exits 1"`; `"real run output is unchanged"`.
- **B19.2 API calls lack a total bound** (R313, R291, R296 narrowed, R316; severity medium by finding, low by verifier. R315 is dropped; see §5)
  - Sites: :178, :212, :224, :276-285, :385, :572, :620, :643-649, :863.
  - Change:
    - :212: `anthropic.Anthropic(api_key=api_key, timeout=30.0, max_retries=2)`. This keeps the SDK's own backoff and `Retry-After` handling (`_base_client.py:790`). Worst case today is estimated at about 6.9 h for the default `--limit` of 100, arithmetic from its 600 s and 2-retry defaults.
    - `TOTAL_API_BUDGET_S = 300`, `deadline = start_time + budget` in main, passed to `process_session`, checked at the top of the API branch. Past it, return `TagResult(sid, [], "", [], "skip", "deadline", False)`. Those rows keep `tagged_at` NULL for the next run. Don't route them to regex, which would mark them tagged for good.
    - urllib (:178): bounded retry for 429 and 529 only, at most 2, honouring `Retry-After` capped at 60 s, otherwise backoff with jitter, never past the deadline. `/v1/messages` persists nothing, so replay is safe apart from tokens; say so in a comment. Print `Retrying automatically…` once on stderr unless quiet.
    - One helper inside `haiku_tag` maps status to a reason: `api_rate_limited` for 429, `api_auth` for 401 and 403, otherwise `api_error`. `classify_failure` (:572) passes these through.
    - TagResult gains a slot for the fallback reason, counted in main even when regex succeeded, shown as a stderr note or summary row and added to the log line at :1066. Fix the dead branch at :385. C6 builds its exit codes on this slot.
    - Remove the semaphore and correct the comments at :863 and :620. `Semaphore(8)` with `max_workers=8` never blocks, so the finding's "hold the limiter around the call" is a no-op.
  - Tests: `test_sdk_client_is_bounded` (fake module records kwargs); `test_deadline_skips_without_tagging`; `test_urllib_retries_429_honouring_retry_after`; `test_urllib_does_not_retry_500`; `test_fallback_reason_is_counted`.
- **B19.3 A capped batch reads as Done with no next step** (R347, R004, R017, R149; severity medium)
  - Sites: :464, :529, :686, :848, :1055, docstring :9.
  - Change: exit 0 stays for a capped batch. The non-TTY `Done in ...: tagged=...` line stays byte-identical. All new text is additive and appears only when capped:
    - Hoist `where` and `params` from the branches at :770-830 and run a COUNT with them before `conn.close()`. Don't compute total minus tagged: failed rows never get `tagged_at`, and retag successes with no summary aren't written.
    - `capped = total_untagged > effective_count`. Banner: `{effective_count} of {total} queued` when capped.
    - After the summary, under `capped and not quiet`, on stderr: `Processed N of T untagged sessions. R still untagged (F failed, K not attempted).`, then the command alone on its line: `shlex.join(["python3", resolved_script, *project, *regex_only, *retag, "--limit", str(remaining)])`, dropping `--dry-run`. In dry-run say `Previewed`.
    - `--limit {remaining}`, not the original limit: selection is newest-first and permanent failures stay NULL, so repeating the same limit can stall once failures fill it.
    - :9 says "Tag up to --limit untagged sessions". README's 650-session example is U7's.
  - Tests: `"a capped run prints the remainder and an exact command"`; `"an uncapped run prints no rerun line"`; `"--quiet stays silent"`; `"the rerun command parses"` (R100).
- **B19.4 Styling and copy** (R115, R199, R206, R412, R191, R214, R227, R181; severity low. R204 is weak; see §5)
  - Sites: :40-51, :409, :417-418, :432-448, :506, :518, :527-556, :475-477.
  - Change, keeping flags, exits and streams:
    - `resolve_style()` in main after `parse_args` (module-level constants can't honour `--no-color`), passed to Dashboard, `print_mode_banner`, `print_summary_box` and the box helpers. Cursor codes go through it.
    - Colour and rich stay separate: rich needs a TTY and `TERM!=dumb` only, so `FORCE_COLOR` never starts cursor movement in a pipe and `NO_COLOR` doesn't remove the dashboard. Rich follows stdout until C7, then stderr.
    - Remove GRAY (:49): default foreground, or the DIM role for a muted border.
    - :418 shows the full ID, but fit the line to `shutil.get_terminal_size()` and shorten only tags with `…`. A plain swap grows it from 60 to 88 columns (estimated by arithmetic), wraps at 80 and breaks the fixed cursor-up at :432 and :444. When the ID alone doesn't fit, drop tags and the method label, not the ID.
    - Durations through `fmt_duration`, at :506 and the uncited :409.
    - Outcome per mode at :518 and :529, because `Tagged 80 sessions` would be false in two modes: dry-run per B19.1; `--retag-summaries`: `Added N summaries`; normal: `Tagged N of M sessions`, with no green when `failed>0`. Non-TTY: `Tagged N of M sessions in 4m 3s: tagged=.. failed=.. regex=.. haiku=.. summaries=+..`. The key=value tail and `Failures:` stay.
    - :527-556 and :475-477: gutter rows through one helper, label column 16, values at column 18 (R181).
  - Recorded conflict: progress-ui.sh:106-122, :149-173 and :267-306 use the same box for backfill and install output, and no written repo rule protects it. R181 stands, so changing only the tagger leaves it inconsistent with its siblings until a later pass; accept that, or extend B13.2 to the boxes.
  - Tests: `"NO_COLOR removes colour, not the dashboard"`; `"TERM=dumb has no cursor codes"`; `"--no-color works though constants load early"`; `"a long ID is never cut at 80 columns"`; `"dry-run never says Tagged"`; `"failures remove the green outcome"`; `"tests through the symlink"`, because install.sh:217 hides an ImportError from `cli_common`.
- **B19.5 Disclosure line before a send** (narrow part of "sends session text to the API"; R001; severity low; only if C12 picks option A)
  - Site: main after the `if not rows` exit (:838) and before :846, outside the `not args.quiet` block, guarded by `not effective_regex_only and not args.dry_run`.
  - Change, one stderr line: `Sending session summaries and first prompts to api.anthropic.com (Claude Haiku) because ANTHROPIC_API_KEY is set. Pass --regex-only to stay local.` Keep flags, defaults and key gate. No key characters.
  - Test: `"a key and --quiet still disclose on stderr"`; `"--regex-only and --dry-run don't"`.

### U20: `scripts/session-index-tag.py` global options (Round 2; after U19)
Also owns `tests/test_tag_global.py`.

- **B20.1 Missing global options and machine output** (R062, R086, R243; severity low. R073 applies only once C16 adds a layer; see §5)
  - Sites: :35-36, :42-51, :675, :727, :736, :846, :997, :1051.
  - Change, all additive, with behaviour without the new options byte-identical:
    - `-v/--version` as `store_true`, not `action='version'`, so `--help` wins and `--version --json` prints `{"version":...}`. Branch right after `parse_args`, before :714 and :736, so it needs no DB. It reads `cli_common.VERSION`.
    - `--no-color`, wired through B19.4.
    - `-d/--debug`: traceback through `run_cli`. `allow_abbrev=False` from B18.5 means `--d` can't turn ambiguous.
    - `--json`: set rich off and blank every style and cursor constant, including HIDE_CURSOR and SHOW_CURSOR, because :727 and :997 write SHOW_CURSOR to stdout unconditionally and would corrupt the document on a TTY. It implies `--quiet` for :846, :1051 and :831-838. One R248 bulk document: `{"results":[{"id":<session_id>,"outcome":"tagged"|"skipped"|"planned","error"?:<category>}],"summary":{"succeeded","failed","skipped","unknown"}}`. No rows means empty results and exit 0.
    - Pre-work failures at :715-719, :746-747 and :759-763: nothing on stdout, one JSON error line on stderr, exit 1 (R253). The write failure at :996-1000 comes after processing: write the partial result to stdout with no error document, and report it wasn't persisted (R318). `failed>0` exits 1 under `--json` only. The exit without `--json` is C6.
    - N/A under R062: `--cwd`, `--local-config`, `--scope`, `--token` (key comes from `ANTHROPIC_API_KEY`), and `--non-interactive` has no prompts to govern, so it is accepted and does nothing.
  - Tests: `"--version needs no DB and prints only the version"`; `"--help wins over --version"`; `"--json is one document on a TTY"` (`run_in_pty`, no cursor codes); `"--json with no rows is empty results, exit 0"`; `"--json pre-work failure is one stderr line"`.

### U21: Scope-wide contract tests and CI (Round 2; lands after U20, before U7)
Owns `tests/scripts_contract.bats`, `tests/contract_modes.bats`, `tests/test_transcripts.py` and `.github/workflows/ci.yml` (U2 owns ci.yml earlier, in A1). Each unit above carries tests for its own rows. This unit adds what crosses them.

- **B21.1 No audited CLI has contract tests** (R390, R391, R392, R397, R400, R100, R402; severity medium)
  - Sites: tests/smoke-test.sh:1, :52, :54; .github/workflows/ci.yml:19, :26. Measured: `grep` for the five script names across tests and both workflows finds nothing. Hermetic harness requirements are in U11a. Corrections to the finding: exit codes on success are already asserted at smoke-test.sh:16, so the gap is failure-path exits and separate streams; session-search.py already has smoke coverage, and the complete gap is the five scripts plus bin/claude-search and session-index-tag.sh.
  - Change: do not edit the existing smoke step. Add `bats tests/` (already from U2), plus these cases under `HOME=$(mktemp -d)`:
    - Old inputs, each invocation in the caller census (R402): `session-index-backfill.sh --quiet`, `--since 7 --quiet`, `session-index-chunk.py --backfill`, `--backfill --since 7`, `session-index-tag.py --regex-only --limit 1000 --quiet`, `session-search.py --context-inject <DIR>`, `--format=fzf q`, `--format=json q`, `claude-search '<nouns>' --deep-search`.
    - Round trip: install, then uninstall. Every link from install.sh:143-151 is gone, including the three install.sh:149-151 adds; the session-index hook entries are gone while the unrelated hook survives; launchctl's stub log shows a matched load and unload; `session-index.db` stays. Do not assert "removes everything": the DB is preserved by contract (invariant 14), and C19 decides the rest.
    - Symlink entry: run `$HOME/.claude/bin/session-index-backfill.sh --quiet` through the real link install creates. This is the path plist :11 takes.
    - Process (R400): a child's exit 42 passes through `session-index-tag.sh` and `bin/claude-search`; argv with spaces and metacharacters; a closed pipe (`| head -1`) on each command that prints; `TERM` and `INT` exit codes.
    - Partial failure: `settings.json` that fails patching exits 1 with bytes unchanged.
  - Decision C19 sets what the round trip pins for leftovers.
- **B21.2 Per-mode matrix** (R403, R404; named by critic2.json, no earlier plan row)
  - File: `tests/contract_modes.bats`. For one success and one failure of the engine search, wrapper `--fzf`, `install.sh --version`, `backfill --help` and `tag.py --dry-run`, in each mode: interactive TTY (`run_in_pty`), stdout redirected, stdin piped, `--json` on a TTY, `--non-interactive` on a TTY, `CI=1` with a TTY, `CLAUDECODE=1`. Assert whether a prompt appeared, what each stream holds, and the exit code.
  - Then R404 for the same commands: `NO_COLOR` and `FORCE_COLOR` cleared gives styled output on a TTY; `--no-color`, `TERM=dumb` and redirected output give none; stripping styling recovers the same text; JSON, identifiers and TSV stay unstyled with `FORCE_COLOR=1`. These replace, as the source of truth, the per-unit colour checks where they overlap.
  - `run_in_pty` merges streams, so stream separation is asserted only in the non-TTY modes.
- **B21.3 Transcripts at three widths** (R401, R407, R211, R191, R212; named by critic2.json)
  - File: `tests/test_transcripts.py`. Run table, preview, tagger summary and installer rows at `COLUMNS=40`, `80` and `120`, with long and Unicode values, rich and plain. Assert no ID or path is cut, no line overlaps, and stdout and stderr are checked separately. Exact columns are checked only at the shared layout helpers (R407). Goldens go in `tests/golden/`, reviewed by hand.
  - Known risk: R211's 40-column bar is unproven for the box-drawn stats and analytics views (not measured; the views use a fixed width of 52 at :1799). If it fails, the fix belongs with B5.1, not a test relaxation.
- **B21.4 CI wiring** (.github/workflows/ci.yml)
  - `tests/workflow-index-test.sh` and `apt-get install bats` are U2's. Add a matrix entry for `macos-latest`, so the BSD `date` and `stat` branches run in CI (estimated cost: one more job per push). `shellcheck` and `ruff` stay local gates, as they are today. Keep job id `smoke-test` (ci.yml:10) because README.md:7's badge points at the workflow.
  - Test: the PR's CI itself (G8).

---

## 4. Wave C: contract-changing fixes

### C1. `--json` envelope; deprecate `--format json`
- **Source:** the machine-output finding. Its verdict is **breaking**.
- **Rules:** R243, R248, R251, R253, R438.
- **NEEDS OPERATOR DECISION** before U3's B3.5.
- **Callers:**
  - bin/claude-search:106 (the wrapper's `--json` path; exits 2 today).
  - bin/claude-search:129 (Ctrl-O runs `jq '.project_path'` on `--format=json --preview`; broken today).
  - tests/smoke-test.sh:46 (checks exit code only).
  - README.md:117 and :354.
  - The engine docstring at bin/session-search.py:6-8.
  - Unknown outside users of the installed `~/.claude/bin/session-search.py --format=json`, which only that docstring documents.
- **Migration:**
  - `--json` emits `{"sessions":[...]}`, `{"session":{...}}`, `{"stats":{...}}` or `{"analytics":{...}}` from its first release (U3, U4).
  - `--format json` keeps the bare array byte-for-byte for at least one release. (Round 2: corrected, because this row contradicted U1b, which hides `--format` from help, and R050, R111, R308 and R385, which require a deprecated alias to be hidden and to warn.) The notice is one stderr line per run, reason `deprecated`: `--format json is deprecated. Use --json.` It also goes in the docstring and the README's "Behavior changes". Stdout is untouched (invariant 4). The in-repo callers all move in the same commits below, and the only `2>&1`-style capture in the repo is the wrapper's resume path, which doesn't use `--format`. So the warning reaches only unknown outside users, who need it (`grep -rn -- --format` measured).
  - In-repo callers move in the same commits: :106 via forwarding (U6); :129 to `--json --preview` with `.session.project_path` (U6); smoke-test.sh:46 (U3); README (U7).
  - Removing the `json` choice is a later unit, U10.
- **Why a decision is needed:**
  - Envelope versus bare array, and the exact field list, become a public contract.
  - The README publishes `--json` as "JSON output for scripting" in a public repo.
  - Recommendation: the envelope. `claude-search --json` has never produced output. The engine never defined `--json`; `git log -S'"--json"' -- bin/session-search.py` is empty (measured). So no consumer can depend on any shape yet.
  - If U3 shipped a bare array under `--json`, switching to the envelope later would be a real break.
  - The operator also needs to set the removal date for `--format json`.

### C2. Non-TTY output of the default search: TSV, full IDs, ISO times
- **Source:** the table-output finding. Its verdict is compatible; it is routed here because it changes the primary command's piped stdout.
- **Rules:** R189, R191, R213, R217, R188.
- **NEEDS OPERATOR DECISION.**
- **Callers:**
  - claude-infrastructure/hooks/lib/episodic_cue.sh:162: agents run `claude-search '<nouns>'` and read the piped table.
  - assets/demo/build.sh:21: a visual check, `| head -8`.
  - README.md:16-31: a TTY sample, unchanged.
- **Migration:**
  - In `format_table`, when stdout is not a TTY, print a header `rank\tsession_id\tcreated_at\tmessages\tproject\tbranch\ttags\tsummary`, then one row per result.
  - Rows use the full ID, ISO 8601 UTC times and exact counts. Tabs and newlines inside fields become spaces. No padding, truncation or boxes.
  - (Round 2) An empty result on a non-TTY prints the header line only (R195).
  - (Round 2: removed "an explicit `--format table` keeps the box table when piped". R189 requires TSV on any non-TTY stdout, and `--format` is hidden and not to be extended, R438.)
  - The TTY table is unchanged apart from B5.4.
- **Why a decision is needed:** it changes what agents in another repo read. Two options:
  - Recommended: TSV as the piped default. Agents then get full IDs that work with `--preview` and `claude --resume`.
  - Alternative (Round 2: corrected, because `--format tsv` would be a new `--format` spelling, and R438 makes `--json` the only format selector): keep the boxes when piped, record the R189 deviation under R422, and point scripts at `--json`. No new option.
- **Second question:** should the TTY table show the full 36-character ID? R191 says never truncate the only copy of an ID; today only `sid[:8]` is shown (:1484, :1695).
- **Owner:** U8.

### C3. `--resume N` resolution and cache semantics
- **Source:** findings "--resume N picks by rank" and "read path spawns backfills". Their fixes conflict.
- **Rules:** R043, R044, R005, R001.
- **NEEDS OPERATOR DECISION.**
- **The conflict:**
  - The first fix caches only output that shows rank numbers, stores `{query, filters, results}`, and reuses the cache when the query matches.
  - The second fix keeps caching every search, so `--resume N` follows the last fzf query.
- **Callers:**
  - README.md:62 and :145 ("the 2nd result of your last search").
  - The footer hint at session-search.py:1609, which becomes a Tip in U5.
  - The examples at bin/claude-search:7-8.
  - The wrapper's resume path.
- **Migration:**
  - Cache v2 is `{"version":2,"query":...,"filters":...,"created_at":...,"results":[...]}`. The loader still accepts the old bare list.
  - The cache is written only for table output and `--json`, which carry `rank`.
  - `--resume N "<q>"` uses the cache when query and filters match, and searches again otherwise.
  - README wording becomes "of your last search".
- **Recommendation:** the first semantics. fzf rows never show N, and every fzf keystroke reload overwrites the cache with a prefix query.
- **Owner:** U8.

### C4. Subcommand grammar
- **Source:** the "modes are flags" finding, subcommand part only. The rest of that finding is in U1b and U6.
- **Rules:** R024, R032.
- **NEEDS OPERATOR DECISION** (recommend deferring).
- **Callers:**
  - episodic_cue.sh:162 (`claude-search '<nouns>' --deep-search` must stay a search).
  - episodic-cue-outcome.py:83 and :105 (substring match).
  - hooks/session-index-start.sh:23 (an engine flag, unaffected).
  - README.md:62-66, :290, :310 and :345-357.
- **Migration:**
  - A registry in the wrapper only: `search`, `resume <SESSION>`, `inspect <SESSION>`, `stats`, `analytics [--fails]`, each mapped to existing engine flags. (Round 2: `<NUMBER|SESSION>` corrected, R434. `inspect` is also the way out of the `--preview` conflict in "Recorded conflicts".)
  - The old flags remain silent aliases.
  - The first word counts as a subcommand only on an exact match when the next word fits (a number or ID for `resume` and `inspect`).
  - A leading `search` or `--` forces a search.
- **Why a decision is needed:** queries are free text. `claude-search resume bug` or `claude-search stats regression` would stop searching.
- **Owner:** U9.

### C5. LLM expansion default in `--fzf`
- **Source:** the LLM finding, default part only. The mechanism (B5.5) is compatible and lands in U5.
- **Rules:** R379, R381.
- **NEEDS OPERATOR DECISION.**
- **Callers:** bin/claude-search:121 and :130 (fzf feed and reload), and README.md:37.
- **Migration:**
  - The wrapper adds `--no-llm` to the reload bind unless `SESSION_SEARCH_FZF_LLM=1`.
  - Optionally it keeps expansion for the single initial query.
  - README:37 is updated to match.
- **Why a decision is needed:** it trades recall on short prefixes for privacy and latency. Today every keystroke whose prefix has fewer than 3 hits can send the query to api.anthropic.com.
- **Owner:** U9, or U6 if decided first (about 3 lines).

### C1b (later). Remove `--format json`
- Callers by then: none in the repo. Unknown external users have had a deprecation window.
- **Owner:** U10, after the date the operator sets in C1.

### (Round 2) C6. Scripts report partial work and exit 1
- **Source:** findings "install.sh reports registered/Ready after failed or skipped steps", "uninstall.sh says Uninstall complete", "session-index-backfill.sh read failures become empty results", "session-index-chunk.py missing or skipped transcript reports success", "session-index-tag.py exits 0 and reports Tagged". All five verdicts are **breaking**, in the strict sense of R382 and R386: paths that exit 0 today would exit 1.
- **Rules:** R003, R017, R339, R318, R187, R141, R168, R275, R283, R138 (dropped for backfill, see §5).
- **NEEDS OPERATOR DECISION** on three questions below.
- **Callers:** no caller found parses these outputs. The one that matters is install.sh:214, bare under `set -euo pipefail`: a backfill exit 1 would abort the install before tagging, PATH and the scheduler, so U22's guard lands first. bin/session-search.py:249-272 respawns a backfill on every search while `last_backfill` is missing or older than 7 days. The repo is public, so unseen external scripts are possible, and that is why this is a decision. **Owner:** U22, U23, U24.
- **Migration, install.sh** (sites :132-133, :163, :204, :207, :217, :220, :222-223, :234, :240, :258, :265, :271, :280):
  - Add `PARTIAL=()`. Use the third argument of `inst_step_replace` (:62-68) for the fail glyph.
  - Symlinks: keep the no-overwrite at :132-133, and record each kept path. If `cmp -s` shows it matches the source, it is kept and not partial. If it differs, add to PARTIAL with `mv <path> <path>.bak && ./install.sh`. Report `N linked, M kept`.
  - Settings missing: fail glyph, PARTIAL, recovery from B14.6.
  - Tagging (:217): drop `2>/dev/null || true`, capture stderr, PARTIAL on failure. The tagger's lock-busy exit 1 (tag.py:747) is transient, so re-running is the recovery.
  - Counts (:222-223): `TOTAL=$(sqlite3 ...) || { TOTAL=unknown; PARTIAL+=(...); }`. A failed read never prints 0.
  - Scheduler: count a job as registered only if `launchctl list <label>` succeeds after the load. A missing plist is a tracked-file problem and goes in PARTIAL.
  - Summary (:280): title `Installed` only when PARTIAL is empty (B14.6), otherwise `Partial`. Print what applied, what did not and the recovery for each, then `exit 1`. Reference `"${PARTIAL[@]}"` only inside a `${#PARTIAL[@]} -gt 0` guard, because `set -u` on an empty array errors in bash 3.2.
  - `compileall` at :161 stays best-effort.
- **Migration, uninstall.sh** (sites :35-36 done in B15.2; :56, :67, :69-73, :88-89, :96-97, :105):
  - `FAILED` and `SKIPPED` lists. `remove_symlink` uses `rm "$path" || { record; return 0; }`. Non-symlink files go in SKIPPED, not FAILED. Keep every success line, so a clean run prints the same text plus B15.2's rows.
  - LaunchAgents: after unload check `launchctl list <label>`. If still loaded, keep the plist so a re-run can retry, and record a failure.
  - `Uninstall complete.` only when FAILED is empty. Otherwise `Uninstall incomplete:` with the items on stderr, exit 1.
  - PATH line: report, don't edit (C19).
- **Migration, backfill** (sites :115, :120, :128, :145, :228-235, :252, :331, :454, :466, :478, :539, :549, :636, :648, :650, :660-661, :667, :674):
  - `_bf_fail PHASE MSG` increments `_BF_FAILED` and appends file, phase and the first stderr line to `$SESSION_INDEX_LOG`. The terminal gets per-phase counts only, so output stays inside invariant 9. Do not stream raw child stderr: chunk.py has no top-level except before B17.2, and R283 applies.
  - Absent versus unreadable: test the jq rc at :115, :128, :145. Phase detail reads `N indexed, M unreadable`, and `no entries` only when M=0. A corrupt middle line of history.jsonl today silently drops every later entry (measured with jq 1.7.1 on sample input): `if ! pipeline; then _bf_fail`, keep the rows read, and say later rows were not read.
  - Reads at :252, :454, :478, :539, :549 count a failed read as a failure and skip the item. They never mean "not indexed" or "no gaps".
  - :466 and :495 get a `phase4_empty` counter shown as skipped. Add a `[ -r "$transcript" ]` preflight counted as failed. Leave :584 and :593 alone, because they are already counted and "6708 no transcript" in the log would make every run exit 1.
  - One EXIT handler, chained with B16.3's, prints the failed phase, says a re-run is safe and gives the log path, then exits 1. That normalizes sqlite's rc=5 (R337). It only normalizes failure, never turns success into failure (R342).
  - Write `last_backfill` before the banner on any run that reached the end, including partial ones, so session-search.py doesn't respawn. Not on an abort, as today. Title `Backfill Complete` with exit 0 when `_BF_FAILED=0`; otherwise `Backfill Partial`, a `Failed  N (see log)` row and exit 1.
- **Migration, chunk.py** (:183-187, :278-280): single-session branch of `main()` only. `chunk_session` keeps returning 0, because backfill branches on `n > 0` at :215-218 and :235-238.
  - Named constant `MAX_TRANSCRIPT_BYTES = 52428800`.
  - Missing path, checked before connect: `Couldn't find transcript <path>. Check the path and retry.` stderr, exit 1 (Reference J Not found).
  - Oversize: `Skipped session <id>: transcript is <size>, over the 52.4 MB limit. No chunks written.`, exit 1.
  - Too short: `No chunks written for <id>: <t> turns, minimum is 5.` on stdout, exit 0. Don't say the session has no chunks: `store_chunks` returns early at :147 and older chunks stay.
  - `Generated <n> chunks for <id>` stays byte-identical when n > 0. `--backfill` keeps exit 0 and its filtering (invariant 10); R318's report there is C17.
- **Migration, tag.py** (:278-285, :658-664, :972, :1023-1025, :1043, :1050, :1075):
  - `failed > 0` must not drive the exit code. `failed` includes `no_match` and `empty_text`, which recur on every run (query at :820-828), so a run with one unmatchable session would exit 1 forever.
  - Auth: on the first `api_auth` (from B19.2) set a `threading.Event`. `process_session` checks it before calling the API and does not fall back to regex for those rows, so they keep `tagged_at` NULL and stay queued. `shutdown(cancel_futures=True)`. On stderr, even under `--quiet`: `ANTHROPIC_API_KEY was rejected by the Anthropic API (HTTP 401): N sessions not tagged. Set a valid key, or pass --regex-only to tag without the API.` 403 names the permission. Rows finished before the abort are still written. Exit 1.
  - Other API failures: `Anthropic API unavailable for N of M sessions; used regex tags.` on stderr, even under `--quiet` (R141).
  - `--retag-summaries`: a result with no summary isn't written (:972), so count it as `unchanged`, not `tagged`, and leave it out of `updated_sids`.
  - FTS failure (:1023): tags stay committed, stderr warning `Search index not updated: <err>. Tags are saved; run session-index-backfill.sh to rebuild.`, exit 1 at the end.
  - Exit map at the end of main: exit 1 for auth abort or FTS failure, and on API fallback per question (c). `no_match` and `empty_text` alone stay exit 0 as counts. A no-key run stays exit 0 (README.md:320). `--dry-run` stays exit 0.
  - Append `unchanged=` and `api_fallback=` to the `Done in` keys, in order. Keep the `Tagging complete:` log prefix. Add exit codes to the docstring.
- **Questions:**
  - (a) Accept exit 1 on partial at all? Recommended yes. The contract is formally breaking and no known caller is affected.
  - (b) Non-macOS scheduler skip: exit 0 with a named skip, or non-zero? R003 could read it as partial. Recommended exit 0, because README.md:88 labels it macOS-only and :273 already does this. Non-zero would fail every Linux install.
  - (c) API failure that fell back to regex: Option A exit 1, because R003 and R318 treat it as partial and those rows get `tagged_at`, so the normal queue never retries them with Haiku. Option B exit 0 with the warning, because tag.py:5-6 documents the fallback and a run with regex tags did complete. Recommended A. Separately optional: leave `tagged_at` NULL on fallback rows so they retry, which changes what later runs process.
  - (d) A kept file that differs from the source makes every re-run exit 1 until resolved. Correct under R318, and no repo rule says otherwise, but it is visible to a user who customized a hook by hand. Recommended yes.
- **Tests** (`tests/install_contract.bats`, `tests/backfill_contract.bats`, `tests/test_chunk_contract.py`, `tests/test_tag_contract.py`):
  - `"a failed launchctl load is not reported as registered"`.
  - `"a differing kept file exits 1 and names the mv recovery"`.
  - `"success keeps its exit 0 and step labels"`.
  - `"uninstall names what stayed and exits 1"`; `"jq failure on a prompt-type hook is not reported as removed"`.
  - `"corrupt sessions-index.json counts as unreadable, not no entries"`; `"corrupt history.jsonl line is reported and later rows are not claimed"`; `"partial run writes last_backfill and exits 1"`.
  - `test_missing_transcript_exits_1`; `test_too_short_exits_0_and_keeps_old_chunks`; `test_backfill_keeps_exit_0_for_skips`.
  - `test_bad_key_stops_early_and_leaves_rows_queued`; `test_api_fallback_warns_even_when_quiet`; `test_no_match_alone_exits_0`; `test_fts_failure_warns_and_exits_1`; `test_install_argv_exit_stays_ignored`.

### (Round 2) C7. Human output moves to stderr
- **Source:** findings "install.sh progress and receipts go to stdout", "uninstall.sh all status on stdout", "session-index-backfill.sh progress, receipts and child output on stdout", "session-index-chunk.py receipts on stdout", "session-index-tag.py banner, dashboard, summary and cursor control on stdout". All **breaking** under R382 and R386 (a stream change). Zero known callers break.
- **Rules:** R016, R177, R173, R195, R240, R241, R236, R182, R186, R205, R217, R307. R241's guidance clause and R173 fit weakly on the installer.
- **NEEDS OPERATOR DECISION.**
- **Callers:** none captures stdout (`grep`, per finding). Merged logs: repo plist :11 and the infra plist both merge streams, so their logs don't change. install.sh:217 discards stderr, which `--quiet` already silences. bin/session-search.py:269-270 uses DEVNULL. An outside `./install.sh > file` would lose its content, so release notes must name the move (R386, R022). The repo has no tags, so "major version" has no direct mechanism here (measured: `git tag`). **Owner:** U22, U23, U24.
- **Migration, install.sh:** `exec 1>&2` before `source` at :26, leaving no human stream on fd 1. `[ -t 1 ]` then tests stderr and every site moves together, so B13.1's separate stderr colour set can collapse here. Command substitutions keep their own stdout. At :214, on a TTY only, send the child to a `mktemp` log and show it only on failure, because a child's lines land inside the installer's cursor-relative redraw (:118-121) and backfill:665 re-shows the cursor. Off a TTY the child keeps streaming, so `./install.sh 2>&1 | tee` logs stay useful. Replace the offers block (:302-319): gate on `css_guidance_on`, delete the non-TTY branch at :311-317, use one `Next steps:` heading with the benefit before the command (R236). README.md:94-101 stays the non-interactive documentation of optional deps.
- **Migration, uninstall.sh:** all status to stderr, stdout empty. Rich only when `css_rich 2`. Plain: `Removed <path>` and `Warning: <path> is not a symlink, so it was left in place. Remove it manually if you no longer want it: rm <path>`. Retire `⚠` and the `- <path>` dash for `<path> not found`. Item rows take a blank gutter, one `✓ Uninstalled claude-session-search` at :105 (R182). Don't source progress-ui.sh for this: it tests `[ -t 1 ]` and installs an EXIT trap.
- **Migration, backfill:** `exec 3>&1 1>&2` before :13, so the library's `-t 1` tests stderr and every `ui_*` call moves. Do not edit the library's write targets: `install.sh | tee log` would then get raw cursor codes (finding's fix rejected). On exit 0, `printf '%s\n' "$SESSION_INDEX_DB" >&3` is the closest capturable result (R173, R176). install.sh:214 adds `>/dev/null`. session-search.py is unaffected. Plist logs gain one harmless line.
- **Migration, chunk.py:** :240 and :280 go to stderr with correct plurals and comma grouping, e.g. `Chunked 1 session -> 1,204 chunks` (R217). `backfill()` returns `(sessions, chunks)`; its only caller ignores the value. Single-session: the bare session ID on stdout when `not sys.stdout.isatty()` (R173). Backfill mode: stdout empty. Backfill's `2>/dev/null` then discards the receipt, so backfill.sh needs no edit for this; C17 may change that redirect.
- **Migration, tag.py:** `IS_TTY = sys.stderr.isatty()` at :40. Banner, summary, `Nothing to tag`, dashboard and cursor writes at :474-490, :517-557, :834, :836, :432-449, :727-728, :855-856, :997-998 and :1032-1033 go to stderr. Keep `--quiet` gating and exits. Not :275 and :277, which the finding cited but which print nothing.
- **Question: does a mutation with no single identifier print anything?**
  - tag.py Option A (recommended): stdout empty, plus the log line and optional `--json`. Option B: keep the single key=value `Done in ...` line on non-TTY stdout, which preserves any outside `> log` user, makes the contract compatible, and keeps a receipt on stdout, which R177 forbids.
  - install.sh and uninstall.sh have no identity: stdout stays empty, recorded as a known R173 deviation.
- **Tests:** `"install stdout is empty and stderr holds the steps"`; `"exit codes are unchanged after the move"`; `"non-interactive runs print no offers"`; `"a TTY backfill failure shows the child log"`; `"uninstall stdout is empty"`; `"uninstall plain mode uses words"`; `"backfill stdout is only the DB path, on exit 0 only"` (R176); `"phase rows go to stderr"`; `test_chunk_plural_and_streams`; `test_tag_stdout_empty_in_every_mode`; `test_tag_nothing_to_tag_is_on_stderr`.

### (Round 2) C8. Exit-code corrections on invalid input and on Ctrl+C
- **Source:** findings "session-index-chunk.py bare invocation writes to the DB before showing usage", "conflicting or meaningless inputs are ignored", "session-index-tag.py conflicting and invalid options are not usage errors", "session-index-tag.py Ctrl+C exits 1". All **breaking** under R386 (exit code).
- **Rules:** R015, R064, R302, R337, R070, R069, R074, R304, R344, R335, R416, R007.
- **NEEDS OPERATOR DECISION** on the sub-questions. **Owner:** U23 (chunk), U24 (tag).
- **Callers:** backfill passes only `--backfill` and valid `--since` to chunk.py. install.sh:217 passes valid tag.py options, with `|| true`. The wrapper tag.sh forwards. No caller branches on 1 versus 2 or 130. Exposure: a person typing `session-index-backfill.sh --since 0` is already refused by B12.3, so nothing forwards a bad value.
- **Migration, chunk.py:** validate right after `parse_args`, before :252, so nothing durable changes first (a DB with no chunks schema gets DDL at :261 today):
  - `if not args.backfill and not (args.session_id and transcript): parser.error("expected <session> and --transcript <FILE>, or --backfill")`. Lines 281-283 go. Exit 2, usage on stderr.
  - `--since` below 1: `parser.error`. Change :200's truthiness to `is not None`. This reverses B17.4's temporary `0` behaviour, and help says `--since` takes 1 or more, omitted meaning all history.
  - `--since` without `--backfill`, and `--backfill` with positionals: `parser.error`.
  - Follow-up, not in this decision: `SID PATH --backfill` and `SID PATH --since N` run today; they are covered by the checks above and named in the release note.
- **Migration, tag.py invalid options:** right after `parse_args` (:710), before :714:
  - `if args.retag_summaries and args.regex_only: parser.error("Can't use --retag-summaries with --regex-only.")`; `if args.limit < 1: parser.error("--limit must be at least 1.")`. No cap: install.sh:217's `--limit 1000` must keep working.
  - The key check moves up too, narrowed to `args.retag_summaries and not key`, on stderr, not `parser.error`. Keep :753's fallback: a keyless run without `--retag-summaries` is the documented README path. Lines 756-763 go.
- **Migration, tag.py signals** (:723-732, :855, :916, :966, :997, :1032, :1037-1038):
  - Handlers for SIGINT, SIGTERM and SIGHUP (guard with `hasattr`). First signal records signum and raises a private `_Interrupted(BaseException)`. A flag alone won't work, because `as_completed` stays blocked until the next completion. Second signal writes SHOW_CURSOR and calls `os._exit(128+signum)`; `sys.exit` still joins non-daemon workers.
  - Replace `with ThreadPoolExecutor` at :916 by explicit try, except, finally, because `with` calls `shutdown(wait=True)`. On interrupt, `shutdown(wait=False, cancel_futures=True)`, then harvest every done, not cancelled, not consumed future. Results of up to 8 in-flight calls are dropped.
  - Move the write block (about :945-1025) into a helper, called from the normal, Haiku-interrupt and regex-interrupt paths (R420). Writes happen only after the loop today, so completed, billed results are discarded. Optionally flush every N results, so a crash also keeps work. Keep `summaries_added` correct per flush.
  - `Interrupted: N of M saved; rerun to tag the rest` on stderr, guarded against OSError on a hung-up terminal. Exit 130, 143 or 129 as a normal exit, not by re-killing self, so install.sh:217 keeps going. After persisting, `os._exit(code)` following a flush.
  - try/finally around :855 to :1032 restores SHOW_CURSOR and all three handlers.
- **Questions:**
  - (a) Change these exit codes at all? Option A (recommended): yes, and note them in the release notes. R337 and R260 are clear and no caller is affected. Option B: move validation ahead of side effects but keep exit 1 and help output, accepting the R337 miss.
  - (b) A missing `ANTHROPIC_API_KEY` under `--retag-summaries`: Option A exit 1 (recommended), because Reference J's Authentication class is 1 and R260 says "auth exits 1". Option B exit 2, as the finding proposes, treating the variable as missing input.
- **Tests:** `test_bare_chunk_exits_2_with_empty_stdout`; `test_bare_chunk_leaves_a_schema_less_db_untouched`; `test_since_zero_and_negative_exit_2`; `test_since_without_backfill_exits_2`; `test_backfill_with_positionals_exits_2`; `test_conflict_exits_2_before_the_lock_file_is_created`; `test_limit_below_one_exits_2`; `test_keyless_run_still_falls_back`; `test_first_sigint_keeps_finished_results_and_exits_130`; `test_second_sigint_exits_immediately`; `test_term_exits_143_and_hup_129`; `test_cursor_restored_on_exception`.

### (Round 2) C9. Installer consent for targets owned elsewhere
- **Source:** finding "install.sh replaces foreign symlinks and guesses the shell rc with no preview". Verdict **breaking**: a non-TTY run with a foreign target goes from exit 0 to exit 2, and a bash login user with a .zshrc now gets .bashrc.
- **Rules:** R001, R002, R005, R146, R350, R124, R147, R149, R153, R325 (constrains `--dry-run`, not violated), R338. R354 does not apply, because this is a setup command.
- **NEEDS OPERATOR DECISION.**
- **Sites:** install.sh:13-14, :127-131, :146, :153, :235, :239-240, :256-258, :263-265.
- **Measured live impact:** 4 of the 9 link destinations on this machine point at claude-infrastructure (`ls -ld`). Its helpers copy is 1486 lines against this repo's 608 (`wc -l`). Both installed plists differ from `config/` (`diff -q`), and the live sweep plist carries `SESSION_INDEX_SWEEP_MIN_INTERVAL_S=300`, which a re-run would drop. So re-running `./install.sh` here silently retargets live hooks.
- **Callers:** no script runs it. Invariant 12 keeps bare runs non-interactive on a fresh machine or one whose links are already this repo's. **Owner:** U22.
- **Migration:** a preflight before :106 classifies every target and mutates nothing. The finding's `--force` is corrected to `--yes`, because R146 and R153 require `--yes` for taking from another owner.
  - Parse `--dry-run`, `-y/--yes`, `--shell-rc <FILE>`. `--dry-run` has no short form (R465).
  - Plan on stderr: each link destination, settings.json, the rc file, both plists. No prompt for an ordinary install (R158).
  - Link classes, comparing canonical paths (`cd dirname && pwd -P`), not the raw string at :130: absent, create. This repo, no-op. Dangling, replace without consent and show a `Replaced` row, which keeps a moved clone re-linking. Live target outside this repo, foreign, needs consent. Regular file, keep with a `Skipped` row.
  - Plist classes: identical (`cmp`), skip including unload and load. Bytes match any committed version of that config file (`git log` plus `git show`), this repo's older copy, replace with `Replaced`, which keeps the update flow. Anything else, foreign.
  - Consent: on a TTY through `css_interactive`, preview each foreign target and its current destination on its own line, then `Replace N links and plists owned elsewhere? (y/N)`. Declining mutates nothing and exits 130 (R338; the finding did not state this). Non-interactive without `--yes`: exit 2, reason `confirmation_required`, before any mutation, printing the exact `./install.sh --yes`. `--yes` never picks among ambiguous targets (R151).
  - rc file: `--shell-rc`, else `basename $SHELL`: zsh gives `${ZDOTDIR:-$HOME}/.zshrc`, bash gives `~/.bashrc`. Any other shell or a missing file: don't edit or create, print the exact PATH line. Keep the `.claude/bin` grep idempotence.
  - `--dry-run`: plan and exit 0, no prompt, gating :141, :143-151, :153, :161, :172-189, :214, :217, :220, :235-237, :256-258, :263-265.
  - Limit `chmod` at :153 to links resolving into this repo, because chmod follows symlinks into foreign files.
  - Add `Replaced` and `Skipped` receipt rows. README.md:79 and install.sh:4 describe the gate.
- **Question:** take the gate now, or ship only the additive `--dry-run` and `--shell-rc` and print a warning for foreign targets? The additive path has no break but leaves the silent retarget measured above. Recommended: the gate. This also interacts with C18, because a machine managed by claude-infrastructure keeps its own copies.
- **Adjacent, not in this decision:** uninstall.sh:17-18 also removes foreign symlinks unconditionally. Flagged, so the same classes should reach `remove_symlink` if the gate is approved.
- **Tests:** `"fresh install stays non-interactive and exit 0"`; `"rerun with own links makes no prompt"`; `"a foreign link without --yes on a non-TTY exits 2 and changes nothing"`; `"--yes replaces and shows a Replaced row"`; `"declining exits 130 and changes nothing"` (`run_in_pty`); `"a dangling link re-links without consent"`; `"an older committed plist updates without consent"`; `"--dry-run changes nothing"` (`assert_tree_unchanged`); `"--shell-rc wins and other shells print the line"`; `"chmod skips foreign targets"`; `"every install help example parses"` extended to the new options (R100).

### (Round 2) C10. Lock primitive and fail-on-timeout
- **Source:** finding "lock does not exclude the tagger on this machine and proceeds after timeout" (verdict **breaking**), plus the decision left open in "bypasses the busy-timeout wrapper".
- **Rules:** R329, R330, R332, R019. R368 and R319 fit weakly: SQLite serializes these writes, and the harm is SQLITE_BUSY, not lost data.
- **NEEDS OPERATOR DECISION.**
- **Evidence:** `flock` is absent here (`which`, measured), so helpers:69 uses `mkdir session-index.lock.d` while tag.py:742 uses `fcntl.flock` on `session-index.lock`, and neither sees the other. The log holds 75 `proceeding anyway` lines (measured: `grep -c`), all from backfill, because :52 is the only caller of `session_index_lock`.
- **Callers:** install.sh:214 is the only caller affected: an exit 1 on timeout would abort the install under `set -e`. bin/session-search.py:268 ignores the code. The plists log it. `session_index_trylock` callers exit 0 on failure. install.sh:217 discards tag.py's exit. Message strings have no parser.
- **Correction to the finding (read from claude-infrastructure/hooks/lib/session-index-helpers.sh:124-190):** a live machine's hooks source that copy, not this repo's. It takes `flock` first, falls back to `mkdir` with owner-verified stale reclaim, and refuses on timeout (`NOT proceeding`). Moving only this repo's backfill to `flock(2)` would fix backfill against the tagger and lose backfill against the hooks. So this repo can't switch primitives alone.
- **Migration** (hooks/lib/session-index-helpers.sh:65-100, backfill:50-52, tag.py:746):
  - Acquire `flock(2)` on fd 9: `flock -n`/`flock -w N` when `command -v flock`, otherwise `python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX|fcntl.LOCK_NB)'` looped to a deadline. The kernel releases it on process death, and the probe shows it persists after the helper exits (measured by the verifier). tag.py:742 is already this.
  - While the sibling copy still uses `.lock.d`, also hold `.lock.d`, porting its stale reclaim, and release both in `session_index_unlock`. Do fail-on-timeout only after this: on the bare mkdir lock a SIGKILLed holder would wedge backfill for good.
  - `session_index_lock` takes a timeout, default 300 s (today's value), and bounds the `flock` path, which today blocks with no limit at helpers:69. Timeout: keep the log line, reworded; stderr `Can't acquire the session index lock: another backfill, tagger or sweep held it for 5m. Retry, or raise --timeout.`; return 1, so backfill exits 1, matching tag.py and R332.
  - Backfill gains `--timeout <DURATION>`, default `5m`. One waiting line on stderr once past the usual duration, only when not `--quiet` (R329).
  - Measure the extra python3 start in `session_index_trylock` against session-index-end.sh's 200 ms target (end.sh:4) before landing. A perl helper is the fallback.
- **Questions:**
  - (a) Fail on timeout, or keep "proceeding anyway"? Option 1 keeps installs from aborting but keeps concurrent backfills. Option 2 ports the sibling's refusal. Recommended 2.
  - (b) install.sh:214: continue with a visible warning, which also stops real backfill failures aborting the installer because exit 1 can't separate them, or keep aborting and rely on an idempotent re-run? Recommended continue (U22's guard, same as C6).
  - (c) Land the dual-primitive lock here alone, or port to claude-infrastructure at the same time? Recommended here first: it is safe on its own, and that repo needs its own change.
- **Tests:** `"tagger and backfill exclude each other without flock on PATH"`; `"a killed holder does not wedge the next run"`; `"timeout exits 1 with the named message"`; `"--timeout 1s is honoured"`; `"a held .lock.d still blocks backfill"`; `"hooks skip while the lock is held"`. The B4.6 test's `flock` branch is updated to match.
- **Owner:** U23.

### (Round 2) C11. `session-index-tag.py --project` selects write targets by substring
- **Source:** the "Needs decision" finding. Verdict **breaking**, for human invocations only.
- **Rules:** R043, R470, R071, R013, R194. R008 supports the choice below but is not violated. R009 does not apply, because there's no synonym pair.
- **NEEDS OPERATOR DECISION.**
- **Sites:** tag.py:693, :774, :780-783, :794-798, :805, :810-816, :466. (:224, :239 and :254 cited by the finding are unrelated.) bin/session-search.py:551 is read-only.
- **Measured:** `--project reso` matches 35 distinct names and 1069 rows, against 52 rows for exact `reso`. Exact `reso-management` matches 0 rows and `%reso-management%` matches 852 under `reso-management-app` (`sqlite3` immutable read). So the docstring's only example would match nothing under exact semantics.
- **Callers:** no caller passes `--project` to the tagger. Read-side callers depend on substring: README.md:115, bin/session-search.py:10, bin/claude-search:43, :153, :160. **Owner:** U24.
- **Options:**
  - (A) Make tag.py exact (R043). The same option name then differs from `claude-search --project` (R008), and the documented example breaks.
  - (B, recommended) Keep substring and resolve to exact names before writing:
    - Escape LIKE metacharacters with `ESCAPE '\'` here, and at bin/session-search.py:551, :625 and :852, so both tools agree (owned by U8).
    - Empty or whitespace value: `parser.error`. Today `--project "$UNSET"` silently widens to all rows (13070 measured).
    - `SELECT DISTINCT project_name ... LIKE`, with no tag predicate. 0 names: `No project matches <value>`, exit 1 (a matching project with nothing to do keeps `Nothing to tag.`, exit 0). 1 name: proceed. More than 1: list them with row counts on stderr and exit 2 without writing or calling the API, unless `--all` accepts the whole set or `--exact` restricts to equality. `--dry-run` lists and continues.
    - `--all`, not the verifier's `--all-matching`: R446 names `--all` for this concept and bans variants. `--all` and `--exact` conflict (R070). `-a` is not added (R468 doesn't force it here, but the command writes).
    - Row queries (:780, :783, :797-798, :810, :813, :815-816) use `project_name IN (...)`, so rows written are exactly the names shown. The banner names resolved projects, including in dry-run.
    - Help at :693 and the docstring state substring, literal `%`/`_`, and the single-name rule.
- **Why a decision is needed:** a multi-match run that writes today would refuse, a typo that exits 0 would exit 1, and writes spend API money.
- **Tests:** `test_multi_match_refuses_and_lists_names`; `test_all_accepts_the_listed_set`; `test_exact_selects_one`; `test_no_match_exits_1`; `test_percent_is_literal`; `test_empty_project_is_a_usage_error`; `test_rows_written_match_names_shown`; `test_runs_without_project_are_unchanged`.

### (Round 2) C12. Does a key alone send session text to the API?
- **Source:** the "Needs decision" finding. Verdict compatible. The finding's R005, R010 and R160 don't hold (§5); the real gap is R001: the disclosure banner is on stdout and `--quiet` skips it.
- **NEEDS OPERATOR DECISION.**
- **Sites:** tag.py:155-157, :178, :224, :482-486, :753-754, :846; README.md:37, :280. :194-195 cited by the finding are response parsing.
- **Callers:** install.sh:217 passes `--regex-only`, so it never sends. Only a person running the tagger by hand with a key reaches this path.
- **Options:**
  - (A, recommended) Keep the documented key gate and add B19.5's stderr line, which also covers `--quiet`.
  - (B) Require an explicit `--haiku`, so a key alone means regex-only. This changes the default README.md:280 documents and needs a deprecation path. No caller or rule requires it.
- **Note:** bin/session-search.py:673 has the same key gate for query expansion (README.md:223). B5.5 and C5 own that one. If the policy changes, both must move.
- **Owner:** U19 for A, U24 for B.

### (Round 2) C13. Not used
The Ctrl+C decision for the tagger was first listed separately and is now part of C8.

### (Round 2) C14. What `--quiet` means on backfill
- **Source:** the finding "`--quiet` is accepted but does nothing". Verdict compatible, but three other verdicts contradict its fix: the install.sh streams finding, the backfill streams finding and the stale description finding each say not to wire `--quiet` in, because that empties the scheduled log.
- **Rules:** R437 (loose fit), R023, R016.
- **NEEDS OPERATOR DECISION.**
- **Sites:** backfill:15, :21 (assigned, never read: `grep -n QUIET`), install.sh:214, config plist:11, bin/session-search.py:268.
- **Callers:** all three pass `--quiet`. bin/session-search.py sends everything to DEVNULL. Others see output by accident. Line 240's chunk print also reaches the installer's redraw, and scripts/session-index-tag.py:701-704 implements `--quiet` for real, so the intent is clear.
- **Options:**
  - (A, recommended) Honour it. After parsing: `exec 3>&1; if $QUIET; then exec 1>/dev/null; else exec 1>&2; fi` (with C7), or `exec >/dev/null` alone without C7. `$(...)` captures keep working, so state and exit codes don't change, and cursor codes go to /dev/null too. B16.6's ERR trap keeps errors. Do not put the check in progress-ui.sh, because install.sh shares it. Recorded effects: `backfill-scheduled.log` holds only errors and `verdict=` lines (a success record remains in `session-index.log` and meta `last_backfill`), and install.sh's Indexing step shows one static line.
  - (B) Keep it a documented no-op. Nothing changes, and help keeps saying so (B12.2).
- **Test (for A):** `"--quiet prints nothing on success and keeps rc"`; `"--quiet still reports a failure on stderr"`; `"install's redraw is clean"`.
- **Owner:** U23.

### (Round 2) C15. One version source
- **Source:** findings on install.sh, uninstall.sh, backfill, chunk and tag global options, plus U1a's literal.
- **Rules:** R086, R295 (Version row).
- **NEEDS OPERATOR DECISION** before U11a and U11b. Measured: `git tag` is empty, and there is no VERSION, pyproject or `__version__`.
- **Options:**
  - (A, recommended, assumed by rows above) A tracked `VERSION` file read by the scripts, plus U1a's literal in the engine, kept equal by `test_version_file_matches_engine`. Stable, and it works from any checkout, but it is one more thing to bump.
  - (B) `git -C "$REPO_DIR" describe --tags --always`. No new file, but prints `unknown` outside a checkout, which is every copy-based deploy.
- The operator also picks the first number. `0.1.0` is a placeholder.

### (Round 2) C16. Config-dir override
- **Source:** Part 2 of the global-options findings on install.sh, uninstall.sh, backfill, chunk and tag (R062, R073, R079). Each verdict rejected an install.sh-only or helpers-only version, because it splits the index: backfill would write one DB while install.sh:220-223 reads another, settings would still point at `~/.claude` hooks (:180, :187), and a set variable would make search read `~/.claude` while its background refresh (session-search.py:268) writes elsewhere.
- **NEEDS OPERATOR DECISION** (recommend deferring).
- **Sites, all or none:** install.sh:8, :180, :187, :232, :234; helpers:6-9, :62; bin/session-search.py:38-39, :1633; tag.py:35-36, :736; chunk.py:18-19; bin/claude-search:15; uninstall.sh:6-8; config/*.plist:11. The plists have one fixed launchd label each, so a second install would overwrite the first's jobs. uninstall.sh:84-101 acts on `~/Library/LaunchAgents` regardless, so uninstalling with another dir would delete the default install's agents unless it skips and reports them.
- **Options:**
  - (A, recommended) Explicit `-Q, --global-config <DIR>` plus `SESSION_SEARCH_CONFIG_DIR`, in the order option, env, `~/.claude`, with an invalid explicit value failing (R074). A bare `./install.sh` still targets `~/.claude`.
  - (B) Read `CLAUDE_CONFIG_DIR` as the env layer. This changes the no-arg target in any shell that exports it. It is set in this session (measured: `env`), and hooks inherit it from Claude Code, so a re-run would silently move the index. Breaking, and needs a README note.
  - (C) Record R062's config-dir item as a known deviation under R422 and do nothing. Reasonable, because no caller needs it.
- **Owner:** U25.

### (Round 2) C17. Does backfill surface a partial chunk run?
- **Source:** the verdict on "no top-level handling, and per-item failures abort the batch".
- **NEEDS OPERATOR DECISION.**
- **Options:**
  - (A) Leave backfill:648 and :650 as they are. Fully compatible, but one permanently unreadable transcript keeps aborting backfill and install at Phase 7 with no visible reason, as today. `last_backfill` stays unwritten, so search keeps respawning backfills.
  - (B, recommended with C6) Capture rc and stderr at :648 and :650, send stderr to the log, show the partial in `ui_phase_done`, and continue to the `last_backfill` write. This satisfies R003 and R318 end to end, and marks the index fresh despite failed sessions.
- **Owner:** U23.

### (Round 2) C18. Two plists for one launchd label
- **Source:** finding "the PATH-installed entry cannot start", needs-decision line. `cmp` shows the two differ at line 11 (measured).
- **Callers:** install.sh:257 copies this repo's plist over the installed one. claude-infrastructure migration 0025 `--verify` uses `cmp` between the installed copy and that repo's (migrations/0025-session-search-backfill-path.sh:44), and that repo's tests/session-search-backfill-launchd-path.bats extracts its command from its own copy. Re-running this repo's install.sh today fails that verification and restores the broken form.
- **NEEDS OPERATOR DECISION.**
- **Options:**
  - (A, recommended, assumed by B12.4) Keep them byte-identical by porting the infra form here. Smallest change.
  - (B) One repo is the sole owner and the other's installer stops copying it. Cleaner long term, and it needs a change in the sibling repo.
- **Owner:** U12.

### (Round 2) C19. What uninstall leaves behind
- **Source:** the scope-wide test finding's question, and the finding "says Uninstall complete".
- **NEEDS OPERATOR DECISION.** No documented repo rule decides. The DB stays either way (invariant 14).
- **Items:** the PATH line from install.sh:235-237, `settings.json.bak` and the new unique backups, `~/.claude/logs/`, `~/.claude/.last-search-results.json`, and the tips file from B5.2.
- **Options:**
  - (A) Remove them. Closer to "uninstall". The PATH line is risky: install.sh:234 treats any `.claude/bin` line as already present and other tools may share the directory, so delete only the exact `# claude-session-search` marker plus the `PATH_LINE` pair.
  - (B, recommended) Keep them and print what was left, checking both `~/.zshrc` and `~/.bashrc`: `PATH line left in <rc>: remove it manually if nothing else uses ~/.claude/bin`.
- B21.1's round-trip test pins whichever is chosen.
- **Owner:** U22.

### (Round 2) C20. Machine-readable help
- **Source:** critic2.json entries on R106, R107 and R108, verified: `grep -n -- '--help\|help --all\|help search'` finds no implementation in any CLI here. These are MUSTs and no earlier row scopes them.
- **Rules:** R106, R107, R108, R247, R252, R454.
- **NEEDS OPERATOR DECISION.**
- **Callers:** none. `claude-search help search foo` searches for "help search foo" today, so R107 and R108 change what a free-text query means, the same collision as C4.
- **Options:**
  - (A, recommended) `claude-search --help --json` (R106) from `build_parser()` metadata, with `--fields` for `--json` search (R252). The wrapper execs the engine for this path, and `--help` alone stays hand-written. For R107 and R108, take them with C4 if C4 is approved, otherwise record a deviation.
  - (B) Also add `--help --json` to install.sh, uninstall.sh, backfill, chunk and tag. R106 says every path, but these have small audiences and hand-written shell help. Recommended: argparse-based chunk and tag only, and record the shell scripts under R422.
  - (C) Record all three as known deviations under R422.
- **Owner:** U26.

### (Round 2) C21. Bulk preview on backfill and chunk
- **Source:** verdicts on the two "no target shown, no preview" findings. R325 and R441 constrain a `--dry-run` that exists, and neither requires adding one.
- **NEEDS OPERATOR DECISION.**
- **Options:**
  - (A, recommended for backfill) No `--dry-run`. Classify it as Ordinary: it merges into a local derived index, and tags and enrichment survive the `CASE` merge at helpers:285-303. A real backfill `--dry-run` needs parallel counting paths across 7 inline phases, and it fails R441 if any path still writes.
  - (B, recommended for chunk) `--dry-run` returning before :256-274, because WAL and DDL are mutations. Reuse `parse_transcript` and `generate_chunks` to count, skip `store_chunks`, `outcome: "planned"`. Additive and small. Stderr preview from B17.5 already meets R002's stated check.
- **Do not add a `--yes` requirement to backfill.** The "many resources" tier in R146 would ask for it, but all three automated callers pass only `--quiet`, so caller compatibility wins. See "Recorded conflicts".
- **Owner:** U23 for any chunk or backfill change.

### (Round 2) Recorded conflicts (the rule stays; caller compatibility wins for now)
The repo has no CLAUDE.md or rules file, so every conflict here is against a caller or the deployment model. None of these rules is dropped.

| Rule | Conflict | What the plan does | When it goes away |
|---|---|---|---|
| R438, R009 (`--json` is the only format selector) | `--format=fzf` is the picker's feed (bin/claude-search:121, :130) | `--format` is hidden. `json` warns and is removed in C1b. `table` is the default and is not extended. `fzf` stays an internal value (R111) | Renaming the feed to a hidden `--fzf-feed` is one line in U6 and U1b if the operator wants the option gone entirely |
| R441 (never `--preview` for a preview) | `--preview <SESSION>` is an existing, unrelated read of one session; it isn't a dry run. Callers: bin/claude-search:125, tests/smoke-test.sh:66, README.md:357 | Kept. The name stays visible, because R441's grep will flag it | C4's `inspect <SESSION>`, with `--preview` as a deprecated alias |
| R087 (help generated from metadata) | The wrapper's help must work with no engine (R012) | Hand-written, with a drift test (B6.3). The same holds for install.sh, uninstall.sh and backfill.sh | Not planned |
| R116, R408, R412 (one module) | The engine deploys as one copied file, and shell scripts can't import Python | One module per form, with lints and a parity test (§2) | Not planned |
| R173 (mutation prints an identifier) | install.sh and uninstall.sh have no noun identity | stdout stays empty (C7) | Not planned |
| R318 (partial bulk exits 1) | `chunk.py --backfill` skips: backfill runs it bare under `set -e` | Skips stay exit 0 (invariant 10). Real failures already exit 1 | C17's option B changes the caller |
| R146 (`--yes` for many resources) | Backfill has three automated callers that pass only `--quiet` | No `--yes` (C21). The index is derived data, R155 | Not planned |
| R366 (preserve formatting) | jq re-serializes settings.json | Write only when a hook is missing, keep key order, tell the user, report the backup (B14.2) | Not planned |
| R191 (never truncate an ID) | The TTY table shows `sid[:8]` at :1484 and :1695 | C2's second question | C2 |
| R181 (shared gutter) | progress-ui.sh's box is shared with backfill and install output | B19.4 records it | A later pass over progress-ui.sh |
| R389, R377 (telemetry) | N/A | No telemetry exists | N/A |

---

## 5. Dropped

The verifier's `dropped` list is empty and no finding is Vercel-specific. These sub-claims and suggested fixes are not carried into the plan:

- "Ctrl+C exits 1" (uncaught-exceptions finding) is refuted. Since Python 3.8 an uncaught KeyboardInterrupt re-raises SIGINT, so the shell sees 130. Only the traceback and the leftover spinner are real.
- "NULL project_name raises TypeError" is refuted. The schema declares `project_name TEXT NOT NULL` (session-index-helpers.sh:168, build_demo_db.py:135).
- "search_log may be absent" is unlikely, since the schema creates it. The R074 citation does not fit (the code crashes; it does not fall back).
- The resume finding's suggested `if ! X=$(...); then exit $?; fi` is refuted: inside the then-branch `$?` is 0. Replaced by `|| exit $?`.
- The resume finding's R003/R339 breach is refuted, because the exit is already 1. The real breach is R275 (the error is hidden).
- The fzf finding's "refuse when CI is set" without touching the demo is replaced. On its own it would publish a broken GIF through demo.yml:63-70; U6 updates the tape in the same commit.
- The fzf finding's "map 130 to Canceled" as written would mislabel a successful Ctrl-Y (`execute-silent+abort`). Replaced by `--expect=ctrl-y`.
- "The spinner pollutes piped stdout" is refuted: it is gated on a TTY stdout (:1884). Only the stream choice remains (B3.7).
- "`\033[90m` is a fixed 256-colour code" is refuted: it is bright black, one of the basic 16. "Suggestions are dim" is partly wrong: the commands are cyan and only the headings are dim.
- The cache encoding risk is refuted, because `json.dumps` writes ASCII by default. The explicit utf-8 in B4.3 is hygiene only.
- The `SESSION_SEARCH_PYTHON_DEPS` sys.path concern is harmless: the helpers export the repo's own `.python-deps`.
- Query-less `--explain` and `--context-inject` through the wrapper are not documented uses, so they are out of scope.
- The R019 citation for `--limit` is a stretch. (Round 2: the rest of this row is reversed. `limit_clamped` is in Reference K and R344 and R396 name it, so calling it API-flavoured was no ground for dropping it. U1b and B3.6 now emit it.)
- R137's "linked target" wording is link-flavoured. Only its general part ("a read never creates side effects") is applied.
- (Round 2: reversed.) This row called the R436 value-hint list house style. R436 is a MUST with an allowed list, generalized by the checklist. All hints now come from it: `<NUMBER|SESSION>` and `<auto|always|never>` are gone, and `<SESSION>`, `<QUERY>` and `<NAME>` are allowed nouns or hints.
- Edits to `docs/SESSION_RESUME_UX_DESIGN.md:436` are dropped: `docs/` is untracked in this checkout (`?? docs/`).
- Changing `scripts/session-index-tag.py:716` to the same error copy is a different CLI, outside this unit. Flag it for its own audit.
- The `--file` and `--tool` flags in `docs/METADATA_EXTRACTION_PIPELINE.md` exist only in a design doc and are implemented nowhere.

**(Round 2) Sub-claims from the 58 findings not carried into the plan.** The verifier dropped no finding and none is Vercel-specific. Each rule below is dropped only from a finding's citation, with a named reason. The rule itself stays in force.

- install.sh `--help`: :5 and :106 are weak citations (`set -euo`, a timer). Help must also precede :8, which the finding's "before line 19" misses.
- install.sh false reports: "always Ready, exit 0" holds only on reaching the end, because `set -e` aborts at :135, :214, :257 and :264. The finding's "create the rc file" is the worse option, because :14 picks .bashrc whatever the shell. Its FTS step is replaced by B14.3.
- install.sh RMW: atomicity holds on this Mac, where `$TMPDIR` and `$HOME` share a filesystem (`df`), and "may" fits only hosts with a tmpfs /tmp. R351 still stands. The proposed `flock` is replaced, because it is absent on this Mac (`command -v`). The verdict's claim that no trap exists is wrong: progress-ui.sh:346 sets one, so U11a uses no trap.
- install.sh FTS: `2>/dev/null || true` does not hide the alias loss, because omitting a column raises no error. It hides a separate failure. R017 is a weak fit here; R420 carries it. Citation tag.py:1015 is really :1014-1018. A bare `session_index_rebuild_fts` would abort the install.
- install.sh foreign symlinks: R325 is a constraint on `--dry-run`, not a violation. R354 does not apply to a setup command. `--force` is replaced by `--yes`. "Refuse every link outside this repo" would break moved clones, and treating every differing plist as foreign would break `git pull && ./install.sh`, so C9 has classes.
- install.sh streams: "unconditional" is wrong: :302 gates on a missing dependency. "After success" is already met. R241 and R173 fit weakly. "Route through progress-ui.sh" is replaced by `exec 1>&2`, because it would change backfill's stream and break `$(...)` helpers.
- install.sh scheduler: "launchctl is unguarded" is wrong for the abort claim: :256, :258, :263 and :265 have `|| true`, and `cp` is the only abort site.
- install.sh colour: :47 emits no styling, :305 and :309 are allowed to be faint, and "normal foreground" for recovery commands conflicts with R201. :32 counts only under "one shared set".
- install.sh error copy: R185 does not apply to `Ready`: the guide itself shows `✓ Ready in 41s`. The objection to it is R033 and R187. A helper in progress-ui.sh can't serve :21, which fires when that file is missing. Printing recovery inline at :204 would break the redraw.
- install.sh and uninstall.sh global options: R073 is the weak citation, since one layer can't invert an order. It binds once C16 adds a layer. `--non-interactive` is nominal. `--scope` and `--token` are N/A.
- uninstall.sh false report: "Removed backfill plist" is literally true of the file; the false part is the overall "complete". Auto-removing the PATH line is rejected (C19).
- uninstall.sh streams: :21 does state a consequence ("skipping"), so R307 fails only on the missing fix. The `!` gutter alone would violate R205 in plain mode. Per-item `✓` conflicts with R182.
- uninstall.sh preview: R325 is not violated and R002 is weak (ordinary tier, R146). -wal/-shm is R004, not R103 or R105. "Unsafe" is overstated: it mostly fails.
- backfill entry: helpers:12 is not "looping on readlink". "Skipped silently" is half right, since Phase 7 prints a skip line. :626, :644 and :655 are latent.
- backfill help: sourcing is not itself mutating, but it does break help through the symlink. The finding's `breaking` label is downgraded by the verdict, because only already-failing invocations change.
- backfill `--since`: "instead of failing" is imprecise: `abc` fails late at Phase 7, and SQL paths go the other way (NULL matches nothing). R344 is mis-cited, because `--since` is a time window. Multi-statement injection is inferred, not demonstrated.
- backfill `--quiet`: "all 3 callers get full output" is overstated: bin/session-search.py sends everything to DEVNULL. The plist's `head -50` isn't hit today (about 20 lines, estimated). R006 is weak. "Guard ui_* calls" misses chunk.py:240.
- backfill streams: "every ui_* call writes to stdout" is overstated. Library-level redirection is replaced by `exec` in the script, because it breaks install.sh.
- backfill read failures: the log evidence is misapplied, because those 5 failures printed an error and exited nonzero. :584 is not a defect. R138 is dropped: these are data files, not config. R283 applies only to the raw `(5)`. "Keep child stderr" would violate R283 unless it goes to the log.
- backfill raw sqlite3: "matches the measured failure" is refuted (see B16.2). The migration half is already fixed on `origin/main`. R019 and R015 are weak.
- backfill lock: R019 is only partly right, since the `mkdir` loop is bounded. R368 and R319 fit weakly. Fail-on-timeout on the current primitive would wedge after a SIGKILL, so C10 orders it. The finding's and verdict's plan to switch only this repo's helpers is corrected in C10.
- backfill trap: "no cleanup path" is too strong, because the normal path removes temp files. "Any abort" holds only for a direct TTY run. The trap must install after the lock.
- backfill GNU: the title understates it, because :266, :359, :366 and :498 aren't gated on `--since`. :494 fails open. The ubuntu CI citation is weak, since CI never ran the script. "Fail early" is rejected as breaking.
- backfill grammar: "no documented default window" is overstated (:4 says full backfill). R436 at the cited sites is refuted: the real hit is chunk.py:7. "Keep the bare integer as documented day count" holds, but `^[0-9]+$` is narrowed to `1-36500` from the validation finding.
- backfill no target: R325 is not violated and R002 is weak. R023 applies on other evidence: the usage comment omits `--quiet`. README:86 is really :85.
- chunk bare invocation: durable effect is often nil, because helpers:161 and :216-234 create the same tables. R137 is dropped: not a read. R064 is weak.
- chunk conflicts: `--since` without `--backfill` is silently ignored only when both positionals are given. R344 is dropped, and R074 carries the refusal.
- chunk session ID: R043 is dropped, because this code uses the exact ID it was given. "Check the ID in sessions" is dropped. Severity lowered by the verifier.
- chunk streams: `{"sessionId":...}` from the verdict is replaced by R248's noun-keyed shape with snake_case keys, matching B3.5.
- chunk batch: `partial` means failures only, or a routine long session would abort backfill. The raw traceback rarely reaches users, because stderr goes to /dev/null at backfill:648. KeyboardInterrupt already dies by SIGINT since Python 3.8, so only the traceback text is the gap.
- chunk help: R029 and R023 are dropped. `metavar='session-id'` from the verdict is replaced by `session` (R434).
- chunk `--since`: "Match backfill.sh" can't be done, since backfill is days-only too. The finding's "no offset means local time" is overruled by the UTC in B12.3 and the engine. "`0` stays no cutoff" holds only until C8.
- chunk target and globals: R325 and R073 are not violated as written. `--config-dir` is replaced by `-Q, --global-config`.
- tag key: "No masking of this form is allowed" is the finder's inference. The fix stands, because "never appear" covers a partial value.
- tag exits: "reports Tagged when work did not happen" holds literally only in retag mode. The fallback and the no-key mode are documented, not defects. R168 fits only through 403. `failed > 0` must not drive the exit code.
- tag streams: :275 and :277 print nothing, and cursor codes never reach a pipe. `--json` doesn't exist yet, so "reserve stdout for --json" is deferred to B20.1.
- tag dry-run: "drop the key requirement" conflicts with R325. :737 and :770 are citation drift.
- tag invalid options: "missing key exit 2" is C8's question. "Runs after DB and lock steps" is weaker than R070's bar. R302's "report every problem" is a weak fit.
- tag Ctrl+C: "billed" and "waits for all" apply only to Haiku mode. :966 is a comment. `shutdown(cancel_futures=True)` inside `with` still waits, and a flag doesn't wake `as_completed`.
- tag tracebacks: R138 is dropped, because there is no config. :925 is a weak site. "Locked DB" is less likely than implied.
- tag API bound: R315 is dropped, since no retry loop wraps a POST. "No backoff" is false for the SDK path. R296 is narrowed. "Hold the limiter around the call" is a no-op.
- tag capped batch: R149 is weak, and R347 applies only through its last clause. The same `--limit` can stall, so B19.3 prints the remainder.
- tag lock: :716 is an unrelated message. "Another tagger or backfill" still guesses, because hooks take the same lock.
- tag untrusted text: :466 is the user's own argv. The finding missed aliases.
- tag help: R023 and R029 are dropped. "Or vice versa" is rejected, because it silently stops processing untagged rows.
- tag SDK import: `find_spec` regresses the fallback. R012 is weak: no network before help is shown, and the SDK's own import was not audited.
- tag styling: R204's check doesn't match `\033[90m`. R115's per-stream clause isn't violated yet. R227 is weakest at :518. `Tagged 80 sessions` is false in two modes.
- tag globals: the fix misses `--no-color` and the unguarded SHOW_CURSOR. R073 is the weak citation.
- tag sends: R005, R010 and R160 don't fit (C12). :194-195 are response parsing. "Whenever" and "session text" are overstated.
- tag.sh entry: R023 is mis-cited for a comment, and R356 is README-only. :716 names another command. A new `session-index-tag` symlink is rejected, because it adds a third name.
- tag.sh recovery: "offer only git restore" fails with no `.git`. `missing_command` doesn't apply. R237's remote clause doesn't apply.
- Scope-wide tests: "exit codes are not asserted" is overstated. "Uninstall removing everything" contradicts invariant 14. R392, R397 and R400 fire when fixes land, not today. R100 has little to test until fixes add examples, which they now do.
- Critic: uncoveredClis entries 2 and 5 concern agent-context-sync, agent-secrets and worktree-harness. Their `install.sh` isn't this repo's. missedFindings entry 5 is agent-secrets.

---

## 6. Implementation sizing

LOC figures are estimates: changed or added lines summed per cited line range from reading the code, with test files sized at about 10-15 lines per test case. Nothing was measured by implementing.

| Unit | Step | Files owned | Est. LOC (code + tests) | Depends on |
|---|---|---|---|---|
| U1a | A1 | bin/session-search.py (contract section, new lines after :39); tests/engine_loader.py; tests/test_contract_layer.py | 310 + 145 = ~455 (Round 2: +45 for REASONS, warn, parse_time) | none |
| U2 | A1 | tests/helpers.bash; tests/harness.bats; tests/smoke-test.sh (self-isolating HOME, keeps the summary and 0/1 exit used by ci.yml:26); .github/workflows/ci.yml (apt `bats`, add G5 and G6 steps) | 80 + 50 + 40 + 10 = ~180 | none (parallel with U1a) |
| (Round 2) U11b | A1 | scripts/lib/cli_common.py; VERSION; tests/test_scripts_common.py | 170 + 100 = ~270 | U1a (parity test); assumes C15 option A |
| U1b | A2 | bin/session-search.py (build_parser, validate_args, :1759-1776, :1925-1926); tests/test_parser.py | 140 + 90 = ~230 (Round 2: +40 for short forms, hidden aliases, R068) | U1a |
| (Round 2) U11a | A2 | scripts/lib/cli-common.sh; scripts/lib/settings-edit.sh; tests/helpers_scripts.bash; tests/scripts_lib.bats | 200 + 150 = ~350 | U2 (extends its sandbox) |
| (Round 2) U12 | B0 | scripts/session-index-backfill.sh (:1-35, the argument at :648); config/com.claude.session-search-backfill.plist; tests/backfill_cli.bats | 130 + 2 + 110 = ~242 | U11a, U11b; before U3 (R053); B12.4 follows C18 |
| (Round 2) U13 | B0 | scripts/lib/progress-ui.sh; tests/progress_ui.bats | 70 + 60 = ~130 | U11a |
| (Round 2) U15 | B0 | uninstall.sh; tests/uninstall.bats | 160 + 90 = ~250 | U11a |
| (Round 2) U17 | B0 | scripts/session-index-chunk.py; tests/test_chunk_cli.py | 270 + 150 = ~420 | U11b |
| (Round 2) U18 | B0 | scripts/session-index-tag.py (:116-121, :149-158, :190-203, :213-251, :254-261, :274, :483-486, :675-710, :743-747, :994, :1074-1075); scripts/session-index-tag.sh; tests/test_tag_cli.py; tests/tag_wrapper.bats | 220 + 150 = ~370 | U11a, U11b |
| U3 | B1 | bin/session-search.py (main :1779-1919, :1688-1690, docstring :3-21); tests/engine_cli.bats; tests/smoke-test.sh:46 | 150 + 185 + 5 = ~340 (Round 2: +15 for R176 and alias tests) | U1b, U2, (Round 2) U12; B3.5 waits for C1 |
| U6 | B1 | bin/claude-search; assets/demo/fzf-demo.tape; tests/wrapper.bats | 245 + 2 + 225 = ~472 (Round 2: +42 for help Notes, R100 and new arms) | U2 to develop; lands after U3 |
| (Round 2) U14 | B1 | install.sh; tests/install.bats | 270 + 180 = ~450 | U11a, U13 |
| (Round 2) U19 | B1 | scripts/session-index-tag.py (:178, :212, :224, :276-285, :385, :398-448, :464-557, :572, :620-664, :736-749, :769, :838-863, :870-881, :1055-1069); tests/test_tag_runs.py | 310 + 160 = ~470 | U18; B19.5 waits for C12 |
| U4 | B2 | bin/session-search.py (:144-151, :320-325, :567-570, :604-607, :637-640, :762-769, :977-1100, :1631-1684, :1734-1754); scripts/session-index-backfill.sh (the parser table, :50-52); (Round 2) hooks/lib/session-index-helpers.sh (:85-100); tests/test_engine_pipeline.py; tests/backfill.bats | 168 + 170 = ~338 (Round 2: +18 for the trylock fix) | U3, (Round 2) U12 |
| (Round 2) U20 | B2 | scripts/session-index-tag.py (:35-51, :675-710, :715-763, :727, :831-846, :996-1000, :1051); tests/test_tag_global.py | 100 + 50 = ~150 | U19 |
| U5 | B3 | bin/session-search.py (:245-274, :402-407, :671-720, :857-887, :897-1100 palettes, :1143-1147, :1203-1283, :1406-1729, :1906); tests/test_engine_output.py | 255 + 215 = ~470 (Round 2: +30 for the once-per-user tip and empty-state copy) | U4 (needs `--if-idle`) |
| (Round 2) U16 | B3 | scripts/session-index-backfill.sh (:12-13, :48-59, Phase bodies, :636-674); hooks/lib/session-index-helpers.sh (date and stat helpers, retry, :550-552); tests/backfill_pipeline.bats | 180 + 120 = ~300 | U4, U12 |
| (Round 2) U21 | B4 | tests/scripts_contract.bats; tests/contract_modes.bats; tests/test_transcripts.py with tests/golden/; .github/workflows/ci.yml | 310 + 8 = ~318 | U3 through U20 |
| U7 | B4 (Round 2: moved from B3) | README.md; tests/docs.bats | 135 + 70 = ~205 (Round 2: +95 for the additions) | parallel with U21; content follows C1 |
| (Round 2) U22 | C1 | install.sh; uninstall.sh; tests/install_contract.bats | C6 135 + C7 60 + C9 110 + the :214 guard 5 = 310, + 160 = ~470 | U14, U15 and the C6, C7, C9, C19 decisions |
| (Round 2) U23 | C1 | scripts/session-index-backfill.sh; hooks/lib/session-index-helpers.sh; scripts/session-index-chunk.py; tests/backfill_contract.bats; tests/test_chunk_contract.py | C6 110 + C7 30 + C8 20 + C10 65 + C14 5 + C17 10 = 240, + 170 = ~410 | U16, U17, U22's guard, and the C6, C7, C8, C10, C14, C17, C21 decisions |
| (Round 2) U24 | C1 | scripts/session-index-tag.py; tests/test_tag_contract.py | C6 110 + C7 45 + C8 100 + C11 70 = 325, + 150 = ~475 | U20 and the C6, C7, C8, C11 decisions |
| U8 | C1 | bin/session-search.py (format_table non-TTY branch, cache v2, (Round 2) LIKE escaping at :551, :625, :852); tests/test_engine_c.py | C2 ~105 + C3 ~90 = ~195 | U5 and the C2/C3 decisions |
| U9 | C1 | bin/claude-search; tests/wrapper-subcommands.bats; README.md | C4 ~230 + C5 ~5 = ~235 | U6, U7 and the C4/C5 decisions |
| U10 | C2, later | bin/session-search.py; tests/engine_cli.bats | ~20 | the C1 removal date |
| (Round 2) U25 | C2, later | install.sh; uninstall.sh; hooks/lib/session-index-helpers.sh; bin/session-search.py; bin/claude-search; scripts/session-index-tag.py; scripts/session-index-chunk.py; config/*.plist; tests/config_dir.bats | 150 + 60 = ~210 | C16; runs alone, after U10 |
| (Round 2) U26 | C2, later | bin/session-search.py; bin/claude-search; scripts/session-index-tag.py; scripts/session-index-chunk.py; tests/test_machine_help.py | 120 + 60 = ~180 | C20; runs alone, after U25 |

**Per wave (estimated, Round 2 totals):** Wave A ~1485; Wave B ~4925; Wave C ~2195. Total about 8600 LOC, roughly 43% of it tests (summed from the table). Round 1 was about 2850. The largest single unit is U24 at ~475, and every unit is under 500. If an implementer finds U6, U19, U24, U5 or U22 running over, the split point is named here: U6 moves B6.6's tests to a second file, U19 moves B19.4 out, U24 moves C11 out, U5 moves B5.5 and B5.6 out, U22 moves C9 out.

**File ownership:** within each step (A1, A2, B0, B1, B2, B3, B4, C1) no two units share a file. C2's units share files, so they run one at a time.
- `bin/session-search.py` is a single file, so its units run in sequence: U1a, U1b, U3, U4, U5, U8, then U10, U25, U26.
- Parallel tracks: U2 and U11b with U1a; U11a with U1b; U12, U13, U15, U17 and U18 in B0; U6, U14 and U19 with U3; U20 with U4; U16 with U5; U7 with U21; U8, U9, U22, U23 and U24 in C1.
- `tests/smoke-test.sh` is owned by U2 in A1 and by U3 in B1.
- `README.md` is owned by U7 in B4 and by U9 in C1.
- `bin/claude-search` is owned by U6 in B1 and by U9 in C1.
- (Round 2) `scripts/session-index-backfill.sh`: U12 in B0, U4 in B2, U16 in B3, U23 in C1.
- (Round 2) `hooks/lib/session-index-helpers.sh`: U4 in B2, U16 in B3, U23 in C1.
- (Round 2) `scripts/session-index-tag.py`: U18 in B0, U19 in B1, U20 in B2, U24 in C1.
- (Round 2) `scripts/session-index-chunk.py`: U17 in B0, U23 in C1.
- (Round 2) `install.sh`: U14 in B1, U22 in C1. `uninstall.sh`: U15 in B0, U22 in C1. `.github/workflows/ci.yml`: U2 in A1, U21 in B4.

**Commit and landing order:** U1a, U2, U11b, U1b, U11a, U12, U13, U15, U17, U18, U3, U6, U14, U19, U4, U20, U5, U16, U21, U7. Then U22, U23, U24, U8 and U9 after the decisions, and U10, U25 and U26 later. CI stays green at every commit:
- U2's `bats tests/` initially has harness.bats only.
- U6's end-to-end cases need U3's `--json`.
- U4's `--if-idle` lands before U5 starts passing it.
- (Round 2) U12 lands before U3, because B3.1 and `run_cli` teach the symlink path it repairs (R053).
- (Round 2) U4's trylock fix lands with B4.6's test, or that test fails on ubuntu-latest.
- (Round 2) U22's install.sh:214 guard lands before U23's exit-1-on-partial, or a partial backfill aborts the install. The guard is safe on its own.
- (Round 2) U7 lands after every parser it teaches (R053). Lines for C-wave options go in with U22, U23 and U24, through U9's ownership of README.md in C1, as one more commit in that unit.

**Execution locus** (from the operator's plan-file convention; kept inside this section because the brief fixes the section list)
- Every unit runs as **S**: a dispatched handoff session in its own worktree, branched from the integration branch `cli-contract` at the tip left by the previous step.
- Each step gets one `--goal`:
  - A1: "U1a and U2 merged; G1-G6 pass — proven by printing the G1-G6 output; do not edit files outside the unit's owned list".
  - A2: "build_parser is the only option table; G5 passes".
  - B1: "`claude-search --json q` and `--analytics` work in the sandbox; G1-G7 pass".
  - B2: "broken index exits 1 and `--if-idle` skips when the lock is held; G5-G7 pass".
  - B3: "source lint finds no raw ANSI or TTY checks outside the contract layer; G1-G8 pass".
  - C: one goal per approved decision.
  - (Round 2) A1 also: "VERSION, cli_common.py and its parity test pass". A2 also: "`css_parse_args` and `css_settings_patch` pass tests/scripts_lib.bats".
  - (Round 2) B0: "in the sandbox, `session-index-backfill.sh --help` works through a symlink; `./uninstall.sh --help` removes nothing; `session-index-tag.py --help` imports no anthropic; G1-G6 pass, proven by printing their output".
  - (Round 2) B1 also: "`./install.sh --help` changes nothing and `./install.sh` still exits 0 in the sandbox".
  - (Round 2) B3 also: "`SIGINT` during a backfill exits 130 and restores the cursor; every backfill sqlite3 call sets a timeout".
  - (Round 2) B4: "tests/contract_modes.bats and the install-then-uninstall round trip pass on ubuntu and macOS; every README example parses".
  - (Round 2) C1 and C2: one goal per approved decision, as above.
- Every session follows the same constraints: never touch `docs/` or `.venv/`, and never run `tests/smoke-test.sh` against the real HOME before U2 lands.
- (Round 2) Script tests never run against the real HOME. A real `./install.sh` on this machine would retarget live hooks and drop the sweep throttle (C9), and a real `launchctl` acts on real jobs, so every session uses `script_sandbox_setup`.

---

## 7. Round 2 changes

No existing section was removed or rewritten. Rows that contradicted the checklist were corrected in place and marked "(Round 2)".

### 7.1 The 58 new findings

"Contract" is the verifier's verdict, not the finder's label. Measured from the input: 41 compatible, 17 breaking.

| # | Finding | Severity | Contract | Row | Unit |
|---|---|---|---|---|---|
| 1 | install.sh: `--help` or any argument runs the full install | high | compatible | B14.1 | U14 |
| 2 | install.sh: reports registered/Ready after failed or skipped steps | high | breaking | C6 | U22 |
| 3 | install.sh: settings.json read-modify-write | medium | compatible | B14.2, S8 helper | U14, U11a |
| 4 | install.sh: FTS rebuild drops search_aliases | medium | compatible | B14.3 | U14 |
| 5 | install.sh: replaces foreign symlinks, guesses the shell rc | medium | breaking | C9 | U22 |
| 6 | install.sh: progress on stdout, offers unconditional | medium | breaking | C7 | U22 |
| 7 | install.sh: scheduler aborts on supported hosts | medium | compatible | B14.4 | U14 |
| 8 | install.sh: colour and glyph rules | low | compatible | B13.1, B13.2, B14.5 | U13, U14 |
| 9 | install.sh: error copy | low | compatible | B14.6 | U14 |
| 10 | install.sh: missing global options | low | compatible | B14.7, C16 | U14, U25 |
| 11 | uninstall.sh: `--help` performs the uninstall | high | compatible | B15.1 | U15 |
| 12 | uninstall.sh: says complete while artifacts and failures remain | high | breaking | B15.2 (links), C6 (exit) | U15, U22 |
| 13 | uninstall.sh: settings.json edit | medium | compatible | B15.3, S8 helper | U15, U11a |
| 14 | uninstall.sh: all status on stdout, fixed glyphs | medium | breaking | C7 | U22 |
| 15 | uninstall.sh: no preview, unsafe delete suggestion | low | compatible | B15.4 | U15 |
| 16 | uninstall.sh: missing global options | low | compatible | B15.5, C16 | U15, U25 |
| 17 | backfill: PATH-installed entry cannot start | high | compatible | B12.1, B12.4, C18 | U12 |
| 18 | backfill: no help, usage errors exit 1 | high | compatible | B12.2 | U12 |
| 19 | backfill: `--since` unvalidated, in SQL, widens to a full run | medium | compatible | B12.3 | U12 |
| 20 | backfill: `--quiet` does nothing | medium | compatible | B16.6, C14 | U16, U23 |
| 21 | backfill: progress and child output on stdout | medium | breaking | B13.2 (plain rows), C7 | U13, U23 |
| 22 | backfill: read failures become empty results | high | breaking | C6 | U23 |
| 23 | backfill: bypasses the busy timeout, migrates before locking | medium | compatible | B16.1, B16.2, C10 | U16, U23 |
| 24 | backfill: lock doesn't exclude the tagger, proceeds after timeout | medium | breaking | C10 | U23 |
| 25 | backfill: lock trap replaces cursor cleanup, temp files leak | medium | compatible | B16.3 | U16 |
| 26 | backfill: BSD-only date and stat | low | compatible | B16.4 | U16 |
| 27 | backfill: `--since` takes bare days | low | compatible | B12.3 | U12 |
| 28 | backfill: no target, no preview, stale description | low | compatible | B13.3, B13.4, B16.5, U7, C21 | U13, U16, U7 |
| 29 | backfill: missing global options | low | compatible | B16.7, C16 | U16, U25 |
| 30 | chunk: missing or skipped transcript reports success | medium | breaking | C6 | U23 |
| 31 | chunk: bare invocation writes before usage, exits 1 | medium | breaking | B17.5 (order), C8 (exit) | U17, U23 |
| 32 | chunk: conflicting inputs ignored | medium | breaking | C8 | U23 |
| 33 | chunk: session ID not validated | medium | compatible | B17.1 | U17 |
| 34 | chunk: receipts on stdout | medium | breaking | C7 | U23 |
| 35 | chunk: no top-level handling, batch aborts | medium | compatible | B17.2, C17 | U17, U23 |
| 36 | chunk: argparse and help | low | compatible | B17.3 | U17 |
| 37 | chunk: `--since` takes bare days | low | compatible | B17.4 | U17 |
| 38 | chunk: no target shown, missing global options | low | compatible | B17.5, C16, C21 | U17, U25, U23 |
| 39 | tag: prints part of the API key | high | compatible | B18.1 | U18 |
| 40 | tag: exits 0 and reports Tagged when work failed | high | breaking | C6 | U24 |
| 41 | tag: banner, dashboard and cursor on stdout | medium | breaking | C7 | U24 |
| 42 | tag: `--project` selects write targets by substring | medium | breaking | C11 | U24, U8 |
| 43 | tag: `--dry-run` doesn't preview the real run | medium | compatible | B19.1 | U19 |
| 44 | tag: conflicting and invalid options | medium | breaking | C8 | U24 |
| 45 | tag: Ctrl+C exits 1, waits, loses results | medium | breaking | C8 | U24 |
| 46 | tag: raw tracebacks, post-work exit changes | medium | compatible | B18.2 | U18 |
| 47 | tag: API calls lack a total bound | medium | compatible | B19.2 | U19 |
| 48 | tag: capped batch reads as Done | medium | compatible | B19.3 | U19 |
| 49 | tag: lock failure misreports the cause | low | compatible | B18.3 | U18 |
| 50 | tag: transcript and model text treated as trusted | medium | compatible | B18.4 | U18 |
| 51 | tag: help omits its variable, misdescribes options | low | compatible | B18.5 | U18 |
| 52 | tag: SDK import before `--help` | low | compatible | B18.6 | U18 |
| 53 | tag: styling and copy | low | compatible | B19.4 | U19 |
| 54 | tag: missing global options | low | compatible | B20.1, C16 | U20, U25 |
| 55 | tag: key in the environment sends text to the API | low | compatible | B19.5, C12 | U19 |
| 56 | tag.sh: taught entry differs from the installed one | low | compatible | B18.7, U7 | U18, U7 |
| 57 | tag.sh: missing-file and spawn recovery | low | compatible | B18.7 | U18 |
| 58 | Scope-wide: no contract tests | medium | compatible | B21.1 to B21.4, U11a harness | U21, U11a |

### 7.2 critic2.json entries that concern this repo, each checked against the code

| Entry | Checked | Result | Action |
|---|---|---|---|
| planConflicts[5]: U1b hides `--format`, C1 says the note goes in help | Plan text; R050, R111, R308, R385 | Real. C1 was also wrong to rule out a runtime warning | C1 corrected: hidden plus one stderr warning. U1b unchanged on hiding. B3.6 test added |
| missedFindings[11]: R100 | `grep` of the plan: the credited line 483 tests README lines only, and B6.3's three help examples had no parser test | Real, and wider than the critic said | B6.3 test added. Every new help has one: B12.2, B14.1, B15.1, B17.3, B18.5. Rerun command: B19.3. README: U7 |
| uncoveredClis[1]: chunk, tag and backfill on PATH; install, uninstall and tag.sh unaudited | install.sh:149-151; chunk.py shebang and exec bit; plan's B4.1 line | Real. Now covered by the 58 findings. The chunk recovery command does work through its symlink. **The backfill one doesn't**, and B3.1 taught it | U12 lands before U3 (R053). B3.1 note added |
| uncoveredClis[2], [5]; missedFindings[5] | Named repos | Other repos' `install.sh` and `cmd/uninstall.sh` | None here |
| unmentionedRules[0]: method | Read | Not a finding | None |
| [1] R020, R165, R293, R300, R315, R317 | tag.py POST path | R315 not violated: `/v1/messages` persists nothing. The rest N/A: no charges or mutations with outcomes | B19.2 comment states why replay is safe |
| [2] R018, R356-R358; R349 | tag.py:484, README.md:280; no stdin input in any CLI | R018 and R355 real (finding 39). R356 applies to the README example only. R357, R358, R349 N/A | B18.1, U7 |
| [3] R133; [14] R110; [17] R135; [19] R159-R164, R166, R479; [20] R169-R171, R480; [29] R265-R272; [33] R331-R333; [35] R345, R346; [36] R365; [37] R367-R373, R376-R378, R389 | `grep` for masked input, purchase, login, JSONL, follow, `--wait`, paging, servers, telemetry, notifier | N/A: none of these features exists here. R388 is a MAY; verdicts judged it not needed, because no caller needs a compat switch | Recorded here |
| [4] R033, R035 | Receipts in install.sh and uninstall.sh | `Ready` breaks R033 and R187 when hooks went unregistered. `remove` fits Reference A | B14.6, C7 (`Uninstalled`) |
| [5] R025-R052 grammar; [6] extensions | Dispatch arms | N/A for flat CLIs, except R028 on chunk.py (B17.3) | Recorded here |
| [7] R060 | `grep -n flag` over all CLIs | Real here too: backfill:24, tag.py:480, README.md:115, :344. The critic named only agent-secrets | B12.2, B18.5, U7 |
| [8] R072, R434-R469 standard spellings | `grep` | The critic's "satisfied" is too generous for this repo: no `-n`, `-p`, `-s`, `-u`, `-v`, `-d` (R443, R444, Reference B, G). `--preview` trips R441. `--resume <NUMBER\|SESSION>` trips R434. `--all-matching` from a verdict trips R446 | U1b, B6.1, B6.3, B18.5 corrected. C11 uses `--all`. `--preview` under "Recorded conflicts" |
| [9] R073-R080, R139-R145 | Env reads | Context rules N/A. R079 and R080 are real: undocumented variables, no `<PREFIX>_ACCESSIBLE`, wrong guidance name. R073 binds if C16 lands | Invariant 7, B6.3 Notes, U7 table, U1a `accessible` |
| [10] R088, R092, R096, R101, R104 | B6.3 and the new help rows | R092, R096, R101 applied. R088 N/A until C4. R104 N/A: suggestions use placeholders | B6.3, new help rows |
| [11] R100 | See above | Real | See above |
| [12] R107, R108 | `grep -rnE 'help --all\|help search\|--help --json' bin scripts install.sh uninstall.sh hooks`: no hit | Real. R106 is also unmet | C20 |
| [13] R109 | `find` for completion files | N/A: none exist. Recorded in case one is added | None |
| [15] R112, R117, R119 | U1a Mode; B6.6 gate | R117 was missed by B6.6's gate. R119 N/A | B6.6, `css_interactive` |
| [16] R122-R134; [18] R149, R156-R158 | Prompts: the plan's first prompt is C9's | R338 and R228 applied there. No prompts elsewhere | C9 |
| [21] R174-R176 | Planned tests | Real: nothing asserted R176 | B3.4 tests, C7 tests |
| [22] R179-R196 | B5.2 copy | R195 and R196 were not followed | B5.2, C2 corrected |
| [23] R202, R208, R211 | U1a precedence | R208 was not respected by `--color=always` | U1a corrected; `--color` removed |
| [24] R212; [25] R214-R218 | Copy | R214 real (B19.4). R218 real: "50 MB" is 52.4 MB | B17.3, C6 |
| [26] R221-R234 | `grep -nEi` for filler and `!` in CLI strings | No hits in CLI output. Only `All tests passed!` in smoke-test.sh:78, which U2 owns | Note for U2 |
| [27] R235-R242 | B5.2 | R238's name and R239's once-per-user were missed | Invariant 7, B5.2 corrected |
| [28] R245-R264 JSON details | U1a `render_error`, B3.5 | Real: `next` was a list of strings (R249, R257), no `pagination` (R248), no `warnings` (R309), one reason literal (R255), no canceled document (R262), no `status: action_required` (R254) | U1a and B3.5 corrected. `--fields` (R252) is C20 |
| [30] R281-R305 error classes | tag.py | R296 narrowed, R291 real | B19.2, C6 |
| [31] R306-R312 | Deprecations | R308 applied to `--format json`, `--after`, `--before` and the chunk positional | U1a `warn`, U1b, B17.3 |
| [32] R316, R326 | B19.2; install reruns | R316 applied. R326: `hooks already registered` already meets it | B19.2 |
| [34] R340, R342 | New EXIT handlers | R342 stated on B16.3 and C6 | Noted |
| [38] R374 | Enum handling | No API enums here | N/A |
| [39] R383-R385 | Option renames | R385 was not followed for `--after` and `--before` | U1b, U7 |
| [40] R392, R394, R396-R407, including R401, R403, R404 | Plan tests | Real: no matrix, widths or colour matrix | B21.2, B21.3 |
| [41] R419-R421 | Process | N/A for a plan, except R420, which findings cite | None |
| [42] R423-R433 | `grep -ri glossary`: none | R423 real | U7 glossary |
| [43] R470-R478 | C11; `grep` for "resource", `login` | R470 applied. Others have no hit | C11 |

### 7.3 Round 1 rows corrected, and why

- **`--color` removed** (U1a, U1b, B5.1, B6.1, B6.3, B6.6, U7). R206's precedence has no such option, and R208 bars forced colour in plain output. The picker uses an internal variable.
- **`--format`** (C1, C2, U1b). The planned `--format tsv` was a new spelling against R438 and is gone. So is "an explicit `--format table` keeps the box table when piped", against R189.
- **Reversed drops in §5**: `limit_clamped` and the R436 hint list. Both were dropped as "API-flavoured" or "house style" though the checklist generalizes them.
- **Standard spellings** (U1b, B6.1, B6.3, U7): `-n`, `-p`, `-s`, `-u`, `-v`, `-d`; `--since` and `--until` take real `<TIME>` values; `--after` and `--before` are hidden deprecated aliases that warn instead of taught aliases.
- **Machine errors** (U1a): `next` objects, `REASONS` registry, `status`, canceled document, `warnings`.
- **Exit codes** (B6.4, B6.5, B6.6, U7): a missing hard-coded dependency is exit 1, `spawn_failed`, not 2.
- **Env names** (invariant 7, B5.2): `SESSION_SEARCH_GUIDANCE_DISABLED`, not `SESSION_SEARCH_NO_TIPS`.
- **Tip** (B5.2): at most once per user (R239).
- **Empty results** (B5.2, C2): copy per R195 and R196, and a header line on non-TTY after C2.
- **`--fzf` gate** (B6.6): also refuses `CLAUDECODE` and accessible mode.
- **B4.6**: its test would fail on ubuntu-latest because of a trylock bug in the helpers. The fix is now in U4.
- **Landing**: step 0, because `origin/main` is 4 commits ahead. That changes B3.4, B3.5, B6.5 and B6.6 for `wf_*` rows, and cures part of a round 2 finding.
- **Gates**: G1 to G4 and G7 cover the new files, with measured baselines.
- **Help examples (R100)**: each new parser test reads the help output at run time, so options added later (B16.7, B20.1, C9, C10, C11) are covered with no new test.
- **Checked and not present in this plan**: a `--confirm` spelling, a `<CENTS>` hint, a dropped `node_modules` step (the repo has no package manager), and any rule dropped as Vercel-specific. The closest thing was the two §5 drops reversed above, which used "API-flavoured" and "house style" as the ground.

### 7.4 Conflicts among the new verdicts, and how each was settled

| Conflict | Settled as |
|---|---|
| `--quiet`: one verdict wires it in; three say don't, because it empties the scheduled log | Decision C14. B12.2 and B16.5 keep today's behaviour until then. The ERR trap (B16.6) lands regardless |
| `--since 0`: rejected by two verdicts, "stays no cutoff" and "`^[0-9]+$`" in two others | Backfill refuses it now (B12.3, compatible, no caller). chunk keeps it until C8, then refuses it |
| ISO with no offset: UTC in one verdict, local in another | UTC, matching the engine at :321 and stored times |
| Version source: `git describe`, a VERSION file, or a constant | Decision C15. Rows assume a file plus the engine literal, with an equality test |
| Installer title: `Ready`/`Partial` against `Installed` | `Installed`/`Partial` |
| Missing settings.json: exit 0 and a `printf` recovery, against exit 1 and "start Claude Code once" | The `printf` recovery, which is a real command, in B14.6; exit 1 under C6 |
| Trap claim: one verdict says no trap exists and asks for `trap ... EXIT` | Wrong: progress-ui.sh:346 sets one. `css_settings_patch` sets none |
| Argument parsing: a parser "before line 19" inline, against "a shared parser in scripts/lib" | A short inline help scan before any source, so help works with a missing lib, then a shared table parser (R063) |
| Chunk receipt: `>/dev/null` in backfill, or stderr in chunk with backfill unedited | stderr in chunk (C7). Backfill's `2>/dev/null` then discards it, until C17 sends stderr to the log |
| Tagger rich stream: stdout in one verdict, stderr in another | Stdout until C7, then stderr; `resolve_style` takes the stream |
| Chunk and tag JSON shapes from verdicts, against R248 and B3.5 | R248 noun-keyed and bulk shapes, snake_case |
| Lock primitive: switch this repo's helpers, against the sibling repo's copy | C10 holds both primitives until the sibling ports, and the verdict's plan is corrected |
| `--all-matching` | `--all` (R446) |
| "Do not change the shared helpers" against helper changes in other rows | That constraint covers the failure-tracking rows only. B16.2 and B16.4 add helpers, and `session_index_sql` keeps its behaviour |

### 7.5 Sizing change

Counted from the §6 table: from 11 units and about 2850 LOC to 28 units and about 8600 LOC, with all LOC estimated. Every unit is under 500 (largest: U24 ~475). Steps went from A1, A2, B1, B2, B3, C to A1, A2, B0, B1, B2, B3, B4, C1, C2. Within each step except C2, files are disjoint, and C2's units run one at a time. Wave C decisions went from 5 to 20 (C1 to C12 and C14 to C21, with C13 unused).

### 7.6 Limits of this round

- No CLI under audit was executed. Numbers credited to a verifier were not re-measured. Re-measured here: `git status`, `git show origin/main`, `git tag`, `shellcheck`, `ruff --no-cache`, `bash -n`, `ast.parse`, and `grep` for callers and strings.
- New rows' line numbers were spot-checked against b765dda by reading install.sh, uninstall.sh, tag.sh, the smoke test, chunk.py lines 1-40 and 100-289, tag.py lines 264-286, 455-492, 612-1075, and the cited ranges in backfill.sh and progress-ui.sh. tag.py's prompt builders (:142-262) and Dashboard (:338-454) were not re-read, so rows citing them rest on the verdicts.
- LOC figures are estimates, summed per cited range, at about 10-15 test lines per case. None was measured by implementing.
- The "Execution locus" stays in §6 rather than becoming a new first section, because this round may not rewrite the section list.
- The hooks' own CLI-rule exposure (session-index-sweep.sh BSD `stat`, helpers:472) is flagged in B16.4, not planned.

---

## 8. Implementation record (2026-11-06 to 2026-11-07)

**Execution locus used:** T (in-session named teammates, one per unit, each in its own worktree), not the S default in §6, because the brief for this run asked for one team led in one session. Every unit was gated with G1-G7 (`/tmp/css-cli/gates.sh`, which asserts the unittest summary and the TAP plan line) and landed by rebase and fast-forward push, verified by `git ls-tree origin/main` and an empty `git diff` on the changed paths. Direct to `main`, no PR (no repo rule requires one).

### 8.1 Landed units

| Unit | Landed on `main` | Notes |
|---|---|---|
| plan copy | f9737fd | this file |
| U1a | 98aa893 | |
| U2 | ce525f5 | |
| U11b | bfe6f89 | VERSION 0.1.0 (C15 default A) |
| U1b | 7817e05 | |
| U17 | d511b1f | |
| U11a | f97c187 | |
| U18 | 53d5640 | |
| U15 | 3ce3921 | |
| U13 | 2e92dd7 | |
| U12, U3, U6 | 328455f | one push: U3 and U6 had to land together (the wrapper's `2>&1` resume capture) |
| U19 | 4053faa | |
| U14 | 15cc602 | |
| U4 | 4f77d5e | |
| U20, U16 | 0fbe18c | one push, after a red gate run was traced to a lock-timeout flake |
| U5 | f57deda | |
| U21 | see git log | landed by the lead; teammate stopped at its account's weekly limit |
| U7 | see git log | written by the lead; the capacity gate refused its teammate |

Fixes landed between units, each with its own commit: 57e7101 (ruff.toml: exempt the three legacy Python files from `ruff format`, because the post-edit formatter hook rewrote whole files), 94b032c (CI: workflow-index test macOS only), 95dfa44 (settings lock: `os.mkdir`, see 8.3), 2babb11 (settings lock waits at least 30 s).

### 8.2 Wave C: kept as today, per decision packet ad226c7513ea (default "keep", unanswered at landing)

Every Wave C row (C1-C21) needs an operator decision, so none was implemented. Where the keep option adds help text, it landed: each CLI's help lists its exit codes, and README.md has the exit-code, option and environment tables. Each decision the packet does not settle was filed once as class B, default keep, no-change: C1 (removal date for `--format json`), C3, C4, C5, C10, C11, C12, C14, C15, C16, C17, C18, C19, C20, C21. C6, C7, C8 and C9 are covered by the packet itself.

### 8.3 Recorded conflicts and findings (callers kept working; nothing widened)

- **C18, new evidence:** config/com.claude.session-search-backfill.plist:11 has a bare `&` (`2>&1`), so the file is invalid XML (`plutil -lint`); launchctl likely cannot load it, and install.sh:257-259 hides that behind `|| true`. Kept byte-identical; tests/backfill_cli.bats `"repo plist parses"` is a `skip` naming C18 until it is decided.
- **uutils `mkdir` on ubuntu-latest exits 0 when it loses a race** (measured under strace on the runner: two processes both "won"). The settings lock now uses `os.mkdir` (scripts/lib/settings-edit.sh). The helpers' own `mkdir` lock (hooks/lib/session-index-helpers.sh, flock-absent hosts) has the same exposure on Linux; C10 owns that primitive.
- **workflow-index-test.sh** can't pass on Linux: hooks/session-index-sweep.sh uses BSD `stat -f`. It runs only in the macOS CI entry.
- **Width (B21.3, R211):** tests/test_transcripts.py `KNOWN_WIDTH_FAILURES` lists the views that overflow today: stats box (fixed width 52), preview prose (unwrapped), tagger banner/bars/summary at 40 and one 82-column line at 80, installer box and rows at 40, the tagger banner row 2 columns wider than its border, and a wrapped installer row at 40 that `\r` plus erase-line cannot clear. Each entry names its file:line. The list is exact, so a fix must remove its entry. **Open follow-up unit:** fix those views, emptying the list (fits B5.1 for the engine views, B19.4 for the tagger, B13.2 for the installer).
- **R191:** the table and preview keep 8-character IDs (C2's second question, kept).
- **R205:** plain piped output keeps Unicode box glyphs; glyphs become words only in accessible mode.
- **B6.5:** `--resume <uuid>` checks the ID with plain `--preview` (not `--json --preview`), so a not-found error is human text.
- **B19.1/B19.3 vs B19.4:** the non-TTY `Done in ...` line became `Tagged N of M sessions in ...` (B19.4, the later row); no reader of the old line exists.
- **B20.1:** under `--json`, `no_match` and `empty_text` rows count as skipped, not failed, because they recur every run (§4 C6 tag.py note); `failed>0` exits 1 under `--json` only.
- **B14.2:** "corrupted during patching" is gone: the patch validates before an atomic `mv`, so the file is never corrupted by the patch. The message is "Can't patch settings.json: <why>. The file was not changed."
- **REASONS registry (R255):** the tagger's `lock_held`, `lock_failed` and `not_persisted` are outside the engine's registry, because the engine stays one copied file.
- **B6.3:** help's `--no-llm` note became true with U5 (landed after U6).
