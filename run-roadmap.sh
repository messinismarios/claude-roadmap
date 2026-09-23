#!/usr/bin/env bash
#
# run-roadmap.sh -- part of ftero-scripts (github.com/messinismarios/ftero-scripts)
#
# Drives Claude Code (headless mode) through a target repo's specs/roadmap.md
# in a fresh zero-context invocation per step of work, waits and retries on
# quota/rate-limit hits, gives up after real failures, and pushes an ntfy.sh
# notification on every transition so you can leave it running overnight and
# check your phone.
#
# This script is repo-agnostic -- it is meant to be cloned/pulled ONCE and
# reused, unmodified, across every repo you want to drive a roadmap in. All
# repo-specific knowledge (what kind of repo it is, how to verify a change,
# which phase to stop at, cross-cutting rules a task must not quietly break)
# comes from a small config file the TARGET repo owns and commits -- see
# CONFIG LOADING below and roadmap.config.example.sh in this same repo for
# every variable and what it does. See README.md for full setup instructions.
#
# Run it from the ROOT of the target repo (the repo whose specs/roadmap.md
# you want driven), e.g.:
#   cd ~/code/some-product && bash ~/code/ftero-scripts/run-roadmap.sh
# It expects that repo to be a single git repository containing its own
# specs/roadmap.md and a committed scripts/roadmap.config.sh (see below).
#
# UNIT OF WORK: a "unit" is one ## Phase N section of the target repo's
# roadmap file. Most roadmaps have no ### N.M sub-sections inside a phase, so
# every phase runs as one flat unit -- it is the PLAN stage below that
# decides whether a large phase needs to be split into several
# separately-implemented tasks. The unit parsing below still understands
# ### N.M section headers if a roadmap ever grows them, so adding sections
# later needs no script change.
#
# PER-UNIT PIPELINE: each unit runs through five stages, each its own
# fresh-context Claude turn (except the deterministic gate, which is plain
# bash -- no LLM call):
#   1. PLAN   -- reads the unit, decides whether it is small enough for one
#                focused implementation turn or genuinely bundles several
#                mostly-independent pieces of work that deserve separate
#                turns. Either way it writes its decision as a task list to
#                TASKS_DIR/<unit>.tasks (one line per task; a single line
#                means no split). This file is the durable plan -- on resume
#                it is loaded instead of re-planned.
#   2. IMPLEMENT (per task) -- does the work for exactly one task, commits to
#                the repo. Ends with one of FOUR outcomes: COMPLETE
#                (everything done), PARTIAL (everything done except one or
#                more deliverables that genuinely depend on a phase not yet
#                built or an operator-only action -- named verbatim so the
#                roadmap bookkeeping step can record exactly that, see
#                TRACKING #3 below), NEEDS_INPUT (genuinely blocked on
#                something only the human operator can provide -- a real
#                API key/secret, a third-party account or app registration,
#                a business/legal decision -- where skipping or deferring it
#                would leave the result materially worse, not just
#                unverified. Unlike PARTIAL, this is NOT a "continue and
#                note it" situation: it halts the entire run immediately, see
#                NEEDS_INPUT HANDLING below), or FAILED (truly blocked,
#                retried then eventually stops the run). PARTIAL still goes
#                through GATE and REVIEW like a normal completion -- it is
#                not a lower bar, just an honest one, and the reviewer is
#                specifically asked to judge whether the deferral is
#                legitimate.
#   3. GATE   (per task) -- plain bash, no LLM: independently re-runs the
#                target repo's own verification command (GATE_CMD from its
#                config -- lint/typecheck/test, terraform validate, whatever
#                that repo defines) itself. This does not trust the
#                implementer's self-report -- it is the same command the
#                implement prompt already asks Claude to run, just re-run
#                outside the implementer's control so a turn cannot claim a
#                green check it never actually got green. If the repo's
#                config leaves GATE_CMD empty, this stage is a no-op. A gate
#                failure is treated exactly like a failed implement attempt
#                (same retry budget, findings fed back in).
#   4. REVIEW (per task) -- a second, independent fresh-context Claude turn
#                that did not write the code. It is told explicitly to
#                assume the implementer may have satisfied a deliverable's
#                literal wording while violating a hard constraint stated
#                elsewhere in the roadmap, its spec files, or the repo's own
#                CROSS_CUTTING_CONSTRAINTS (config-supplied -- a repo's own
#                hard, easy-to-quietly-break rules, e.g. "never propose
#                replacing the production database" or "this endpoint must
#                keep serving with the cache down") -- and a task narrowly
#                scoped to one phase can easily satisfy its own checklist
#                while quietly breaking one of those. The reviewer reads the
#                actual diff, not the implementer's commit message, and is
#                instructed not to edit or commit code itself -- it only
#                reports REVIEW_OK or REVIEW_ISSUES: <findings>. Findings get
#                fed into a fresh IMPLEMENT retry (bounded by
#                MAX_REVIEW_CYCLES); exhausting that budget stops the whole
#                run for manual review, same as exhausting the ordinary
#                failure retry budget does.
#   5. DOCUMENT (per unit, once every task has cleared IMPLEMENT->GATE->
#                REVIEW) -- OPTIONAL, off by default (see WRITE_QA_DOC below):
#                one more fresh-context turn, reading this unit's full diff
#                (every task's commits combined) plus the roadmap and its
#                spec files, that writes a single specs/qa/<unit-slug>.md
#                file: what shipped, how it was built, what files changed,
#                what was deferred and why, and a step-by-step MANUAL TESTING
#                CHECKLIST a human with no other context can follow to
#                actually exercise everything the unit touched. This is the
#                primary artifact a human reviewer reads -- see
#                build_document_prompt below. A unit becomes "complete"
#                (progress file + roadmap.md heading marker + commit)
#                whether or not this stage ran -- set WRITE_QA_DOC=true (in
#                the repo's roadmap.config.sh, or per-run as an env var) to
#                enable it.
#
# NEEDS_INPUT HANDLING: when an implement turn reports NEEDS_INPUT (see
# stage 2 above), this script does NOT retry, does NOT defer-and-continue
# like PARTIAL, and does NOT move on to another task or phase. It stops the
# whole run immediately (same STOP-machinery as an exhausted retry budget --
# see stop_run), pings the phone via ntfy regardless of NTFY_VERBOSE, and
# writes what's needed and why into RESUME_DOC in its own clearly-marked
# section. The task itself is NOT marked complete, so re-running the script
# after providing whatever was requested (a secret in Dokploy's encrypted
# store, a completed account registration, a decision recorded wherever this
# repo's conventions say it belongs, etc.) retries that exact task from
# scratch. This exists because unattended automation must never quietly
# ship degraded work, guess at a placeholder for a real credential, or
# silently defer something whose absence would actually hurt the result --
# those cases need a human in the loop before another dollar or another
# turn is spent building on top of a guess.
#
# INTERACTIVITY: while a turn is running, three commands can be sent from
# another terminal via `scripts/roadmap-ctl.sh` (see that file):
#   scripts/roadmap-ctl.sh stop            -- end the run: the current turn
#           is told to wrap up immediately, a resume document is written
#           (see RESUME DOCUMENT below), and the script exits. Re-running it
#           later resumes exactly where this left off.
#   scripts/roadmap-ctl.sh retry           -- skip whatever wait is
#           currently happening (a quota/rate-limit backoff, a failure
#           backoff, or the pacing pause before nudging a turn that seems to
#           be waiting on a background command) and retry right now. Has no
#           effect if a turn is actively running rather than waiting.
#   scripts/roadmap-ctl.sh pivot "<text>"  -- deliver a message into the
#           CURRENTLY RUNNING turn without stopping it, the same way typing
#           into a normal interactive `claude` session would: the turn reads
#           it and works it into whatever it's already doing, mid-turn, then
#           carries on. If nothing is running right now (between stages, or
#           mid-wait), it is queued and delivered as the opening context of
#           the next turn instead.
#   scripts/roadmap-ctl.sh stop-after-task  -- let whatever's in flight
#           finish completely (current implement/gate/review retry loop,
#           uninterrupted), then stop right after that task passes review --
#           before the next task, or before this unit's DOCUMENT stage if it
#           was the last task. Unlike `stop`, nothing is interrupted and
#           there is no in-flight retry state to worry about, since it only
#           ever fires between turns. See maybe_stop_after/pending_stop_after.
#   scripts/roadmap-ctl.sh stop-after-phase -- same idea, one level up: let
#           the current unit run all the way through its DOCUMENT stage and
#           record_unit_complete, then stop before the next unit's PLAN turn.
#   scripts/roadmap-ctl.sh cancel-stop-after -- cancel a pending
#           stop-after-task/phase before it's reached.
#   scripts/roadmap-ctl.sh status          -- print what the run is
#           currently doing (and any pending stop-after / spend so far),
#           read from RUNTIME_DIR/status.
# This works by running each turn as `claude -p --input-format stream-json
# --output-format stream-json`, fed from a growing file tailed into it (see
# run_claude_turn below) rather than the older one-shot `claude -p "<prompt>"`
# invocation -- the stdin stream is kept open for the life of the turn, so
# new messages (nudges, /pivot text, an operator stop notice) can be injected
# into an in-progress turn exactly like typing into an interactive session.
# A plain FIFO connected directly to `claude`'s stdin was tried first and
# does NOT work reliably for this on Windows/Git Bash (the read side gets
# EOF before a writer connects, producing zero output) -- `tail -f` piped in
# over an ordinary anonymous shell pipe does, and is what's used here.
#
# RESUME DOCUMENT: whenever this script stops, for ANY reason -- a clean
# finish, /stop, a timeout, an exhausted retry budget, an uncaught error, an
# interrupt (Ctrl-C) -- an EXIT trap (see on_exit/write_resume_doc) rewrites
# ${RESUME_DOC} with: what unit/task/stage it was on, why it stopped, the
# in-flight retry state (findings fed back, gate/review cycle counts) if it
# stopped mid-task, and a log tail -- everything a human (or the next run of
# this same script) needs to pick up with no other context. It is committed
# each time it changes, same as the other bookkeeping files. This is
# best-effort: it cannot fire after a hard external kill (a killed process,
# OOM, power loss) -- for that case, TASK_STATE_FILE (rewritten continuously
# during a task's retry loop, not just on exit) is what lets the *next* run
# resume the in-flight retry state without redoing already-exhausted
# attempts, independent of whether the trap ever got to run.
#
# TRACKING: completed work is recorded several ways so it's always clear
# what has and hasn't been done:
#   1. PROGRESS_FILE (specs/.roadmap-progress) -- one completed id per line:
#      a bare unit id (e.g. "1") once every task in it is done, and
#      "<unit>::<task-index>" for each individually-completed task before
#      that -- used by this script to resume mid-unit without re-running
#      finished tasks. A task that ended PARTIAL also appends one
#      "<unit>::<task-index>::DEFERRED::<item text>::<reason>" line per
#      deferred deliverable -- read back at unit-completion time so the
#      roadmap bookkeeping step (below) knows what to record as deferred
#      instead of silently marking the whole unit done.
#   2. TASKS_DIR/<unit>.tasks (specs/.roadmap-tasks/) -- the plan turn's task
#      breakdown for that unit, one line per task. Written once, never
#      rewritten; resume loads it instead of re-planning.
#      TASKS_DIR/<unit>.start-head -- the git HEAD sha captured the first
#      time this unit is encountered, before its plan turn even runs. Used
#      by the DOCUMENT stage to diff "everything this unit changed"
#      regardless of how many tasks it got split into or how many times the
#      run was resumed in between. Also written once, never rewritten.
#   3. specs/qa/<unit-slug>.md -- the DOCUMENT stage's output, one file per
#      completed unit, committed permanently. This is the file a human
#      actually reads; see stage 5 above. Only written when WRITE_QA_DOC=true
#      (default false -- the stage is skipped otherwise).
#   4. specs/roadmap.md itself -- once a unit completes, its own `## Phase N`
#      heading line gets a trailing "**(complete)**" marker (or
#      "**(complete -- N item(s) deferred -- see 'Roadmap automation notes'
#      at the end of this file)**" if anything was legitimately deferred, with
#      the detail appended in that section at the very end of the file).
#      roadmap.md's deliverables are prose bullets, not "- [ ]" checkboxes --
#      unlike a checkbox-tracked roadmap, this script never ticks individual
#      lines, and it never inserts new lines mid-document either: every edit
#      either appends text to the end of an existing header line (no line
#      count change, so cached line numbers for units later in the file stay
#      valid) or appends whole new lines strictly after the file's original
#      end (so nothing already parsed ever shifts). That constraint is why
#      deferred-item detail lives in one running section at the bottom of the
#      file instead of next to the phase it came from.
#   5. specs/.roadmap-cost -- append-only "<timestamp>|<label>|<usd>" log,
#      one line per turn attempt (whatever its outcome -- cost is incurred
#      either way), summed from the total_cost_usd the CLI already reports
#      on every stream-json result event. Read back by record_turn_cost/
#      sum_cost_file; shown in both the live status file and every resume
#      document so spend is never invisible.
# Steps 1-5 are committed directly by this script (not by Claude), separately
# from Claude's own implementation commits, so the bookkeeping history stays
# readable on its own.
#
# Requires: claude CLI on PATH, node on PATH (already a hard dependency of
# the claude CLI itself -- used here to build stream-json input messages and
# to parse stream-json output without adding a new dependency; see
# roadmap-stream-parse.js), git, curl. Anything the target repo's own
# INSTALL_CMD/GATE_CMD need (pnpm, docker, terraform, ...) is that repo's
# concern, declared in its own config.
#
# Windows gotcha: do NOT run this by typing `bash ...` in a plain PowerShell
# or cmd window. On most Windows installs, `bash` on PATH resolves to
# C:\Windows\System32\bash.exe -- the WSL launcher shim -- not Git Bash, and
# if your default WSL distro isn't a full Linux install (e.g. it's the
# docker-desktop distro), you'll get:
#   WSL (12 - Relay) ERROR: CreateProcessCommon:818: execvpe(/bin/bash) failed
# Instead, either double-click run-roadmap.bat (same folder), or run it from
# any Windows shell (it forwards to Git Bash's real bash.exe, sidestepping
# the WSL shim entirely):
#   path\to\ftero-scripts\run-roadmap.bat
#
# Before the first run, if the target repo's config sets NTFY_TOPIC, subscribe
# to notifications from your phone: install the ntfy app and subscribe to
# that topic (or just open https://ntfy.sh/<topic> in a browser).
#
# Every Claude turn (plan, implement, review, document) runs with
# --permission-mode bypassPermissions: Claude gets full, unattended tool
# access (shell, file edits, package installs) for that turn with no
# approval prompts. That's what makes a hands-off run possible, but it means
# any turn can do anything a normal `claude` session could do to the target
# repo. The reviewer is told in its prompt not to edit or commit code -- that
# is a prompt-level instruction, not a sandboxed guarantee (same trust model
# the script already uses for "don't edit the roadmap yourself" on implement
# turns). Only leave this running against a repo/branch you're fine with
# being modified without review.
#
set -uo pipefail

# ---------------------------------------------------------------------------
# WORKSPACE: this script is generic and lives outside the target repo, so
# WORKSPACE_DIR is wherever it's invoked FROM, not wherever the script itself
# lives (that's SCRIPT_DIR, used only to find this repo's own sibling files
# like roadmap-stream-parse.js). Run this from the target repo's root, or
# from anywhere inside it.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ---------------------------------------------------------------------------
# CONFIG LOADING: everything specific to the target repo lives in a config
# file it owns and commits (default scripts/roadmap.config.sh, relative to
# WORKSPACE_DIR) -- see roadmap.config.example.sh in this repo for every
# variable this file may set, with full documentation. Override the path
# with $1 or $ROADMAP_CONFIG_FILE if you keep it somewhere else.
# ---------------------------------------------------------------------------
CONFIG_FILE="${1:-${ROADMAP_CONFIG_FILE:-$WORKSPACE_DIR/scripts/roadmap.config.sh}}"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    echo "Run this from the target repo's root (or set \$ROADMAP_CONFIG_FILE), and make sure" >&2
    echo "scripts/roadmap.config.sh exists there -- copy roadmap.config.example.sh from this" >&2
    echo "repo (ftero-scripts) as a starting point. See README.md for full setup instructions." >&2
    exit 1
fi

# Defaults for every OPTIONAL config variable -- the config file overrides
# whichever of these it wants; anything it doesn't set keeps these defaults.
ROADMAP_FILE="specs/roadmap.md"                  # relative to WORKSPACE_DIR
SPEC_FILES=""                                    # space-separated extra spec files read for context, besides ROADMAP_FILE
INSTALL_CMD=""                                   # shell command to install deps before the gate, or "" to skip
GATE_CMD=""                                      # shell command for the deterministic verification gate, or "" to skip the gate entirely
CROSS_CUTTING_CONSTRAINTS=""                     # repo-specific hard rules fed to the reviewer turn
SHARED_MODULE_SYNC_NOTE=""                       # note about shared/cross-cutting modules that must move together with their consumers
NTFY_TOPIC=""                                    # ntfy.sh topic for phone push notifications, or "" to disable
NTFY_VERBOSE=false                               # false: only ping the phone for run start/stop, unit/phase completion, quota waits. true: ping on every notify().
WRITE_QA_DOC=false                               # false (default): skip the DOCUMENT stage entirely -- no specs/qa/<unit-slug>.md is written. true: run it as described in stage 5 above. Override per-run without touching the config file, e.g. `WRITE_QA_DOC=true bash run-roadmap.sh`.
MAX_TURN_BUDGET_USD=""                           # empty: no per-turn cost cap. Set e.g. "5.00" to pass --max-budget-usd to every claude invocation.
CLAUDE_MODEL=""                                  # empty: inherit the claude CLI's own settings. Otherwise passed as --model (e.g. "opus", "sonnet", "claude-opus-5-5").
CLAUDE_EFFORT=""                                 # empty: inherit. Otherwise passed as --effort (low|medium|high|xhigh|max).
PLAN_MODEL="";      PLAN_EFFORT=""               # per-stage overrides of CLAUDE_MODEL/CLAUDE_EFFORT; empty falls back to those.
IMPLEMENT_MODEL=""; IMPLEMENT_EFFORT=""
REVIEW_MODEL="";    REVIEW_EFFORT=""
DOCUMENT_MODEL="";  DOCUMENT_EFFORT=""
CLAUDE_SETTINGS=""                               # empty: none. Otherwise passed as --settings (a file path relative to the repo root, or a JSON string) -- e.g. to disable plugins/hooks the runner's turns don't need.
CLAUDE_STRICT_MCP=false                          # true: pass --strict-mcp-config so turns load no MCP servers (user- or project-configured).
SKIP_PLAN_FOR_SECTIONS=false                     # true: a ### N.M section unit skips the PLAN turn and runs as one task -- the roadmap author already split it.
GATE_FINDINGS_TAIL_LINES=80                      # on a gate failure, this many trailing lines of its output go straight into the retry's findings.
RETRY_WAIT_SECONDS=1800
MAX_NON_QUOTA_RETRIES=3
MAX_REVIEW_CYCLES=6
UNIT_TIMEOUT_SECONDS=10800
BACKGROUND_WAIT_SECONDS=120
MAX_BACKGROUND_NUDGES=15
POLL_INTERVAL_SECONDS=5
STOP_GRACE_SECONDS=60

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# REQUIRED config variables -- the config file must set these; there is no
# sane generic default for either.
: "${REPO_DESCRIPTION:?REPO_DESCRIPTION must be set in $CONFIG_FILE -- see roadmap.config.example.sh}"
: "${LAST_AUTOMATABLE_PHASE:?LAST_AUTOMATABLE_PHASE must be set in $CONFIG_FILE -- see roadmap.config.example.sh}"

PROGRESS_FILE="specs/.roadmap-progress"          # tracks completed unit/task ids (one per line)
TASKS_DIR="specs/.roadmap-tasks"                 # one <unit>.tasks (+ <unit>.start-head) file pair per unit, written once
QA_DIR="specs/qa"                                # one QA/testing doc per completed unit (DOCUMENT stage), committed permanently
LOG_FILE="specs/.roadmap-run.log"
RESUME_DOC="specs/ROADMAP-RESUME.md"             # always rewritten on every stop, for any reason -- see write_resume_doc()
COST_FILE="specs/.roadmap-cost"                  # append-only "<timestamp>|<label>|<usd>" log, one line per turn -- see record_turn_cost()

# A turn now runs as one long-lived `claude -p --input-format stream-json`
# session (see run_claude_turn) instead of a one-shot process, so it can
# background-nudge or /pivot into the SAME session rather than relaunching
# with --continue. If Claude backgrounds a slow command (e.g. a test suite)
# and ends a response expecting to be notified when it finishes, that
# notification never arrives (this is still a one-shot *run*, nothing is
# watching it in the background) -- that shows up as a clean stream-json
# result with no recognized marker in it. Treat it as "still working" and
# nudge it to check back in, rather than counting it as a real failure.

# Matches "## Phase 3 — Web owner app" (H2 phase headers). Deliberately does
# NOT match "## Phase sequence" (the mermaid-diagram heading) or "## §L —
# Legal and admin track" -- both lack a number right after "Phase", so they
# never become units.
PHASE_HEADER_REGEX='^##[[:space:]]+Phase[[:space:]]+([0-9]+)(\+)?[[:space:]]*[—:.-]*[[:space:]]*(.*)$'
# Matches "### 1.1 Some section title" (H3 section headers), for a phase
# split into sections. roadmap.md has none of these today -- every phase is a
# flat unit -- but this is kept so the script keeps working unmodified if
# section sub-headings are ever added.
GROUP_HEADER_REGEX='^###[[:space:]]+([0-9]+\.[0-9]+)[[:space:]]+(.*)$'

PROGRESS_SENTINEL="# roadmap-progress-v1"
AUTOMATION_LOG_HEADER="## Roadmap automation notes"

# ---------------------------------------------------------------------------
# RUNTIME (not committed -- see .gitignore): control file for the
# stop/retry/pivot commands, the live status file, and per-turn scratch dirs
# for the streaming session plumbing.
# ---------------------------------------------------------------------------
RUNTIME_DIR=".roadmap-runtime"
CONTROL_FILE="$RUNTIME_DIR/control"
CONTROL_LOCK_DIR="$RUNTIME_DIR/control.lock"
STATUS_FILE="$RUNTIME_DIR/status"
TASK_STATE_FILE="$RUNTIME_DIR/task-state"
PENDING_PIVOT_FILE="$RUNTIME_DIR/pending-pivot"
STOP_AFTER_FILE="$RUNTIME_DIR/stop-after"        # sticky "task" | "phase" -- see pending_stop_after()
GATE_OUTPUT_FILE="$RUNTIME_DIR/last-gate-failure.log"   # output of the most recent failed gate run, fed to the retry
STREAM_PARSE_JS="$SCRIPT_DIR/roadmap-stream-parse.js"

# ---------------------------------------------------------------------------

# notify() always writes to LOG_FILE. Whether it ALSO pings the phone
# depends on NTFY_VERBOSE: routine/frequent progress chatter (a task
# starting, a gate passing, a nudge) uses plain notify() and stays phone-
# silent by default; genuinely noteworthy events (run start/stop, unit/phase
# completion, a quota wait starting) use notify_important() and always ping
# regardless of NTFY_VERBOSE. Every stop_run() call auto-pings via
# notify_important with STOP_REASON, so most "why did it stop" call sites
# don't need their own explicit notify_important -- see stop_run().
notify() { _notify_impl "$1" "false"; }
notify_important() { _notify_impl "$1" "true"; }
_notify_impl() {
    local msg="$1" important="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $msg" | tee -a "$LOG_FILE"
    if [[ -n "$NTFY_TOPIC" ]] && { [[ "$important" == "true" ]] || [[ "$NTFY_VERBOSE" == "true" ]]; }; then
        curl -s -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
    fi
}

# Best-effort pattern match for rate/usage-limit signals. IMPORTANT: only
# ever call this against reconstructed assistant text and/or stderr, never
# against raw stream-json output -- every turn's raw output contains a
# benign `"type":"rate_limit_event"` telemetry line whose type name alone
# matches this pattern (rate_limit_event -> "rate.?limit" with status
# "allowed"), which would make every single turn look like a quota hit.
is_quota_error() {
    grep -qiE "rate.?limit|usage limit|session limit|quota|429|overloaded|try again later" <<<"$1"
}

# Matched against LAST_SUBTYPE/LAST_TERMINAL_REASON (never raw stream-json,
# same reasoning as is_quota_error) when MAX_TURN_BUDGET_USD is set. Hitting
# --max-budget-usd is deterministic -- retrying immediately hits the same
# wall again -- so this short-circuits record_turn_failure's normal 3x
# retry-with-backoff path and stops the run right away instead.
is_budget_exceeded() {
    grep -qiE "budget" <<<"$1"
}

cd "$WORKSPACE_DIR" || { echo "WORKSPACE_DIR not found: $WORKSPACE_DIR"; exit 1; }
mkdir -p "$TASKS_DIR" "$QA_DIR" "$RUNTIME_DIR"

if ! command -v node >/dev/null 2>&1; then
    echo "Error: 'node' not found on PATH. It's required (the claude CLI itself needs it, and this script uses it to speak stream-json for live /pivot support -- see roadmap-stream-parse.js)." >&2
    exit 1
fi
if [[ ! -f "$STREAM_PARSE_JS" ]]; then
    echo "Error: $STREAM_PARSE_JS not found (should ship alongside this script)." >&2
    exit 1
fi

# `timeout` is a GNU coreutils command -- not preinstalled on macOS. Prefer
# it, fall back to Homebrew's `gtimeout`, otherwise run unguarded (no
# auto-kill of a stuck attempt). Only used by the deterministic verification
# gate now -- Claude turns manage their own timeout (UNIT_TIMEOUT_SECONDS)
# inside run_claude_turn's polling loop, since they run as a long-lived
# streaming session rather than a single wrapped process.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    TIMEOUT_BIN=""
    echo "Warning: no 'timeout' or 'gtimeout' on PATH -- a stuck verification-gate run will not be auto-killed. Install GNU coreutils (or use Git Bash's, which already has it) for that safety net." >&2
fi

# Runs "$@" under a timeout of $1 seconds if a timeout binary is available,
# unguarded otherwise. Used for the deterministic verification gate.
run_with_timeout() {
    local secs="$1"; shift
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" "$secs" "$@"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# CONTROL FILE: stop / retry / pivot commands, appended by
# scripts/roadmap-ctl.sh from another terminal, consumed here one at a time.
# A tiny mkdir-based lock keeps a concurrent append and a concurrent pop from
# corrupting each other's read-modify-write of the file; it is not meant to
# arbitrate real concurrent writers, just to keep a single human's commands
# intact.
# ---------------------------------------------------------------------------
acquire_control_lock() {
    local tries=0
    while ! mkdir "$CONTROL_LOCK_DIR" 2>/dev/null; do
        tries=$((tries + 1))
        (( tries > 50 )) && return 1   # ~5s of contention -- give up rather than hang forever
        sleep 0.1
    done
    return 0
}
release_control_lock() { rmdir "$CONTROL_LOCK_DIR" 2>/dev/null || true; }

# Pops the oldest pending command off CONTROL_FILE into POPPED_COMMAND (one
# of: "stop", "retry", or "pivot:<text>"), or returns 1 if none is pending.
POPPED_COMMAND=""
pop_control_command() {
    POPPED_COMMAND=""
    [[ -s "$CONTROL_FILE" ]] || return 1
    acquire_control_lock || return 1
    if [[ -s "$CONTROL_FILE" ]]; then
        POPPED_COMMAND="$(head -n1 "$CONTROL_FILE")"
        tail -n +2 "$CONTROL_FILE" > "${CONTROL_FILE}.tmp" 2>/dev/null && mv "${CONTROL_FILE}.tmp" "$CONTROL_FILE"
    fi
    release_control_lock
    [[ -n "$POPPED_COMMAND" ]]
}

# A /pivot received while no turn is currently running (between stages, or
# during a quota/backoff wait) has nothing live to steer -- queue it and
# deliver it as the opening context of the next turn instead. Persisted to
# disk so it survives a crash between being queued and being delivered.
PENDING_PIVOT_TEXT=""
queue_pending_pivot() {
    local text="$1"
    if [[ -n "$PENDING_PIVOT_TEXT" ]]; then
        PENDING_PIVOT_TEXT="${PENDING_PIVOT_TEXT}"$'\n'"${text}"
    else
        PENDING_PIVOT_TEXT="$text"
    fi
    printf '%s' "$PENDING_PIVOT_TEXT" > "$PENDING_PIVOT_FILE"
    notify "Received /pivot with no turn currently running -- will deliver as opening context of the next turn: ${text}"
}
consume_pending_pivot() {
    printf '%s' "$PENDING_PIVOT_TEXT"
    PENDING_PIVOT_TEXT=""
    rm -f "$PENDING_PIVOT_FILE"
}
# Restore a pivot left pending by a crashed previous run rather than losing it.
[[ -f "$PENDING_PIVOT_FILE" ]] && PENDING_PIVOT_TEXT="$(cat "$PENDING_PIVOT_FILE")"

# Delivers pivot text live into an already-open turn's input stream (an
# OPERATOR MESSAGE the turn will read and act on without stopping), or
# queues it for the next turn if $2 (the open turn's input file) is empty --
# i.e. nothing is currently running.
# "Finish what's in flight, then stop" -- a sticky flag (not a one-shot
# popped command like stop/retry/pivot, since it may need to survive many
# poll ticks and turn retries before its boundary is actually reached).
# Checked at the two natural checkpoints in the main loop: right after a
# task passes review ("task"), and right after a unit's DOCUMENT stage +
# record_unit_complete ("phase" -- also catches "task" as a safety net, in
# case the command arrived after the last task of a unit already finished).
# Deliberately never interrupts an in-flight turn -- unlike /stop, nothing
# is lost or needs findings/task-state bookkeeping, since it only ever fires
# between turns.
pending_stop_after() {
    [[ -s "$STOP_AFTER_FILE" ]] && cat "$STOP_AFTER_FILE" || echo ""
}
set_stop_after() {
    mkdir -p "$RUNTIME_DIR"
    printf '%s' "$1" > "${STOP_AFTER_FILE}.tmp" && mv "${STOP_AFTER_FILE}.tmp" "$STOP_AFTER_FILE"
}
clear_stop_after() {
    rm -f "$STOP_AFTER_FILE"
}

# Called at each of the two checkpoints above. Stops the run cleanly if $1
# ("task" or "phase") satisfies (or is more specific than) whatever's
# pending, otherwise does nothing and returns.
maybe_stop_after() {
    local boundary="$1" pending
    pending="$(pending_stop_after)"
    [[ -z "$pending" ]] && return 0
    if [[ "$pending" == "$boundary" || ( "$pending" == "task" && "$boundary" == "phase" ) ]]; then
        clear_stop_after
        STOP_KIND="user-stop"
        notify "Stopping now as requested (stop-after-${pending}) -- ${2}."
        stop_run 0 "User requested stop-after-${pending}; stopped cleanly after ${2}."
    fi
}

deliver_or_queue_pivot() {
    local text="$1" live_infile="${2:-}"
    if [[ -n "$live_infile" ]]; then
        build_user_json_line "OPERATOR MESSAGE (sent live by the operator while you were mid-turn -- read it and act on it now, then continue/finish your turn as normal): ${text}" >> "$live_infile"
        notify "Delivered /pivot into the running turn: ${text}"
    else
        queue_pending_pivot "$text"
    fi
}

# Sleeps up to $1 seconds, polling the control file every
# POLL_INTERVAL_SECONDS. $2, if given, is the input file of a currently-open
# turn -- pivots received during the sleep are delivered live into it;
# otherwise they are queued for the next turn. Sets INTERRUPTED_BY to
# "retry" (skip the rest of the wait) or "stop" (caller must stop the run)
# and returns early for either; sets it to "" and returns after the full
# duration otherwise.
INTERRUPTED_BY=""
interruptible_sleep() {
    local total="$1" live_infile="${2:-}" waited=0 step
    INTERRUPTED_BY=""
    while (( waited < total )); do
        step=$POLL_INTERVAL_SECONDS
        (( total - waited < step )) && step=$((total - waited))
        sleep "$step"
        waited=$((waited + step))
        if pop_control_command; then
            case "$POPPED_COMMAND" in
                stop)
                    INTERRUPTED_BY="stop"
                    return 0
                    ;;
                retry)
                    INTERRUPTED_BY="retry"
                    notify "Received /retry -- skipping the remaining wait."
                    return 0
                    ;;
                pivot:*)
                    deliver_or_queue_pivot "${POPPED_COMMAND#pivot:}" "$live_infile"
                    ;;
            esac
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# STAGE TRACKING / STATUS FILE / STOP+RESUME. CURRENT_* are plain globals,
# updated at every stage transition in the main loop, so both the live
# status file (read by `roadmap-ctl.sh status`) and the resume document
# (written no matter how the script exits, see on_exit below) can always
# describe exactly where things stood.
# ---------------------------------------------------------------------------
CURRENT_UNIT_LABEL=""
CURRENT_STAGE="starting up"
CURRENT_TASK_INDEX=""
CURRENT_TASK_TOTAL=""
CURRENT_TASK_SCOPE=""
STOP_KIND="unknown"      # normal-complete | user-stop | error | nothing-to-do | needs-input
STOP_REASON=""
NEEDS_INPUT_ITEM=""      # set when STOP_KIND=needs-input -- what the operator must provide, see write_resume_doc
NEEDS_INPUT_REASON=""    # set when STOP_KIND=needs-input -- why the result would be worse without it

# In-flight retry state for whichever task is currently being worked, kept
# in sync with the real loop variables (FINDINGS/gate_fail_count/
# review_cycle) so save_task_state can persist it. Declared here so it's
# always defined even before the main loop starts (a resume doc written
# before any unit begins should not reference unset variables).
FINDINGS=""
gate_fail_count=0
review_cycle=0

set_stage() {
    CURRENT_STAGE="$1"
    write_status_file
}

write_status_file() {
    mkdir -p "$RUNTIME_DIR"
    {
        echo "Updated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "PID: $$"
        echo "Stage: $CURRENT_STAGE"
        [[ -n "$CURRENT_UNIT_LABEL" ]] && echo "Unit: $CURRENT_UNIT_LABEL"
        if [[ -n "$CURRENT_TASK_TOTAL" && "$CURRENT_TASK_TOTAL" != "1" ]]; then
            echo "Task: $CURRENT_TASK_INDEX/$CURRENT_TASK_TOTAL -- $CURRENT_TASK_SCOPE"
        fi
        local pending_sa; pending_sa="$(pending_stop_after)"
        [[ -n "$pending_sa" ]] && echo "Pending: will stop after this ${pending_sa} completes (roadmap-ctl.sh cancel-stop-after to undo)"
        local total_cost; total_cost="$(sum_cost_file)"
        [[ -n "$total_cost" ]] && echo "Spend so far this run: \$${total_cost}"
    } > "$STATUS_FILE"
}

# Persists the current task's in-flight retry state so a crash mid-retry-
# loop (killed process, OOM, power loss -- anything that skips the EXIT
# trap) still resumes without redoing already-cleared gate/review cycles.
# Called after every state change in the task retry loop.
save_task_state() {
    local unit="$1" task="$2"
    mkdir -p "$RUNTIME_DIR"
    {
        echo "UNIT=$unit"
        echo "TASK=$task"
        echo "GATE_FAIL_COUNT=$gate_fail_count"
        echo "REVIEW_CYCLE=$review_cycle"
        printf 'FINDINGS_B64=%s\n' "$(printf '%s' "$FINDINGS" | base64 | tr -d '\n')"
    } > "$TASK_STATE_FILE"
}

# If TASK_STATE_FILE exists and matches unit/task $1/$2, loads
# FINDINGS/gate_fail_count/review_cycle from it and returns 0; otherwise
# leaves them untouched and returns 1.
load_task_state_if_matching() {
    local unit="$1" task="$2" su st
    [[ -f "$TASK_STATE_FILE" ]] || return 1
    su=$(grep -m1 '^UNIT=' "$TASK_STATE_FILE" | cut -d= -f2-)
    st=$(grep -m1 '^TASK=' "$TASK_STATE_FILE" | cut -d= -f2-)
    [[ "$su" == "$unit" && "$st" == "$task" ]] || return 1
    gate_fail_count=$(grep -m1 '^GATE_FAIL_COUNT=' "$TASK_STATE_FILE" | cut -d= -f2-)
    review_cycle=$(grep -m1 '^REVIEW_CYCLE=' "$TASK_STATE_FILE" | cut -d= -f2-)
    FINDINGS="$(grep -m1 '^FINDINGS_B64=' "$TASK_STATE_FILE" | cut -d= -f2- | base64 -d 2>/dev/null || true)"
    notify "Resuming $unit task $task mid-retry-loop from a previous run (gate failures so far: $gate_fail_count, review cycles so far: $review_cycle)."
    return 0
}

clear_task_state() {
    rm -f "$TASK_STATE_FILE"
}

# The ONLY place this script calls `exit`. Centralizing it guarantees
# STOP_REASON is always set to something meaningful before the EXIT trap
# (on_exit -> write_resume_doc) runs, and that every stop -- for any reason,
# regardless of NTFY_VERBOSE -- gets one important phone ping explaining why.
stop_run() {
    local code="$1" reason="${2:-}"
    [[ -n "$reason" ]] && STOP_REASON="$reason"
    [[ -n "$STOP_REASON" ]] && notify_important "Stopping: $STOP_REASON"
    exit "$code"
}

# Writes/rewrites RESUME_DOC with everything needed to resume with no other
# context, and commits it. Runs from the EXIT trap, so it must not itself
# call `exit` or rely on anything that might already be torn down.
write_resume_doc() {
    local exit_code="$1"
    mkdir -p "$(dirname "$RESUME_DOC")"

    local kind_label
    case "$STOP_KIND" in
        normal-complete) kind_label="Finished normally -- nothing left to resume" ;;
        user-stop)       kind_label="Stopped by operator (/stop)" ;;
        nothing-to-do)   kind_label="Nothing to do -- already up to date" ;;
        error)           kind_label="Stopped on error -- needs manual review" ;;
        needs-input)     kind_label="ACTION REQUIRED -- blocked on information/action only you can provide" ;;
        *)               kind_label="Stopped (exit code $exit_code)" ;;
    esac

    local head_line
    head_line="$(git log -1 --format='%h %s' 2>/dev/null || echo 'unknown -- not a git repo or no commits yet')"

    local resume_how
    if [[ "$STOP_KIND" == "normal-complete" || "$STOP_KIND" == "nothing-to-do" ]]; then
        resume_how="Nothing to resume. All automatable units through Phase ${LAST_AUTOMATABLE_PHASE} are marked complete in ${PROGRESS_FILE}."
    elif [[ "$STOP_KIND" == "needs-input" ]]; then
        resume_how=$(cat <<EOF
Provide what's requested in "What's needed" below FIRST -- add the
secret/credential to wherever this repo's own conventions say it belongs
(e.g. Dokploy's encrypted store, a committed \`.example\` file with the real
value filled in only in the real secret store, never in git), finish the
account/registration, or make the decision yourself. Do NOT just re-run the
script without doing that -- this exact task will hit the same block again
and stop again. Once it's actually provided, re-run the script as usual:
    scripts\\run-roadmap.bat      (Windows, double-click or run from any shell)
    bash scripts/run-roadmap.sh   (Git Bash / macOS / Linux)
The blocked task was NOT marked complete, so it will be retried from
scratch with the new information available.
EOF
)
    else
        resume_how=$(cat <<EOF
Just re-run the script -- it resumes automatically from ${PROGRESS_FILE},
${TASKS_DIR}, and ${TASK_STATE_FILE} (if present), with no manual steps:
    scripts\\run-roadmap.bat      (Windows, double-click or run from any shell)
    bash scripts/run-roadmap.sh   (Git Bash / macOS / Linux)
If it stopped mid-task (see "In-flight retry state" below), the next run
picks that task's findings/gate/review counters back up automatically and
continues its retry loop -- it does not restart the task from scratch.
EOF
)
    fi

    local pending_pivot_note=""
    if [[ -n "$PENDING_PIVOT_TEXT" ]]; then
        pending_pivot_note=$(cat <<EOF

## Pending /pivot not yet delivered
A /pivot was received but no turn was running to deliver it into live. It
will be delivered as opening context of the next turn that starts:
> ${PENDING_PIVOT_TEXT}
EOF
)
    fi

    local task_state_note=""
    if [[ -n "$CURRENT_TASK_INDEX" ]]; then
        task_state_note=$(cat <<EOF

## In-flight retry state for the current task
- Findings fed back into the next implement attempt: ${FINDINGS:-none}
- Gate failures so far on this task: ${gate_fail_count}/${MAX_NON_QUOTA_RETRIES}
- Review cycles so far on this task: ${review_cycle}/${MAX_REVIEW_CYCLES}
EOF
)
    fi

    local pending_sa_note="" pending_sa
    pending_sa="$(pending_stop_after)"
    if [[ -n "$pending_sa" ]]; then
        pending_sa_note="
## Pending deferred stop
A stop-after-${pending_sa} was requested but not yet reached when this run
ended for a different reason. It is still queued -- the next run will honor
it at the next task/phase boundary unless cancelled first with
\`scripts/roadmap-ctl.sh cancel-stop-after\`."
    fi

    local needs_input_note=""
    if [[ "$STOP_KIND" == "needs-input" ]]; then
        needs_input_note=$(cat <<EOF

## What's needed
- **Needed:** ${NEEDS_INPUT_ITEM:-<not specified>}
- **Why:** ${NEEDS_INPUT_REASON:-<not specified>}
EOF
)
    fi

    local cost_line="" total_cost
    total_cost="$(sum_cost_file)"
    [[ -n "$total_cost" ]] && cost_line="**Total spend recorded (${COST_FILE}):** \$${total_cost}"

    local log_tail=""
    [[ -f "$LOG_FILE" ]] && log_tail="$(tail -n 40 "$LOG_FILE" 2>/dev/null)"

    local progress_tail=""
    [[ -f "$PROGRESS_FILE" ]] && progress_tail="$(tail -n 15 "$PROGRESS_FILE" 2>/dev/null)"

    {
        echo "# Roadmap automation -- run status"
        echo
        echo "**Generated:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "**Outcome:** ${kind_label}"
        echo "**Exit code:** ${exit_code}"
        [[ -n "$STOP_REASON" ]] && echo "**Reason:** ${STOP_REASON}"
        [[ -n "$cost_line" ]] && echo "$cost_line"
        echo
        echo "## Where things stood"
        if [[ "$STOP_KIND" == "normal-complete" || "$STOP_KIND" == "nothing-to-do" ]]; then
            echo "- Nothing in progress -- the run finished."
        else
            echo "- Unit: ${CURRENT_UNIT_LABEL:-none -- between units}"
            if [[ -n "$CURRENT_TASK_INDEX" ]]; then
                echo "- Task: ${CURRENT_TASK_INDEX}/${CURRENT_TASK_TOTAL} -- ${CURRENT_TASK_SCOPE}"
            fi
            echo "- Stage: ${CURRENT_STAGE}"
        fi
        echo "- Git HEAD: ${head_line}"
        [[ -n "$task_state_note" ]] && echo "${task_state_note}"
        [[ -n "$needs_input_note" ]] && echo "${needs_input_note}"
        echo
        echo "## How to resume"
        echo "${resume_how}"
        [[ -n "$pending_pivot_note" ]] && echo "${pending_pivot_note}"
        [[ -n "$pending_sa_note" ]] && echo "${pending_sa_note}"
        echo
        echo "## Recent progress entries (${PROGRESS_FILE}, last 15)"
        echo '```'
        echo "${progress_tail:-<empty>}"
        echo '```'
        echo
        echo "## Recent log tail (${LOG_FILE}, last 40 lines)"
        echo '```'
        echo "${log_tail:-<empty>}"
        echo '```'
    } > "$RESUME_DOC"

    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add "$RESUME_DOC" "$COST_FILE" >/dev/null 2>&1
        git commit -q -m "Roadmap: run status -- ${kind_label}" >/dev/null 2>&1 || true
    fi
}

on_exit() {
    local code=$?
    write_resume_doc "$code"
}
trap on_exit EXIT

on_signal() {
    STOP_KIND="user-stop"
    STOP_REASON="Interrupted by signal (Ctrl-C or termination) while: ${CURRENT_STAGE}."
    notify "Received interrupt signal -- stopping and writing the resume document."
    exit 130
}
trap on_signal INT TERM

# ---------------------------------------------------------------------------
# PARSE ROADMAP: phase headers, section headers, and the line ranges each
# owns (used later to place heading markers).
# ---------------------------------------------------------------------------
mapfile -t PHASE_LINES < <(grep -nE "$PHASE_HEADER_REGEX" "$ROADMAP_FILE")
if [[ ${#PHASE_LINES[@]} -eq 0 ]]; then
    echo "No phase headers matched in $ROADMAP_FILE. Check PHASE_HEADER_REGEX."
    exit 1
fi

declare -A PHASE_TITLES PHASE_LINE_BY_NUM
for line in "${PHASE_LINES[@]}"; do
    lineno="${line%%:*}"
    content="${line#*:}"
    if [[ "$content" =~ Phase[[:space:]]+([0-9]+)(\+)?[[:space:]]*[—:.-]*[[:space:]]*(.*) ]]; then
        num="${BASH_REMATCH[1]}"
        PHASE_TITLES["$num"]="${BASH_REMATCH[3]}"
        PHASE_LINE_BY_NUM["$num"]="$lineno"
    fi
done

mapfile -t GROUP_LINES < <(grep -nE "$GROUP_HEADER_REGEX" "$ROADMAP_FILE")
declare -A GROUP_TITLE_BY_ID GROUP_LINE_BY_ID
GROUP_IDS_IN_FILE_ORDER=()
for line in "${GROUP_LINES[@]}"; do
    lineno="${line%%:*}"
    content="${line#*:}"
    if [[ "$content" =~ ^###[[:space:]]+([0-9]+\.[0-9]+)[[:space:]]+(.*)$ ]]; then
        gid="${BASH_REMATCH[1]}"
        GROUP_TITLE_BY_ID["$gid"]="${BASH_REMATCH[2]}"
        GROUP_LINE_BY_ID["$gid"]="$lineno"
        GROUP_IDS_IN_FILE_ORDER+=("$gid")
    fi
done

TOTAL_LINES=$(wc -l < "$ROADMAP_FILE")
mapfile -t ALL_HEADER_LINES < <(
    {
        for n in "${!PHASE_LINE_BY_NUM[@]}"; do echo "${PHASE_LINE_BY_NUM[$n]}"; done
        for g in "${!GROUP_LINE_BY_ID[@]}"; do echo "${GROUP_LINE_BY_ID[$g]}"; done
    } | sort -n
)

# The line just before the next header (phase or section) after $1, or EOF
# (as it stood at parse time -- see the note in TRACKING #4 above about why
# this script never inserts lines before this point once parsing is done).
end_line_for() {
    local start="$1" nxt=""
    for l in "${ALL_HEADER_LINES[@]}"; do
        if (( l > start )); then nxt="$l"; break; fi
    done
    if [[ -n "$nxt" ]]; then echo $(( nxt - 1 )); else echo "$TOTAL_LINES"; fi
}

# ---------------------------------------------------------------------------
# BUILD UNITS: one entry per section for phases that have ### sub-sections,
# one entry for the whole phase otherwise. Order matches the roadmap. As of
# this writing every phase in roadmap.md is flat (no ### N.M headers), so
# UNIT_IDS is just "0".."15" in order.
# ---------------------------------------------------------------------------
UNIT_IDS=()
declare -A UNIT_PHASE UNIT_TITLE UNIT_HEADERLINE UNIT_ENDLINE UNIT_ISGROUP

mapfile -t PHASE_NUMS_SORTED < <(printf '%s\n' "${!PHASE_TITLES[@]}" | sort -n)

for P in "${PHASE_NUMS_SORTED[@]}"; do
    phase_groups=()
    for gid in "${GROUP_IDS_IN_FILE_ORDER[@]}"; do
        [[ "${gid%%.*}" == "$P" ]] && phase_groups+=("$gid")
    done

    if (( ${#phase_groups[@]} > 0 )); then
        for gid in "${phase_groups[@]}"; do
            UNIT_IDS+=("$gid")
            UNIT_PHASE["$gid"]="$P"
            UNIT_TITLE["$gid"]="${GROUP_TITLE_BY_ID[$gid]}"
            UNIT_HEADERLINE["$gid"]="${GROUP_LINE_BY_ID[$gid]}"
            UNIT_ENDLINE["$gid"]="$(end_line_for "${GROUP_LINE_BY_ID[$gid]}")"
            UNIT_ISGROUP["$gid"]=1
        done
    else
        UNIT_IDS+=("$P")
        UNIT_PHASE["$P"]="$P"
        UNIT_TITLE["$P"]="${PHASE_TITLES[$P]}"
        UNIT_HEADERLINE["$P"]="${PHASE_LINE_BY_NUM[$P]}"
        UNIT_ENDLINE["$P"]="$(end_line_for "${PHASE_LINE_BY_NUM[$P]}")"
        UNIT_ISGROUP["$P"]=0
    fi
done

describe_unit() {
    local u="$1" p="${UNIT_PHASE[$1]}"
    if (( UNIT_ISGROUP[$u] )); then
        echo "Phase $p, Section $u: ${UNIT_TITLE[$u]}"
    else
        echo "Phase $p: ${UNIT_TITLE[$u]}"
    fi
}

phase_fully_done() {
    local p="$1" u
    for u in "${UNIT_IDS[@]}"; do
        if [[ "${UNIT_PHASE[$u]}" == "$p" ]]; then
            is_unit_completed "$u" || return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# PROGRESS FILE: one completed id per line, behind a sentinel first line.
# ---------------------------------------------------------------------------
is_unit_completed() {
    grep -qxF "$1" "$PROGRESS_FILE" 2>/dev/null
}

mark_unit_completed() {
    echo "$1" >> "$PROGRESS_FILE"
}

# Task-level completion, tracked as "<unit>::<task-index>" lines in the same
# PROGRESS_FILE so a crash/resume mid-unit does not re-run finished tasks. A
# bare unit id (mark_unit_completed) is only ever written once every task
# belonging to it is done -- see record_unit_complete.
is_task_completed() {
    grep -qxF "$1::$2" "$PROGRESS_FILE" 2>/dev/null
}

mark_task_completed() {
    echo "$1::$2" >> "$PROGRESS_FILE"
}

# Records one deliverable a PARTIAL task deliberately left unimplemented
# (genuinely blocked on a phase not yet built, or an operator-only action),
# as "<unit>::<task>::DEFERRED::<item text>::<reason>". Read back by
# unit_deferred_items() at unit-completion/documentation time.
mark_task_deferred() {
    local unit="$1" task="$2" item="$3" reason="$4"
    printf '%s::%s::DEFERRED::%s::%s\n' "$unit" "$task" "$item" "$reason" >> "$PROGRESS_FILE"
}

# All (item, reason) pairs deferred by any task of unit $1, across this run
# and any resumed-from-crash previous run. Sets DEFERRED_ITEM_TEXTS /
# DEFERRED_ITEM_REASONS (parallel arrays), reset on every call so a unit
# with nothing deferred correctly yields two empty arrays.
DEFERRED_ITEM_TEXTS=()
DEFERRED_ITEM_REASONS=()
unit_deferred_items() {
    local unit="$1" line rest
    DEFERRED_ITEM_TEXTS=()
    DEFERRED_ITEM_REASONS=()
    [[ -f "$PROGRESS_FILE" ]] || return 0
    while IFS= read -r line; do
        case "$line" in
            "${unit}::"[0-9]*"::DEFERRED::"*)
                rest="${line#"${unit}::"}"
                rest="${rest#*::DEFERRED::}"
                DEFERRED_ITEM_TEXTS+=("${rest%%::*}")
                DEFERRED_ITEM_REASONS+=("${rest#*::}")
                ;;
        esac
    done < "$PROGRESS_FILE"
}

# ---------------------------------------------------------------------------
# UNIT START-HEAD: the git HEAD sha captured the first time a unit is
# encountered, before its plan turn runs. Used by the DOCUMENT stage to diff
# "everything this unit changed" across however many tasks/resumes it took.
# Written once (TASKS_DIR/<unit>.start-head), never rewritten.
# ---------------------------------------------------------------------------
unit_start_head_file() { echo "${TASKS_DIR}/$1.start-head"; }

save_unit_start_head() {
    local unit="$1" f
    f="$(unit_start_head_file "$unit")"
    [[ -f "$f" ]] && return 0
    git rev-parse HEAD 2>/dev/null > "$f" || : > "$f"
}

unit_start_head_for() {
    local f
    f="$(unit_start_head_file "$1")"
    [[ -s "$f" ]] && cat "$f" || echo ""
}

# Accumulates each task's passing-review commentary for a unit, so the
# DOCUMENT stage doesn't start cold on risk areas the reviewer(s) already
# identified while reading the exact same diff. Appended once per task that
# passes review (never rewritten -- a crash/resume mid-unit keeps earlier
# tasks' notes); read back in whole by the DOCUMENT stage.
unit_review_notes_file() { echo "${TASKS_DIR}/$1.review-notes"; }

append_unit_review_note() {
    local unit="$1" task="$2" text="$3"
    [[ -z "$(sed -E '/^[[:space:]]*$/d' <<<"$text")" ]] && return 0
    {
        echo "--- Task ${task} reviewer's notes ---"
        echo "$text"
        echo
    } >> "$(unit_review_notes_file "$unit")"
}

unit_review_notes_for() {
    local f
    f="$(unit_review_notes_file "$1")"
    [[ -s "$f" ]] && cat "$f" || echo ""
}

# ---------------------------------------------------------------------------
# ROADMAP.MD BOOKKEEPING. roadmap.md's deliverables are prose bullets, not
# "- [ ]" checkboxes, so there is nothing to tick per line. Bookkeeping is
# therefore heading-level only: a "**(complete)**" marker appended to the end
# of the unit's own header LINE (never a new line -- editing a line's content
# doesn't change the file's line count, so every other unit's cached header
# line number stays valid). Deferred-item detail can't fit on the header line
# legibly, so it goes in one running section appended at the true end of the
# file -- always strictly after every line already parsed, so that append
# never shifts anything either. See TRACKING #4 at the top of this file.
# ---------------------------------------------------------------------------
append_complete_marker() {
    local line_num="$1" note="$2"
    local marker="**(complete)**"
    [[ -n "$note" ]] && marker="**(complete -- ${note})**"
    if ! sed -n "${line_num}p" "$ROADMAP_FILE" | grep -qF '**(complete'; then
        sed "${line_num}s/\$/ ${marker}/" "$ROADMAP_FILE" > "${ROADMAP_FILE}.tmp" && mv "${ROADMAP_FILE}.tmp" "$ROADMAP_FILE"
    fi
}

ensure_automation_log_section() {
    # Exact whole-line match, deliberately not a substring grep: the
    # complete-marker note on a phase heading also mentions this header's
    # text inline (see mark_unit_in_roadmap below), so a substring match
    # would false-positive on that mention and skip creating the real
    # section, leaving deferred-item bullets with no header above them.
    if ! grep -qxF "$AUTOMATION_LOG_HEADER" "$ROADMAP_FILE"; then
        {
            echo ""
            echo "---"
            echo ""
            echo "$AUTOMATION_LOG_HEADER"
            echo ""
            echo "Appended automatically by scripts/run-roadmap.sh when a task legitimately"
            echo "defers a deliverable to a later phase or to an operator-only action. Each"
            echo "affected phase heading above also carries a **(complete -- N item(s)"
            echo "deferred)** marker pointing back here."
            echo ""
        } >> "$ROADMAP_FILE"
    fi
}

# Appends one bullet per deferred item for unit $1 (DEFERRED_ITEM_TEXTS/
# DEFERRED_ITEM_REASONS must already be populated via unit_deferred_items).
append_deferred_notes() {
    local unit="$1" label="$2" i
    ensure_automation_log_section
    for i in "${!DEFERRED_ITEM_TEXTS[@]}"; do
        printf -- '- **%s** deferred: "%s" -- %s\n' "$label" "${DEFERRED_ITEM_TEXTS[$i]}" "${DEFERRED_ITEM_REASONS[$i]}" >> "$ROADMAP_FILE"
    done
}

# Heading marker(s) for one just-completed unit. Loads this unit's deferred
# items first so the marker/notes agree; they remain readable in
# DEFERRED_ITEM_TEXTS/DEFERRED_ITEM_REASONS after this returns, for callers
# (record_unit_complete) that want the count.
mark_unit_in_roadmap() {
    local u="$1"
    unit_deferred_items "$u"
    if (( ${#DEFERRED_ITEM_TEXTS[@]} > 0 )); then
        append_complete_marker "${UNIT_HEADERLINE[$u]}" "${#DEFERRED_ITEM_TEXTS[@]} item(s) deferred -- see \"${AUTOMATION_LOG_HEADER}\" at the end of this file"
        append_deferred_notes "$u" "$(describe_unit "$u")"
    else
        append_complete_marker "${UNIT_HEADERLINE[$u]}" ""
    fi
    if (( UNIT_ISGROUP[$u] )) && phase_fully_done "${UNIT_PHASE[$u]}"; then
        append_complete_marker "${PHASE_LINE_BY_NUM[${UNIT_PHASE[$u]}]}" ""
    fi
}

commit_progress_if_repo() {
    local msg="$1"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add "$PROGRESS_FILE" "$ROADMAP_FILE" "$TASKS_DIR" "$QA_DIR" "$COST_FILE" >/dev/null 2>&1
        git commit -q -m "$msg" >/dev/null 2>&1 || true
    fi
}

# Marks a just-finished unit complete everywhere (progress file + roadmap.md
# + commit). Returns 0 normally; if this unit completing also finished every
# section of its phase, notify_phase_done_var is set to that phase number so
# the caller can log it in the right order (after the unit's own message).
notify_phase_done_var=""
record_unit_complete() {
    local u="$1" p="${UNIT_PHASE[$1]}"
    mark_unit_completed "$u"
    mark_unit_in_roadmap "$u"
    local commit_msg="Roadmap: $(describe_unit "$u") complete"
    if (( ${#DEFERRED_ITEM_TEXTS[@]} > 0 )); then
        commit_msg="$commit_msg (${#DEFERRED_ITEM_TEXTS[@]} item(s) deferred, see roadmap.md)"
    fi
    notify_phase_done_var=""
    if (( UNIT_ISGROUP[$u] )) && phase_fully_done "$p"; then
        commit_msg="$commit_msg (phase $p fully complete)"
        notify_phase_done_var="$p"
    fi
    commit_progress_if_repo "$commit_msg"
}

init_progress_file() {
    if [[ ! -f "$PROGRESS_FILE" ]]; then
        echo "$PROGRESS_SENTINEL" > "$PROGRESS_FILE"
    fi
}

init_progress_file

# ---------------------------------------------------------------------------
# DETERMINE RANGE TO RUN
# ---------------------------------------------------------------------------
MAX_INDEX=-1
for i in "${!UNIT_IDS[@]}"; do
    (( UNIT_PHASE[${UNIT_IDS[$i]}] <= LAST_AUTOMATABLE_PHASE )) && MAX_INDEX=$i
done

if (( MAX_INDEX == -1 )); then
    echo "No automatable units found at or below Phase $LAST_AUTOMATABLE_PHASE. Check the roadmap/config."
    exit 1
fi

START_INDEX=-1
for (( i=0; i<=MAX_INDEX; i++ )); do
    if ! is_unit_completed "${UNIT_IDS[$i]}"; then
        START_INDEX=$i
        break
    fi
done

if (( START_INDEX == -1 )); then
    STOP_KIND="nothing-to-do"
    stop_run 0 "Nothing to do -- all automatable units through Phase $LAST_AUTOMATABLE_PHASE are already marked complete in $PROGRESS_FILE (see $ROADMAP_FILE for what's beyond that)."
fi

notify_important "$(basename "$WORKSPACE_DIR") roadmap run starting. Resuming at $(describe_unit "${UNIT_IDS[$START_INDEX]}"), through Phase $LAST_AUTOMATABLE_PHASE."
[[ -n "$PENDING_PIVOT_TEXT" ]] && notify "A /pivot from a previous run is still pending delivery: ${PENDING_PIVOT_TEXT}"

# ---------------------------------------------------------------------------
# TURN EXECUTION HELPERS
# ---------------------------------------------------------------------------

# Writes prompt text $1 to stdout as one stream-json user-message line. Uses
# node (already a hard dependency of the claude CLI itself) rather than
# hand-rolled shell JSON escaping, since prompts are multi-KB heredocs that
# can contain arbitrary quotes/backticks/newlines.
build_user_json_line() {
    local text="$1" tmp
    tmp="$(mktemp "$RUNTIME_DIR/msg.XXXXXX")"
    printf '%s' "$text" > "$tmp"
    node -e '
        const fs = require("fs");
        const text = fs.readFileSync(process.argv[1], "utf8");
        process.stdout.write(JSON.stringify({type: "user", message: {role: "user", content: [{type: "text", text}]}}) + "\n");
    ' "$tmp"
    rm -f "$tmp"
}

# Ends one streaming turn's claude process: the caller has already told the
# input generator to stop feeding it (closing its stdin), which lets it
# finish whatever it was doing and exit on its own -- give it up to $2
# seconds to do that before SIGTERM, then SIGKILL.
end_stream_session() {
    local pid="$1" grace="$2" waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < grace )); do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

# Appends one line to COST_FILE for a just-finished turn (any outcome --
# cost is incurred whether the turn succeeded or not) and returns quietly if
# there's nothing to record (e.g. a turn that errored before any billed
# request went out). Sum with sum_cost_file for a running total.
record_turn_cost() {
    local label="$1" usd="$2"
    [[ -z "$usd" ]] && return 0
    # usd is a decimal string (e.g. "0.031500") -- bash arithmetic can't
    # compare floats, so let awk decide whether it's worth a line.
    if ! awk -v u="$usd" 'BEGIN { exit !(u > 0) }' 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "$COST_FILE")"
    printf '%s|%s|%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$label" "$usd" >> "$COST_FILE"
}

sum_cost_file() {
    [[ -f "$COST_FILE" ]] || { echo ""; return 0; }
    awk -F'|' '{sum += $3} END {if (NR > 0) printf "%.4f", sum}' "$COST_FILE" 2>/dev/null
}

append_turn_log() {
    local label="$1" outfile="$2" errfile="$3"
    {
        echo "=== $label -- raw stream-json output ==="
        cat "$outfile" 2>/dev/null
        echo "=== $label -- stderr ==="
        cat "$errfile" 2>/dev/null
    } >> "$LOG_FILE"
}

# Counts one more failed attempt of the CURRENT turn (run_claude_turn's
# fail_count -- relies on bash's dynamic scoping of unshadowed locals, since
# this is always called from directly within run_claude_turn), logs the raw
# transcript, stops the whole run if MAX_NON_QUOTA_RETRIES is exhausted,
# otherwise backs off (interruptibly -- /retry skips the wait, /stop ends
# the run) before the caller starts a fresh session.
record_turn_failure() {
    local label="$1" desc="$2" outfile="$3" errfile="$4"
    fail_count=$((fail_count + 1))
    notify "$label $desc (attempt $fail_count/$MAX_NON_QUOTA_RETRIES)."
    append_turn_log "$label" "$outfile" "$errfile"
    if (( fail_count >= MAX_NON_QUOTA_RETRIES )); then
        STOP_KIND="error"
        stop_run 1 "$label failed $MAX_NON_QUOTA_RETRIES times ($desc). Stopping run for manual review."
    fi
    interruptible_sleep 30
    if [[ "$INTERRUPTED_BY" == "stop" ]]; then
        STOP_KIND="user-stop"
        stop_run 0 "User requested /stop during backoff after a failed attempt of: $label"
    fi
}

# Runs one logical Claude turn (plan / implement / review / document) to a
# real, final verdict, handling quota waits, timeouts, and background-nudges
# uniformly, and supporting live /stop, /retry, /pivot for the whole
# duration. Unlike the one-shot `claude -p "<prompt>"` this replaced, the
# turn runs as a single continuous `claude -p --input-format stream-json`
# session for as long as it takes to reach a verdict -- see the
# INTERACTIVITY note in the file header for why (live /pivot needs the
# stdin stream kept open, not a fresh process per message).
#
# Args:
#   $1 label            -- for logs/notify
#   $2 init_prompt       -- the turn's opening message
#   $3 continue_prompt   -- sent as a same-session nudge if a response ends
#                            without a result marker (see BACKGROUND_WAIT_
#                            SECONDS above)
#   $4 done_re           -- regex matching any marker that means "the turn
#                            reached a real, final verdict" (may be more
#                            than one alternative, e.g. review's OK|ISSUES)
#   $5 explicit_fail_re  -- optional regex matching a clean "I'm blocked"
#                            marker that, unlike done_re, should still be
#                            retried (same bucket as a mechanical failure)
#                            before giving up. Pass "" (or omit) when the
#                            turn kind has no such marker.
#
# On success: sets CLAUDE_TURN_OUTPUT to the reconstructed plain-text
# transcript (all assistant text blocks, newline-joined -- the same shape
# the old plain-text `-p` output was, so existing marker-extraction grep/sed
# logic elsewhere in this script needs no changes) and returns 0.
# Exhausting the failure/timeout retry budget or the background-nudge budget
# stops the whole run (via stop_run) -- a run that can't get a turn to a
# real verdict needs a human, not an infinite loop. A /stop also stops the
# whole run, deliberately, via stop_run.
run_claude_turn() {
    local label="$1" init_prompt="$2" continue_prompt="$3" done_re="$4" explicit_fail_re="${5:-}" stage="${6:-}"
    local fail_count=0

    # Model/effort: the stage's own override (e.g. REVIEW_MODEL), else the
    # run-wide CLAUDE_MODEL/CLAUDE_EFFORT, else whatever the CLI's settings say.
    local model="$CLAUDE_MODEL" effort="$CLAUDE_EFFORT" var
    if [[ -n "$stage" ]]; then
        var="${stage}_MODEL";  [[ -n "${!var:-}" ]] && model="${!var}"
        var="${stage}_EFFORT"; [[ -n "${!var:-}" ]] && effort="${!var}"
    fi
    local extra_claude_args=()
    [[ -n "$MAX_TURN_BUDGET_USD" ]] && extra_claude_args+=(--max-budget-usd "$MAX_TURN_BUDGET_USD")
    [[ -n "$model" ]] && extra_claude_args+=(--model "$model")
    [[ -n "$effort" ]] && extra_claude_args+=(--effort "$effort")
    [[ -n "$CLAUDE_SETTINGS" ]] && extra_claude_args+=(--settings "$CLAUDE_SETTINGS")
    [[ "$CLAUDE_STRICT_MCP" == "true" ]] && extra_claude_args+=(--strict-mcp-config)
    local cost_label="$label [${model:-default}/${effort:-default}]"

    while true; do
        local turn_dir infile outfile errfile statefile textfile metafile stopflag
        turn_dir="$(mktemp -d "$RUNTIME_DIR/turn.XXXXXX")"
        infile="$turn_dir/in.jsonl"; outfile="$turn_dir/out.jsonl"; errfile="$turn_dir/err.log"
        statefile="$turn_dir/parse-state.json"; textfile="$turn_dir/text.txt"; metafile="$turn_dir/meta.env"
        stopflag="$turn_dir/stop.flag"
        : > "$infile"; : > "$textfile"

        (
            sent=0
            while [[ ! -f "$stopflag" ]]; do
                total=$(wc -l < "$infile" 2>/dev/null || echo 0)
                if (( total > sent )); then
                    sed -n "$((sent + 1)),${total}p" "$infile"
                    sent=$total
                fi
                sleep 1
            done
        ) | claude -p --input-format stream-json --output-format stream-json --verbose \
                --permission-mode bypassPermissions "${extra_claude_args[@]}" \
                > "$outfile" 2> "$errfile" &
        local claude_pid=$!

        local first_text="$init_prompt" pivot
        pivot="$(consume_pending_pivot)"
        if [[ -n "$pivot" ]]; then
            first_text="OPERATOR NOTE (sent by the operator before this turn started -- read it first): ${pivot}

${init_prompt}"
        fi
        build_user_json_line "$first_text" >> "$infile"

        local start_ts nudge_count last_result_seen outcome
        start_ts=$(date +%s); nudge_count=0; last_result_seen=0; outcome=""

        while true; do
            sleep "$POLL_INTERVAL_SECONDS"

            node "$STREAM_PARSE_JS" "$outfile" "$statefile" "$textfile" "$metafile" 2>>"$errfile" || true
            RESULT_COUNT=0 LAST_IS_ERROR=unknown LAST_SUBTYPE="" LAST_API_ERROR_STATUS="" LAST_RESULT_TEXT_LINES=0 LAST_TERMINAL_REASON=""
            # shellcheck disable=SC1090
            [[ -f "$metafile" ]] && source "$metafile"

            local acc_text=""
            [[ -f "$textfile" ]] && acc_text="$(cat "$textfile")"

            if grep -qE "$done_re" <<<"$acc_text"; then
                outcome="done"; break
            fi
            if [[ -n "$explicit_fail_re" ]] && grep -qE "$explicit_fail_re" <<<"$acc_text"; then
                outcome="fail"; break
            fi

            if pop_control_command; then
                case "$POPPED_COMMAND" in
                    stop)
                        outcome="stop"; break ;;
                    pivot:*)
                        deliver_or_queue_pivot "${POPPED_COMMAND#pivot:}" "$infile" ;;
                    retry)
                        notify "$label: /retry has no effect right now -- a turn is actively running, not waiting on anything. (It only skips a quota/backoff/nudge-pacing wait.)" ;;
                esac
            fi

            if ! kill -0 "$claude_pid" 2>/dev/null; then
                outcome="ended"; break
            fi

            if (( RESULT_COUNT > last_result_seen )); then
                last_result_seen=$RESULT_COUNT
                if [[ "$LAST_IS_ERROR" == "true" ]]; then
                    outcome="error"; break
                fi
                nudge_count=$((nudge_count + 1))
                if (( nudge_count > MAX_BACKGROUND_NUDGES )); then
                    outcome="nudge_exhausted"; break
                fi
                notify "$label: a response ended without a result marker (nudge $nudge_count/$MAX_BACKGROUND_NUDGES) -- likely still waiting on a background command. Pausing ${BACKGROUND_WAIT_SECONDS}s then nudging it to continue."
                interruptible_sleep "$BACKGROUND_WAIT_SECONDS" "$infile"
                if [[ "$INTERRUPTED_BY" == "stop" ]]; then
                    outcome="stop"; break
                fi
                build_user_json_line "$continue_prompt" >> "$infile"
            fi

            if (( $(date +%s) - start_ts >= UNIT_TIMEOUT_SECONDS )); then
                outcome="timeout"; break
            fi
        done

        touch "$stopflag"
        if [[ "$outcome" == "stop" ]]; then
            build_user_json_line "STOP REQUESTED by the operator. Wrap up immediately: do not start any new step, safely finish or cleanly abandon whatever single step you are mid-way through (do not leave a git operation half-done -- finish or revert it), then end your turn now." >> "$infile"
        fi
        end_stream_session "$claude_pid" "$STOP_GRACE_SECONDS"

        CLAUDE_TURN_OUTPUT=""
        [[ -f "$textfile" ]] && CLAUDE_TURN_OUTPUT="$(cat "$textfile")"
        record_turn_cost "$cost_label" "${SESSION_COST_USD:-}"

        case "$outcome" in
            done)
                rm -rf "$turn_dir"
                return 0
                ;;
            stop)
                STOP_KIND="user-stop"
                notify "$label: stopping now by operator request."
                rm -rf "$turn_dir"
                stop_run 0 "User requested /stop during: $label"
                ;;
            fail)
                record_turn_failure "$label" "reported an explicit blocked/failed marker" "$outfile" "$errfile"
                ;;
            error)
                if [[ -n "$MAX_TURN_BUDGET_USD" ]] && is_budget_exceeded "${LAST_SUBTYPE:-} ${LAST_TERMINAL_REASON:-}"; then
                    STOP_KIND="error"
                    rm -rf "$turn_dir"
                    stop_run 1 "$label exceeded its per-turn budget cap of \$${MAX_TURN_BUDGET_USD} (subtype: ${LAST_SUBTYPE:-unknown}). Retrying would very likely hit the same cap again, so stopping now instead of burning the retry budget on it -- raise MAX_TURN_BUDGET_USD in the script config if this was expected, or investigate why this turn needed that much."
                elif [[ "$LAST_API_ERROR_STATUS" == "429" ]] || is_quota_error "$CLAUDE_TURN_OUTPUT"$'\n'"$(cat "$errfile" 2>/dev/null)"; then
                    notify_important "$label hit a usage/rate limit (subtype: ${LAST_SUBTYPE:-unknown}). Waiting ${RETRY_WAIT_SECONDS}s before retrying (send /retry to skip the wait)..."
                    interruptible_sleep "$RETRY_WAIT_SECONDS"
                    if [[ "$INTERRUPTED_BY" == "stop" ]]; then
                        STOP_KIND="user-stop"
                        rm -rf "$turn_dir"
                        stop_run 0 "User requested /stop while waiting out a quota limit during: $label"
                    fi
                else
                    record_turn_failure "$label" "attempt failed (result subtype: ${LAST_SUBTYPE:-unknown})" "$outfile" "$errfile"
                fi
                ;;
            ended)
                if is_quota_error "$(cat "$errfile" 2>/dev/null)"; then
                    notify_important "$label hit a usage/rate limit before responding. Waiting ${RETRY_WAIT_SECONDS}s before retrying (send /retry to skip the wait)..."
                    interruptible_sleep "$RETRY_WAIT_SECONDS"
                    if [[ "$INTERRUPTED_BY" == "stop" ]]; then
                        STOP_KIND="user-stop"
                        rm -rf "$turn_dir"
                        stop_run 0 "User requested /stop while waiting out a quota limit during: $label"
                    fi
                else
                    record_turn_failure "$label" "ended unexpectedly with no result" "$outfile" "$errfile"
                fi
                ;;
            nudge_exhausted)
                record_turn_failure "$label" "still hadn't resolved after $MAX_BACKGROUND_NUDGES nudges" "$outfile" "$errfile"
                ;;
            timeout)
                record_turn_failure "$label" "timed out after ${UNIT_TIMEOUT_SECONDS}s" "$outfile" "$errfile"
                ;;
        esac

        rm -rf "$turn_dir"
        # loop retries with a brand-new session
    done
}

# Sets PLAN_PROMPT_INIT / PLAN_PROMPT_CONTINUE for a unit's planning turn.
build_plan_prompt() {
    local label="$1" marker="$2" scope_sentence="$3" plan_file="$4"

    local SHARED_MODULE_SYNC_SPLIT_NOTE=""
    if [[ -n "$SHARED_MODULE_SYNC_NOTE" ]]; then
        SHARED_MODULE_SYNC_SPLIT_NOTE="  - ${SHARED_MODULE_SYNC_NOTE} Never split such a change away from updating everything that consumes it -- that always belongs in the same task, never spread across tasks.
"
    fi

    PLAN_PROMPT_INIT=$(cat <<EOF
You are starting with zero prior conversation context, running unattended in
${REPO_DESCRIPTION}

First read ${ROADMAP_FILE} in full (not just the phase below -- it may have
cross-cutting sections, like a "never do X" list or the exit criteria of
earlier phases, that later work must not silently break) and these spec
files: ${SPEC_FILES}.

This is a PLANNING turn, not an implementation turn -- do not write or commit
any code. Your only job is to decide how to break $label into one or more
independently-implementable tasks, then write that decision to ${plan_file}.

$label's own scope, if implemented as a single turn, would be:
"${scope_sentence}"

Decide: is that genuinely small and cohesive enough for one focused
implementation turn to do well in one sitting? Or does it bundle several
mostly-independent pieces of work -- e.g. a mix of infra/ops decisions, data
model work, and app-facing features, or several deliverables that could each
be verified on their own -- where a single turn is more likely to lose track
of scope, or reach for a shortcut on the part it understands least, than to
do the whole thing right? Bias toward NOT splitting: most units are fine as
one turn. Only split when the heterogeneity is real. A phase whose
deliverables span several genuinely unrelated concerns (e.g. a data-model
change, an auth/permissions change, and an unrelated user-facing feature all
in one phase) is exactly the kind of case that usually IS worth splitting; a
phase that is one coherent piece of work usually is not.

Write your decision to ${plan_file}:
- If you decide NOT to split, the file must contain exactly one line,
  containing exactly this text (copy it verbatim):
  ${scope_sentence}
- If you decide TO split, write 2-6 lines, one per task, in the order they
  should be implemented, and nothing else in the file. Each line must be a
  single self-contained instruction sentence that names which roadmap
  deliverable(s) it covers (so nothing gets dropped), e.g. "Build the
  database schema for organisations, memberships, and the role matrix
  (roadmap 'Organisations, memberships, roles, invitations' and 'Role matrix'
  deliverables of this phase)." Requirements for the split itself:
  - Order tasks so each is buildable on top of the commits of the ones
    before it -- they will run as separate turns, each starting fresh with
    no memory of the others, seeing only what previous tasks already
    committed.
${SHARED_MODULE_SYNC_SPLIT_NOTE}  - Do not invent scope beyond what $label already calls for.

Do not touch any product code, and do not edit ${ROADMAP_FILE}.

This is a non-interactive, unattended run. It is not one-shot anymore --
your input stream stays open, so if the operator sends you a message mid-turn
(an "OPERATOR MESSAGE" or "OPERATOR NOTE" block) treat it as a real
instruction from the person running this, and act on it immediately. Nothing
else will resume or notify you if you stop responding without finishing,
though, so do not end your turn until ${plan_file} is written and one of the
markers below has been output.

When you are done writing ${plan_file}, output exactly one of these as the
very last line of your final message:
${marker}_PLAN_SPLIT
${marker}_PLAN_NOSPLIT
(or, if you are genuinely unable to even read the roadmap/repo state to make
this decision:)
${marker}_PLAN_FAILED: <short reason>
EOF
)

    PLAN_PROMPT_CONTINUE=$(cat <<EOF
Checking in: are you still working, or did you stop responding without
finishing? If you have a slow command running, check on it now and use its
result. Continue exactly where you left off planning $label -- check whether
${plan_file} was already written; if not, finish deciding and write it now.
No one else is watching for this to complete, so do not end your turn again
until ${plan_file} exists and you have output one of:
${marker}_PLAN_SPLIT
${marker}_PLAN_NOSPLIT
${marker}_PLAN_FAILED: <short reason>
EOF
)
}

# Sets IMPLEMENT_PROMPT_INIT / IMPLEMENT_PROMPT_CONTINUE for one task's
# implementation turn (a task is either a real sub-task from a split unit, or
# the whole unit when the plan turn chose not to split).
build_implement_prompt() {
    local label="$1" task_marker="$2" scope_sentence="$3" commit_prefix="$4" \
          verify_sentence="$5" task_context="$6" findings_block="$7"

    # Appended at the very end of the prompt (after the outcome-marker
    # instructions), not inline where the task description used to reference
    # it -- keeps everything above it byte-identical across retries of the
    # SAME task (only this block changes attempt to attempt), which is what
    # lets the API's prompt cache actually hit on a retry instead of
    # re-billing the whole prompt at full price every time.
    local findings_section=""
    if [[ -n "$findings_block" ]]; then
        findings_section=$(cat <<EOF

STOP -- READ THIS BEFORE YOU START, EVEN THOUGH IT'S THE LAST THING IN THIS
PROMPT: a review or verification pass already found issues with your
PREVIOUS attempt at this exact task:
${findings_block}
The previous attempt's commit(s) are already in the repo -- read them first,
then fix the issues above. Build on that work (amend, or add follow-up
commits) rather than starting over, UNLESS the findings say the fundamental
approach was wrong, in which case redo the affected part properly.
EOF
)
    fi

    local shared_module_block=""
    if [[ -n "$SHARED_MODULE_SYNC_NOTE" ]]; then
        shared_module_block=$(cat <<EOF

SHARED-MODULE SYNC -- IMPORTANT RULE OF THIS RUN:
${SHARED_MODULE_SYNC_NOTE}
EOF
)
    fi

    local verify_block
    if [[ -n "$GATE_CMD" ]]; then
        verify_block=$(cat <<EOF
- From the repo root$( [[ -n "$INSTALL_CMD" ]] && echo ", run \`${INSTALL_CMD}\` if needed," ), then run:
  \`${GATE_CMD}\`
  and make sure it passes for everything your change touches. ${verify_sentence}
  A script-level gate independently re-runs this same command after you
  finish, outside your control -- it will not trust a claim that it passes,
  so make sure it actually does before you end your turn.
EOF
)
    else
        verify_block="- ${verify_sentence} This repo has no automated verification command configured -- use your own judgement and whatever manual checks are appropriate to confirm your change actually works."
    fi

    IMPLEMENT_PROMPT_INIT=$(cat <<EOF
You are starting with zero prior conversation context, running unattended in
${REPO_DESCRIPTION}

First read, in ${ROADMAP_FILE}, this unit's own section in full plus every
cross-cutting part (hard constraints, "never do X" lists, conventions) --
skip other phases' deliverable lists. Then read whichever of these spec files
bear on this task, as deeply as the task needs: ${SPEC_FILES}. An independent
reviewer reads all of them in full afterwards.

${scope_sentence} Match the existing conventions of whichever part of the
repo you are editing.

CONTEXT HYGIENE: redirect the output of any build, test, lint, install or
docker command that can be long (gradle, xcodebuild, npm test, compose logs,
...) to a file and read only its tail or grep it for failures -- never let a
full build or test log land in your context.
${task_context}${shared_module_block}
VERIFICATION:
${verify_block}
- If part of this task can only be VERIFIED with production infrastructure,
  real third-party credentials, or a physical device -- i.e. the code itself
  is fully written and would work, you just cannot prove it from this
  machine -- implement the code fully anyway, verify everything that CAN be
  verified locally, and record the deferred verification in the commit
  message. That counts as COMPLETE, not PARTIAL or FAILED; see below.
- Do not start any multi-gigabyte download or provision any real paid cloud
  resource; build and test against small local fixtures instead.

A second, independent review pass (not you, fresh context, has not seen your
reasoning) will read your diff after the deterministic gate above passes. It
is specifically briefed to check for a deliverable being satisfied in letter
while a broader constraint stated elsewhere in the roadmap or its spec files
is violated -- so satisfy the actual intent, not just the literal wording of
this task's own deliverables. After that, a third turn writes a
human QA/testing document covering this unit's whole diff -- nothing further
is asked of you for that, just make sure your commits and commit messages
accurately describe what you actually did, since that turn reads them too.

Do not edit ${ROADMAP_FILE} yourself -- the runner script that invoked you
handles marking this unit complete there once every task for it has passed
review.

This is a non-interactive, unattended run. It is not one-shot anymore --
your input stream stays open, so if the operator sends you a message mid-turn
(an "OPERATOR MESSAGE" or "OPERATOR NOTE" block) treat it as a real
instruction from the person running this, and act on it immediately. If you
run a slow command (tests, builds, docker pulls, etc.), wait for it to
finish yourself and check its result before ending your turn -- do not end
your turn early expecting a background task or a scheduled check-in to
report back, because no such notification will ever arrive on its own.

When you are done, you have FOUR possible outcomes -- read all four before
picking one, they are easy to conflate:

1. COMPLETE -- every deliverable this task covers is actually implemented
   (production-infra/credential-only verification gaps are still COMPLETE,
   per VERIFICATION above). Commit your changes with clear messages prefixed
   "${commit_prefix}:". Then output exactly this as the very last line of
   your final message:
   ${task_marker}_COMPLETE

2. PARTIAL -- everything is implemented and committed EXCEPT one or more
   specific deliverables that cannot be done right now for one of exactly
   two reasons: (a) the item itself depends on a later phase of
   ${ROADMAP_FILE} that has not been built yet (not "is hard" or "is
   ambiguous" -- genuinely cannot exist until that other phase ships), or (b)
   it requires an operator-only action nobody but a human can take from
   outside this machine (registering a legal entity, creating accounts or
   app-store/marketplace entries under a provider's dashboard, obtaining a
   production credential that requires identity verification, DNS changes on
   a domain you don't control) -- as opposed to merely a credential to VERIFY
   already-complete code, which
   is COMPLETE per above, not this. Do not use PARTIAL as a way to skip
   something merely difficult or time-consuming -- only for a genuine
   external dependency. Commit everything you did finish, the same as in
   COMPLETE above, then output exactly this as the last line of your final
   message, one entry per deferred item, entries separated by "; " if there
   is more than one:
   ${task_marker}_PARTIAL: <deliverable text, copied VERBATIM from
   ${ROADMAP_FILE}>::<short reason it genuinely can't be done yet>
   A second reviewer turn will specifically judge whether each deferral is
   legitimate -- an unjustified PARTIAL comes back as review issues exactly
   like an incomplete COMPLETE would.

3. NEEDS_INPUT -- you are NOT ambiguous about what to build, and this is NOT
   a later-phase dependency or an operator-only action you can cleanly defer
   (that's PARTIAL, above). You are blocked because doing this task properly
   requires something only the human operator can provide RIGHT NOW, and the
   result would be materially worse without it -- e.g. a real third-party
   API key/secret/credential the code needs to actually function (not just
   to be verified -- a missing verification-only credential is COMPLETE per
   VERIFICATION above), a third-party account/app/marketplace registration
   that gates what you're building, a business/legal/product decision only
   the operator can make, or data only the operator has. Do NOT invent a
   placeholder value, a fake credential, or guess at a decision to keep
   moving -- that produces work that looks done but silently isn't, which is
   worse than stopping. Commit only whatever is genuinely finished and does
   not depend on the missing input (nothing half-done or broken -- same rule
   as FAILED below). This is a stronger, rarer outcome than PARTIAL: it
   halts the ENTIRE automated run, not just this task, so use it only when
   the missing thing is truly mission-critical to doing this task well, not
   merely convenient to have. Then output exactly this as the last line of
   your final message:
   ${task_marker}_NEEDS_INPUT: <exactly what you need from the operator --
   name the specific secret/credential/account/decision>::<why the result
   would be materially worse without it, specifically -- not just "it would
   help">

4. FAILED -- you cannot finish this task AT ALL (truly blocked: ambiguous
   spec, broken toolchain, local infrastructure that will not start; this is
   different from PARTIAL, which still finishes and commits everything else,
   and different from NEEDS_INPUT, which is specifically about something
   only the operator can provide, not an internal blocker).
   Do not commit broken or partial-and-undisclosed work. Instead output
   exactly this as the last line of your final message:
   ${task_marker}_FAILED: <short reason>
${findings_section}
EOF
)

    IMPLEMENT_PROMPT_CONTINUE=$(cat <<EOF
Checking in: are you still working, or did you stop responding without
finishing? Most likely you started a slow command (tests, builds, downloads,
etc.) and stopped responding before it finished -- no one else is watching
for it to complete, so check on it now. If it's still running, wait for it
to finish before doing anything else; if it already finished, use its
result. Do not end this turn again until you know whether this task's
deliverables and verification pass.

Then follow the same completion instructions as before.${SHARED_MODULE_SYNC_NOTE:+ Remember: ${SHARED_MODULE_SYNC_NOTE}} Do not edit ${ROADMAP_FILE} yourself. Recall there are four
possible outcomes:
1. If everything passes, commit your changes, then output exactly this as
   the very last line of your final message:
   ${task_marker}_COMPLETE
2. If everything is done except one or more deliverables that genuinely
   depend on a not-yet-built phase or an operator-only action (not merely a
   credential needed to VERIFY otherwise-complete code -- that's COMPLETE),
   commit what you did finish, then output exactly this as the last line,
   items separated by "; " if more than one:
   ${task_marker}_PARTIAL: <deliverable text, copied VERBATIM from
   ${ROADMAP_FILE}>::<short reason>
3. If this task genuinely cannot be done well without something only the
   operator can provide right now (a real credential the code needs to
   function, an account/registration, a decision only they can make -- not
   merely convenient, mission-critical), do not guess or use a placeholder.
   Commit only what's genuinely finished, then output exactly this as the
   last line:
   ${task_marker}_NEEDS_INPUT: <exactly what you need>::<why the result
   would be materially worse without it>
4. If you cannot finish this task at all, do not commit broken or
   partial-and-undisclosed work. Instead output exactly this as the last line
   of your final message:
   ${task_marker}_FAILED: <short reason>
EOF
)
}

# Sets REVIEW_PROMPT_INIT / REVIEW_PROMPT_CONTINUE for one task's independent
# review turn. repo_before is the git HEAD before this task's implement turn
# started ("" if no new commits landed), used to point the reviewer at
# exactly this task's diff. deferred_claim is the raw text after
# "${task_marker}_PARTIAL:" if the implementer reported PARTIAL, empty for an
# ordinary COMPLETE.
build_review_prompt() {
    local label="$1" task_marker="$2" task_scope="$3" repo_before="$4" deferred_claim="$5"

    # Appended at the very end of the prompt (after the verdict-marker
    # instructions) rather than inline near "WHAT WAS SUPPOSED TO HAPPEN" --
    # keeps that stable, task-scope-only prefix identical across review
    # cycles of the same task, for whatever prompt-cache benefit is left
    # once the (inherently per-attempt-unique) diff/commit-sha hint below it
    # already breaks the match.
    local deferred_section=""
    if [[ -n "$deferred_claim" ]]; then
        deferred_section=$(cat <<EOF

STOP -- READ THIS BEFORE YOU FINALIZE YOUR VERDICT ABOVE, EVEN THOUGH IT'S
THE LAST THING IN THIS PROMPT: the implementer reported this as PARTIAL, not
COMPLETE -- it claims the following deliverable(s) genuinely cannot be done
yet and deferred them (format: item text::reason), while everything else in
the task's scope is claimed done:
${deferred_claim}
Judge each deferral on its own merits: is it TRUE that this item depends on
a phase of ${ROADMAP_FILE} that hasn't been built yet, or on an
operator-only action nobody but a human can perform from outside this
machine? Or could the implementer actually have done it and is using PARTIAL
to dodge real work (the same shortcut-signing risk described below, just
taking the form of an honest-looking excuse instead of a fake pass)? If a
deferral is not legitimate, treat it exactly like an unfinished deliverable
-- report it as a review issue naming the item and why the excuse doesn't
hold up. Also check that everything the implementer did NOT defer is
actually complete -- a legitimate deferral for item X does not excuse
skipping items Y and Z.
EOF
)
    fi

    local repo_diff_hint
    if [[ -n "$repo_before" ]]; then
        repo_diff_hint="Run \`git log --oneline ${repo_before}..HEAD\` and \`git diff ${repo_before}..HEAD\` to see exactly what this task changed."
    else
        repo_diff_hint="No new commits were found from this task -- that is itself worth flagging as a review issue unless the task was a no-op by its own nature."
    fi

    local gate_note="A deterministic gate (plain script, not an LLM) has already independently re-run this repo's own verification command against this diff and it passed -- do not re-run it or the full test suites; spend your attention on what automation can't check. If you do run a command with long output, redirect it to a file and read only the tail or grep it."
    [[ -z "$GATE_CMD" ]] && gate_note="This repo has no automated verification gate configured, so nothing has been independently re-verified yet -- factor that into how much scrutiny you give correctness, not just intent."

    local constraints_block=""
    if [[ -n "$CROSS_CUTTING_CONSTRAINTS" ]]; then
        constraints_block=$(cat <<EOF
 This repo's own hard, easy-to-quietly-break constraints (not exhaustive,
read the actual docs too) include:
${CROSS_CUTTING_CONSTRAINTS}
EOF
)
    fi

    local shared_module_check=""
    if [[ -n "$SHARED_MODULE_SYNC_NOTE" ]]; then
        shared_module_check="- ${SHARED_MODULE_SYNC_NOTE} Was every consumer actually updated to match, not left pointing at the old shape?
"
    fi

    REVIEW_PROMPT_INIT=$(cat <<EOF
You are starting with zero prior conversation context, running unattended in
${REPO_DESCRIPTION}
You are an independent REVIEWER -- you did not write this code and have not
seen the implementer's reasoning, that is deliberate.

First read the FULL ${ROADMAP_FILE} (not just the phase you are reviewing --
it may have cross-cutting sections, like a "never cut"/"never do X" list or
earlier phases' exit criteria, that apply beyond the phase being reviewed
and are easy to miss if you only read that one section) and these spec
files: ${SPEC_FILES}.

WHAT WAS SUPPOSED TO HAPPEN (the task an implementer just finished):
"${task_scope}"

WHAT TO LOOK AT:
${repo_diff_hint}

${gate_note}

ASSUME THE IMPLEMENTER MAY HAVE TAKEN A SHORTCUT THAT LOOKS COMPLETE ON THE
SURFACE. A task narrowly scoped to one phase's deliverables can satisfy them
in letter while violating a broader constraint stated elsewhere in the
roadmap or its spec files in spirit.${constraints_block}
Do not trust the implementer's commit message as evidence of what it
actually did -- read the diff yourself.

Also check:
- Does the diff actually match what "${task_scope}" asked for -- no less
  (silently skipped or stubbed parts) and no more (scope creep)?
${shared_module_check}- Anything that looks like it was faked, stubbed, or deferred without being
  honestly recorded as deferred in the commit message.

You must NOT edit or commit any code, and must NOT edit ${ROADMAP_FILE}. You
are a reviewer, not a fixer -- if you find a real problem, report it; a
fresh implement turn will receive your findings and fix them.

This is a non-interactive, unattended run. It is not one-shot anymore --
your input stream stays open, so if the operator sends you a message mid-turn
(an "OPERATOR MESSAGE" or "OPERATOR NOTE" block) treat it as a real
instruction from the person running this, and act on it immediately. Nothing
else will resume or notify you if you stop responding without finishing.

When you are done, output exactly one line as the very last line of your
final message:
- If the work genuinely holds up:
  ${task_marker}_REVIEW_OK
- If you found real problems (be specific and concrete enough that a fresh
  implementer with no other context knows exactly what to fix; separate
  multiple findings with semicolons on this same line):
  ${task_marker}_REVIEW_ISSUES: <finding 1>; <finding 2>
${deferred_section}
EOF
)

    REVIEW_PROMPT_CONTINUE=$(cat <<EOF
Checking in: are you still working, or did you stop responding without
finishing? Continue exactly where you left off reviewing $label. If you had
a command running, check on it now and use its result. No one else is
watching for this to complete, so do not end this turn again until you have
a verdict. Then output exactly one of:
${task_marker}_REVIEW_OK
${task_marker}_REVIEW_ISSUES: <findings, semicolon-separated if more than one>
EOF
)
}

# Sets DOCUMENT_PROMPT_INIT / DOCUMENT_PROMPT_CONTINUE for a unit's
# DOCUMENT-stage turn -- see stage 5 in the file header. unit_start_head is
# the git HEAD captured before this unit's first task began (see
# save_unit_start_head), used to diff the unit's ENTIRE combined change,
# regardless of how many tasks it took or how many times the run resumed in
# between. deferred_block is a pre-formatted list of anything this unit
# legitimately deferred (empty string if nothing was).
build_document_prompt() {
    local label="$1" marker="$2" unit_start_head="$3" doc_path="$4" deferred_block="$5" review_notes="$6"

    local review_notes_block=""
    if [[ -n "$review_notes" ]]; then
        review_notes_block=$(cat <<EOF

The independent reviewer(s) who cleared this unit's diff (same diff you're
about to read) left these notes while doing so -- they may point at risk
areas or subtleties worth emphasizing in the manual testing checklist below,
so read them before you start writing rather than treating them as an
afterthought:
${review_notes}
EOF
)
    fi

    local diff_hint
    if [[ -n "$unit_start_head" ]]; then
        diff_hint="Run \`git log --oneline ${unit_start_head}..HEAD\` and \`git diff ${unit_start_head}..HEAD\` to see everything this unit changed. A handful of those commits may be this runner script's own bookkeeping (messages starting \"Roadmap: ...\", touching only ${PROGRESS_FILE}, ${ROADMAP_FILE}, or ${TASKS_DIR}) -- note them only in passing, do not describe them as feature work."
    else
        diff_hint="No commit range could be determined -- run \`git log -20 --oneline\` and use your judgement about which recent commits belong to this unit."
    fi

    DOCUMENT_PROMPT_INIT=$(cat <<EOF
You are starting with zero prior conversation context, running unattended in
${REPO_DESCRIPTION}
You did not write this code. Your job is to produce a
single, high-quality markdown document that a human QA tester -- who was NOT
involved in building this and has no other context -- will use as their
PRIMARY reference to understand and manually test everything that just
shipped in "$label". Treat this as a genuinely important deliverable, not a
formality: it is the one artifact a human will actually read end to end, and
it will be extensively relied on for real QA. Write it to the highest
standard you can.

First read the FULL ${ROADMAP_FILE} and these spec files: ${SPEC_FILES}, so
you understand what this unit was supposed to deliver and any cross-cutting
constraints (auth/entitlements rules, caching rules, etc.) it had to respect.

${diff_hint}
${review_notes_block}
${deferred_block}
Write the document to ${doc_path} with this structure (adapt headings to the
actual content, but cover all of these sections, in this order):

1. A title and a short (3-6 sentence) summary of what this unit shipped.
2. "What changed" -- organized by area (e.g. by app/package), describe what
   was added, altered, or fixed. Be concrete: name the actual
   endpoints/components/tables/flows, not vague summaries like "improved
   the API."
3. "How it was implemented" -- key design decisions, notable approaches,
   anything a reviewer would want to know about *why* it was built this
   way, especially anything non-obvious or any tradeoff that was made.
4. "Files touched" -- a grouped list (by app/package) of the files this
   unit's diff changed.
5. "Left out / deferred" -- anything genuinely deferred and why (see above
   if this unit had any), or state plainly "Nothing was deferred" if not.
6. "Other notes" -- new env vars, migrations that need running, follow-up
   work implied but not done, risks worth flagging to a human.
7. "Manual testing checklist" -- THE MOST IMPORTANT SECTION, and the reason
   this document exists. One subsection per distinct feature/change touched
   by this unit. Each subsection needs:
   - Prerequisites/setup: exact commands to get the app into a testable
     state (which services to start, seed data needed, accounts to use,
     env vars to set).
   - Numbered, literal step-by-step instructions a human can follow with
     zero prior knowledge of this feature -- exact URLs/routes, exact
     buttons/fields, exact values to type.
   - The exact expected result after each meaningful step (what should be
     visible/return/persist), not just "it should work."
   - Edge cases / negative paths worth checking, not just the happy path --
     draw on the cross-cutting constraints in the roadmap and spec files
     where they apply to what you're testing, whatever is actually relevant
     to THIS unit.
   Write this section as if you suspect a careless implementation could
   have silently cut a corner -- the checklist should be able to catch it,
   not just confirm the obvious happy path.

Formatting: write prose paragraphs as a single continuous line each, with no
manual line-wrapping (do not break a paragraph onto multiple lines at ~80
columns the way a text editor would). Our markdown reader renders every
newline literally instead of reflowing soft-wrapped text, so hard-wrapped
paragraphs show up as broken, choppy lines -- let the reader's own word-wrap
handle line breaks within a paragraph. Line breaks are fine (expected, even)
between headings, list items, and paragraphs -- just not inside one.

Do not edit any product code, and do not edit ${ROADMAP_FILE} yourself.

This is a non-interactive, unattended run. It is not one-shot anymore --
your input stream stays open, so if the operator sends you a message mid-turn
treat it as a real instruction and act on it immediately. If you run a slow
command, wait for it to finish and check its result before ending your turn.

When ${doc_path} is fully written to the standard above, output exactly one
of these as the very last line of your final message:
${marker}_WRITTEN
(or, if you genuinely cannot produce it -- e.g. the diff is unreadable:)
${marker}_FAILED: <short reason>
EOF
)

    DOCUMENT_PROMPT_CONTINUE=$(cat <<EOF
Checking in: are you still working, or did you stop responding without
finishing? Continue exactly where you left off writing the QA document for
$label at ${doc_path}. Check what you've already written (if anything) and
finish it properly -- do not start over from scratch, but do not leave it
half-finished either. If you had a slow command running, check its result
now. No one else is watching for this to complete. When finished, output
exactly one of:
${marker}_WRITTEN
${marker}_FAILED: <short reason>
EOF
)
}

# Independently re-verifies the repo (plain bash, no LLM) after an implement
# turn claims COMPLETE/PARTIAL, so completion never rests solely on the
# implementer's self-report. Runs the target repo's own INSTALL_CMD/GATE_CMD
# from its config, from WORKSPACE_DIR. A no-op if GATE_CMD is empty ("" is
# the default -- a repo with no automated verification command relies solely
# on the implementer's and reviewer's own judgement). Returns 0 (pass) or 1
# (fail); on failure, output is appended to LOG_FILE.
run_verification_gate() {
    local label="$1"
    if [[ -z "$GATE_CMD" ]]; then
        notify "$label: no GATE_CMD configured for this repo -- skipping the deterministic verification gate."
        return 0
    fi
    notify "$label: running deterministic verification gate..."
    local gate_output gate_exit
    gate_output=$(cd "$WORKSPACE_DIR" && GATE_CMD="$GATE_CMD" INSTALL_CMD="$INSTALL_CMD" \
        run_with_timeout "$UNIT_TIMEOUT_SECONDS" bash -c '
        set -uo pipefail
        status=0
        if [[ -n "$INSTALL_CMD" ]]; then
            eval "$INSTALL_CMD" 2>&1
            status=$?
        fi
        if (( status == 0 )); then
            eval "$GATE_CMD" 2>&1
            status=$?
        fi
        exit $status
    ' 2>&1)
    gate_exit=$?
    if (( gate_exit != 0 )); then
        notify "$label: deterministic gate FAILED (exit $gate_exit). See $LOG_FILE."
        echo "$gate_output" >> "$LOG_FILE"
        # Kept on its own so the retry turn gets the failure itself, not a
        # log file full of every earlier turn's raw stream-json.
        printf '%s\n' "$gate_output" > "$GATE_OUTPUT_FILE"
        return 1
    fi
    notify "$label: deterministic gate passed."
    return 0
}

# ---------------------------------------------------------------------------
# MAIN LOOP: one unit at a time. Each unit is planned (or resumes an
# existing plan), then run task-by-task through IMPLEMENT -> GATE -> REVIEW,
# then documented once every task has passed.
# ---------------------------------------------------------------------------
for (( i=START_INDEX; i<=MAX_INDEX; i++ )); do
    UNIT="${UNIT_IDS[$i]}"
    P="${UNIT_PHASE[$UNIT]}"
    TITLE="${UNIT_TITLE[$UNIT]}"
    IS_GROUP="${UNIT_ISGROUP[$UNIT]}"
    LABEL="$(describe_unit "$UNIT")"
    MARKER="PHASE_${UNIT//./_}"
    CURRENT_UNIT_LABEL="$LABEL"
    CURRENT_TASK_INDEX=""; CURRENT_TASK_TOTAL=""; CURRENT_TASK_SCOPE=""

    save_unit_start_head "$UNIT"

    if (( IS_GROUP )); then
        SCOPE_SENTENCE="Implement ONLY Section ${UNIT} (\"${TITLE}\") of Phase ${P}. This phase is split into sections in ${ROADMAP_FILE} (### headings) -- do not start any other section of this phase or any other phase, and do not exceed what this section's own deliverables require."
        COMMIT_PREFIX="Phase ${UNIT}"
        VERIFY_SENTENCE="Verify this section's own deliverables are correctly implemented and that relevant tests pass. The phase's overall exit criterion (at the end of the Phase ${P} block) may depend on sections not yet implemented in later turns -- that's expected, not a failure of this turn."
    else
        SCOPE_SENTENCE="Implement ONLY Phase ${P}: ${TITLE}. Do not start any other phase, and do not exceed what its exit criterion requires."
        COMMIT_PREFIX="Phase ${P}"
        VERIFY_SENTENCE="Verify the phase's exit criterion actually holds, not just that code compiles."
    fi

    # -----------------------------------------------------------------
    # PLAN (or load an existing plan left over from a previous, interrupted
    # run of this same unit -- never re-planned once written).
    # -----------------------------------------------------------------
    PLAN_FILE="${TASKS_DIR}/${UNIT}.tasks"

    if [[ -s "$PLAN_FILE" ]]; then
        mapfile -t TASKS < <(grep -v '^[[:space:]]*$' "$PLAN_FILE")
    elif (( IS_GROUP )) && [[ "$SKIP_PLAN_FOR_SECTIONS" == "true" ]]; then
        # A ### section is already a split the roadmap author made -- a whole
        # Claude turn to decide "don't split" isn't worth its tokens.
        printf '%s\n' "$SCOPE_SENTENCE" > "$PLAN_FILE"
        TASKS=("$SCOPE_SENTENCE")
        commit_progress_if_repo "Roadmap: $LABEL plan written (1 task, section -- plan turn skipped)"
    else
        set_stage "planning $LABEL"
        notify "Planning $LABEL"
        build_plan_prompt "$LABEL" "$MARKER" "$SCOPE_SENTENCE" "$PLAN_FILE"
        run_claude_turn "$LABEL (plan)" "$PLAN_PROMPT_INIT" "$PLAN_PROMPT_CONTINUE" \
            "${MARKER}_PLAN_SPLIT|${MARKER}_PLAN_NOSPLIT" "${MARKER}_PLAN_FAILED" PLAN

        if [[ ! -s "$PLAN_FILE" ]]; then
            # Defensive fallback: the planning turn reported success but did
            # not actually leave a well-formed task file behind. Proceed as
            # if it had chosen not to split rather than stalling the run
            # over a formatting slip.
            notify "$LABEL: plan turn did not leave a usable task file; proceeding unsplit."
            printf '%s\n' "$SCOPE_SENTENCE" > "$PLAN_FILE"
        fi
        mapfile -t TASKS < <(grep -v '^[[:space:]]*$' "$PLAN_FILE")
        if (( ${#TASKS[@]} > 1 )); then
            notify "$LABEL: planning turn split this unit into ${#TASKS[@]} tasks."
        fi
        commit_progress_if_repo "Roadmap: $LABEL plan written (${#TASKS[@]} task(s))"
    fi

    # -----------------------------------------------------------------
    # IMPLEMENT -> GATE -> REVIEW, one task at a time.
    # -----------------------------------------------------------------
    for (( t=1; t<=${#TASKS[@]}; t++ )); do
        if is_task_completed "$UNIT" "$t"; then
            continue
        fi

        if (( ${#TASKS[@]} == 1 )); then
            TASK_SCOPE="${TASKS[0]}"
            TASK_CONTEXT=""
            TASK_LABEL="$LABEL"
        else
            TASK_SCOPE="${TASKS[$((t-1))]}"
            TASK_CONTEXT=$(cat <<EOF

TASK SCOPE: This is task ${t} of ${#TASKS[@]} that together implement
$LABEL (split decided by an earlier planning turn; full list in
${PLAN_FILE}). Implement ONLY this task: "${TASK_SCOPE}"
Do not attempt any other task from that list -- earlier tasks (1..$((t-1)))
are already committed in the repo for you to build on; later tasks are
handled in separate future turns. Do not exceed what this task's own
instruction requires.
EOF
)
            TASK_LABEL="$LABEL, task $t/${#TASKS[@]}"
        fi

        CURRENT_TASK_INDEX="$t"; CURRENT_TASK_TOTAL="${#TASKS[@]}"; CURRENT_TASK_SCOPE="$TASK_SCOPE"

        TASK_MARKER="${MARKER}_T${t}"
        FINDINGS=""
        gate_fail_count=0
        review_cycle=0
        task_done=false

        if load_task_state_if_matching "$UNIT" "$t"; then
            : # FINDINGS/gate_fail_count/review_cycle already restored
        else
            clear_task_state
        fi

        while [[ "$task_done" == false ]]; do
            REPO_HEAD_BEFORE="$(git rev-parse HEAD 2>/dev/null || true)"

            set_stage "implementing $TASK_LABEL"
            notify "Starting $TASK_LABEL"
            build_implement_prompt "$TASK_LABEL" "$TASK_MARKER" "$TASK_SCOPE" "$COMMIT_PREFIX" \
                "$VERIFY_SENTENCE" "$TASK_CONTEXT" "$FINDINGS"
            run_claude_turn "$TASK_LABEL" "$IMPLEMENT_PROMPT_INIT" "$IMPLEMENT_PROMPT_CONTINUE" \
                "${TASK_MARKER}_COMPLETE|${TASK_MARKER}_PARTIAL|${TASK_MARKER}_NEEDS_INPUT" "${TASK_MARKER}_FAILED" IMPLEMENT
            IMPLEMENT_TURN_OUTPUT="$CLAUDE_TURN_OUTPUT"

            # NEEDS_INPUT is checked FIRST and is terminal for the whole run,
            # not just this task -- unlike PARTIAL (which defers and keeps
            # going) this means the task genuinely cannot be done well
            # without something only the operator can provide. Do not run
            # the gate or review, do not mark the task complete, do not
            # touch the roadmap -- just stop and say exactly what's needed,
            # see NEEDS_INPUT HANDLING in the file header.
            if grep -qE "${TASK_MARKER}_NEEDS_INPUT:" <<<"$IMPLEMENT_TURN_OUTPUT"; then
                NEEDS_INPUT_CLAIM="$(grep -oE "${TASK_MARKER}_NEEDS_INPUT:.*" <<<"$IMPLEMENT_TURN_OUTPUT" | tail -1 | sed -E "s/^${TASK_MARKER}_NEEDS_INPUT:[[:space:]]*//")"
                NEEDS_INPUT_ITEM="${NEEDS_INPUT_CLAIM%%::*}"
                NEEDS_INPUT_REASON="${NEEDS_INPUT_CLAIM#*::}"
                STOP_KIND="needs-input"
                stop_run 1 "$TASK_LABEL cannot proceed without operator-provided information. Needed: ${NEEDS_INPUT_ITEM}. Why: ${NEEDS_INPUT_REASON}. See ${RESUME_DOC} for how to resume once it's provided."
            fi

            TASK_PARTIAL_CLAIM=""
            if grep -qE "${TASK_MARKER}_PARTIAL:" <<<"$IMPLEMENT_TURN_OUTPUT"; then
                TASK_PARTIAL_CLAIM="$(grep -oE "${TASK_MARKER}_PARTIAL:.*" <<<"$IMPLEMENT_TURN_OUTPUT" | tail -1 | sed -E "s/^${TASK_MARKER}_PARTIAL:[[:space:]]*//")"
                notify "$TASK_LABEL implementation reported PARTIAL (deferred: ${TASK_PARTIAL_CLAIM}); running deterministic gate."
            else
                notify "$TASK_LABEL implementation complete; running deterministic gate."
            fi

            set_stage "gate-checking $TASK_LABEL"
            if ! run_verification_gate "$TASK_LABEL"; then
                gate_fail_count=$((gate_fail_count + 1))
                save_task_state "$UNIT" "$t"
                if (( gate_fail_count >= MAX_NON_QUOTA_RETRIES )); then
                    STOP_KIND="error"
                    stop_run 1 "$TASK_LABEL failed the deterministic gate $MAX_NON_QUOTA_RETRIES times. Stopping run for manual review."
                fi
                FINDINGS="The deterministic gate (an independent re-run of this repo's GATE_CMD, outside your control) failed after your last attempt. The last ${GATE_FINDINGS_TAIL_LINES} lines of its output are below; the full output is in ${GATE_OUTPUT_FILE} (grep it, don't read it whole). Fix whatever is causing it to fail before ending your turn again.
$(tail -n "$GATE_FINDINGS_TAIL_LINES" "$GATE_OUTPUT_FILE" 2>/dev/null)"
                save_task_state "$UNIT" "$t"
                continue
            fi

            REPO_HEAD_AFTER="$(git rev-parse HEAD 2>/dev/null || true)"
            [[ "$REPO_HEAD_AFTER" == "$REPO_HEAD_BEFORE" ]] && REPO_HEAD_BEFORE=""

            set_stage "reviewing $TASK_LABEL"
            notify "Starting review of $TASK_LABEL"
            build_review_prompt "$TASK_LABEL" "$TASK_MARKER" "$TASK_SCOPE" "$REPO_HEAD_BEFORE" "$TASK_PARTIAL_CLAIM"
            run_claude_turn "$TASK_LABEL (review)" "$REVIEW_PROMPT_INIT" "$REVIEW_PROMPT_CONTINUE" \
                "${TASK_MARKER}_REVIEW_OK|${TASK_MARKER}_REVIEW_ISSUES" "" REVIEW

            if grep -qE "${TASK_MARKER}_REVIEW_OK" <<<"$CLAUDE_TURN_OUTPUT"; then
                notify "$TASK_LABEL passed review."
                append_unit_review_note "$UNIT" "$t" "${CLAUDE_TURN_OUTPUT//${TASK_MARKER}_REVIEW_OK/}"
                if [[ -n "$TASK_PARTIAL_CLAIM" ]]; then
                    IFS=';' read -ra DEFERRED_ENTRIES <<< "$TASK_PARTIAL_CLAIM"
                    for entry in "${DEFERRED_ENTRIES[@]}"; do
                        entry="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$entry")"
                        [[ -z "$entry" ]] && continue
                        deferred_item="${entry%%::*}"
                        deferred_reason="${entry#*::}"
                        mark_task_deferred "$UNIT" "$t" "$deferred_item" "$deferred_reason"
                        notify "$TASK_LABEL: deferring deliverable (recorded in ${ROADMAP_FILE}'s automation notes): \"$deferred_item\" -- $deferred_reason"
                    done
                fi
                mark_task_completed "$UNIT" "$t"
                clear_task_state
                commit_progress_if_repo "Roadmap: $LABEL, task $t/${#TASKS[@]} implemented and reviewed"
                task_done=true
            else
                review_cycle=$((review_cycle + 1))
                FINDINGS="$(grep -oE "${TASK_MARKER}_REVIEW_ISSUES:.*" <<<"$CLAUDE_TURN_OUTPUT" | tail -1 | sed -E "s/^${TASK_MARKER}_REVIEW_ISSUES:[[:space:]]*//")"
                notify "$TASK_LABEL: review found issues (cycle $review_cycle/$MAX_REVIEW_CYCLES): ${FINDINGS:-<no detail given>}"
                if (( review_cycle >= MAX_REVIEW_CYCLES )); then
                    STOP_KIND="error"
                    stop_run 1 "$TASK_LABEL failed review $MAX_REVIEW_CYCLES times. Stopping run for manual review."
                fi
                gate_fail_count=0
                save_task_state "$UNIT" "$t"
            fi
        done

        maybe_stop_after "task" "$TASK_LABEL passed review"
    done

    CURRENT_TASK_INDEX=""; CURRENT_TASK_TOTAL=""; CURRENT_TASK_SCOPE=""

    # -----------------------------------------------------------------
    # DOCUMENT -- one high-quality QA/summary doc per completed unit,
    # covering every task's combined diff. See build_document_prompt and
    # stage 5 in the file header. Optional: gated by WRITE_QA_DOC (default
    # false -- see the config default above), since it's a whole extra
    # Claude turn per unit that not every run wants. A unit is marked
    # complete regardless of whether this stage ran.
    # -----------------------------------------------------------------
    if [[ "$WRITE_QA_DOC" == "true" ]]; then
        set_stage "writing QA document for $LABEL"
        unit_deferred_items "$UNIT"
        DEFERRED_BLOCK=""
        if (( ${#DEFERRED_ITEM_TEXTS[@]} > 0 )); then
            DEFERRED_BLOCK=$'\n'"THIS UNIT DEFERRED ${#DEFERRED_ITEM_TEXTS[@]} DELIVERABLE(S):"$'\n'
            for di in "${!DEFERRED_ITEM_TEXTS[@]}"; do
                DEFERRED_BLOCK+="- \"${DEFERRED_ITEM_TEXTS[$di]}\" -- ${DEFERRED_ITEM_REASONS[$di]}"$'\n'
            done
        fi
        DOC_SLUG="$(echo "$LABEL" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
        DOC_PATH="${QA_DIR}/${DOC_SLUG}.md"
        DOC_MARKER="${MARKER}_DOC"
        build_document_prompt "$LABEL" "$DOC_MARKER" "$(unit_start_head_for "$UNIT")" "$DOC_PATH" "$DEFERRED_BLOCK" "$(unit_review_notes_for "$UNIT")"
        run_claude_turn "$LABEL (document)" "$DOCUMENT_PROMPT_INIT" "$DOCUMENT_PROMPT_CONTINUE" \
            "${DOC_MARKER}_WRITTEN" "${DOC_MARKER}_FAILED" DOCUMENT
        if [[ ! -s "$DOC_PATH" ]]; then
            notify_important "$LABEL: document turn reported success but ${DOC_PATH} is missing/empty -- writing a minimal fallback so QA still has something to read."
            {
                echo "# $LABEL -- QA notes (fallback, auto-generated)"
                echo
                echo "The automated documentation turn did not leave a readable file behind."
                echo "Commits for this unit: see \`git log --oneline $(unit_start_head_for "$UNIT")..HEAD\`."
            } > "$DOC_PATH"
        fi
        notify "$LABEL: QA/testing document written to $DOC_PATH"
    else
        notify "$LABEL: skipping QA document (WRITE_QA_DOC is not true)."
    fi

    set_stage "finalizing $LABEL"
    record_unit_complete "$UNIT"
    notify_important "$LABEL complete."
    [[ -n "$notify_phase_done_var" ]] && notify_important "Phase $notify_phase_done_var fully complete (all sections done)."

    maybe_stop_after "phase" "$LABEL completed"
done

CURRENT_UNIT_LABEL=""
STOP_KIND="normal-complete"
FINAL_MSG="All automatable units through Phase ${LAST_AUTOMATABLE_PHASE} complete."
HIGHEST_PHASE_NUM="${PHASE_NUMS_SORTED[-1]:-$LAST_AUTOMATABLE_PHASE}"
if (( HIGHEST_PHASE_NUM > LAST_AUTOMATABLE_PHASE )); then
    FINAL_MSG="$FINAL_MSG Phases beyond ${LAST_AUTOMATABLE_PHASE} are configured (LAST_AUTOMATABLE_PHASE in this repo's roadmap.config.sh) as needing something no headless run can do or verify -- see ${ROADMAP_FILE}."
fi
stop_run 0 "$FINAL_MSG"
