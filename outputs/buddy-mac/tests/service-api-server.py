#!/usr/bin/env python3
"""Offline stand-in for connected services, for tests/ServiceLeases.swift: a RunPod-shaped API under /v2 (a CPU catalog, pods that start
PROVISIONING and are RUNNING with an SSH address after two looks, DELETE terminates) and a plain notes API under /notes/v1. It listens on
127.0.0.1 only and writes its port to BUDDY_SERVICE_PORT_FILE. Each pod's machine is a folder under BUDDY_SERVICE_STATE/pods/<id>/root,
which tests/service-ssh.py runs commands in. A key is checked by its SHA-256 (BUDDY_SERVICE_KEY_SHA for /v2 as Authorization: Bearer,
BUDDY_NOTES_KEY_SHA for /notes as X-API-Key); no header value is ever logged, only whether the key was right. Every request goes to
BUDDY_SERVICE_STATE/requests.jsonl. control.json in the state folder changes behaviour: {"create": 402} refuses the next create,
{"deleteFails": n} answers the next n deletes with HTTP 500."""
import hashlib, json, os, signal, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE = os.environ['BUDDY_SERVICE_STATE']
lock = threading.Lock()
pods = {}
counter = [0]

def sha(text): return hashlib.sha256(text.encode()).hexdigest()
def log(entry):
    with open(os.path.join(STATE, 'requests.jsonl'), 'a') as f: f.write(json.dumps(entry) + '\n')
def control():
    try:
        with open(os.path.join(STATE, 'control.json')) as f: return json.load(f)
    except (OSError, ValueError): return {}
def set_control(value):
    with open(os.path.join(STATE, 'control.json'), 'w') as f: json.dump(value, f)
def save(pod):
    with open(os.path.join(STATE, 'pods', pod['id'] + '.json'), 'w') as f: json.dump(pod, f)
def public(pod):
    out = {k: v for k, v in pod.items() if k not in ('polls', 'root', 'sshPort')}
    running = pod['status'] == 'RUNNING'
    out['ssh'] = {'proxy': None, 'direct': {'host': '127.0.0.1', 'port': pod['sshPort'], 'username': 'root', 'command': 'ssh root@127.0.0.1 -p %d' % pod['sshPort']} if running else None}
    out['cost'] = pod['cost'] if pod['status'] in ('PROVISIONING', 'STARTING', 'RUNNING') else 0
    return out
def stop_machine(pod):
    """Terminating a pod stops everything its commands started (each was its own process group)."""
    for folder, _, files in os.walk(pod['root']):
        for name in files:
            if name in ('pid', 'watch.pid'):
                try:
                    with open(os.path.join(folder, name)) as f: pid = int(f.read().strip())
                    os.killpg(pid, signal.SIGKILL)
                except (OSError, ValueError): pass

CATALOG = {'cpus': [
    {'id': 'cpu3c-2-4', 'name': 'Compute-Optimized', 'group': 'Gen 3', 'vcpu': {'min': 2, 'max': 32}, 'ramGbPerVcpu': 2.5, 'price': {'securePerVcpu': 0.04, 'serverlessPerVcpu': 0.03}, 'availability': 'HIGH'},
    {'id': 'cpu3g-2-8', 'name': 'General Purpose', 'group': 'Gen 3', 'vcpu': {'min': 2, 'max': 64}, 'ramGbPerVcpu': 4, 'price': {'securePerVcpu': 0.05, 'serverlessPerVcpu': 0.04}, 'availability': 'MEDIUM'}]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, status, value=None, headers=None):
        data = b'' if value is None else json.dumps(value).encode()
        self.send_response(status)
        if value is not None: self.send_header('Content-Type', 'application/problem+json' if status >= 400 else 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Set-Cookie', 'session=fixture-cookie')
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        if data: self.wfile.write(data)
    def handle_any(self, method):
        url = urlparse(self.path); path = url.path
        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length) if length else b''
        try: body = json.loads(raw) if raw else None
        except ValueError: body = '<not json>'
        if path.startswith('/notes/'):
            auth = sha(self.headers.get('X-API-Key', '')) == os.environ.get('BUDDY_NOTES_KEY_SHA')
        else:
            header = self.headers.get('Authorization', '')
            auth = header.startswith('Bearer ') and sha(header[7:]) == os.environ.get('BUDDY_SERVICE_KEY_SHA')
        log({'method': method, 'path': path, 'query': parse_qs(url.query), 'body': body, 'auth': auth, 'headerNames': sorted(self.headers.keys())})
        if not auth: return self.reply(401, {'title': 'Unauthorized', 'status': 401, 'detail': 'invalid api key'})
        with lock:
            if path == '/notes/v1/items' and method == 'POST': return self.reply(201, {'id': 'note-1', 'text': (body or {}).get('text')})
            if path == '/notes/v1/items' and method == 'GET': return self.reply(200, {'items': []})
            if path == '/v2/catalog/cpus' and method == 'GET': return self.reply(200, CATALOG)
            if path == '/v2/pods' and method == 'GET': return self.reply(200, {'pods': [public(p) for p in pods.values()], 'pagination': {}})
            if path == '/v2/pods' and method == 'POST':
                c = control()
                if c.get('create'):
                    status = c.pop('create'); set_control(c)
                    return self.reply(status, {'title': 'Payment Required', 'status': status, 'detail': 'Insufficient balance to start this pod.'})
                counter[0] += 1
                pid = 'pod%02dfixture' % counter[0]
                root = os.path.join(STATE, 'pods', pid, 'root'); os.makedirs(root, exist_ok=True)
                cpu = (body or {}).get('cpu', {})
                pod = {'id': pid, 'name': (body or {}).get('name', ''), 'status': 'PROVISIONING', 'image': (body or {}).get('image', ''), 'cpu': cpu, 'env': (body or {}).get('env', {}),
                       'cost': round(0.04 * cpu.get('vcpuCount', 2), 4), 'polls': 0, 'root': root, 'sshPort': 40000 + counter[0]}
                pods[pid] = pod; save(pod)
                return self.reply(201, public(pod))
            if path.startswith('/v2/pods/'):
                pid = path.split('/')[3]
                pod = pods.get(pid)
                if not pod: return self.reply(404, {'title': 'Not Found', 'status': 404, 'detail': 'resource not found'})
                if method == 'GET':
                    pod['polls'] += 1
                    if pod['status'] != 'TERMINATED': pod['status'] = 'RUNNING' if pod['polls'] >= 2 else 'STARTING'
                    save(pod); return self.reply(200, public(pod))
                if method == 'DELETE':
                    c = control()
                    if c.get('deleteFails', 0) > 0:
                        c['deleteFails'] -= 1; set_control(c)
                        return self.reply(500, {'title': 'Internal Server Error', 'status': 500, 'detail': 'try again'})
                    pod['status'] = 'TERMINATED'; save(pod); stop_machine(pod)
                    return self.reply(204)
            return self.reply(404, {'title': 'Not Found', 'status': 404, 'detail': 'no such route'})
    def do_GET(self): self.handle_any('GET')
    def do_POST(self): self.handle_any('POST')
    def do_DELETE(self): self.handle_any('DELETE')
    def do_PUT(self): self.handle_any('PUT')
    def do_PATCH(self): self.handle_any('PATCH')
    def do_HEAD(self): self.handle_any('HEAD')

os.makedirs(os.path.join(STATE, 'pods'), exist_ok=True)
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(os.environ['BUDDY_SERVICE_PORT_FILE'] + '.tmp', 'w') as f: f.write(str(server.server_address[1]))
os.replace(os.environ['BUDDY_SERVICE_PORT_FILE'] + '.tmp', os.environ['BUDDY_SERVICE_PORT_FILE'])
signal.signal(signal.SIGTERM, lambda *a: (stop_all(), sys.exit(0)))
def stop_all():
    for pod in pods.values(): stop_machine(pod)
try: server.serve_forever()
finally: stop_all()
