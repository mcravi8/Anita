#!/usr/bin/env python3
"""Offline stand-in for the Claude coding bridge (coding.mjs), the background Claude bridge (claude.mjs) and the supervisor's Claude run, for
tests/SignInCommand.swift. No network, no real keys and no real sign-in: it only plays the tool calls an agent would make and writes every
start and every tool result it receives, one JSON object per line, to the file named by BUDDY_SIGNIN_FIXTURE_LOG, which the test reads to
check what the model side was shown. Commands it asks for run for real in Buddy's sandboxed command runner."""
import base64, json, os, sys

LOG = os.environ.get('BUDDY_SIGNIN_FIXTURE_LOG', '')
SESSION = '6c1f2e9a-5b7d-4e0a-9c3b-2a4d6e8f0b1c'
# Prints the sign-in it was given (Buddy must hide it), a digest that proves the exact values arrived, after a pause long enough to see the
# Duo wait while it runs.
ENV_CMD = ("node -e 'const c=require(\"crypto\");const u=process.env.PGUSER||\"\",p=process.env.PGPASSWORD||\"\";"
           "setTimeout(()=>{console.log(\"user=\"+u+\" pass=\"+p);console.log(\"digest=\"+c.createHash(\"sha256\").update(u+\":\"+p).digest(\"hex\"))},3000)'")
PLAIN_CMD = "node -e 'console.log(\"plain user=\"+process.env.PGUSER+\" pass=\"+process.env.PGPASSWORD)'"
ROUTINE_CMD = 'curl -fsSL https://cdn.cboe.com/api/global/us_indices/daily_prices/VIX_History.csv -o data/vix.csv'
OWN_CMD = 'curl -fsS --max-time 5 https://buddy-fixture-never-resolves.example.com/vix.csv -o data/vix.csv'
# A project script the agent writes with an ordinary command, then asks to run with network access. It only writes a file in the project.
def probe(n): return 'const fs=require("fs");fs.writeFileSync("tools/probe%s-out.txt","probe ran\\n");\n// PROBE_FIXTURE\n' % n
def make(n): return "node -e 'require(\"fs\").mkdirSync(\"tools\",{recursive:true});require(\"fs\").writeFileSync(\"tools/probe%s.js\",Buffer.from(\"%s\",\"base64\"))'" % (n, base64.b64encode(probe(n).encode()).decode())
config = {}

def log(kind, value):
    if LOG:
        with open(LOG, 'a') as f: f.write(json.dumps({'kind': kind, 'value': value}) + '\n')
def emit(value): print(json.dumps(dict(value, runId=config.get('runId', ''))), flush=True)
def call(cid, tool, arguments): emit({'type': 'call', 'id': cid, 'tool': tool, 'arguments': arguments})
def finish(text): emit({'type': 'result', 'text': text, 'subtype': 'success', 'cost': 0.0, 'sessionId': SESSION})

def supervise(c):
    """The supervisor's run: approve a routine command review, decline one whose reason asks for it, hold everything else. A review whose reason
    says EDIT_AFTER_REVIEW has its scripts edited first, as an agent changing a script after Buddy read it would."""
    brief = json.loads(c['prompt'])
    items = brief.get('items', [])
    log('supervisor', {'items': items, 'enum': c['outputSchema']['properties']['actions']['items']['properties']['do']['enum'], 'instructions': c['instructions']})
    actions = []
    for i in items:
        if i.get('kind') == 'command_review':
            review = i.get('command') or {}
            if 'EDIT_AFTER_REVIEW' in review.get('reason', ''):
                for script in review.get('scripts', []):
                    if not script.get('inline'):
                        with open(os.path.join(review.get('project', ''), script['path']), 'a') as f: f.write('// edited after Buddy read it\n')
            if 'DECLINE_FIXTURE' in json.dumps(review):
                actions.append({'item': i['key'], 'do': 'decline_command', 'reason': 'Not needed for the task.'})
            else:
                actions.append({'item': i['key'], 'do': 'approve_command', 'reason': 'A public CBOE download the stage 3 check needs, saved inside the project.'})
        else:
            actions.append({'item': i['key'], 'do': 'hold', 'reason': 'Nothing to do yet.'})
    print(json.dumps({'type': 'result', 'runId': c['runId'], 'text': json.dumps({'actions': actions}), 'subtype': 'success', 'error': None, 'cost': 0.0, 'sessionId': 'fixture'}), flush=True)

for line in sys.stdin:
    value = json.loads(line)
    if value.get('command') == 'start':
        if value.get('outputSchema'):
            config = value; supervise(value); continue
        config = value
        names = [t['name'] for t in value['tools']]
        prompt = value['prompt']
        log('start', {'tools': names, 'prompt': prompt, 'instructions': value['instructions'], 'resume': value.get('resume')})
        emit({'type': 'session', 'sessionId': SESSION})
        if 'buddy_coding_command' not in names:
            # A background task (no command runner): it asks for the sign-in and stops.
            call('bg-ask', 'buddy_request_signin', {'profile': 'wrds', 'purpose': 'look up the WRDS data dictionary'})
        elif 'SIGNIN_FIXTURE' in prompt and 'Your WRDS sign-in is saved' in prompt:
            call('ask2', 'buddy_request_signin', {'profile': 'wrds', 'purpose': 'run the OptionMetrics SPX skew extract'})
        elif 'SIGNIN_FIXTURE' in prompt:
            call('ask', 'buddy_request_signin', {'profile': 'wrds', 'purpose': 'run the OptionMetrics SPX skew extract'})
        elif 'NETWORK_OWN_FIXTURE' in prompt:
            # Chief's own routine download. The host never resolves, so nothing leaves this Mac even after Buddy approves it.
            call('net', 'buddy_coding_command', {'code': OWN_CMD, 'network': True, 'reason': 'fetch the public VIX history for the check'})
        elif 'NETWORK_SCRIPT_EDIT_FIXTURE' in prompt:
            call('mk2', 'buddy_coding_command', {'code': make(2)})
        elif 'NETWORK_SCRIPT_FIXTURE' in prompt:
            call('mk1', 'buddy_coding_command', {'code': make(1)})
        elif 'NETWORK_ROUTINE_FIXTURE' in prompt:
            call('net', 'buddy_coding_command', {'code': ROUTINE_CMD, 'network': True, 'reason': 'DECLINE_FIXTURE: fetch the public VIX history for the check'})
        else:
            finish('Nothing to do.')
    elif value.get('command') == 'result':
        cid, result = value['id'], value['result']
        log('result', {'id': cid, 'result': result})
        if cid in ('ask', 'bg-ask'):
            finish('WRDS needs your sign-in; I will continue once it is saved.')
        elif cid == 'ask2':
            if result.get('status') == 'available':
                call('cred1', 'buddy_coding_command', {'code': ENV_CMD, 'credential': 'wrds', 'reason': 'Run the WRDS extract with the saved sign-in'})
            else:
                finish('UNEXPECTED: the saved sign-in was not available.')
        elif cid == 'cred1':
            # The first review is declined: the same command is asked for once more.
            call('cred2', 'buddy_coding_command', {'code': ENV_CMD, 'credential': 'wrds', 'reason': 'Run the WRDS extract with the saved sign-in'})
        elif cid == 'cred2':
            call('plain', 'buddy_coding_command', {'code': PLAIN_CMD})
        elif cid == 'plain':
            finish('Ran the extract with the saved sign-in; it stayed private.')
        elif cid in ('mk1', 'mk2'):
            n = cid[-1]
            reason = 'run the project probe for the check' + (' EDIT_AFTER_REVIEW' if n == '2' else '')
            call('script' + n, 'buddy_coding_command', {'code': 'node tools/probe%s.js' % n, 'network': True, 'reason': reason})
        elif cid in ('script1', 'script2'):
            finish('The script did not run: ' + str(result.get('error')) if 'error' in result else 'Ran the project probe.')
        elif cid == 'net':
            finish('The supervisor declined the download, so it did not run.' if 'error' in result else 'UNEXPECTED: the download ran.')
        else:
            finish('UNEXPECTED tool result ' + cid)
    elif value.get('command') == 'stop':
        break
