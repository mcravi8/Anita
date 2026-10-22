#!/usr/bin/env python3
"""Inert app-server fixture for tests/FolderAccessWorker.swift: background tasks whose file tools name a place on the Mac. A brief with
TOOL:<json> ({"tool": name, "arguments": {...}}) calls that tool and finishes the turn with what it answered. A turn resumed with Buddy's
note that the user allowed access calls it again; one told the user declined finishes at once. Every turn's text and every tool result are
written to BUDDY_ACCESS_SERVER_LOG."""
import sys,json,os
calls={};seq=0;log=os.environ.get('BUDDY_ACCESS_SERVER_LOG')
def out(x):print(json.dumps(x),flush=True)
def record(kind,value):
 if log:
  with open(log,'a') as f:f.write(json.dumps({'kind':kind,'value':value})+'\n')
def finish(tid,turn,text):
 out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':text}}})
 out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
def asked(text):
 at=text.find('TOOL:')
 if at<0:return None
 value,_=json.JSONDecoder().raw_decode(text,at+len('TOOL:'))
 return value
for line in sys.stdin:
 m=json.loads(line);rid=m.get('id');method=m.get('method');p=m.get('params',{});result={}
 if not method:
  call=calls.pop(str(rid),None)
  if call:
   tid,turn,tool=call;r=m.get('result',{})
   text=''.join(i.get('text','') for i in r.get('contentItems',[]))
   record('result',{'thread':tid,'tool':tool,'success':r.get('success'),'text':text})
   finish(tid,turn,('Done: ' if r.get('success') else 'Asked: ')+text[:300])
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
  tool=None if '[Buddy] The user declined' in text else asked(text)
  if tool is not None:
   call='call-'+str(seq);calls[call]=(tid,turn,tool.get('tool'))
   out({'id':call,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':call,'tool':tool.get('tool'),'arguments':tool.get('arguments',{})}})
  else:finish(tid,turn,'Worked without it.')
  continue
 elif method in ['turn/interrupt','thread/unsubscribe','thread/inject_items','initialize']:pass
 if rid is not None:out({'id':rid,'result':result})
