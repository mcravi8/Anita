#!/usr/bin/env python3
"""Inert app-server fixture for a background task. Writes only a local Buddy file tool."""
import sys,json
threads={};calls={};seq=0

def out(x):print(json.dumps(x),flush=True)
def notice(m,p):out({'method':m,'params':p})
def finish(tid,turn):
 notice('item/completed',{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':'Saved a private fixture report. No external actions were performed.'}})
 notice('turn/completed',{'threadId':tid,'turn':{'id':turn,'status':'completed'}})
for line in sys.stdin:
 m=json.loads(line);method=m.get('method');p=m.get('params',{});result={}
 if not method:
  call=calls.pop(str(m.get('id')),None)
  if call:
   assert m.get('result',{}).get('success'),m
   finish(*call)
  continue
 if method=='initialize':pass
 elif method=='config/read':result={'config':{}}
 elif method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method=='app/installed':result={'apps':[{'id':'offline','runtimeName':'Offline fixture service','enabled':True,'callable':not bool(p.get('threadId'))}]}
 elif method=='app/read':result={'apps':[{'id':'offline','name':'Offline fixture service','toolSummaries':[{'name':'read_fixture','isReadOnly':True,'isEnabled':True}]}]}
 elif method in ['thread/start','thread/fork','thread/resume']:
  seq+=1;tid='thread-'+str(seq);threads[tid]=p;result={'thread':{'id':tid}}
  assert any(t['name']=='buddy_browser' for t in p.get('dynamicTools',[]))
 elif method in ['thread/inject_items','thread/unsubscribe']:pass
 elif method=='turn/start':
  tid=p['threadId'];seq+=1;turn='turn-'+str(seq);result={'turn':{'id':turn,'status':'inProgress'}}
  out({'id':m['id'],'result':result});rid='call-'+str(seq);calls[rid]=(tid,turn)
  out({'id':rid,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':rid,'tool':'buddy_write_file','arguments':{'path':'fixture.md','content':'# Background result\n\nPrivate and durable.','expectedVersion':''}}});continue
 elif method=='turn/interrupt':pass
 else:out({'id':m.get('id'),'error':{'code':-32601,'message':'Unexpected '+str(method)}});continue
 if 'id' in m:out({'id':m['id'],'result':result})
