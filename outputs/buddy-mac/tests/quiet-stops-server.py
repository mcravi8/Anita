#!/usr/bin/env python3
"""Inert app-server fixture whose ChatGPT connector runtime fails to refresh, as it did for Inbox's 06:00 check.

Every connection list fails with the error the real app-server gave. Only "fixture" is a model. With QUIET_FIXTURE_SIGNED_OUT=1 in the
environment the account is signed out. No network, keys or user data."""
import sys,json,os
signed_out=os.environ.get('QUIET_FIXTURE_SIGNED_OUT')=='1'
def out(x):print(json.dumps(x),flush=True)
for line in sys.stdin:
 m=json.loads(line);method=m.get('method');result={}
 if not method:continue
 if method=='initialize':pass
 elif method=='config/read':result={'config':{}}
 elif method=='account/read':result={'account':None} if signed_out else {'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='model/list':result={'data':[{'model':'fixture','isDefault':True}]}
 elif method=='app/installed':
  out({'id':m.get('id'),'error':{'code':-32603,'message':"failed to refresh installed connector runtime state: failed to refresh tools for MCP server 'codex_apps'"}});continue
 elif method in ['thread/unsubscribe','turn/interrupt']:pass
 else:out({'id':m.get('id'),'error':{'code':-32601,'message':'Unexpected '+str(method)}});continue
 if 'id' in m:out({'id':m['id'],'result':result})
