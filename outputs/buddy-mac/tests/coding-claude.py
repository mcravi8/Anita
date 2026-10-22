#!/usr/bin/env python3
"""Offline SDK protocol fixture; actual files and commands run through native tools.

HOLD_FIXTURE:<name> in the brief holds the attempt open until the test says so: it writes <name>.start (when, this process's id, the
budget it was given) into $BUDDY_HOLD_FIXTURE_DIR, waits for <name>.release there, writes <name>.end and finishes. A retry after a stop
holds as <name>-again. SHELL_HOLD_FIXTURE:<name> runs one command that writes its runner's process id into the project (shell.pid) and
waits a few seconds, so a test can stop that runner while the command runs."""
import json,os,re,sys,time
session='4b088c90-af25-410c-8a7d-74d54e9c1cad'
config={}
def emit(value):
    print(json.dumps(dict(value,runId=config['runId'])),flush=True)
def hold_open(name):
    folder=os.environ.get('BUDDY_HOLD_FIXTURE_DIR','')
    if not folder:
        emit({'type':'result','text':'','subtype':'error_during_execution','error':'No hold folder was given to the fixture.','cost':0,'sessionId':session});return
    def mark(kind):
        path=os.path.join(folder,name+'.'+kind)
        with open(path+'.part','w') as f: json.dump({'at':time.time(),'pid':os.getpid(),'budget':config.get('budget'),'runId':config['runId'],'resume':config.get('resume')},f)
        os.replace(path+'.part',path)
    mark('start')
    release=os.path.join(folder,name+'.release')
    while not os.path.exists(release):
        # A test that ended (its folder is gone) or a worker that is gone (this process was handed to launchd) leaves nothing running.
        if not os.path.isdir(folder) or os.getppid()==1: sys.exit(0)
        time.sleep(0.05)
    mark('end')
    emit({'type':'result','text':'Held '+name+' open and finished.','subtype':'success','cost':0.01,'sessionId':session})
for line in sys.stdin:
    value=json.loads(line)
    if value['command']=='start':
        config=value
        if config.get('outputSchema'):
            # A structured background run that is not a coding session (the supervisor lane or a team check-in): it decides nothing here.
            emit({'type':'result','text':json.dumps({'actions':[]}),'subtype':'success','cost':0,'sessionId':session})
            continue
        names=[t['name'] for t in config['tools']]
        assert 'buddy_coding_command' in names and 'buddy_write_file' in names and 'buddy_copy_into_project' in names and 'buddy_copy_out_of_project' in names and 'buddy_checkpoint' in names and 'buddy_review_checkpoint' not in names
        assert 'buddy_request_decision' in names
        # The decision policy reaches every coding session, and a checkpoint is only for what the user must do in person.
        assert 'Decisions: decide by default.' in config['instructions'] and 'Use buddy_checkpoint only when the user must act in person' in config['instructions'],config['instructions'][:300]
        assert 'buddy_browser' not in names and 'buddy_connected_services' not in names
        emit({'type':'session','sessionId':session})
        prompt=config['prompt']
        shell_hold=re.search(r'SHELL_HOLD_FIXTURE:([A-Za-z0-9-]+)',prompt)
        held=re.search(r'HOLD_FIXTURE:([A-Za-z0-9-]+)',prompt)
        if shell_hold:
            emit({'type':'call','id':'shellhold','tool':'buddy_coding_command','arguments':{'code':'echo $PPID > shell.pid; sleep 6; echo held-'+shell_hold.group(1)}})
        elif held:
            hold_open(held.group(1)+('-again' if 'The last attempt stopped because' in prompt else ''))
        elif 'SUPERVISOR_CONTINUE' in prompt:
            # Continued by the team's supervisor after a technical stop: the follow-up is labelled as the supervisor's, not the user's.
            assert '\n\nUpdates from your supervisor:\n[From ' in prompt,prompt
            emit({'type':'result','text':'Continued on the supervisor\'s word and finished it.','subtype':'success','cost':0.01,'sessionId':session})
        elif 'The last attempt stopped because' in prompt:
            # Buddy's own retry note is labelled as a note from Buddy, not as the user's words.
            assert '\n\nNote from Buddy (not from the user):\nContinue the same brief. The last attempt stopped because' in prompt,prompt
            # Buddy resumed this by itself after a technical stop, with the plain cause appended to the brief.
            emit({'type':'result','text':'Recovered: continued the same brief and finished it.','subtype':'success','cost':0.01,'sessionId':session})
        elif 'STALL_FIXTURE' in prompt:
            pass   # the session started, then nothing: the host has to notice the silence
        elif 'MAXTURNS_FIXTURE' in prompt:
            emit({'type':'result','text':'','subtype':'error_max_turns','error':'It reached its limit on steps before it could finish. Continue it to keep going.','cost':0.01,'sessionId':session})
        elif 'LIMIT_FIXTURE' in prompt:
            if config.get('resume'): emit({'type':'result','text':'Finished once the daily limit had room again.','subtype':'success','cost':0.01,'sessionId':session})
            else: emit({'type':'result','text':'','subtype':'error_max_budget_usd','error':'It reached its spending limit before it could finish. Raise the Claude task limit in Settings and continue.','cost':1.0,'sessionId':session})
        elif 'LOST_SUMMARY_FIXTURE' in prompt:
            if config.get('resume'):
                emit({'type':'progress','text':'streamed text'})
                emit({'type':'result','text':'','subtype':'error_during_execution','error':'Claude hit an error while working.','cost':0.01,'sessionId':session})
            else: emit({'type':'result','text':'First attempt verified result.','subtype':'success','cost':0.01,'sessionId':session})
        elif 'REQUEST_DECISION_FIXTURE' in prompt:
            if '[Answer from' in prompt: emit({'type':'result','text':'Used the answer and finished the report.','subtype':'success','cost':0.01,'sessionId':session})
            else: emit({'type':'call','id':'decision','tool':'buddy_request_decision','arguments':{'question':'Which data year should the report use?','category':'approach','options':['2015','2020'],'recommendation':'Use the 2015 data.','context':'Both years are in the project folder.'}})
        elif 'SIGNIN_CHECKPOINT_FIXTURE' in prompt:
            emit({'type':'call','id':'signin','tool':'buddy_checkpoint','arguments':{'reason':'Sign in to the fixture site in private Chrome.','need':'signin'}})
        elif config.get('resume'):
            assert config['resume']==session
            emit({'type':'call','id':'command','tool':'buddy_coding_command','arguments':{'code':'node -e \'console.log("continued")\'' if 'CHECKPOINT_FIXTURE' in config['prompt'] else 'node --check index.js'}})
        elif 'CHECKPOINT_FIXTURE' in prompt:
            emit({'type':'call','id':'checkpoint','tool':'buddy_checkpoint','arguments':{'reason':'Choose the feature to implement next.'}})
        elif 'SLOW_FIXTURE' in prompt:
            emit({'type':'call','id':'command','tool':'buddy_coding_command','arguments':{'code':'node -e \'console.log("slow")\''}})
        elif 'COPY_FIXTURE' in prompt:
            folder=re.search(r'COPY_FIXTURE ([0-9A-Fa-f-]{36})',prompt).group(1)
            emit({'type':'call','id':'copy','tool':'buddy_copy_into_project','arguments':{'folderId':folder,'paths':['data/','missing.csv']}})
        elif 'NETWORK_REVIEW_FIXTURE' in prompt:
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
        elif value['id']=='decision':
            assert 'error' not in result and 'resumed with the answer' in result['instruction'],result
            emit({'type':'result','text':'Asked which data year to use; waiting for the answer.','cost':0.01,'sessionId':session})
        elif value['id']=='signin':
            # A coding session's commands can't use Chrome: a sign-in step is refused, saying to ask for the file instead.
            assert 'need file' in result.get('error',''),result
            emit({'type':'call','id':'signin-folders','tool':'buddy_list_folders','arguments':{}})
        elif value['id']=='signin-folders':
            folder=next(f['folderId'] for f in result['folders'] if not f.get('primary') and f.get('available'))
            emit({'type':'call','id':'signin-file','tool':'buddy_checkpoint','arguments':{'reason':'Save the fixture article PDF into the folder.','need':'file','url':'https://fixture.example/article/1','folderId':folder,'path':'sources/article.pdf'}})
        elif value['id']=='signin-file':
            assert result['paused'] is True,result
            emit({'type':'result','text':'Save the fixture article into the folder, then I will continue.','cost':0.01,'sessionId':session})
        elif value['id']=='shellhold':
            # The command's runner was stopped under it: this attempt ends in an error, as a real session would report it.
            if 'error' in result: emit({'type':'result','text':'','subtype':'error_during_execution','error':'Claude hit an error while working.','cost':0.01,'sessionId':session})
            else: emit({'type':'result','text':'Held the shell: '+result.get('output','').strip(),'subtype':'success','cost':0.01,'sessionId':session})
        else:
            if 'error' in result:
                emit({'type':'result','text':'The native command was declined. It did not run.','cost':0.01,'sessionId':session})
            else:
                assert result['exitCode']==0,result
                if 'SLOW_FIXTURE' in config['prompt']: time.sleep(4)   # long enough for the host's one-second checks to see the agent change
                emit({'type':'result','text':'Implemented the fixture and ran the actual Node syntax check.','cost':0.01,'sessionId':session})
