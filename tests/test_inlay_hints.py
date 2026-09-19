import json, subprocess, sys, tempfile, os, shutil

# textDocument/inlayHint is opt-in: off by default (not advertised, empty
# result), enabled via initializationOptions/dls.json (`"inlayHints": true`).
# Shows inferred `auto` types and non-obvious call parameter names.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)


class Daemon:
    def __init__(self, args):
        self.proc = subprocess.Popen([BIN] + args, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, bufsize=0)

    def send(self, obj):
        body = json.dumps(obj).encode()
        self.proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
        self.proc.stdin.flush()

    def read(self):
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
        import select
        r, _, _ = select.select([self.proc.stdout], [], [], timeout)
        return bool(r)

    def drain(self, timeout):
        while self.ready(timeout):
            self.read()


SRC = tempfile.mkdtemp(prefix='dmd-lsp-hints-')
TEXT = ('module m;\n'
        'void f()\n{\n'
        '    auto x = 5;\n'
        '    auto s = "hi";\n'
        '    int a = 1;\n'
        '    g(a, 5);\n'
        '}\n'
        'void g(int first, int second) {}\n')
PATH = os.path.join(SRC, 'm.d')
open(PATH, 'w').write(TEXT)
URI = 'file://' + PATH


def run(enable):
    d = Daemon(['--stdio', '--import=' + SRC])
    opts = {"importPaths": [SRC]}
    if enable:
        opts["inlayHints"] = True
    d.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"rootUri": None,
                       "capabilities": {"textDocument": {"inlayHint": {}}},
                       "initializationOptions": opts}})
    init = d.read()['result']
    caps = init.get('capabilities', {})
    d.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    d.send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
            "params": {"textDocument": {"uri": URI, "languageId": "d",
                                        "version": 1, "text": TEXT}}})
    d.drain(1.0)
    d.send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/inlayHint",
            "params": {"textDocument": {"uri": URI},
                       "range": {"start": {"line": 0, "character": 0},
                                 "end": {"line": 9, "character": 0}}}})
    hints = d.read().get('result') or []
    d.proc.kill()
    got = sorted((h['position']['line'], h['position']['character'], h['label'])
                 for h in hints)
    return caps.get('inlayHintProvider') is not None, got


off_advertised, off_hints = run(False)
check('inlay-hints-advertised', off_advertised, str(off_advertised))
check('inlay-hints-off-empty', off_hints == [], str(off_hints))

on_advertised, on_hints = run(True)
check('inlay-hints-on-advertised', on_advertised, str(on_advertised))
check('inlay-hints-auto-types',
      (3, 10, ': int') in on_hints and (4, 10, ': string') in on_hints,
      str(on_hints))
check('inlay-hints-param-name',
      (6, 6, 'first:') in on_hints
      and not any(h[2] == 'second:' for h in on_hints), str(on_hints))

shutil.rmtree(SRC, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
