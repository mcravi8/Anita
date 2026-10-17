#!/usr/bin/env python3
"""Offline Claude bridge fixture: verifies explicit model and shared history."""
import json, sys, time
for line in sys.stdin:
    c = json.loads(line)
    assert c['apiKey']=='fixture-key'
    assert c['model'] in ['claude-sonnet-4-6','claude-other'], c['model']
    if 'PINNED_TURN' in c['prompt']:
        print(json.dumps({'type':'progress','runId':c['runId'],'text':'Fixture active'}),flush=True)
        time.sleep(1)
    text=json.dumps({'model':c['model'],'context':c['prompt']})
    print(json.dumps({'type':'result','runId':c['runId'],'text':text,'cost':0,'error':None}),flush=True)
