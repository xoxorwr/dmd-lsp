import json, subprocess, sys, time, os

# Growing a member name (`s.a`, `s.al`, `s.alp`, ...) neutralises to the same
# analysis text (`s.__dmd_lsp_ph()`), so completion must reuse one universe
# instead of rebuilding per keystroke. The worker key is the analysis text
# (server.serverWouldHitAnalysis), not the document identity.

BIN = './dmd-lsp'
FILE = '/tmp/dmd-lsp-prefix.d'
URI = 'file://' + FILE
ERR = '/tmp/dmd-lsp-prefix.err'

errf = open(ERR, 'w')
proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=400', '--import=/tmp'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=errf, env=dict(os.environ, DMD_LSP_TIMING='1'))

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

# A `.` completion appends built-in properties (`alignof`, `init`, ...); this
# test is about filtering the *members* of the chain, so drop them.
BUILTIN_PROPS = {
    'init', 'sizeof', 'alignof', 'mangleof', 'stringof', 'max', 'min',
    'length', 'ptr', 'dup', 'idup', 'capacity', 'reserve', 'reverse', 'sort',
    'keys', 'values', 'byKey', 'byValue', 'byKeyValue', 'rehash', 'get',
    'require', 'update', 'min_normal', 'nan', 'infinity', 'epsilon', 'dig',
    'mant_dig', 'max_10_exp', 'min_10_exp', 'max_exp', 'min_exp', 'tupleof',
    'classinfo',
}

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

def analyses():
    errf.flush()
    return open(ERR).read().count('] analyze')

# Advertise semantic tokens too: it turns on the token precompute, which is
# what clobbered the completion universe when the idle flush fired between
# keystrokes. With the idle clock restarting after each handled request, that
# must not happen.
send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None,
                 "capabilities": {
                     "textDocument": {"semanticTokens": {}},
                     "workspace": {"semanticTokens": {"refreshSupport": True}}},
                 "initializationOptions": {"importPaths": ["/tmp"]}}})
read()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

def mk(t):
    return ('module prefix;\n'
            'struct S { int alpha; int alpine; int beta; }\n'
            'void main()\n{\n'
            '    S s = S(1, 2, 3);\n'
            '    s.' + t + '\n}\n')

open(FILE, 'w').write(mk(''))
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": mk('')}}})
read()
time.sleep(0.3)
before = analyses()

counts = []
for i, ch in enumerate('alpin'):
    t = 'alpin'[:i + 1]
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 2 + i},
                     "contentChanges": [{"text": mk(t)}]}})
    rid = 100 + i
    send({"jsonrpc": "2.0", "id": rid, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": URI},
                     "position": {"line": 5, "character": 6 + len(t)}}})
    while True:
        m = read()
        if m.get('method') == 'workspace/semanticTokens/refresh':
            send({"jsonrpc": "2.0", "id": m['id'], "result": None})
            continue
        if m.get('id') == rid:
            labels = [i['label'] for i in m.get('result', {}).get('items', [])]
            counts.append(len([l for l in labels if l not in BUILTIN_PROPS]))
            break

after = analyses()
check('prefix-one-build', after - before <= 1, 'extra_analyses=%d' % (after - before))
check('prefix-filtering', counts == [2, 2, 2, 1, 1], str(counts))

# A partial identifier *after other code* (`auto x = al`) must also
# neutralise to one buffer; otherwise every keystroke rebuilds.
URI2 = 'file:///tmp/dmd-lsp-prefix2.d'
FILE2 = '/tmp/dmd-lsp-prefix2.d'
def mk2(t):
    return ('module prefix2;\n'
            'struct S { int alpha; int alpine; int beta; }\n'
            'void main()\n{\n'
            '    S s;\n'
            '    auto x = ' + t + '\n}\n')
open(FILE2, 'w').write(mk2(''))
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI2, "languageId": "d",
                                 "version": 1, "text": mk2('')}}})
read()
time.sleep(0.3)
before = analyses()
for i, ch in enumerate('alpin'):
    t = 'alpin'[:i + 1]
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI2, "version": 2 + i},
                     "contentChanges": [{"text": mk2(t)}]}})
    rid = 200 + i
    send({"jsonrpc": "2.0", "id": rid, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": URI2},
                     "position": {"line": 5, "character": 13 + len(t)}}})
    while True:
        m = read()
        if m.get('method') == 'workspace/semanticTokens/refresh':
            send({"jsonrpc": "2.0", "id": m['id'], "result": None})
            continue
        if m.get('id') == rid:
            break
after = analyses()
check('word-after-code-one-build', after - before <= 1,
      'extra_analyses=%d' % (after - before))

proc.stdin.close()
time.sleep(0.2)
errf.close()

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
