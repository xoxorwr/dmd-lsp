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

shutil.rmtree(root, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
