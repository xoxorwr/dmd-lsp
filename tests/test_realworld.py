import json, subprocess, sys, tempfile, time, os, shutil

# End-to-end session against a small multi-module project, driven the way an
# editor does it: pipelined didChange + completion while typing, deletes,
# hover/definition, semantic-token pulls, and a second file. Checks that a
# handful of keystrokes does not fork a worker per key and that pulls stay
# responsive.

BIN = './dmd-lsp'
ROOT = tempfile.mkdtemp(prefix='dmd-lsp-rw-')
SRC = os.path.join(ROOT, 'src')
ERR = os.path.join(ROOT, 'err.txt')

GEOM = '''module rw.geom;

struct Vec2
{
    double x;
    double y;

    Vec2 opBinary(string op)(Vec2 rhs) if (op == "+")
        => Vec2(x + rhs.x, y + rhs.y);

    double length() const { return x * x + y * y; }
}

enum Direction : ubyte { north, south, east, west }

alias Scalar = double;
'''

ENTITY = '''module rw.entity;

import rw.geom;

struct Entity
{
    Vec2 position;
    Vec2 velocity;
    Direction facing;
    int health;
    string name;

    void move(Vec2 delta) { position = position + delta; }
    bool alive() const { return health > 0; }
}
'''

ASSETS = '''module rw.assets;

struct AssetCache
{
    string[] textures;
    string[] sounds;

    void load(string path) { textures ~= path; }
    int textureCount() const { return cast(int) textures.length; }
}
'''

WORLD = '''module rw.world;

import rw.entity;
import rw.assets;

struct World
{
    Entity[] entities;
    AssetCache assets;
    int tick;

    Entity spawn(Vec2 at, string name)
    {
        Entity e;
        e.position = at;
        e.name = name;
        e.health = 100;
        entities ~= e;
        return entities[$ - 1];
    }

    void update(double dt)
    {
        tick++;
        foreach (ref e; entities)
            e.move(e.velocity);
    }
}
'''

MAIN = '''module rw.main;

import rw.world;
import rw.entity;
import rw.geom;
import rw.assets;

void on_init(World* w)
{
    auto e = w.spawn(Vec2(1, 2), "player");
    w.assets.load("hero.png");
}

int main()
{
    World w;
    on_init(&w);
    w.assets.
    return 0;
}
'''

files = {'rw/geom.d': GEOM, 'rw/entity.d': ENTITY, 'rw/assets.d': ASSETS,
         'rw/world.d': WORLD, 'rw/main.d': MAIN}
for rel, text in files.items():
    p = os.path.join(SRC, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w').write(text)

MAIN_PATH = os.path.join(SRC, 'rw/main.d')
WORLD_PATH = os.path.join(SRC, 'rw/world.d')
MAIN_URI = 'file://' + MAIN_PATH
WORLD_URI = 'file://' + WORLD_PATH

errf = open(ERR, 'w')
proc = subprocess.Popen(
    [BIN, '--stdio', '--debounce-ms=250', '--import=' + SRC],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errf,
    env=dict(os.environ, DMD_LSP_TRACE_SPAWN='1'))

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

def pump(mid, refresh=True):
    while True:
        m = read()
        if m.get('method') == 'workspace/semanticTokens/refresh':
            send({"jsonrpc": "2.0", "id": m['id'], "result": None})
            continue
        if m.get('id') == mid:
            return m

def spawns():
    errf.flush()
    return open(ERR).read().count('spawn')

def request(method, params):
    global _id
    _id += 1
    send({"jsonrpc": "2.0", "id": _id, "method": method, "params": params})
    return pump(_id)

_id = 0
send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": 'file://' + ROOT,
                 "capabilities": {
                     "textDocument": {
                         "completion": {"completionItem": {"labelDetailsSupport": True}},
                         "semanticTokens": {}},
                     "workspace": {"semanticTokens": {"refreshSupport": True}}},
                 "initializationOptions": {"importPaths": [SRC]}}})
init = read()
legend = init['result']['capabilities']['semanticTokensProvider']['legend']
stypes = legend['tokenTypes']
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# --- open main.d ---
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": MAIN_URI, "languageId": "d",
                                 "version": 1, "text": MAIN}}})
while True:
    m = read()
    if m.get('method') == 'workspace/semanticTokens/refresh':
        send({"jsonrpc": "2.0", "id": m['id'], "result": None})
        continue
    if m.get('method') == 'textDocument/publishDiagnostics':
        break
open_spawns = spawns()
check('open-one-worker', open_spawns == 1, 'spawns=%d' % open_spawns)

lines = MAIN.split('\n')
dot_line = next(i for i, l in enumerate(lines) if l.strip() == 'w.assets.')
dot_col = lines[dot_line].rindex('.') + 1  # right after the member dot

def with_member(m):
    l = list(lines)
    l[dot_line] = '    w.assets.' + m
    return '\n'.join(l)

# --- real typing: pipeline didChange + completion per key, cancelling prev ---
before = spawns()
prev = None
cids = []
for i, ch in enumerate('load'):
    member = 'load'[:i + 1]
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": MAIN_URI, "version": 2 + i},
                     "contentChanges": [{"text": with_member(member)}]}})
    if prev is not None:
        send({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": prev}})
    _id += 1
    cids.append(_id)
    ctx = {"triggerKind": 2, "triggerCharacter": "."} if i == 0 else {"triggerKind": 3}
    send({"jsonrpc": "2.0", "id": _id, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": MAIN_URI},
                     "position": {"line": dot_line, "character": dot_col + len(member)},
                     "context": ctx}})
    prev = _id
typed_items = {}
while len(typed_items) < len(cids):
    m = read()
    if m.get('method') == 'workspace/semanticTokens/refresh':
        send({"jsonrpc": "2.0", "id": m['id'], "result": None})
        continue
    if m.get('id') in cids:
        r = m.get('result', {})
        typed_items[m['id']] = [i['label'] for i in r.get('items', [])]
typing_spawns = spawns() - before
check('typing-completion-items', 'load' in typed_items.get(cids[-1], []),
      str(typed_items.get(cids[-1])))
check('typing-bounded-builds', typing_spawns <= 2, 'extra_spawns=%d' % typing_spawns)

# --- deletes, same pipelined pattern ---
before = spawns()
prev = None
dids = []
for i, member in enumerate(['loa', 'lo', 'l', '']):
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": MAIN_URI, "version": 20 + i},
                     "contentChanges": [{"text": with_member(member)}]}})
    if prev is not None:
        send({"jsonrpc": "2.0", "method": "$/cancelRequest", "params": {"id": prev}})
    _id += 1
    dids.append(_id)
    send({"jsonrpc": "2.0", "id": _id, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": MAIN_URI},
                     "position": {"line": dot_line, "character": dot_col + len(member)},
                     "context": {"triggerKind": 3}}})
    prev = _id
while len(dids):
    m = read()
    if m.get('method') == 'workspace/semanticTokens/refresh':
        send({"jsonrpc": "2.0", "id": m['id'], "result": None})
        continue
    if m.get('id') in dids:
        dids.remove(m['id'])
delete_spawns = spawns() - before
check('delete-bounded-builds', delete_spawns <= 2, 'extra_spawns=%d' % delete_spawns)

# --- hover + goto on a real symbol (a type use, stable in a broken buffer) ---
wl = next(i for i, l in enumerate(lines) if l.strip() == 'World w;')
h = request("textDocument/hover",
            {"textDocument": {"uri": MAIN_URI},
             "position": {"line": wl, "character": lines[wl].index('World')}})
hv = h.get('result')
check('hover-symbol', hv is not None and 'World' in hv['contents']['value'],
      str(hv)[:70])
g = request("textDocument/definition",
            {"textDocument": {"uri": MAIN_URI},
             "position": {"line": wl, "character": lines[wl].index('World')}})
check('goto-symbol', g.get('result') is not None
      and g['result'][0]['uri'].endswith('world.d'), str(g.get('result')))

# --- settle, then semantic pull: cached/computed quickly ---
time.sleep(0.6)
t0 = time.time()
sem = request("textDocument/semanticTokens/full", {"textDocument": {"uri": MAIN_URI}})
dt = time.time() - t0
data = sem['result']['data']
check('semantic-pull-fast', dt < 0.5, 'dt=%.3fs' % dt)
check('semantic-has-tokens', len(data) // 5 > 10, 'tokens=%d' % (len(data) // 5))

# --- second file: open + edit world.d ---
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": WORLD_URI, "languageId": "d",
                                 "version": 1, "text": WORLD}}})
while True:
    m = read()
    if m.get('method') == 'workspace/semanticTokens/refresh':
        send({"jsonrpc": "2.0", "id": m['id'], "result": None})
        continue
    if m.get('method') == 'textDocument/publishDiagnostics':
        break

# edit world.d: rename a field, keep it valid; then pull its tokens
WORLD2 = WORLD.replace('int tick;', 'int ticks;').replace('tick++;', 'ticks++;')
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": WORLD_URI, "version": 2},
                 "contentChanges": [{"text": WORLD2}]}})
time.sleep(0.5)
wsem = request("textDocument/semanticTokens/full", {"textDocument": {"uri": WORLD_URI}})
check('second-file-tokens', len(wsem['result']['data']) // 5 > 5,
      'tokens=%d' % (len(wsem['result']['data']) // 5))

# --- save main.d ---
send({"jsonrpc": "2.0", "method": "textDocument/didSave",
      "params": {"textDocument": {"uri": MAIN_URI}}})
while True:
    m = read()
    if m.get('method') == 'workspace/semanticTokens/refresh':
        send({"jsonrpc": "2.0", "id": m['id'], "result": None})
        continue
    if m.get('method') == 'textDocument/publishDiagnostics':
        break

total = spawns()
# open + world open + a couple of atext builds for the typing/deleting above.
check('session-bounded-builds', total <= 8, 'total_spawns=%d' % total)

send({"jsonrpc": "2.0", "id": 9999, "method": "shutdown", "params": {}})
read()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
try:
    proc.stdin.close()
except Exception:
    pass
proc.wait(timeout=5)
errf.close()
shutil.rmtree(ROOT, ignore_errors=True)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
