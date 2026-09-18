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
    def __init__(self, args, stderr=None):
        self.proc = subprocess.Popen([BIN] + args, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=stderr,
                                     bufsize=0)

    def err(self):
        if self.proc.stderr is None:
            return ''
        try:
            return self.proc.stderr.read().decode(errors='replace')
        except Exception:
            return ''

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

    def prepare(self, path, line, ch):
        self.send({"jsonrpc": "2.0", "id": 101,
                   "method": "textDocument/prepareRename",
                   "params": {"textDocument": {"uri": 'file://' + path},
                              "position": {"line": line, "character": ch}}})
        return self.read_msg()

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


def loc_key(refs):
    return [(r['uri'], r['range']['start']['line'],
             r['range']['start']['character'], r['range']['end']['character'])
            for r in (refs or [])]


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
lk = loc_key(r)
check('cross-file-includes-decl',
      ('lib.d', 1, 4, 10) in got and ('app.d', 4, 4, 10) in got
      and ('app.d', 4, 17, 23) in got,
      str(got))
# No duplicates (each (file,line,start) appears once) — asserted on the full
# location, not the basename, in case the two producers report different paths
# for the same offset.
check('no-duplicates', len(got) == len(set(got)), str(got))
check('no-duplicate-locations', len(lk) == len(set(lk)), str(lk))
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
r4 = d.references(libp, 1, 4, True)
got4 = fmt(r4)
lk4 = loc_key(r4)
check('decl-finds-importers',
      ('lib.d', 1, 4, 10) in got4 and ('app.d', 4, 4, 10) in got4
      and ('app.d', 4, 17, 23) in got4,
      str(got4))
check('decl-merge-no-duplicate-locations', len(lk4) == len(set(lk4)), str(lk4))
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

# Lexer fallback: a syntax error elsewhere collapses a body, but the module's
# identifiers are still resolved, so uses inside it are not lost.
bad = ('module br;\n'
       'void f() {}\n'
       'void g()\n{\n'
       '    f();\n'
       '    int bad = ;\n'
       '}\n')
bp = os.path.join(root, 'br.d')
open(bp, 'w').write(bad)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(bp, bad)
d.drain(1.0)
brefs = fmt(d.references(bp, 1, 5, True))
check('collapsed-body-fallback', sorted(l for (_, l, _, _) in brefs) == [1, 4],
      str(brefs))
brefs2 = fmt(d.references(bp, 1, 5, False))
check('collapsed-body-exclude-decl',
      sorted(l for (_, l, _, _) in brefs2) == [4], str(brefs2))
d.close()

# Cyclic imports with an importer outside the request closure. The wide root
# must import c -> a <-> b without stale symbols / hanging; base finds a+b,
# wide adds c.
os.makedirs(os.path.join(root, 'cyc'))
ca = ('module a;\n'
      'import b;\n'
      'void sharedA() {}\n')
cb = ('module b;\n'
      'import a;\n'
      'void fb() { sharedA(); }\n')
cc = ('module c;\n'
      'import a;\n'
      'void fc() { sharedA(); }\n')
for nm, txt in (('a.d', ca), ('b.d', cb), ('c.d', cc)):
    open(os.path.join(root, 'cyc', nm), 'w').write(txt)
d = Daemon(['--debounce-ms=0', '--import=' + root, '--import=' + root + '/cyc'])
d.init(root)
d.drain(0.5)
d.open_doc(os.path.join(root, 'cyc', 'a.d'), ca)
d.drain(1.0)
crefs = fmt(d.references(os.path.join(root, 'cyc', 'a.d'), 2, 5, True))
check('cyclic-import-refs',
      sorted((os.path.basename(f), l) for (f, l, _, _) in crefs) ==
      [('a.d', 2), ('b.d', 2), ('c.d', 2)],
      str(crefs))
d.close()

# Struct member access. dmd stores the *receiver* location in DotVarExp, not
# the member's, so a naive walk reports a bogus location at the receiver (and,
# before, a correct one via the lexer fallback). Semantic-only resolution must
# report the member identifier exactly once, at its real position.
mem = ('module mem;\n'
       'struct S { int field; void method() {} }\n'
       'void g(S s)\n{\n'
       '    s.method();\n'
       '    int v = s.field;\n'
       '}\n')
mp = os.path.join(root, 'mem.d')
open(mp, 'w').write(mem)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(mp, mem)
d.drain(1.0)
mrefs = fmt(d.references(mp, 4, 9, True))  # `method` in `s.method()`
check('member-method-refs',
      ('mem.d', 1, 27, 33) in mrefs and ('mem.d', 4, 6, 12) in mrefs
      and len(mrefs) == 2, str(mrefs))
frefs = fmt(d.references(mp, 5, 14, True))  # `field` in `s.field`
check('member-field-refs',
      ('mem.d', 1, 15, 20) in frefs and ('mem.d', 5, 14, 19) in frefs
      and len(frefs) == 2, str(frefs))
d.close()

# Overloaded functions: a call resolves to one overload, but references/rename
# operate on the name, so every call and every overload declaration is listed.
ovl = ('module ovl;\n'
       'void f(int x) {}\n'
       'void f(string s) {}\n'
       'void g()\n{\n'
       '    f(1);\n'
       '    f("a");\n'
       '}\n')
op = os.path.join(root, 'ovl.d')
open(op, 'w').write(ovl)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(op, ovl)
d.drain(1.0)
orefs = fmt(d.references(op, 5, 4, True))
check('overload-group-refs',
      sorted(l for (_, l, _, _) in orefs) == [1, 2, 5, 6] and len(orefs) == 4,
      str(orefs))
d.close()

# Failure isolation + completeness. An importer with an unresolvable import
# must not hide a sibling importer's use, and it must mark the result
# incomplete (rename will refuse on that). The worker reports completeness on
# stderr under DMD_LSP_TRACE_REFS.
os.makedirs(os.path.join(root, 'parts'))
pa = 'module a;\nvoid thing() {}\n'
pb = ('module b;\nimport a;\nimport definitely_missing_module;\n'
      'void fb() { thing(); }\n')
pc = 'module c;\nimport a;\nvoid fc() { thing(); }\n'
for nm, txt in (('a.d', pa), ('b.d', pb), ('c.d', pc)):
    open(os.path.join(root, 'parts', nm), 'w').write(txt)
os.environ['DMD_LSP_TRACE_REFS'] = '1'
d = Daemon(['--debounce-ms=0', '--import=' + root,
            '--import=' + root + '/parts'], stderr=subprocess.PIPE)
d.init(root)
d.drain(0.5)
d.open_doc(os.path.join(root, 'parts', 'a.d'), pa)
d.drain(1.0)
prefs = fmt(d.references(os.path.join(root, 'parts', 'a.d'), 1, 5, True))
check('importer-failure-isolated',
      ('a.d', 1, 5, 10) in prefs and ('c.d', 2, 12, 17) in prefs
      and not any(nm == 'b.d' for (nm, _, _, _) in prefs), str(prefs))
d.close()
os.environ.pop('DMD_LSP_TRACE_REFS', None)
trace = d.err()
check('incomplete-marked',
      'complete=0' in trace and 'unloaded import in b' in trace, trace[-200:])

# A plain function call must not be located by scanning forward for a
# dot-preceded spelling of the name (`obj.target` in a later comment): the
# callee's own loc is already the identifier.
cmt = ('module cmt;\n'
       'void target() {}\n'
       'void f()\n{\n'
       '    target();\n'
       '}\n'
       '// see obj.target() for details\n')
cmp_ = os.path.join(root, 'cmt.d')
open(cmp_, 'w').write(cmt)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(cmp_, cmt)
d.drain(1.0)
crefs2 = fmt(d.references(cmp_, 4, 4, True))
check('callee-not-located-in-comment',
      sorted(l for (_, l, _, _) in crefs2) == [1, 4], str(crefs2))
d.close()

# Aggregate declarations store the *keyword* in `loc` (not the name), and dmd
# does not keep the type-name span on a resolved `Type`, so struct/class type
# references need explicit handling: the declaration, explicit type
# annotations, and invocation from a type annotation.
st = ('module st;\n'
      'struct S { int f; }\n'
      'S gvar;\n'
      'void f(S p)\n{\n'
      '    S s;\n'
      '}\n')
stp = os.path.join(root, 'st.d')
open(stp, 'w').write(st)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(stp, st)
d.drain(1.0)
srefs = fmt(d.references(stp, 1, 7, True))  # `S` in the struct declaration
check('struct-type-refs',
      ('st.d', 1, 7, 8) in srefs and ('st.d', 2, 0, 1) in srefs
      and ('st.d', 3, 7, 8) in srefs and ('st.d', 5, 4, 5) in srefs,
      str(srefs))
r = d.prepare(stp, 2, 0)  # cursor on the type annotation `S gvar;`
check('struct-type-prepare',
      r.get('result') and r['result']['placeholder'] == 'S'
      and r['result']['range']['start'] == {'line': 2, 'character': 0},
      str(r.get('result')))
d.close()

# Uses inside expression kinds that a hand-rolled walk tends to miss:
# array/associative-array/struct literals and casts.
lit = ('module lit;\n'
       'int a;\n'
       'struct S { int v; }\n'
       'void f()\n{\n'
       '    auto arr = [a, a + 1];\n'
       '    auto aa = ["k": a];\n'
       '    S s = S(a);\n'
       '    auto c = cast(int) a;\n'
       '}\n')
litp = os.path.join(root, 'lit.d')
open(litp, 'w').write(lit)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(litp, lit)
d.drain(1.0)
lrefs = fmt(d.references(litp, 1, 4, True))
check('literal-uses-found',
      sorted(l for (_, l, _, _) in lrefs) == [1, 5, 5, 6, 7, 8], str(lrefs))
d.close()

# Function parameters resolve like locals (declaration + both uses).
par = ('module par;\n'
       'void f(int alpha)\n{\n'
       '    alpha = alpha + 1;\n'
       '}\n')
pp = os.path.join(root, 'par.d')
open(pp, 'w').write(par)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(pp, par)
d.drain(1.0)
prefs2 = fmt(d.references(pp, 3, 4, True))  # first `alpha` use
check('parameter-refs',
      prefs2 == [('par.d', 1, 11, 16), ('par.d', 3, 4, 9),
                 ('par.d', 3, 12, 17)], str(prefs2))
d.close()

# A string-mixin-generated member gets a synthetic Loc that can point at
# unrelated source (here the generated `printValue` reported inside `main`).
# References must only report real source spans, never the generated
# declaration.
os.makedirs(os.path.join(root, 'mix'))
mix = ('module main_test;\n'
       '\n'
       'string makeStruct(string structName, string fieldName)\n'
       '{\n'
       '    return "struct " ~ structName ~ " {\\n"\n'
       '         ~ "    int " ~ fieldName ~ ";\\n"\n'
       '         ~ "    void printValue() { }\\n"\n'
       '         ~ "}";\n'
       '}\n'
       '\n'
       'mixin(makeStruct("GeneratedUser", "userId"));\n'
       '\n'
       'extern(C) void main()\n'
       '{\n'
       '    GeneratedUser user;\n'
       '    user.printValue();\n'
       '}\n')
mxp = os.path.join(root, 'mix', 'main_test.d')
open(mxp, 'w').write(mix)
d = Daemon(['--debounce-ms=0', '--import=' + root + '/mix'])
d.init(root)
d.drain(0.5)
d.open_doc(mxp, mix)
d.drain(1.0)
mixrefs = fmt(d.references(mxp, 15, 9, True))  # `printValue` in `user.printValue()`
check('mixin-generated-decl-excluded',
      mixrefs == [('main_test.d', 15, 9, 19)], str(mixrefs))
d.close()

# A default-constructed struct literal `S()` is a StructLiteralExp whose loc is
# the `(`; the type name before it must still be a reference.
slit = ('module slit;\n'
        'struct S { int f; }\n'
        'S make() { return S(); }\n')
slp = os.path.join(root, 'slit.d')
open(slp, 'w').write(slit)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(slp, slit)
d.drain(1.0)
srefs = fmt(d.references(slp, 1, 7, True))
check('struct-literal-type',
      ('slit.d', 1, 7, 8) in srefs and ('slit.d', 2, 0, 1) in srefs
      and ('slit.d', 2, 18, 19) in srefs, str(srefs))
r = d.prepare(slp, 2, 18)
check('struct-literal-prepare',
      r.get('result') and r['result']['placeholder'] == 'S',
      str(r.get('result')))
d.close()

# A qualified static member access: dmd resolves `Camera.ortho` to a direct
# `VarExp(ortho)` whose loc is the *qualifier*, dropping the scope node. Both
# the type qualifier and the member must still be found.
qual = ('module qual;\n'
        'struct Camera { static Camera ortho(); }\n'
        'void f() { auto c = Camera.ortho(); }\n')
qp = os.path.join(root, 'qual.d')
open(qp, 'w').write(qual)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(qp, qual)
d.drain(1.0)
# `Camera` declaration -> includes the qualifier in `Camera.ortho()`
crefs = fmt(d.references(qp, 1, 7, True))
check('qualified-static-type',
      ('qual.d', 1, 7, 13) in crefs and ('qual.d', 2, 20, 26) in crefs,
      str(crefs))
# `ortho` declaration -> includes the call site member
orefs = fmt(d.references(qp, 1, 30, True))
check('qualified-static-member',
      ('qual.d', 1, 30, 35) in orefs and ('qual.d', 2, 27, 32) in orefs,
      str(orefs))
# cursor on the qualifier resolves to the type
r = d.prepare(qp, 2, 20)
check('qualified-static-prepare',
      r.get('result') and r['result']['placeholder'] == 'Camera',
      str(r.get('result')))
d.close()

# Enum members are constant-folded during semantic (`Test.A` becomes an
# IntegerExp typed as the enum, whose loc is the qualifier and whose EnumMember
# link is gone). The enum type, its members and every `Enum.Member` use must
# still resolve. The enum type is also recognised before `toBasetype()` (which
# would unwrap it to the base integer type).
en = ('module en;\n'
      'enum Test { A, B, C }\n'
      'Test t1 = Test.A;\n'
      'Test t2 = Test.A;\n'
      'Test t3 = Test.C;\n')
enp = os.path.join(root, 'en.d')
open(enp, 'w').write(en)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(enp, en)
d.drain(1.0)
erefs = fmt(d.references(enp, 1, 5, True))  # `Test` in the enum declaration
check('enum-type-refs',
      erefs == [('en.d', 1, 5, 9), ('en.d', 2, 0, 4), ('en.d', 2, 10, 14),
                ('en.d', 3, 0, 4), ('en.d', 3, 10, 14), ('en.d', 4, 0, 4),
                ('en.d', 4, 10, 14)], str(erefs))
arefs = fmt(d.references(enp, 1, 12, True))  # `A` in the enum declaration
check('enum-member-refs',
      arefs == [('en.d', 1, 12, 13), ('en.d', 2, 15, 16), ('en.d', 3, 15, 16)],
      str(arefs))
crefs = fmt(d.references(enp, 4, 15, True))  # `C` in `Test.C`
check('enum-member-use-refs', crefs == [('en.d', 1, 18, 19), ('en.d', 4, 15, 16)],
      str(crefs))
r = d.prepare(enp, 2, 15)  # cursor on a folded `Test.A`
check('enum-member-prepare',
      r.get('result') and r['result']['placeholder'] == 'A'
      and r['result']['range']['start'] == {'line': 2, 'character': 15},
      str(r.get('result')))
d.close()

# Enum members inside a constant expression (`Test.A + Test.B`) are folded by
# the frontend unless manifest-constant expansion is disabled for the analysis
# (see `lspNoManifestExpand`). Both simple and compound uses -- function body
# and module-level initializer -- must be found.
enc = ('module enc;\n'
       'enum Test { A, B, C }\n'
       'int f() { return Test.A + Test.B; }\n'
       'Test t = Test.A + Test.B;\n')
encp = os.path.join(root, 'enc.d')
open(encp, 'w').write(enc)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(encp, enc)
d.drain(1.0)
crefs = fmt(d.references(encp, 1, 12, True))  # `A` in the enum declaration
check('enum-compound-member-refs',
      crefs == [('enc.d', 1, 12, 13), ('enc.d', 2, 22, 23), ('enc.d', 3, 14, 15)],
      str(crefs))
crefs = fmt(d.references(encp, 1, 5, True))  # `Test` in the enum declaration
check('enum-compound-type-refs',
      crefs == [('enc.d', 1, 5, 9), ('enc.d', 2, 17, 21), ('enc.d', 2, 26, 30),
                ('enc.d', 3, 0, 4), ('enc.d', 3, 9, 13), ('enc.d', 3, 18, 22)],
      str(crefs))
d.close()

# The same substitution affects `const`/`immutable` manifest constants, so the
# declaration and every folded use must be found too.
cst = ('module cst;\n'
       'const int K = 5;\n'
       'int f() { return K + K; }\n'
       'int x = K;\n')
cstp = os.path.join(root, 'cst.d')
open(cstp, 'w').write(cst)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(cstp, cst)
d.drain(1.0)
krefs = fmt(d.references(cstp, 1, 10, True))  # `K` in the const declaration
check('const-manifest-refs',
      krefs == [('cst.d', 1, 10, 11), ('cst.d', 2, 17, 18), ('cst.d', 2, 21, 22),
                ('cst.d', 3, 8, 9)], str(krefs))
d.close()

# UFCS: dmd rewrites `s.helper()` to a call to the free `helper` with `s` as
# the first argument, and the callee node's loc is the *dot*, so a naive walk
# reports nothing at the call site (a broken rename).
uf = ('module uf;\n'
      'struct S { int v; }\n'
      'void helper(S s) { }\n'
      'void tmpl(T)(T x) { }\n'
      'int prop(S s) { return s.v; }\n'
      'void bar()\n'
      '{\n'
      '    S s;\n'
      '    s.helper();\n'
      '    s.tmpl();\n'
      '    auto x = s.prop;\n'
      '}\n')
ufp = os.path.join(root, 'uf.d')
open(ufp, 'w').write(uf)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(ufp, uf)
d.drain(1.0)
ufrefs = fmt(d.references(ufp, 2, 5, True))  # `helper` declaration
check('ufcs-refs',
      ufrefs == [('uf.d', 2, 5, 11), ('uf.d', 8, 6, 12)], str(ufrefs))
trefs = fmt(d.references(ufp, 3, 5, True))  # template UFCS `s.tmpl()`
check('ufcs-template-refs',
      trefs == [('uf.d', 3, 5, 9), ('uf.d', 9, 6, 10)], str(trefs))
prefs = fmt(d.references(ufp, 4, 4, True))  # property UFCS `s.prop` (no parens)
check('ufcs-property-refs',
      prefs == [('uf.d', 4, 4, 8), ('uf.d', 10, 15, 19)], str(prefs))
d.close()

# `alias this`: a use through the promoted member (`w.promoted`) resolves to the
# subobject's field, so references/rename already follow it.
at = ('module al;\n'
      'struct Inner { int promoted; }\n'
      'struct Wrapper { Inner inner; alias inner this; }\n'
      'void f() { Wrapper w; auto x = w.promoted; }\n')
atp = os.path.join(root, 'al.d')
open(atp, 'w').write(at)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(atp, at)
d.drain(1.0)
atrefs = fmt(d.references(atp, 1, 19, True))  # `promoted`
check('alias-this-refs',
      atrefs == [('al.d', 1, 19, 27), ('al.d', 3, 33, 41)], str(atrefs))
d.close()

# `opDispatch`: `d.whatever` is rewritten to `d.opDispatch!"whatever"` with no
# source occurrence of a real member. References must find only the declaration
# and the explicit `opDispatch` use, never a guessed location at `whatever`.
op = ('module op;\n'
      'struct D\n{\n'
      '    int opDispatch(string name)() { return 0; }\n'
      '}\n'
      'void f()\n{\n'
      '    D d;\n'
      '    auto x = d.whatever;\n'
      '    auto y = d.opDispatch!"foo";\n'
      '}\n')
opp = os.path.join(root, 'op.d')
open(opp, 'w').write(op)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(opp, op)
d.drain(1.0)
oprefs = fmt(d.references(opp, 3, 8, True))  # `opDispatch` declaration
check('opdispatch-no-wrong-location',
      ('op.d', 3, 8, 18) in oprefs and ('op.d', 9, 15, 25) in oprefs
      and not any(l == 8 for (_, l, _, _) in oprefs), str(oprefs))
d.close()

# textDocument/implementation: derived classes for an interface, and overrides
# for an interface method. The importer is on disk so the workspace index finds
# it (the request universe alone does not contain it).
imb = 'module ibase;\ninterface Ii\n{\n    void run();\n}\n'
imm = 'module imain;\nimport ibase;\nclass Impl : Ii\n{\n    void run() {}\n}\n'
ibp = os.path.join(root, 'ibase.d')
imp = os.path.join(root, 'imain.d')
open(ibp, 'w').write(imb)
open(imp, 'w').write(imm)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(ibp, imb)
d.drain(1.0)

def implementation(path, line, ch):
    d.send({"jsonrpc": "2.0", "id": 120,
            "method": "textDocument/implementation",
            "params": {"textDocument": {"uri": 'file://' + path},
                       "position": {"line": line, "character": ch}}})
    return d.read_msg().get('result')

irefs = implementation(ibp, 1, 10)  # `Ii`
check('implementation-interface',
      bool(irefs) and any(r['uri'].endswith('/imain.d')
                          and r['range']['start']['line'] == 2 for r in irefs),
      str(irefs))
mrefs = implementation(ibp, 3, 9)  # `Ii.run`
check('implementation-method',
      bool(mrefs) and any(r['uri'].endswith('/imain.d')
                          and r['range']['start']['line'] == 4 for r in mrefs),
      str(mrefs))
d.close()
os.remove(ibp)
os.remove(imp)

shutil.rmtree(root, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
