#!/usr/bin/env bash
# Container healthcheck for the Claude remote-control supervisor.
#
# The supervisor (entrypoint.sh) records its state in /run/claude/state and the
# PID of the current claude process in /run/claude/claude.pid.
#
#   healthy   - claude process is alive, or the supervisor is in a short-lived
#               transitional state (starting/backoff/network-wait/updating)
#               that has been refreshed recently.
#   unhealthy - login required (needs a human: docker exec -it claude
#               claude-login), a transitional state has gone stale, or state
#               is missing.
set -uo pipefail

STATE_DIR=/run/claude
STATE_FILE="${STATE_DIR}/state"
PID_FILE="${STATE_DIR}/claude.pid"

# How stale a transitional state may be before we call it wedged.
MAX_TRANSIENT_AGE=300

[[ -f "${STATE_FILE}" ]] || { echo "no state file"; exit 1; }

state="$(cat "${STATE_FILE}" 2>/dev/null || true)"

case "${state}" in
  running)
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      echo "running (pid ${pid})"
      exit 0
    fi
    echo "state=running but claude process is gone"
    exit 1
    ;;
  starting|backoff|network-wait|auth-check)
    # A crash-loop cycles through these states fast enough to keep the state
    # file fresh forever — catch it via the supervisor's fast-exit counter.
    streak="$(cat "${STATE_DIR}/fail-streak" 2>/dev/null || echo 0)"
    if [[ "${streak}" =~ ^[0-9]+$ ]] && (( streak >= 5 )); then
      echo "crash-looping: ${streak} consecutive fast exits (state: ${state})"
      exit 1
    fi
    now="$(date +%s)"
    mtime="$(stat -c %Y "${STATE_FILE}" 2>/dev/null || echo 0)"
    age=$(( now - mtime ))
    if (( age < MAX_TRANSIENT_AGE )); then
      echo "${state} (${age}s)"
      exit 0
    fi
    echo "stale transitional state: ${state} (${age}s)"
    exit 1
    ;;
  login-required)
    echo "login required: docker exec -it claude claude-login"
    exit 1
    ;;
  *)
    echo "unknown state: ${state}"
    exit 1
    ;;
esac
