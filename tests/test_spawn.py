import json, subprocess, sys, time, os

# Analysis runs in-process on memory levels (docs/design.md): an edit drops the
# overlay and re-analyses the root on the warm levels below, so nothing is ever
# spawned. The regression guarded here is a stale analysis that ignores the edit.

BIN = './dmd-lsp'
URI = 'file:///tmp/spawntest.d'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

# A `.` completion appends built-in properties (`init`, `sizeof`, ...); the
# checks below are about the struct's members.
BUILTIN_PROPS = {
    'init', 'sizeof', 'alignof', 'mangleof', 'stringof', 'max', 'min',
    'length', 'ptr', 'dup', 'idup', 'capacity', 'reserve', 'reverse', 'sort',
    'keys', 'values', 'byKey', 'byValue', 'byKeyValue', 'rehash', 'get',
    'require', 'update', 'min_normal', 'nan', 'infinity', 'epsilon', 'dig',
    'mant_dig', 'max_10_exp', 'min_10_exp', 'max_exp', 'min_exp', 'tupleof',
    'classinfo',
}
def members_only(labels):
    return [l for l in labels if l not in BUILTIN_PROPS]

proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=150'], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    proc.stdin.flush()


def children():
    # Everything runs in the server process: it must never have a child.
    return subprocess.run(['pgrep', '-P', str(proc.pid)],
                          capture_output=True, text=True).stdout.split()


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
send({"jsonrpc": "2.0", "id": 90, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 6, "character": 5}}})
while True:
    msg = read_msg()
    if msg.get('id') == 90:
        break
check('trivia-save-no-child', not children(), str(children()))

# Version 1 (trailing dot): didChange only marks pending.
v1 = 'module spawntest;\nstruct S { int x; int y; }\nvoid main()\n{\n    S s;\n    s.\n}\n'
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": URI, "version": 2},
                 "contentChanges": [{"text": v1}]}})

# Completion before the debounce flush: builds the placeholder universe.
send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 5, "character": 6}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('trailing-dot-completion', members_only(labels) == ['x', 'y'], str(labels))

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
check('edit-reflected', members_only(labels) == ['x', 'y', 'z'], str(labels))

# No subprocess: everything runs in-process.
check('no-subprocess', not children(), str(children()))

send({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
proc.stdin.close()
proc.wait(timeout=5)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
