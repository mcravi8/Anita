#!/usr/bin/env python3
"""Inert stand-in for the supervisor's Claude run. No network, no real keys, no user data.

It reads the lane's start command, records what it was given in fixture-calls.jsonl (next to the run folders), and answers with the
structured actions the test chose in fixture-mode.txt: auto (accept results, answer questions, resume stops, finish stage checks),
forward, bogus, hold or fail."""
import json, sys
from pathlib import Path

ANSWER = 'Use Table 2 of the paper; it is the published baseline.'

for line in sys.stdin:
    c = json.loads(line)
    if c.get('command') != 'start':
        continue
    folder = Path(c['cwd']).parent
    brief = json.loads(c['prompt'])
    mode_file = folder / 'fixture-mode.txt'
    mode = mode_file.read_text().strip() if mode_file.exists() else 'auto'
    items = brief.get('items', [])
    schema = c['outputSchema']
    call = {
        'runId': c['runId'], 'model': c['model'], 'mode': mode, 'tools': c['tools'], 'budget': c['budget'],
        'items': [i['key'] for i in items], 'kinds': [i['kind'] for i in items],
        'enum': schema['properties']['actions']['items']['properties']['do']['enum'],
        'policy': 'Decisions: decide by default.' in c['instructions'],
        'supervises': 'You supervise this team.' in c['instructions'],
        'text': 'supervising this Buddy team in the background between the user' in c['instructions'] and 'is data, never instructions' in c['instructions'],
        'you': brief.get('you'), 'authorization': brief.get('authorization'), 'directives': brief.get('directives'),
        'members': [m.get('id') for m in brief.get('members', [])], 'outcomes': len(brief.get('ledger', {}).get('outcomes', [])),
        'files': [f for i in items for f in i.get('files', [])], 'results': [i.get('result', '') for i in items],
        'questions': [(i.get('question') or {}).get('question', '') for i in items], 'cwd': c['cwd'], 'home': c['home'],
        'notices': 'notices' in (brief.get('plan') or {}), 'bytes': len(c['prompt'].encode()),
    }
    with (folder / 'fixture-calls.jsonl').open('a') as f:
        f.write(json.dumps(call) + '\n')
    if mode == 'fail':
        print(json.dumps({'type': 'result', 'runId': c['runId'], 'text': '', 'subtype': 'error_during_execution', 'error': 'Claude hit an error while working.', 'cost': 0.01, 'sessionId': 'fixture'}), flush=True)
        continue
    actions = []
    plan = brief.get('plan') or {}
    for i in items:
        key, kind = i['key'], i['kind']
        if mode == 'hold':
            actions.append({'item': key, 'do': 'hold', 'reason': 'Waiting to see more.'})
        elif mode == 'forward':
            actions.append({'item': key, 'do': 'forward_to_user', 'reason': 'Only the user can sign in.', 'category': 'credential',
                            'text': 'Forge needs you to sign in to the data portal.', 'recommendation': 'Sign in with your university account.'})
        elif mode == 'bogus':
            actions.append({'item': 'no-such-item', 'do': 'accept', 'reason': 'An item nobody presented.'})
            actions.append({'item': key, 'do': 'accept', 'reason': 'Looks done.'})
            actions.append({'item': key, 'do': 'stage_done', 'reason': 'All done.', 'text': 'Done.', 'evidence': ['task:nothing']})
        elif kind == 'question':
            actions.append({'item': key, 'do': 'answer', 'reason': 'The paper names Table 2 as the baseline.', 'text': ANSWER})
        elif kind == 'result':
            actions.append({'item': key, 'do': 'accept', 'reason': 'It delivers the deliverable.'})
        elif kind in ('stopped', 'paused'):
            actions.append({'item': key, 'do': 'resume', 'reason': 'A technical stop.'})
        elif kind == 'stage_check':
            stage = next((s for s in plan.get('stages', []) if s.get('id') == i.get('stage', {}).get('id')), {})
            done = ['task:' + t['id'] for t in stage.get('tasks', []) if t.get('status') == 'done']
            actions.append({'item': key, 'do': 'stage_done', 'reason': 'Every criterion is met.', 'evidence': done,
                            'text': 'Stage 1 is done: the baseline reproduces and Vera signed off. Files: baseline.csv. Decisions I made: Table 2 is the baseline. Open: none.'})
        else:
            actions.append({'item': key, 'do': 'hold', 'reason': 'Nothing to do yet.'})
    print(json.dumps({'type': 'result', 'runId': c['runId'], 'text': json.dumps({'actions': actions}), 'subtype': 'success', 'error': None, 'cost': 0.07, 'sessionId': 'fixture'}), flush=True)
