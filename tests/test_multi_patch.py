# Body patches across documents (docs/design.md): every edited document the
# overlay loaded takes edits inside its bodies as patches, so switching
# between two files being edited never re-analyses either in full. What one
# document sees of the other must follow: positions into it (definition),
# its interface (a change is a full analysis), what CTFE ran (not swappable),
# and the buffer of an open document loaded later (a function-local import).
import json, os, re, shutil, subprocess, sys, tempfile, threading, time

BIN = os.path.abspath('./dmd-lsp')
ROOT = tempfile.mkdtemp(prefix='dmd-lsp-multi-')
LIB = '''module lib;

int twice(int v)
{
    return v * 2;
}

int thrice(int v)
{
    return v * 3;
}

int later()
{
    return 7;
}
'''
APP = '''module app;
import lib;

enum L = twice(2);
static assert(L == 4, "L changed");

int user()
{
    return thrice(1) + later();
}
'''
EXTRA = '''module extra;
int onDisk() { return 1; }
'''
for n, t in (('lib.d', LIB), ('app.d', APP), ('extra.d', EXTRA)):
    open(os.path.join(ROOT, n), 'w').write(t)

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
diags = {}
counts = {}

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
        if m.get('method') == 'textDocument/publishDiagnostics':
            u = m['params']['uri'].rsplit('/', 1)[-1]
            diags[u] = [(d['range']['start']['line'], d['message'])
                        for d in m['params']['diagnostics'] if d.get('severity', 1) == 1]
            counts[u] = counts.get(u, 0) + 1
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

def uri(n):
    return 'file://' + os.path.join(ROOT, n)

def log_size():
    err.flush()
    return os.path.getsize(err.name)

def log_since(mark):
    err.flush()
    return open(err.name).read()[mark:]

texts = {}
ver = {}
def open_doc(n, t):
    texts[n] = t
    ver[n] = 1
    c = counts.get(n, 0)
    send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen',
          'params': {'textDocument': {'uri': uri(n), 'languageId': 'd', 'version': 1, 'text': t}}})
    end = time.time() + 20
    while counts.get(n, 0) == c and time.time() < end:
        time.sleep(0.02)

def edit(n, t):
    """Change document `n` and wait for its debounced analysis."""
    mark = log_size()
    texts[n] = t
    ver[n] += 1
    c = counts.get(n, 0)
    send({'jsonrpc': '2.0', 'method': 'textDocument/didChange',
          'params': {'textDocument': {'uri': uri(n), 'version': ver[n]},
                     'contentChanges': [{'text': t}]}})
    end = time.time() + 20
    while counts.get(n, 0) == c and time.time() < end:
        time.sleep(0.02)
    time.sleep(0.1)
    return log_since(mark)

def line_of(t, needle):
    return t.count('\n', 0, t.index(needle))

def pos_of(t, needle, delta=0):
    off = t.index(needle) + delta
    return {'line': t.count('\n', 0, off), 'character': off - (t.rfind('\n', 0, off) + 1)}

def full(ev):
    return '] analyze: ' in ev

request('initialize', {'rootUri': 'file://' + ROOT, 'capabilities': {}})
send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
open_doc('app.d', APP)
open_doc('lib.d', LIB)
open_doc('extra.d', EXTRA)
check('base-clean', not diags.get('app.d') and not diags.get('lib.d'), str(diags))

# 1) Bodies of both files, alternately. The first edit of lib, an unedited
#    dependency until now, takes it out of the dependency level (a rebuild,
#    once); app is then analysed as a root of the new overlay (no rebuild).
#    From then on: patches only.
l1 = LIB.replace('    return v * 3;', '    int pad1 = 0;\n    int pad2 = 0;\n    return v * 3;')
ev = edit('lib.d', l1)
check('first-lib-edit-drops-dependency', re.search(r'\] deps: \d+ ms \(reaches-edited', ev), ev.strip()[-200:])
ev = edit('app.d', APP.replace('    return thrice(1) + later();', '    int local = 1;\n    return thrice(local) + later();'))
check('app-joins-overlay', 'overlay.push' not in ev and 'deps:' not in ev, ev.strip()[-200:])
l1 = l1.replace('    int pad2 = 0;', '    int pad2 = 0;\n    int pad4 = 0;')
ev = edit('lib.d', l1)
check('lib-edit-patched', 'analyze.patch' in ev and not full(ev), ev.strip()[-200:])
l2 = l1.replace('    int pad1 = 0;', '    int pad1 = 1;\n    int pad3 = 0;')
ev = edit('lib.d', l2)
check('switch-to-lib-patched', 'analyze.patch' in ev and not full(ev), ev.strip()[-200:])
ev = edit('app.d', texts['app.d'].replace('int local = 1;', 'int local = 2;'))
check('switch-back-patched', 'analyze.patch' in ev and not full(ev), ev.strip()[-200:])
check('still-clean', not diags.get('app.d') and not diags.get('lib.d'), str(diags))

# 2) A position in lib after its edited body (`later`, below `thrice`'s
#    grown body), from app: shifted.
r = request('textDocument/definition', {'textDocument': {'uri': uri('app.d')},
                                         'position': pos_of(texts['app.d'], 'later()')})
locs = r if isinstance(r, list) else ([r] if r else [])
check('definition-into-patched-import',
      any(l.get('uri', '').endswith('lib.d') and
          l.get('range', {}).get('start', {}).get('line') == line_of(texts['lib.d'], 'int later(')
          for l in locs), str(locs))

# 3) A body app evaluated at compile time (enum L = twice(2)): full, and the
#    value follows.
ev = edit('lib.d', texts['lib.d'].replace('    return v * 2;', '    return v * 5;'))
check('ctfe-body-full', full(ev) and 'analyze.patch' not in ev, ev.strip()[-300:])
edit('app.d', texts['app.d'] + '\n')  # app analysed against the new lib
check('ctfe-value-follows', any('L changed' in m for _, m in diags.get('app.d', [])),
      str(diags.get('app.d')))
edit('lib.d', texts['lib.d'].replace('    return v * 5;', '    return v * 2;'))
edit('app.d', texts['app.d'].rstrip('\n') + '\n')

# 4) lib's interface changes: full, and app reports what breaks.
ev = edit('lib.d', texts['lib.d'].replace('int thrice(int v)', 'int thrice(int v, int w)'))
check('interface-change-full', full(ev), ev.strip()[-300:])
edit('app.d', texts['app.d'] + '\n')
check('interface-change-seen', any('thrice' in m for _, m in diags.get('app.d', [])),
      str(diags.get('app.d')))
edit('lib.d', texts['lib.d'].replace('int thrice(int v, int w)', 'int thrice(int v)'))

# 5) Two documents changed within one debounce: app, whose body now imports
#    extra, analysed first, while extra (open, not loaded by the overlay) has
#    a buffer the overlay did not register. The import must read the buffer.
edit('app.d', texts['app.d'] + '\n') # a patch base for app with this overlay
texts['app.d'] = texts['app.d'].replace('    return thrice(local) + later();',
                                        '    import extra : inBuffer;\n    return thrice(local) + later() + inBuffer();')
texts['extra.d'] = EXTRA + 'int inBuffer() { return 2; }\n'
c = counts.get('app.d', 0)
for n in ('app.d', 'extra.d'):
    ver[n] += 1
    send({'jsonrpc': '2.0', 'method': 'textDocument/didChange',
          'params': {'textDocument': {'uri': uri(n), 'version': ver[n]},
                     'contentChanges': [{'text': texts[n]}]}})
end = time.time() + 20
while counts.get('app.d', 0) == c and time.time() < end:
    time.sleep(0.02)
check('local-import-reads-buffer', not diags.get('app.d'), str(diags.get('app.d')))

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
