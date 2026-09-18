import json, subprocess, sys, tempfile, os, shutil

# Dotted completion must resolve a LHS that is an imported type/enum (hover
# already resolves those), and member access on a pointer loop/param must
# survive a collapsed function body via the pre-semantic snapshot.

BIN = './dmd-lsp'
ROOT = tempfile.mkdtemp(prefix='dmd-lsp-scope-')
SRC = os.path.join(ROOT, 'src')

MOD = '''module mod;

enum EventType { GFX_RESIZE, INPUT_KEY_DOWN }
struct Event { EventType type; int consumed; Vec2 resize; }
struct Vec2 { int width; int height; }

Event make_event() { return Event.init; }
'''

MAIN = '''module main;

import mod;

void on_event()
{
    EventType.
}

void on_process(Event*[] q)
{
    foreach (Event* ev; q)
    {
        ev.
        int bad = ;
    }
}

void on_resize(Event* ev)
{
    ev.
}

void on_make()
{
    Event e = {
        c
    };
}

void on_value()
{
    Event e2 = {
        type:
    };
}

void on_shadow()
{
    if (true)
    {
        Event e1;
        e1.
    }
    if (true)
    {
        Vec2 e1;
        e1.width = 1;
    }
}

void on_factory()
{
    auto ev = make_event().
}

void on_array()
{
    Event[] arr;
    arr.
}

void on_array_index()
{
    Event[] arr2;
    arr2[0].
}
'''

os.makedirs(SRC)
open(os.path.join(SRC, 'mod.d'), 'w').write(MOD)
MAIN_PATH = os.path.join(SRC, 'main.d')
open(MAIN_PATH, 'w').write(MAIN)
URI = 'file://' + MAIN_PATH

proc = subprocess.Popen([BIN, '--stdio', '--import=' + SRC],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL)

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

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

def complete_items(line, ch):
    send({"jsonrpc": "2.0", "id": 900, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": URI},
                     "position": {"line": line, "character": ch}}})
    return read()['result']['items']

def complete(line, ch):
    return [i['label'] for i in complete_items(line, ch)]

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None,
                 "capabilities": {"textDocument": {"completion": {
                     "completionItem": {"labelDetailsSupport": True}}}},
                 "initializationOptions": {"importPaths": [SRC]}}})
read()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": MAIN}}})
read()

lines = MAIN.split('\n')
def line_of(marker):
    return next(i for i, l in enumerate(lines) if marker in l)

# 1) imported enum, dotted from the type itself
el = line_of('EventType.')
labels = complete(el, len(lines[el]))
check('imported-enum-dot', 'GFX_RESIZE' in labels and 'INPUT_KEY_DOWN' in labels,
      str(labels[:6]))
# Plain prefix (before the dot): the imported enum type itself is in scope.
labels = complete(el, lines[el].index('EventType') + len('EventType'))
check('imported-type-in-scope', 'EventType' in labels, str(labels[:6]))

# 2) pointer loop var with a body-collapsing error
fl = line_of('foreach (Event* ev; q)')
evl = fl + 2  # `        ev.`
labels = complete(evl, len(lines[evl]))
check('loop-var-pointer-members',
      'type' in labels and 'consumed' in labels and 'resize' in labels,
      str(labels[:6]))

# The loop var's completion detail must show the full declared type, not the
# pointer-stripped name used internally for member resolution.
items = complete_items(evl, lines[evl].index('ev') + len('ev'))
evitem = next((i for i in items if i['label'] == 'ev'), None)
desc = evitem and evitem.get('labelDetails', {}).get('description')
check('loop-var-type-display', desc == 'Event*', str(desc))

# 3) pointer parameter (the `ev.` under on_resize, not the loop one)
rl = line_of('void on_resize')
pl = next(i for i, l in enumerate(lines) if i > rl and l.strip() == 'ev.')
labels = complete(pl, len(lines[pl]))
check('param-pointer-members',
      'type' in labels and 'consumed' in labels, str(labels[:6]))

# 4) designated struct initializer (`Event e = { ... }`) offers field names
il = line_of('Event e = {') + 1  # the `        c` line
labels = complete(il, len(lines[il]))
check('struct-init-fields', labels == ['consumed'], str(labels))

# 5) the value position (`field:`) must NOT scope to the type's fields; it
# uses normal completion (imported types, scope, ...).
vl = line_of('type:')
labels = complete(vl, len(lines[vl]))
check('struct-init-value-normal', 'Event' in labels and 'consumed' not in labels,
      str(sorted(set(labels))[:8]))

# 6) a sibling block's same-named variable must not shadow the cursor's own.
sl = line_of('e1.')
labels = complete(sl, len(lines[sl]))
check('scope-shadowing', 'resize' in labels and 'width' not in labels,
      str(sorted(set(labels))[:8]))

# 7) a member on a call result: `make_event().` -> Event's members.
cl = line_of('make_event().')
labels = complete(cl, len(lines[cl]))
check('call-result-members', 'resize' in labels and 'type' in labels,
      str(sorted(set(labels))[:8]))

# 8) a dynamic array local: `arr.` offers the built-in properties, not the
# element's fields (`Event`'s `type`/`consumed` must not appear).
al = line_of('    arr.')
labels = complete(al, len(lines[al]))
check('array-member-properties',
      'length' in labels and 'ptr' in labels and 'dup' in labels
      and 'type' not in labels and 'consumed' not in labels,
      str(sorted(set(labels))[:8]))
# Indexing on the same array completes on the *element* type.
ail = line_of('arr2[0].')
labels = complete(ail, len(lines[ail]))
check('array-index-element-members',
      'type' in labels and 'consumed' in labels, str(sorted(set(labels))[:8]))

proc.stdin.close()
proc.wait(timeout=5)
shutil.rmtree(ROOT, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
