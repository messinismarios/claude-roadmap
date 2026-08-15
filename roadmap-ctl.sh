#!/usr/bin/env bash
#
# roadmap-ctl.sh -- part of ftero-scripts (github.com/messinismarios/ftero-scripts)
#
# Sends a command to an already-running run-roadmap.sh, or checks its
# status. See the INTERACTIVITY section near the top of run-roadmap.sh for
# exactly what each command does and how it's delivered.
#
# Run it from the same target repo root you ran run-roadmap.sh from (like
# that script, it is repo-agnostic and takes its WORKSPACE_DIR from wherever
# it's invoked, not from where the script itself lives):
#   path/to/ftero-scripts/roadmap-ctl.sh stop
#   path/to/ftero-scripts/roadmap-ctl.sh stop-after-task   -- finish the current task, then stop (nothing interrupted)
#   path/to/ftero-scripts/roadmap-ctl.sh stop-after-phase  -- finish the current phase/section, then stop
#   path/to/ftero-scripts/roadmap-ctl.sh cancel-stop-after -- cancel a pending stop-after-task/phase
#   path/to/ftero-scripts/roadmap-ctl.sh retry             -- skip a quota/backoff/nudge-pacing wait
#   path/to/ftero-scripts/roadmap-ctl.sh pivot "text to send into the running turn"
#   path/to/ftero-scripts/roadmap-ctl.sh status
#
# On Windows, run this via roadmap-ctl.bat (or Git Bash directly) rather
# than plain `bash roadmap-ctl.sh` in PowerShell/cmd -- see the "Windows
# gotcha" note in run-roadmap.sh's header for why (the WSL bash shim on
# PATH is not Git Bash).
#
set -uo pipefail

WORKSPACE_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RUNTIME_DIR="$WORKSPACE_DIR/.roadmap-runtime"
CONTROL_FILE="$RUNTIME_DIR/control"
CONTROL_LOCK_DIR="$RUNTIME_DIR/control.lock"
STATUS_FILE="$RUNTIME_DIR/status"
STOP_AFTER_FILE="$RUNTIME_DIR/stop-after"
RESUME_DOC="$WORKSPACE_DIR/specs/ROADMAP-RESUME.md"

usage() {
    echo "Usage: $0 stop|stop-after-task|stop-after-phase|cancel-stop-after|retry|status" >&2
    echo "       $0 pivot \"<text to send into the running turn>\"" >&2
    exit 1
}

cmd="${1:-}"
[[ -z "$cmd" ]] && usage

if [[ "$cmd" == "status" ]]; then
    if [[ -f "$STATUS_FILE" ]]; then
        cat "$STATUS_FILE"
    else
        echo "No status file at $STATUS_FILE -- run-roadmap.sh does not appear to be running (or hasn't started its first turn yet)."
        exit 1
    fi
    exit 0
fi

if [[ ! -d "$RUNTIME_DIR" ]]; then
    echo "Error: $RUNTIME_DIR does not exist -- run-roadmap.sh does not appear to have run yet in this repo." >&2
    exit 1
fi

# stop-after-task/phase and cancel-stop-after write a single sticky flag
# file directly rather than going through CONTROL_FILE's one-shot command
# queue -- it needs to still be there many poll ticks (and possibly many
# turn retries) later, whenever the next task/phase boundary is actually
# reached, not consumed the instant it's read.
case "$cmd" in
    stop-after-task|stop-after-phase)
        boundary="${cmd#stop-after-}"
        mkdir -p "$RUNTIME_DIR"
        printf '%s' "$boundary" > "${STOP_AFTER_FILE}.tmp" && mv "${STOP_AFTER_FILE}.tmp" "$STOP_AFTER_FILE"
        echo "Queued: stop after the current ${boundary} completes. Nothing in-flight is interrupted -- the run finishes whatever it's doing and stops cleanly at that boundary. Cancel with: $0 cancel-stop-after"
        exit 0
        ;;
    cancel-stop-after)
        if [[ -s "$STOP_AFTER_FILE" ]]; then
            pending="$(cat "$STOP_AFTER_FILE")"
            rm -f "$STOP_AFTER_FILE"
            echo "Cancelled pending stop-after-${pending}."
        else
            echo "No pending stop-after-task/phase to cancel."
        fi
        exit 0
        ;;
esac

case "$cmd" in
    stop)
        line="stop"
        ;;
    retry)
        line="retry"
        ;;
    pivot)
        text="${2:-}"
        if [[ -z "$text" ]]; then
            usage
        fi
        # One command per line in CONTROL_FILE -- collapse embedded
        # newlines so a multi-line pivot can't split into bogus commands.
        text="${text//$'\n'/ }"
        line="pivot:${text}"
        ;;
    *)
        usage
        ;;
esac

tries=0
while ! mkdir "$CONTROL_LOCK_DIR" 2>/dev/null; do
    tries=$((tries + 1))
    if (( tries > 50 )); then
        echo "Error: could not acquire the control-file lock ($CONTROL_LOCK_DIR) after ~5s -- is another roadmap-ctl.sh command running at this exact moment? Try again." >&2
        exit 1
    fi
    sleep 0.1
done
printf '%s\n' "$line" >> "$CONTROL_FILE"
rmdir "$CONTROL_LOCK_DIR" 2>/dev/null || true

case "$cmd" in
    stop)
        echo "Queued: stop. The current turn will be asked to wrap up, then the run will exit and write $RESUME_DOC."
        ;;
    retry)
        echo "Queued: retry. If run-roadmap.sh is currently waiting (quota/backoff/nudge-pacing), it will retry immediately. If a turn is actively running instead, this has no effect."
        ;;
    pivot)
        echo "Queued: pivot -- \"$text\". Delivered live into the running turn within a few seconds if one is active, otherwise held and delivered as opening context of the next turn."
        ;;
esac
