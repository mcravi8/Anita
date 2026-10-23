#!/usr/bin/env python3
import sys,json
from pathlib import Path
calls={};seq=0
def out(x):print(json.dumps(x),flush=True)
def done(tid,turn):
 out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':'Private sign-in fixture checkpoint finished. No external account was created.'}}})
 out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
for line in sys.stdin:
 x=json.loads(line);rid=x.get('id');method=x.get('method');p=x.get('params',{});result={}
 if not method:
  if str(rid) in calls:
   tid,turn,kind=calls.pop(str(rid))
   if kind=='signin':Path('signin-stage').write_text('done')
   done(tid,turn)
  continue
 if method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':result={'config':{}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method=='app/installed':result={'apps':[]}
 elif method=='app/read':result={'apps':[]}
 elif method in ['thread/start','thread/resume','thread/fork']:
  if method=='thread/start':assert any(t['name']=='buddy_browser_signin' for t in p.get('dynamicTools',[]))
  seq+=1;result={'thread':{'id':'thread-'+str(seq)}}
 elif method=='turn/start':
  seq+=1;tid=p['threadId'];turn='turn-'+str(seq);out({'id':rid,'result':{'turn':{'id':turn,'status':'inProgress'}}})
  # A browser step on the deploy page: one the browser calls routine (a tab) and one it does not (Deploy).
  step='routine' if 'ROUTINE-CLICK' in json.dumps(p) else 'reviewed' if 'REVIEWED-CLICK' in json.dumps(p) else None
  if step:
   call='call-'+str(seq);calls[call]=(tid,turn,'act');out({'id':call,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':call,'tool':'buddy_browser','arguments':{'operation':'act','action':'click','snapshotId':'snapshot-1','ref':step}}})
  elif Path('signin-stage').exists():done(tid,turn)
  else:
   call='call-'+str(seq);calls[call]=(tid,turn,'signin');out({'id':call,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':call,'tool':'buddy_browser_signin','arguments':{'mode':'signin','reason':'Sign in to the inert fixture the user asked about.'}}})
  continue
 elif method in ['turn/interrupt','thread/unsubscribe','thread/inject_items','initialize']:pass
 if rid is not None:out({'id':rid,'result':result})
