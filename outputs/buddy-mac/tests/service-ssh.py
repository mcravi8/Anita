#!/usr/bin/env python3
"""Offline stand-in for ssh, for tests/ServiceLeases.swift. Buddy runs it as it would run /usr/bin/ssh; it reaches no network. It finds the
pod tests/service-api-server.py gave this port, refuses unless that pod is RUNNING and was created with the public half of the identity
Buddy passed (env PUBLIC_KEY), and then runs the remote command with bash in the pod's folder (HOME), passing stdin and stdout through, in a
process group of its own as a machine would. Buddy runs ssh with almost no environment, so the test puts the service's state folder and
the log first on the command line (--state, --log); every call's arguments go to that log (Buddy must never put a secret there)."""
import json, os, subprocess, sys

args = sys.argv[1:]
STATE, LOG = args[1], args[3]
args = args[4:]
with open(LOG, 'a') as f: f.write(json.dumps({'argv': args, 'env': sorted(os.environ.keys())}) + '\n')
options, identity, port, i = [], None, 22, 0
while i < len(args) and args[i].startswith('-'):
    flag = args[i]
    if flag in ('-F', '-i', '-o', '-p'):
        value = args[i + 1]
        if flag == '-i': identity = value
        if flag == '-p': port = int(value)
        if flag == '-o': options.append(value)
        i += 2
    else: i += 1
destination, remote = args[i], args[i + 1]
# Real ssh reads UserKnownHostsFile as a list of files split at spaces unless the path is quoted (Buddy's folder is under "Application Support").
for option in options:
    if option.startswith('UserKnownHostsFile='):
        value = option.split('=', 1)[1]
        if not (len(value) > 1 and value.startswith('"') and value.endswith('"')): sys.stderr.write('stand-in ssh: unquoted UserKnownHostsFile %s\n' % value); sys.exit(255)
for needed in ('BatchMode=yes', 'IdentitiesOnly=yes', 'StrictHostKeyChecking=accept-new'):
    if needed not in options: sys.stderr.write('stand-in ssh: missing -o %s\n' % needed); sys.exit(255)
pod = None
for name in os.listdir(os.path.join(STATE, 'pods')):
    if name.endswith('.json'):
        with open(os.path.join(STATE, 'pods', name)) as f: candidate = json.load(f)
        if candidate.get('sshPort') == port: pod = candidate
if not pod or pod.get('status') != 'RUNNING' or not destination.endswith('@127.0.0.1'):
    sys.stderr.write('ssh: connect to host port %d: Connection refused\n' % port); sys.exit(255)
with open(identity + '.pub') as f: offered = f.read().strip()
if pod.get('env', {}).get('PUBLIC_KEY', '').strip() != offered:
    sys.stderr.write('root@127.0.0.1: Permission denied (publickey).\n'); sys.exit(255)
env = {'HOME': pod['root'], 'PATH': os.path.dirname(sys.executable) + ':/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C'}
done = subprocess.run(['bash', '-c', remote], cwd=pod['root'], env=env, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr, start_new_session=True)
sys.exit(done.returncode)
