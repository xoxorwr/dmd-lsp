import json, subprocess, sys, time, os

# The worker is spawned once and keeps the dependency closure warm. A root
# edit is re-analysed in a fork child (copy-on-write, exits after answering),
# so completions, the debounced analyze, hover and definition after an edit
# must never spawn another worker. The regression guarded here is a
# per-edit worker rebuild (and a stale warm universe that ignores the edit).

BIN = './dmd-lsp'
URI = 'file:///tmp/spawntest.d'
TRACE = '/tmp/dmd_lsp_spawn_trace.txt'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

errf = open(TRACE, 'w')
env = dict(os.environ, DMD_LSP_TRACE_SPAWN='1')
proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=150'], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=errf, env=env)


def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    proc.stdin.flush()


def read_msg():
    headers = {}
    while True:
        line = proc.stdout.readline().decode().strip()
        if not line:
            break
        k, v = line.split(':', 1)
        headers[k.strip().lower()] = v.strip()
    n = int(headers['content-length'])
    data = b''
    while len(data) < n:
        data += proc.stdout.read(n - len(data))
    return json.loads(data)


send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# Version 0 (no trailing dot): didOpen analyzes and builds universe(text0).
v0 = 'module spawntest;\nstruct S { int x; int y; }\nvoid main()\n{\n    S s;\n    s;\n}\n'
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d", "version": 1, "text": v0}}})
read_msg()

# Version 1 (trailing dot): didChange only marks pending.
v1 = 'module spawntest;\nstruct S { int x; int y; }\nvoid main()\n{\n    S s;\n    s.\n}\n'
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": URI, "version": 2},
                 "contentChanges": [{"text": v1}]}})

# Completion before the debounce flush: builds the placeholder universe.
send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 5, "character": 6}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('trailing-dot-completion', labels == ['x', 'y'], str(labels))

# Idle flush: the analyze for v1 must reuse the completion's universe.
time.sleep(0.6)
msg = read_msg()
check('flush-publishes', msg.get('method') == 'textDocument/publishDiagnostics',
      str(msg.get('method')))

# Symbol requests for the same document must reuse that placeholder universe
# by identity (root text), not rebuild it.
send({"jsonrpc": "2.0", "id": 4, "method": "textDocument/hover",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 1, "character": 7}}})
hov = read_msg()['result']
check('hover-reuses',
      hov is not None and 'struct S' in hov['contents']['value'], str(hov))
send({"jsonrpc": "2.0", "id": 5, "method": "textDocument/definition",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 1, "character": 7}}})
dfn = read_msg()['result']
check('definition-reuses',
      dfn is not None and dfn[0]['range']['start']['line'] == 1, str(dfn))

# A semantic root edit must be picked up by the fork child (the warm parent
# still holds the pre-edit root): the added field has to show up.
v2 = v1.replace('int y; }', 'int y; int z; }')
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": URI, "version": 3},
                 "contentChanges": [{"text": v2}]}})
send({"jsonrpc": "2.0", "id": 6, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 5, "character": 6}}})
while True:
    msg = read_msg()
    if msg.get('id') == 6:
        break
labels = [i['label'] for i in msg['result']['items']]
check('edit-reflected', labels == ['x', 'y', 'z'], str(labels))

send({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
proc.stdin.close()
proc.wait(timeout=5)
errf.close()

spawns = sum(1 for line in open(TRACE) if 'spawn' in line)
# Exactly one worker: didOpen's build warms it, and everything after runs in
# fork children. More than one means the edit path still rebuilds a worker.
check('warm-worker-reused', spawns == 1, 'spawns=%d' % spawns)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
