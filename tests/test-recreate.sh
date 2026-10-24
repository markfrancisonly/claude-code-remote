#!/usr/bin/env bash
# Mock Docker completely; test both call sites without container operations.
set -euo pipefail
stack_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/fallback"
: > "${work}/fallback/compose.yaml"

# Copies differ only in the container-detection probe, allowing both branches
# to run on any test host. Their fallback stack is the temporary fixture.
python3 - "${stack_dir}/recreate.sh" "${work}/fallback" <<'PYTEST'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
probe = 'in_container() { [[ -f /.dockerenv ]]; }'
assert source.count(probe) == 1
for mode, status in [('container', 0), ('host', 1)]:
    Path(sys.argv[2], mode + '.sh').write_text(source.replace(
        probe, 'in_container() { return ' + str(status) + '; }'))
PYTEST

export TEST_RECREATE_CAPTURE="${work}/docker-call"
export TEST_RECREATE_LABEL=/docker/claude
export HOST_STACK_DIR=/srv/other-stack
docker() {
  case "$1" in
    inspect)
      [[ "$2" == claude ]]
      if [[ "$4" == *com.docker.compose.project.working_dir* ]]; then
        printf '%s' "${TEST_RECREATE_LABEL}"
      elif [[ "$4" == '{{.Config.Image}}' ]]; then
        printf 'claude-image:test'
      else
        return 90
      fi
      ;;
    run|compose)
      printf '%s\0' "$@" > "${TEST_RECREATE_CAPTURE}"
      printf '%s' "$PWD" > "${TEST_RECREATE_CAPTURE}.cwd"
      ;;
    *) return 91 ;;
  esac
}
export -f docker

check_run() {
  python3 - "${TEST_RECREATE_CAPTURE}" "$1" <<'PYTEST'
from pathlib import Path
import sys
args = Path(sys.argv[1]).read_bytes().rstrip(b'\0').decode().split('\0')
stack = sys.argv[2]
assert args[0] == 'run', args
assert args[args.index('-w') + 1] == stack, args
assert stack + ':' + stack in args, args
assert '/srv/other-stack' not in repr(args), args
assert 'claude-image:test' in args, args
PYTEST
}
bash "${work}/fallback/container.sh" > "${work}/output"
check_run /docker/claude
printf 'PASS: caller HOST_STACK_DIR cannot redirect Claude recreation\n'

TEST_RECREATE_LABEL='<no value>'
bash "${work}/fallback/container.sh" > "${work}/output"
check_run "${work}/fallback"
printf 'PASS: absent Compose label falls back to the script directory\n'

TEST_RECREATE_LABEL=/docker/claude
bash "${work}/fallback/host.sh" > "${work}/output"
[[ "$(cat "${TEST_RECREATE_CAPTURE}.cwd")" == /docker/claude ]]
[[ "$(tr '\0' ' ' < "${TEST_RECREATE_CAPTURE}")" == 'compose up -d --remove-orphans ' ]]
printf 'PASS: host execution uses the same authoritative stack path\n'

rm "${TEST_RECREATE_CAPTURE}"
TEST_RECREATE_LABEL="${work}/missing-stack"
if bash "${work}/fallback/container.sh" > "${work}/output" 2>&1; then
  echo 'Expected invalid stack path to fail' >&2
  exit 1
fi
[[ ! -e "${TEST_RECREATE_CAPTURE}" ]]
grep -q 'no readable compose.yaml' "${work}/output"
printf 'PASS: invalid stack path fails before any Docker mutation\n'
