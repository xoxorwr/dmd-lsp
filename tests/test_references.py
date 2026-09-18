import json, os, select, shutil, subprocess, sys, tempfile

# textDocument/references: resolved-declaration identity across the loaded
# closure, includeDeclaration, dedupe. (Requested from a use site, whose
# universe contains the declaring module; see PLAN.md for the importer gap.)

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

    def open_doc(self, path, text):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                   "params": {"textDocument": {"uri": 'file://' + path,
                                              "languageId": "d",
                                              "version": 1, "text": text}}})

    def references(self, path, line, ch, include):
        self.send({"jsonrpc": "2.0", "id": 100,
                   "method": "textDocument/references",
                   "params": {"textDocument": {"uri": 'file://' + path},
                              "position": {"line": line, "character": ch},
                              "context": {"includeDeclaration": include}}})
        return self.read_msg()['result']

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


def fmt(refs):
    out = []
    for r in refs or []:
        out.append((os.path.basename(r['uri'].replace('file://', '')),
                    r['range']['start']['line'],
                    r['range']['start']['character'],
                    r['range']['end']['character']))
    return sorted(out)


root = tempfile.mkdtemp(prefix='dmd-lsp-refs-')
LIB = 'module lib;\nint gcount;\nint inc(int a) { return a + 1; }\n'
APP = 'module app;\nimport lib;\nvoid f()\n{\n    gcount = inc(gcount);\n}\n'
libp = os.path.join(root, 'lib.d')
appp = os.path.join(root, 'app.d')
open(libp, 'w').write(LIB)
open(appp, 'w').write(APP)

d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(libp, LIB)
d.open_doc(appp, APP)
d.drain(1.0)

# From the use site (app), both uses in app plus the declaration in lib.
r = d.references(appp, 4, 4, True)
got = fmt(r)
check('cross-file-includes-decl',
      ('lib.d', 1, 4, 10) in got and ('app.d', 4, 4, 10) in got
      and ('app.d', 4, 17, 23) in got,
      str(got))
# No duplicates (each (file,line,start) appears once).
check('no-duplicates', len(got) == len(set(got)), str(got))
# includeDeclaration=false drops the lib declaration.
got2 = fmt(d.references(appp, 4, 4, False))
check('exclude-declaration', ('lib.d', 1, 4, 10) not in got2 and len(got2) == 2,
      str(got2))
# Function reference: use site in app + declaration in lib.
got3 = fmt(d.references(appp, 4, 13, True))
check('function-refs',
      ('lib.d', 2, 4, 7) in got3 and ('app.d', 4, 13, 16) in got3,
      str(got3))
# From the *declaration* file, importer uses must still be found (index-wide).
got4 = fmt(d.references(libp, 1, 4, True))
check('decl-finds-importers',
      ('lib.d', 1, 4, 10) in got4 and ('app.d', 4, 4, 10) in got4
      and ('app.d', 4, 17, 23) in got4,
      str(got4))
d.close()

# Sibling scopes reuse a name; each resolves to its own declaration.
shadow = ('module s;\n'
          'void f()\n{\n'
          '    {\n        int x = 1;\n        x = 2;\n    }\n'
          '    {\n        int x = 3;\n        x = x + 1;\n    }\n}\n')
sp = os.path.join(root, 's.d')
open(sp, 'w').write(shadow)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(sp, shadow)
d.drain(1.0)
first = fmt(d.references(sp, 4, 12, True))   # first block's x
second = fmt(d.references(sp, 8, 12, True))  # second block's x
check('first-block-local', set(l for (_, l, _, _) in first) == {4, 5}
      and len(first) == 2, str(first))
check('second-block-local', set(l for (_, l, _, _) in second) == {8, 9}
      and len(second) == 3, str(second))
d.close()

# Template function: calls instantiate the template; references must fold the
# instance back to the TemplateDeclaration.
tmpl = ('module tm;\n'
        'void LINFO(Char, A...)(in Char[] fmt, scope A args) {}\n'
        'extern(C) void main()\n{\n'
        '    LINFO("aaa");\n'
        '    LINFO("bbb");\n'
        '    LINFO("ccc");\n'
        '}\n')
tp = os.path.join(root, 'tm.d')
open(tp, 'w').write(tmpl)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(tp, tmpl)
d.drain(1.0)
tmrefs = fmt(d.references(tp, 1, 5, True))
check('template-refs',
      sorted(l for (_, l, _, _) in tmrefs) == [1, 4, 5, 6],
      str(tmrefs))
d.close()

shutil.rmtree(root, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
