# claude-code-remote

A fully containerized `claude remote-control` deployment: a single hub
container that runs 24/7 on a Docker host and is operated from the Claude
mobile app, Claude Desktop, and claude.ai/code. It manages the host's Docker
environment through the mounted socket, and all work happens as concurrent
sessions on that one hub.

The container runs as root and mounts the Docker socket, which is
root-equivalent on the host — run it only on a host you would give Claude
full control of, and don't expose it to untrusted networks.

```
<stack-dir>/               # default /docker/claude
├── compose.yaml           # the hub container
├── claude-login.sh        # guided OAuth login, baked into the image (docker exec)
├── recreate.sh            # apply staged compose/.env changes via sibling handoff
├── Dockerfile             # image: tools + docker CLI + seed Claude install
├── entrypoint.sh          # supervisor: reconnect, auto-update, auth
├── healthcheck.sh         # docker healthcheck (state machine aware)
├── .env                   # all configuration switches (copy of .env.example)
└── data/
    ├── claude/            # ~/.claude — auth, sessions, settings (shared by all)
    └── local/             # ~/.local — hub's CLI install (self-updating)
```

## First deployment

```bash
docker compose up -d --build
docker exec -it claude claude-login   # guided OAuth login, copy-friendly URL
```

(Manual alternative: `docker exec -it claude claude`, then `/login`, complete
the flow, `/exit`.)

Auth persists in `./data/claude` and survives restarts, recreations, image
rebuilds and CLI updates.

**Auth gotchas:**

- Remote Control needs BOTH the tokens in `data/claude/.credentials.json` AND
  the `oauthAccount` org metadata in `data/claude/.claude.json`. The
  entrypoint symlinks `~/.claude.json` to the persisted file and never
  fabricates it — a synthetic file without `oauthAccount` permanently breaks
  org detection ("Unable to determine your organization").
- Only a full `/login` works. `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN`
  are inference-only. `ANTHROPIC_API_KEY` or a non-Anthropic
  `ANTHROPIC_BASE_URL` in the environment silently disables Remote Control.
- **Logins hard-expire ~30 days after `/login`**: the grant carries an
  absolute `refreshTokenExpiresAt` (visible in `.credentials.json`) that
  token rotation does NOT extend. Past it, launches die instantly with
  "You must be logged in to use Remote Control" even though the account is
  fine. The supervisor classifies those as fatal (immediate `login-required`,
  unhealthy in `docker ps`), warns `CLAUDE_AUTH_EXPIRY_WARN_DAYS` (default 5)
  days ahead, and can push both via `CLAUDE_NOTIFY_URL` — a generic webhook
  that takes a plain-text POST body by default, or
  `{"source","event","message"}` JSON with `CLAUDE_NOTIFY_FORMAT=json`
  (for Home Assistant webhooks, Slack/gotify gateways, and the like). Re-login any time
  with zero downtime: `docker exec -it claude claude` → `/login` → `/exit`
  (shared credentials file — the running session adopts the new tokens).
  A re-login can recover the connection, but does not guarantee that old
  remote sessions or their environment can be restored after the outage.
  Local transcripts remain in the persisted volume; for sessions that do
  not come back, see [revive-sessions.py](#revive-sessionspy) below.
  Over SSH, prefer `docker exec -it claude claude-login`: the login UI wraps
  and redraws its authorization URL, which makes it painful to copy out of
  PuTTY. `claude-login` drives that same UI in a hidden PTY, prints the URL
  alone on one line, and prompts for the pasted code — zero downtime, no
  attach, no restart. This is the every-~30-days renewal command. It also
  works when the supervisor is already parked at `login-required`: the
  supervisor polls for externally-completed logins and resumes on its own —
  re-login never requires a container restart.

## Why it stays connected (design)

The supervisor relaunches the normal multi-session server in the same
workspace directory. Claude maintains its own reconnect record,
`projects/<cwd-bucket>/bridge-pointer.json`, in the persisted `data/claude`
volume. The supervisor neither guesses a primary session from transcript
filenames nor uses `--continue` / `--session-id`: those flags restore only
one session and cannot be combined with multi-session spawn/capacity flags.

According to the [official Remote Control documentation](https://code.claude.com/docs/en/remote-control#resume-sessions-after-stopping-the-server),
a normal server restart can restore its previous sessions for about **four
hours** after stopping. Keep the working directory unchanged, run only one
server there, and leave session precreation enabled (do not pass
`--no-create-session-in-dir`). The supervisor forwards termination to Claude
and waits for orderly shutdown; Compose allows 45 seconds before force-kill.
Longer outages, expired logins, or unavailable server-side sessions can still
require a fresh session. Saved transcripts are not a guarantee of restoring
the old app conversation.

| Failure | Mitigation |
|---|---|
| Remote-control process exits | Relaunch with capped backoff and the same server settings; native reconnect state handles eligible sessions |
| Network is unreachable | Wait for a network probe to succeed before relaunching |
| Login expires or is rejected | Log and optionally send expiry warnings; fatal authentication failures enter `login-required`; repeated fast failures also report unhealthy |
| Process stays alive but stops responding | Optional `CLAUDE_RECYCLE_HOURS` bounds silent stalls; disabled by default because recycling interrupts sessions |

`restart: always` restarts the container if the supervisor itself dies.
The healthcheck reports process/state health, including reconnecting,
crash-looping and login-required; it does not prove that every app
conversation is reachable.

## Multi-project architecture

All work happens as **sessions on the single hub**, which runs
`claude remote-control` in server mode with `--capacity` concurrent sessions.
"New session" in the mobile app / claude.ai/code opens another session in the
workspace directory; the stack pins Claude's spawn mode to `same-dir` so the
remote-control process starts non-interactively. Every subdirectory can be
its own git repo (`git safe.directory` is pre-trusted globally). Use
`/add-dir` to pull more directories into a session. Per-project context lives
in each repo's `CLAUDE.md` (auto-loaded when files there are touched).

*(Design rule if a sibling container ever shares `data/claude`: every
`claude remote-control` process MUST have a unique working directory —
session crash-resume is bucketed by cwd, and two processes on one cwd adopt
each other's sessions. A single shared credentials file across processes is
the supported multi-login pattern; separate logins rotate each other's
refresh tokens.)*

## docker-mcp: considered, not baked in

Claude inside this container already has the full `docker` CLI + compose
against the mounted socket — strictly more capable than MCP tool wrappers
around the same socket, and Remote Control already gives the mobile/Desktop
apps full access to it. A docker MCP server would only add value to let
Claude Desktop manage the host *without* a remote-control session, at the
cost of exposing and authenticating another network service. If ever wanted,
it's a config-level addition (`claude mcp add` / an MCP gateway container),
not an architecture change.

## Session history & retention

Transcripts live in `./data/claude/projects/<cwd-bucket>/`, on the host,
and survive container recreation and image rebuilds. They preserve local
conversation history separately from the CLI's native remote reconnect
record. Keeping them longer does not extend the remote reconnect window.

The CLI prunes them after `cleanupPeriodDays`, which upstream defaults to 30.
First boot therefore seeds `settings.json` with
`CLAUDE_TRANSCRIPT_RETENTION_DAYS` (default 3650). It only ever *adds* the key
— set it yourself and the entrypoint leaves your value alone; set the variable
to `0` and it won't touch `settings.json` at all.

## Auto-update

Two mechanisms, both persisted so they survive recreation:

1. The native CLI self-updates in the background (default behavior).
2. The supervisor checks every `CLAUDE_UPDATE_INTERVAL_HOURS` (default 12),
   runs `claude update`, and — because a running process keeps its old
   version — compares the on-disk version to the *launched* version and
   restarts when they differ if `CLAUDE_UPDATE_RESTART=1`. With `0`, the new
   version takes effect on the next natural restart.

The image itself is just a stable toolbox (docker CLI, git, python, node…);
rebuild occasionally with:

```bash
docker compose build --pull && docker compose up -d
```

## Applying config changes from inside a session

Recreating this container from a session running *inside* it would kill
compose mid-recreate, so `./recreate.sh` hands `docker compose up -d` to a
short-lived sibling container. Active sessions are interrupted while the
container is replaced. Local history is preserved; eligible remote sessions
can reconnect through the CLI's native recovery described above. The helper
reads Claude's stack path from its Compose labels, falling back to its own
directory, so invoking it from another container targets the Claude stack.

## Operations cheat-sheet

```bash
docker logs -f claude                      # supervisor + session logs
docker ps                                  # healthy = connected/reconnecting
docker attach claude                       # local TTY (detach: Ctrl+P Ctrl+Q)
docker exec -it claude bash                # shell next to the session
docker exec claude cat /run/claude/state   # supervisor state
docker exec claude cat /run/claude/state-history  # timestamped state transitions
docker exec claude cat /run/claude/last-stderr    # stderr of the last abnormal exit
docker exec -it claude claude-login        # guided ~30-day re-login (see above)
docker exec -it claude claude              # zero-downtime re-login (/login, /exit)
CLAUDE_FORCE_AUTH_LOGIN=1 in .env + up -d  # force a fresh /login
```

**Healthcheck states:** `running` (claude process alive), `starting`,
`auth-check`, `network-wait`, `backoff` (transient, healthy while fresh),
`login-required` (unhealthy — attach and `/login`). Independently of state,
≥5 consecutive fast exits report unhealthy as `crash-looping`.

**Known upstream behaviors** (not fixable client-side): idle remote sessions
can be archived server-side after ~10–20 min without real messages; archived
sessions reappear on the next message or reattach. Old disconnected sessions
may accumulate at claude.ai/code — archive them in the UI.

## revive-sessions.py

A session is "wedged" when its worker died dirty (e.g. a host reboot severed
the connection before the server could deregister it): the backend accepts
client messages but never dispatches a new worker, and the client shows
"bridged Claude Code process stopped responding mid-turn" forever. Clean
shutdowns revive on their own. Run inside the container — `plan` first, since
`run` recreates every disconnected active session it lists and
`cleanup --yes` deletes originals server-side. Sessions stranded on an
environment that no longer exists (they show "Remote environment
unavailable") need `--from-env <env id>` on `plan` and `run`.

## Contributing

Offline regression checks (use a fake CLI and Docker; no live sessions):

```bash
bash tests/test-server-reconnect.sh
bash tests/test-recreate.sh
```

See [HUMAN_POLICY.md](HUMAN_POLICY.md).

## License

MIT — see [LICENSE](LICENSE).
