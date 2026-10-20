#!/usr/bin/env python3
"""Inert stand-in for `codex app-server` in a coding session. It answers the JSON-RPC methods Buddy uses and plays one scripted turn chosen
by a keyword in the brief: commands, an approval request, a Buddy tool call, a usage limit, silence, an error or a crash. It writes only
inside the thread's project folder (the cwd Buddy gives thread/start) and logs everything it receives, one JSON object per line, to
codex-fixture.jsonl in its own working folder, which the test reads. No network and no model."""
import json, os, re, sys, time, uuid

LOG = os.path.join(os.getcwd(), 'codex-fixture.jsonl')
threads = {}   # thread id -> {'cwd': project folder, 'resumed': whether this process resumed it}
waiting = {}   # id of a request this fixture made of Buddy -> what to do with the answer
seq = 0

def log(kind, value):
    with open(LOG, 'a') as f: f.write(json.dumps({'kind': kind, 'value': value, 'at': time.time()}) + '\n')
def out(value): print(json.dumps(value), flush=True)
def notice(method, params): out({'method': method, 'params': params})
def nxt():
    global seq
    seq += 1
    return seq
def ask(method, params, then):
    rid = 'srv-' + str(nxt()); waiting[rid] = then
    out({'id': rid, 'method': method, 'params': params})
def item(tid, turn, event, value): notice('item/' + event, {'threadId': tid, 'turnId': turn, 'item': value})
def say(tid, turn, text, phase='final_answer'):
    item(tid, turn, 'completed', {'type': 'agentMessage', 'id': 'msg-' + str(nxt()), 'phase': phase, 'text': text})
def done(tid, turn, status='completed', error=None):
    value = {'id': turn, 'status': status}
    if error: value['error'] = error
    notice('turn/completed', {'threadId': tid, 'turn': value})
def command(tid, turn, cid, code, exit_code, output='', duration=42, started=True):
    cwd = threads[tid]['cwd']
    if started: item(tid, turn, 'started', {'type': 'commandExecution', 'id': cid, 'command': code, 'cwd': cwd, 'status': 'inProgress', 'commandActions': []})
    if output: notice('item/commandExecution/outputDelta', {'threadId': tid, 'turnId': turn, 'itemId': cid, 'delta': output})
    item(tid, turn, 'completed', {'type': 'commandExecution', 'id': cid, 'command': code, 'cwd': cwd, 'status': 'completed' if exit_code == 0 else 'failed', 'exitCode': exit_code, 'durationMs': duration, 'aggregatedOutput': output, 'commandActions': []})
def write(tid, name, text, mode='w'):
    with open(os.path.join(threads[tid]['cwd'], name), mode) as f: f.write(text)
def tool_text(result):
    try: return json.loads(result['contentItems'][0]['text'])
    except Exception: return {}

def play(tid, turn, brief):
    again = threads[tid]['resumed']; cwd = threads[tid]['cwd']
    notice('turn/started', {'threadId': tid, 'turn': {'id': turn, 'status': 'inProgress'}})
    retried = any(k in brief for k in ['CODEX_STALL', 'CODEX_LIMIT', 'CODEX_ERROR', 'CODEX_CRASH'])
    if retried and again:
        say(tid, turn, 'Recovered: continued on the same thread and finished.'); done(tid, turn); return
    if 'CODEX_STALL' in brief: return   # nothing more: the worker has to notice the silence
    if 'CODEX_LIMIT' in brief:
        error = {'message': "You've hit your usage limit. Upgrade to Pro or try again later.", 'codexErrorInfo': 'usageLimitExceeded', 'additionalDetails': None}
        say(tid, turn, 'Started on the fixture before the limit.', 'commentary')
        notice('error', {'threadId': tid, 'turnId': turn, 'error': error, 'willRetry': False})
        done(tid, turn, 'failed', error); return
    if 'CODEX_ERROR' in brief:
        done(tid, turn, 'failed', {'message': 'stream disconnected before completion', 'codexErrorInfo': {'responseStreamDisconnected': {'httpStatusCode': None}}}); return
    if 'CODEX_CRASH' in brief:
        os._exit(3)
    if 'CODEX_NETWORK_DECLINE' in brief:
        # The command item is announced first and the approval request does not repeat the command.
        code = 'npm install left-pad'
        item(tid, turn, 'started', {'type': 'commandExecution', 'id': 'cmd-net-2', 'command': code, 'cwd': cwd, 'status': 'inProgress', 'commandActions': []})
        def declined(result):
            log('decision', result.get('decision'))
            if result.get('decision') == 'accept':
                write(tid, 'installed.txt', 'ran'); command(tid, turn, 'cmd-net-2', code, 0, 'added 1 package\n', 300, started=False); say(tid, turn, 'Installed it.')
            else:
                item(tid, turn, 'completed', {'type': 'commandExecution', 'id': 'cmd-net-2', 'command': code, 'cwd': cwd, 'status': 'declined', 'commandActions': []})
                say(tid, turn, 'The install was declined. It did not run.')
            done(tid, turn)
        ask('item/commandExecution/requestApproval', {'threadId': tid, 'turnId': turn, 'itemId': 'cmd-net-2', 'reason': 'Install the package the tests import.'}, declined); return
    if 'CODEX_NETWORK' in brief:
        code = 'curl -fsS https://example.com/dependency.tgz -o fetched.txt'
        def answered(result):
            log('decision', result.get('decision'))
            if result.get('decision') == 'accept':
                write(tid, 'fetched.txt', 'approved'); command(tid, turn, 'cmd-net', code, 0, 'fetched\n', 120); say(tid, turn, 'Fetched the dependency after your approval.')
            else:
                item(tid, turn, 'completed', {'type': 'commandExecution', 'id': 'cmd-net', 'command': code, 'cwd': cwd, 'status': 'declined', 'commandActions': []})
                say(tid, turn, 'The network command was declined. It did not run.')
            done(tid, turn)
        ask('item/commandExecution/requestApproval', {'threadId': tid, 'turnId': turn, 'itemId': 'cmd-net', 'reason': 'Download the dependency the build needs.', 'command': code, 'cwd': cwd}, answered); return
    if 'CODEX_OUTSIDE' in brief:
        target = '/tmp/buddy-outside-fixture-never-written.txt'
        item(tid, turn, 'started', {'type': 'fileChange', 'id': 'patch-out', 'changes': [{'path': target, 'kind': {'type': 'add'}, 'diff': '+outside'}], 'status': 'inProgress'})
        def patched(result):
            log('decision', result.get('decision'))
            item(tid, turn, 'completed', {'type': 'fileChange', 'id': 'patch-out', 'changes': [{'path': target, 'kind': {'type': 'add'}, 'diff': '+outside'}], 'status': 'completed' if result.get('decision') == 'accept' else 'declined'})
            say(tid, turn, 'Writing outside the project was ' + ('approved.' if result.get('decision') == 'accept' else 'declined.')); done(tid, turn)
        ask('item/fileChange/requestApproval', {'threadId': tid, 'turnId': turn, 'itemId': 'patch-out', 'reason': 'Put the build output next to the project.', 'grantRoot': '/tmp'}, patched); return
    if 'CODEX_COPY' in brief:
        folder = re.search(r'CODEX_COPY ([0-9A-Fa-f-]{36})', brief).group(1)
        def copied(result):
            log('tool-result', {'success': result.get('success'), 'value': tool_text(result)})
            write(tid, 'notes.txt', ' edited in the copy', 'a')
            command(tid, turn, 'cmd-copy', 'cat notes.txt', 0, 'original notes edited in the copy', 5)
            say(tid, turn, 'Copied notes.txt into the project and edited the copy.'); done(tid, turn)
        ask('item/tool/call', {'threadId': tid, 'turnId': turn, 'callId': 'call-copy', 'tool': 'buddy_copy_into_project', 'arguments': {'folderId': folder, 'paths': ['notes.txt']}}, copied); return
    if 'CODEX_DECISION' in brief:
        def asked(result):
            log('tool-result', {'success': result.get('success'), 'value': tool_text(result)})
            say(tid, turn, 'Asked which data year to use; waiting for the answer.'); done(tid, turn)
        ask('item/tool/call', {'threadId': tid, 'turnId': turn, 'callId': 'call-decision', 'tool': 'buddy_request_decision', 'arguments': {'question': 'Which data year should the report use?', 'category': 'approach', 'options': ['2015', '2020'], 'recommendation': 'Use the 2015 data.'}}, asked); return
    if 'CODEX_FORBIDDEN' in brief:
        def refused(result):
            log('tool-result', {'success': result.get('success'), 'value': tool_text(result)})
            say(tid, turn, 'buddy_write_file was ' + ('refused.' if result.get('success') is False else 'ALLOWED.')); done(tid, turn)
        ask('item/tool/call', {'threadId': tid, 'turnId': turn, 'callId': 'call-write', 'tool': 'buddy_write_file', 'arguments': {'path': 'x.txt', 'content': 'y', 'expectedVersion': ''}}, refused); return
    if again:
        command(tid, turn, 'cmd-again', 'node --check index.js', 0, '', 30)
        say(tid, turn, 'Continued on the same thread: the follow-up check passed.'); done(tid, turn); return
    # CODEX_BUILD and anything else: edit the project, run two commands, comment, then answer.
    write(tid, 'index.js', 'console.log("codex fixture");\n')
    command(tid, turn, 'cmd-build', 'node --check index.js', 0, '', 42)
    command(tid, turn, 'cmd-fail', "node -e 'process.exit(1)'", 1, 'boom\n', 7)
    say(tid, turn, 'Checking the build.', 'commentary')
    say(tid, turn, 'Built the fixture: node --check passed and the exit test failed as expected.')
    done(tid, turn)

for line in sys.stdin:
    m = json.loads(line); method = m.get('method'); p = m.get('params', {})
    if method is None:
        log('response', m)
        then = waiting.pop(m.get('id'), None)
        if then: then(m.get('result') if 'result' in m else {'error': m.get('error')})
        continue
    log('request', {'method': method, 'params': p})
    if 'id' not in m: continue   # a notification (initialized)
    result = {}
    if method == 'initialize': result = {'userAgent': 'codex-coding-fixture'}
    elif method == 'config/read': result = {'config': {}}
    elif method == 'account/read': result = {'account': {'type': 'chatgpt', 'planType': 'plus'}}
    elif method == 'model/list':
        result = {'data': [{'model': 'gpt-fixture-default', 'displayName': 'Fixture default', 'isDefault': True, 'defaultReasoningEffort': 'medium'},
                           {'model': 'gpt-fixture-coder', 'displayName': 'Fixture coder', 'defaultReasoningEffort': 'high'}]}
    elif method == 'account/rateLimits/read':
        now = int(time.time())
        result = {'rateLimits': {'primary': {'usedPercent': 100, 'windowDurationMins': 300, 'resetsAt': now + 3}, 'secondary': {'usedPercent': 30, 'windowDurationMins': 10080, 'resetsAt': now + 86400}}}
    elif method == 'thread/start':
        tid = str(uuid.uuid4()); threads[tid] = {'cwd': p.get('cwd'), 'resumed': False}; result = {'thread': {'id': tid}}
    elif method == 'thread/resume':
        tid = p.get('threadId'); threads[tid] = {'cwd': p.get('cwd'), 'resumed': True}; result = {'thread': {'id': tid}}
    elif method == 'turn/start':
        tid = p['threadId']; turn = 'turn-' + str(nxt())
        out({'id': m['id'], 'result': {'turn': {'id': turn, 'status': 'inProgress', 'items': []}}})
        play(tid, turn, ' '.join(i.get('text', '') for i in p.get('input', []) if isinstance(i, dict)))
        continue
    elif method == 'turn/interrupt':
        out({'id': m['id'], 'result': {}}); done(p.get('threadId'), p.get('turnId'), 'interrupted'); continue
    elif method == 'thread/unsubscribe': result = {}
    else:
        out({'id': m['id'], 'error': {'code': -32601, 'message': 'Unexpected ' + str(method)}}); continue
    out({'id': m['id'], 'result': result})
