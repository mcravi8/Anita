#!/usr/bin/env python3
"""Protocol fixture. Effects only append a local test receipt; no network or email."""
import sys,json
from pathlib import Path
threads={};reviews={};n=0
mail={'id':'mail','enabled':True,'callable':True,'runtimeName':'Gmail'}
def out(obj): print(json.dumps(obj),flush=True)
def notice(method,params): out({'method':method,'params':params})
def finish(tid,turn,text,status='completed'):
 notice('item/completed',{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':text}})
 notice('turn/completed',{'threadId':tid,'turn':{'id':turn,'status':status}})
def tool(tid,turn,status,error=None):
 return {'threadId':tid,'turnId':turn,'item':{'id':'effect-'+turn,'type':'mcpToolCall','server':'mail','tool':'send_email','arguments':{'to':'test@example.invalid','subject':'Test reply','body':'Fixture only.'},'appContext':{'connectorId':'mail','appName':'Gmail'},'status':status,'error':{'message':error} if error else None,'result':{'content':[],'structuredContent':{'messageId':'local-test-'+turn}} if status=='completed' else None}}
def formtool(tid,turn,status,error=None):
 completed=tool(tid,turn,status,error);item=completed['item']
 item['connectorId']='mail';item['appName']='Gmail';item.pop('appContext');item['tool']='gmail.send_email';item['server']='codex_apps'
 item['arguments'].pop('body');item['arguments']['payload']={'mime_type':'text/html','body':{'content':'<p>Hello,</p><p>This is an isolated review check. No email will be sent.</p>'}}
 return completed
for line in sys.stdin:
 m=json.loads(line);method=m.get('method');p=m.get('params',{});result={}
 if not method:
  r=reviews.pop(str(m.get('id')),None)
  if not r:continue
  tid,turn,mode=r
  form=mode.startswith('form-')
  if form:
   response=m.get('result',{})
   assert response.get('action') in ['accept','decline','cancel'] and 'answers' not in response
   accepted=response.get('action')=='accept'
   assert response.get('content')==({} if accepted else None)
  else:
   answer=m.get('result',{}).get('answers',{}).get('approve',{}).get('answers',[])
   accepted=answer==['Accept']
  if accepted:
   receipt=Path(threads[tid]['cwd'])/'fixture-effects.jsonl'
   with receipt.open('a') as f:f.write(json.dumps({'turn':turn,'to':'test@example.invalid'})+'\n')
  if mode in ['uncertain','form-uncertain'] and accepted:continue
  completed=(formtool if form else tool)(tid,turn,'completed' if accepted else 'failed',None if accepted else 'User declined or cancelled')
  if form:
   item=completed['item']
   if mode=='form-mismatch':item['arguments']['to']='different@example.invalid'
  notice('item/completed',completed)
  finish(tid,turn,'Test action confirmed.' if accepted else 'No action was taken.')
  continue
 if method=='initialize': result={'userAgent':'Buddy test fixture'}
 elif method=='config/read':result={'config':{}}
 elif method=='account/read':result={'account':{'type':'chatgpt','planType':'test'}}
 elif method=='model/list':result={'data':[{'model':'test-fixture','isDefault':True}]}
 elif method=='app/installed':
  enabled=threads.get(p.get('threadId'),{}).get('config',{}).get('apps',{}).get('mail',{}).get('enabled',True)
  result={'apps':[{**mail,'callable':enabled}]}
 elif method=='app/read':result={'apps':[{'id':'mail','name':'Gmail','toolSummaries':[{'name':'search_emails','isReadOnly':True,'isEnabled':True},{'name':'send_email','isReadOnly':False,'isEnabled':True},{'name':'disabled','isReadOnly':False,'isEnabled':False}]}]}
 elif method in ['thread/start','thread/fork','thread/resume']:
  n+=1;tid='thread-'+str(n);threads[tid]=p
  policy=p['config']['apps']['mail']
  if policy['enabled']:
   assert policy['tools']['send_email']=={'enabled':True,'approval_mode':'prompt'}
   assert not policy['tools']['disabled']['enabled']
  result={'thread':{'id':tid}}
 elif method=='thread/inject_items':pass
 elif method=='thread/unsubscribe':pass
 elif method=='turn/start':
  tid=p['threadId'];n+=1;turn='turn-'+str(n);mode=p['input'][0]['text'];result={'turn':{'id':turn,'status':'inProgress'}}
  if not threads[tid]['config']['apps']['mail']['enabled']:
   out({'id':m['id'],'result':result});finish(tid,turn,'Connection access is removed.');continue
  notice('item/started',tool(tid,turn,'inProgress'))
  rid='review-'+turn;reviews[rid]=(tid,turn,mode)
  if mode.startswith('form-'):
   params={'threadId':tid,'turnId':'old-turn' if mode=='form-stale' else turn,'serverName':'codex_apps','mode':'url' if mode=='form-url' else 'form','message':'Allow Gmail to send an email?','requestedSchema':{'type':'object','properties':{'password':{'type':'string'}} if mode=='form-secret' else {}},'_meta':{'codex_approval_kind':'mcp_tool_call','source':'connector','connector_id':'not-allowed' if mode=='form-wrong-connection' else 'mail','connector_name':'Gmail','tool_title':'disabled' if mode=='form-disabled-tool' else 'send_email','tool_params':{**formtool(tid,turn,'inProgress')['item']['arguments'],'cc':'','bcc':'','reply_message_id':None}}}
   out({'id':rid,'method':'mcpServer/elicitation/request','params':params})
   if mode=='form-duplicate':out({'id':rid,'method':'mcpServer/elicitation/request','params':params})
   if mode=='form-expired':
    reviews.pop(rid,None)
    notice('serverRequest/resolved',{'threadId':tid,'requestId':rid})
    completed=formtool(tid,turn,'failed','Review timed out')
    notice('item/completed',completed);finish(tid,turn,'Review expired. No action was taken.')
  else:
   params={'threadId':tid,'turnId':'old-turn' if mode=='stale' else turn,'itemId':'effect-'+turn,'isBlocking':True,'questions':[{'id':'approve','header':'Send email','question':'Send this test reply to test@example.invalid?','isOther':False,'isSecret':mode=='secret','options':[{'label':'Accept','description':'Send the reviewed reply.'},{'label':'Decline','description':'Leave the inbox unchanged.'},{'label':'Cancel','description':'Cancel this action.'}]}]}
   out({'id':rid,'method':'item/tool/requestUserInput','params':params})
  # Deliberately deliver the request before the turn/start response.
 elif method=='turn/interrupt':
  result={};out({'id':m['id'],'result':result});finish(p['threadId'],p['turnId'],'Stopped.','interrupted');continue
 else:
  out({'id':m.get('id'),'error':{'code':-32601,'message':'Unexpected fixture request: '+str(method)}});continue
 if 'id' in m:out({'id':m['id'],'result':result})
