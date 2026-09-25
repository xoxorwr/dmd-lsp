# Body patches (docs/design.md): an edit inside function bodies re-analyses
# only those bodies, in place. Everything the root's analysis answers must
# follow the new text: diagnostics (new ones, and old ones moved by the lines
# the edit added), definition/hover/tokens at shifted positions, completion
# of the new body's locals. What others can see through a body (CTFE) and
# edits outside bodies must fall back to a full analysis.
import json, os, re, shutil, subprocess, sys, tempfile, threading, time

BIN = os.path.abspath('./dmd-lsp')
ROOT = tempfile.mkdtemp(prefix='dmd-lsp-patch-')
FILE = os.path.join(ROOT, 'app.d')
URI = 'file://' + FILE
LIB = '''module lib;
struct Vec { int x, y; }
int twice(int v) { return v * 2; }
'''
APP = '''module app;
import lib;

enum K = compute();
static assert(K == 3, "K changed");
int compute() { return 3; }

int helper(int x)
{
    return x + 1;
}

int user()
{
    int a = helper(2);
    Vec v;
    later();
    return a + twice(v.x);
}

void later()
{
    int z = "err";
}
'''
open(os.path.join(ROOT, 'lib.d'), 'w').write(LIB)
open(FILE, 'w').write(APP)

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

err = open(os.path.join(ROOT, 'server.log'), 'w')
proc = subprocess.Popen([BIN, '--debounce-ms=100'], cwd=ROOT, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=err, env=dict(os.environ, DMD_LSP_TIMING='1'))
lock = threading.Lock()
replies = {}
diags = []

def send(obj):
    b = json.dumps(obj).encode()
    with lock:
        proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
        proc.stdin.flush()

def reader():
    while True:
        h = {}
        while True:
            line = proc.stdout.readline()
            if not line:
                return
            line = line.decode().strip()
            if not line:
                break
            k, v = line.split(':', 1)
            h[k.lower()] = v.strip()
        m = json.loads(proc.stdout.read(int(h['content-length'])))
        if m.get('method') == 'textDocument/publishDiagnostics' and m['params']['uri'] == URI:
            diags.append(m['params']['diagnostics'])
        if 'method' in m:
            if 'id' in m:
                send({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
            continue
        replies[m['id']] = m
threading.Thread(target=reader, daemon=True).start()

rid = [0]
def request(method, params):
    rid[0] += 1
    i = rid[0]
    send({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params})
    end = time.time() + 30
    while i not in replies and time.time() < end:
        time.sleep(0.005)
    return (replies.pop(i, None) or {}).get('result')

def log_size():
    err.flush()
    return os.path.getsize(err.name)

def log_since(mark):
    err.flush()
    return open(err.name).read()[mark:]

version = [1]
cur = [APP]
def set_text(t):
    """Replace the document and wait for the debounced analysis."""
    mark = log_size()
    n = len(diags)
    version[0] += 1
    cur[0] = t
    send({'jsonrpc': '2.0', 'method': 'textDocument/didChange',
          'params': {'textDocument': {'uri': URI, 'version': version[0]},
                     'contentChanges': [{'text': t}]}})
    end = time.time() + 20
    while len(diags) == n and time.time() < end:
        time.sleep(0.02)
    time.sleep(0.1)
    return log_since(mark)

def errors():
    return [(d['range']['start']['line'], d['message']) for d in diags[-1] if d.get('severity', 1) == 1]

def pos_of(text, needle, delta=0):
    off = text.index(needle) + delta
    line = text.count('\n', 0, off)
    return {'line': line, 'character': off - (text.rfind('\n', 0, off) + 1)}

def line_of(text, needle):
    return text.count('\n', 0, text.index(needle))

TD = {'uri': URI}
request('initialize', {'rootUri': 'file://' + ROOT, 'capabilities': {
    'textDocument': {'semanticTokens': {'requests': {'full': True}}}}})
send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen',
      'params': {'textDocument': {'uri': URI, 'languageId': 'd', 'version': 1, 'text': APP}}})
end = time.time() + 20
while not diags and time.time() < end:
    time.sleep(0.02)
check('base-error', any('"err"' in m for _, m in errors()), str(errors()))

# 1) Two lines added inside `helper`: a patch; the error in `later` moves.
t1 = APP.replace('    return x + 1;', '    int q = 1;\n    int r = 2;\n    return x + 1;')
ev = set_text(t1)
check('patched', 'analyze.patch' in ev and '] analyze:' not in ev, ev.strip()[-200:])
check('old-error-moved', (line_of(t1, 'int z = "err"'), ) == tuple(l for l, m in errors() if '"err"' in m),
      str(errors()))

# 2) A new error inside the patched body, at its line.
t2 = t1.replace('    int r = 2;', '    int r = "bad";')
ev = set_text(t2)
check('patched-again', 'analyze.patch' in ev, ev.strip()[-200:])
errs = errors()
check('new-error-at-line', any(l == line_of(t2, 'int r = "bad"') and '"bad"' in m for l, m in errs), str(errs))
check('old-error-still-moved', any(l == line_of(t2, 'int z = "err"') for l, m in errs), str(errs))

# 3) Navigation at shifted positions (after the patched body).
r = request('textDocument/definition', {'textDocument': TD, 'position': pos_of(t2, 'helper(2)')})
locs = r if isinstance(r, list) else ([r] if r else [])
check('definition-into-patched', any(l.get('range', {}).get('start', {}).get('line') == line_of(t2, 'int helper(')
                                     for l in locs), str(locs))
r = request('textDocument/hover', {'textDocument': TD, 'position': pos_of(t2, 'later()', 1)})
check('hover-after-patched', r is not None and 'later' in json.dumps(r), str(r)[:200])
r = request('textDocument/definition', {'textDocument': TD, 'position': pos_of(t2, 'Vec v', 1)})
locs = r if isinstance(r, list) else ([r] if r else [])
check('definition-from-shifted', any('lib.d' in l.get('uri', '') for l in locs), str(locs))
r = request('textDocument/semanticTokens/full', {'textDocument': TD})
data = (r or {}).get('data', [])
lines = set()
ln = 0
for i in range(0, len(data), 5):
    ln += data[i]
    lines.add(ln)
toks = {}
ln = col = 0
for i in range(0, len(data), 5):
    ln += data[i]
    col = data[i + 1] if data[i] else col + data[i + 1]
    toks[(ln, col)] = data[i + 2]
lp = pos_of(t2, 'later()')
check('token-at-shifted-position', (lp['line'], lp['character']) in toks,
      str(sorted(k for k in toks if abs(k[0] - lp['line']) <= 2)))
r = request('textDocument/definition', {'textDocument': TD, 'position': pos_of(t2, 'later();')})
locs = r if isinstance(r, list) else ([r] if r else [])
check('definition-to-shifted', any(l.get('range', {}).get('start', {}).get('line') == line_of(t2, 'void later()')
                                   for l in locs), str(locs))
r = request('textDocument/documentHighlight', {'textDocument': TD, 'position': pos_of(t2, 'int z', 4)})
check('highlight-at-shifted', bool(r) and all(h['range']['start']['line'] == line_of(t2, 'int z') for h in r),
      str(r))

# 4) Completion sees the new body's locals.
t3 = t2.replace('    int r = "bad";', '    int newlocal = 5;\n    newl')
set_text(t3)
r = request('textDocument/completion', {'textDocument': TD, 'position': pos_of(t3, '    newl', 8)})
labels = [i['label'] for i in (r or {}).get('items', [])]
check('completion-new-local', 'newlocal' in labels, str(labels[:8]))

# 5) A body CTFE evaluates is part of what others see: full analysis, and the
#    compile-time value follows.
set_text(t2) # a clean base again (completion's variant replaced it)
t4 = t2.replace('int compute() { return 3; }', 'int compute() { return 4; }')
ev = set_text(t4)
check('ctfe-body-full', '] analyze:' in ev and 'body-not-swappable' in ev, ev.strip()[-300:])
check('ctfe-value-follows', any('K changed' in m for _, m in errors()), str(errors()))

# 6) Outside the bodies: full analysis.
t5 = APP + 'int added() { return 1; }\n'
ev = set_text(t5)
check('declarations-full', '] analyze:' in ev, ev.strip()[-300:])

# 7) Back to the base text through a patch: its errors, where they were.
t6 = t5.replace('    int z = "err";', '    int z = 1;')
ev = set_text(t6)
check('fix-patched', 'analyze.patch' in ev, ev.strip()[-200:])
check('fix-clears-error', not errors(), str(errors()))

check('alive', proc.poll() is None)
proc.terminate()
try:
    proc.wait(timeout=2)
except Exception:
    proc.kill()
if not fails:
    shutil.rmtree(ROOT, ignore_errors=True)
else:
    print('log:', err.name)
print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
