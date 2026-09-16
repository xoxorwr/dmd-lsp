import json, subprocess, sys, time

# A syntax error anywhere in a function makes dmd replace the whole body with
# an ErrorStatement, losing every local's semantic type. Member access on
# locals must still classify from the pre-semantic snapshot: explicit types,
# `auto x = Type(...)`, and factory calls `auto x = f!(Type)()`.

BIN = './dmd-lsp'
FILE = '/tmp/dmd-lsp-broken.d'
URI = 'file://' + FILE

HEAD = ('module brk;\n'
        'struct Point { int x; int y; }\n'
        'struct State { int alpha; int beta; }\n'
        'struct Factory { static T create(T)() { return T.init; } }\n'
        'T make(T)() { return T.init; }\n'
        'void f()\n{\n'
        '    Point p;\n'
        '    int a = p.x;\n'
        '    auto q = Point(3, 4);\n'
        '    int b = q.y;\n'
        '    auto s = Factory.create!(State)();\n'
        '    int c = s.alpha;\n'
        '    auto m = make!(State)();\n'
        '    int d = m.beta;\n')
TAIL = '}\n'


def tokens(text):
    open(FILE, 'w').write(text)
    p = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=/tmp'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL)
    def send(o):
        b = json.dumps(o).encode()
        p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
        p.stdin.flush()
    def read():
        h = {}
        while True:
            l = p.stdout.readline().decode().strip()
            if not l:
                break
            k, v = l.split(':', 1)
            h[k.strip().lower()] = v.strip()
        n = int(h['content-length'])
        d = b''
        while len(d) < n:
            d += p.stdout.read(n - len(d))
        return json.loads(d)
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"rootUri": None,
                     "capabilities": {"textDocument": {"semanticTokens": {}}},
                     "initializationOptions": {"importPaths": ["/tmp"]}}})
    init = read()
    types = init['result']['capabilities']['semanticTokensProvider']['legend']['tokenTypes']
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": URI, "languageId": "d",
                                     "version": 1, "text": text}}})
    read()
    send({"jsonrpc": "2.0", "id": 2, "method": "textDocument/semanticTokens/full",
          "params": {"textDocument": {"uri": URI}}})
    data = read()['result']['data']
    p.stdin.close()
    lines = text.split('\n')
    line = 0
    col = 0
    out = {}
    i = 0
    while i < len(data):
        dl, dc, ln, tt, tm = data[i:i + 5]
        i += 5
        line += dl
        col = dc if dl else col + dc
        out[(line, col)] = (lines[line][col:col + ln], types[tt])
    return out


valid = tokens(HEAD + '    int e = d;\n' + TAIL)
# `p.` as a statement is one of the errors that collapses the whole body.
broken = tokens(HEAD + '    p.\n' + TAIL)

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

def props(ts):
    return sorted(set(n for (n, t) in ts.values() if t == 'property'))

vp = props(valid)
bp = props(broken)
check('valid-properties', vp == ['alpha', 'beta', 'x', 'y'], str(vp))
check('broken-keeps-properties', bp == vp, 'broken=%s valid=%s' % (bp, vp))
# the broken statement itself may be dropped, but nothing above it should be
upper_valid = {k: v for k, v in valid.items() if k[0] <= 13}
upper_broken = {k: v for k, v in broken.items() if k[0] <= 13}
missing = {k: v for k, v in upper_valid.items() if k not in upper_broken}
check('broken-keeps-upper-body', not missing, str(missing))

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
