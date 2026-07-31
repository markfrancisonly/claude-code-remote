#!/usr/bin/env bash
# login.sh — guided OAuth login with a copy-friendly authorization URL.
#
# The CLI's login flow prints a long URL and then waits for a code pasted back.
# Over SSH that URL is easy to mangle: it wraps, and the TUI redraws over it.
# This routes the prompt through the supervisor instead, so the URL lands in
# `docker logs` as plain text, prints it alone on one line (trivial to select
# in PuTTY or any terminal), and hands you the attach command for pasting the
# code back.
#
# Remote Control requires a real OAuth login. `claude setup-token` and
# CLAUDE_CODE_OAUTH_TOKEN produce inference-only credentials and cannot
# establish it, so there is no headless path — only a less painful one.
set -euo pipefail

CONTAINER="${CLAUDE_CONTAINER:-claude}"
TIMEOUT="${LOGIN_URL_TIMEOUT:-90}"

if [[ -f /.dockerenv ]]; then
  echo "Run this from the Docker host, not inside the container:" >&2
  echo "  bash ${HOST_STACK_DIR:-/docker/claude}/login.sh" >&2
  echo "(it restarts the container, which would kill this session mid-flow)" >&2
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)" != "true" ]]; then
  echo "Container '${CONTAINER}' is not running. Start it first:" >&2
  echo "  docker compose up -d" >&2
  exit 1
fi

echo "Requesting an interactive login from the supervisor..."
# The marker survives `docker restart` by design; the supervisor checks it on
# its next pass through ensure_auth and runs the login on the container's own
# TTY, which is what puts the URL into `docker logs`.
since="$(date -u +%Y-%m-%dT%H:%M:%S)"
docker exec "${CONTAINER}" touch /run/claude/force-login
docker restart "${CONTAINER}" >/dev/null

echo "Waiting for the authorization URL (up to ${TIMEOUT}s)..."
url=""
for _ in $(seq 1 "${TIMEOUT}"); do
  url="$(docker logs --since "${since}" "${CONTAINER}" 2>&1 \
         | grep -oE 'https://[^[:space:]]+' \
         | grep -E 'claude\.ai|anthropic\.com' \
         | tail -1 || true)"
  [[ -n "${url}" ]] && break
  sleep 1
done

if [[ -z "${url}" ]]; then
  cat >&2 <<EOF

No authorization URL appeared within ${TIMEOUT}s. Either the login prompt has
not been reached yet or auth is already valid. Check the supervisor state and,
if it says login-required, attach and complete the prompt by hand:

  docker exec ${CONTAINER} cat /run/claude/state
  docker attach ${CONTAINER}      # detach: Ctrl+P then Ctrl+Q
EOF
  exit 1
fi

cat <<EOF

================================================================
1. Open this URL and approve, then copy the code it shows:

${url}

2. Paste the code into the waiting prompt:

     docker attach ${CONTAINER}

   Right-click pastes in PuTTY. Press Enter, then detach with
   Ctrl+P then Ctrl+Q  (Ctrl+C would stop the session).

3. Confirm it took:

     docker exec ${CONTAINER} cat /run/claude/state    # expect: running
================================================================
EOF
