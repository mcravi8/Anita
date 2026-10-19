#!/usr/bin/env python3
"""Offline SDK protocol fixture; actual files and commands run through native tools."""
import json,re,sys
session='4b088c90-af25-410c-8a7d-74d54e9c1cad'
config={}
def emit(value):
    print(json.dumps(dict(value,runId=config['runId'])),flush=True)
for line in sys.stdin:
    value=json.loads(line)
    if value['command']=='start':
        config=value
        names=[t['name'] for t in config['tools']]
        assert 'buddy_coding_command' in names and 'buddy_write_file' in names and 'buddy_copy_into_project' in names and 'buddy_copy_out_of_project' in names
        assert 'buddy_browser' not in names and 'buddy_connected_services' not in names
        emit({'type':'session','sessionId':session})
        if config.get('resume'):
            assert config['resume']==session
            emit({'type':'call','id':'command','tool':'buddy_coding_command','arguments':{'code':'node -e \'console.log("continued")\'' if 'CHECKPOINT_FIXTURE' in config['prompt'] else 'node --check index.js'}})
        elif 'CHECKPOINT_FIXTURE' in config['prompt']:
            emit({'type':'call','id':'checkpoint','tool':'buddy_checkpoint','arguments':{'reason':'Choose the feature to implement next.'}})
        elif 'COPY_FIXTURE' in config['prompt']:
            folder=re.search(r'COPY_FIXTURE ([0-9A-Fa-f-]{36})',config['prompt']).group(1)
            emit({'type':'call','id':'copy','tool':'buddy_copy_into_project','arguments':{'folderId':folder,'paths':['data/','missing.csv']}})
        elif 'NETWORK_REVIEW_FIXTURE' in config['prompt']:
            emit({'type':'call','id':'network','tool':'buddy_coding_command','arguments':{'code':'node -e \'require("fs").writeFileSync("reviewed.txt","approved")\'','network':True,'reason':'Inert fixture verifies exact-command review; no internet request is made.'}})
        else:
            emit({'type':'call','id':'write','tool':'buddy_write_file','arguments':{'path':'index.js','content':'console.log("fixture coding tool");\n','expectedVersion':''}})
    elif value['command']=='result':
        assert value['runId']==config['runId']
        result=value['result']
        if value['id']=='write':
            assert 'error' not in result,result
            emit({'type':'call','id':'command','tool':'buddy_coding_command','arguments':{'code':'node --check index.js'}})
        elif value['id']=='copy':
            assert 'error' not in result,result
            assert [c['path'] for c in result['copied']]==['data/prices.csv'] and [f['path'] for f in result['failed']]==['missing.csv'],result
            emit({'type':'call','id':'copycmd','tool':'buddy_coding_command','arguments':{'code':'node -e \'console.log(require("fs").statSync("data/prices.csv").size)\''}})
        elif value['id']=='copycmd':
            assert result['exitCode']==0,result
            emit({'type':'call','id':'out','tool':'buddy_copy_out_of_project','arguments':{'folderId':re.search(r'COPY_FIXTURE ([0-9A-Fa-f-]{36})',config['prompt']).group(1),'paths':['data/'],'into':'results'}})
        elif value['id']=='out':
            assert 'error' not in result and [c['to'] for c in result['copied']]==['results/data/prices.csv'] and not result['failed'],result
            emit({'type':'result','text':'Copied the data in, checked it, and saved it back under results.','cost':0.01,'sessionId':session})
        elif value['id']=='checkpoint':
            assert result['paused'] is True,result
            emit({'type':'result','text':'Which feature should I implement next?','cost':0.01,'sessionId':session})
        else:
            if 'error' in result:
                emit({'type':'result','text':'The native command was declined. It did not run.','cost':0.01,'sessionId':session})
            else:
                assert result['exitCode']==0,result
                emit({'type':'result','text':'Implemented the fixture and ran the actual Node syntax check.','cost':0.01,'sessionId':session})
