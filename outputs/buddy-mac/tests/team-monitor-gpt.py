#!/usr/bin/env python3
"""Tool-free OpenAI app-server fixture; never contacts an account or network."""
import json,sys
seq=0

def out(x):print(json.dumps(x),flush=True)
for line in sys.stdin:
 m=json.loads(line);p=m.get('params',{});method=m.get('method');r={}
 if not method:continue
 if method=='account/read':r={'account':{'type':'chatgpt','planType':'fixture'}}
 elif method=='config/read':r={'config':{}}
 elif method=='model/list':r={'data':[{'model':'fixture-gpt','isDefault':True}]}
 elif method in ['app/installed','app/read']:r={'apps':[]}
 elif method in ['thread/start','thread/fork','thread/resume']:
  assert not p.get('dynamicTools') and p.get('config',{}).get('features.apps') is False
  assert p['sandbox']=='read-only' and p['approvalPolicy']=='never'
  seq+=1;r={'thread':{'id':'thread-'+str(seq)}}
 elif method=='turn/start':
  assert p['model']=='fixture-gpt' and 'notify' in p['outputSchema']['properties']
  text='\n'.join(i.get('text','') for i in p['input'] if i['type']=='text');data=None;decoder=json.JSONDecoder()
  for i,ch in enumerate(text):
   if ch!='{':continue
   try:
    candidate,_=decoder.raw_decode(text[i:])
    if isinstance(candidate,dict) and ('reports' in candidate or 'sources' in candidate):data=candidate;break
   except ValueError:pass
  assert data is not None
  ids=data.get('checkinIds',[]) or [s['id'] for s in data.get('sources',[]) if s.get('kind')=='worker']
  result={'notify':bool(ids),'body':'GPT Chief verified the peer check-in: Maze needs a decision.','priority':0,'sourceIds':ids}
  seq+=1;turn='turn-'+str(seq);tid=p['threadId'];out({'id':m['id'],'result':{'turn':{'id':turn,'status':'inProgress'}}})
  out({'method':'item/completed','params':{'threadId':tid,'turnId':turn,'item':{'type':'agentMessage','id':'answer-'+turn,'phase':'final_answer','text':json.dumps(result)}}})
  out({'method':'turn/completed','params':{'threadId':tid,'turn':{'id':turn,'status':'completed'}}});continue
 elif method not in ['initialize','initialized','thread/inject_items','thread/unsubscribe','turn/interrupt']:raise AssertionError(method)
 if 'id' in m:out({'id':m['id'],'result':r})
