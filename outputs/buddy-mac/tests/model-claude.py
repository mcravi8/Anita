#!/usr/bin/env python3
"""Offline Claude bridge fixture: verifies explicit model and shared history."""
import json, sys, time
for line in sys.stdin:
    c = json.loads(line)
    assert c['apiKey']=='fixture-key'
    assert c['model'] in ['claude-sonnet-4-6','claude-other'], c['model']
    assert 'Selected model: '+c['model'] in c['instructions']
    assert 'Buddy provides buddy_coding_session' in c['instructions']
    if 'PINNED_TURN' in c['prompt']:
        print(json.dumps({'type':'progress','runId':c['runId'],'text':'Fixture active'}),flush=True)
        time.sleep(1)
    text=json.dumps({'model':c['model'],'context':c['prompt']})
    if 'DELEGATE_CHECK' in c['prompt']:
        print(json.dumps({'type':'call','runId':c['runId'],'id':'delegate','tool':'buddy_connected_services','arguments':{'request':'Fixture lookup only; no external effects.'}}),flush=True)
        response=json.loads(sys.stdin.readline())['result']
        text=json.dumps({'model':c['model'],'context':c['prompt'],'delegate':response})
    print(json.dumps({'type':'result','runId':c['runId'],'text':text,'cost':0,'error':None}),flush=True)
