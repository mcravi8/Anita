#!/usr/bin/env python3
"""Inert ChatGPT auth/conversation adapter; logout is intentionally forbidden."""
import json,sys
seq=0;calls={}

def out(x):print(json.dumps(x),flush=True)
def finish(tid,turn):
 out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':'ChatGPT fixture answer'}}})
 out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
for line in sys.stdin:
 m=json.loads(line);p=m.get('params',{});method=m.get('method');r={}
 if not method:
  call=calls.pop(str(m.get('id')),None)
  if call:
   assert m.get('result',{}).get('success'),m
   finish(*call)
  continue
 if method=='account/logout':raise AssertionError('Buddy disconnect must not sign out shared ChatGPT credentials')
 if method=='account/read':r={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':r={'config':{}}
 elif method=='model/list':r={'data':[{'model':'fixture','isDefault':True}]}
 elif method in ['app/installed','app/read']:r={'apps':[]}
 elif method in ['thread/start','thread/fork','thread/resume']:
  seq+=1;r={'thread':{'id':'thread-'+str(seq)}}
 elif method=='turn/start':
  seq+=1;turn='turn-'+str(seq);tid=p['threadId'];out({'id':m['id'],'result':{'turn':{'id':turn,'status':'inProgress'}}})
  if 'SAVE_PROACTIVE' in str(p.get('input')):
   rid='proactive-'+str(seq);calls[rid]=(tid,turn)
   out({'id':rid,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':rid,'tool':'buddy_team','arguments':{'action':'set_proactive','enabled':True,'quote':'Keep me updated.'}}})
  else:finish(tid,turn)
  continue
 elif method not in ['initialize','initialized','thread/inject_items','thread/unsubscribe','turn/interrupt']:raise AssertionError(method)
 if 'id' in m:out({'id':m['id'],'result':r})
