# Dependency levels (docs/design.md): library code (druntime/Phobos) gets a
# level of its own that edits never rebuild, and the project's dependencies
# are planned from the import graph, so a module that reaches the edited
# document through an import cycle is analysed above it without being
# "learned" back into the dependency level every time (which rebuilt it on
# every analysis).
import json, os, re, shutil, subprocess, sys, tempfile, threading, time

BIN = os.path.abspath('./dmd-lsp')
ROOT = tempfile.mkdtemp(prefix='dmd-lsp-levels-')
FILES = {
    'a.d': 'module a;\nimport b;\nimport c;\nimport std.algorithm : max;\nint fa() { return fb() + fc() + max(1, 2); }\n'
           'static assert(is(b.FA == typeof(fa())), "b is stale");\n',
    'b.d': 'module b;\nimport a;\nint fb() { return 1; }\nalias FA = typeof(fa());\n',
    'c.d': 'module c;\nimport std.string : strip;\nint fc() { return cast(int) strip(" x ").length; }\n',
}
for n, t in FILES.items():
    open(os.path.join(ROOT, n), 'w').write(t)
A = os.path.join(ROOT, 'a.d')
URI = 'file://' + A

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

err = open(os.path.join(ROOT, 'server.log'), 'w')
proc = subprocess.Popen([BIN, '--debounce-ms=100'], cwd=ROOT, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=err, env=dict(os.environ, DMD_LSP_TIMING='1'))
lock = threading.Lock()
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
            diags.append([d['message'] for d in m['params']['diagnostics'] if d.get('severity', 1) == 1])
        elif 'method' in m and 'id' in m:
            send({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
threading.Thread(target=reader, daemon=True).start()

def wait_diags(n):
    end = time.time() + 20
    while len(diags) <= n and time.time() < end:
        time.sleep(0.02)
    time.sleep(0.1)

def log():
    err.flush()
    return open(err.name).read()

send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'rootUri': 'file://' + ROOT, 'capabilities': {}}})
send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen',
      'params': {'textDocument': {'uri': URI, 'languageId': 'd', 'version': 1, 'text': FILES['a.d']}}})
wait_diags(0)
check('open-clean', diags and not diags[-1], str(diags[-1:]))
opened = len(log())
libs = re.findall(r'libraries: (\d+) modules loaded', log())
check('library-level-holds-phobos', libs and int(libs[-1]) > 0, str(libs))

# Edits outside function bodies: each is a full analysis of `a`.
text = FILES['a.d']
for k in range(4):
    text += 'int extra%d() { return %d; }\n' % (k, k)
    n = len(diags)
    send({'jsonrpc': '2.0', 'method': 'textDocument/didChange',
          'params': {'textDocument': {'uri': URI, 'version': 2 + k}, 'contentChanges': [{'text': text}]}})
    wait_diags(n)
after = log()[opened:]
full = re.findall(r'\] analyze: ', after)
deps = re.findall(r'\] deps: \d+ ms \((\S+)', after)
libs = re.findall(r'\] libs: \d+ ms \((\S+)', after)
check('four-full-analyses', len(full) == 4, str(len(full)))
check('dependencies-rebuilt-once', len(deps) <= 1, str(deps))
# The library level learns what the project's first build pulled in, with the
# one rebuild of the project level (which reloads them anyway); never alone.
check('libraries-rebuilt-with-deps-only', len(libs) <= len(deps) <= 1, str((libs, deps)))
check('still-clean', not diags[-1], str(diags[-1]))
# `b` (a cycle through `a`) is analysed with every analysis of `a`, against
# the buffer's `a`: its `FA` follows `fa`'s new return type.
n = len(diags)
send({'jsonrpc': '2.0', 'method': 'textDocument/didChange',
      'params': {'textDocument': {'uri': URI, 'version': 20},
                 'contentChanges': [{'text': text.replace('int fa()', 'string fa()').replace(
                     'return fb() + fc() + max(1, 2);', 'return "";')}]}})
wait_diags(n)
check('cycle-sees-edit', not any('stale' in m for m in diags[-1]), str(diags[-1]))

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
