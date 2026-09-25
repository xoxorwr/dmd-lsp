# Typing in a large file the way VS Code drives a server: one incremental
# didChange per keystroke, and after each one the requests the editor sends on
# its own (document highlight, the code-action lightbulb, semantic tokens,
# inlay hints, the outline), plus completion on word starts and after `.`.
# The document is dmd's own expressionsem.d (17k lines, vendored in src/dmd),
# where anything that scales with the file per keystroke shows.
#
# Keystrokes must not analyse: the analysis runs once, on the debounce idle.
# Every per-keystroke op must stay far below the debounce, or the debounce can
# never be idle (it fired between every key while one op cost seconds).
import json, os, re, subprocess, sys, tempfile, threading, time

BIN = os.path.abspath('./dmd-lsp')
SRC = os.path.abspath('src')
FILE = os.path.join(SRC, 'dmd', 'expressionsem.d')
URI = 'file://' + FILE
KEY_MS = 120 # a fast typist
TYPED = 'auto t = e.type.ty;'
OP_CEILING_MS = 250 # per-keystroke ops take a few ms; they took seconds

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

err = tempfile.NamedTemporaryFile(prefix='dmd-lsp-typing-', suffix='.log', delete=False)
# The string-import paths dmd's own build uses (`import("VERSION")`, the ddoc
# theme): without them the first such import errors and cascades.
proc = subprocess.Popen([BIN, '--import=' + SRC, '--debounce-ms=500',
                         '--string-import=' + os.path.join(SRC, 'dmd'),
                         '--string-import=' + os.path.join(SRC, 'dmd', 'res')],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                        env=dict(os.environ, DMD_LSP_TIMING='1'))
lock = threading.Lock()
replies = {}

def send(obj):
    b = json.dumps(obj).encode()
    with lock:
        proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
        proc.stdin.flush()

def reader():
    f = proc.stdout
    while True:
        h = {}
        while True:
            line = f.readline()
            if not line:
                return
            line = line.decode().strip()
            if not line:
                break
            k, v = line.split(':', 1)
            h[k.lower()] = v.strip()
        m = json.loads(f.read(int(h['content-length'])))
        if 'method' in m:
            if 'id' in m: # server -> client request (refresh, registration)
                send({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
            continue
        with lock:
            replies[m['id']] = m
threading.Thread(target=reader, daemon=True).start()

rid = [0]
def request(method, params):
    rid[0] += 1
    send({'jsonrpc': '2.0', 'id': rid[0], 'method': method, 'params': params})
    return rid[0]

def wait(i, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        with lock:
            if i in replies:
                return replies.pop(i)
        time.sleep(0.002)
    return None

def notify(method, params):
    send({'jsonrpc': '2.0', 'method': method, 'params': params})

def log_since(mark):
    err.flush()
    with open(err.name) as f:
        f.seek(mark)
        return f.read()

def log_size():
    err.flush()
    return os.path.getsize(err.name)

def pos(l, c):
    return {'line': l, 'character': c}

doc = {'textDocument': {'uri': URI}}
wait(request('initialize', {'rootUri': 'file://' + SRC, 'capabilities': {
    'textDocument': {'semanticTokens': {'requests': {'full': True}},
                     'completion': {'completionItem': {'snippetSupport': True}},
                     'inlayHint': {}},
    'workspace': {'semanticTokens': {'refreshSupport': True}}}}))
notify('initialized', {})
text = open(FILE).read()
notify('textDocument/didOpen', {'textDocument': {
    'uri': URI, 'languageId': 'd', 'version': 1, 'text': text}})
for m in ('textDocument/semanticTokens/full', 'textDocument/documentSymbol'):
    wait(request(m, doc))
time.sleep(1.0)

lines = text.split('\n')
ln = next(k for k, l in enumerate(lines) if 'Expression expressionSemantic(Expression e, Scope* sc)' in l)
# Type into a new line inside the function body.
ln += 1
while '{' not in lines[ln]:
    ln += 1
indent = ' ' * 8
version = [1]
def change(l, c, t):
    version[0] += 1
    notify('textDocument/didChange', {'textDocument': {'uri': URI, 'version': version[0]},
        'contentChanges': [{'range': {'start': pos(l, c), 'end': pos(l, c)}, 'text': t}]})

mark = log_size()
change(ln, len(lines[ln]), '\n' + indent)
L, col = ln + 1, len(indent)
missing = []
mid_tokens = []
word_start = True
for ch in TYPED:
    time.sleep(KEY_MS / 1000)
    change(L, col, ch)
    col += 1
    p = dict(doc, position=pos(L, col))
    ids = []
    ident = ch.isalnum() or ch == '_'
    if ch == '.' or (ident and word_start):
        ids.append(request('textDocument/completion', p))
    word_start = not ident
    ids.append(request('textDocument/documentHighlight', p))
    ids.append(request('textDocument/codeAction', dict(doc,
        range={'start': pos(L, col), 'end': pos(L, col)},
        context={'diagnostics': [], 'triggerKind': 2})))
    tok = request('textDocument/semanticTokens/full', doc)
    ids.append(tok)
    ids.append(request('textDocument/inlayHint', dict(doc,
        range={'start': pos(L - 30, 0), 'end': pos(L + 30, 0)})))
    ids.append(request('textDocument/documentSymbol', doc))
    for i in ids:
        r = wait(i, 10)
        if r is None:
            missing.append(i)
        elif i == tok:
            mid_tokens.append(r)
typing = log_since(mark)
mark = log_size()
# Past the debounce, the build. The first after an edit also moves what the
# edit invalidated out of the cached levels (expressionsem.d is in import
# cycles with most of dmd), so wait for it rather than for a fixed time.
end = time.time() + 60
while time.time() < end and not re.search(r'\] analyze(\.patch)?: ', log_since(mark)):
    time.sleep(0.1)
time.sleep(1.0) # nothing else may follow
idle = log_since(mark)

def ops(log):
    return [(n, int(ms)) for ms, n in re.findall(r'\] op: (\d+) ms \((\w+)\)', log)]

check('every-request-answered', not missing, str(missing))
typed_analyses = re.findall(r'\] analyze(?:\.variant|\.patch)?: .*', typing)
check('no-analysis-per-keystroke', not typed_analyses, str(typed_analyses[:3]))
# A full analysis or, for an edit inside a body, a body patch.
idle_analyses = re.findall(r'\] analyze(?:\.patch)?: .*', idle)
check('one-analysis-after-typing', len(idle_analyses) == 1, str(idle_analyses))
slow = [(n, ms) for n, ms in ops(typing) if ms > OP_CEILING_MS]
check('per-keystroke-ops-fast', not slow, str(slow[:5]))
check('mid-edit-tokens-content-modified',
      mid_tokens and all(r.get('error', {}).get('code') == -32801 for r in mid_tokens),
      str(mid_tokens[:1]))
check('alive', proc.poll() is None)

proc.terminate()
try:
    proc.wait(timeout=2)
except Exception:
    proc.kill()
os.unlink(err.name)
print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
