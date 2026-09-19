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
        'struct Data { int v; }\n'
        'struct Box(T) { T v; }\n'
        'void g(int first, int second) {}\n'
        'void take(Data d) {}\n'
        'void takeBox(Box!int b) {}\n'
        'int makeData() { return 0; }\n'
        'int makeT(T)(T x) { return 0; }\n'
        'void f()\n{\n'
        '    auto x = 5;\n'
        '    auto s = "hi";\n'
        '    int a = 1;\n'
        '    take(Data());\n'
        '    takeBox(Box!int());\n'
        '    g(a, 5);\n'
        '    g(makeData(), makeT!(int)(1));\n'
        '}\n')
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
                                 "end": {"line": 17, "character": 0}}}})
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
      (10, 10, ': int') in on_hints and (11, 10, ': string') in on_hints,
      str(on_hints))
check('inlay-hints-param-name',
      (15, 6, 'first:') in on_hints
      and not any(h[2] == 'second:' and h[0] == 15 for h in on_hints),
      str(on_hints))
# The hint goes before the argument, even when the argument's AST loc is the
# `(`: struct literal `Data()`, template struct `Box!int()`, template call.
check('inlay-hints-struct-literal-arg',
      (13, 9, 'd:') in on_hints, str(on_hints))
check('inlay-hints-template-arg',
      (14, 12, 'b:') in on_hints and (16, 18, 'second:') in on_hints,
      str(on_hints))

shutil.rmtree(SRC, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
