#!/usr/bin/env bash
# claude-login — complete the Remote Control OAuth login from a docker exec
# session, with a copy-friendly URL and a plain paste prompt.
#
#   docker exec -it claude claude-login
#
# Why this exists: the login UI redraws and wraps the authorization URL,
# which makes copying it out of an SSH terminal (PuTTY especially) miserable,
# and with nobody attached it sits forever at an interactive method picker.
# This runs that same UI inside a hidden PTY (`script`), answers the picker,
# scrapes the URL out of the raw output, prints it once on its own line, and
# relays the pasted code back. No attach, no container restart — the
# supervised session adopts the refreshed credentials on its next token
# refresh (shared credentials file).
#
# There is no headless login: `claude setup-token` / CLAUDE_CODE_OAUTH_TOKEN
# are inference-only and cannot establish Remote Control. A browser is
# required; this only removes the copy/paste pain.
set -euo pipefail

CRED_FILE="${HOME}/.claude/.credentials.json"
PERSISTED_CLAUDE_JSON="${HOME}/.claude/.claude.json"
URL_TIMEOUT="${CLAUDE_LOGIN_URL_TIMEOUT:-60}"
DONE_TIMEOUT="${CLAUDE_LOGIN_DONE_TIMEOUT:-180}"

if [[ ! -t 0 ]]; then
  echo "claude-login needs an interactive terminal:" >&2
  echo "  docker exec -it claude claude-login" >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/claude-login.XXXXXX)"
FIFO="${WORK}/in"
OUT="${WORK}/out"
mkfifo "${FIFO}"
: > "${OUT}"
SPID=""
cleanup() {
  [[ -n "${SPID}" ]] && kill "${SPID}" 2>/dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

started_at="$(date +%s)"

# Read-write open so neither end of the FIFO blocks; keystrokes reach the UI
# through fd 3. The PTY is made very wide so the URL never wraps mid-line.
exec 3<>"${FIFO}"
script -qfc "stty cols 500 rows 50 2>/dev/null; exec claude" "${OUT}" <&3 >/dev/null 2>&1 &
SPID=$!

# Strip ANSI escapes (CSI, then BEL-terminated OSC, then any stray ESC) and
# carriage returns from the captured UI output.
strip_ansi() {
  sed -E -e $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' \
         -e $'s/\x1b\\][^\x07]*\x07//g' \
         -e $'s/\x1b//g' \
         -e $'s/\r//g' "${OUT}" 2>/dev/null || true
}

echo "Starting the login flow..."
url=""
picker_answered=0
login_typed=0
deadline=$(( started_at + URL_TIMEOUT ))
while (( $(date +%s) < deadline )); do
  kill -0 "${SPID}" 2>/dev/null || break
  text="$(strip_ansi)"

  # Fresh-login and /login both show a "select login method" picker; the
  # claude.ai subscription option is the highlighted default — accept it.
  if (( ! picker_answered )) && grep -qiE 'login method|select.*account|choose.*account' <<< "${text}"; then
    sleep 1
    printf '\r' >&3
    picker_answered=1
  fi

  # Already-valid credentials: claude opens its normal idle UI instead of the
  # login wizard. Ask for a re-login explicitly (proactive monthly refresh).
  if (( ! login_typed && ! picker_answered )) && grep -q 'for shortcuts' <<< "${text}"; then
    printf '/login\r' >&3
    login_typed=1
  fi

  url="$(grep -oE 'https://(claude\.ai|console\.anthropic\.com)[^[:space:]]*' <<< "${text}" | head -1 || true)"
  [[ -n "${url}" ]] && break
  sleep 1
done

if [[ -z "${url}" ]]; then
  echo >&2
  echo "No authorization URL appeared within ${URL_TIMEOUT}s. Last UI output:" >&2
  strip_ansi | grep -vE '^[[:space:]]*$' | tail -12 >&2
  echo >&2
  echo "Fallback: docker attach claude   (detach: Ctrl+P then Ctrl+Q)" >&2
  exit 1
fi

cat <<EOF

================================================================
Open this URL in any browser (phone works) and approve:

${url}

================================================================
EOF
read -r -p "Paste the authorization code here, then press Enter: " code
if [[ -z "${code}" ]]; then
  echo "Empty code; aborting." >&2
  exit 1
fi
printf '%s\r' "${code}" >&3

echo "Waiting for the credentials to land..."
deadline=$(( $(date +%s) + DONE_TIMEOUT ))
ok_creds=0
ok_org=0
while (( $(date +%s) < deadline )); do
  if (( ! ok_creds )) \
     && [[ "$(stat -c %Y "${CRED_FILE}" 2>/dev/null || echo 0)" -gt "${started_at}" ]] \
     && jq -e '.claudeAiOauth.accessToken // empty' "${CRED_FILE}" >/dev/null 2>&1; then
    ok_creds=1
  fi
  # Remote Control also needs the oauthAccount org metadata that the CLI
  # fetches right after login (see entrypoint.sh for the full gotcha).
  if (( ok_creds )) \
     && jq -e '.oauthAccount.organizationUuid // empty' "${PERSISTED_CLAUDE_JSON}" >/dev/null 2>&1; then
    ok_org=1
    break
  fi
  sleep 2
done

if (( ! ok_creds )); then
  echo "Credentials were not refreshed. Last UI output:" >&2
  strip_ansi | grep -vE '^[[:space:]]*$' | tail -12 >&2
  exit 1
fi

exp_ms="$(jq -r '.claudeAiOauth.refreshTokenExpiresAt // 0' "${CRED_FILE}" 2>/dev/null || echo 0)"
echo
echo "  Login complete."
if [[ "${exp_ms}" =~ ^[0-9]+$ ]] && (( exp_ms > 0 )); then
  echo "  Grant expires: $(date -d "@$(( exp_ms / 1000 ))" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "~30 days")"
fi
if (( ok_org )); then
  echo "  Organization metadata present — Remote Control eligible."
else
  echo "  WARNING: no organizationUuid yet; if Remote Control complains about"
  echo "  organization eligibility, run this again or use docker attach."
fi
echo "  The supervised session picks the new tokens up automatically."
