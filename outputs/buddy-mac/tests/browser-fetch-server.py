#!/usr/bin/env python3
"""Inert stand-in for `codex app-server` for tests/BrowserFetch.swift: a website task's ChatGPT conversation and a coding task's Codex thread
alike. A brief with CALLS:<json list of [tool, arguments]> makes those Buddy tool calls one after another: the next one only after the
previous was refused, and it stops at the first one that is not. In a coding thread (sandbox workspace-write, cwd its project copy), a file
a fetch saved is then read from the project with the thread's own file access, and what it holds is logged. A turn resumed with Buddy's
note reads the file the note names. Every turn, tool result and read goes to BUDDY_FETCH_SERVER_LOG. No network and no model."""
import sys,json,os,re
LOG=os.environ.get('BUDDY_FETCH_SERVER_LOG');threads={};pending={};seq=0
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
def read(tid,path):
 cwd=threads.get(tid,{}).get('cwd')
 if not cwd or not threads[tid].get('coding'):return None
 try:
  with open(os.path.join(cwd,path),'rb') as f:return f.read().decode('latin1')
 except OSError as e:return 'unreadable: '+str(e)
def call(tid,turn,queue):
 if not queue:finish(tid,turn,'Nothing left to try.');return
 tool,args=queue.pop(0);cid='call-%d'%nxt();pending[cid]=(tid,turn,queue,tool,args)
 out({'id':cid,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':cid,'tool':tool,'arguments':args}})
for line in sys.stdin:
 m=json.loads(line);rid=m.get('id');method=m.get('method');p=m.get('params',{});result={}
 if not method:
  waiting=pending.pop(str(rid),None)
  if waiting:
   tid,turn,queue,tool,args=waiting;r=m.get('result',{})
   text=''.join(i.get('text','') for i in r.get('contentItems',[]))
   record('result',{'thread':tid,'tool':tool,'arguments':args,'success':r.get('success'),'text':text})
   try:value=json.loads(text)
   except ValueError:value={}
   if not r.get('success'):call(tid,turn,queue)
   elif value.get('saved') and threads.get(tid,{}).get('coding'):
    record('read',{'thread':tid,'path':value.get('path'),'content':read(tid,value.get('path') or '')});finish(tid,turn,'Read '+str(value.get('path')))
   else:finish(tid,turn,'Waiting for the user.' if value.get('paused') else 'Done.')
  continue
 if method=='initialize':result={'userAgent':'browser-fetch-fixture'}
 elif method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':result={'config':{}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method=='account/rateLimits/read':result={'rateLimits':{}}
 elif method in ['app/installed','app/read']:result={'apps':[]}
 elif method in ['thread/start','thread/resume','thread/fork']:
  tid=p.get('threadId') if method=='thread/resume' else 'thread-%d'%nxt()
  threads[tid]={'cwd':p.get('cwd'),'coding':p.get('sandbox')=='workspace-write' or threads.get(tid,{}).get('coding',False)}
  if method=='thread/start':record('start',{'thread':tid,'coding':threads[tid]['coding'],'tools':[t.get('name') for t in p.get('dynamicTools') or []],'instructions':p.get('developerInstructions') or ''})
  result={'thread':{'id':tid}}
 elif method=='turn/start':
  tid=p['threadId'];turn='turn-%d'%nxt();out({'id':rid,'result':{'turn':{'id':turn,'status':'inProgress'}}})
  text=' '.join(i.get('text','') for i in p.get('input',[]) if isinstance(i,dict))
  record('turn',{'thread':tid,'text':text[-6000:]})
  if '[Buddy]' in text:
   named=re.search(r'in your project at (\S+) \(',text)
   if named:record('read',{'thread':tid,'path':named.group(1),'content':read(tid,named.group(1))})
   finish(tid,turn,'Continued with the saved file.' if named else 'Continued.');continue
  at=text.find('CALLS:')
  if at<0:finish(tid,turn,'Nothing to do.');continue
  calls,_=json.JSONDecoder().raw_decode(text,at+len('CALLS:'))
  call(tid,turn,[(c[0],c[1]) for c in calls]);continue
 elif method in ['turn/interrupt','thread/unsubscribe','thread/inject_items']:pass
 if rid is not None:out({'id':rid,'result':result})
