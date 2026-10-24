#!/usr/bin/env python3
"""Offline app-server fixture: reports actual model, thread and migrated context."""
import json, sys
seq = 0
runtime = {}
def out(value): print(json.dumps(value), flush=True)
for line in sys.stdin:
    m = json.loads(line); p = m.get('params', {}); method = m.get('method'); result = {}
    if not method: continue
    if method == 'account/read': result = {'account': {'type': 'chatgpt', 'planType': 'fixture'}}
    elif method == 'config/read': result = {'config': {}}
    elif method == 'model/list':
        if p.get('cursor') == 'page-2':
            result = {'data': [{'model':'gpt-beta','displayName':'GPT Beta','defaultReasoningEffort':'low'}]}
        else:
            result = {'data': [{'model':'gpt-alpha','displayName':'GPT Alpha','isDefault':True,'defaultReasoningEffort':'medium'}, {'model':'hidden-model','hidden':True}], 'nextCursor':'page-2'}
    elif method in ['app/installed', 'app/read']: result = {'apps': []}
    elif method in ['thread/start','thread/fork']:
        seq += 1; result = {'thread': {'id': 'thread-'+str(seq)}}
    elif method == 'thread/resume': result = {'thread': {'id': p['threadId']}}
    elif method == 'thread/inject_items':
        runtime[p['threadId']] = json.dumps(p['items'])
    elif method == 'turn/start':
        assert p['model'] in ['gpt-alpha','gpt-beta'], p
        assert 'Selected model: '+p['model'] in runtime.get(p['threadId'],''), runtime
        assert 'Buddy provides buddy_coding_session' in runtime.get(p['threadId'],''), runtime
        assert 'search_service_web_run' not in runtime.get(p['threadId'],''), 'no web search connected, so none is named'
        assert p['effort'] == ('medium' if p['model']=='gpt-alpha' else 'low'), p
        seq += 1; turn='turn-'+str(seq); tid=p['threadId']
        result = {'model':p['model'], 'thread':tid, 'context':'\n'.join(x.get('text','') for x in p['input'])}
        out({'id':m['id'],'result':{'turn':{'id':turn,'status':'inProgress'}}})
        out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':json.dumps(result)}}})
        out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}}); continue
    elif method not in ['initialize','initialized','thread/inject_items','thread/unsubscribe','turn/interrupt','thread/archive','thread/unarchive']:
        raise AssertionError(method)
    if 'id' in m: out({'id':m['id'],'result':result})
