#!/usr/bin/env python3
"""Inert tool-free coordination adapter. No network, real keys or user data."""
import json,sys,time
from pathlib import Path
for line in sys.stdin:
 c=json.loads(line)
 if c.get('command')!='start':continue
 assert c['tools']==[]
 p=json.loads(c['prompt']);kind='memory' if 'changed' in c['outputSchema']['properties'] else 'overview' if 'reports' in p else 'checkin'
 folder=Path(c['cwd']).parent
 call={'kind':kind,'model':c['model'],'runId':c['runId']}
 if kind=='memory':
  props=c['outputSchema']['properties'];call['required']=c['outputSchema'].get('required');call['rewrites']='role' in props or 'instructions' in props
 with (folder/'fixture-calls.jsonl').open('a') as f:f.write(json.dumps(call)+'\n')
 # fixture-checkin-mode.txt = hang: a check-in never answers, so the monitor's own limits decide what happens to it.
 hang=folder/'fixture-checkin-mode.txt'
 if kind=='checkin' and hang.exists() and hang.read_text().strip()=='hang':continue
 if kind=='memory':
  messages=p['messages'];text=' '.join(m['text'] for m in messages)
  if 'SLOW' in text:time.sleep(2)
  # fixture-memory-mode.txt = no_rules: the learner says something changed but gives no sourced rule, which is rejected.
  mode=folder/'fixture-memory-mode.txt'
  if mode.exists() and mode.read_text().strip()=='no_rules':r={'changed':True,'rules':[]}
  else:
   changed=next((m for m in messages if 'concise' in m['text']),None)
   r={'changed':bool(changed),'rules':[{'messageId':changed['id'],'quote':'concise','instruction':'Keep answers concise.','replaces':[]}] if changed else []}
 elif kind=='checkin':
  sources=p.get('sources',[]);blocking=next((s for s in sources if s.get('status') in ['waiting_user','waiting_review','failed']),None);completed=next((s for s in sources if s.get('status')=='completed'),None);s=blocking or completed
  r={'notify':bool(s),'body':'I need your decision before continuing.' if blocking else 'The requested work finished.' if completed else '', 'priority':0 if blocking else 1,'sourceIds':[s['id']] if s else []}
  say=folder/'fixture-checkin-body.txt'
  if r['notify'] and say.exists():r['body']=say.read_text().strip()
 else:
  reports=p['reports'];chosen=[x for x in reports if x['report']['notify']]
  r={'notify':bool(chosen),'body':'**Maze needs you:** review the pending decision.' if chosen else '', 'priority':0 if any(x['report']['priority']==0 for x in chosen) else 1,'sourceIds':[x['sources'][0]['id'] if x.get('sources') else x['id'] for x in chosen]}
  say=folder/'fixture-overview-body.txt'
  if r['notify'] and say.exists():r['body']=say.read_text().strip()
 print(json.dumps({'type':'result','runId':c['runId'],'text':json.dumps(r),'cost':0.02}),flush=True)
