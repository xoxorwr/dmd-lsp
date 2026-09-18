import json, os, select, shutil, subprocess, sys, tempfile, time

# Semantic-token classification that does NOT come from resolution: `module` /
# `import` path segments (namespace), `@attributes` (modifier vs decorator),
# and the lexical skips (keywords, strings incl. r""/`/q{}, comments, numbers).
# These are the parts the scanner contributes; the test pins them so a scanner
# change (e.g. moving to dmd's Lexer) cannot silently regress highlighting.

BIN = './dmd-lsp'

TYPES = ["namespace", "type", "class", "enum", "interface", "struct",
         "typeParameter", "parameter", "variable", "property", "enumMember",
         "event", "function", "method", "macro", "keyword", "modifier",
         "comment", "string", "number", "regexp", "operator", "decorator"]

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
                   "params": {"rootUri": 'file://' + root,
                              "capabilities": {"textDocument": {
                                  "semanticTokens": {}}}}})
        self.read_msg()
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def open_doc(self, path, text):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                   "params": {"textDocument": {"uri": 'file://' + path,
                                              "languageId": "d",
                                              "version": 1, "text": text}}})

    def tokens(self, path):
        self.send({"jsonrpc": "2.0", "id": 100,
                   "method": "textDocument/semanticTokens/full",
                   "params": {"textDocument": {"uri": 'file://' + path}}})
        return self.read_msg()['result']['data']

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


def decode(data, text):
    """LSP semantic-token delta array -> [(line, col, len, type, mods)]."""
    lines = text.split('\n')
    out = []
    line = 0
    col = 0
    i = 0
    while i < len(data):
        dl, dc, ln, tt, tm = data[i:i + 5]
        i += 5
        line += dl
        col = dc if dl else col + dc
        out.append((line, col, ln, TYPES[tt], tm))
    return out


def at(toks, line, col):
    for (l, c, ln, t, m) in toks:
        if l == line and c == col:
            return (ln, t, m)
    return None


root = tempfile.mkdtemp(prefix='dmd-lsp-semhints-')
os.makedirs(os.path.join(root, 'other'))
open(os.path.join(root, 'other', 'mod.d'), 'w').write(
    'module other.mod;\nclass C {}\nenum E { One }\n')

SRC = ('module hintmod;\n'
       'import std.conv;\n'
       'import other.mod : C, d = E;\n'
       '@safe int f() { return 1; }\n'
       '@custom void g() {}\n'
       '@property int p;\n'
       'void h() { f(); g(); p = 2; }\n'
       'auto s = r"raw";\n'
       'auto t = q{ token };\n'
       'auto u = `back`;\n'
       'auto v = "plain";\n'
       '// comment ident\n'
       'int x = 42;\n'
       'C c; E e;\n')
path = os.path.join(root, 'hintmod.d')
open(path, 'w').write(SRC)

d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(path, SRC)
d.drain(1.2)
toks = decode(d.tokens(path), SRC)

# module name / import path segments -> namespace
check('module-name-namespace', at(toks, 0, 7) == (7, 'namespace', 0),
      str(at(toks, 0, 7)))
check('import-segment-namespace', at(toks, 1, 7) == (3, 'namespace', 0)
      and at(toks, 1, 11) == (4, 'namespace', 0), str(at(toks, 1, 7)))
check('import-deep-segments', at(toks, 2, 7) == (5, 'namespace', 0)
      and at(toks, 2, 13) == (3, 'namespace', 0), str(at(toks, 2, 7)))
# selective-import names resolve to their declarations (cross-file symbols)
check('selective-import-class', at(toks, 2, 19) == (1, 'class', 512),
      str(at(toks, 2, 19)))
check('selective-import-enum', at(toks, 2, 26) == (1, 'enum', 512),
      str(at(toks, 2, 26)))
# @attributes: builtin -> modifier, unknown -> decorator
check('builtin-attr-modifier', at(toks, 3, 1) == (4, 'modifier', 0),
      str(at(toks, 3, 1)))
check('builtin-attr-property', at(toks, 5, 1) == (8, 'modifier', 0),
      str(at(toks, 5, 1)))
check('unknown-attr-decorator', at(toks, 4, 1) == (6, 'decorator', 0),
      str(at(toks, 4, 1)))
# declarations and uses
check('func-decl', at(toks, 3, 10) == (1, 'function', 0), str(at(toks, 3, 10)))
check('func-call', at(toks, 6, 11) == (1, 'function', 0), str(at(toks, 6, 11)))
check('var-use', at(toks, 6, 21) == (1, 'variable', 0), str(at(toks, 6, 21)))
check('cross-file-type-use', at(toks, 13, 0) == (1, 'class', 512),
      str(at(toks, 13, 0)))
# lexical skips: string prefixes/contents, comments, numbers, keywords
check('raw-string-skipped', at(toks, 7, 12) is None, str(at(toks, 7, 12)))
check('token-string-skipped', at(toks, 8, 12) is None, str(at(toks, 8, 12)))
check('backtick-skipped', at(toks, 9, 12) is None, str(at(toks, 9, 12)))
check('plain-string-skipped', at(toks, 10, 12) is None, str(at(toks, 10, 12)))
check('comment-skipped', at(toks, 11, 3) is None, str(at(toks, 11, 3)))
check('number-skipped', at(toks, 12, 8) is None, str(at(toks, 12, 8)))
check('keyword-skipped', at(toks, 3, 4) is None, str(at(toks, 3, 4)))
d.close()

# Edge cases: multi-segment module, more attributes, parameters, newlines.
SRC2 = ('module pkg.deep.thing;\n'
        'import alpha.beta;\n'
        '@nogc\n@trusted\n@system\n@disable\n@live\n@unknown\n'
        'void k(int arg)\n{\n'
        '    arg = arg + 1;\n'
        '}\n')
p2 = os.path.join(root, 'deep.d')
open(p2, 'w').write(SRC2)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(p2, SRC2)
d.drain(1.2)
t2 = decode(d.tokens(p2), SRC2)
check('module-multisegment',
      at(t2, 0, 7) == (3, 'namespace', 0) and at(t2, 0, 11) == (4, 'namespace', 0)
      and at(t2, 0, 16) == (5, 'namespace', 0), str(t2[:3]))
check('attrs-all-modifiers',
      all([at(t2, 2, 1) == (4, 'modifier', 0), at(t2, 3, 1) == (7, 'modifier', 0),
           at(t2, 4, 1) == (6, 'modifier', 0), at(t2, 5, 1) == (7, 'modifier', 0),
           at(t2, 6, 1) == (4, 'modifier', 0)]), str(t2))
check('attr-unknown-decorator', at(t2, 7, 1) == (7, 'decorator', 0),
      str(at(t2, 7, 1)))
check('param-decl', at(t2, 8, 11) == (3, 'parameter', 0), str(at(t2, 8, 11)))
check('param-use', at(t2, 10, 4) == (3, 'parameter', 0)
      and at(t2, 10, 10) == (3, 'parameter', 0), str(at(t2, 10, 4)))
d.close()

shutil.rmtree(root, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
