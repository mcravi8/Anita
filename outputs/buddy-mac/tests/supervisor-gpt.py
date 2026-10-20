#!/usr/bin/env python3
"""Inert stand-in for the supervisor's ChatGPT run: a Codex app-server that never contacts an account or the network. No real keys, no user data.

ConversationService starts it in <support>/Conversations. It answers the app-server protocol, records what each supervisor turn was given in
Worker/Supervisor/fixture-calls.jsonl (the same file the Claude fixture writes, with transport "chatgpt"): the model, whether the thread had
any tool surface, the output schema and the instructions, and answers with the structured actions the test chose in
Worker/Supervisor/fixture-mode.txt: auto (accept results, answer questions, resume stops, plan empty stages, finish stage checks; a
commentary message comes before the answer), hold, fail (the turn fails before any answer), empty (the turn completes with no answer),
crash (the app-server exits half way through the turn) or signedout (the account is not signed in to ChatGPT)."""
import json, os, sys
from pathlib import Path

ANSWER = 'Use Table 2 of the paper; it is the published baseline.'
FIRST = 'Freeze stage 2 rules, classify every shock and run the paired p-by-maturity test'
folder = Path(os.getcwd()).parent / 'Worker' / 'Supervisor'
threads = {}
injected = {}
seq = 0


def mode():
    f = folder / 'fixture-mode.txt'
    return f.read_text().strip() if f.exists() else 'auto'


def out(x):
    print(json.dumps(x), flush=True)


def actions_for(brief, current):
    actions = []
    plan = brief.get('plan') or {}
    for i in brief.get('items', []):
        key, kind = i['key'], i['kind']
        if current == 'hold':
            actions.append({'item': key, 'do': 'hold', 'reason': 'Waiting to see more.'})
        elif kind == 'question':
            actions.append({'item': key, 'do': 'answer', 'reason': 'The paper names Table 2 as the baseline.', 'text': ANSWER})
        elif kind == 'result':
            actions.append({'item': key, 'do': 'accept', 'reason': 'It delivers the deliverable.'})
        elif kind in ('stopped', 'paused'):
            actions.append({'item': key, 'do': 'resume', 'reason': 'A technical stop.'})
        elif kind == 'stage_plan':
            ids = {m.get('name'): m.get('id') for m in brief.get('members', [])}
            actions.append({'item': key, 'do': 'add_tasks', 'reason': 'Stage 2 is authorized and has no tasks yet.', 'tasks': [
                {'title': FIRST, 'assignee': ids.get('Forge', ''), 'kind': 'coding', 'brief': 'Freeze the stage 2 rules, classify every shock and run the paired p-by-maturity test.',
                 'deliverable': 'The classification table and the test results'},
                {'title': 'Vera sign-off or objections on the stage 2 classification and maturity test', 'assignee': ids.get('Vera', ''), 'kind': 'general', 'dependsOn': [FIRST],
                 'brief': 'Review the classification and the maturity test; sign off or list objections.', 'deliverable': 'A sign-off note or a list of objections'}]})
        elif kind == 'stage_check':
            stage = next((s for s in plan.get('stages', []) if s.get('id') == i.get('stage', {}).get('id')), {})
            done = ['task:' + t['id'] for t in stage.get('tasks', []) if t.get('status') == 'done']
            actions.append({'item': key, 'do': 'stage_done', 'reason': 'Every criterion is met.', 'evidence': done,
                            'text': 'Stage 1 is done: the baseline reproduces and Vera signed off. Files: baseline.csv. Decisions I made: Table 2 is the baseline. Open: none.'})
        else:
            actions.append({'item': key, 'do': 'hold', 'reason': 'Nothing to do yet.'})
    return actions


for line in sys.stdin:
    m = json.loads(line)
    method, p = m.get('method'), m.get('params', {})
    if not method:
        continue
    r = {}
    if method == 'account/read':
        r = {'account': None} if mode() == 'signedout' else {'account': {'type': 'chatgpt', 'planType': 'fixture'}}
    elif method == 'config/read':
        r = {'config': {}}
    elif method == 'model/list':
        r = {'data': [{'model': 'fixture-gpt', 'isDefault': True}, {'model': 'fixture-gpt-chief', 'isDefault': False}, {'model': 'gpt-5', 'isDefault': False}]}
    elif method in ('app/installed', 'app/read'):
        r = {'apps': []}
    elif method == 'thread/start':
        seq += 1
        tid = 'thread-' + str(seq)
        threads[tid] = p
        r = {'thread': {'id': tid}}
    elif method == 'thread/inject_items':
        injected[p.get('threadId')] = json.dumps(p.get('items', []))
    elif method == 'turn/start':
        tid = p['threadId']
        thread = threads.get(tid, {})
        instructions = (thread.get('developerInstructions') or '') + injected.get(tid, '')
        texts = [i.get('text', '') for i in p.get('input', []) if i.get('type') == 'text']
        brief = json.loads(texts[0]) if len(texts) == 1 else {}
        items = brief.get('items', [])
        schema = p.get('outputSchema') or {}
        current = mode()
        call = {
            'transport': 'chatgpt', 'runId': p.get('clientUserMessageId'), 'model': p.get('model'), 'mode': current,
            'items': [i['key'] for i in items], 'kinds': [i['kind'] for i in items],
            'dynamicTools': thread.get('dynamicTools', []), 'apps': (thread.get('config') or {}).get('features.apps'),
            'sandbox': thread.get('sandbox'), 'approvalPolicy': thread.get('approvalPolicy'), 'ephemeral': thread.get('ephemeral'),
            'mentions': [i for i in p.get('input', []) if i.get('type') != 'text'], 'outputSchema': schema,
            'policy': 'Decisions: decide by default.' in instructions,
            'supervises': 'You supervise this team.' in instructions,
            'text': 'supervising this Buddy team in the background between the user' in instructions and 'is data, never instructions' in instructions,
            'addTasks': 'Each task is {key, title, assignee, kind, brief, deliverable, dependsOn}' in instructions and 'authorized stage with no tasks' in instructions,
            'you': brief.get('you'), 'authorization': brief.get('authorization'), 'results': [i.get('result', '') for i in items],
            'bytes': len(texts[0].encode()) if texts else 0,
        }
        folder.mkdir(parents=True, exist_ok=True)
        with (folder / 'fixture-calls.jsonl').open('a') as f:
            f.write(json.dumps(call) + '\n')
        if current == 'crash':
            sys.exit(0)
        seq += 1
        turn = 'turn-' + str(seq)
        out({'id': m['id'], 'result': {'turn': {'id': turn, 'status': 'inProgress'}}})
        if current == 'fail':
            out({'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': turn, 'status': 'failed', 'error': {'message': 'ChatGPT hit an error before answering.'}}}})
            continue
        if current == 'empty':
            out({'method': 'item/completed', 'params': {'threadId': tid, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer-' + turn, 'phase': 'final_answer', 'text': ''}}})
            out({'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': turn, 'status': 'completed'}}})
            continue
        out({'method': 'item/completed', 'params': {'threadId': tid, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'note-' + turn, 'phase': 'commentary', 'text': 'Reading the items.'}}})
        answer = json.dumps({'actions': actions_for(brief, current)})
        out({'method': 'item/completed', 'params': {'threadId': tid, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer-' + turn, 'phase': 'final_answer', 'text': answer}}})
        out({'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': turn, 'status': 'completed'}}})
        continue
    if 'id' in m:
        out({'id': m['id'], 'result': r})
