import json, subprocess, sys, time, os

# A typing burst with completion active must not rebuild the universe per
# keystroke. Completion keys on the neutralised analysis text, so every
# keystroke of the burst reuses one universe and returns real items; the
# builds stay bounded (didOpen + the atext build + the debounced real
# build), not one per key.

BIN = './dmd-lsp'
FILE = '/tmp/dmd-lsp-burst.d'
URI = 'file://' + FILE
ERR = '/tmp/dmd-lsp-burst.err'

errf = open(ERR, 'w')
proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=500', '--import=/tmp'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=errf, env=dict(os.environ, DMD_LSP_TIMING='1'))

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    proc.stdin.flush()

def read():
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

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None,
                 "capabilities": {"workspace": {
                     "semanticTokens": {"refreshSupport": True}}},
                 "initializationOptions": {"importPaths": ["/tmp"]}}})
read()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

def mk(t):
    return ('module burst;\n'
            'struct S { int xxxxxxxxxx; int yy; }\n'
            'void main()\n{\n'
            '    S s = S(1, 2);\n'
            '    s.' + t + '\n}\n')

open(FILE, 'w').write(mk(''))
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": mk('')}}})
time.sleep(0.3)

# Pipeline six keystrokes + completions without reading in between (what an
# editor does while the user types continuously).
ids = []
for n in range(6):
    t = 'x' * (n + 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 2 + n},
                     "contentChanges": [{"text": mk(t)}]}})
    rid = 1000 + n
    ids.append(rid)
    send({"jsonrpc": "2.0", "id": rid, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": URI},
                     "position": {"line": 5, "character": 6 + len(t)}}})

seen = {}
while len(seen) < len(ids):
    m = read()
    if m.get('method') == 'workspace/semanticTokens/refresh':
        send({"jsonrpc": "2.0", "id": m['id'], "result": None})
        continue
    if m.get('id') in ids:
        seen[m['id']] = len(m.get('result', {}).get('items', []))

last = seen.get(ids[-1])
check('burst-last-completion-has-items', last is not None and last >= 1,
      'items=%s' % last)
answered = sum(1 for r in ids if seen.get(r) is not None)
check('burst-all-completions-answered', answered == len(ids),
      'answered=%d/%d' % (answered, len(ids)))

time.sleep(0.7)
proc.stdin.close()
time.sleep(0.2)
errf.close()
analyses = open(ERR).read().count('] analyze')
# Bounded, not per-keystroke: didOpen + one atext build + one real build.
check('burst-bounded-builds', analyses <= 3, 'analyses=%d' % analyses)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
