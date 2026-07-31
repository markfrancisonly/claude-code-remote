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

log() {
  printf '[claude-entrypoint] %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

# Optional operator alert: plain-text POST to NOTIFY_URL (ntfy topic / generic
# webhook). Best-effort — an unreachable notifier must never worsen an outage.
notify() {
  [[ -n "${NOTIFY_URL:-}" ]] || return 0
  curl -m 10 -s -o /dev/null -d "[claude-hub] $*" "${NOTIFY_URL}" || true
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
FORCE_LOGIN_MARKER="${STATE_DIR}/force-login"
FAIL_STREAK_FILE="${STATE_DIR}/fail-streak"             # consecutive fast crashes (healthcheck reads)
mkdir -p "${STATE_DIR}"

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
    log "WARNING: network install failed; falling back to image-baked CLI."
    log "         Auto-update is degraded until a network install succeeds."
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

auth_complete() {
  have_credentials && have_org_metadata
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
  set_state login-required
  notify "Login required: no usable OAuth grant. Run: docker exec -it claude claude-login"
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
      if auth_complete; then
        zzz 3   # grace: let the prompt finish its own post-login writes
        kill "${tui_pid}" 2>/dev/null || true
      fi
      zzz 5
    done
    wait "${tui_pid}" 2>/dev/null || true
    if auth_complete; then
      break
    fi
  done
  merge_onboarding_flags
  fail_streak=0
  printf '0' > "${FAIL_STREAK_FILE}" 2>/dev/null || true
}

ensure_auth() {
  set_state auth-check
  if [[ -f "${FORCE_LOGIN_MARKER}" ]]; then
    rm -f "${FORCE_LOGIN_MARKER}"
    log "Auth refresh required (requested by session failure analysis)."
    run_auth_login
  elif [[ "${CLAUDE_FORCE_AUTH_LOGIN:-0}" == "1" ]]; then
    log "CLAUDE_FORCE_AUTH_LOGIN=1; refreshing Claude auth."
    CLAUDE_FORCE_AUTH_LOGIN=0
    run_auth_login
  elif auth_complete; then
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
    log "WARNING: still no organizationUuid; Remote Control will report 'Unable to"
    log "         determine your organization'. Attach and run /login interactively."
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
      log "Network unreachable (${url}); waiting..."
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
      if (( days_left <= warn_days )) && [[ "$(cat "${stamp_file}" 2>/dev/null || true)" != "${today}" ]]; then
        log "WARNING: the OAuth grant expires in ~${days_left} day(s); Remote Control dies with it."
        log "         Re-login without downtime: docker exec -it claude claude -> /login -> /exit"
        notify "OAuth grant expires in ~${days_left} day(s). Re-login: docker exec -it claude claude, then /login."
        printf '%s' "${today}" > "${stamp_file}"
      fi
    fi
    zzz 21600   # first check at boot, then every 6h
  done
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
  log "WARNING: host Docker socket is not reachable."
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
newest_session_id() {
  local dir="${HOME}/.claude/projects/$(cwd_bucket)" f sid
  [[ -d "${dir}" ]] || return 1
  while IFS= read -r f; do
    sid="$(basename "${f}" .jsonl)"
    if [[ -f "${dir}/${sid}.ccr-tip.json" ]]; then
      printf '%s' "${sid}"
      return 0
    fi
  done < <(ls -1t "${dir}"/*.jsonl 2>/dev/null)
  return 1
}

build_launch_args() {
  local resume="$1"
  LAUNCH_ARGS=(claude remote-control)
  LAUNCH_ARGS+=(--permission-mode "${CLAUDE_PERMISSION_MODE:-acceptEdits}")
  [[ -n "${CLAUDE_SESSION_NAME:-}" ]] && LAUNCH_ARGS+=(--name "${CLAUDE_SESSION_NAME}")
  if [[ "${resume}" == "1" ]]; then
    # Prefer resuming an exact session id (no recency window); fall back to
    # --continue if we can't find one. Both strip the spawn flags below.
    local sid
    sid="$(newest_session_id || true)"
    if [[ -n "${sid}" ]]; then
      LAUNCH_ARGS+=(--session-id "${sid}")
      log "Resuming session ${sid} via --session-id."
    else
      LAUNCH_ARGS+=(--continue)
    fi
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
  if (( resume == 1 && resume_fail_streak >= 3 )); then
    log "Resume failed ${resume_fail_streak} times in a row; starting a fresh session."
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

  set +e
  # <&0 keeps the container TTY on stdin (bash redirects background jobs'
  # stdin from /dev/null otherwise, which breaks the interactive TUI).
  "${LAUNCH_ARGS[@]}" <&0 2> >(tee "${err_file}" >&2) &
  CLAUDE_PID=$!
  echo "${CLAUDE_PID}" > "${PID_FILE}"
  set_state running
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

  log "Claude exited (status ${status}) after ${duration}s."

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
    log "Resume attempt failed fast (${resume_fail_streak}/3); retrying."
    rm -f "${err_file}"
    zzz $(( 10 * resume_fail_streak ))
    continue
  fi
  resume_fail_streak=0

  # Classify the failure from stderr.
  if grep -Eq "${AUTH_FATAL_RE}" "${err_file}"; then
    log "Fatal auth error (expired/revoked grant or wrong account type); forcing re-login."
    touch "${FORCE_LOGIN_MARKER}"
    auth_suspect_streak=0
  elif grep -Eq "Access denied \(403\)|status code 401|no longer a member of the organization|Failed to refresh session token|OAuth token has expired" "${err_file}"; then
    # Known fatal-on-403 poll death (anthropics/claude-code#53563). Tokens
    # often recover on relaunch after refresh; only force an interactive
    # re-login after repeated fast auth-flavored failures.
    auth_suspect_streak=$(( auth_suspect_streak + 1 ))
    log "Auth-flavored exit detected (streak ${auth_suspect_streak})."
    if (( auth_suspect_streak >= 3 && duration < 300 )); then
      log "Repeated auth failures; forcing interactive re-login."
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
