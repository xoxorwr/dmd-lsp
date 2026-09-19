import json, os, select, shutil, subprocess, sys, tempfile, time

# Index-build invariants (hack H3, docs/hacks.md):
#  1. building the workspace index must not evict the warm universe, and
#  2. registration-free parse must still yield fully-qualified module names.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

root = tempfile.mkdtemp(prefix='dmd-lsp-index-')
src = os.path.join(root, 'src')
os.makedirs(os.path.join(src, 'sub'))
open(os.path.join(src, 'lib.d'), 'w').write('module lib;\nstruct Point { int x; }\n')
open(os.path.join(src, 'sub', 'deep.d'), 'w').write(
    'module sub.deep;\nstruct DeepThing { int q; }\n')
app = ('module app;\nimport lib;\nvoid f()\n{\n    Point p;\n    Deep\n}\n')
apath = os.path.join(src, 'app.d')
open(apath, 'w').write(app)
auri = 'file://' + apath

errpath = os.path.join(root, 'server.err')
proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + src],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=open(errpath, 'w'),
                        env=dict(os.environ, DMD_LSP_TIMING='1'))

def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    proc.stdin.flush()

def read_msg(timeout=120):
    r, _, _ = select.select([proc.stdout], [], [], timeout)
    if not r:
        return None
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

def wait_id(i):
    while True:
        m = read_msg()
        if m is None or m.get('id') == i:
            return m

def wait_diag(uri):
    while True:
        m = read_msg()
        if m is None:
            return
        if m.get('method') == 'textDocument/publishDiagnostics' \
                and m.get('params', {}).get('uri') == uri:
            return

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": 'file://' + root,
                 "capabilities": {},
                 "initializationOptions": {"importPaths": [src],
                                           "autoImports": True}}})
wait_id(1)
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": auri, "languageId": "d",
                                  "version": 1, "text": app}}})
wait_diag(auri)

# Build the index, then use the semantic universe.
send({"jsonrpc": "2.0", "id": 5, "method": "workspace/symbol",
      "params": {"query": "Point"}})
sym = wait_id(5)
labels = [s['name'] for s in sym['result']]
check('workspace-symbol-after-index', 'Point' in labels, str(labels))

send({"jsonrpc": "2.0", "id": 6, "method": "textDocument/hover",
      "params": {"textDocument": {"uri": auri},
                 "position": {"line": 4, "character": 5}}})
wait_id(6)

time.sleep(0.3)
err = open(errpath).read()
full = err.count('analyze.full')
check('index-keeps-universe', full <= 1, 'analyze.full=%d' % full)

# Auto-import candidate must carry the fully-qualified module name (H3 parses
# without a package parent, so `indexModuleName` rebuilds it from `md.packages`).
send({"jsonrpc": "2.0", "id": 7, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": auri},
                 "position": {"line": 5, "character": 8}}})
comp = wait_id(7)
cand = next((i for i in comp['result']['items'] if i['label'] == 'DeepThing'), None)
check('index-module-fqn', cand is not None and cand.get('detail') == 'sub.deep',
      str(cand))

proc.stdin.close()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
shutil.rmtree(root, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
