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
 elif method=='app/installed':r={'apps':[{'id':'mail','enabled':True,'callable':True}]}
 elif method=='app/read':r={'apps':[{'id':'mail','name':'Gmail','toolSummaries':[{'name':n,'isReadOnly':n!='send_email','isEnabled':True} for n in ['get_profile','search_email_ids','read_email','send_email','forged_read']]}]}
 elif method=='thread/start':
  seq+=1;root=Path(p['cwd']).parent;r={'thread':{'id':'read-'+str(seq)}}
  assert p['ephemeral'] and p['config']['apps']['mail']['destructive_enabled']==False
  assert 'send_email' not in p['config']['apps']['mail']['tools']
 elif method=='mcpServerStatus/list':
  tools={}
  for name in ['get_profile','read_email','send_email','forged_read']:
   tools['gmail.'+name]={'description':'Fixture read','inputSchema':{'type':'object','properties':{'message_id':{'type':'string'}}},'annotations':{'readOnlyHint':name not in ['send_email','forged_read'],'destructiveHint':False},'_meta':{'connector_id':'mail'}}
  tools['other.read_email']={'inputSchema':{'type':'object'},'annotations':{'readOnlyHint':True},'_meta':{'connector_id':'other'}}
  r={'data':[{'name':'codex_apps','tools':tools}]}
 elif method=='mcpServer/tool/call':
  assert p['server']=='codex_apps' and p['tool'] in ['gmail.get_profile','gmail.read_email']
  calls+=1
  if p['tool']=='gmail.get_profile':data={'email_address':(root/'fixture-mailbox.txt').read_text() if (root/'fixture-mailbox.txt').exists() else 'fixture@example.invalid'}
  else:
   if p['arguments'].get('message_id')=='delayed':time.sleep(0.1)
   data={'id':p['arguments'].get('message_id'),'fixtureThreads':seq,'fixtureCalls':calls,'source':'https://example.invalid/source'}
  r={'structuredContent':data}
 elif method=='turn/start':raise AssertionError('Direct reads must never run a model')
 if 'id' in m:out({'id':m['id'],'result':r})
