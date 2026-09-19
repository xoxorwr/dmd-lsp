import json, os, select, shutil, subprocess, sys, tempfile, time

# textDocument/codeAction: add-import quickfix for an unresolved identifier
# (a module in the workspace index exports it and the file does not import it).

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

root = tempfile.mkdtemp(prefix='dmd-lsp-ca-')
src = os.path.join(root, 'src')
os.makedirs(src)
open(os.path.join(src, 'lib.d'), 'w').write('module lib;\n\nvoid helperFn() {}\n')
main = ('module main;\n'
        '\n'
        'void f()\n'
        '{\n'
        '    helperFn();\n'
        '    missingFn();\n'
        '    help\n'
        '}\n')
mpath = os.path.join(src, 'main.d')
open(mpath, 'w').write(main)
uri = 'file://' + mpath

proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + src],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL)

def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    proc.stdin.flush()

def read_msg(timeout=30):
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

def drain(t=0.4):
    while read_msg(t):
        pass

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": 'file://' + root, "capabilities": {}}})
check('initialize', read_msg() is not None)
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": uri, "languageId": "d",
                                  "version": 1, "text": main}}})
time.sleep(2)
drain()

send({"jsonrpc": "2.0", "id": 100, "method": "textDocument/codeAction",
      "params": {"textDocument": {"uri": uri},
                 "range": {"start": {"line": 4, "character": 4},
                           "end": {"line": 4, "character": 12}},
                 "context": {"diagnostics": []}}})
acts = read_msg()['result']
titles = [a['title'] for a in acts]
check('add-import-offered', any('helperFn' in t and 'lib' in t for t in titles),
      str(titles))
edits = []
for a in acts:
    for u, es in a.get('edit', {}).get('changes', {}).items():
        if u == uri:
            edits += es
check('add-import-edit', any(e['newText'] == 'import lib;\n' and
                             e['range']['start']['line'] == 1 for e in edits),
      str(edits))

# An identifier no module exports gets no add-import action.
send({"jsonrpc": "2.0", "id": 101, "method": "textDocument/codeAction",
      "params": {"textDocument": {"uri": uri},
                 "range": {"start": {"line": 5, "character": 4},
                           "end": {"line": 5, "character": 13}},
                 "context": {"diagnostics": []}}})
acts = read_msg()['result']
check('no-candidate-no-action',
      not any('missingFn' in a['title'] for a in acts),
      str([a['title'] for a in acts]))

# Completion auto-import: `help` offers `helperFn` from lib with the import as
# an additional edit.
send({"jsonrpc": "2.0", "id": 102, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": uri},
                 "position": {"line": 6, "character": 8}}})
items = read_msg()['result']['items']
auto = [i for i in items if i['label'] == 'helperFn' and i.get('additionalTextEdits')]
check('auto-import-completion',
      len(auto) == 1 and
      auto[0]['additionalTextEdits'][0]['newText'] == 'import lib;\n',
      str(auto))

# Implement/override: a class with unimplemented interface methods offers a
# stub per method.
shape = ('module shape;\n'
         'interface Read { void read(); int size(); }\n'
         'class Bin : Read\n'
         '{\n'
         '}\n')
spath = os.path.join(src, 'shape.d')
open(spath, 'w').write(shape)
suri = 'file://' + spath
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": suri, "languageId": "d",
                                  "version": 1, "text": shape}}})
time.sleep(1)
drain()
send({"jsonrpc": "2.0", "id": 103, "method": "textDocument/codeAction",
      "params": {"textDocument": {"uri": suri},
                 "range": {"start": {"line": 2, "character": 6},
                           "end": {"line": 2, "character": 9}},
                 "context": {"diagnostics": []}}})
acts = read_msg()['result']
titles = [a['title'] for a in acts]
check('implement-stubs-offered',
      'Implement `read`' in titles and 'Implement `size`' in titles, str(titles))
edits = []
for a in acts:
    for u, es in a.get('edit', {}).get('changes', {}).items():
        if u == suri:
            edits += es
check('implement-stub-sig',
      any(e['newText'] == '    override void read()\n    {\n    }\n' for e in edits),
      str(edits))

proc.stdin.close()
proc.wait(timeout=5)
shutil.rmtree(root, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
