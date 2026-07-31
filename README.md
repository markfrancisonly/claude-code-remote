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
<stack-dir>/               # default /docker/claude, set HOST_STACK_DIR
├── compose.yaml           # the hub container
├── claude-login.sh        # guided OAuth login, baked into the image (docker exec)
├── recreate.sh            # apply staged compose/.env changes via sibling handoff
├── Dockerfile             # image: tools + docker CLI + seed Claude install
├── entrypoint.sh          # supervisor: reconnect, reattach, auto-update, auth
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
  days ahead, and can push both via `CLAUDE_NOTIFY_URL`. Re-login any time
  with zero downtime: `docker exec -it claude claude` → `/login` → `/exit`
  (shared credentials file — the running session adopts the new tokens).
  Over SSH, prefer `docker exec -it claude claude-login`: the login UI wraps
  and redraws its authorization URL, which makes it painful to copy out of
  PuTTY. `claude-login` drives that same UI in a hidden PTY, prints the URL
  alone on one line, and prompts for the pasted code — zero downtime, no
  attach, no restart. This is the every-~30-days renewal command. It also
  works when the supervisor is already parked at `login-required`: the
  supervisor polls for externally-completed logins and resumes on its own —
  re-login never requires a container restart.

## Why it stays connected (design)

A bare `claude remote-control` process dies in practice for four distinct
reasons (each documented in anthropics/claude-code issues); the supervisor
handles all of them:

| Failure (evidence) | Mitigation |
|---|---|
| WebSocket drops every 20–60 min; client auto-reconnect sometimes gives up or wedges (#31853, #34255) | In-container supervisor relaunches on exit with capped backoff; optional `CLAUDE_RECYCLE_HOURS` proactively restarts-and-reattaches to bound silent wedges; auto-update keeps the many upstream reconnect fixes current |
| Fatal OAuth 403 "poll death" every few days kills the process; a plain restart orphans all claude.ai sessions under a new environment ID (#53563) | Supervisor relaunches with `--continue` (CLI ≥ 2.1.200) which **reattaches the same claude.ai session**; auth-flavored failures are detected and only force an interactive re-login after repeated failures |
| >~10 min of network unreachability makes the process exit **by design** (docs) | Relaunches are gated on an actual network probe, then reattach via `--continue` |
| OAuth grant hard-expires ~30 days after `/login`; the process then dies instantly — a crash-loop that a state-freshness healthcheck alone reads as *healthy* (≤180s backoff cycles keep the state file inside the 300s staleness window) | Expiry warning N days ahead (log + optional `CLAUDE_NOTIFY_URL` push); "not logged in" stderr is classified fatal → immediate `login-required` (unhealthy); the healthcheck independently flags ≥5 consecutive fast exits as `crash-looping` |

Plus: `restart: always` restarts the whole container if the supervisor
itself ever dies; the reattach marker lives in the persisted volume, so
`docker stop`, `docker restart`, and full recreation/rebuild all come back to
the SAME claude.ai environment (only a clean `/exit` starts fresh); and a
healthcheck distinguishes "connected", "reconnecting", "crash-looping" and
"needs a human to log in" (`docker ps` shows it).

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

Transcripts live in `./data/claude/projects/<cwd-bucket>/`, on the host — a
dead worker, a killed container or a rebuilt image never touches them. They
are also load-bearing: reattach resolves the newest session **by reading those
files**, so losing them turns a resumable session into an orphaned one.

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
   restarts-with-reattach when they differ.

The image itself is just a stable toolbox (docker CLI, git, python, node…);
rebuild occasionally with:

```bash
docker compose build --pull && docker compose up -d
```

## Applying config changes from inside a session

Recreating this container from a session running *inside* it would kill
compose mid-recreate, so `./recreate.sh` hands `docker compose up -d` to a
short-lived sibling container. The session drops and auto-reconnects in
~30–60 s; history is preserved.

## Operations cheat-sheet

```bash
docker logs -f claude                      # supervisor + session logs
docker ps                                  # healthy = connected/reconnecting
docker attach claude                       # local TTY (detach: Ctrl+P Ctrl+Q)
docker exec -it claude bash                # shell next to the session
docker exec claude cat /run/claude/state   # supervisor state
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
`cleanup --yes` deletes originals server-side.

## Contributing

See [HUMAN_POLICY.md](HUMAN_POLICY.md).

## License

MIT — see [LICENSE](LICENSE).
