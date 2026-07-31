#!/usr/bin/env bash
# recreate.sh — apply staged compose/.env changes to the claude stack.
#
# Recreating the claude container from INSIDE itself would kill compose
# mid-recreate, so when run in-container the `docker compose up -d` is handed
# to a short-lived detached sibling container. The current remote session
# drops and auto-reconnects in ~30-60s (history is preserved; the claude.ai
# environment persists across recreates).
#
# On the host it just runs compose directly.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_STACK_DIR="${HOST_STACK_DIR:-/docker/claude}"

in_container() { [[ -f /.dockerenv ]]; }

hub_image() {
  local img
  img="$(docker inspect claude --format '{{.Config.Image}}' 2>/dev/null || true)"
  img="${img//[$'\r\n']/}"
  printf '%s' "${img:-markfrancisonly/claude-code-remote:local}"
}

if in_container; then
  image="$(hub_image)"
  echo "THIS container will be recreated: the current remote session drops"
  echo "and reconnects automatically in ~30-60s."
  docker run -d --rm \
    --name claude-recreate \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOST_STACK_DIR}:${HOST_STACK_DIR}" \
    -w "${HOST_STACK_DIR}" \
    --entrypoint bash \
    "${image}" \
    -c "sleep 2 && docker compose up -d --remove-orphans" >/dev/null
  echo "Sibling launched (claude-recreate)."
else
  ( cd "${SCRIPT_DIR}" && docker compose up -d --remove-orphans )
fi
