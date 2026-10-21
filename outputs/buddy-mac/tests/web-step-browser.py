#!/usr/bin/env python3
"""Stand-in for the one shared private browser (browser.mjs) with the same JSONL protocol, for tests/WebStep.swift. It logs every command
it gets with its session, scope, account, url, page and reload to BUDDY_STEP_BROWSER_LOG. Done's look at the page again answers that Buddy
can't tell, so the task simply continues. A download writes a PDF fixture where it is told, unless the address has captcha in it: then the
site sent a web page, and nothing is written."""
import sys,json,os,hashlib
log=os.environ.get('BUDDY_STEP_BROWSER_LOG');manual=False
def record(value):
 if log:
  with open(log,'a') as f:f.write(json.dumps(value)+'\n')
for line in sys.stdin:
 x=json.loads(line);command=x.get('command');result=None;error=None
 record({k:x.get(k) for k in ['command','session','scope','account','url','page','reload','to','expect']})
 if command=='recheck':result={'signedIn':False,'unknown':True}
 elif command in ['open','read']:result={'url':x.get('url') or 'https://iopscience.iop.org/','title':'Fixture','text':'Fixture page','controls':[],'snapshotId':'snapshot-1'}
 elif command in ['manual','manualGoogle']:manual=True;result={'opened':True,'private':True}
 elif command=='finishManual':manual=False;result={'closed':True,'url':None}
 elif command=='download':
  if 'captcha' in (x.get('url') or ''):error='The website sent a web page instead of the file, most likely a sign-in page or a CAPTCHA. Nothing was saved.'
  else:
   body=b'%PDF-1.7 fixture downloaded\n'
   with open(x['to'],'xb') as f:f.write(body)
   result={'saved':True,'bytes':len(body),'sha256':hashlib.sha256(body).hexdigest(),'contentType':'application/pdf','origin':'https://iopscience.iop.org'}
 elif command=='closeSession':result={'closed':True,'remaining':0}
 elif command=='sessions':result={'sessions':[],'pages':[],'manual':manual}
 elif command=='close':result={'closed':True}
 else:error='Unexpected browser fixture command: '+str(command)
 print(json.dumps({'id':x.get('id'),**({'error':error} if error else {'result':result})}),flush=True)
