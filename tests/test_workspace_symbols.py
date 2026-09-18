import json, os, select, shutil, subprocess, sys, tempfile

# workspace/symbol: parse-only index over the workspace root, query matching,
# skip hidden files, lazy rebuild after a watched change.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)


class Daemon:
    def __init__(self, args):
        self.proc = subprocess.Popen([BIN] + args, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, bufsize=0)

    def send(self, obj):
        body = json.dumps(obj).encode()
        self.proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
        self.proc.stdin.flush()

    def read_msg(self):
        headers = {}
        while True:
            line = self.proc.stdout.readline().decode().strip()
            if not line:
                break
            k, v = line.split(':', 1)
            headers[k.strip().lower()] = v.strip()
        n = int(headers['content-length'])
        data = b''
        while len(data) < n:
            data += self.proc.stdout.read(n - len(data))
        return json.loads(data)

    def ready(self, timeout):
        r, _, _ = select.select([self.proc.stdout], [], [], timeout)
        return bool(r)

    def drain(self, timeout):
        out = []
        while self.ready(timeout):
            out.append(self.read_msg())
        return out

    def init(self, root):
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"rootUri": 'file://' + root, "capabilities": {}}})
        self.read_msg()
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def workspace_symbol(self, query):
        self.send({"jsonrpc": "2.0", "id": 100, "method": "workspace/symbol",
                   "params": {"query": query}})
        return self.read_msg()['result']

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


root = tempfile.mkdtemp(prefix='dmd-lsp-wsym-')
os.makedirs(os.path.join(root, 'sub'))
open(os.path.join(root, 'lib.d'), 'w').write(
    'module lib;\nint gcount;\nint inc(int a){ return a+1; }\n'
    'struct Point { int x; int y; }\n')
open(os.path.join(root, 'sub', 'deep.d'), 'w').write(
    'module sub.deep;\nclass Shape { int id; }\nvoid move(){}\n')
open(os.path.join(root, '.hidden.d'), 'w').write('module hidden;\nint secret;\n')


def fmt(rs):
    out = []
    for r in rs or []:
        out.append((os.path.relpath(r['location']['uri'].replace('file://', ''),
                                    root), r['name'], r['kind']))
    return sorted(out)


d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.3)

check('prefix', fmt(d.workspace_symbol('Poi')) == [('lib.d', 'Point', 23)],
      str(fmt(d.workspace_symbol('Poi'))))
check('subsequence', fmt(d.workspace_symbol('Shp')) ==
      [('sub/deep.d', 'Shape', 5)], str(fmt(d.workspace_symbol('Shp'))))
check('case-insensitive', fmt(d.workspace_symbol('inc')) ==
      [('lib.d', 'inc', 12)], str(fmt(d.workspace_symbol('inc'))))
allnames = [n for (_, n, _) in fmt(d.workspace_symbol(''))]
check('all-symbols', len(allnames) == 8, str(allnames))
check('hidden-skipped', 'secret' not in allnames, str(allnames))
check('nested-container',
      any(n == 'x' for n in allnames), str(allnames))

# A watched change marks the index stale; the next query rebuilds.
with open(os.path.join(root, 'lib.d'), 'a') as f:
    f.write('struct Widget { int w; }\n')
d.send({"jsonrpc": "2.0", "method": "workspace/didChangeWatchedFiles",
        "params": {"changes": [{"uri": 'file://' + root + '/lib.d',
                                "type": 2}]}})
d.drain(0.3)
check('reindex-after-change', fmt(d.workspace_symbol('Widget')) ==
      [('lib.d', 'Widget', 23)], str(fmt(d.workspace_symbol('Widget'))))
d.close()

shutil.rmtree(root, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
