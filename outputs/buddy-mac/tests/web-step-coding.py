#!/usr/bin/env python3
"""Offline stand-in for the Claude coding bridge (coding.mjs) for tests/WebStep.swift. A brief with CALLS:<json list of [tool, arguments]>
makes those tool calls one after another: the next one only after the previous was refused, and it stops at the first one that is not.
"$PRIVATE" in an argument is the task's own project copy (the primary folder buddy_list_folders returns). A resumed attempt (its brief
carries Buddy's note) finishes at once. Every start and every tool result is written to BUDDY_STEP_CODING_LOG."""
import json,os,sys
LOG=os.environ.get('BUDDY_STEP_CODING_LOG','');SESSION='0b5f7c1e-2d4a-4e6b-9c8d-1a2b3c4d5e6f'
config={};queue=[];private=''
def log(kind,value):
 if LOG:
  with open(LOG,'a') as f:f.write(json.dumps({'kind':kind,'value':value})+'\n')
def emit(value):print(json.dumps(dict(value,runId=config.get('runId',''))),flush=True)
def finish(text):emit({'type':'result','text':text,'subtype':'success','cost':0.0,'sessionId':SESSION})
def fill(value):
 if isinstance(value,str):return value.replace('$PRIVATE',private)
 if isinstance(value,dict):return {k:fill(v) for k,v in value.items()}
 if isinstance(value,list):return [fill(v) for v in value]
 return value
def next_call():
 if not queue:finish('Nothing left to try.');return
 n,tool,args=queue.pop(0)
 emit({'type':'call','id':'c%d'%n,'tool':tool,'arguments':fill(args)})
for line in sys.stdin:
 value=json.loads(line)
 if value.get('command')=='start':
  config=value;prompt=value['prompt']
  log('start',{'tools':[t['name'] for t in value['tools']],'prompt':prompt,'instructions':value['instructions'],'resume':value.get('resume')})
  emit({'type':'session','sessionId':SESSION})
  at=prompt.find('CALLS:')
  if '[Buddy]' in prompt or at<0:finish('Checked the folder and continued.');continue
  calls,_=json.JSONDecoder().raw_decode(prompt,at+len('CALLS:'))
  queue=[(i,c[0],c[1]) for i,c in enumerate(calls)]
  if '$PRIVATE' in json.dumps(calls):emit({'type':'call','id':'folders','tool':'buddy_list_folders','arguments':{}})
  else:next_call()
 elif value.get('command')=='result':
  cid,result=value['id'],value['result']
  log('result',{'id':cid,'result':result})
  if cid=='folders':
   private=next((f['folderId'] for f in result.get('folders',[]) if f.get('primary')),'')
   next_call()
  elif 'error' in result:next_call()
  else:finish('Asked the user; waiting.')
