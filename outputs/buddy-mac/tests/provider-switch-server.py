#!/usr/bin/env python3
"""Inert ChatGPT app-server fixture for "Switch all agents": a signed-in account and a model list, newest first. Nothing else."""
import json, sys
MODELS = [
    {'model': 'gpt-5.5-pro', 'displayName': 'GPT-5.5 Pro', 'defaultReasoningEffort': 'high'},
    {'model': 'gpt-5.5', 'displayName': 'GPT-5.5', 'isDefault': True, 'defaultReasoningEffort': 'medium'},
    {'model': 'gpt-5.5-mini', 'displayName': 'GPT-5.5 mini', 'defaultReasoningEffort': 'low'},
    {'model': 'gpt-5.4', 'displayName': 'GPT-5.4', 'defaultReasoningEffort': 'medium'},
]
for line in sys.stdin:
    m = json.loads(line); method = m.get('method')
    if not method or 'id' not in m: continue
    if method in ('thread/start', 'thread/resume', 'turn/start'): raise AssertionError('switching providers never starts a conversation: ' + method)
    if method == 'account/read': result = {'account': {'type': 'chatgpt', 'planType': 'fixture'}}
    elif method == 'config/read': result = {'config': {}}
    elif method == 'model/list': result = {'data': MODELS}
    elif method in ('app/installed', 'app/read'): result = {'apps': []}
    else: result = {}
    print(json.dumps({'id': m['id'], 'result': result}), flush=True)
