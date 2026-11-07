<div align="center">

# claude-session-search

**Find any past Claude Code session in milliseconds — full-text search across every project, ranked like a search engine.**

[![CI](https://github.com/renchris/claude-session-search/actions/workflows/ci.yml/badge.svg)](https://github.com/renchris/claude-session-search/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-d4af37?style=flat-square)](LICENSE)
[![Search latency](https://img.shields.io/badge/Search-%3C5ms-d4af37?style=flat-square)](#measure-and-tune-your-own-search)

[Why it exists](#why-this-exists) · [Install](#install-in-one-command) · [Search](#search-by-keyword-date-project-or-tag) · [Resume](#resume-the-right-session-with-one-keystroke) · [Ranking](#see-exactly-why-every-result-ranked-where-it-did) · [Architecture](#the-index-maintains-itself)

</div>

```console
$ claude-search "rum latency"

  ╭──────────────────────────────────────────────────────────────────────╮
  │ Session Search                                       3 results · 2ms │
  ╰──────────────────────────────────────────────────────────────────────╯
   1  RUM Analysis: Friday Event Latency Report
       5mo ·   10 msgs · audit, docs, events, monitoring, +1    c1d32436
  ──────────────────────────────────────────────────────────────────────
   2  CloudWatch dashboards + p95 alarm thresholds
       2mo ·    8 msgs · docs, events, monitoring               e3d88717
  ──────────────────────────────────────────────────────────────────────
   3  Fly.io RUM latency testing, cold start bias, CLI fixes,
      cross-provider region discovery
       5mo ·   20 msgs · bugfix, deployment, monitoring, +2     08ada21a
```

> Notice `rum` matched sessions about *monitoring* and *CloudWatch* — the query expanded through a synonym table before it ever hit the index. [See how](#see-exactly-why-every-result-ranked-where-it-did)

**Everything stays on your machine.** Your sessions and the search index never leave it — the only network call is the optional Haiku tagging and query-expansion, and only when you set your own `ANTHROPIC_API_KEY`. With a key set, a search with few local matches sends the query to api.anthropic.com, including while you type in the `--fzf` picker; `--no-llm` or `SESSION_SEARCH_NO_LLM=1` stops that. The tagger sends session summaries and the start of the first prompt, and says so on stderr; `--regex-only` keeps it local.

---

## Why this exists

Claude Code records every session with rich metadata — AI-written summaries, message counts, git branches, timestamps. **None of it is searchable.** When you need "that migration session from last week," your only tool is scrolling.

| The problem today | The cost |
|---|---|
| `/resume` shows a flat, unsearchable list | Finding one session means scrolling past hundreds |
| Sessions are siloed per project directory | No cross-project discovery — 220 projects, 220 manual checks |
| Summaries, branches, and tags live in unindexed JSON | No keyword search, no date filtering, no fuzzy matching |

**This tool indexes every session into a single SQLite FTS5 database and queries it through a ranked search pipeline** — so retrieval takes ~2&nbsp;ms instead of minutes of scrolling.

### What you can do

| You want to… | Run |
|---|---|
| Find sessions by keyword | `claude-search "bottle menu"` |
| Search by time, in plain English | `claude-search "monitoring last week"` |
| Scope to one project | `claude-search "@reso sync"` |
| Filter by topic tag | `claude-search "#auth login"` |
| Browse + resume interactively | `claude-search --fzf "migration"` |
| Resume a result by number | `claude-search --resume 2` |
| Understand *why* a result ranked | `claude-search "rum latency" --explain` |
| Search inside the conversation | `claude-search "cold start" --deep-search` |
| Check index health | `claude-search --stats` |
| Tune your own search quality | `claude-search --analytics` |

---

## Install in one command

```bash
git clone https://github.com/renchris/claude-session-search.git
cd claude-session-search
./install.sh
```

<details>
<summary><b>What the installer does</b> (idempotent — safe to re-run)</summary>

<br>

1. **Symlinks** hooks and `bin/` into `~/.claude/` (edits in the repo go live immediately)
2. **Registers** `SessionEnd` + `SessionStart` hooks in `settings.json` (backs it up first)
3. **Backfills** every existing session via a 7-phase scan
4. **Tags** sessions with regex and builds the FTS5 index
5. **Adds** `~/.claude/bin` to your `PATH`
6. **Schedules** two background jobs (macOS `launchd`): a weekly backfill and a 60-second sweep. On other systems the installer skips this step and says so
7. **Pre-compiles** the Python engine for faster cold starts

`./install.sh --help` lists its options and exit codes and changes nothing.

</details>

**Requires** `sqlite3` (with FTS5 — the macOS default), `python3` ≥ 3.10, and `jq`.
**Optional** (each unlocks a feature, none are required):

| Package | Unlocks |
|---|---|
| `fzf` | Interactive picker (`--fzf`) |
| `rapidfuzz` | Typo-tolerant fuzzy correction |
| `anthropic` | Haiku tagging + LLM query expansion |
| `yake` | Multi-word key-phrase extraction |

**Update:** `git pull && ./install.sh`  ·  **Uninstall:** `./uninstall.sh` (preserves your database). `./uninstall.sh --dry-run` shows the plan first, and `./uninstall.sh --help` lists its options.

---

## Search by keyword, date, @project, or #tag

```bash
claude-search "bottle menu"                 # Keyword search
claude-search "monitoring last week"        # Temporal: "yesterday", "march 1", "last 3 days"
claude-search "@reso sync"                  # Inline project filter
claude-search "#auth #bugfix login"         # Inline tag filters (combinable)
claude-search --since 2026-03-01 "rum"      # Explicit date range; --until sets the end
claude-search --project reso "sync"         # Option-style project filter
claude-search --deep-search "cold start"    # Also search inside conversation turns
claude-search --json "floor plan"           # One JSON document for scripting
```

**Natural-language dates work out of the box.** `yesterday`, `today`, `this week`, `last week`, `last 3 days`, `last 2 months`, `march 1`, and ISO dates (`2026-03-01`) are extracted from the query and turned into a date filter automatically.

**Abbreviations expand before the search runs.** `rum` → `monitoring, cloudwatch, metrics, observability`; `db` → `database, turso, sqlite`; `ws` → `websocket, soketi, pusher`. The dictionary ships with **66 terms across 289 expansions** and is editable in [`synonyms/default.json`](synonyms/default.json).

---

## Resume the right session with one keystroke

```bash
claude-search --fzf "migration"
```

<p align="center">
  <img src="assets/fzf-demo.gif" alt="The claude-search fzf picker: typing a query narrows the ranked results live while the right-hand preview pane updates per selection, ending with Enter to resume the chosen session." width="840">
</p>

Pipes ranked results into an [`fzf`](https://github.com/junegunn/fzf) picker with a live preview pane that re-searches as you type:

| Key | Action |
|---|---|
| <kbd>Enter</kbd> | Resume the session (`claude --resume <id>`) |
| <kbd>Ctrl-Y</kbd> | Copy the session ID to the clipboard |
| <kbd>Ctrl-O</kbd> | Open the project directory |
| *type* | Live re-search as you type |

Prefer the keyboard from a plain search? `claude-search --resume 2` resumes the 2nd result of your last search — no need to retype the query.

---

## See exactly why every result ranked where it did

Search is a black box in most tools. Here it isn't — `--explain` shows the matched columns, the strategy that fired, the BM25 score, and every synonym the query expanded into:

```console
$ claude-search "rum latency" --explain

   1  RUM Analysis: Friday Event Latency Report
       5mo ·   10 msgs · audit, docs, events, monitoring, +1    c1d32436
      ┊ 'rum' → summary, first_prompt, keywords
      ┊ 'latency' → summary, first_prompt, keywords
      ┊ 'monitoring' → first_prompt, tags, keywords
      ┊ Strategy: NEAR proximity · BM25: 14.77
      ┊ Expanded: cloudwatch, metrics, monitoring, observability, real user monitoring
```

<details>
<summary><b>The ranking model</b> — BM25 relevance, recency, and conversation depth</summary>

<br>

Every result gets an **additive score** so no single signal can dominate:

```
score = 0.60 · BM25      (text relevance, normalized across the result set)
      + 0.15 · recency   (Gaussian decay, 30-day half-life — a gentle tiebreaker)
      + 0.10 · depth     (message-count sweet spot: 10–100 msgs rank highest)
      + 0.15 · BM25 × recency   (interaction: reward results that are both)
```

BM25 itself is **column-weighted across 11 indexed fields** — a hit in the AI-written summary counts far more than a hit in a shell command:

| Column | Weight | Why |
|---|--:|---|
| `summary` | 12.0 | Claude-generated description — the strongest signal |
| `search_aliases` | 8.0 | LLM-generated alternate phrasings of the session |
| `tags` | 5.0 | Semantic categories (`auth`, `monitoring`, …) |
| `files_changed` | 3.5 | File paths touched during the session |
| `first_prompt` | 3.0 | Your opening message |
| `keywords` | 3.0 | Auto-extracted technical terms |
| `context_text` | 2.5 | Your first few messages from the transcript |
| `assistant_text` | 1.5 | Claude's responses |
| `commands_run` | 1.0 | Shell commands executed |
| `project_name` | 0.5 | Broad project match |

</details>

<details>
<summary><b>The query pipeline</b> — 5 fallback strategies, widening only when results are sparse</summary>

<br>

```mermaid
flowchart TD
    A["query: slide-out panel last week"] --> B["normalize · strip @project #tag"]
    B --> C["temporal extraction → date range"]
    C --> D["tokenize · stopwords · verb + synonym expansion"]
    D --> E["fuzzy typo correction"]
    E --> F{"NEAR · within 5 words"}
    F -->|sparse| G{"AND · all terms"}
    G -->|sparse| H{"OR · any term"}
    H -->|sparse| I{"core terms only"}
    I -->|sparse| J{"prefix match"}
    F -->|enough hits| K["BM25 · 11 weighted columns"]
    G -->|enough hits| K
    H -->|enough hits| K
    I -->|enough hits| K
    J --> K
    K --> L["additive score:<br/>relevance + recency + depth"]
    L --> M["ranked results"]
```

The pipeline tries the **most precise** strategy first and only widens when a strategy returns fewer than 3 hits — so exact phrase matches win, but a fuzzy or partial query still finds something. Two safety nets sit underneath:

- **LLM fallback** — if fewer than 3 results come back, Haiku rewrites the query into 4 interpretations, each searched and merged via Reciprocal Rank Fusion *(needs `ANTHROPIC_API_KEY`)*. In the `--fzf` picker only the initial query can use it; the as-you-type refresh never does, so keystrokes don't reach the API.
- **Deep search** (`--deep-search`) — also queries a turn-level chunk index (5-turn sliding windows), so a phrase buried mid-conversation is findable even when the summary never mentions it.

</details>

---

## The index maintains itself

You never run an indexer by hand. Hooks capture sessions as they happen; a sweep daemon catches anything the hooks miss; a backfill seeds history and self-heals weekly.

```mermaid
flowchart LR
    subgraph feed["Indexing · fully automatic"]
        direction TB
        H1["SessionEnd hook<br/>~200ms"]
        H2["SessionStart hook"]
        H3["Sweep daemon<br/>every 60s"]
        BF["Backfill<br/>7-phase scan"]
    end
    DB[("SQLite FTS5<br/>session-index.db")]
    Q["claude-search 'query'"]
    R["Ranked results"]
    H1 --> DB
    H2 --> DB
    H3 --> DB
    BF --> DB
    Q --> DB --> R
```

<details>
<summary><b>Where the data comes from</b> — six sources, highest quality wins</summary>

<br>

When two sources describe the same session, the richer one overwrites the thinner one:

| Source | Provides | Role |
|---|---|---|
| `sessions-index.json` | AI summaries, message counts, branches, timestamps | **Richest** — wins on conflict |
| `SessionEnd` hook | The just-finished session + enriched transcript data | Live capture (`< 200 ms`) |
| `SessionStart` hook | The session you're opening now | Live capture |
| 60-second sweep | New/changed transcripts the hooks missed | Self-healing (`< 500 ms` idle) |
| `history.jsonl` | User prompts, project paths | Gap fill |
| Legacy entries | Pre-`sessionId` history grouped by project + time gaps | Synthetic IDs |

</details>

### Tag sessions for topic-based recall

Tags like `database`, `monitoring`, `bottle-service`, `slide-out` are indexed and weighted, so a search for a *topic* surfaces sessions whose summaries never used your exact words.

```bash
# Free, instant — 42 regex patterns (24 technology · 10 task-type · 8 domain)
session-index-tag.py --regex-only

# Higher accuracy via Claude Haiku — ~95% accurate, ~$0.09 for 650 sessions
export ANTHROPIC_API_KEY="$(<your secret manager's read command>)"
session-index-tag.py --limit 650
```

Each run tags up to `--limit` untagged sessions (default 100), and prints the exact command for the rest when more remain.

---

## Measure and tune your own search

Every search is logged locally, so you can see what's slow and what's failing:

```console
$ claude-search --analytics

  ╭────────────────────────────────────────────────────────╮
  │ Search Analytics                          531 searches │
  ├────────────────────────────────────────────────────────┤
  │ Avg latency                                      4.9ms │
  │ Zero-result                             18.5% (98/531) │
  ╰────────────────────────────────────────────────────────╯

  Top Queries
  ────────────────────────────────────────────────────────
    37×  bottle service menu                 avg 10 results
    14×  slide-out panel                     avg  6 results
     8×  floor plan                          avg  9 results

  Failed Queries  (tuning targets)
  ────────────────────────────────────────────────────────
     3×  xyznonexistent
```

`claude-search --stats` shows the complementary view — total sessions, tagged count, and a breakdown by source. `--analytics --fails` lists only zero-result queries, the exact set worth adding synonyms for.

---

## Every layer degrades gracefully

No optional dependency is load-bearing. Remove any one and search still works — just with one fewer enhancement.

| If this is unavailable | Fallback | What you lose |
|---|---|---|
| Haiku API key | Regex-only tagging | Slightly less precise tags |
| `rapidfuzz` | Skip fuzzy correction | Typo tolerance (synonyms still cover most) |
| `anthropic` SDK | Raw HTTP, or skip LLM expansion | Nothing, or the LLM query fallback |
| `sessions-index.json` | Rebuild from transcripts + `history.jsonl` | Some per-session metadata |
| `fzf` | Plain ranked text output | The interactive picker |
| `yake` | Simpler keyword extraction | Multi-word key phrases |

---

## Customize

**Add domain synonyms** for better recall — edit [`synonyms/default.json`](synonyms/default.json):

```json
{ "term": "k8s", "expansions": ["kubernetes", "cluster", "pod", "deployment"], "category": "infra" }
```

Then reload the table with `./scripts/session-index-backfill.sh`.

<details>
<summary><b>Command reference</b></summary>

<br>

| Option | Effect |
|---|---|
| `--fzf` | Interactive picker with live re-search |
| `--resume <SESSION>` | Resume a session by full ID, or by result number (with a query, or from the last search) |
| `--explain`, `--no-explain` | Show match attribution, strategy, BM25, and expansions |
| `--deep-search`, `--no-deep-search` | Also search within conversation turns |
| `-s`, `--since <TIME>` | Only sessions after this time: ISO 8601 or relative (`7d`, `12h`). A date with no offset is UTC |
| `-u`, `--until <TIME>` | Only sessions before this time; works on its own |
| `-p`, `--project <NAME>` | Filter by project |
| `--min-msgs <NUMBER>` | Minimum message count (default 0) |
| `-n`, `--limit <NUMBER>` | Max results (default 10, max 200) |
| `--json` | One JSON document (below) |
| `--stats` | Index statistics |
| `--analytics`, `--analytics --fails` | Search-log analytics; `--fails` shows only zero-result queries |
| `--preview <SESSION>` | Preview a single session |
| `--no-llm` | Never send the query to the Anthropic API |
| `--no-color` | Turn off color |
| `--non-interactive` | Never prompt |
| `-d`, `--debug` | Print debug details on stderr |
| `-v`, `--version` | Print the version |
| `-h`, `--help` | Show help |

`--after` and `--before` still work and warn; use `--since` and `--until`.

**`--json` prints one document.** A search gives `{"sessions": [...], "pagination": {"next": null}}`, where each session has `rank`, `session_id`, `project_name`, `project_path`, `git_branch`, `created_at`, `modified_at`, `message_count`, `summary`, `tags`, `score` and `workflow_path`. `--preview` gives `{"session": {...}}`, `--stats` gives `{"stats": {...}}` and `--analytics` gives `{"analytics": {...}}`. A failure prints nothing on stdout and one JSON line on stderr.

`--format json` is deprecated: it keeps its older bare array and prints a warning on stderr. It has no removal date. Piped search output without `--json` is the same table without color, so scripts should use `--json`.

</details>

<details>
<summary><b>Exit codes</b></summary>

<br>

| Command | Code | Meaning |
|---|---|---|
| `claude-search` | 0 | Success or an empty result |
| | 1 | Failure, including a missing engine, `fzf` or `claude` |
| | 2 | Usage error or missing input |
| | 130 | Canceled |
| `./install.sh` | 0 | Success |
| | 1 | A required step failed |
| | 2 | Usage error |
| `./uninstall.sh` | 0 | Success |
| | 1 | `settings.json` could not be edited, or another step failed |
| | 2 | Usage error |
| `session-index-backfill.sh` | 0 | Success, or skipped by `--if-idle` |
| | 1 | Failure, including a missing prerequisite or file |
| | 2 | Usage error |
| | 5 | The database stayed locked; a re-run is safe |
| | 129, 130, 143 | Stopped by HUP, INT or TERM |
| | Other | A failed step's own exit code |
| `session-index-chunk.py` | 0 | Success, including skipped sessions |
| | 1 | Failure, a missing database, or a bare invocation |
| | 2 | Usage error |
| | 130 | Interrupted |
| `session-index-tag.py` | 0 | Success |
| | 1 | Failure, including a held lock or a missing key under `--retag-summaries`; under `--json`, also when any session failed or was not attempted |
| | 2 | Usage error |
| | 130 | Interrupted after the work window |

</details>

<details>
<summary><b>Environment variables</b></summary>

<br>

An empty value is the same as unset unless the row says otherwise. Each is read on every run and nothing is saved.

| Variable | Effect | Precedence |
|---|---|---|
| `SESSION_SEARCH_NO_LLM` | Any non-empty value does what `--no-llm` does | Either one turns the API off |
| `SESSION_SEARCH_DEBUG` | Any non-empty value does what `--debug` does | Either one turns debug on |
| `SESSION_SEARCH_GUIDANCE_DISABLED` | Any non-empty value hides next-step tips | Tips also need an interactive terminal |
| `SESSION_SEARCH_ACCESSIBLE` | `1` prints plain glyphs and refuses `--fzf`; any other value is off | Applies whatever the terminal supports |
| `NO_COLOR` | Any non-empty value turns off color | Below `--no-color`, above `FORCE_COLOR` |
| `FORCE_COLOR` | Keeps color tint on `Warning:` and `Error:` lines in plain output; `0` is off | Below `NO_COLOR` |
| `ANTHROPIC_API_KEY` | Turns on Haiku tagging and query expansion. Read from the environment only and never stored | `--regex-only` and `--no-llm` win |
| `SESSION_INDEX_BUSY_TIMEOUT` | How long backfill waits on a locked database, in milliseconds | Default is 60000 |

</details>

<details>
<summary><b>Glossary</b></summary>

<br>

| Term | Meaning |
|---|---|
| Session | One Claude Code run, identified by its full session ID. Help writes it as `<SESSION>`; output labels it `Session ID` |
| Result | One ranked row of a search |
| Index | The database at `~/.claude/session-index.db` |
| Transcript | The JSONL file Claude Code writes for a session |
| Chunk | A window of turns from a transcript, searched by `--deep-search` |
| Tag | A topic label on a session, such as `database` or `monitoring` |
| Workflow result | A `wf_*` row for a workflow's result file. It can be previewed but not resumed |

</details>

<details>
<summary><b>Behavior changes</b> — for scripts written against older versions</summary>

<br>

- Usage errors now exit 2 and print only to stderr.
- A preview of an unknown ID exits 1.
- `--deep`-style abbreviations are rejected. Spell options in full.
- `claude-search help` shows help. `claude-search -- help` searches for the word.
- Canceling the picker exits 130.
- `--fzf` refuses non-interactive runs, including under `CI` or `CLAUDECODE`.
- Zero-result text and tips now go to stderr, so piped stdout holds only results.
- A bad `--since` value exits 2 before anything runs, on both `claude-search` and `session-index-backfill.sh`.
- `./install.sh --help` and `./uninstall.sh --help` print help. They used to run the install or the uninstall, whatever the arguments.
- `--format json` warns on stderr; its stdout is unchanged.

</details>

<details>
<summary><b>File layout</b> — the repo symlinks into <code>~/.claude/</code></summary>

<br>

All installed files are symlinks, so a `git pull` updates your live install instantly.

```
claude-session-search/                      ~/.claude/
├── hooks/
│   ├── session-index-end.sh        ──────→ hooks/session-index-end.sh     (SessionEnd)
│   ├── session-index-start.sh      ──────→ hooks/session-index-start.sh   (SessionStart)
│   ├── session-index-sweep.sh      ──────→ hooks/session-index-sweep.sh   (60s daemon)
│   └── lib/session-index-helpers.sh ─────→ hooks/lib/…
├── bin/
│   ├── claude-search               ──────→ bin/claude-search             (the CLI)
│   └── session-search.py           ──────→ bin/session-search.py         (the engine)
├── scripts/
│   ├── session-index-backfill.sh           (7-phase history scan)
│   ├── session-index-tag.py                (regex + Haiku tagging)
│   └── session-index-chunk.py              (turn-based chunks for --deep-search)
├── synonyms/default.json                   (66 terms · 289 expansions)
├── config/*.plist                          (launchd: weekly backfill + 60s sweep)
├── install.sh  ·  uninstall.sh
                                            └── session-index.db          (SQLite FTS5)
```

</details>

---

## License

[MIT](LICENSE)
