import json, subprocess, sys, tempfile, os, shutil

# Parser error recovery can extend a function's AST past its real body (an
# unterminated `.` swallows following functions), and the pre-semantic
# snapshot keys local scope off function ranges. Snapshot scopes are therefore
# bounded with the lexer's matching body brace: a recovered/merged function
# must never offer a following function's locals, and braces inside strings or
# nested lambdas must not confuse the bound.

BIN = './dmd-lsp'

def run(text, markers):
    root = tempfile.mkdtemp(prefix='dmd-lsp-recovery-')
    path = os.path.join(root, 'sc.d')
    open(path, 'w').write(text)
    uri = 'file://' + path
    proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + root],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)

    def send(obj):
        body = json.dumps(obj).encode()
        proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
        proc.stdin.flush()

    def read():
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

    def complete(line, ch):
        send({"jsonrpc": "2.0", "id": 900, "method": "textDocument/completion",
              "params": {"textDocument": {"uri": uri},
                         "position": {"line": line, "character": ch}}})
        while True:
            m = read()
            if m.get('id') == 900:
                it = m['result']
                return [i['label'] for i in (it.get('items', []) if isinstance(it, dict) else it)]

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"rootUri": None, "capabilities": {},
                     "initializationOptions": {"importPaths": [root]}}})
    read()
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": uri, "languageId": "d",
                                     "version": 1, "text": text}}})
    read()

    lines = text.split('\n')
    out = {}
    for name, marker in markers.items():
        ln = next(i for i, l in enumerate(lines) if marker in l)
        indent = len(lines[ln]) - len(lines[ln].lstrip())
        out[name] = complete(ln, indent)  # plain completion at the statement start
    proc.stdin.close()
    proc.wait(timeout=5)
    shutil.rmtree(root, ignore_errors=True)
    return out


fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)


HEAD = ('module sc;\n'
        'struct Point { int x; int y; }\n')

# 1) Recovery merge: `p.` in `a` swallows `b`, but `b`'s locals must not appear
# as in-scope when completing inside `b`.
MERGE = (HEAD +
         'void a()\n{\n    Point p;\n    int aLocal = 1;\n    p.\n}\n'
         'void b()\n{\n    Point p2;\n    int bLocal = 2;\n    int zb = p2.x;\n}\n')
r = run(MERGE, {'a': 'int aLocal', 'b': 'int bLocal'})
check('merge-keeps-own-scope', 'aLocal' in r['a'] and 'p' in r['a'],
      str(sorted(set(r['a']) & {'aLocal', 'bLocal', 'p', 'p2'})))
check('merge-no-forward-leak', 'aLocal' not in r['b'] and 'p' not in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 2) Valid file regression: each function scopes only its own locals.
VALID = (HEAD +
         'void a()\n{\n    Point p;\n    int aLocal = 1;\n    int za = p.x;\n}\n'
         'void b()\n{\n    Point p2;\n    int bLocal = 2;\n    int zb = p2.x;\n}\n')
r = run(VALID, {'a': 'int aLocal', 'b': 'int bLocal'})
check('valid-a-scope', 'aLocal' in r['a'] and 'p' in r['a'] and 'bLocal' not in r['a'],
      str(sorted(set(r['a']) & {'aLocal', 'bLocal', 'p', 'p2'})))
check('valid-b-scope', 'bLocal' in r['b'] and 'p2' in r['b'] and 'aLocal' not in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 3) Nested delegate/lambda braces in the collapsed body must not shift the
# matching close brace.
LAMBDA = (HEAD +
          'void a()\n{\n    Point p;\n    int aLocal = 1;\n'
          '    auto f = () { Point q; return q; };\n'
          '    auto g = delegate int() { return aLocal; };\n'
          '    p.\n}\n'
          'void b()\n{\n    Point p2;\n    int bLocal = 2;\n    int zb = p2.x;\n}\n')
r = run(LAMBDA, {'a': 'int aLocal', 'b': 'int bLocal'})
check('lambda-keeps-own-scope', 'aLocal' in r['a'] and 'p' in r['a'],
      str(sorted(set(r['a']) & {'aLocal', 'bLocal', 'p', 'p2'})))
check('lambda-no-forward-leak', 'aLocal' not in r['b'] and 'p' not in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 4) Braces inside a string literal are not syntactic braces.
STRING = (HEAD +
          'void a()\n{\n    Point p;\n    string s = "}{";\n    int aLocal = 1;\n    p.\n}\n'
          'void b()\n{\n    Point p2;\n    int bLocal = 2;\n    int zb = p2.x;\n}\n')
r = run(STRING, {'a': 'int aLocal', 'b': 'int bLocal'})
check('string-brace-keeps-own-scope', 'aLocal' in r['a'] and 'p' in r['a'],
      str(sorted(set(r['a']) & {'aLocal', 'bLocal', 'p', 'p2'})))
check('string-brace-no-forward-leak', 'aLocal' not in r['b'] and 'p' not in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 5) Missing opening brace: the snapshot must degrade to no body scope rather
# than trust the recovered AST end. The request must still be answered.
NOBRACE = (HEAD +
           'void a()\n    Point p;\n    int aLocal = 1;\n'
           'void b()\n{\n    Point p2;\n    int bLocal = 2;\n}\n')
r = run(NOBRACE, {'b': 'int bLocal'})
check('missing-brace-responds', isinstance(r['b'], list) and 'bLocal' in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 6) Siblings that share an enclosing brace (struct members) must not be
# treated as one region: a's locals must not appear in b.
STRUCT = (HEAD +
          'struct S\n{\n'
          '    void a()\n    {\n        Point p;\n        int aLocal = 1;\n        p.\n    }\n'
          '    void b()\n    {\n        Point p2;\n        int bLocal = 2;\n        int zb = p2.x;\n    }\n'
          '}\n')
r = run(STRUCT, {'a': 'int aLocal', 'b': 'int bLocal'})
check('sibling-struct-no-leak', 'aLocal' not in r['b'] and 'p' not in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))
check('sibling-struct-own-scope', 'bLocal' in r['b'] and 'p2' in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 7) Siblings under a conditional ancestor (version block) likewise.
VERSION = (HEAD +
           'version (X)\n{\n'
           '    void a()\n    {\n        Point p;\n        int aLocal = 1;\n        p.\n    }\n'
           '    void b()\n    {\n        Point p2;\n        int bLocal = 2;\n        int zb = p2.x;\n    }\n'
           '}\n')
r = run(VERSION, {'a': 'int aLocal', 'b': 'int bLocal'})
check('sibling-version-no-leak', 'aLocal' not in r['b'] and 'p' not in r['b'],
      str(sorted(set(r['b']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 8) Module scope has no enclosing brace, so the fallback must be gated: no
# function locals may leak into completion between top-level declarations.
r = run(MERGE, {'a': 'int aLocal', 'b': 'int bLocal', 'mod': 'struct Point'})
check('module-scope-gated',
      not ({'aLocal', 'bLocal', 'p', 'p2'} & set(r['mod'])),
      str(sorted(set(r['mod']) & {'aLocal', 'bLocal', 'p', 'p2'})))

# 9) Nested function descent is gated by lexical body too: inside `inner` its
# locals are in scope; after `inner` (still in `outer`) they are not.
NESTED = (HEAD +
          'void outer()\n{\n    int outerLocal = 1;\n'
          '    void inner()\n    {\n        int innerLocal = 2;\n        int z = innerLocal;\n    }\n'
          '    int w = outerLocal;\n}\n')
r = run(NESTED, {'in': 'int innerLocal', 'out': 'int w = outerLocal'})
check('nested-inside-scope', 'innerLocal' in r['in'],
      str(sorted(set(r['in']) & {'innerLocal', 'outerLocal'})))
check('nested-after-scope', 'innerLocal' not in r['out'] and 'outerLocal' in r['out'],
      str(sorted(set(r['out']) & {'innerLocal', 'outerLocal'})))

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
