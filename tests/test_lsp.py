import json, os, subprocess, sys

BIN = './dmd-lsp'
FILE = 'tests/cc.d'
URI = 'file://' + os.path.abspath(FILE)

proc = subprocess.Popen([BIN, '--import=tests', '--debounce-ms=0'], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

def send(obj):
    body = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
    proc.stdin.flush()

def read_msg():
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

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

# Built-in properties a `.` completion may append on any type; tests that assert
# the *members* of a dotted chain filter these out first.
BUILTIN_PROPS = {
    'init', 'sizeof', 'alignof', 'mangleof', 'stringof', 'max', 'min',
    'length', 'ptr', 'dup', 'idup', 'capacity', 'reserve', 'reverse', 'sort',
    'keys', 'values', 'byKey', 'byValue', 'byKeyValue', 'rehash', 'get',
    'require', 'update', 'min_normal', 'nan', 'infinity', 'epsilon', 'dig',
    'mant_dig', 'max_10_exp', 'min_10_exp', 'max_exp', 'min_exp', 'tupleof',
    'classinfo',
}

def members_only(labels):
    return [l for l in labels if l not in BUILTIN_PROPS]

text = open(FILE).read()
lines = text.split('\n')

def complete_at(line0, marker, after):
    """Cursor right after `marker` on 0-based line0. Returns label list."""
    idx = lines[line0].index(marker) + len(marker) + after
    send({"jsonrpc": "2.0", "id": 100, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": URI},
                     "position": {"line": line0, "character": idx}}})
    return [i['label'] for i in read_msg()['result']['items']]

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None,
                 "capabilities": {"textDocument": {"completion": {
                     "completionItem": {"labelDetailsSupport": True}}}},
                 "initializationOptions": {"importPaths": ["tests"]}}})
init = read_msg()
check('initialize', init['result']['serverInfo']['version'] == '0.3.0')
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": text}}})
diag = read_msg()
dmsgs = [d['message'] for d in diag['params']['diagnostics']]
check('diag-has-undefined-dou', any('dou' in m for m in dmsgs), str(dmsgs))

# locals: `dou` prefix on line 16 (0-based) -> doubled
labels = complete_at(16, 'dou', 0)
check('local-doubled', 'doubled' in labels, str(labels[:8]))

# params: `ext` prefix would need a probe line; use `extra` occurrence check instead:
# struct member via origin. (line 17, after 'origin.')
labels = complete_at(17, 'origin.', 0)
check('origin-members', all(x in labels for x in ('x', 'y', 'name')), str(labels[:8]))

# param struct member via p. (line 18)
labels = complete_at(18, 'p.', 0)
check('param-members', all(x in labels for x in ('x', 'y', 'name')), str(labels[:8]))

# static-side aggregate name (line 19) still lists members
labels = complete_at(19, 'Point.', 0)
check('aggregate-members', all(x in labels for x in ('x', 'y', 'name')), str(labels[:8]))

# comment suppression (line 15, inside comment)
labels = complete_at(15, 'notin', 0)
check('comment-empty', labels == [], str(labels[:5]))

# string suppression (line 14, inside string)
labels = complete_at(14, 'notin', 0)
check('string-empty', labels == [], str(labels[:5]))

# condition variable: `if (auto dd = ...)` then `dd` inside the body (line 22)
labels = complete_at(22, 'dd', 0)
check('cond-var', labels == ['dd'], str(labels))
l8 = lines[11]  # '    int doubled = extra * 2;'
idx = l8.index('extra') + 2  # mid-word 'ex'
send({"jsonrpc": "2.0", "id": 101, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": URI},
                 "position": {"line": 11, "character": idx}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('param-extra', 'extra' in labels, str(labels[:8]))

# didChangeConfiguration applies new import paths without restart
send({"jsonrpc": "2.0", "method": "workspace/didChangeConfiguration",
      "params": {"settings": {"dmd-lsp": {"importPaths": ["tests"]}}}})

# attribute blocks + mixin members: struct with private:/public:/mixin.
# attr.d lines (0-based): 19:'    auto q = w.sh;', 20:'    w.'
atext = open('tests/attr.d').read()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": 'file://' + os.path.abspath('tests/attr.d'),
                                 "languageId": "d", "version": 1, "text": atext}}})
read_msg()  # diagnostics (parse errors expected from trailing dot)
send({"jsonrpc": "2.0", "id": 103, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": 'file://' + os.path.abspath('tests/attr.d')},
                 "position": {"line": 19, "character": 17}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('attr-selective-shown', labels == ['shown'], str(labels))
send({"jsonrpc": "2.0", "id": 104, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": 'file://' + os.path.abspath('tests/attr.d')},
                 "position": {"line": 20, "character": 6}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('attr-dot-nocrash', 'shown' in labels and 'greet' in labels and
      'hidden' not in labels, str(labels))
# broken code: trailing dot still completes (placeholder variant + snapshot)
btext = 'module b1;\nstruct S { int x; int y; }\nvoid main()\n{\n    S s;\n    s.\n}\n'
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/b1test.d", "languageId": "d",
                                 "version": 1, "text": btext}}})
read_msg()  # diagnostics
send({"jsonrpc": "2.0", "id": 102, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/b1test.d"},
                 "position": {"line": 5, "character": 6}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('broken-trailing-dot', members_only(labels) == ['x', 'y'], str(labels))

# trailing dot on an `auto` local from an imported module: the placeholder
# must survive semantic (else the body collapses and the type is lost)
atext = 'module b2;\nimport autolib;\nvoid main()\n{\n    auto cfg = globalCfg;\n    cfg.\n}\n'
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/b2test.d", "languageId": "d",
                                 "version": 1, "text": atext}}})
read_msg()  # diagnostics
send({"jsonrpc": "2.0", "id": 105, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/b2test.d"},
                 "position": {"line": 5, "character": 8}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('auto-trailing-dot', members_only(labels) == ['workers', 'name'], str(labels))

# Array element access: `xs[0].` completes on the element type.
atext = 'module arridx;\nstruct Entry { int a; int b; }\nvoid f()\n{\n    Entry[] xs;\n    xs[0].\n}\n'
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/arridx.d", "languageId": "d",
                                 "version": 1, "text": atext}}})
read_msg()  # diagnostics
send({"jsonrpc": "2.0", "id": 106, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/arridx.d"},
                 "position": {"line": 5, "character": 10}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('array-index-dot', members_only(labels) == ['a', 'b'], str(labels))

# Declarations produced by a CTFE string mixin must be completable even
# though the buffer being completed has a parse error (incomplete token).
atext = ('module mxt;\n'
         'string makeStruct(string n, string f)\n'
         '{\n    return "struct " ~ n ~ " { int " ~ f ~ "; }";\n}\n'
         'mixin(makeStruct("GeneratedUser", "userId"));\n'
         'void use()\n{\n    Generated\n}\n')
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/mxtest.d", "languageId": "d",
                                 "version": 1, "text": atext}}})
read_msg()  # diagnostics (parse error expected)
send({"jsonrpc": "2.0", "id": 107, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/mxtest.d"},
                 "position": {"line": 8, "character": 13}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('mixin-generated', labels == ['GeneratedUser'], str(labels))

# Symbols re-exported through a `public import` chain must complete in a
# module that imports the package (pkg1 publicly imports pkg2).
atext = 'module usepkg;\nimport pkg1;\nvoid f()\n{\n    pkg_\n}\n'
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/usepkg.d", "languageId": "d",
                                 "version": 1, "text": atext}}})
read_msg()
send({"jsonrpc": "2.0", "id": 108, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/usepkg.d"},
                 "position": {"line": 4, "character": 8}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('public-import-symbol', 'pkg_exported_symbol' in labels, str(labels))

# A standalone partial identifier must not collapse the body's semantic, so
# an `auto` local keeps its inferred type in the completion detail.
atext = ('module autotype;\n'
         'struct State { int x; }\n'
         'State makeState() { return State(); }\n'
         'void main()\n{\n    auto state = makeState();\n    st\n}\n')
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/autotype.d", "languageId": "d",
                                 "version": 1, "text": atext}}})
read_msg()
send({"jsonrpc": "2.0", "id": 109, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/autotype.d"},
                 "position": {"line": 6, "character": 6}}})
items = read_msg()['result']['items']
det = [(i.get('labelDetails') or {}).get('description') or i.get('detail')
       for i in items if i['label'] == 'state']
check('standalone-prefix-auto-type', det == ['State'], str(det))

# LSP 3.17 labelDetails: functions render as label + "(params)" + return type.
ldtext = ('module labeldet;\n'
          'struct Point { int x; int y; }\n'
          'int dist(Point p, int extra) { return extra; }\n'
          'void freeFn() {}\n'
          'void use()\n{\n    di\n    fr\n}\n')
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/labeldet.d", "languageId": "d",
                                 "version": 1, "text": ldtext}}})
read_msg()
send({"jsonrpc": "2.0", "id": 110, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/labeldet.d"},
                 "position": {"line": 6, "character": 6}}})
items = read_msg()['result']['items']
dist = [i for i in items if i['label'] == 'dist']
check('labeldetails-fn',
      bool(dist) and dist[0].get('labelDetails') ==
      {'detail': '(Point, int)', 'description': 'int'}, str(dist))
send({"jsonrpc": "2.0", "id": 111, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/labeldet.d"},
                 "position": {"line": 7, "character": 6}}})
items = read_msg()['result']['items']
free = [i for i in items if i['label'] == 'freeFn']
check('labeldetails-void',
      bool(free) and free[0].get('labelDetails') ==
      {'detail': '()', 'description': 'void'} and 'detail' not in free[0], str(free))

# signature help: function calls, struct literals and methods.
_sid = [200]
def open_doctype(name, text):
    uri = 'file:///tmp/' + name
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": uri, "languageId": "d",
                                     "version": 1, "text": text}}})
    read_msg()
    return uri

# Completion must not offer imported compiler/runtime internals (`__unittest_*`
# thunks, `_d_*` runtime helpers, `__ArrayCast`/`__cmp` object internals): the
# implicit `object`/druntime closure is full of them. The root's own symbols are
# kept, so a user's `__`-prefixed code still completes.
filtdoc = ('module filt;\n'
           'int __userFlag;\n'
           'void f()\n{\n'
           '    \n}\n')
filturi = open_doctype('filt.d', filtdoc)
send({"jsonrpc": "2.0", "id": 122, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": filturi},
                 "position": {"line": 4, "character": 4}}})
fitems = read_msg()['result']['items']
flabels = [i['label'] for i in fitems]
finst = [l for l in flabels if l.startswith('__unittest_') or l.startswith('_d_')]
check('completion-no-internals', bool(flabels) and not finst, str(finst[:6]))
check('completion-keeps-user-underscore', '__userFlag' in flabels,
      str(flabels[:8]))
# Keywords are offered (kind 14 = Keyword) in a bare completion...
kwkinds = [i['label'] for i in fitems if i.get('kind') == 14]
check('completion-keywords',
      all(k in kwkinds for k in ('if', 'else', 'return', 'struct', 'foreach')),
      str(kwkinds[:8]))
# Kind-based sortText groups the list; keywords always sort last.
kwsort = [i['sortText'] for i in fitems if i.get('kind') == 14]
othsort = [i['sortText'] for i in fitems if i.get('kind') != 14]
check('completion-keywords-sort-last',
      bool(kwsort) and bool(othsort) and min(kwsort) > max(othsort),
      'kw=%s other=%s' % (min(kwsort) if kwsort else None,
                          max(othsort) if othsort else None))

# ...but not after a dot.
dotdoc = 'module dotk;\nstruct S { int x; }\nvoid f() { S s; s. }\n'
doturi = open_doctype('dotk.d', dotdoc)
send({"jsonrpc": "2.0", "id": 123, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": doturi},
                 "position": {"line": 2,
                              "character": dotdoc.split('\n')[2].index('s.') + 2}}})
dotitems = read_msg()['result']['items']
check('completion-no-keywords-after-dot',
      not any(i.get('kind') == 14 for i in dotitems),
      str([i['label'] for i in dotitems if i.get('kind') == 14][:6]))

# ...nor mid-expression (keywords are offered only at a statement boundary).
middoc = 'module midk;\nint g;\nvoid f(int a)\n{\n    int y = g + \n}\n'
miduri = open_doctype('midk.d', middoc)
send({"jsonrpc": "2.0", "id": 124, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": miduri},
                 "position": {"line": 4,
                              "character": len(middoc.split('\n')[4])}}})
miditems = read_msg()['result']['items']
check('completion-no-keywords-mid-expression',
      not any(i.get('kind') == 14 for i in miditems),
      str([i['label'] for i in miditems if i.get('kind') == 14][:6]))

# Built-in properties after a dot, by type: `a.` on an int -> init/sizeof/max.
propdoc = 'module propk;\nvoid f(int a)\n{\n    a.\n}\n'
propuri = open_doctype('propk.d', propdoc)
send({"jsonrpc": "2.0", "id": 125, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": propuri},
                 "position": {"line": 3,
                              "character": propdoc.split('\n')[3].index('a.') + 2}}})
props = [i['label'] for i in read_msg()['result']['items']]
check('completion-builtin-properties',
      all(p in props for p in ('init', 'sizeof', 'mangleof', 'max', 'min')),
      str(props[:12]))

# Typing a keyword prefix must still see the statement boundary before it
# (the partial word itself is not the "previous token").
def kw_prefix(name, token):
    doc = 'module %s;\nvoid f()\n{\n    %s\n}\n' % (name, token)
    uri = open_doctype('%s.d' % name, doc)
    send({"jsonrpc": "2.0", "id": 126, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": uri},
                     "position": {"line": 3,
                                  "character": 4 + len(token)}}})
    return [i['label'] for i in read_msg()['result']['items'] if i.get('kind') == 14]

check('completion-keyword-prefix-struct', 'struct' in kw_prefix('kp1', 'stru'), '')
check('completion-keyword-prefix-switch', 'switch' in kw_prefix('kp2', 'swit'), '')
check('completion-keyword-prefix-foreach', 'foreach' in kw_prefix('kp3', 'fore'), '')
check('completion-keyword-prefix-return', 'return' in kw_prefix('kp4', 'ret'), '')

def sig_at(uri, line, ch):
    _sid[0] += 1
    send({"jsonrpc": "2.0", "id": _sid[0], "method": "textDocument/signatureHelp",
          "params": {"textDocument": {"uri": uri},
                     "position": {"line": line, "character": ch}}})
    return read_msg()['result']

furi = open_doctype('sigf.d',
    'module sigf;\nstruct Point { int x; int y; }\n'
    'int dist(Point p, int extra) { return extra; }\n'
    'void main()\n{\n    dist(1, \n}\n')
r = sig_at(furi, 5, 9)
check('sighelp-fn-start',
      r['signatures'][0]['label'] == 'int dist(Point p, int extra)' and
      r['activeParameter'] == 0, str(r))
r = sig_at(furi, 5, 12)
check('sighelp-fn-active', r['activeParameter'] == 1, str(r))

suri = open_doctype('sigs.d',
    'module sigs;\nstruct Entry { int target; float hate; }\n'
    'void main()\n{\n    Entry(\n}\n')
r = sig_at(suri, 4, 10)
check('sighelp-struct-literal',
      r['signatures'][0]['label'] == 'Entry(int target, float hate)', str(r))

muri = open_doctype('sigm.d',
    'module sigm;\nstruct Calc { int add(int a, int b) { return a + b; } }\n'
    'void main()\n{\n    Calc c;\n    c.add(\n}\n')
r = sig_at(muri, 5, 10)
check('sighelp-method',
      r['signatures'][0]['label'] == 'int add(int a, int b)' and
      r['activeParameter'] == 0, str(r))

# Dot completion inside an unclosed call argument list: the placeholder must
# neutralise the whole expression statement so semantic does not collapse
# and the local's inferred type survives.
curi = open_doctype('syscmd.d',
    'module syscmd;\n'
    'struct Combatant { int owner_handle; int hp; }\n'
    'struct World { Combatant[] combatants; uint combatant_count; }\n'
    'Combatant* world_get_transform(World* w, int handle) { return null; }\n'
    'void drain(World* w)\n{\n'
    '    for (uint i = 0; i < w.combatant_count; i++)\n    {\n'
    '        auto c = &w.combatants[i];\n'
    '        world_get_transform(w, c.\n'
    '    }\n}\n')
send({"jsonrpc": "2.0", "id": 300, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": curi},
                 "position": {"line": 9, "character": 33}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('dot-in-call-arg', members_only(labels) == ['owner_handle', 'hp'], str(labels))

# Same position without a dot: the local's inferred type must be shown
# (not the snapshot's "local" fallback).
plainuri = open_doctype('syscmd2.d',
    'module syscmd2;\n'
    'struct Combatant { int owner_handle; int hp; }\n'
    'struct World { Combatant[] combatants; uint combatant_count; }\n'
    'Combatant* world_get_transform(World* w, int handle) { return null; }\n'
    'void drain(World* w)\n{\n'
    '    for (uint i = 0; i < w.combatant_count; i++)\n    {\n'
    '        auto c = &w.combatants[i];\n'
    '        world_get_transform(w, c\n'
    '    }\n}\n')
send({"jsonrpc": "2.0", "id": 301, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": plainuri},
                 "position": {"line": 9, "character": 31}}})
items = read_msg()['result']['items']
cdet = [(i.get('labelDetails') or {}).get('description') or i.get('detail')
        for i in items if i['label'] == 'c']
check('plain-in-call-arg-type', cdet == ['Combatant*'], str(cdet))

# goto definition: local, module member, dotted field, imported symbol.
def def_at(uri, line, ch):
    _sid[0] += 1
    send({"jsonrpc": "2.0", "id": _sid[0], "method": "textDocument/definition",
          "params": {"textDocument": {"uri": uri},
                     "position": {"line": line, "character": ch}}})
    return read_msg()['result']

deftext = ('module defs;\n'
           'struct Point { int x; int y; }\n'
           'int add(int a, int b) { return a + b; }\n'
           'void main()\n{\n'
           '    Point p;\n'
           '    int z = add(p.x, 2);\n}\n')
duri = open_doctype('defs.d', deftext)
check('def-fn',
      def_at(duri, 6, 13)[0]['range']['start'] == {'line': 2, 'character': 4},
      str(def_at(duri, 6, 13)))
check('def-field',
      def_at(duri, 6, 18)[0]['range']['start'] == {'line': 1, 'character': 19},
      '')
check('def-local',
      def_at(duri, 6, 8)[0]['range']['start'] == {'line': 6, 'character': 8},
      '')

# Conditional declarations: definition must follow the branch dmd selected,
# not the first branch in the AST. A versioned-out / static-if-false
# declaration must not shadow the live one (core.stdc.stdio's `printf` picks
# up the MinGW/ieee128 alias otherwise).
cond = ('module conddefs;\n'
        'enum useAlt = false;\n'
        'static if (useAlt) { int pick() { return 1; } }\n'
        'else { int pick() { return 2; } }\n'
        'void main() { pick(); }\n')
curi = open_doctype('conddefs.d', cond)
check('def-staticif-active-branch',
      def_at(curi, 4, 14)[0]['range']['start']['line'] == 3,
      str(def_at(curi, 4, 14)))

def _req_at(method, uri, line, ch):
    _sid[0] += 1
    send({"jsonrpc": "2.0", "id": _sid[0], "method": method,
          "params": {"textDocument": {"uri": uri},
                     "position": {"line": line, "character": ch}}})
    return read_msg()['result']

# typeDefinition: a variable goes to its type's declaration; declaration is the
# definition target.
tdef = _req_at('textDocument/typeDefinition', duri, 5, 10)  # `p`
check('typedef-local',
      bool(tdef) and tdef[0]['range']['start'] == {'line': 1, 'character': 0},
      str(tdef))
dcla = _req_at('textDocument/declaration', duri, 6, 13)  # `add`
check('declaration-fn',
      bool(dcla) and dcla[0]['range']['start'] == {'line': 2, 'character': 4},
      str(dcla))

# documentHighlight: every occurrence of the cursor's symbol in the file.
dhuri = open_doctype('dh.d',
    'module dh;\nvoid f(int a)\n{\n    a = a + 1;\n    int b = a;\n}\n')
dhl = _req_at('textDocument/documentHighlight', dhuri, 1, 11)  # `a`
check('document-highlight',
      bool(dhl) and sorted((r['range']['start']['line'],
                            r['range']['start']['character']) for r in dhl)
      == [(1, 11), (3, 4), (3, 8), (4, 12)], str(dhl))

# foldingRange: brace blocks, comment runs, import runs.
def _req(uri, method):
    _sid[0] += 1
    send({"jsonrpc": "2.0", "id": _sid[0], "method": method,
          "params": {"textDocument": {"uri": uri}}})
    return read_msg()['result']

folduri = open_doctype('fold.d',
    'module fold;\nvoid f()\n{\n    if (true)\n    {\n        int x;\n    }\n}\n'
    '// a\n// b\nimport os;\nimport std.stdio;\n')
folds = _req(folduri, 'textDocument/foldingRange')
fset = sorted((r['startLine'], r['endLine'], r.get('kind')) for r in (folds or []))
check('folding-range',
      (2, 7, 'region') in fset and (4, 6, 'region') in fset
      and (8, 9, 'comment') in fset and (10, 11, 'imports') in fset, str(fset))

xuri = open_doctype('usedef.d',
    'module usedef;\nimport autolib;\nvoid f() { auto c = globalCfg; }\n')
xdef = def_at(xuri, 2, 25)
check('def-import', bool(xdef) and xdef[0]['uri'].endswith('/tests/autolib.d'),
      str(xdef))

# goto through a `public import` chain (pkg1 publicly imports pkg2).
puri = open_doctype('usedef2.d',
    'module usedef2;\nimport pkg1;\nvoid f() { pkg_exported_symbol; }\n')
pdef = def_at(puri, 2, 11)
check('def-public-import',
      bool(pdef) and pdef[0]['uri'].endswith('/tests/pkg2.d'), str(pdef))

# labelDetails for non-functions: variables describe their type, types their kind.
ld2 = ('module ld2;\n'
       'struct Point { int x; int y; }\n'
       'void use()\n{\n'
       '    Point p;\n'
       '    p.\n'
       '    \n}\n')
ld2uri = open_doctype('ld2.d', ld2)
send({"jsonrpc": "2.0", "id": 112, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": ld2uri},
                 "position": {"line": 6, "character": 4}}})
items = read_msg()['result']['items']
def _ld(label):
    for i in items:
        if i['label'] == label:
            return i.get('labelDetails')
    return None
check('labeldetails-type', _ld('Point') == {'description': 'struct'}, str(_ld('Point')))
check('labeldetails-var', _ld('p') == {'description': 'Point'}, str(_ld('p')))
send({"jsonrpc": "2.0", "id": 113, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": ld2uri},
                 "position": {"line": 5, "character": 6}}})
items = read_msg()['result']['items']
check('labeldetails-field',
      any(i['label'] == 'x' and i.get('labelDetails') == {'description': 'int'}
          for i in items), str(items[:5]))

# hover: declaration line + doc comment.
hovertext = ('module hovt;\n'
             'struct Point { int x; int y; }\n'
             '/// Adds two things.\n'
             'int add(int a, int b) { return a + b; }\n'
             'void main()\n{\n'
             '    Point p;\n'
             '    int z = add(p.x, 2);\n}\n')
huri = open_doctype('hovt.d', hovertext)
def hover_at(line, ch):
    _sid[0] += 1
    send({"jsonrpc": "2.0", "id": _sid[0], "method": "textDocument/hover",
          "params": {"textDocument": {"uri": huri},
                     "position": {"line": line, "character": ch}}})
    r = read_msg()['result']
    return r['contents']['value'] if r else None
hv = hover_at(7, 13)
check('hover-fn',
      hv is not None and 'int add(int a, int b)' in hv and 'Adds two things.' in hv,
      str(hv))
hv = hover_at(7, 18)
check('hover-field', hv is not None and 'int x' in hv, str(hv))

# The prefix segment of a dotted chain targets that segment, not the tail:
# hovering `s` in `s.x` must resolve the local, not the field.
def hover_uri(uri, line, ch):
    _sid[0] += 1
    send({"jsonrpc": "2.0", "id": _sid[0], "method": "textDocument/hover",
          "params": {"textDocument": {"uri": uri},
                     "position": {"line": line, "character": ch}}})
    r = read_msg()['result']
    return r['contents']['value'] if r else None
cuna = open_doctype('chain.d',
    'module chain;\nstruct S { int x; }\nvoid f() { S s; int y = s.x; }\n')
hv = hover_uri(cuna, 2, 24)
check('hover-chain-prefix', hv is not None and 'S s' in hv, str(hv))
dv = def_at(cuna, 2, 24)
check('def-chain-prefix',
      bool(dv) and dv[0]['range']['start'] == {'line': 2, 'character': 13}, str(dv))

# An identifier inside an index expression is its own chain: hovering `k` in
# `tbl[k].a` must resolve the parameter, not the array `tbl` (the old text
# scanner walked left across `[` and merged the chains).
htext = ('module hidx;\n'
         'struct E { int a; }\n'
         'void f(E[4] tbl, int k) { tbl[k].a = 1; }\n')
hidxuri = open_doctype('hidx.d', htext)
hcol = htext.split('\n')[2].index('tbl[') + 4
hv = hover_uri(hidxuri, 2, hcol)
check('hover-index-identifier', hv is not None and 'int k' in hv, str(hv))
hv = hover_uri(hidxuri, 2, htext.split('\n')[2].index('tbl[') + 1)
check('hover-index-array', hv is not None and 'E[4] tbl' in hv, str(hv))

# hover on a type/enum is a short, fully-qualified declaration, not the body
# (the body reads as source and dumps enum members as `cast` expressions).
hv = hover_uri(cuna, 1, 7)
check('hover-type-def', hv is not None and 'struct chain.S' in hv and
      'int x' not in hv, str(hv))
hk = ('module hk;\n'
      'class C { int y; }\n'
      'enum E { a, b }\n'
      'void f() { C c; E e; }\n')
hkuri = open_doctype('hk.d', hk)
hv = hover_uri(hkuri, 3, hk.split('\n')[3].index('C c'))
check('hover-class-short', hv is not None and 'class hk.C' in hv and
      'int y' not in hv, str(hv))
hv = hover_uri(hkuri, 3, hk.split('\n')[3].index('E e'))
check('hover-enum-short', hv is not None and 'enum hk.E' in hv and
      'cast' not in hv, str(hv))

# Selective import: complete the imported module's members after ':'.
seluri = open_doctype('selimp.d',
    'module selimp;\nimport autolib : gl\nvoid f() {}\n')
send({"jsonrpc": "2.0", "id": 120, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": seluri},
                 "position": {"line": 1, "character": 19}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('selective-import', labels == ['globalCfg'], str(labels))
send({"jsonrpc": "2.0", "id": 121, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": seluri},
                 "position": {"line": 1, "character": 16}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('selective-import-all', 'Cfg' in labels and 'globalCfg' in labels, str(labels))
# Module-name completion after `import `: the workspace index supplies `autolib`.
send({"jsonrpc": "2.0", "id": 122, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": seluri},
                 "position": {"line": 1, "character": 10}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('import-module-completion', 'autolib' in labels, str(labels[:8]))

# Module-qualified completion: `import nm.a;` -> `nm.` / `nm.a.`
mquri = open_doctype('modqual.d',
    'module modqual;\nimport nm.a;\nvoid f()\n{\n    nm.\n    nm.a.\n}\n')
send({"jsonrpc": "2.0", "id": 123, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": mquri},
                 "position": {"line": 4, "character": 7}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('module-qualifier', labels == ['a'], str(labels))
send({"jsonrpc": "2.0", "id": 124, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": mquri},
                 "position": {"line": 5, "character": 9}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('module-members', labels == ['nm_a_symbol'], str(labels))

# Semantic tokens: whole-file identifier classification (legend + delta data).
leg = init['result']['capabilities']['semanticTokensProvider']['legend']
stypes = leg['tokenTypes']
def sem_tokens(uri):
    _sid[0] += 1
    send({"jsonrpc": "2.0", "id": _sid[0],
          "method": "textDocument/semanticTokens/full",
          "params": {"textDocument": {"uri": uri}}})
    data = read_msg()['result']['data']
    toks = {}
    line = 0
    col = 0
    for k in range(0, len(data), 5):
        dl, dc, ln, tt, tm = data[k:k + 5]
        line += dl
        col = dc if dl else col + dc
        toks[(line, col)] = (ln, stypes[tt], tm)
    return toks

semtext = ('module semh;\n'
           'struct Point { int x; int y; void function(int) fp; }\n'
           'enum Color { red, green }\n'
           'int add(int a, int b) { int sum = a + b; return sum; }\n'
           'void main()\n{\n'
           '    auto p = Point(1, 2);\n'
           '    int z = add(p.x, Color.red);\n'
           '    p.fp(z);\n'
           '}\n')
semuri = open_doctype('semh.d', semtext)
sl = semtext.split('\n')
stoks = sem_tokens(semuri)
def sem_at(line, col):
    return stoks.get((line, col))

pt = sl[1].index('Point')
check('sem-struct', sem_at(1, pt) == (5, 'struct', 0), str(sem_at(1, pt)))
fx = sl[1].index('x;')
check('sem-field', sem_at(1, fx) == (1, 'property', 0), str(sem_at(1, fx)))
rd = sl[2].index('red')
check('sem-enum-member', sem_at(2, rd) == (3, 'enumMember', 0), str(sem_at(2, rd)))
ad = sl[3].index('add')
check('sem-function', sem_at(3, ad) == (3, 'function', 0), str(sem_at(3, ad)))
pa = sl[3].index('a,')
check('sem-parameter', sem_at(3, pa) == (1, 'parameter', 0), str(sem_at(3, pa)))
sm = sl[3].index('sum')
check('sem-local', sem_at(3, sm) == (3, 'variable', 0), str(sem_at(3, sm)))
# Use site: p.x field access and Color.red enum member.
last = 7
px = sl[last].index('p.x') + 2
check('sem-field-use', sem_at(last, px) == (1, 'property', 0), str(sem_at(last, px)))
cr = sl[last].index('Color.red')
check('sem-enum-use', sem_at(last, cr) == (5, 'enum', 0), str(sem_at(last, cr)))
check('sem-enummember-use', sem_at(last, cr + 6) == (3, 'enumMember', 0),
      str(sem_at(last, cr + 6)))
# A function-pointer field: `property` where it is declared/read, `method`
# where it is called.
fdecl = sl[1].index('fp;')
check('sem-fnptr-decl', sem_at(1, fdecl) == (2, 'property', 0),
      str(sem_at(1, fdecl)))
call_line = 8
fpc = sl[call_line].index('fp(')
check('sem-fnptr-call', sem_at(call_line, fpc) == (2, 'method', 0),
      str(sem_at(call_line, fpc)))
# Tokens must be sorted and non-overlapping (LSP requirement).
ordered = sorted(stoks)
check('sem-sorted', list(stoks) == ordered, 'unsorted')

# Template + alias chain: `value`'s type resolves through the template member
# `__traits(getMember, T, name)` (name is a CTFE enum), i.e. int.
alias_text = ('module aliastest;\n'
              'struct Foo(T)\n{\n    alias bar = T;\n}\n'
              'Foo!int foo;\n'
              'enum name = "bar";\n'
              'alias T = typeof(foo);\n'
              'alias M = __traits(getMember, T, name);\n'
              'M value;\n'
              'extern(C) void main()\n{\n    val\n}\n')
open('/tmp/aliastest.d', 'w').write(alias_text)
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/aliastest.d",
                                 "languageId": "d", "version": 1, "text": alias_text}}})
read_msg()
send({"jsonrpc": "2.0", "id": 111, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/aliastest.d"},
                 "position": {"line": 12, "character": 7}}})
items = read_msg()['result']['items']
vitem = next((i for i in items if i['label'] == 'value'), None)
vdesc = (vitem or {}).get('labelDetails', {}).get('description')
check('alias-template-member-type', vdesc == 'int', str(vdesc))

# An unrelated semantic error and an incomplete `shap` line both collapse the
# enclosing body. Locals must still resolve from dmd's own resolved types on
# the parsed declarations (they are semanticized in order before the collapse),
# including nested initializers (`auto sss = &shapes;`).
err_text = ('module errcomp;\n'
            'struct Shapes { void clear_queue() {} int count; }\n'
            'struct State { Shapes shapes; }\n'
            'struct Allocator {}\n'
            'State gState;\n'
            'State* editor_init(State* a);\n'
            'void f(State* state, Allocator alloc)\n'
            '{\n'
            '    auto shapes = &state.shapes;\n'
            '    auto sss = &shapes;\n'
            '    editor_init(state);\n'
            '    shap\n'
            '    sss.\n'
            '}\n')
open('/tmp/errcomp.d', 'w').write(err_text)
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/errcomp.d",
                                 "languageId": "d", "version": 1, "text": err_text}}})
read_msg()
send({"jsonrpc": "2.0", "id": 113, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/errcomp.d"},
                 "position": {"line": 12, "character": 8}}})
err_items = [i['label'] for i in read_msg()['result']['items']]
check('error-local-auto-dot', 'clear_queue' in err_items and 'count' in err_items,
      str(err_items[:8]))

# Function templates are presented as functions with a full signature
# `(template params)(function params)` + return type, not as an opaque
# "template" item.
tmpl_text = ('module tmpltest;\n'
             'void LINFO(Char, A...)(in Char[] fmt, scope A args)\n'
             '{\n}\n'
             'void main()\n'
             '{\n'
             '    LIN\n'
             '}\n')
open('/tmp/tmpltest.d', 'w').write(tmpl_text)
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": "file:///tmp/tmpltest.d",
                                 "languageId": "d", "version": 1, "text": tmpl_text}}})
read_msg()
send({"jsonrpc": "2.0", "id": 114, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///tmp/tmpltest.d"},
                 "position": {"line": 6, "character": 7}}})
tmpl_items = read_msg()['result']['items']
tmpl = next((i for i in tmpl_items if i['label'] == 'LINFO'), None)
tmld = (tmpl or {}).get('labelDetails') or {}
check('fn-template-kind', tmpl is not None and tmpl['kind'] == 3, str(tmpl))
check('fn-template-detail', tmld.get('detail') == '(Char, A...)(Char[], A)',
      str(tmld))
check('fn-template-return', tmld.get('description') == 'void', str(tmld))

send({"jsonrpc": "2.0", "id": 4, "method": "shutdown", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
proc.stdin.close()
print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
