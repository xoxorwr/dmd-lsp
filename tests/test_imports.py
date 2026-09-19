import json, os, select, shutil, subprocess, sys, tempfile, time

# Import-statement completion: module names after `import` (project index +
# stdlib), and a module's exported names after `import m : `.

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

def complete(uri, line, ch):
    send({"jsonrpc": "2.0", "id": 200, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": uri},
                     "position": {"line": line, "character": ch}}})
    while True:
        m = read_msg()
        if m.get('id') == 200:
            return [i['label'] for i in m['result']['items']]

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

names = complete(muri, 1, len('import std.st'))
check('import-module-completion', 'std.stdio' in names, str(names[:8]))

mems = complete(auri, 1, len('import lib : '))
check('import-selective-completion',
      'beta' in mems and 'Gamma' in mems, str(mems))
# After the partial name: only `beta`.
part = complete(auri, 1, len('import lib : be'))
check('import-selective-prefix', part == ['beta'], str(part))

proc.stdin.close()
proc.wait(timeout=5)
shutil.rmtree(root, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
