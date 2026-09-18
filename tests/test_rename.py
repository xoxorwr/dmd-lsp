import json, os, select, shutil, subprocess, sys, tempfile

# textDocument/rename + prepareRename. Rename is all-or-nothing: it applies the
# declaration and every proven use, refuses when the reference set is
# incomplete, and validates the new name. Edits are applied here and compared
# to the expected sources.

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

    def change_doc(self, path, text, version):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didChange",
                   "params": {"textDocument": {"uri": 'file://' + path,
                                              "version": version},
                              "contentChanges": [{"text": text}]}})

    def save_doc(self, path, text):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didSave",
                   "params": {"textDocument": {"uri": 'file://' + path},
                              "text": text}})

    def prepare(self, path, line, ch):
        self.send({"jsonrpc": "2.0", "id": 50,
                   "method": "textDocument/prepareRename",
                   "params": {"textDocument": {"uri": 'file://' + path},
                              "position": {"line": line, "character": ch}}})
        return self.read_msg()

    def rename(self, path, line, ch, new_name):
        self.send({"jsonrpc": "2.0", "id": 51,
                   "method": "textDocument/rename",
                   "params": {"textDocument": {"uri": 'file://' + path},
                              "position": {"line": line, "character": ch},
                              "newName": new_name}})
        return self.read_msg()

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


def apply_changes(changes, sources):
    """Apply a WorkspaceEdit's `changes` to {path: text}; return new sources."""
    out = dict(sources)
    for uri, edits in changes.items():
        path = uri.replace('file://', '')
        text = out[path]
        # splice from the end so earlier offsets stay valid
        for e in sorted(edits, key=lambda e: (e['range']['start']['line'],
                                              e['range']['start']['character']),
                        reverse=True):
            s = e['range']['start']
            en = e['range']['end']
            lines = text.split('\n')
            start = sum(len(l) + 1 for l in lines[:s['line']]) + s['character']
            end = sum(len(l) + 1 for l in lines[:en['line']]) + en['character']
            text = text[:start] + e['newText'] + text[end:]
        out[path] = text
    return out


def edit_keys(changes):
    keys = []
    for uri, edits in (changes or {}).items():
        for e in edits:
            keys.append((uri, e['range']['start']['line'],
                         e['range']['start']['character'],
                         e['range']['end']['character']))
    return keys


root = tempfile.mkdtemp(prefix='dmd-lsp-rename-')

# ---- multi-file rename: declaration + uses in another module ----
LIB = 'module lib;\nint gcount;\n'
APP = 'module app;\nimport lib;\nvoid f()\n{\n    gcount = gcount + 1;\n}\n'
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

r = d.prepare(appp, 4, 4)
check('prepare-range',
      r.get('result') and r['result']['range']['start'] == {'line': 4, 'character': 4}
      and r['result']['range']['end'] == {'line': 4, 'character': 10}
      and r['result']['placeholder'] == 'gcount', str(r.get('result')))

r = d.rename(appp, 4, 4, 'total')
check('rename-ok', 'result' in r and 'error' not in r, str(r)[:200])
if 'result' in r:
    changes = r['result']['changes']
    check('rename-edits-cover-decl-and-uses',
          len(edit_keys(changes)) == 3
          and len(edit_keys(changes)) == len(set(edit_keys(changes))),
          str(edit_keys(changes)))
    new = apply_changes(changes, {libp: LIB, appp: APP})
    check('rename-applied',
          new[libp] == 'module lib;\nint total;\n'
          and new[appp] == 'module app;\nimport lib;\nvoid f()\n{\n    total = total + 1;\n}\n',
          repr(new[appp]))
else:
    check('rename-edits-cover-decl-and-uses', False, 'no result')
    check('rename-applied', False, 'no result')

# Invalid new name is refused (keyword and malformed identifier).
for bad in ('struct', '1abc', 'a-b'):
    r = d.rename(appp, 4, 4, bad)
    check('rename-rejects-' + bad, 'error' in r, str(r)[:160])
d.close()

# ---- overload group: every overload declaration and every call ----
OVL = ('module ovl;\n'
       'void f(int x) {}\n'
       'void f(string s) {}\n'
       'void g()\n{\n'
       '    f(1);\n'
       '    f("a");\n'
       '}\n')
ovlp = os.path.join(root, 'ovl.d')
open(ovlp, 'w').write(OVL)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(ovlp, OVL)
d.drain(1.0)
r = d.rename(ovlp, 5, 4, 'h')
if 'result' in r:
    new = apply_changes(r['result']['changes'], {ovlp: OVL})
    check('rename-overload-group',
          new[ovlp] == ('module ovl;\n'
                        'void h(int x) {}\n'
                        'void h(string s) {}\n'
                        'void g()\n{\n'
                        '    h(1);\n'
                        '    h("a");\n'
                        '}\n'), repr(new[ovlp]))
else:
    check('rename-overload-group', False, str(r)[:160])
d.close()

# ---- local rename stays inside the file ----
LOC = ('module loc;\n'
       'void f()\n{\n'
       '    int x = 1;\n'
       '    x = x + 1;\n'
       '}\n')
locp = os.path.join(root, 'loc.d')
open(locp, 'w').write(LOC)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(locp, LOC)
d.drain(1.0)
r = d.rename(locp, 4, 4, 'y')
if 'result' in r:
    new = apply_changes(r['result']['changes'], {locp: LOC})
    check('rename-local',
          new[locp] == ('module loc;\n'
                        'void f()\n{\n'
                        '    int y = 1;\n'
                        '    y = y + 1;\n'
                        '}\n'), repr(new[locp]))
else:
    check('rename-local', False, str(r)[:160])
d.close()

# ---- incomplete: an importer with an unresolvable import refuses rename ----
os.makedirs(os.path.join(root, 'parts'))
pa = 'module a;\nvoid thing() {}\n'
pb = ('module b;\nimport a;\nimport definitely_missing_module;\n'
      'void fb() { thing(); }\n')
pc = 'module c;\nimport a;\nvoid fc() { thing(); }\n'
for nm, txt in (('a.d', pa), ('b.d', pb), ('c.d', pc)):
    open(os.path.join(root, 'parts', nm), 'w').write(txt)
d = Daemon(['--debounce-ms=0', '--import=' + root,
            '--import=' + root + '/parts'])
d.init(root)
d.drain(0.5)
d.open_doc(os.path.join(root, 'parts', 'a.d'), pa)
d.drain(1.0)
r = d.rename(os.path.join(root, 'parts', 'a.d'), 1, 5, 'renamed')
check('rename-refused-incomplete', 'error' in r, str(r)[:200])
d.close()

# ---- declaration outside the project (stdlib) is refused ----
STD = ('module appstd;\n'
       'import std.stdio;\n'
       'void f()\n{\n'
       '    writeln("hi");\n'
       '}\n')
stdp = os.path.join(root, 'appstd.d')
open(stdp, 'w').write(STD)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(stdp, STD)
d.drain(1.5)
r = d.rename(stdp, 4, 4, 'renamed')
check('rename-refused-outside-project', 'error' in r, str(r)[:200])
d.close()

# Two renames in a row with the client applying and saving the first: the
# re-analysis after the save can respawn the worker, which starts with no
# workspace index. A stale "index built" flag made the second rename fail with
# "declaring module not indexed".
L2 = 'module lib2;\nint gcount;\n'
A2 = 'module app2;\nimport lib2;\nvoid f()\n{\n    gcount = gcount + 1;\n}\n'
l2 = os.path.join(root, 'lib2.d')
a2 = os.path.join(root, 'app2.d')
open(l2, 'w').write(L2)
open(a2, 'w').write(A2)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(l2, L2)
d.open_doc(a2, A2)
d.drain(1.0)
r = d.rename(a2, 4, 4, 'total')
check('rename-twice-first-ok', 'result' in r, str(r)[:160])
if 'result' in r:
    new = apply_changes(r['result']['changes'], {l2: L2, a2: A2})
    for p, t in new.items():
        open(p, 'w').write(t)
    d.change_doc(l2, new[l2], 2)
    d.change_doc(a2, new[a2], 2)
    d.save_doc(l2, new[l2])
    d.save_doc(a2, new[a2])
    d.drain(2.5)  # let the debounced re-analysis (possibly respawning) settle
    r2 = d.rename(l2, 1, 4, 'count')
    check('rename-twice-second-ok', 'result' in r2, str(r2)[:200])
else:
    check('rename-twice-second-ok', False, 'first rename failed')
d.close()

# Renaming a type must rewrite the declaration and every explicit type
# annotation (not just expression uses).
ST2 = ('module st2;\n'
       'struct S { int f; }\n'
       'S gvar;\n'
       'void fn(S p) { S s; }\n')
st2 = os.path.join(root, 'st2.d')
open(st2, 'w').write(ST2)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(st2, ST2)
d.drain(1.0)
r = d.rename(st2, 1, 7, 'T')  # `S` in the struct declaration
if 'result' in r:
    new = apply_changes(r['result']['changes'], {st2: ST2})
    check('rename-type-annotations',
          new[st2] == ('module st2;\n'
                       'struct T { int f; }\n'
                       'T gvar;\n'
                       'void fn(T p) { T s; }\n'), repr(new[st2]))
else:
    check('rename-type-annotations', False, str(r)[:200])
d.close()

# A default-constructed struct literal `S()` must be renamed too.
SLIT = ('module slit2;\n'
        'struct S { int f; }\n'
        'S make() { return S(); }\n')
slp2 = os.path.join(root, 'slit2.d')
open(slp2, 'w').write(SLIT)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(slp2, SLIT)
d.drain(1.0)
r = d.rename(slp2, 1, 7, 'T')
if 'result' in r:
    new = apply_changes(r['result']['changes'], {slp2: SLIT})
    check('rename-struct-literal',
          new[slp2] == ('module slit2;\n'
                        'struct T { int f; }\n'
                        'T make() { return T(); }\n'), repr(new[slp2]))
else:
    check('rename-struct-literal', False, str(r)[:200])
d.close()

# Qualified static access: renaming the type must rewrite the qualifier too.
QUAL = ('module qual2;\n'
        'struct Camera { static Camera ortho(); }\n'
        'void f() { auto c = Camera.ortho(); }\n')
qup = os.path.join(root, 'qual2.d')
open(qup, 'w').write(QUAL)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(qup, QUAL)
d.drain(1.0)
r = d.rename(qup, 1, 7, 'Lens')
if 'result' in r:
    new = apply_changes(r['result']['changes'], {qup: QUAL})
    check('rename-qualified-static',
          new[qup] == ('module qual2;\n'
                       'struct Lens { static Lens ortho(); }\n'
                       'void f() { auto c = Lens.ortho(); }\n'), repr(new[qup]))
else:
    check('rename-qualified-static', False, str(r)[:200])
d.close()

# Enum members are constant-folded (`Test.A` -> IntegerExp); rename must still
# rewrite the declaration and every `Test.A` use, and the enum type likewise.
EN2 = ('module en2;\n'
       'enum Test { A, B, C }\n'
       'Test t1 = Test.A;\n'
       'Test t2 = Test.A;\n')
en2p = os.path.join(root, 'en2.d')
open(en2p, 'w').write(EN2)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(en2p, EN2)
d.drain(1.0)
r = d.rename(en2p, 1, 12, 'X')  # `A` in the enum declaration
if 'result' in r:
    new = apply_changes(r['result']['changes'], {en2p: EN2})
    check('rename-enum-member',
          new[en2p] == ('module en2;\n'
                        'enum Test { X, B, C }\n'
                        'Test t1 = Test.X;\n'
                        'Test t2 = Test.X;\n'), repr(new[en2p]))
else:
    check('rename-enum-member', False, str(r)[:200])
r = d.rename(en2p, 1, 5, 'Color')  # `Test` in the enum declaration
if 'result' in r:
    new = apply_changes(r['result']['changes'], {en2p: EN2})
    check('rename-enum-type',
          new[en2p] == ('module en2;\n'
                        'enum Color { A, B, C }\n'
                        'Color t1 = Color.A;\n'
                        'Color t2 = Color.A;\n'), repr(new[en2p]))
else:
    check('rename-enum-type', False, str(r)[:200])
d.close()

# Enum member inside a constant expression: rename must rewrite the compound
# uses too (function body and module-level initializer).
ENC2 = ('module enc2;\n'
        'enum Test { A, B, C }\n'
        'int f() { return Test.A + Test.B; }\n'
        'Test t = Test.A + Test.B;\n')
enc2p = os.path.join(root, 'enc2.d')
open(enc2p, 'w').write(ENC2)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(enc2p, ENC2)
d.drain(1.0)
r = d.rename(enc2p, 1, 15, 'X')  # `B` in the enum declaration
if 'result' in r:
    new = apply_changes(r['result']['changes'], {enc2p: ENC2})
    check('rename-enum-compound-member',
          new[enc2p] == ('module enc2;\n'
                         'enum Test { A, X, C }\n'
                         'int f() { return Test.A + Test.X; }\n'
                         'Test t = Test.A + Test.X;\n'), repr(new[enc2p]))
else:
    check('rename-enum-compound-member', False, str(r)[:200])
d.close()

# UFCS call site: renaming a free function must rewrite `s.helper()`.
UF = ('module uf2;\n'
      'struct S { int v; }\n'
      'void helper(S s) { }\n'
      'void bar() { S s; s.helper(); }\n')
ufp = os.path.join(root, 'uf2.d')
open(ufp, 'w').write(UF)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(ufp, UF)
d.drain(1.0)
r = d.rename(ufp, 2, 5, 'util')  # `helper`
if 'result' in r:
    new = apply_changes(r['result']['changes'], {ufp: UF})
    check('rename-ufcs',
          new[ufp] == ('module uf2;\n'
                       'struct S { int v; }\n'
                       'void util(S s) { }\n'
                       'void bar() { S s; s.util(); }\n'), repr(new[ufp]))
else:
    check('rename-ufcs', False, str(r)[:200])
d.close()

shutil.rmtree(root, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
