import json, os, select, shutil, subprocess, sys, tempfile, time

# Contextual (textual) completion: module names after `import`, a module's
# members after `import m : `, and `version(`/`debug(` condition identifiers.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

root = tempfile.mkdtemp(prefix='dmd-lsp-imports-')
src = os.path.join(root, 'src')
os.makedirs(src)
open(os.path.join(src, 'lib.d'), 'w').write(
    'module lib;\nint alpha;\nvoid beta() {}\nclass Gamma {}\n')
mods = 'module mods;\nimport std.st\n'
app = 'module app;\nimport lib : be\nvoid f() {}\n'
mpath = os.path.join(src, 'mods.d')
apath = os.path.join(src, 'app.d')
open(mpath, 'w').write(mods)
open(apath, 'w').write(app)
muri = 'file://' + mpath
auri = 'file://' + apath

proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + src],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL)

def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    proc.stdin.flush()

def read_msg(timeout=60):
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

def complete_items(uri, line, ch):
    send({"jsonrpc": "2.0", "id": 200, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": uri},
                     "position": {"line": line, "character": ch}}})
    while True:
        m = read_msg()
        if m.get('id') == 200:
            return m['result']['items']

def complete(uri, line, ch):
    return [i['label'] for i in complete_items(uri, line, ch)]

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": 'file://' + root, "capabilities": {}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": muri, "languageId": "d",
                                  "version": 1, "text": mods}}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": auri, "languageId": "d",
                                  "version": 1, "text": app}}})
time.sleep(1)
while read_msg(0.3):
    pass

items = complete_items(muri, 1, len('import std.st'))
names = [i['label'] for i in items]
check('import-module-completion', 'std.stdio' in names, str(names[:8]))
# The edit must replace the whole typed path (`std.st`), not just `st`.
it = next((i for i in items if i['label'] == 'std.stdio'), None)
check('import-module-edit',
      it is not None and it.get('textEdit', {}).get('newText') == 'std.stdio'
      and it['textEdit']['range']['start'] == {'line': 1, 'character': 7}
      and it['textEdit']['range']['end'] == {'line': 1, 'character': 13},
      str(it))

mems = complete(auri, 1, len('import lib : '))
check('import-selective-completion',
      'beta' in mems and 'Gamma' in mems, str(mems))
# After the partial name: only `beta`.
part = complete(auri, 1, len('import lib : be'))
check('import-selective-prefix', part == ['beta'], str(part))

# `version(`/`debug(` conditions: predefined identifiers + project declarations.
ver = ('module ver;\n'
       'version = Custom;\n'
       'version(li\n'
       'version(Cu\n'
       'void f() {}\n')
vpath = os.path.join(src, 'ver.d')
open(vpath, 'w').write(ver)
vuri = 'file://' + vpath
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": vuri, "languageId": "d",
                                  "version": 1, "text": ver}}})
time.sleep(0.5)
while read_msg(0.3):
    pass
check('version-predefined',
      complete(vuri, 2, len('version(li')) == ['linux'], '')
check('version-user-declared',
      complete(vuri, 3, len('version(Cu')) == ['Custom'], '')

# Function-scoped `import`: its symbols are in scope from the declaration to
# the end of the enclosing function, and must not leak into sibling functions.
li = ('module licomp;\n'
      'void withImport()\n'
      '{\n'
      '    import lib;\n'
      '    al\n'
      '}\n'
      'void plain()\n'
      '{\n'
      '    al\n'
      '}\n')
lpath = os.path.join(src, 'licomp.d')
open(lpath, 'w').write(li)
luri = 'file://' + lpath
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": luri, "languageId": "d",
                                  "version": 1, "text": li}}})
time.sleep(0.5)
while read_msg(0.3):
    pass
inscope = complete(luri, 4, len('    al'))
check('local-import-in-scope', 'alpha' in inscope, str(inscope))
outscope = complete(luri, 8, len('    al'))
check('local-import-sibling-out-of-scope', 'alpha' not in outscope,
      str(outscope))

proc.stdin.close()
proc.wait(timeout=5)
shutil.rmtree(root, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
