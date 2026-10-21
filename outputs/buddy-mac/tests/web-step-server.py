#!/usr/bin/env python3
"""Inert app-server fixture for tests/WebStep.swift: website tasks that ask the person for a step on a web page. A brief with
CHECKPOINT:<json> calls buddy_checkpoint with exactly those arguments and finishes the turn once the tool answers; a turn resumed after
the person's Done (its brief carries Buddy's note) and any other brief finish at once. Every turn's text and every tool result, with the
thread it belongs to, are written to BUDDY_STEP_SERVER_LOG."""
import sys,json,os
calls={};seq=0;log=os.environ.get('BUDDY_STEP_SERVER_LOG')
def out(x):print(json.dumps(x),flush=True)
def record(kind,value):
 if log:
  with open(log,'a') as f:f.write(json.dumps({'kind':kind,'value':value})+'\n')
def finish(tid,turn,text):
 out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':text}}})
 out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
def checkpoint(text):
 at=text.find('CHECKPOINT:')
 if at<0:return None
 value,_=json.JSONDecoder().raw_decode(text,at+len('CHECKPOINT:'))
 return value
for line in sys.stdin:
 m=json.loads(line);rid=m.get('id');method=m.get('method');p=m.get('params',{});result={}
 if not method:
  call=calls.pop(str(rid),None)
  if call:
   tid,turn,args=call;r=m.get('result',{})
   text=''.join(i.get('text','') for i in r.get('contentItems',[]))
   record('result',{'thread':tid,'arguments':args,'success':r.get('success'),'text':text})
   finish(tid,turn,'Waiting for the user.' if r.get('success') else 'Stopped: '+text[:300])
  continue
 if method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':result={'config':{}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method in ['app/installed','app/read']:result={'apps':[]}
 elif method in ['thread/start','thread/resume','thread/fork']:
  seq+=1;result={'thread':{'id':'thread-'+str(seq)}}
 elif method=='turn/start':
  seq+=1;tid=p['threadId'];turn='turn-'+str(seq);out({'id':rid,'result':{'turn':{'id':turn,'status':'inProgress'}}})
  text=' '.join(i.get('text','') for i in p.get('input',[]) if isinstance(i,dict))
  record('turn',{'thread':tid,'text':text[-6000:]})
  args=None if '[Buddy]' in text else checkpoint(text)
  if args is not None:
   call='call-'+str(seq);calls[call]=(tid,turn,args)
   out({'id':call,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':call,'tool':'buddy_checkpoint','arguments':args}})
  else:finish(tid,turn,'Continued after the step. No external account was changed.')
  continue
 elif method in ['turn/interrupt','thread/unsubscribe','thread/inject_items','initialize']:pass
 if rid is not None:out({'id':rid,'result':result})
