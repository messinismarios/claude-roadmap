# ftero-scripts

A headless Claude Code runner that drives any repo's `specs/roadmap.md` to completion,
phase by phase, unattended. Designed to be cloned or pulled **once** and reused,
unmodified, across every repo you want it to run in — all repo-specific knowledge lives
in a small config file that repo owns and commits, not in this script.

Pull updates here and every repo using it picks up the new version the next time it
runs (whatever it's checked out at). The scripts themselves never need to be copied
into a target repo.

## What it does

For each `## Phase N` heading in the target repo's roadmap file (a "unit"), it runs a
five-stage pipeline, each stage its own fresh-context, zero-memory Claude turn:

1. **PLAN** — decides whether the phase is small enough for one turn, or should be
   split into several independently-implementable tasks. Written once to
   `specs/.roadmap-tasks/<unit>.tasks`; never re-planned on resume.
2. **IMPLEMENT** (per task) — does the work, commits it. Ends in one of three states:
   `COMPLETE`, `PARTIAL` (everything done except a deliverable that genuinely can't be
   done yet — a later phase's dependency, or an operator-only action), or `FAILED`
   (truly blocked).
3. **GATE** (per task) — plain bash, no LLM: independently re-runs the repo's own
   `GATE_CMD` (see [Configuration](#configuration)) outside the implementer's control,
   so a turn can never claim a green check it never actually got. Skipped entirely if
   the repo has no `GATE_CMD` configured.
4. **REVIEW** (per task) — a second, independent fresh-context turn that did not write
   the code, briefed to assume a deliverable might be satisfied in letter while
   violating a constraint stated elsewhere in the roadmap, spec files, or the repo's
   own `CROSS_CUTTING_CONSTRAINTS`. Reports `REVIEW_OK` or `REVIEW_ISSUES`; issues get
   fed into a fresh implement retry (bounded by `MAX_REVIEW_CYCLES`).
5. **DOCUMENT** (per unit, once every task clears the above) — optional, off by
   default (see `WRITE_QA_DOC` below). When enabled, writes `specs/qa/<unit-slug>.md`:
   what shipped, how, what was deferred, and a step-by-step manual testing checklist
   for a human with no other context.

A unit is marked complete (progress file + a `**(complete)**` marker appended to its
own roadmap heading + a commit) once every task clears review, whether or not the
QA document was written.

**Also handles, so you can leave it running unattended overnight:**

- Quota/rate-limit hits — waits and retries, doesn't burn your retry budget on them.
- Real failures — retries a bounded number of times, then stops for manual review
  rather than looping forever.
- A crash/kill mid-task — the next run resumes exactly where it left off (in-flight
  retry counters and all), never redoing already-cleared work.
- Phone notifications via [ntfy.sh](https://ntfy.sh) on every meaningful transition, if
  configured.
- Live steering from another terminal while a turn is running (see
  [Commands](#commands) below) — stop, stop-after-task, stop-after-phase, retry, or
  inject a message into the currently-running turn.
- A resume document (`specs/ROADMAP-RESUME.md`) rewritten on every stop, for any
  reason, with everything needed to pick back up with no other context.
- A cost log (`specs/.roadmap-cost`) — every turn's `total_cost_usd`, so spend is never
  invisible.

## Commands

Run everything from the **root of the target repo** (the one with `specs/roadmap.md`),
pointing at wherever you have this repo checked out:

```bash
# start (or resume) a run
bash /path/to/ftero-scripts/run-roadmap.sh

# from another terminal, while it's running:
bash /path/to/ftero-scripts/roadmap-ctl.sh status
bash /path/to/ftero-scripts/roadmap-ctl.sh stop                 # wrap up the current turn, then exit cleanly
bash /path/to/ftero-scripts/roadmap-ctl.sh stop-after-task       # finish the in-flight task, then stop
bash /path/to/ftero-scripts/roadmap-ctl.sh stop-after-phase      # finish the in-flight phase, then stop
bash /path/to/ftero-scripts/roadmap-ctl.sh cancel-stop-after     # cancel a pending stop-after-task/phase
bash /path/to/ftero-scripts/roadmap-ctl.sh retry                 # skip a quota/backoff/nudge-pacing wait right now
bash /path/to/ftero-scripts/roadmap-ctl.sh pivot "text to send into the running turn"
```

On Windows, use `run-roadmap.bat` / `roadmap-ctl.bat` instead of typing `bash ...`
directly in PowerShell/cmd — see the comment at the top of each file for why (the
`bash` on most Windows PATHs is a WSL shim, not Git Bash, and silently fails).

## Setup for a new repo

1. In the target repo, create `scripts/roadmap.config.sh` by copying
   [`roadmap.config.example.sh`](./roadmap.config.example.sh) from this repo.
2. Fill in at minimum `REPO_DESCRIPTION` and `LAST_AUTOMATABLE_PHASE` (required —
   the script refuses to start without them). Fill in whichever optional variables
   apply; see the comments in the example file for all of them.
3. Commit `scripts/roadmap.config.sh` to the target repo.
4. Make sure the target repo's roadmap file matches the [structure](#roadmap-structure-a-target-repo-needs)
   below.
5. Run it: `bash /path/to/ftero-scripts/run-roadmap.sh` from the target repo's root.

## Configuration

Everything in `scripts/roadmap.config.sh` (in the **target** repo, not this one) is a
plain shell variable assignment, sourced directly by `run-roadmap.sh`.

| Variable | Required | Purpose |
|---|---|---|
| `REPO_DESCRIPTION` | **yes** | One paragraph describing the repo's shape, injected into every turn's opening prompt. The single biggest lever over turn quality. |
| `LAST_AUTOMATABLE_PHASE` | **yes** | Highest phase number the script may run unattended; phases beyond it are left alone. |
| `ROADMAP_FILE` | no (default `specs/roadmap.md`) | Path to the roadmap file. |
| `SPEC_FILES` | no (default empty) | Space-separated extra spec files every turn should also read. |
| `INSTALL_CMD` | no (default empty) | Shell command to install deps before the gate. |
| `GATE_CMD` | no (default empty — gate skipped) | Shell command the deterministic verification gate runs after every implement turn. |
| `CROSS_CUTTING_CONSTRAINTS` | no (default empty) | This repo's own hard rules a narrowly-scoped task could quietly violate; fed to the reviewer. |
| `SHARED_MODULE_SYNC_NOTE` | no (default empty) | Note about a shared module that must move together with its consumers in the same commit. |
| `NTFY_TOPIC` | no (default empty — disabled) | ntfy.sh topic for phone push notifications. |
| `NTFY_VERBOSE` | no (default `false`) | Ping the phone on every notification, not just major transitions. |
| `MAX_TURN_BUDGET_USD` | no (default empty — no cap) | Per-turn `--max-budget-usd` passed to `claude`. |
| `WRITE_QA_DOC` | no (default `false`) | Run the DOCUMENT stage and write `specs/qa/<unit-slug>.md` per unit. Can also be set per-run as an env var, e.g. `WRITE_QA_DOC=true bash run-roadmap.sh`. |
| `RETRY_WAIT_SECONDS`, `MAX_NON_QUOTA_RETRIES`, `MAX_REVIEW_CYCLES`, `UNIT_TIMEOUT_SECONDS`, `BACKGROUND_WAIT_SECONDS`, `MAX_BACKGROUND_NUDGES`, `POLL_INTERVAL_SECONDS`, `STOP_GRACE_SECONDS` | no | Retry/timeout tuning; sane defaults, see the example file. |

Override which config file gets loaded with `$ROADMAP_CONFIG_FILE` or a first
positional argument, if you don't want the default `scripts/roadmap.config.sh`:

```bash
bash /path/to/ftero-scripts/run-roadmap.sh path/to/other-config.sh
```

## Roadmap structure a target repo needs

- **`specs/roadmap.md`** (or wherever `ROADMAP_FILE` points), with phases as H2
  headings matching `## Phase N — Title` (a trailing `**(status)**` marker is fine and
  is exactly what the script appends on completion). Headings without a number right
  after "Phase" (e.g. `## Phase sequence`) are never treated as units, so free-standing
  diagrams/sections are safe.
  - Optional: `### N.M Section title` H3 sub-headings inside a phase, if you want a
    phase pre-split into sections rather than letting the PLAN stage decide. Most
    roadmaps don't need this — it's picked up automatically if present.
  - Deliverables should be prose, not `- [ ]` checkboxes — the script never edits
    individual lines, only appends a `**(complete)**` marker to a phase's own heading
    line and appends new content strictly after the file's original end (so line
    numbers already parsed never shift, even mid-run).
- **`scripts/roadmap.config.sh`** — see [Setup](#setup-for-a-new-repo) above.
- A git repository — every stage's bookkeeping (progress file, task plans, QA docs,
  cost log, resume doc) is committed directly by the script as it goes.

Everything else the script creates lives under `specs/` in the target repo and should
be committed there (except `.roadmap-runtime/`, which is ephemeral — gitignore it):

| Path | What | Committed? |
|---|---|---|
| `specs/.roadmap-progress` | Completed unit/task ids, one per line | yes |
| `specs/.roadmap-tasks/` | Each unit's task breakdown + start-HEAD sha | yes |
| `specs/qa/<unit-slug>.md` | DOCUMENT-stage output, one per completed unit | yes |
| `specs/.roadmap-run.log` | Full raw turn transcripts | **no** — gitignore it |
| `specs/ROADMAP-RESUME.md` | Rewritten on every stop, for any reason | yes |
| `specs/.roadmap-cost` | Append-only `<timestamp>\|<label>\|<usd>` cost log | yes |
| `.roadmap-runtime/` | Control file, live status, per-turn scratch dirs | **no** — gitignore it |

Add this to the target repo's `.gitignore`:

```
.roadmap-runtime/
specs/.roadmap-run.log
```

## Requirements

`claude` CLI and `node` on `PATH`, `git`, `curl`. Anything the target repo's own
`INSTALL_CMD`/`GATE_CMD` need (a package manager, `docker`, `terraform`, ...) is that
repo's concern, not this tool's.

## Safety note

Every Claude turn runs with `--permission-mode bypassPermissions`: full, unattended
tool access with no approval prompts. That's what makes a hands-off run possible, but
it means any turn can do anything a normal `claude` session could do to the target
repo. The reviewer turn is told in its prompt not to edit or commit code — that's a
prompt-level instruction, not a sandboxed guarantee. Only leave this running against a
repo/branch you're fine being modified without review, and don't set `GATE_CMD` to
anything that provisions real paid resources or touches production infrastructure.
