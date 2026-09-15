import json, subprocess, sys

BIN = './dmd-lsp'
FILE = 'tests/cc.d'
URI = 'file:///home/ryuukk/dev/dmd-lsp/tests/cc.d'

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
      "params": {"textDocument": {"uri": "file:///home/ryuukk/dev/dmd-lsp/tests/attr.d",
                                 "languageId": "d", "version": 1, "text": atext}}})
read_msg()  # diagnostics (parse errors expected from trailing dot)
send({"jsonrpc": "2.0", "id": 103, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///home/ryuukk/dev/dmd-lsp/tests/attr.d"},
                 "position": {"line": 19, "character": 17}}})
labels = [i['label'] for i in read_msg()['result']['items']]
check('attr-selective-shown', labels == ['shown'], str(labels))
send({"jsonrpc": "2.0", "id": 104, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": "file:///home/ryuukk/dev/dmd-lsp/tests/attr.d"},
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
check('broken-trailing-dot', labels == ['x', 'y'], str(labels))

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
check('auto-trailing-dot', labels == ['workers', 'name'], str(labels))

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
check('array-index-dot', labels == ['a', 'b'], str(labels))

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
check('dot-in-call-arg', labels == ['owner_handle', 'hp'], str(labels))

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

# hover on a type shows the declaration source, not just "struct S".
hv = hover_uri(cuna, 1, 7)
check('hover-type-def', hv is not None and 'struct S' in hv and 'int x' in hv,
      str(hv))

send({"jsonrpc": "2.0", "id": 4, "method": "shutdown", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
proc.stdin.close()
print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
