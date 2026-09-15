import json, subprocess, sys, time, os

# A completion that needs the trailing-dot placeholder must key its universe
# on the *real* document text, so the following debounced analyze for that
# same text is a hit. Otherwise every keystroke that triggers completion
# builds the file twice (once for completion, once for diagnostics).

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

send({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
proc.stdin.close()
proc.wait(timeout=5)
errf.close()

spawns = sum(1 for line in open(TRACE) if 'spawn' in line)
# One build for didOpen(v0), one for the completion/analyze of v1. A third
# means completion and the debounced analyze each built v1 (the regression).
check('one-build-per-version', spawns == 2, 'spawns=%d' % spawns)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
