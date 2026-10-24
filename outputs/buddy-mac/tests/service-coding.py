#!/usr/bin/env python3
"""Offline stand-in for the Claude coding bridge (coding.mjs) and the supervisor's Claude run, for tests/ServiceLeases.swift. No model and
no network. A coding brief with CALLS:<json list> plays those calls one after another, whatever each one returns; an attempt whose brief
carries a note from Buddy ("[Buddy]") plays AFTER:<json list> instead when there is one. A call is [tool, arguments] or [tool, arguments,
{"until": {"path": "body.status", "equals": "RUNNING"}}], which repeats it (a tenth of a second apart) until the result says so. In
arguments, "$R<n>.<path>" is a value from result n of this attempt (the whole string: the value itself; inside text: as text). Pseudo-calls:
["$write", {"path", "content"}] writes a file into the project (the bridge's cwd), ["$finish", text] ends the attempt there, ["$fail",
text] ends it with an error. A result that says paused ends the attempt. The supervisor's run approves a service request (unless its reason
says DECLINE) and holds everything else. Every start, tool result and supervisor brief goes to BUDDY_SERVICE_CODING_LOG."""
import json, os, re, sys, time

LOG = os.environ.get('BUDDY_SERVICE_CODING_LOG', '')
SESSION = '3d2f1a0b-9c8e-4f7d-8a6b-5c4d3e2f1a0b'
config, queue, results, number = {}, [], [], [0]

def log(kind, value):
    if LOG:
        with open(LOG, 'a') as f: f.write(json.dumps({'kind': kind, 'value': value}) + '\n')
def emit(value): print(json.dumps(dict(value, runId=config.get('runId', ''))), flush=True)
def finish(text): emit({'type': 'result', 'text': text, 'subtype': 'success', 'cost': 0.0, 'sessionId': SESSION})
def fail(text): emit({'type': 'result', 'text': text, 'subtype': 'error_other', 'error': text, 'cost': 0.0, 'sessionId': SESSION})
def get(value, path):
    for part in [p for p in path.split('.') if p]:
        if isinstance(value, list): value = value[int(part)] if part.isdigit() and int(part) < len(value) else None
        elif isinstance(value, dict): value = value.get(part)
        else: return None
    return value
def fill(value):
    if isinstance(value, str):
        whole = re.fullmatch(r'\$R(\d+)((?:\.[A-Za-z0-9_]+)*)', value)
        if whole: return get(results[int(whole.group(1))], whole.group(2))
        return re.sub(r'\$R(\d+)((?:\.[A-Za-z0-9_]+)*)', lambda m: str(get(results[int(m.group(1))], m.group(2))), value)
    if isinstance(value, dict): return {k: fill(v) for k, v in value.items()}
    if isinstance(value, list): return [fill(v) for v in value]
    return value
def next_call():
    while queue:
        step = queue[0]
        if step[0] == '$write':
            queue.pop(0); spec = fill(step[1]); path = os.path.join(config['cwd'], spec['path'])
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w') as f: f.write(spec['content'])
            results.append({'written': spec['path']}); continue
        if step[0] == '$finish': queue.clear(); finish(step[1]); return
        if step[0] == '$fail': queue.clear(); fail(step[1]); return
        number[0] += 1
        emit({'type': 'call', 'id': 'c%d' % number[0], 'tool': step[0], 'arguments': fill(step[1])})
        return
    finish('Done.')

def supervise(c):
    brief = json.loads(c['prompt'])
    log('supervisor', {'items': brief.get('items', [])})
    actions = []
    for i in brief.get('items', []):
        request = i.get('serviceRequest')
        if i.get('kind') == 'command_review' and request:
            decline = 'DECLINE' in request.get('reason', '')
            actions.append({'item': i['key'], 'do': 'decline_command' if decline else 'approve_command', 'reason': 'Not what the task needs.' if decline else 'A note the task needs, on the user’s notes service.'})
        else:
            actions.append({'item': i['key'], 'do': 'hold', 'reason': 'Nothing to do yet.'})
    print(json.dumps({'type': 'result', 'runId': c['runId'], 'text': json.dumps({'actions': actions}), 'subtype': 'success', 'error': None, 'cost': 0.0, 'sessionId': 'fixture'}), flush=True)

for line in sys.stdin:
    value = json.loads(line)
    if value.get('command') == 'start':
        if value.get('outputSchema'): config = value; supervise(value); continue
        config = value; prompt = value['prompt']; results.clear(); queue.clear()
        log('start', {'tools': [t['name'] for t in value['tools']], 'prompt': prompt, 'instructions': value['instructions'], 'cwd': value['cwd']})
        emit({'type': 'session', 'sessionId': SESSION})
        marker = 'AFTER:' if '[Buddy]' in prompt and 'AFTER:' in prompt else 'CALLS:'
        at = prompt.find(marker)
        if at < 0: finish('Nothing to do.'); continue
        calls, _ = json.JSONDecoder().raw_decode(prompt, at + len(marker))
        queue.extend(calls); next_call()
    elif value.get('command') == 'result':
        result = value['result']; log('result', {'id': value['id'], 'tool': queue[0][0] if queue else '', 'result': result})
        step = queue[0] if queue else None
        if step and len(step) > 2 and 'until' in step[2]:
            want = step[2]['until']
            if get(result, want['path']) != want['equals'] and step[2].setdefault('tries', 0) < 300:
                step[2]['tries'] += 1; time.sleep(0.1); number[0] += 1
                emit({'type': 'call', 'id': 'c%d' % number[0], 'tool': step[0], 'arguments': fill(step[1])}); continue
        if queue: queue.pop(0)
        results.append(result)
        if result.get('paused'): queue.clear(); finish('Waiting for the user.'); continue
        next_call()
    elif value.get('command') == 'stop':
        break
