#!/usr/bin/env python3
"""Offline app-server stand-in that keeps saved threads the way Codex 0.155 does (checked against `codex app-server` in an empty CODEX_HOME):
a saved thread is listed in the person's ChatGPT/Codex apps until it is archived; archiving unloads it; an archived thread can't be resumed or
forked until it is unarchived; archiving one that is already archived, or ephemeral, finds no rollout; unarchiving one that isn't archived is
refused. What it holds is kept in codex-home.json beside its working folder, as Codex keeps its rollouts on disk, so it outlives a restart.
Every request is appended to codex-requests.jsonl there. A turn whose text says HOLD never finishes. No network and no model."""
import json, os, sys, uuid

HOME = os.path.join(os.path.dirname(os.getcwd()), 'codex-home.json')
LOG = os.path.join(os.path.dirname(os.getcwd()), 'codex-requests.jsonl')
loaded = set()   # threads this process has loaded: a restart loads none

def load():
    try:
        with open(HOME) as f: return json.load(f)
    except (OSError, ValueError): return {}
def save(value):
    with open(HOME, 'w') as f: json.dump(value, f)
def out(value): print(json.dumps(value), flush=True)
def fail(m, message): out({'id': m['id'], 'error': {'code': -32600, 'message': message}})

for line in sys.stdin:
    m = json.loads(line); p = m.get('params', {}); method = m.get('method')
    if not method: continue
    with open(LOG, 'a') as f: f.write(json.dumps({'method': method, 'params': p}) + '\n')
    if 'id' not in m: continue
    home = load(); tid = p.get('threadId'); result = {}
    if method == 'account/read': result = {'account': {'type': 'chatgpt', 'planType': 'fixture'}}
    elif method == 'config/read': result = {'config': {}}
    elif method == 'model/list': result = {'data': [{'model': 'gpt-fixture', 'displayName': 'GPT Fixture', 'isDefault': True, 'defaultReasoningEffort': 'medium'}]}
    elif method in ['app/installed', 'app/read']: result = {'apps': []}
    elif method in ['thread/start', 'thread/fork']:
        if method == 'thread/fork':
            if home.get(tid, {}).get('archived'): fail(m, 'session %s is archived. Run `codex unarchive %s` to unarchive it first.' % (tid, tid)); continue
            if tid not in home: fail(m, 'no rollout found for thread id %s' % tid); continue
        new = str(uuid.uuid4()); loaded.add(new)
        if not p.get('ephemeral'): home[new] = {'archived': False, 'opened': method.split('/')[1], 'from': tid, 'turns': 0}; save(home)
        result = {'thread': {'id': new, 'ephemeral': bool(p.get('ephemeral'))}}
    elif method == 'thread/resume':
        if home.get(tid, {}).get('archived'): fail(m, 'session %s is archived. Run `codex unarchive %s` to unarchive it first.' % (tid, tid)); continue
        if tid not in home: fail(m, 'no rollout found for thread id %s' % tid); continue
        loaded.add(tid); result = {'thread': {'id': tid, 'ephemeral': False}}
    elif method == 'thread/archive':
        if tid not in home or home[tid]['archived']: fail(m, 'no rollout found for thread id %s' % tid); continue
        home[tid]['archived'] = True; save(home); loaded.discard(tid)
    elif method == 'thread/unarchive':
        if tid in loaded: fail(m, 'thread %s already has an active writer' % tid); continue
        if not home.get(tid, {}).get('archived'): fail(m, 'no archived rollout found for thread id %s' % tid); continue
        home[tid]['archived'] = False; save(home); result = {'thread': {'id': tid, 'ephemeral': False}}
    elif method == 'thread/inject_items':
        if tid not in loaded: fail(m, 'thread not found: %s' % tid); continue
    elif method == 'turn/start':
        if tid not in loaded: fail(m, 'thread not found: %s' % tid); continue
        if tid in home: home[tid]['turns'] += 1; save(home)
        text = '\n'.join(x.get('text', '') for x in p['input']); turn = 'turn-' + uuid.uuid4().hex[:6]
        out({'id': m['id'], 'result': {'turn': {'id': turn, 'status': 'inProgress'}}})
        if 'HOLD' in text: continue
        answer = json.dumps({'thread': tid, 'saved': tid in home})
        out({'method': 'item/completed', 'params': {'threadId': tid, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer-' + turn, 'phase': 'final_answer', 'text': answer}}})
        out({'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': turn, 'status': 'completed'}}}); continue
    elif method not in ['initialize', 'thread/unsubscribe', 'turn/interrupt']:
        raise AssertionError(method)
    out({'id': m['id'], 'result': result})
