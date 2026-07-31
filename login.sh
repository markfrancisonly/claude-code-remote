#!/usr/bin/env bash
# login.sh — host-side shortcut for the in-container guided login.
#
# Equivalent to: docker exec -it claude claude-login
# (see claude-login.sh for what that does and why).
set -euo pipefail

CONTAINER="${CLAUDE_CONTAINER:-claude}"

if [[ -f /.dockerenv ]]; then
  echo "You are already inside the container — run: claude-login" >&2
  exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null || echo false)" != "true" ]]; then
  echo "Container '${CONTAINER}' is not running. Start it first:" >&2
  echo "  docker compose up -d" >&2
  exit 1
fi

if ! docker exec "${CONTAINER}" test -x /usr/local/bin/claude-login 2>/dev/null; then
  echo "This image predates claude-login — rebuild first:" >&2
  echo "  docker compose build && docker compose up -d" >&2
  echo "Until then: docker attach ${CONTAINER}   (detach: Ctrl+P then Ctrl+Q)" >&2
  exit 1
fi

exec docker exec -it "${CONTAINER}" claude-login
