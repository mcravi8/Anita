#!/usr/bin/env python3
"""Inert connected-tool transport. A model handoff is a test failure."""
import json,sys,time
from pathlib import Path
seq=0;calls=0;root=None

def out(v):print(json.dumps(v),flush=True)
for line in sys.stdin:
 m=json.loads(line);method=m.get('method');p=m.get('params',{});r={}
 if method=='account/read':r={'account':{'type':'chatgpt'}}
 elif method=='config/read':r={'config':{}}
 elif method=='app/installed':r={'apps':[{'id':'mail','enabled':True,'callable':True},{'id':'connector_openai_search_service','enabled':True,'callable':True}]}
 elif method=='app/read':r={'apps':[{'id':'mail','name':'Gmail','toolSummaries':[{'name':n,'isReadOnly':n!='send_email','isEnabled':True} for n in ['get_profile','search_email_ids','read_email','send_email','forged_read']]},{'id':'connector_openai_search_service','name':'Search Service','toolSummaries':[{'name':'web_run','isReadOnly':True,'isEnabled':True}]}]}
 elif method=='thread/start':
  seq+=1;root=Path(p['cwd']).parent;r={'thread':{'id':'read-'+str(seq)}}
  apps={k:v for k,v in p['config']['apps'].items() if k!='_default'}
  assert p['ephemeral'] and apps and all(v['destructive_enabled']==False for v in apps.values())
  assert 'send_email' not in apps.get('mail',{}).get('tools',{})
 elif method=='mcpServerStatus/list':
  tools={}
  for name in ['get_profile','read_email','send_email','forged_read']:
   tools['gmail.'+name]={'description':'Fixture read','inputSchema':{'type':'object','properties':{'message_id':{'type':'string'}}},'annotations':{'readOnlyHint':name not in ['send_email','forged_read'],'destructiveHint':False},'_meta':{'connector_id':'mail'}}
  tools['other.read_email']={'inputSchema':{'type':'object'},'annotations':{'readOnlyHint':True},'_meta':{'connector_id':'other'}}
  tools['search_service.web_run']={'description':'Fixture web search','inputSchema':{'type':'object','properties':{'system2_search_query':{'type':'array'},'open':{'type':'array'},'response_length':{'type':'string','enum':['short','medium','long']}}},'annotations':{'readOnlyHint':True,'destructiveHint':False},'_meta':{'connector_id':'connector_openai_search_service'}}
  r={'data':[{'name':'codex_apps','tools':tools}]}
 elif method=='mcpServer/tool/call':
  assert p['server']=='codex_apps' and p['tool'] in ['gmail.get_profile','gmail.read_email','search_service.web_run']
  calls+=1
  if p['tool']=='search_service.web_run':
   # Like the real search service: the text grows with response_length, one block per query, and carries no structured content.
   a=p['arguments'];length=a.get('response_length','medium');per={'short':3000,'medium':9000,'long':15000}[length]
   head='response_length=%s queries=%d\n'%(length,len(a.get('system2_search_query') or []))
   body=''.join('Result %d for %s (https://example.invalid/%d)\n%s\n'%(i,q.get('q'),i,'w'*per) for i,q in enumerate(a.get('system2_search_query') or []))
   r={'content':[{'type':'text','text':head+body}]};out({'id':m['id'],'result':r});continue
  if p['tool']=='gmail.get_profile':data={'email_address':(root/'fixture-mailbox.txt').read_text() if (root/'fixture-mailbox.txt').exists() else 'fixture@example.invalid'}
  else:
   if p['arguments'].get('message_id')=='delayed':time.sleep(0.1)
   data={'id':p['arguments'].get('message_id'),'fixtureThreads':seq,'fixtureCalls':calls,'source':'https://example.invalid/source'}
  r={'structuredContent':data}
 elif method=='turn/start':raise AssertionError('Direct reads must never run a model')
 if 'id' in m:out({'id':m['id'],'result':r})
