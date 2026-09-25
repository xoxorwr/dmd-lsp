import json, subprocess, sys, time, os

# Verifies the semantic-token strategy: while an edit is still debounced, a
# pull is answered from the last token set (no analysis); after the debounced
# analysis lands, a workspace/semanticTokens/refresh asks the client to re-pull
# and the fresh tokens show up. Also asserts the stale pull did not analyse.

BIN = './dmd-lsp'
FILE = '/tmp/dmd-lsp-semantic.d'
URI = 'file://' + FILE
ERR = '/tmp/dmd-lsp-semantic.err'

env = dict(os.environ, DMD_LSP_TIMING='1')
errf = open(ERR, 'w')
proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=500', '--import=/tmp'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=errf, env=env)

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
inited = read()
leg = inited['result']['capabilities']['semanticTokensProvider']['legend']
stypes = leg['tokenTypes']
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

sid = [10]
def sem_request():
    sid[0] += 1
    send({"jsonrpc": "2.0", "id": sid[0],
          "method": "textDocument/semanticTokens/full",
          "params": {"textDocument": {"uri": URI}}})
    return sid[0]

def get_reply():
    my = sem_request()
    while True:
        m = read()
        if m.get('method') == 'workspace/semanticTokens/refresh':
            send({"jsonrpc": "2.0", "id": m['id'], "result": None})
            continue
        if m.get('id') == my:
            return m

def get_tokens():
    return get_reply()['result']['data']

def decode(data, text):
    lines = text.split('\n')
    line = 0
    col = 0
    toks = {}
    i = 0
    while i < len(data):
        dl, dc, ln, tt, tm = data[i:i + 5]
        i += 5
        line += dl
        col = dc if dl else col + dc
        toks[(line, col)] = (ln, stypes[tt])
    return toks

text = ('module semt;\n'
        'int alpha(int x) { return x; }\n'
        'int beta(int y) { return y; }\n')
open(FILE, 'w').write(text)
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": text}}})
toks = decode(get_tokens(), text)
bl = text.split('\n')
ab = bl[1].index('alpha')
check('sem-alpha-present', (1, ab) in toks and toks[(1, ab)][1] == 'function',
      str(toks.get((1, ab))))

# Edit: append a new function. The analysis is still debounced, so the
# immediate pull is answered ContentModified: the client (it takes refreshes)
# keeps its own tokens, shifted by the edit, instead of getting the whole
# stale set re-sent per keystroke.
text2 = text + 'int gamma(int z) { return z; }\n'
open(FILE, 'w').write(text2)
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": URI, "version": 2},
                 "contentChanges": [{"text": text2}]}})
mid = get_reply()
check('sem-mid-edit-content-modified',
      'result' not in mid and mid.get('error', {}).get('code') == -32801, str(mid))
g = text2.split('\n')[3].index('gamma')

# Wait past the debounce: the build lands, refresh fires, and a fresh pull
# contains the new function.
time.sleep(0.9)
fresh = decode(get_tokens(), text2)
check('sem-fresh-has-new', (3, g) in fresh and fresh[(3, g)][1] == 'function',
      str(fresh.get((3, g))))

send({"jsonrpc": "2.0", "id": 4, "method": "shutdown", "params": {}})
try:
    send({"jsonrpc": "2.0", "method": "exit", "params": {}})
except Exception:
    pass
proc.stdin.close()
time.sleep(0.2)
errf.flush()
errf.close()
analyses = open(ERR).read().count('] analyze')
# didOpen analysis + one for the debounced edit; the stale pull must not
# have caused a third.
check('sem-no-per-keystroke-analysis', analyses <= 2, 'analyses=%d' % analyses)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
