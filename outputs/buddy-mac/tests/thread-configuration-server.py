#!/usr/bin/env python3
"""Offline app-server fixture for the fixed text Buddy sends each turn. Every reply reports what the thread was given since its last turn:
how it was opened, its developer instructions and config, the developer items injected into it, and this process's own arguments. A
request containing COMPACT_NOW compacts the thread first, as Codex does when a conversation outgrows the model's context."""
import json, sys, uuid
seq = 0
threads = {}
def out(value): print(json.dumps(value), flush=True)
for line in sys.stdin:
    m = json.loads(line); p = m.get('params', {}); method = m.get('method'); result = {}
    if not method: continue
    if method == 'account/read': result = {'account': {'type': 'chatgpt', 'planType': 'fixture'}}
    elif method == 'config/read': result = {'config': {}}
    elif method == 'model/list': result = {'data': [{'model': 'gpt-fixture', 'displayName': 'GPT Fixture', 'isDefault': True, 'defaultReasoningEffort': 'medium'}]}
    elif method in ['app/installed', 'app/read']: result = {'apps': []}
    elif method in ['thread/start', 'thread/fork']:
        tid = 'thread-' + uuid.uuid4().hex[:8]
        threads[tid] = {'opened': method.split('/')[1], 'params': p, 'injected': []}
        result = {'thread': {'id': tid}}
    elif method == 'thread/resume':
        # A thread from before a restart is loaded from its saved history, as Codex does.
        tid = p['threadId']; threads.setdefault(tid, {'injected': []}).update({'opened': 'resume', 'params': p})
        result = {'thread': {'id': tid}}
    elif method == 'thread/inject_items':
        for item in p['items']:
            assert item['type'] == 'message' and item['role'] == 'developer', item
            threads[p['threadId']]['injected'] += [c['text'] for c in item['content']]
    elif method == 'turn/start':
        seq += 1; tid = p['threadId']; turn = 'turn-' + str(seq); thread = threads[tid]
        text = '\n'.join(x.get('text', '') for x in p['input'])
        report = {'thread': tid, 'opened': thread['opened'], 'injected': thread['injected'], 'argv': sys.argv[1:],
                  'developerInstructions': thread['params'].get('developerInstructions', ''), 'config': thread['params'].get('config', {}), 'ephemeral': thread['params'].get('ephemeral', False)}
        thread['injected'] = []
        out({'id': m['id'], 'result': {'turn': {'id': turn, 'status': 'inProgress'}}})
        if 'COMPACT_NOW' in text:
            out({'method': 'item/started', 'params': {'threadId': tid, 'turnId': turn, 'item': {'type': 'contextCompaction', 'id': 'compact-' + turn}}})
            out({'method': 'item/completed', 'params': {'threadId': tid, 'turnId': turn, 'item': {'type': 'contextCompaction', 'id': 'compact-' + turn}}})
        out({'method': 'item/completed', 'params': {'threadId': tid, 'turnId': turn, 'item': {'type': 'agentMessage', 'id': 'answer-' + turn, 'phase': 'final_answer', 'text': json.dumps(report)}}})
        out({'method': 'turn/completed', 'params': {'threadId': tid, 'turn': {'id': turn, 'status': 'completed'}}}); continue
    elif method not in ['initialize', 'initialized', 'thread/unsubscribe', 'turn/interrupt', 'thread/archive', 'thread/unarchive']:
        raise AssertionError(method)
    if 'id' in m: out({'id': m['id'], 'result': result})
