import json, os, select, shutil, subprocess, sys, tempfile

# textDocument/documentSymbol: hierarchical outline from the semantic module.

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

    def document_symbols(self, path):
        self.send({"jsonrpc": "2.0", "id": 100,
                   "method": "textDocument/documentSymbol",
                   "params": {"textDocument": {"uri": 'file://' + path}}})
        return self.read_msg()['result']

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


SRC = '''module syms;

struct Point { int x; int y; }
class Shape
{
    int id;
    this(int i) { id = i; }
    void move(int dx) {}
}
enum Color { Red, Green, Blue }
alias P = Point;
int gvar;
int add(int a, int b) { return a + b; }
union U { int i; float f; }
'''

root = tempfile.mkdtemp(prefix='dmd-lsp-syms-')
path = os.path.join(root, 'syms.d')
open(path, 'w').write(SRC)

d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(path, SRC)
d.drain(1.0)
syms = d.document_symbols(path)

names = [s['name'] for s in syms]
check('top-level-names',
      all(n in names for n in ['Point', 'Shape', 'Color', 'P', 'gvar', 'add', 'U']),
      str(names))

by = {s['name']: s for s in syms}
check('struct-kind', by['Point']['kind'] == 23, str(by['Point']['kind']))
check('class-kind', by['Shape']['kind'] == 5, str(by['Shape']['kind']))
check('enum-kind', by['Color']['kind'] == 10, str(by['Color']['kind']))
check('function-kind', by['add']['kind'] == 12, str(by['add']['kind']))
check('ctor-shows-this',
      any(c['name'] == 'this' and c['kind'] == 9 for c in by['Shape']['children']),
      str([c['name'] for c in by['Shape']['children']]))
check('method-kind',
      any(c['name'] == 'move' and c['kind'] == 6 for c in by['Shape']['children']),
      str([(c['name'], c['kind']) for c in by['Shape']['children']]))
check('field-detail', by['Point']['children'][0].get('detail') == 'int',
      str(by['Point']['children'][0]))
check('enum-members',
      [c['name'] for c in by['Color']['children']] == ['Red', 'Green', 'Blue'],
      str([c['name'] for c in by['Color']['children']]))

# selectionRange points at the identifier, not the `struct` keyword.
lines = SRC.split('\n')
point_line = next(i for i, l in enumerate(lines) if l.startswith('struct Point'))
check('struct-selection-name',
      by['Point']['selectionRange']['start']['line'] == point_line and
      by['Point']['selectionRange']['start']['character'] ==
      lines[point_line].index('Point'),
      str(by['Point']['selectionRange']))
# function range spans to its closing brace (one-liner here)
add_line = next(i for i, l in enumerate(lines) if l.startswith('int add'))
fr = by['add']['range']
check('function-range',
      fr['start']['line'] == add_line and fr['end']['line'] == add_line,
      str(fr))
# range must contain selectionRange
for s in syms:
    r, sel = s['range'], s['selectionRange']
    ok = (r['start']['line'] < sel['start']['line'] or
          (r['start']['line'] == sel['start']['line'] and
           r['start']['character'] <= sel['start']['character'])) and \
         (r['end']['line'] > sel['end']['line'] or
          (r['end']['line'] == sel['end']['line'] and
           r['end']['character'] >= sel['end']['character']))
    check('range-contains-selection-' + s['name'], ok, str((r, sel)))

d.close()

# Empty file -> [] and no crash.
empty = tempfile.mkdtemp(prefix='dmd-lsp-syms-')
epath = os.path.join(empty, 'e.d')
open(epath, 'w').write('module e;\n')
d = Daemon(['--debounce-ms=0', '--import=' + empty])
d.init(empty)
d.drain(0.5)
d.open_doc(epath, 'module e;\n')
d.drain(0.5)
check('empty-module', d.document_symbols(epath) == [], '')
d.close()

# A syntax error elsewhere must still yield the parsed symbols.
broken = tempfile.mkdtemp(prefix='dmd-lsp-syms-')
bpath = os.path.join(broken, 'b.d')
btxt = 'module b;\nstruct Good { int v; }\nvoid f( {\n'
open(bpath, 'w').write(btxt)
d = Daemon(['--debounce-ms=0', '--import=' + broken])
d.init(broken)
d.drain(0.5)
d.open_doc(bpath, btxt)
d.drain(1.0)
syms = d.document_symbols(bpath)
check('broken-still-partial', any(s['name'] == 'Good' for s in syms),
      str([s['name'] for s in syms]))
d.close()

# Edge cases for the visitor walk: templates, nested aggregates, attribute
# blocks (`private:`), anonymous aggregate members (flattened), and static-if.
EDGE = ('module edge;\n'
        'template Tmpl(T) { T value; }\n'
        'struct Outer\n{\n'
        '    struct Inner { int z; }\n'
        '    int a;\n'
        '    private:\n'
        '    int b;\n'
        '}\n'
        'enum Anon { A, B }\n'
        'static if (true) { int condvar; }\n'
        'struct { int anonfield; } anon;\n')
epath = os.path.join(root, 'edge.d')
open(epath, 'w').write(EDGE)
d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
d.drain(0.5)
d.open_doc(epath, EDGE)
d.drain(1.0)
syms = d.document_symbols(epath)
by = {s['name']: s for s in syms}
check('edge-template-present', 'Tmpl' in by, str(list(by)))
check('edge-nested-aggregate',
      any(c['name'] == 'Inner' and any(g['name'] == 'z'
          for g in c.get('children', [])) for c in by.get('Outer', {}).get('children', [])),
      str([c['name'] for c in by.get('Outer', {}).get('children', [])]))
check('edge-attribute-block',
      any(c['name'] == 'b' for c in by.get('Outer', {}).get('children', [])),
      str([c['name'] for c in by.get('Outer', {}).get('children', [])]))
check('edge-enum-members',
      [c['name'] for c in by['Anon'].get('children', [])] == ['A', 'B'],
      str(by['Anon'].get('children')))
check('edge-static-if-member', 'condvar' in by, str(list(by)))
check('edge-anon-aggregate-flattened', 'anonfield' in by, str(list(by)))
d.close()

shutil.rmtree(root, ignore_errors=True)
shutil.rmtree(empty, ignore_errors=True)
shutil.rmtree(broken, ignore_errors=True)

print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
