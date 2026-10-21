#!/usr/bin/env python3
import sys,json,time,base64
for line in sys.stdin:
 x=json.loads(line);rid=x.get('id');method=x.get('method');p=x.get('params',{});result={}
 if rid is None:continue
 if method=='account/read':result={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':result={'config':{}}
 elif method=='app/installed':result={'apps':[{'id':'mail','runtimeName':'Gmail','enabled':True,'callable':True}]}
 elif method=='app/read':result={'apps':[{'id':'mail','name':'Gmail','toolSummaries':[{'name':n,'isReadOnly':True,'isEnabled':True} for n in ['get_profile','search_email_ids','read_email']]}]}
 elif method=='thread/start':
  assert p['ephemeral'] and p['config']['apps']['mail']['destructive_enabled']==False
  result={'thread':{'id':'mail-fixture'}}
 elif method=='mcpServer/tool/call':
  assert p['server']=='codex_apps'
  tool=p['tool'];args=p['arguments']
  if tool=='gmail.get_profile':data={'email':'fixture@example.com'}
  elif tool=='gmail.search_email_ids':
   assert 'to:fixture@example.com' in args['query'] and '@example.com' in args['query'] and args['max_results']==5
   data={'message_ids':['fixture-message']}
  elif tool=='gmail.read_email':
   assert args=={'message_id':'fixture-message','format':'full'}
   data={'id':'fixture-message','internalDate':str(int(time.time()*1000)),'payload':{'mimeType':'text/plain','body':{'data':base64.urlsafe_b64encode(b'Your verification code is 410239').decode()},'headers':[{'name':'From','value':'signin@example.com'},{'name':'To','value':'fixture@example.com'},{'name':'Subject','value':'Verify email'},{'name':'Authentication-Results','value':'mx.google.com; dmarc=pass header.from=example.com'}]}}
  else:raise AssertionError('Only three bounded read tools are allowed')
  result={'content':[{'type':'text','text':json.dumps(data)}]}
 print(json.dumps({'id':rid,'result':result}),flush=True)
