#!/usr/bin/env python3
"""Stand-in for the one shared private browser (browser.mjs) with the same JSONL protocol. It logs every command it gets to
BUDDY_SHARED_BROWSER_LOG with its session, scope and token; a typed value is logged only as its SHA-256, never as written. The right
password is the one whose SHA-256 is BUDDY_SHARED_RIGHT_SHA256: anything else is "wrong" and the site asks again with a fresh token.
After the person's Chrome window, the first Done finds the site still signed out and the second finds it signed in."""
import sys,json,os,hashlib
log=os.environ.get('BUDDY_SHARED_BROWSER_LOG');right=os.environ.get('BUDDY_SHARED_RIGHT_SHA256','')
origin='https://shop.example';account='ada@example.com';n=0;tokens={};checks={};manual=False
def record(value):
 if log:
  with open(log,'a') as f:f.write(json.dumps(value)+'\n')
def token(kind):
 global n
 n+=1;return kind+'-'+str(n)
def page(text):return {'url':origin+'/account','title':'Fixture shop','text':text,'controls':[],'snapshotId':'snapshot-'+str(n)}
record({'command':'argv','argv':sys.argv[1:]})
for line in sys.stdin:
 x=json.loads(line);command=x.get('command');session=x.get('session');result=None;error=None
 entry={'command':command,'session':session,'scope':x.get('scope')}
 if 'token' in x:entry['token']=x['token']
 if 'value' in x:entry['valueSHA256']=hashlib.sha256(x['value'].encode()).hexdigest()
 if 'reload' in x:entry['reload']=x['reload']
 record(entry)
 if command in ['open','read']:result=page('Fixture shop')
 elif command=='prepareSignIn':result={'token':token('auth'),'origin':origin,'mode':x.get('mode'),'accountEmail':account,'filled':False,'googleAvailable':False,'private':True}
 elif command=='useSaved':result={'needsUser':True,'reason':'Chrome has not filled a saved login. Open privately to choose a saved account or unlock Password Manager.'}
 elif command=='secretPlan':
  t=token('secret');tokens[session]=t;result={'token':t,'origin':origin,'field':'password','account':account,'private':True}
 elif command=='fillSecret':
  if tokens.pop(session,None)!=x.get('token'):error='This sign-in request was already used or replaced. Nothing was typed.'
  elif entry['valueSHA256']==right:result={'signedIn':True,'performed':True,'page':page('Signed in fixture: your orders')}
  else:
   t=token('secret');tokens[session]=t;result={'signedIn':False,'next':{'token':t,'field':'password','origin':origin,'account':account},'kind':'signin'}
 elif command=='recheck':
  checks[session]=checks.get(session,0)+1
  if checks[session]>=2:result={'signedIn':True,'performed':True,'page':page('Signed in fixture: your orders')}
  else:result={'signedIn':False,'next':None,'waiting':True,'kind':'signin'}
 elif command in ['manual','manualGoogle']:manual=True;result={'opened':True,'private':True}
 elif command=='finishManual':manual=False;result={'closed':True,'url':origin}
 elif command=='closeSession':tokens.pop(session,None);result={'closed':True,'remaining':0}
 elif command=='sessions':result={'sessions':[],'pages':[],'manual':manual}
 elif command=='close':result={'closed':True}
 else:error='Unexpected shared browser fixture command: '+str(command)
 print(json.dumps({'id':x.get('id'),**({'error':error} if error else {'result':result})}),flush=True)
