import json, os, select, shutil, subprocess, sys, tempfile, time

# textDocument/documentLink: `import("...")` string imports resolve against the
# string-import paths; a missing file yields no link.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

root = tempfile.mkdtemp(prefix='dmd-lsp-links-')
src = os.path.join(root, 'src')
os.makedirs(src)
open(os.path.join(src, 'data.txt'), 'w').write('hi')
text = ('module app;\n'
        'enum s = import("data.txt");\n'
        'enum q = import("missing.txt");\n')
mpath = os.path.join(src, 'app.d')
open(mpath, 'w').write(text)
uri = 'file://' + mpath

proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + src,
                         '--string-import=' + src],
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

def drain():
    while read_msg(0.3):
        pass

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": 'file://' + root, "capabilities": {}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": uri, "languageId": "d",
                                  "version": 1, "text": text}}})
time.sleep(1)
drain()

send({"jsonrpc": "2.0", "id": 100, "method": "textDocument/documentLink",
      "params": {"textDocument": {"uri": uri}}})
links = read_msg()['result']
check('document-link-resolves',
      len(links) == 1 and links[0]['target'].endswith('/data.txt'),
      str(links))
check('document-link-range',
      bool(links) and links[0]['range']['start'] == {'line': 1, 'character': 17}
      and links[0]['range']['end'] == {'line': 1, 'character': 25}, str(links))

proc.stdin.close()
proc.wait(timeout=5)
shutil.rmtree(root, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
