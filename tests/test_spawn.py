import json, subprocess, sys, time, os

# Analysis runs in-process: the daemon keeps one warm universe and re-parses
# the root in place on edits, so nothing is ever spawned. The regression
# guarded here is a stale warm universe that ignores the edit.

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


def wpid():
    # The worker is a direct child of the server (fork/spawn). A respawn
    # replaces it, so the pid changing is the signal.
    out = subprocess.run(['pgrep', '-P', str(proc.pid)],
                         capture_output=True, text=True).stdout.split()
    return out[0] if out else '-'


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

# A trivia-only save while the universe is exactly the opened text: the
# universe must stay usable (no invalidate -> respawn). Windows runs the
# incremental re-analysis inline, so its universe advances and this branch is
# reached while typing newlines; POSIX forks, so the test drives it via a save.
v0b = v0.replace('void main()', '\nvoid main()')
send({"jsonrpc": "2.0", "method": "textDocument/didSave",
      "params": {"textDocument": {"uri": URI}, "text": v0b}})
time.sleep(0.4)
w0 = wpid()
send({"jsonrpc": "2.0", "id": 90, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 6, "character": 5}}})
while True:
    msg = read_msg()
    if msg.get('id') == 90:
        break
check('trivia-save-no-respawn', wpid() == w0, 'pid %s -> %s' % (w0, wpid()))

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
      hov is not None and 'struct spawntest.S' in hov['contents']['value'], str(hov))
send({"jsonrpc": "2.0", "id": 5, "method": "textDocument/definition",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 1, "character": 7}}})
dfn = read_msg()['result']
check('definition-reuses',
      dfn is not None and dfn[0]['range']['start']['line'] == 1, str(dfn))

# A semantic root edit must be picked up by the in-place re-parse: the added
# field has to show up. Analysis is debounce-only now, so the edit lands on the
# idle flush; completion reflects it after that (it never triggers a build).
v2 = v1.replace('int y; }', 'int y; int z; }')
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": URI, "version": 3},
                 "contentChanges": [{"text": v2}]}})
time.sleep(0.6)  # let the debounced analysis land
msg = read_msg()  # publishDiagnostics from the flush
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
# No subprocess: everything runs in-process.
check('no-subprocess', spawns == 0, 'spawns=%d' % spawns)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
