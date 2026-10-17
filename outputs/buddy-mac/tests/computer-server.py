#!/usr/bin/env python3
"""Inert desktop protocol fixture. No apps or network are operated."""
import json,sys
from pathlib import Path
threads={};calls={};permissions={};seq=0;state='0 window Calculator\n1 button Two\n2 text Result: 0'
def out(x):print(json.dumps(x),flush=True)
def notice(method,params):out({'method':method,'params':params})
def finish(tid,turn,status='completed'):
 notice('item/completed',{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':'Fixture finished.'}})
 notice('turn/completed',{'threadId':tid,'turn':{'id':turn,'status':status}})
def dynamic(tid,turn,mode,step,snapshot=None):
 global seq
 seq+=1;rid='tool-'+str(seq);tool=['buddy_desktop_apps','buddy_desktop_observe','buddy_desktop_act'][step]
 args=[{}, {'appId':'com.apple.calculator'}, {'action':'click','element':1,'snapshotId':snapshot}][step]
 calls[rid]=(tid,turn,mode,step)
 out({'id':rid,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':rid,'tool':tool,'arguments':args}})
for line in sys.stdin:
 m=json.loads(line);method=m.get('method');p=m.get('params',{});result={}
 if not method:
  permission=permissions.pop(str(m.get('id')),None)
  if permission:
   original,tid=permission
   accepted=m.get('result',{}).get('action')=='accept'
   out({'id':original,'result':{'content':[{'type':'text','text':state if accepted else 'App access denied'}],'isError':not accepted}})
   continue
  call=calls.pop(str(m.get('id')),None)
  if not call:continue
  tid,turn,mode,step=call;r=m.get('result',{})
  notice('item/completed',{'threadId':tid,'turnId':turn,'item':{'type':'dynamicToolCall','id':'item-'+str(m['id']),'tool':['buddy_desktop_apps','buddy_desktop_observe','buddy_desktop_act'][step],'success':r.get('success')}})
  if not r.get('success') or step==2:finish(tid,turn);continue
  snapshot=None
  if step==1:
   text=r['contentItems'][0]['text'];snapshot=text.split('Fresh snapshotId: ')[1].split('\n')[0]
  dynamic(tid,turn,mode,step+1,snapshot);continue
 if method=='initialize':pass
 elif method=='config/read':result={'config':{}}
 elif method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method in ['app/installed','app/read']:result={'apps':[]}
 elif method in ['thread/start','thread/fork','thread/resume']:
  seq+=1;tid='thread-'+str(seq);threads[tid]=p;result={'thread':{'id':tid}}
 elif method=='mcpServerStatus/list':result={'data':[{'name':'cua_repl','pluginId':'unified-computer-use@openai-bundled','runtimeStatus':'connected','tools':{'js':{},'js_reset':{}}}], 'nextCursor':None}
 elif method=='mcpServer/tool/call':
  code=p['arguments']['code'];tid=p['threadId']
  if code=='await cua.getState();':text='## Computer Use\nFixture docs'
  elif 'cua.listApps' in code:text='{"apps":[{"id":"com.apple.calculator","name":"Calculator"}]}'
  else:
   if 'cua.getApp' in code:
    seq+=1;rid='permission-'+str(seq);permissions[rid]=(m['id'],tid)
    out({'id':rid,'method':'mcpServer/elicitation/request','params':{'threadId':tid,'turnId':None,'serverName':'cua_repl','mode':'form','message':'Allow Computer Use to use "Calculator"?','requestedSchema':{'type':'object','properties':{}},'_meta':{'connector_id':'computer-use','tool_name':'get_app_state','tool_params':{'app':'com.apple.calculator'},'tool_params_display':[{'name':'app','value':'Calculator'}]}}})
    continue
   if code.startswith('await buddyComputerApp.click'):
    receipt=Path(threads[tid]['cwd'])/'desktop-effects.jsonl'
    with receipt.open('a') as f:f.write('{"operation":"click"}\n')
   text=state
  result={'content':[{'type':'text','text':text}],'isError':False}
 elif method in ['thread/inject_items','thread/unsubscribe']:pass
 elif method=='turn/start':
  tid=p['threadId'];seq+=1;turn='turn-'+str(seq);mode=p['input'][0]['text'];result={'turn':{'id':turn,'status':'inProgress'}}
  dynamic(tid,turn,mode,0) # deliberately arrives before turn/start response
 elif method=='turn/interrupt':
  out({'id':m['id'],'result':{}});finish(p['threadId'],p['turnId'],'interrupted');continue
 else:
  out({'id':m.get('id'),'error':{'code':-32601,'message':'Unexpected fixture request: '+str(method)}});continue
 if 'id' in m:out({'id':m['id'],'result':result})
