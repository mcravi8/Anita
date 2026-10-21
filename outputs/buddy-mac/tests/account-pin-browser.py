#!/usr/bin/env python3
"""Stand-in for the one shared private browser (browser.mjs) with the same JSONL protocol. It logs every command with its session, scope and
account to BUDDY_PIN_BROWSER_LOG. Opening a page whose address contains NOT_SIGNED_IN answers as browser.mjs does when Google's account
chooser does not offer the task's account."""
import sys,json,os
log=os.environ.get('BUDDY_PIN_BROWSER_LOG');manual=False;sessions={}
def record(value):
 if log:
  with open(log,'a') as f:f.write(json.dumps(value)+'\n')
for line in sys.stdin:
 x=json.loads(line);command=x.get('command');session=x.get('session');account=x.get('account');result=None;error=None
 record({'command':command,'session':session,'scope':x.get('scope'),'account':account,'url':x.get('url')})
 if command in ['open','read','recheck']:
  if session in sessions and sessions[session]!=(account or ''):error='This browser session keeps the account it was opened with.'
  else:
   sessions.setdefault(session,account or '')
   if command=='open' and 'NOT_SIGNED_IN' in (x.get('url') or ''):error=f'{account} isn’t signed in to Buddy’s Chrome. Sign in to {account} in Buddy’s Chrome, then press Done.'
   elif command=='recheck':result={'signedIn':False,'unknown':True}
   else:result={'url':x.get('url') or 'https://mail.google.com/mail/','title':'Inbox','text':'Mail for '+(account or 'the default account'),'controls':[],'snapshotId':'snapshot-1'}
 elif command in ['manual','manualGoogle']:manual=True;result={'opened':True,'private':True}
 elif command=='finishManual':manual=False;result={'closed':True,'url':None}
 elif command=='closeSession':sessions.pop(session,None);result={'closed':True,'remaining':len(sessions)}
 elif command=='sessions':result={'sessions':list(sessions),'pages':[],'manual':manual}
 elif command=='close':result={'closed':True}
 else:error='Unexpected browser fixture command: '+str(command)
 print(json.dumps({'id':x.get('id'),**({'error':error} if error else {'result':result})}),flush=True)
