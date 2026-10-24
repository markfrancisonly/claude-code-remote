#!/usr/bin/env bash
# Run the real supervisor loop with a fake CLI; never invoke Docker or Claude.
set -euo pipefail
stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
supervisor_pid=""
cleanup() {
  if [[ -n "${supervisor_pid}" ]]; then
    kill -TERM "${supervisor_pid}" 2>/dev/null || true
    wait "${supervisor_pid}" 2>/dev/null || true
  fi
  rm -rf "${work}"
}
trap cleanup EXIT

# Extract only supervision; first-boot setup would access real state.
sed -n '/^CLAUDE_PID=""$/,$p' "${stack_dir}/entrypoint.sh" > "${work}/supervisor.sh"
[[ -s "${work}/supervisor.sh" ]]
if grep -q '\${HOME}' "${work}/supervisor.sh"; then
  echo 'Refusing test: supervisor still accesses real HOME; remove legacy transcript scanning first.' >&2
  exit 1
fi
mkdir -p "${work}/state" "${work}/data/projects/-docker"
printf 'legacy-primary\n' > "${work}/data/.hub-primary-sid"
: > "${work}/data/.resume-next"
printf '{"environmentId":"test-env","source":"standalone","sessionId":"test-session"}\n' > "${work}/data/projects/-docker/bridge-pointer.json"
printf '{"type":"test-history"}\n' > "${work}/data/projects/-docker/test-session.jsonl"
sha256sum "${work}/data/.hub-primary-sid" "${work}/data/.resume-next" "${work}/data/projects/-docker/"* > "${work}/before.sha256"

cat > "${work}/cli-stub.sh" <<'STUB'
set -euo pipefail
n=$(cat "${TEST_RECONNECT_WORK}/launch-count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$@" > "${TEST_RECONNECT_WORK}/args-${n}"
printf '%s' "${n}" > "${TEST_RECONNECT_WORK}/launch-count"
if (( n == 1 )); then
  exit 17
fi
trap 'printf TERM > "${TEST_RECONNECT_WORK}/cli-signal"; exit 0' TERM
printf ready > "${TEST_RECONNECT_WORK}/cli-ready"
while true; do
  sleep 0.05 &
  wait $! || true
done
STUB

run_supervisor() {
  export TEST_RECONNECT_WORK="${work}"
  STATE_DIR="${work}/state"
  PID_FILE="${STATE_DIR}/claude.pid"
  RUNNING_VERSION_FILE="${STATE_DIR}/running-version"
  RESTART_REQUEST_MARKER="${STATE_DIR}/restart-request"
  FORCE_LOGIN_MARKER="${STATE_DIR}/force-login"
  FAIL_STREAK_FILE="${STATE_DIR}/fail-streak"
  LAST_STDERR_FILE="${STATE_DIR}/last-stderr"
  # Legacy files deliberately exist: updated supervision must ignore them.
  RESUME_MARKER="${work}/data/.resume-next"
  HUB_SID_FILE="${work}/data/.hub-primary-sid"
  CLAUDE_PERMISSION_MODE=acceptEdits
  CLAUDE_SESSION_NAME=docker-host
  CLAUDE_EXTRA_ARGS='--spawn=same-dir --capacity 99'
  RECONNECT_BACKOFF_MIN=1
  RECONNECT_BACKOFF_MAX=2
  log() { printf '%s\n' "$*"; }
  warn() { log "$@"; }
  error() { log "$@"; }
  notify() { :; }
  ensure_auth() { :; }
  wait_for_network() { :; }
  updater_loop() { :; }
  recycler_loop() { :; }
  expiry_warn_loop() { :; }
  claude_version() { printf 'test-cli\n'; }
  mktemp() { command mktemp "${work}/stderr.XXXXXX"; }
  set_state() { printf '%s' "$1" > "${STATE_DIR}/state"; }
  zzz() { sleep 0.02 & wait $! || true; }
  console_filter() { cat; }
  stderr_tag() { cat; }
  claude() { exec bash "${work}/cli-stub.sh" "$@"; }
  exec 9>&1
  source "${work}/supervisor.sh"
}
run_supervisor > "${work}/supervisor.log" 2>&1 &
supervisor_pid=$!
for _ in {1..200}; do
  [[ -f "${work}/cli-ready" ]] && break
  if ! kill -0 "${supervisor_pid}" 2>/dev/null; then
    cat "${work}/supervisor.log" >&2
    exit 1
  fi
  sleep 0.02
done
[[ -f "${work}/cli-ready" ]] || { cat "${work}/supervisor.log" >&2; exit 1; }
kill -TERM "${supervisor_pid}"
set +e
wait "${supervisor_pid}"
status=$?
set -e
supervisor_pid=""
[[ "${status}" == 143 ]]
[[ "$(cat "${work}/cli-signal")" == TERM ]]
[[ "$(cat "${work}/launch-count")" == 2 ]]
printf '%s\n' remote-control --permission-mode acceptEdits --name docker-host --spawn=same-dir --capacity 99 > "${work}/expected-args"
diff -u "${work}/expected-args" "${work}/args-1"
diff -u "${work}/expected-args" "${work}/args-2"
sha256sum -c "${work}/before.sha256" > /dev/null
printf 'PASS: initial and retried launches retain full server arguments\n'
printf 'PASS: native pointer, history, and legacy markers remain unchanged\n'
printf 'PASS: SIGTERM reaches the CLI and supervisor exits cleanly\n'
