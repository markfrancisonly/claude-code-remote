#!/usr/bin/env bash
# Supervising entrypoint for the Claude remote-control container.
#
# Responsibilities:
#   1. First-boot install of the Claude CLI into the persisted /root/.local
#      volume (image seed as offline fallback), so self-updates survive
#      container recreation.
#   2. Preserve working auth across recreation, including the Remote Control
#      org-metadata gotcha (see the auth section).
#   3. Supervise the Remote Control process forever:
#        - relaunch on exit with capped exponential backoff
#        - gate relaunches on network reachability (a >10min network outage
#          makes the process exit by design — docs "Limitations")
#        - reattach to the SAME claude.ai session after abnormal exits via
#          `--continue` (v2.1.200+), so crashes/updates don't orphan sessions
#        - classify auth-flavored failures (OAuth 403 poll death, org
#          eligibility) and force a re-login only when warranted
#   4. Periodically apply CLI updates and restart-with-reattach so the new
#      version actually takes effect.
#   5. Surface state to the Docker healthcheck via /run/claude/state.
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Logging: one event per line on stdout, in a standard shape log viewers
# (Portainer, dozzle, `docker logs`) can actually read —
#   <RFC3339 timestamp> LEVEL [component] message
# Level is colorized when stdout is a TTY. Components: supervisor (this
# script), claude (the CLI's console/stderr, relayed by the filters below).
# ---------------------------------------------------------------------------
_C_DIM='' _C_YEL='' _C_RED='' _C_OFF=''
if [[ -t 1 ]]; then
  _C_DIM=$'\e[2m'; _C_YEL=$'\e[33m'; _C_RED=$'\e[31m'; _C_OFF=$'\e[0m'
fi
_emit() {  # _emit <color> <LEVEL> <component> <message...>
  local c="$1" lvl="$2" comp="$3"; shift 3
  printf '%s %s%-5s%s [%s] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${c}" "${lvl}" "${c:+${_C_OFF}}" "${comp}" "$*"
}
# Stable handle to PID1 stdout: the launch pipeline's process substitutions
# write through fd 9 explicitly, so the stderr relay can never end up feeding
# the console filter (observed as double-tagged lines).
exec 9>&1
log()   { _emit ''           INFO  supervisor "$@"; }
warn()  { _emit "${_C_YEL}"  WARN  supervisor "$@"; }
error() { _emit "${_C_RED}"  ERROR supervisor "$@"; }
# Verbose diagnostics, enabled with LOG_LEVEL=debug (CLAUDE_LOG_LEVEL in .env).
debug() {
  [[ "${LOG_LEVEL:-info}" == "debug" ]] || return 0
  _emit "${_C_DIM}" DEBUG supervisor "$@"
}

# Relay the CLI's stderr into the standard log shape (raw copy still lands in
# the classification file first via tee). Not everything on stderr is an
# error — the CLI logs progress there too ("Resuming session …") — so only
# Error-looking lines get the ERROR level.
stderr_tag() {
  local l
  while IFS= read -r l; do
    l="$(sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' <<< "${l}")"
    [[ -n "${l// /}" ]] || continue
    if [[ "${l}" == Error* || "${l}" == *" Error:"* ]]; then
      _emit "${_C_RED}" ERROR claude "${l}"
    else
      _emit '' INFO claude "${l}"
    fi
  done
}

# The remote-control console is a full-screen TUI: cursor-homing redraws and
# spinner frames every ~100ms, which docker log viewers render as pages of
# escape garbage (or nothing at all). In the default CLAUDE_CONSOLE=log mode
# its stdout runs through this filter: ANSI stripped, blank lines dropped,
# recently-seen lines suppressed (redraw cycles repeat the same status block),
# the rest emitted as standard log lines. Set CLAUDE_CONSOLE=tui for the raw
# console (e.g. to use the QR code screen over docker attach).
console_filter() {
  python3 -u -c '
import collections, re, sys, time
ansi = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][0-9A-Za-z]|\x1b[=>]|[\r\x00-\x08\x0b-\x1f]")
recent = collections.deque(maxlen=32)
for raw in sys.stdin:
    l = ansi.sub("", raw).strip()
    if not l or l in recent:
        continue
    recent.append(l)
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    print(f"{ts} INFO  [claude] {l}", flush=True)
'
}

# Optional operator alert: HTTP POST to NOTIFY_URL, a generic webhook.
# NOTIFY_FORMAT=text (default) sends the message as a plain-text body
# (ntfy-style); NOTIFY_FORMAT=json sends {"source","event","message"} for
# consumers that want structure (Home Assistant webhooks, Slack proxies,
# gotify gateways, ...). Best-effort — an unreachable notifier must never
# worsen an outage.
notify() {  # notify <event-slug> <message...>
  [[ -n "${NOTIFY_URL:-}" ]] || return 0
  local event="$1"; shift
  if [[ "${NOTIFY_FORMAT:-text}" == "json" ]]; then
    jq -cn --arg event "${event}" --arg message "$*" \
       '{source: "claude-hub", event: $event, message: $message}' \
      | curl -m 10 -s -o /dev/null -H 'Content-Type: application/json' \
             -d @- "${NOTIFY_URL}" || true
  else
    curl -m 10 -s -o /dev/null -d "[claude-hub] $*" "${NOTIFY_URL}" || true
  fi
}

STATE_DIR=/run/claude
STATE_FILE="${STATE_DIR}/state"
PID_FILE="${STATE_DIR}/claude.pid"
RUNNING_VERSION_FILE="${STATE_DIR}/running-version"
RESTART_REQUEST_MARKER="${STATE_DIR}/restart-request"   # set by updater/recycler
# The reattach marker lives in the PERSISTED volume, not /run: environments
# must come back online across container recreation and image rebuilds, not
# just `docker restart`. Cleared only by a clean /exit.
RESUME_MARKER="${HOME}/.claude/.resume-next"            # reattach on next launch
HUB_SID_FILE="${HOME}/.claude/.hub-primary-sid"         # the hub console session's id (see record_hub_primary)
FORCE_LOGIN_MARKER="${STATE_DIR}/force-login"
FAIL_STREAK_FILE="${STATE_DIR}/fail-streak"             # consecutive fast crashes (healthcheck reads)
NOTIFY_LOGIN_STAMP="${STATE_DIR}/notify-login-stamp"    # hourly login-required alert throttle
STATE_HISTORY_FILE="${STATE_DIR}/state-history"         # timestamped state transitions
LAST_STDERR_FILE="${STATE_DIR}/last-stderr"             # stderr of the last abnormal exit
mkdir -p "${STATE_DIR}"
# Keep the transition trail bounded (it survives docker restart).
if [[ -f "${STATE_HISTORY_FILE}" ]]; then
  tail -n 500 "${STATE_HISTORY_FILE}" > "${STATE_HISTORY_FILE}.tmp" 2>/dev/null \
    && mv "${STATE_HISTORY_FILE}.tmp" "${STATE_HISTORY_FILE}" || true
fi

# /run is plain container fs (persists across `docker restart`): drop state
# that must not outlive the previous supervisor. FORCE_LOGIN stays valid
# across a restart.
rm -f "${RESTART_REQUEST_MARKER}" "${PID_FILE}" "${FAIL_STREAK_FILE}"

# Hub works in /docker (= host /docker); spawned project containers set
# WORKSPACE_DIR=/project. Keeping per-container directories distinct also
# scopes --continue resume to this container's own sessions.
WORKSPACE_DIR="${WORKSPACE_DIR:-/docker}"

# Interruptible sleep: plain `sleep` defers the TERM trap until it finishes;
# backgrounding + wait lets `docker stop` act immediately in backoff states.
zzz() {
  sleep "$1" &
  wait $! 2>/dev/null || true
}

set_state() {
  printf '%s' "$1" > "${STATE_FILE}"
  # Timestamped transition trail for post-mortems (`docker exec claude cat
  # /run/claude/state-history`): reconstructing an outage from interleaved
  # console logs alone proved painful (2026-08-29 expired-grant incident).
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "${STATE_HISTORY_FILE}" 2>/dev/null || true
  debug "state -> $1"
}

claude_version() {
  claude --version 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# CLI install: persisted volume first, network install at first boot, baked
# seed as offline fallback (PATH already prefers /root/.local/bin).
# ---------------------------------------------------------------------------
install_cli_if_missing() {
  if [[ -x /root/.local/bin/claude ]]; then
    return 0
  fi
  log "No persisted Claude CLI in /root/.local; installing ${CLAUDE_INSTALL_VERSION:-latest}..."
  if curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_INSTALL_VERSION:-latest}"; then
    hash -r
    log "Installed Claude CLI: $(claude_version)"
  else
    warn "network install failed; falling back to image-baked CLI."
    warn "  auto-update is degraded until a network install succeeds."
  fi
}

# ---------------------------------------------------------------------------
# Auth plumbing.
#
# Claude stores account/onboarding metadata in ~/.claude.json, separate from
# the tokens in ~/.claude/.credentials.json. Critically, ~/.claude.json holds
# the `oauthAccount` object (organizationUuid/...) that Remote Control reads
# to resolve your organization. Persist it by symlinking it into the mounted
# config directory so a real `/login` survives container recreation.
#
# Do NOT fabricate this file. A synthetic file that sets hasCompletedOnboarding
# without an oauthAccount makes Claude skip the profile fetch that populates
# org metadata, so Remote Control fails forever with "Unable to determine your
# organization for Remote Control eligibility". A dangling symlink is fine:
# `/login` writes through it and creates the persisted target.
#
# Also: auth must be a full `/login` session. `claude setup-token` /
# CLAUDE_CODE_OAUTH_TOKEN is inference-only and cannot establish Remote
# Control. Never set ANTHROPIC_API_KEY or a non-Anthropic ANTHROPIC_BASE_URL
# here — either one disables Remote Control entirely.
# ---------------------------------------------------------------------------
PERSISTED_CLAUDE_JSON="${HOME}/.claude/.claude.json"
CRED_FILE="${HOME}/.claude/.credentials.json"

have_org_metadata() {
  jq -e '.oauthAccount.organizationUuid // empty' "${PERSISTED_CLAUDE_JSON}" >/dev/null 2>&1
}

have_credentials() {
  [[ -f "${CRED_FILE}" && -s "${CRED_FILE}" ]]
}

# The CLI blanks the tokens (but keeps the file, with refreshTokenExpiresAt
# and scopes intact) when the grant hard-expires. A mere file-exists check
# therefore reads a DEAD grant as logged-in — which once made run_auth_login
# kill its own login prompt after one poll and report success, leaving the
# supervisor bouncing through healthy-looking backoff cycles for the whole
# outage. "Complete" requires an actual access token.
have_access_token() {
  jq -e '.claudeAiOauth.accessToken // empty' "${CRED_FILE}" >/dev/null 2>&1
}

auth_complete() {
  have_credentials && have_access_token && have_org_metadata
}

merge_onboarding_flags() {
  # Merge onboarding/trust flags onto the REAL account file so Remote Control
  # launch is not blocked by onboarding or trust prompts — without clobbering
  # the oauthAccount metadata that login just wrote. Edit the persisted target
  # directly so the ~/.claude.json symlink is preserved.
  if [[ -s "${PERSISTED_CLAUDE_JSON}" ]] && jq -e . "${PERSISTED_CLAUDE_JSON}" >/dev/null 2>&1; then
    local merged
    merged="$(mktemp)"
    if jq --arg ws "${WORKSPACE_DIR}" \
         '.hasCompletedOnboarding = true
          | .remoteDialogSeen = true
          | .projects[$ws].hasTrustDialogAccepted = ((.projects[$ws].hasTrustDialogAccepted) // true)' \
         "${PERSISTED_CLAUDE_JSON}" > "${merged}"; then
      cat "${merged}" > "${PERSISTED_CLAUDE_JSON}"
    fi
    rm -f "${merged}"
  fi
}

run_auth_login() {
  # Credentials written strictly before ${since} don't count as a completed
  # login: without this gate a stale-but-parseable credentials file (or, on a
  # forced refresh, the very grant being replaced) satisfies the poll on its
  # first pass and the login prompt gets killed before a human ever sees it.
  local since="${1:-$(date +%s)}"
  fresh_login() {
    auth_complete \
      && [[ "$(stat -c %Y "${CRED_FILE}" 2>/dev/null || echo 0)" -ge "${since}" ]]
  }
  set_state login-required

  # Alert at most hourly: during an outage the supervisor may re-enter this
  # state every cycle, and each re-entry is the same news.
  local now_ts last_ts
  now_ts="$(date +%s)"
  last_ts="$(cat "${NOTIFY_LOGIN_STAMP}" 2>/dev/null || echo 0)"
  [[ "${last_ts}" =~ ^[0-9]+$ ]] || last_ts=0
  if (( now_ts - last_ts >= 3600 )); then
    notify login-required "Login required: no usable OAuth grant. Run: docker exec -it claude claude-login"
    printf '%s' "${now_ts}" > "${NOTIFY_LOGIN_STAMP}" 2>/dev/null || true
  fi
  cat <<'EOF'

==============================================
  Interactive Claude auth required
==============================================

Easiest path — guided login with a copy-friendly URL (from the host):

  docker exec -it claude claude-login

Alternative: attach to this TTY and complete the flow by hand:

  docker attach claude          (detach with Ctrl+P then Ctrl+Q)

If no login prompt appears there, an interactive claude session will open
instead: run /login inside it, then /exit.

==============================================

EOF
  local cmd tui_pid
  for cmd in "claude auth login" "claude"; do
    # Run the interactive prompt in the background (keeping the container TTY
    # on stdin) and poll auth_complete beside it: a login completed EXTERNALLY
    # (docker exec -it claude claude-login) must unstick this state without a
    # container restart — re-login never reboots the environment. The same
    # poll also frees a `docker attach` user from needing /exit: once
    # credentials land, the prompt is reclaimed automatically.
    # shellcheck disable=SC2086 — intentional word splitting of the command.
    ${cmd} <&0 &
    tui_pid=$!
    while kill -0 "${tui_pid}" 2>/dev/null; do
      if fresh_login; then
        zzz 3   # grace: let the prompt finish its own post-login writes
        kill "${tui_pid}" 2>/dev/null || true
      fi
      zzz 5
    done
    wait "${tui_pid}" 2>/dev/null || true
    if fresh_login; then
      break
    fi
  done
  merge_onboarding_flags
  # Only a completed login clears the crash counter. Resetting it
  # unconditionally here once neutered the healthcheck's crash-loop detector
  # for the entire duration of an expired-grant outage.
  if fresh_login; then
    fail_streak=0
    printf '0' > "${FAIL_STREAK_FILE}" 2>/dev/null || true
    resume_fail_streak=0
    # Brief settle so the CLI's own post-login writes (org metadata, config)
    # finish before the relaunch reads them.
    log "Login complete; settling ${POST_LOGIN_SETTLE:-20}s before relaunch."
    zzz "${POST_LOGIN_SETTLE:-20}"
  fi
}

ensure_auth() {
  set_state auth-check
  if [[ -f "${FORCE_LOGIN_MARKER}" ]]; then
    # Any credentials written after the failure was classified count as the
    # awaited login — covers a re-login completed externally (claude-login)
    # during the backoff that preceded this cycle.
    local forced_at
    forced_at="$(stat -c %Y "${FORCE_LOGIN_MARKER}" 2>/dev/null || echo 0)"
    rm -f "${FORCE_LOGIN_MARKER}"
    log "Auth refresh required (requested by session failure analysis)."
    run_auth_login "${forced_at}"
  elif [[ "${CLAUDE_FORCE_AUTH_LOGIN:-0}" == "1" ]]; then
    log "CLAUDE_FORCE_AUTH_LOGIN=1; refreshing Claude auth."
    CLAUDE_FORCE_AUTH_LOGIN=0
    run_auth_login
  elif auth_complete; then
    debug "auth check passed (credentials + access token + org metadata)."
    merge_onboarding_flags
    return 0
  else
    if have_credentials; then
      log "Credentials exist but ~/.claude.json has no oauthAccount/organizationUuid."
      log "Remote Control cannot resolve your organization without it."
    else
      log "No credentials found."
    fi
    run_auth_login
  fi

  if ! have_org_metadata; then
    warn "still no organizationUuid; Remote Control will report 'Unable to"
    warn "  determine your organization'. Attach and run /login interactively."
  fi
}

# ---------------------------------------------------------------------------
# Network gate: don't burn reconnect attempts while the network/DNS is down.
# Any HTTP response (including 4xx) counts as reachable.
# ---------------------------------------------------------------------------
wait_for_network() {
  local url="${NETWORK_PROBE_URL:-https://api.anthropic.com}"
  local waited=0
  until curl -m 8 -s -o /dev/null "${url}"; do
    set_state network-wait
    if (( waited % 60 == 0 )); then
      warn "Network unreachable (${url}); waiting..."
    fi
    zzz 15
    waited=$(( waited + 15 ))
  done
  if (( waited > 0 )); then
    log "Network is back after ~${waited}s."
  fi
}

# ---------------------------------------------------------------------------
# Restart-request plumbing shared by the updater and recycler loops.
# The relaunch uses --continue, so the claude.ai session is reattached, not
# orphaned (CLI v2.1.200+).
# ---------------------------------------------------------------------------
request_restart() {
  local reason="$1"
  touch "${RESTART_REQUEST_MARKER}"
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    log "Restarting session (${reason}); will reattach with --continue."
    kill -TERM "${pid}" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Auto-update loop (background). The native CLI also auto-updates itself in
# the background, but a running process keeps its old version until restart —
# so the authoritative check is: disk version != version we launched with.
# `claude update` is run first as a deterministic nudge. 0 hours disables.
# ---------------------------------------------------------------------------
updater_loop() {
  local interval_h="${CLAUDE_UPDATE_INTERVAL_HOURS:-12}"
  if [[ "${interval_h}" == "0" ]]; then
    log "Updater loop disabled (CLAUDE_UPDATE_INTERVAL_HOURS=0)."
    return 0
  fi
  local interval_s=$(( interval_h * 3600 ))
  while true; do
    sleep "${interval_s}"
    claude update >/dev/null 2>&1 || log "claude update failed (offline or throttled)."
    local disk running
    disk="$(claude_version)"
    running="$(cat "${RUNNING_VERSION_FILE}" 2>/dev/null || true)"
    if [[ -n "${disk}" && -n "${running}" && "${disk}" != "${running}" ]]; then
      log "CLI updated on disk: '${running}' -> '${disk}'."
      if [[ "${CLAUDE_UPDATE_RESTART:-1}" == "1" ]]; then
        request_restart "apply CLI update"
      else
        log "CLAUDE_UPDATE_RESTART=0; new version applies on next natural restart."
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# Optional session recycler: proactively restart-and-reattach every N hours.
# Bounds the damage of 'zombie' states where the process looks alive but the
# remote bridge is silently dead (github.com/anthropics/claude-code#34255).
# Off by default (0).
# ---------------------------------------------------------------------------
recycler_loop() {
  local hours="${CLAUDE_RECYCLE_HOURS:-0}"
  if [[ "${hours}" == "0" ]]; then
    return 0
  fi
  local interval_s=$(( hours * 3600 ))
  while true; do
    sleep "${interval_s}"
    request_restart "scheduled recycle every ${hours}h"
  done
}

# ---------------------------------------------------------------------------
# OAuth grant expiry early-warning (background). claude.ai logins carry a hard
# refreshTokenExpiresAt (~30 days after /login) that token rotation does NOT
# extend — when it passes, the next refresh fails and Remote Control dies with
# "You must be logged in" (see AUTH_FATAL_RE). Warn ahead of time, while a
# calm zero-downtime re-login is easy:
#   docker exec -it claude claude   ->  /login  ->  /exit
# (shared credentials file: the running session adopts the new tokens on its
# next refresh). One warning per day once inside the window; 0 days disables.
# ---------------------------------------------------------------------------
expiry_warn_loop() {
  local warn_days="${AUTH_EXPIRY_WARN_DAYS:-5}"
  if [[ "${warn_days}" == "0" ]]; then
    return 0
  fi
  local stamp_file="${STATE_DIR}/expiry-warned-on"
  local exp_ms days_left today
  while true; do
    exp_ms="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // 0' "${CRED_FILE}" 2>/dev/null || echo 0)"
    if [[ "${exp_ms}" =~ ^[0-9]+$ ]] && (( exp_ms > 0 )); then
      days_left=$(( (exp_ms / 1000 - $(date +%s)) / 86400 ))
      (( days_left < 0 )) && days_left=0
      today="$(date +%F)"
      debug "grant expiry check: ~${days_left} day(s) left (warn at <=${warn_days})."
      if (( days_left <= warn_days )) && [[ "$(cat "${stamp_file}" 2>/dev/null || true)" != "${today}" ]]; then
        if (( exp_ms / 1000 <= $(date +%s) )); then
          error "the OAuth grant has EXPIRED; Remote Control is down until re-login."
          error "  re-login: docker exec -it claude claude-login"
          notify auth-expired "OAuth grant EXPIRED — Remote Control is down. Re-login: docker exec -it claude claude-login"
        else
          warn "the OAuth grant expires in ~${days_left} day(s); Remote Control dies with it."
          warn "  re-login without downtime: docker exec -it claude claude-login"
          notify expiry-warning "OAuth grant expires in ~${days_left} day(s). Zero-downtime re-login: docker exec -it claude claude-login"
        fi
        printf '%s' "${today}" > "${stamp_file}"
      fi
    fi
    zzz 21600   # first check at boot, then every 6h
  done
}

# The CLI deletes transcripts under ~/.claude/projects/ older than
# cleanupPeriodDays (default 30). newest_session_id() resumes BY READING those
# transcripts, so a pruned bucket silently orphans the session a relaunch would
# have reattached — and the local copy is the only record left of a session
# whose worker died. Seed a long retention on first boot; an existing value
# (operator's own) is never overwritten. 0 = don't touch settings.json.
seed_settings_defaults() {
  local f="${HOME}/.claude/settings.json"
  local days="${TRANSCRIPT_RETENTION_DAYS:-3650}"
  local merged
  [[ "${days}" == "0" ]] && return 0
  [[ -s "${f}" ]] || printf '{}\n' > "${f}"
  if ! jq -e . "${f}" >/dev/null 2>&1; then
    warn "${f} is not valid JSON; leaving it alone."
    return 0
  fi
  if jq -e 'has("cleanupPeriodDays")' "${f}" >/dev/null 2>&1; then
    return 0
  fi
  merged="$(mktemp)"
  if jq --argjson d "${days}" '.cleanupPeriodDays = $d' "${f}" > "${merged}"; then
    cat "${merged}" > "${f}"
    log "Set cleanupPeriodDays=${days} in settings.json (transcript retention)."
  fi
  rm -f "${merged}"
}

# ---------------------------------------------------------------------------
# One-time setup
# ---------------------------------------------------------------------------
set_state starting
log "Starting Claude Code container (uid $(id -u), $(id -un))..."

install_cli_if_missing

mkdir -p "${WORKSPACE_DIR}/.claude"
cd "${WORKSPACE_DIR}"
ln -sf "${PERSISTED_CLAUDE_JSON}" "${HOME}/.claude.json"
seed_settings_defaults

if [[ -n "${DEPLOY_KEY_B64:-}" ]]; then
  log "Configuring SSH deploy key."
  mkdir -p "${HOME}/.ssh"
  printf '%s' "${DEPLOY_KEY_B64}" | base64 -d > "${HOME}/.ssh/id_ed25519"
  chmod 600 "${HOME}/.ssh/id_ed25519"
fi

[[ -n "${GIT_USER_NAME:-}" ]] && git config --global user.name "${GIT_USER_NAME}"
[[ -n "${GIT_USER_EMAIL:-}" ]] && git config --global user.email "${GIT_USER_EMAIL}"

if [[ -n "${GIT_REPO:-}" ]]; then
  if [[ -z "$(find "${WORKSPACE_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "Cloning ${GIT_REPO} into ${WORKSPACE_DIR}."
    clone_args=(--single-branch)
    [[ -n "${GIT_BRANCH:-}" ]] && clone_args+=(--branch "${GIT_BRANCH}")
    git clone "${clone_args[@]}" "${GIT_REPO}" "${WORKSPACE_DIR}"
  else
    log "${WORKSPACE_DIR} is not empty; skipping clone."
  fi
fi

if docker version >/dev/null 2>&1; then
  log "Host Docker socket is reachable."
else
  warn "host Docker socket is not reachable."
fi

init_marker="${HOME}/.claude/.init_done"
if [[ -n "${INIT_COMMAND:-}" && ! -f "${init_marker}" ]]; then
  log "Running one-time INIT_COMMAND."
  bash -lc "${INIT_COMMAND}"
  touch "${init_marker}"
fi

log "Claude Code version: $(claude_version)"

# ---------------------------------------------------------------------------
# Supervisor
# ---------------------------------------------------------------------------
CLAUDE_PID=""
UPDATER_PID=""
RECYCLER_PID=""
EXPIRY_PID=""
SHUTTING_DOWN=0

on_shutdown() {
  SHUTTING_DOWN=1
  log "Shutdown signal received; stopping Claude..."
  set_state starting
  [[ -n "${UPDATER_PID}" ]] && kill "${UPDATER_PID}" 2>/dev/null || true
  [[ -n "${RECYCLER_PID}" ]] && kill "${RECYCLER_PID}" 2>/dev/null || true
  [[ -n "${EXPIRY_PID}" ]] && kill "${EXPIRY_PID}" 2>/dev/null || true
  if [[ -n "${CLAUDE_PID}" ]] && kill -0 "${CLAUDE_PID}" 2>/dev/null; then
    # Marker lives in the data volume: reattach after restart OR recreation.
    touch "${RESUME_MARKER}"
    kill -TERM "${CLAUDE_PID}" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "${CLAUDE_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "${CLAUDE_PID}" 2>/dev/null || true
  fi
  exit 143
}
trap on_shutdown TERM INT

updater_loop &
UPDATER_PID=$!
recycler_loop &
RECYCLER_PID=$!
expiry_warn_loop &
EXPIRY_PID=$!

# Flags that cannot combine with --continue (per Remote Control docs); they
# are stripped from CLAUDE_EXTRA_ARGS on resume attempts.
RESUME_CONFLICT_FLAGS="--spawn --capacity --create-session-in-dir --no-create-session-in-dir"

# Session transcripts live in ~/.claude/projects/<bucket>, where <bucket> is the
# cwd with every non-alphanumeric character replaced by '-' (e.g. /docker/myapp
# -> -docker-myapp). Since siblings would share one ~/.claude volume, scoping by
# the cwd bucket keeps resume pinned to THIS container's own sessions.
cwd_bucket() { printf '%s' "${WORKSPACE_DIR}" | sed 's/[^A-Za-z0-9]/-/g'; }

# Newest remote-control session id for this cwd. Used to resume by id:
# `--continue` only accepts a *recent* session and silently starts fresh once
# the last one ages out (its "No recent session found in this directory" is why
# crash/update relaunches were orphaning history). `--session-id` has no recency
# window, so a bounce reattaches the same conversation regardless of downtime.
# Only sessions with a sibling <id>.ccr-tip.json marker qualify — that marker is
# what remote-control leaves next to its own transcripts, and the filter keeps
# us from resuming headless/cron/local-CLI runs that share the same cwd bucket.
# The hub's own console session (the "primary") is the ONLY session a
# relaunch can resume to restore the full multi-session server. Resuming a
# WORKER session — which is what `--continue` picks, since workers have the
# freshest transcripts — yields a single-session bridge ("Single session ·
# exits when complete") that serves nothing else on the environment
# (observed 2026-08-29). And the CLI no longer marks its own sessions
# (.ccr-tip.json markers stopped ~2.1.2xx, last seen 2026-08-18; before
# that, stale markers resurrected long-dead sessions whose lookups fail and
# trigger environment abandonment). So the supervisor records the primary
# itself: at every fresh registration, the first NEW transcript to appear in
# the bucket belongs to the primary. No recorded primary -> register fresh;
# never --continue.
hub_primary_sid() {
  local dir="${HOME}/.claude/projects/$(cwd_bucket)" sid
  sid="$(cat "${HUB_SID_FILE}" 2>/dev/null || true)"
  [[ -n "${sid}" && -f "${dir}/${sid}.jsonl" ]] || return 1
  printf '%s' "${sid}"
}

record_hub_primary() {  # $1 = file listing the transcripts that predate launch
  local dir="${HOME}/.claude/projects/$(cwd_bucket)" i f sid
  for i in $(seq 1 45); do
    while IFS= read -r f; do
      grep -qxF "${f}" "$1" 2>/dev/null && continue
      sid="$(basename "${f}" .jsonl)"
      printf '%s' "${sid}" > "${HUB_SID_FILE}"
      log "Recorded hub primary session ${sid}."
      return 0
    done < <(ls -1tr "${dir}"/*.jsonl 2>/dev/null)   # oldest-first: the primary is created before any worker
    zzz 2
  done
  warn "no new transcript appeared after fresh registration; hub primary not recorded."
  rm -f "${HUB_SID_FILE}"
}

build_launch_args() {
  local resume="$1"
  LAUNCH_ARGS=(claude remote-control)
  LAUNCH_ARGS+=(--permission-mode "${CLAUDE_PERMISSION_MODE:-acceptEdits}")
  [[ -n "${CLAUDE_SESSION_NAME:-}" ]] && LAUNCH_ARGS+=(--name "${CLAUDE_SESSION_NAME}")
  if [[ "${resume}" == "1" ]]; then
    # The caller guarantees a recorded primary exists (see the main loop);
    # resume exactly it. The spawn flags are stripped below for resumes.
    local sid
    sid="$(hub_primary_sid)"
    LAUNCH_ARGS+=(--session-id "${sid}")
    log "Resuming hub primary session ${sid} via --session-id."
  fi
  if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
    local extra=() tok skip_next=0
    read -r -a extra <<< "${CLAUDE_EXTRA_ARGS}"
    for tok in "${extra[@]}"; do
      if [[ "${skip_next}" == "1" ]]; then
        skip_next=0
        continue
      fi
      if [[ "${resume}" == "1" ]]; then
        local flag="${tok%%=*}"
        if [[ " ${RESUME_CONFLICT_FLAGS} " == *" ${flag} "* ]]; then
          # Flag with a separate value token (no '=') consumes the next token.
          if [[ "${tok}" != *"="* && "${flag}" != --no-* && "${flag}" != "--create-session-in-dir" ]]; then
            skip_next=1
          fi
          log "Dropping '${tok}' for --continue relaunch (incompatible)."
          continue
        fi
      fi
      LAUNCH_ARGS+=("${tok}")
    done
  fi
}

BACKOFF_MIN="${RECONNECT_BACKOFF_MIN:-5}"
BACKOFF_MAX="${RECONNECT_BACKOFF_MAX:-180}"
# Fast resume failures tolerated before abandoning the claude.ai environment.
# Giving up registers a FRESH environment, so the budget errs long: with
# 15s/30s/45s/60s/60s waits, 6 attempts give a genuinely transient failure
# (post-reboot network, server blip) ~4 minutes to clear. Note: under an
# UNCHANGED login a fresh registration reuses the same environment id, so
# falling back is mostly harmless; after a re-login the environment id
# changes with the grant and old-env sessions are orphaned regardless
# (revive-sessions.py --from-env migrates them).
RESUME_RETRY_MAX="${RESUME_RETRY_MAX:-6}"
backoff="${BACKOFF_MIN}"
auth_suspect_streak=0
resume_fail_streak=0
fail_streak=0

# Errors that mean the CLI has NO usable login at all (grant past its hard
# ~30d refreshTokenExpiresAt, revoked token, or non-claude.ai auth). A
# relaunch can never fix these — only an interactive /login can — so they
# skip resume retries and force login-required immediately (which also flips
# the healthcheck unhealthy, making the outage visible in `docker ps`).
AUTH_FATAL_RE="You must be logged in to use Remote Control|only available with claude\.ai subscriptions|Unable to determine your organization for Remote Control eligibility"

while true; do
  ensure_auth
  wait_for_network

  resume=0
  if [[ -f "${RESUME_MARKER}" && "${CLAUDE_RC_CONTINUE:-1}" == "1" ]]; then
    resume=1
  fi
  rm -f "${RESUME_MARKER}"
  if (( resume == 1 )) && ! hub_primary_sid >/dev/null; then
    warn "Reattach requested but no recorded hub primary session; registering fresh."
    warn "  (a fresh registration under an unchanged login reuses the same environment)"
    resume=0
  fi
  if (( resume == 1 && resume_fail_streak >= RESUME_RETRY_MAX )); then
    error "Resume failed ${resume_fail_streak} times in a row; abandoning the old environment."
    error "  a FRESH environment will register — existing claude.ai sessions will show"
    error "  'Remote environment unavailable' (revive-sessions.py can recreate them)."
    notify resume-abandoned "Could not reattach the previous claude.ai environment after ${resume_fail_streak} attempts; registered a fresh one. Old remote sessions are orphaned — revive-sessions.py can recreate them."
    resume=0
    resume_fail_streak=0
  fi

  build_launch_args "${resume}"
  log "Launching: ${LAUNCH_ARGS[*]}"
  err_file="$(mktemp)"
  started_at="$(date +%s)"
  claude_version > "${RUNNING_VERSION_FILE}" || true

  # Crash insurance, written BEFORE launch: a hard host stop / dockerd kill
  # never runs the TERM trap, so the trap alone can't guarantee reattach.
  # Removed after a clean /exit below.
  [[ "${CLAUDE_RC_CONTINUE:-1}" == "1" ]] && touch "${RESUME_MARKER}"

  # Snapshot the transcript bucket so a fresh registration can identify the
  # NEW file its primary session creates (see record_hub_primary).
  ls -1 "${HOME}/.claude/projects/$(cwd_bucket)"/*.jsonl > "${STATE_DIR}/pre-launch-jsonl" 2>/dev/null \
    || : > "${STATE_DIR}/pre-launch-jsonl"

  set +e
  # <&0 keeps the container TTY on stdin (bash redirects background jobs'
  # stdin from /dev/null otherwise, which breaks interactive keys). stderr is
  # tee'd raw into err_file for exit classification and relayed into the log
  # via stderr_tag; stdout is filtered into standard log lines by default, or
  # left as the raw TUI with CLAUDE_CONSOLE=tui. The filters write to fd 9
  # (PID1 stdout) explicitly so the two streams can't chain into each other.
  if [[ "${CLAUDE_CONSOLE:-log}" == "tui" ]]; then
    "${LAUNCH_ARGS[@]}" <&0 2> >(tee "${err_file}" | stderr_tag >&9) &
  else
    "${LAUNCH_ARGS[@]}" <&0 > >(console_filter >&9) 2> >(tee "${err_file}" | stderr_tag >&9) &
  fi
  CLAUDE_PID=$!
  echo "${CLAUDE_PID}" > "${PID_FILE}"
  set_state running
  if (( resume == 0 )); then
    record_hub_primary "${STATE_DIR}/pre-launch-jsonl" &
  fi
  wait "${CLAUDE_PID}"
  status=$?
  set -e

  CLAUDE_PID=""
  rm -f "${PID_FILE}"
  duration=$(( $(date +%s) - started_at ))

  if [[ "${SHUTTING_DOWN}" == "1" ]]; then
    rm -f "${err_file}"
    exit 143
  fi

  # Let the stderr tee (process substitution) flush before classifying.
  zzz 1

  # Supervisor-initiated restart (update/recycle): reattach immediately.
  if [[ -f "${RESTART_REQUEST_MARKER}" ]]; then
    rm -f "${RESTART_REQUEST_MARKER}" "${err_file}"
    touch "${RESUME_MARKER}"
    log "Supervisor-initiated restart; relaunching immediately."
    backoff="${BACKOFF_MIN}"
    continue
  fi

  if [[ "${status}" != "0" ]]; then
    warn "Claude exited (status ${status}) after ${duration}s."
  else
    log "Claude exited cleanly after ${duration}s."
  fi

  # Consecutive-fast-crash counter for the healthcheck: a loop of instant
  # exits used to look "healthy" forever, because every backoff cycle
  # (<=180s) refreshed the state file inside its 300s staleness window.
  if [[ "${status}" != "0" ]] && (( duration < 60 )); then
    fail_streak=$(( fail_streak + 1 ))
  else
    fail_streak=0
  fi
  printf '%s' "${fail_streak}" > "${FAIL_STREAK_FILE}"

  # A resume attempt that dies instantly is usually the transient
  # "Could not reach the server to look up session <id>" right after a host
  # boot — retry the resume a few times before giving up on the session
  # (the streak cap above falls back to fresh). Fatal auth errors are the
  # exception: retrying cannot help, classify them right away instead.
  if [[ "${resume}" == "1" && "${status}" != "0" && "${duration}" -lt 30 ]] \
     && ! grep -Eq "${AUTH_FATAL_RE}" "${err_file}"; then
    resume_fail_streak=$(( resume_fail_streak + 1 ))
    resume_wait=$(( 15 * resume_fail_streak ))
    (( resume_wait > 60 )) && resume_wait=60
    warn "Resume attempt failed fast (${resume_fail_streak}/${RESUME_RETRY_MAX}); retrying in ${resume_wait}s."
    cat "${err_file}" > "${LAST_STDERR_FILE}" 2>/dev/null || true
    rm -f "${err_file}"
    zzz "${resume_wait}"
    continue
  fi
  resume_fail_streak=0

  # Classify the failure from stderr; keep a copy for post-mortems.
  if [[ "${status}" != "0" ]]; then
    cat "${err_file}" > "${LAST_STDERR_FILE}" 2>/dev/null || true
  fi
  if grep -Eq "${AUTH_FATAL_RE}" "${err_file}"; then
    error "Fatal auth error (expired/revoked grant or wrong account type); forcing re-login."
    error "  matched: $(grep -Eo -m1 "${AUTH_FATAL_RE}" "${err_file}" || true)"
    touch "${FORCE_LOGIN_MARKER}"
    auth_suspect_streak=0
  elif grep -Eq "Access denied \(403\)|status code 401|no longer a member of the organization|Failed to refresh session token|OAuth token has expired" "${err_file}"; then
    # Known fatal-on-403 poll death (anthropics/claude-code#53563). Tokens
    # often recover on relaunch after refresh; only force an interactive
    # re-login after repeated fast auth-flavored failures.
    auth_suspect_streak=$(( auth_suspect_streak + 1 ))
    warn "Auth-flavored exit detected (streak ${auth_suspect_streak})."
    if (( auth_suspect_streak >= 3 && duration < 300 )); then
      error "Repeated auth failures; forcing interactive re-login."
      touch "${FORCE_LOGIN_MARKER}"
      auth_suspect_streak=0
    fi
  else
    auth_suspect_streak=0
  fi
  rm -f "${err_file}"

  # The marker was pre-set at launch, so any abnormal exit reattaches on
  # relaunch. A clean exit (user ran /exit) intentionally archives the
  # session, so drop the marker and start fresh.
  if [[ "${status}" == "0" ]]; then
    rm -f "${RESUME_MARKER}"
  fi

  # A run that survived a while means the connection was healthy; reset backoff.
  if (( duration >= 300 )); then
    backoff="${BACKOFF_MIN}"
  fi

  set_state backoff
  log "Restarting in ${backoff}s..."
  zzz "${backoff}"
  backoff=$(( backoff * 2 ))
  (( backoff > BACKOFF_MAX )) && backoff="${BACKOFF_MAX}"
done
