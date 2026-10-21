#!/usr/bin/env python3
"""Inert app-server fixture for website tasks that need the person to sign in. TYPED_SIGNIN and CHROME_STEP ask for the sign-in with
buddy_browser_signin and finish once the tool answers; a turn that was resumed after the person's Done (its brief carries Buddy's note)
and any other brief finish at once. Every tool result is written to BUDDY_SHARED_SERVER_LOG, so the test can check what the model was told."""
import sys,json,os
calls={};seq=0;log=os.environ.get('BUDDY_SHARED_SERVER_LOG')
def out(x):print(json.dumps(x),flush=True)
def record(kind,value):
 if log:
  with open(log,'a') as f:f.write(json.dumps({'kind':kind,'value':value})+'\n')
def finish(tid,turn,text):
 out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':text}}})
 out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
for line in sys.stdin:
 m=json.loads(line);rid=m.get('id');method=m.get('method');p=m.get('params',{});result={}
 if not method:
  call=calls.pop(str(rid),None)
  if call:
   tid,turn=call;r=m.get('result',{})
   record('result',{'tool':'buddy_browser_signin','success':r.get('success'),'text':''.join(i.get('text','') for i in r.get('contentItems',[]))})
   finish(tid,turn,'The sign-in step is done or waiting for the user. No external account was changed.')
  continue
 if method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':result={'config':{}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method in ['app/installed','app/read']:result={'apps':[]}
 elif method in ['thread/start','thread/resume','thread/fork']:
  if method=='thread/start':assert any(t['name']=='buddy_browser_signin' for t in p.get('dynamicTools',[]))
  seq+=1;result={'thread':{'id':'thread-'+str(seq)}}
 elif method=='turn/start':
  seq+=1;tid=p['threadId'];turn='turn-'+str(seq);out({'id':rid,'result':{'turn':{'id':turn,'status':'inProgress'}}})
  text=' '.join(i.get('text','') for i in p.get('input',[]) if isinstance(i,dict))
  record('turn',{'text':text[-3000:]})
  if ('TYPED_SIGNIN' in text or 'CHROME_STEP' in text) and 'finished the sign-in step' not in text:
   call='call-'+str(seq);calls[call]=(tid,turn)
   out({'id':call,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':call,'tool':'buddy_browser_signin','arguments':{'mode':'signin','reason':'Sign in to the fixture shop to read the order.'}}})
  else:finish(tid,turn,'Continued after the sign-in. No external account was changed.')
  continue
 elif method in ['turn/interrupt','thread/unsubscribe','thread/inject_items','initialize']:pass
 if rid is not None:out({'id':rid,'result':result})
