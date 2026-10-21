#!/usr/bin/env python3
"""Stand-in for the one shared private browser (browser.mjs) with the same JSONL protocol, for tests/WebStep.swift. It logs every command
it gets with its session, scope, account, url, page and reload to BUDDY_STEP_BROWSER_LOG. Done's look at the page again answers that Buddy
can't tell, so the task simply continues."""
import sys,json,os
log=os.environ.get('BUDDY_STEP_BROWSER_LOG');manual=False
def record(value):
 if log:
  with open(log,'a') as f:f.write(json.dumps(value)+'\n')
for line in sys.stdin:
 x=json.loads(line);command=x.get('command');result=None;error=None
 record({k:x.get(k) for k in ['command','session','scope','account','url','page','reload']})
 if command=='recheck':result={'signedIn':False,'unknown':True}
 elif command in ['open','read']:result={'url':x.get('url') or 'https://iopscience.iop.org/','title':'Fixture','text':'Fixture page','controls':[],'snapshotId':'snapshot-1'}
 elif command in ['manual','manualGoogle']:manual=True;result={'opened':True,'private':True}
 elif command=='finishManual':manual=False;result={'closed':True,'url':None}
 elif command=='closeSession':result={'closed':True,'remaining':0}
 elif command=='sessions':result={'sessions':[],'pages':[],'manual':manual}
 elif command=='close':result={'closed':True}
 else:error='Unexpected browser fixture command: '+str(command)
 print(json.dumps({'id':x.get('id'),**({'error':error} if error else {'result':result})}),flush=True)
