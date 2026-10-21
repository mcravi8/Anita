#!/usr/bin/env python3
"""Inert app-server fixture for tasks pinned to a Google account. A brief with BROWSE:<url> opens that page with buddy_browser and finishes
once the tool answers; any other brief finishes at once. Every turn's text and every tool result are written to BUDDY_PIN_SERVER_LOG."""
import sys,json,os,re
calls={};seq=0;log=os.environ.get('BUDDY_PIN_SERVER_LOG')
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
   record('result',{'success':r.get('success'),'text':''.join(i.get('text','') for i in r.get('contentItems',[]))})
   finish(tid,turn,'Opened the page. No external account was changed.')
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
  record('turn',{'text':text[-4000:]})
  found=re.search(r'BROWSE:(\S+)',text)
  if found:
   call='call-'+str(seq);calls[call]=(tid,turn)
   out({'id':call,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':call,'tool':'buddy_browser','arguments':{'operation':'open','url':found.group(1)}}})
  else:finish(tid,turn,'Done. No external account was changed.')
  continue
 elif method in ['turn/interrupt','thread/unsubscribe','thread/inject_items','initialize']:pass
 if rid is not None:out({'id':rid,'result':result})
