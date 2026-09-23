#!/usr/bin/env bash
#
# roadmap.config.sh -- per-repo configuration for run-roadmap.sh
# (part of ftero-scripts: github.com/messinismarios/ftero-scripts)
#
# Copy this file to scripts/roadmap.config.sh IN THE TARGET REPO (the repo
# whose specs/roadmap.md you want run-roadmap.sh to drive) and commit it
# there. run-roadmap.sh looks for it at that exact path by default; every
# repo you use this tool on gets its own copy, filled in for that repo.
#
# This file is plain bash, sourced directly by run-roadmap.sh -- every
# variable below is just a shell variable assignment. Only set the ones you
# need; anything you don't set keeps run-roadmap.sh's built-in default
# (shown in comments below).

# ============================================================================
# REQUIRED -- run-roadmap.sh refuses to start without these.
# ============================================================================

# One-paragraph description of this repo, injected verbatim into the opening
# prompt of every turn (plan/implement/review/document) so a zero-context
# Claude invocation immediately knows what kind of repo it's in: monorepo or
# single-app, language/framework, the key top-level directories, and where to
# go for the full layout. This is the single biggest lever you have over
# turn quality -- a vague description produces vague, generic work.
#
# Write it the way you'd describe the repo to a new hire in their first
# minute, ending with a full stop (it's spliced directly before the next
# sentence in every prompt).
REPO_DESCRIPTION="the <repo-name> repository (describe its shape here --
e.g. a single Go service with cmd/, internal/, and a Terraform stack under
infra/; or a pnpm/Turborepo monorepo with apps/* and packages/* -- see
specs/tech-stack.md for the full layout)."

# Last phase number (the "N" in "## Phase N") this script is allowed to run
# unattended. Anything beyond this phase in the roadmap is left alone --
# useful for a tail of phases that need something no headless run can do
# (a live legal entity, a human onboarding real customers, etc). Set it to
# the roadmap's actual last phase number to let it run the whole thing.
LAST_AUTOMATABLE_PHASE=

# ============================================================================
# OPTIONAL -- sensible defaults shown; override only what you need to.
# ============================================================================

# Path to the roadmap file, relative to the repo root.
# ROADMAP_FILE="specs/roadmap.md"

# Space-separated list of other spec files (relative to the repo root) every
# turn should also read for cross-cutting context, besides ROADMAP_FILE.
# Leave empty if ROADMAP_FILE is self-contained.
# SPEC_FILES="specs/tech-stack.md specs/tenant-contract.md"

# Shell command to install dependencies before the verification gate runs,
# or "" (default) to skip. Runs from the repo root via `bash -c`, so
# pipes/&&/redirects all work normally.
# INSTALL_CMD="pnpm install --frozen-lockfile"

# Shell command the deterministic verification gate runs after every
# implement turn (lint/typecheck/test, terraform validate, whatever this
# repo's own "does this actually work" check is). Runs from the repo root
# via `bash -c`, independently of anything the implement turn already ran,
# so a turn can never claim a green check it didn't actually get. Leave ""
# (default) to skip the gate entirely -- every task then relies solely on
# the implementer's and reviewer's own judgement, which is fine for repos
# with no automated test suite (e.g. pure infra-as-code).
# GATE_CMD="pnpm turbo run lint typecheck test"

# This repo's own hard, cross-cutting constraints that a task narrowly
# scoped to one phase could satisfy in letter while violating in spirit --
# fed verbatim to the reviewer turn (which is specifically briefed to look
# for exactly this kind of quiet violation). One bullet per line is easiest
# to read; keep it to the constraints that are genuinely easy to miss, not
# a restatement of everything in your spec files. Leave "" (default) if
# there's nothing beyond what ROADMAP_FILE/SPEC_FILES already say inline.
# CROSS_CUTTING_CONSTRAINTS="- terraform plan must never propose replacing
# the production database or its storage volume.
# - A breaking change to the public API contract requires a version bump,
#   announced in every consumer's repo -- never a silent break."

# A note about a shared/cross-cutting module that must always be updated
# together with everything that consumes it, in the same commit -- e.g. a
# shared package in a monorepo, or a schema every service reads. Fed to the
# plan turn (so a split never separates the two) and the implement/review
# turns (so sync is actually checked). Leave "" (default) if this repo has
# no such concept (e.g. a single-app repo, or a pure infra repo where
# nothing "consumes" anything else in the same sense).
# SHARED_MODULE_SYNC_NOTE="A change to packages/contracts (the shared Zod
# schemas) is only complete once every app that imports it has been updated
# to match, in the same commit series."

# ntfy.sh topic for phone push notifications, or "" (default) to disable.
# Pick something private/unguessable -- anyone who knows the topic can read
# your notifications. Subscribe from the ntfy app, or open
# https://ntfy.sh/<topic> in a browser, before your first run.
# NTFY_TOPIC="some-repo-roadmap-<random-suffix>"

# false (default): only ping the phone for run start/stop, unit/phase
# completion, and quota waits. true: ping on every notify() call. The log
# file (specs/.roadmap-run.log) always has everything either way.
# NTFY_VERBOSE=false

# Empty (default): no per-turn cost cap. Set e.g. "5.00" to pass
# --max-budget-usd to every claude invocation; a turn that hits it fails
# fast instead of blindly retrying into the same wall three times.
# MAX_TURN_BUDGET_USD=""

# Model and effort for every Claude turn, passed as --model/--effort. Empty
# (default) inherits the claude CLI's own settings. Each stage can override
# both; an empty override falls back to CLAUDE_MODEL/CLAUDE_EFFORT. The
# model/effort used is recorded with each turn's cost in specs/.roadmap-cost.
# CLAUDE_MODEL=""; CLAUDE_EFFORT=""
# PLAN_MODEL="sonnet";   PLAN_EFFORT="medium"
# IMPLEMENT_MODEL="opus"; IMPLEMENT_EFFORT="medium"
# REVIEW_MODEL="opus";   REVIEW_EFFORT="medium"
# DOCUMENT_MODEL="sonnet"; DOCUMENT_EFFORT="medium"

# Passed as --settings to every turn (a path relative to the repo root, or a
# JSON string) -- e.g. {"enabledPlugins": {"<plugin>": false},
# "disableAllHooks": true} to drop plugins and hooks meant for interactive
# work. CLAUDE_STRICT_MCP=true adds --strict-mcp-config, so turns load no MCP
# servers at all.
# CLAUDE_SETTINGS=""
# CLAUDE_STRICT_MCP=false

# true: a ### N.M section unit skips the PLAN turn and runs as one task (the
# roadmap author already split it). false (default): every unit is planned.
# SKIP_PLAN_FOR_SECTIONS=false

# On a gate failure, this many trailing lines of the gate's output are put
# straight into the retry turn's findings.
# GATE_FINDINGS_TAIL_LINES=80

# false (default): skip the DOCUMENT stage -- no specs/qa/<unit-slug>.md is
# written for completed units. true: run it, producing a QA/manual-testing
# doc per unit (see stage 5 in run-roadmap.sh's header). It's a whole extra
# Claude turn per unit, so it's off unless you actually want that doc. Can
# also be set per-run without editing this file, e.g.:
#   WRITE_QA_DOC=true bash run-roadmap.sh
# WRITE_QA_DOC=false

# Retry/timeout tuning -- the defaults are reasonable for most repos, change
# only if you have a specific reason to.
# RETRY_WAIT_SECONDS=1800       # wait after a quota/rate-limit hit before retrying
# MAX_NON_QUOTA_RETRIES=3       # give up on a turn (or a gate re-check) after this many real failures
# MAX_REVIEW_CYCLES=2           # give up on a task after this many review-issues cycles without a clean review
# UNIT_TIMEOUT_SECONDS=10800    # kill a stuck turn attempt after this many seconds (default 3h)
# BACKGROUND_WAIT_SECONDS=120   # pace between nudges of a turn that ended without a result marker
# MAX_BACKGROUND_NUDGES=15      # give up after this many nudges
# POLL_INTERVAL_SECONDS=5       # how often a live turn checks its own output and the control file
# STOP_GRACE_SECONDS=60         # grace period before SIGTERM/SIGKILL on stop
