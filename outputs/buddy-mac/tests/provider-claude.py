#!/usr/bin/env python3
"""Inert Claude JSONL bridge fixture. No SDK, credentials or network are used."""
import json,sys

def out(x):print(json.dumps({**x,"runId":config.get("runId")}),flush=True)
for line in sys.stdin:
 config=json.loads(line);assert config['command']=='start' and config['apiKey']=='fixture-key'
 prompt=config['prompt']
 # Only a daily limit gives a turn a ceiling, and then it is the room that limit leaves.
 assert (config['budget'] is None)!=('DAILY_LIMIT' in prompt),config['budget']
 assert all(t['name'].startswith('buddy_') for t in config['tools'])
 if 'ECHO_INSTRUCTIONS' in prompt:
  out({'type':'result','text':config['instructions'],'cost':0.01,'error':None});continue
 if 'COMPUTER_TASK' in prompt:
  assert 'buddy_computer_task' in [t['name'] for t in config['tools']]
  assert 'user does not need to say' in config['instructions']
  out({'type':'call','id':'browser-1','tool':'buddy_computer_task','arguments':{'action':'start','title':'Create AgentMail inbox','goal':'Open AgentMail and create the requested inbox in the existing account.'}})
  result=json.loads(sys.stdin.readline());assert result['result']['task']['status']=='queued',result
 if 'BUILD_TEAM_CLAUDE' in prompt:
  out({'type':'call','id':'team-1','tool':'buddy_build_team','arguments':{'action':'create','teamName':'Claude research','objective':'Research public evidence','reason':'Source gathering','authorizationQuote':'Create a research team.','newAgents':[{'name':'Claude scout','role':'Researcher','description':'Research primary sources and ask only for missing scope.','avatarShape':'clover','avatarColor':'mint'}]}})
  result=json.loads(sys.stdin.readline());assert result['result'].get('created'),result
 if 'SAVE_PROACTIVE' in prompt:
  out({'type':'call','id':'proactive-1','tool':'buddy_team','arguments':{'action':'set_proactive','enabled':True,'quote':'Keep me updated.'}})
  result=json.loads(sys.stdin.readline());assert result['result'].get('saved'),result
 if 'SAVE_RULE' in prompt:
  out({'type':'call','id':'rule-1','tool':'buddy_agent_rules','arguments':{'action':'add','rule':'Show the CV first','then':'proceed','reviewFirst':3,'quote':'send me the CV'}})
  result=json.loads(sys.stdin.readline());assert result['result'].get('saved'),result
 if 'WRITE_CLAUDE' in prompt:
  out({'type':'call','id':'file-1','tool':'buddy_write_file','arguments':{'path':'claude-note.md','content':'# Created through the selected Claude provider','expectedVersion':''}})
  result=json.loads(sys.stdin.readline());assert result['result'].get('saved'),result
 elif 'WAIT_CLAUDE' in prompt:
  out({'type':'progress','text':'Fixture is waiting; no external effects.'})
  for line in sys.stdin:pass
  sys.exit(0)
 if 'HISTORY_CHECK' in prompt:assert 'Earlier ChatGPT answer' in prompt
 out({'type':'progress','text':'Claude fixture responding.'})
 text=json.dumps({'ok':True}) if config.get('outputSchema') else 'Claude fixture answer'
 if 'CLAIM_SCHEDULE' in prompt:text='Yes, I will run this every morning.'
 if 'CLAIM_RULE' in prompt:text='Done. I saved that rule and will follow it from now on.'
 if 'CLAIM_PROACTIVE' in prompt:text='Sure, I will keep you posted.'
 out({'type':'result','text':text,'cost':0.01,'error':None})
