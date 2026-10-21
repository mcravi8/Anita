#!/usr/bin/env python3
"""Inert interview SDK fixture. No network or credentials."""
import json,sys,time
from pathlib import Path
for line in sys.stdin:
    c=json.loads(line)
    if c['command']!='start':continue
    assert c['tools']==[]
    assert 'NO tools' in c['instructions']
    prompt=json.loads(c['prompt']);answers=[m['text'] for m in prompt['conversation'] if m['speaker']=='user'];text=' '.join(answers)
    phase='questions' if 'ready' in c['outputSchema']['properties'] else 'instructions'
    # The interview offers the default user list and never asks what the agent must "never decide without asking";
    # the written instructions keep the user's own boundaries and never add "if in doubt, ask".
    if phase=='questions':
        assert 'offer the default list: money leaving their accounts, sign-ins and credentials, messages or submissions to other people, changes to the objective' in c['instructions'],c['instructions']
        assert "Never ask what the agent should 'never decide without asking'." in c['instructions'],c['instructions']
    else:
        assert "Write boundaries in the user's own terms and only those they stated. Do not add 'if in doubt, ask' or 'check first when unsure'; where the user delegates judgement, write that the agent decides." in c['instructions'],c['instructions']
    directory=Path(c['cwd']).parent
    with (directory/'fixture-calls.jsonl').open('a') as f:f.write(json.dumps({'phase':phase,'model':c['model'],'budget':c['budget'],'repair':'draftToShorten' in prompt})+'\n')
    if phase=='questions':
        result={'role':'Research partner','instructions':'Research primary public sources and return concise, sourced comparisons. Ask only for missing scope.','ready':not (len(answers)==1 and 'NEED_MORE' in text),'question':'Which sources should I use, and what should I bring back to you?' if len(answers)==1 and 'NEED_MORE' in text else ''}
    else:
        if 'SLOW_PROFILE' in text:time.sleep(3)
        marker=directory/'failed-once'
        if 'FAIL_ONCE' in text and not marker.exists():
            marker.write_text('failed')
            print(json.dumps({'type':'error','runId':c['runId'],'error':'Fixture generation failed; answers retained.'}),flush=True);continue
        result={'role':'Research partner','instructions':'You are an expert research partner. Find relevant primary sources, compare their evidence, separate verified facts from inference, and return concise findings with links. Ask when important scope is missing. Follow the user’s stated priorities and current Buddy permissions.'}
        if 'LONG_PROFILE' in text and 'draftToShorten' not in prompt:result['instructions']='Detailed evidence and preferences. '*70
    print(json.dumps({'type':'result','runId':c['runId'],'text':json.dumps(result),'cost':0.04}),flush=True)
