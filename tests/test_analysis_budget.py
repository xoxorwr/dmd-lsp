# Analysis budget: the cache must answer everything that does not change the
# text dmd reads. A realistic session (open, editor pulls, typing with
# completion/signature help, a second file, references, save, close, a
# dependency changing on disk) with the number of analyses, dependency-level
# and warm-level builds each step is allowed. The server logs each one under
# DMD_LSP_TIMING=1 (engine.d), with the reason.
import json, os, select, subprocess, sys, time, tempfile, collections
BIN = os.path.abspath('./dmd-lsp')
W = tempfile.mkdtemp(prefix='dmd-lsp-audit-')
LIB = '''module lib;
struct Vec2 { float x, y; }
float dot(Vec2 a, Vec2 b) { return a.x * b.x + a.y * b.y; }
enum Kind { player, enemy }
'''
UTIL = '''module util;
import lib;
import std.format : format;
string describe(Vec2 v) { return format("(%s, %s)", v.x, v.y); }
Vec2 scale(Vec2 v, float k) { return Vec2(v.x * k, v.y * k); }
'''
APP = '''module app;
import std.stdio, std.algorithm, std.array, std.conv;
import lib, util;

struct Entity { Vec2 pos; Kind kind; string name; }

Entity[] spawnAll(int n)
{
    return iota(0, n).map!(i => Entity(Vec2(i, i), Kind.enemy, "e" ~ to!string(i))).array;
}

void main()
{
    auto es = spawnAll(10);
    foreach (e; es)
        writeln(describe(e.pos), " ", e.name);
    auto total = es.map!(e => dot(e.pos, e.pos)).sum;
    enum boss = Kind.player + 1;
    auto k = Kind.player;
    writeln(total);
}
'''
for n, t in (('lib.d', LIB), ('util.d', UTIL), ('app.d', APP)):
    open(os.path.join(W, n), 'w').write(t)
ERR = os.path.join(W, 'stderr.txt')
p = subprocess.Popen([BIN, '--import=' + W, '--debounce-ms=150'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=open(ERR, 'w'), env=dict(os.environ, DMD_LSP_TIMING='1'))
BUF = [b'']; pending = []
def send(o):
    b = json.dumps(o).encode(); p.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b); p.stdin.flush()
def read(t):
    end = time.time() + t
    while True:
        i = BUF[0].find(b'\r\n\r\n')
        if i >= 0:
            n = int(BUF[0][:i].decode().split(':')[1])
            if len(BUF[0]) >= i + 4 + n:
                m = json.loads(BUF[0][i+4:i+4+n]); BUF[0] = BUF[0][i+4+n:]; return m
        left = end - time.time()
        if left <= 0: return None
        r,_,_ = select.select([p.stdout],[],[],left)
        if not r: return None
        BUF[0] += os.read(p.stdout.fileno(), 1 << 20)
rid = [100]
serverReqs = []
def handle(m):
    if m.get('method') and 'id' in m:   # server->client request (refresh, registration)
        serverReqs.append(m['method']); send({"jsonrpc":"2.0","id":m['id'],"result":None}); return True
    return False
def request(method, params):
    rid[0] += 1; r = rid[0]
    send({"jsonrpc":"2.0","id":r,"method":method,"params":params})
    while True:
        m = read(60)
        if m is None: return None
        if handle(m): continue
        if m.get('id') == r: return m.get('result')
def notify(method, params): send({"jsonrpc":"2.0","method":method,"params":params})
def idle(t=0.6):
    end = time.time() + t
    while time.time() < end:
        m = read(end - time.time())
        if m: handle(m)
# ---- attribution
off = [0]
log = collections.OrderedDict()
def mark(label):
    time.sleep(0.05)
    s = open(ERR).read(); new = s[off[0]:]; off[0] = len(s)
    ev = [l.split('] ',1)[1] for l in new.splitlines() if l.startswith('dmd-lsp[timing]') and any(k in l for k in ('] analyze', '] deps', '] warm'))]
    log[label] = ev
def uri(n): return 'file://' + os.path.join(W, n)
def pos(text, needle, after=0):
    i = text.index(needle) + len(needle) + after
    line = text[:i].count('\n'); col = i - (text[:i].rfind('\n') + 1); return {"line": line, "character": col}
TD = lambda n: {"uri": uri(n)}
caps = {"textDocument": {"completion": {"completionItem": {"labelDetailsSupport": True}},
        "semanticTokens": {"requests": {"full": True}}, "inlayHint": {}},
        "workspace": {"semanticTokens": {"refreshSupport": True}, "inlayHint": {"refreshSupport": True},
                      "didChangeWatchedFiles": {"dynamicRegistration": True}}}
def editor_pulls(n, text, tag):
    request('textDocument/semanticTokens/full', {"textDocument": TD(n)}); mark(tag + ' semanticTokens')
    request('textDocument/documentSymbol', {"textDocument": TD(n)}); mark(tag + ' documentSymbol')
    request('textDocument/foldingRange', {"textDocument": TD(n)}); mark(tag + ' foldingRange')
    request('textDocument/inlayHint', {"textDocument": TD(n), "range": {"start": {"line":0,"character":0}, "end": {"line": text.count('\n'), "character": 0}}}); mark(tag + ' inlayHint')
    request('textDocument/codeAction', {"textDocument": TD(n), "range": {"start": {"line":1,"character":0}, "end": {"line":1,"character":5}}, "context": {"diagnostics": []}}); mark(tag + ' codeAction')
    request('textDocument/documentLink', {"textDocument": TD(n)}); mark(tag + ' documentLink')
fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

def budget(label, analyses, deps=0, warm=0):
    ev = log[label]
    got = (sum(1 for e in ev if e.startswith('analyze')), sum(1 for e in ev if e.startswith('deps')),
           sum(1 for e in ev if e.startswith('warm')))
    check('budget: ' + label, got == (analyses, deps, warm),
          'analyses/deps/warm = %s, want %s  %s' % (got, (analyses, deps, warm), '; '.join(ev)))

request('initialize', {"rootUri": 'file://' + W, "capabilities": caps, "initializationOptions": {"inlayHints": True}})
notify('initialized', {}); idle(0.3); mark('initialize')
notify('textDocument/didOpen', {"textDocument": {"uri": uri('app.d'), "languageId": "d", "version": 1, "text": APP}}); idle(1.0); mark('open app.d')
editor_pulls('app.d', APP, 'app'); mark('pulls after open')
request('textDocument/hover', {"textDocument": TD('app.d'), "position": pos(APP, 'auto es = spawn', 1)})
request('textDocument/definition', {"textDocument": TD('app.d'), "position": pos(APP, 'writeln(desc', 1)})
request('textDocument/documentHighlight', {"textDocument": TD('app.d'), "position": pos(APP, 'foreach (e; e', 0)}); mark('navigation')
ver = [1]; cur = [APP]
anchor = '    writeln(total);\n'
typed = '    auto v = es[0].pos.x;\n    auto w = scale(v'
for k in range(1, len(typed) + 1):
    ver[0] += 1
    t = APP.replace(anchor, anchor + typed[:k] + '\n'); cur[0] = t
    notify('textDocument/didChange', {"textDocument": {"uri": uri('app.d'), "version": ver[0]}, "contentChanges": [{"text": t}]})
    ch = typed[k-1]
    if ch == '.' or (ch.isalpha() and k % 3 == 0):
        request('textDocument/completion', {"textDocument": TD('app.d'), "position": pos(t, anchor + typed[:k])})
    if ch == '(':
        request('textDocument/signatureHelp', {"textDocument": TD('app.d'), "position": pos(t, anchor + typed[:k])})
    if k % 7 == 0:
        request('textDocument/semanticTokens/full', {"textDocument": TD('app.d')})
    time.sleep(0.03)
mark('typing')
idle(1.0); mark('debounce after typing')
request('textDocument/semanticTokens/full', {"textDocument": TD('app.d')})
request('textDocument/hover', {"textDocument": TD('app.d'), "position": pos(cur[0], 'auto es = spawn', 1)})
request('textDocument/completion', {"textDocument": TD('app.d'), "position": pos(cur[0], 'es[0].pos.', 0)}); mark('requests after debounce')
notify('textDocument/didOpen', {"textDocument": {"uri": uri('util.d'), "languageId": "d", "version": 1, "text": UTIL}}); idle(1.0); mark('open unedited util.d')
editor_pulls('util.d', UTIL, 'util')
request('textDocument/hover', {"textDocument": TD('app.d'), "position": pos(cur[0], 'auto es = spawn', 1)}); mark('back in app.d')
RR = request('textDocument/references', {"textDocument": TD('app.d'), "position": pos(cur[0], 'writeln(desc', 1), "context": {"includeDeclaration": True}}); mark('references to a function')
check('references-found', sorted((r['uri'].rsplit('/', 1)[1], r['range']['start']['line']) for r in (RR or [])) == [('app.d', 15), ('util.d', 3)], str(RR))
open(os.path.join(W, 'app.d'), 'w').write(cur[0])
notify('textDocument/didSave', {"textDocument": {"uri": uri('app.d')}, "text": cur[0]})
notify('workspace/didChangeWatchedFiles', {"changes": [{"uri": uri('app.d'), "type": 2}]}); idle(1.0); mark('save (+watched-file echo)')
notify('textDocument/didClose', {"textDocument": TD('util.d')}); idle(0.5)
request('textDocument/hover', {"textDocument": TD('app.d'), "position": pos(cur[0], 'auto es = spawn', 1)}); mark('close unedited util.d')
for i in range(3):
    request('textDocument/semanticTokens/full', {"textDocument": TD('app.d')})
    request('textDocument/hover', {"textDocument": TD('app.d'), "position": pos(cur[0], 'writeln(desc', 1)})
mark('repeated pulls')
open(os.path.join(W, 'lib.d'), 'w').write(LIB + 'float len(Vec2 v) { return dot(v, v); }\n')
notify('workspace/didChangeWatchedFiles', {"changes": [{"uri": uri('lib.d'), "type": 2}]}); idle(1.0); mark('dependency changed on disk')
request('textDocument/hover', {"textDocument": TD('app.d'), "position": pos(cur[0], 'auto es = spawn', 1)}); mark('hover after dependency change')
request('shutdown', None); notify('exit', None)

budget('open app.d', 1, deps=1, warm=1)
budget('pulls after open', 0)
budget('navigation', 0)
budget('typing', 0)              # completion, signature help, token pulls: cache
budget('debounce after typing', 1)
budget('requests after debounce', 0)
budget('open unedited util.d', 1) # a root added to the same overlay
budget('back in app.d', 0)
budget('references to a function', 0)
budget('save (+watched-file echo)', 0)
budget('close unedited util.d', 0)
budget('repeated pulls', 0)
budget('dependency changed on disk', 1, deps=1, warm=1) # the open document, re-analysed on the debounce
budget('hover after dependency change', 0)
print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
