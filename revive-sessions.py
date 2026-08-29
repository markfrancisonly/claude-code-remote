#!/usr/bin/env python3
"""Revive wedged claude.ai cloud sessions into fresh ones with context transfer.

A session is "wedged" when its worker died dirty (host reboot: connection
vanished before the RC server could deregister it) — the backend then accepts
client messages but never dispatches a new worker, and the client shows
"bridged Claude Code process stopped responding mid-turn" forever. Clean
SIGTERM deaths (recreate.sh) revive on their own; this tool is for the rest.

Run INSIDE the hub container (needs ~/.claude/.credentials.json and the
local transcripts).

CAUTION: disconnected != wedged. After a clean hub restart every idle session
shows disconnected but revives when a client pokes it. Only run this for
sessions that still error with "stopped responding" AFTER the hub reconnects,
and review `plan` output first — `run` recreates every disconnected active
session it lists, `cleanup --yes` deletes the originals server-side.

Usage:
  revive-sessions.py list                 all cloud sessions + status
  revive-sessions.py plan                 wedged sessions + transcript mapping
  revive-sessions.py run                  create replacements + transfer context
  revive-sessions.py cleanup --yes        DELETE originals whose replacement replied
State: /tmp/revive_state.json (per-run; safe to delete between campaigns).
"""
import argparse, datetime as dt, glob, json, os, re, sys, time, urllib.request

API = 'https://api.anthropic.com/v1/code'
STATE = '/tmp/revive_state.json'
# Transcripts live in ~/.claude/projects/<bucket>, where <bucket> is the cwd
# with every non-alphanumeric character replaced by '-'.
BUCKET = os.path.expanduser('~/.claude/projects/' + re.sub(
    r'[^A-Za-z0-9]', '-', os.environ.get('WORKSPACE_DIR', '/docker')))
BATCH = 5
WAIT_S = 1500

TOKEN = json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken']


def api(path, method='GET', body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body else None)
    req.add_header('Authorization', 'Bearer ' + TOKEN)
    req.add_header('anthropic-version', '2023-06-01')
    req.add_header('anthropic-beta', 'oauth-2025-04-20')
    if body:
        req.add_header('content-type', 'application/json')
    return json.load(urllib.request.urlopen(req, timeout=30))


def sessions():
    out, cursor = [], None
    while True:
        d = api('/sessions?limit=100' + (f'&cursor={cursor}' if cursor else ''))
        out.extend(d['data'])
        cursor = d.get('next_cursor')
        if not cursor or not d['data']:
            return out


def live_env(sess):
    # the env that currently-connected ACTIVE sessions (e.g. the hub primary) sit on;
    # archived sessions can carry stale connected flags on dead envs. NOTE:
    # connection_status tracks attached *clients* and can read disconnected
    # for every session while nobody has one open — use --env then.
    envs = {s['environment_id'] for s in sess
            if s['connection_status'] == 'connected' and s['status'] == 'active'}
    if len(envs) != 1:
        sys.exit(f"cannot determine live env (connected sessions on: {envs or 'none'}); "
                 f"pass --env with the id shown by the hub console or `list`")
    return envs.pop()


def resolve_env(sess, want):
    # accept a full env id or a unique suffix (list prints env=…XXXXXX)
    hits = {e for e in {s['environment_id'] for s in sess}
            if e == want or e.endswith(want)}
    if len(hits) != 1:
        sys.exit(f"env {want!r} matches {len(hits)} environments (need exactly 1)")
    return hits.pop()


def parse_ts(t):
    return dt.datetime.fromisoformat(t.replace('Z', '+00:00'))


def transcripts():
    out = []
    for f in glob.glob(BUCKET + '/*.jsonl'):
        with open(f, errors='ignore') as fh:
            for line in fh:
                try:
                    ts = json.loads(line).get('timestamp')
                except ValueError:
                    continue
                if ts:
                    out.append((f, parse_ts(ts), os.path.getsize(f)))
                break
    return out


def wedged_map(sess, src=None):
    # src: env whose disconnected-active sessions are the revival candidates.
    # Default is the live env (the original wedged-on-a-surviving-env case);
    # pass --from-env when the sessions are stranded on a DEAD env — e.g.
    # after a resume fallback registered a fresh environment (2026-08-29).
    env = resolve_env(sess, src) if src else live_env(sess)
    trans = transcripts()
    out = []
    for s in sorted(sess, key=lambda x: x['created_at']):
        if not (s['environment_id'] == env and s['connection_status'] == 'disconnected'
                and s['status'] == 'active'):
            continue
        c = parse_ts(s['created_at'])
        best = min(((f, sz, abs((ts - c).total_seconds())) for f, ts, sz in trans),
                   key=lambda x: x[2], default=None)
        if best and best[2] > 900:  # no transcript within 15 min of creation
            best = None
        out.append({'id': s['id'], 'title': s.get('title', ''), 'created': s['created_at'],
                    'model': s['config'].get('model'), 'perm': s['config'].get('permission_mode'),
                    'needs': (s.get('external_metadata', {}).get('post_turn_summary') or {}).get('needs_action', ''),
                    'transcript': best[0] if best else None,
                    'size': best[1] if best else 0, 'delta_s': int(best[2]) if best else None})
    return out


def kickoff_text(o):
    t = (f"[Context transfer — automated] This session replaces '{o['title']}' ({o['id']}), whose worker "
         f"died uncleanly and cannot be revived server-side. "
         f"Full prior conversation transcript: {o['transcript']} ({o['size']} bytes). ")
    if o['needs']:
        t += f"Status snapshot at time of loss — needs action: {o['needs']}. "
    t += ("Read the transcript now (start from the end, work backward as far as needed to fully understand "
          "where the work stood; if the story seems to continue elsewhere, check sibling *.jsonl files in the "
          "same directory by topic). Then reply with a short resume brief: state of the work, anything "
          "mid-flight, and likely next steps. Take NO other actions and change NO files until directed.")
    return t


def cmd_list():
    for s in sorted(sessions(), key=lambda x: x['created_at']):
        print(f"{s['created_at'][:16]} {s['id']} env=…{s['environment_id'][-6:]} "
              f"{s['connection_status']:<12} {s['status']}/{s['status_bucket']} | {s.get('title','')[:55]}")


def cmd_plan(src=None):
    for o in wedged_map(sessions(), src):
        tr = os.path.basename(o['transcript']) if o['transcript'] else 'NO MATCH'
        print(f"{o['created'][:16]} {o['id'][:16]}… → {tr} (Δ{o['delta_s']}s {o['size']}B) | {o['title'][:50]}")


def cmd_run(src=None, target=None):
    sess = sessions()
    todo = [o for o in wedged_map(sess, src) if o['transcript']]
    state = json.load(open(STATE)) if os.path.exists(STATE) else {}
    env = resolve_env(sess, target) if target else live_env(sess)
    todo = [o for o in todo if state.get(o['id'], {}).get('status') not in ('done', 'failed')]
    for i in range(0, len(todo), BATCH):
        batch = todo[i:i + BATCH]
        for o in batch:
            st = state.setdefault(o['id'], {})
            if 'new_id' not in st:
                r = api('/sessions', 'POST', {'environment_id': env, 'title': o['title'],
                        'config': {'model': o['model'] or 'claude-opus-5',
                                   'permission_mode': o['perm'] or 'acceptEdits'}})
                st['new_id'] = r['session']['id']
                api(f"/sessions/{st['new_id']}/events", 'POST', {'events': [{'event_type': 'user',
                    'payload': {'type': 'user', 'message': {'role': 'user', 'content': kickoff_text(o)}}}]})
                st['status'] = 'kicked'
                print(f"created {st['new_id']} for: {o['title'][:50]}", flush=True)
                json.dump(state, open(STATE, 'w'))
                time.sleep(2)
        deadline = time.time() + WAIT_S
        while time.time() < deadline:
            pending = [o for o in batch if state[o['id']]['status'] == 'kicked']
            if not pending:
                break
            time.sleep(20)
            for o in pending:
                st = state[o['id']]
                try:
                    s = api(f"/sessions/{st['new_id']}")['response_shape']
                except Exception as e:
                    print(f"poll error {o['title'][:30]}: {e}", flush=True)
                    continue
                if s['worker_status'] == 'idle' and s['status_bucket'] in ('review_ready', 'blocked', 'completed'):
                    st['status'] = 'done'
                    print(f"REPLIED: {o['title'][:50]}", flush=True)
                elif s['status_bucket'] == 'failed':
                    st['status'] = 'failed'
                    print(f"FAILED: {o['title'][:50]}", flush=True)
                json.dump(state, open(STATE, 'w'))
        for o in batch:
            if state[o['id']]['status'] == 'kicked':
                state[o['id']]['status'] = 'timeout'
                print(f"TIMEOUT: {o['title'][:50]}", flush=True)
        json.dump(state, open(STATE, 'w'))
    print(json.dumps({k: v['status'] for k, v in state.items()}, indent=1))


def cmd_cleanup(yes):
    state = json.load(open(STATE))
    for old_id, st in state.items():
        if st.get('status') != 'done':
            print(f"skip {old_id}: {st.get('status')}")
            continue
        if not yes:
            print(f"would DELETE {old_id} (replaced by {st['new_id']})")
            continue
        api(f"/sessions/{old_id}", 'DELETE')
        st['status'] = 'deleted'
        print(f"DELETED {old_id} (replaced by {st['new_id']})")
        json.dump(state, open(STATE, 'w'))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('cmd', choices=['list', 'plan', 'run', 'cleanup'])
    p.add_argument('--yes', action='store_true', help='cleanup: actually delete originals')
    p.add_argument('--from-env', metavar='ENV',
                   help='plan/run: revive sessions stranded on this env (id or '
                        'unique suffix) instead of the live one — for sessions '
                        'orphaned on a dead env by a fresh-environment fallback')
    p.add_argument('--env', metavar='ENV',
                   help='run: create replacements on this env (id or unique '
                        'suffix) instead of auto-detecting the live one')
    a = p.parse_args()
    {'list': cmd_list, 'plan': lambda: cmd_plan(a.from_env),
     'run': lambda: cmd_run(a.from_env, a.env),
     'cleanup': lambda: cmd_cleanup(a.yes)}[a.cmd]()
