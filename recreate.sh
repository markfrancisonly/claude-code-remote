#!/usr/bin/env bash
# recreate.sh — apply staged compose/.env changes to the claude stack.
#
# Recreating the claude container from INSIDE itself would kill compose
# mid-recreate, so when run in-container the `docker compose up -d` is handed
# to a short-lived detached sibling container. The current remote session
# is interrupted. History is preserved; eligible sessions can reconnect
# after startup.
#
# On the host it just runs compose directly.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Use Claude's own Compose metadata, never a caller container's environment.
stack_dir="$(docker inspect claude --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)"
if [[ -z "${stack_dir}" || "${stack_dir}" == '<no value>' || "${stack_dir}" == '<nil>' ]]; then
  stack_dir="${SCRIPT_DIR}"
fi
if [[ "${stack_dir}" != /* || ! -r "${stack_dir}/compose.yaml" ]]; then
  echo "Cannot recreate Claude: no readable compose.yaml at host stack path ${stack_dir}" >&2
  exit 1
fi

in_container() { [[ -f /.dockerenv ]]; }

hub_image() {
  local img
  img="$(docker inspect claude --format '{{.Config.Image}}' 2>/dev/null || true)"
  img="${img//[$'\r\n']/}"
  printf '%s' "${img:-markfrancisonly/claude-code-remote:local}"
}

if in_container; then
  image="$(hub_image)"
  echo "Recreating Claude at ${stack_dir}; Claude sessions will be interrupted."
  echo "Saved history remains; eligible sessions can reconnect after startup."
  docker run -d --rm \
    --name claude-recreate \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${stack_dir}:${stack_dir}" \
    -w "${stack_dir}" \
    --entrypoint bash \
    "${image}" \
    -c "sleep 2 && docker compose up -d --remove-orphans" >/dev/null
  echo "Sibling launched (claude-recreate)."
else
  ( cd "${stack_dir}" && docker compose up -d --remove-orphans )
fi
