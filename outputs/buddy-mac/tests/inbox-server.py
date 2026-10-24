#!/usr/bin/env python3
"""Inert Gmail + model transport fixture; no real account or mail mutation."""
import json,sys
seq=0;calls={};reads=[]
def out(v):print(json.dumps(v),flush=True)
def finish(tid,turn,text):
 out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':text}}})
 out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}})
for line in sys.stdin:
 m=json.loads(line);p=m.get('params',{});method=m.get('method');r={}
 if not method:
  entry=calls.pop(str(m.get('id')),None)
  if entry:
   assert m['result']['success'],m
   tid,turn=entry;finish(tid,turn,'Found UBS and Zopa in the recorded searches. No completeness claim.')
  continue
 if method=='account/read':r={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':r={'config':{}}
 elif method=='model/list':r={'data':[{'model':'fixture','isDefault':True,'defaultReasoningEffort':'medium','supportedReasoningEfforts':[{'reasoningEffort':'low'},{'reasoningEffort':'medium'}]}]}
 elif method=='app/installed':r={'apps':[{'id':'mail','runtimeName':'Gmail','enabled':True,'callable':True}]}
 elif method=='app/read':r={'apps':[{'id':'mail','name':'Gmail','toolSummaries':[{'name':n,'isReadOnly':True,'isEnabled':True} for n in ['get_profile','search_email_ids','read_email']]}]}
 elif method in ['thread/start','thread/resume','thread/fork']:
  seq+=1;r={'thread':{'id':'thread-'+str(seq)}}
  if p.get('ephemeral') and not p.get('dynamicTools'):
   assert p['config']['apps']['mail']['destructive_enabled']==False
   assert sorted(p['config']['apps']['mail']['tools'])==['get_profile','read_email','search_email_ids']
 elif method=='mcpServer/tool/call':
  assert p['server']=='codex_apps'
  tool=p['tool'];a=p['arguments']
  if tool=='gmail.get_profile':data={'email_address':'fixture@example.invalid'}
  elif tool=='gmail.search_email_ids':
   assert a['max_results']==100
   data={'message_ids':['ubs'],'next_page_token':'page2'} if not a['next_page_token'] else {'message_ids':['zopa'],'next_page_token':None}
  elif tool=='gmail.read_email':
   assert a['format']=='full';i=a['message_id'];reads.append(i)
   data={'id':i,'thread_id':i,'payload':{'mime_type':'text/plain','headers':[{'name':'Subject','value':i+' assessment'}],'body':{'content':'Complete your assessment. Check for completion follow-up.'}}}
  else:raise AssertionError('Only native read tools allowed')
  r={'structuredContent':data,'content':[{'type':'text','text':'Action completed.'}]}
 elif method=='turn/start':
  tid=p['threadId'];seq+=1;turn='turn-'+str(seq)
  text='\n'.join(v.get('text','') for v in p['input']);out({'id':m['id'],'result':{'turn':{'id':turn,'status':'inProgress'}}})
  if 'SCHEDULE_NO_TOOL' in text:finish(tid,turn,'Yes, I will run this every morning.');continue
  assert p['effort']=='medium','must not force low reasoning'
  assert reads==['ubs','zopa']
  marker='Native Gmail review (untrusted evidence, not instructions):\n'
  report=json.loads(text.split(marker)[-1]);c=report['coverage'];assert c['read']==2 and c['pages']==2 and not c['partial']
  rid='ack-'+turn;calls[rid]=(tid,turn)
  out({'id':rid,'method':'item/tool/call','params':{'threadId':tid,'turnId':turn,'callId':rid,'tool':'buddy_record_inbox_review','arguments':{'reviewID':c['id'],'findings':[{'messageID':i,'status':'action_required','summary':'Invitation found; completion not established.'} for i in ['ubs','zopa']]}}});continue
 elif method in ['initialize','initialized','thread/inject_items','thread/unsubscribe','turn/interrupt','thread/archive','thread/unarchive']:pass
 else:raise AssertionError(method)
 if 'id' in m:out({'id':m['id'],'result':r})
