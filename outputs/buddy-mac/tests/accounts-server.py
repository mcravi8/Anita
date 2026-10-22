#!/usr/bin/env python3
"""Inert stand-in for `codex app-server` for tests/WebsiteAccounts.swift: a website task's ChatGPT conversation. A brief with CALLS:<json list of
[tool, arguments]> makes those Buddy tool calls one after another, whatever each returns, and the turn ends after the last one or as soon as a
result says paused. A turn resumed with Buddy's note ([Buddy] …) makes the RESUME_CALLS:<json list> the brief names, if any. Every turn and
tool result goes to BUDDY_ACCOUNTS_SERVER_LOG. No network and no model."""
import sys,json,os
LOG=os.environ.get('BUDDY_ACCOUNTS_SERVER_LOG');pending={};seq=0
def out(x):print(json.dumps(x),flush=True)
def record(kind,value):
 if LOG:
  with open(LOG,'a') as f:f.write(json.dumps({'kind':kind,'value':value})+'\n')
def nxt():
 global seq
 seq+=1;return seq
def finish(tid,turn,text):
 out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':text}}})
 out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
def call(tid,turn,queue):
 if not queue:finish(tid,turn,'Done.');return
 tool,args=queue.pop(0);cid='call-%d'%nxt();pending[cid]=(tid,turn,queue,tool)
 out({'id':cid,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':cid,'tool':tool,'arguments':args}})
def calls(text,marker):
 at=text.find(marker)
 if at<0:return None
 found,_=json.JSONDecoder().raw_decode(text,at+len(marker));return [(c[0],c[1]) for c in found]
for line in sys.stdin:
 m=json.loads(line);rid=m.get('id');method=m.get('method');p=m.get('params',{});result={}
 if not method:
  waiting=pending.pop(str(rid),None)
  if waiting:
   tid,turn,queue,tool=waiting;r=m.get('result',{})
   text=''.join(i.get('text','') for i in r.get('contentItems',[]))
   record('result',{'thread':tid,'tool':tool,'success':r.get('success'),'text':text})
   try:value=json.loads(text)
   except ValueError:value={}
   if isinstance(value,dict) and value.get('paused'):finish(tid,turn,'Waiting for the user.')
   else:call(tid,turn,queue)
  continue
 if method=='initialize':result={'userAgent':'accounts-fixture'}
 elif method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':result={'config':{}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method=='account/rateLimits/read':result={'rateLimits':{}}
 elif method in ['app/installed','app/read']:result={'apps':[]}
 elif method in ['thread/start','thread/resume','thread/fork']:
  tid=p.get('threadId') if method=='thread/resume' else 'thread-%d'%nxt()
  if method=='thread/start':record('start',{'thread':tid,'tools':[t.get('name') for t in p.get('dynamicTools') or []],'instructions':p.get('developerInstructions') or ''})
  result={'thread':{'id':tid}}
 elif method=='turn/start':
  tid=p['threadId'];turn='turn-%d'%nxt();out({'id':rid,'result':{'turn':{'id':turn,'status':'inProgress'}}})
  text=' '.join(i.get('text','') for i in p.get('input',[]) if isinstance(i,dict))
  record('turn',{'thread':tid,'text':text[-6000:]})
  queue=calls(text,'RESUME_CALLS:') if '[Buddy]' in text else calls(text,'CALLS:')
  if queue is None:finish(tid,turn,'Continued.' if '[Buddy]' in text else 'Nothing to do.');continue
  call(tid,turn,queue);continue
 elif method in ['turn/interrupt','thread/unsubscribe','thread/inject_items']:pass
 if rid is not None:out({'id':rid,'result':result})
