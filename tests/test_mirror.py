import json, os, select, shutil, subprocess, sys, tempfile, time

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

# `public import` forwarding must survive the warm per-root cache, including
# after the forwarded dependency is edited unsaved. papp -> pmid -> pbase.
pbase = 'module pbase;\nstruct Base { int x; }\n'
pbase2 = 'module pbase;\nstruct Base { int x; int y; }\n'
pmid = 'module pmid;\npublic import pbase;\n'
papp = ('module papp;\nimport pmid;\nvoid f()\n{\n    Base b;\n    b.\n}\n')
pbasep = os.path.join(src, 'pbase.d')
pmidp = os.path.join(src, 'pmid.d')
pappp = os.path.join(src, 'papp.d')
open(pbasep, 'w').write(pbase)
open(pmidp, 'w').write(pmid)
open(pappp, 'w').write(papp)
pbaseuri, pmiduri, pappuri = 'file://' + pbasep, 'file://' + pmidp, 'file://' + pappp

def rpc(rid, method, params):
    send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
    while True:
        m = read_msg()
        if m is None:
            return None
        if m.get('method') == 'workspace/semanticTokens/refresh':
            send({"jsonrpc": "2.0", "id": m['id'], "result": None})
            continue
        if m.get('id') == rid:
            return m.get('result')

def open_doc(uri, text):
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": uri, "languageId": "d",
                                      "version": 1, "text": text}}})
    diags_for(uri)

open_doc(pbaseuri, pbase)
open_doc(pmiduri, pmid)
open_doc(pappuri, papp)
rx = rpc(700, 'textDocument/completion',
         {"textDocument": {"uri": pappuri},
          "position": {"line": 5, "character": 6}})
labels = [i['label'] for i in (rx or {}).get('items', [])]
check('public-import-forwarded', 'x' in labels, str(labels[:8]))

# Edit the forwarded dependency unsaved; no save, no re-open of papp.
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": pbaseuri, "version": 2},
                 "contentChanges": [{"text": pbase2}]}})
diags_for(pbaseuri)
time.sleep(0.3)
rx = rpc(701, 'textDocument/completion',
         {"textDocument": {"uri": pappuri},
          "position": {"line": 5, "character": 6}})
labels2 = [i['label'] for i in (rx or {}).get('items', [])]
check('public-import-edit-reflected', 'y' in labels2, str(labels2[:10]))


proc.stdin.close()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
shutil.rmtree(root, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
