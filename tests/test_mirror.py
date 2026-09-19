import json, os, select, shutil, subprocess, sys, tempfile

# Open-document mirror (hack H4): a dependency that is open and edited unsaved
# must be analyzed from the editor buffer, not stale disk bytes. Without the
# mirror, `app.d` keeps resolving `libValue` from the on-disk `lib.d` until the
# save.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

root = tempfile.mkdtemp(prefix='dmd-lsp-mirror-')
src = os.path.join(root, 'src')
os.makedirs(src)
lib_orig = 'module lib;\nint libValue;\n'
lib_edit = 'module lib;\nint otherValue;\n'
app = 'module app;\nimport lib;\nint x = libValue;\n'
libp = os.path.join(src, 'lib.d')
appp = os.path.join(src, 'app.d')
open(libp, 'w').write(lib_orig)
open(appp, 'w').write(app)
luri = 'file://' + libp
auri = 'file://' + appp

proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + src],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL)

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

def diags_for(uri):
    while True:
        m = read_msg()
        if m is None:
            return []
        if m.get('method') == 'textDocument/publishDiagnostics' \
                and m.get('params', {}).get('uri') == uri:
            return [d['message'] for d in m['params']['diagnostics']]

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": 'file://' + root,
                 "initializationOptions": {"importPaths": [src]}}})
while True:
    m = read_msg()
    if m and m.get('id') == 1:
        break
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": luri, "languageId": "d",
                                  "version": 1, "text": lib_orig}}})
diags_for(luri)
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": auri, "languageId": "d",
                                  "version": 1, "text": app}}})
before = diags_for(auri)
check('baseline-resolves', not any('libValue' in d and 'undefined' in d
                                   for d in before), str(before))

# Edit lib.d unsaved: libValue disappears. No save.
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": luri, "version": 2},
                 "contentChanges": [{"text": lib_edit}]}})
diags_for(luri)
# Force a full semantic re-analysis of the importer (save = realOnly).
send({"jsonrpc": "2.0", "method": "textDocument/didSave",
      "params": {"textDocument": {"uri": auri}}})
after = diags_for(auri)
check('unsaved-dep-reflected',
      any('libValue' in d and 'undefined' in d for d in after), str(after))

proc.stdin.close()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
shutil.rmtree(root, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
