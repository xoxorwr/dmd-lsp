# Completion while editing a clean file, the way an editor drives it:
# incremental didChange per keystroke, with idle pauses in between.
#
# - A pause in the middle of a statement (`upng` before its `.`) makes the
#   idle pass analyse text the parser derails on; completion must not keep
#   answering from that analysis until the next save.
# - Types declared in a function body (struct, enum, alias, class) are in
#   scope after their declaration.
import json, os, shutil, subprocess, sys, tempfile, threading, time

BIN = os.path.abspath('./dmd-lsp')
ROOT = tempfile.mkdtemp(prefix='dmd-lsp-edits-')
FILE = os.path.join(ROOT, 'app.d')
URI = 'file://' + FILE
TEXT = '''module app;

struct Image { int width; int height; }

bool load(int n)
{
    Image img;
    img.width = n;
    // HERE

    if (img.width != 0)
    {
        return false;
    }
    return true;
}

void locals()
{
    struct LData { int field; }
    enum LKind { first, second }
    alias LAlias = int;
    class LClass {}
    // LOCALS
    struct LLater {}
}
'''
open(FILE, 'w').write(TEXT)

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

proc = subprocess.Popen([BIN, '--debounce-ms=200'], cwd=ROOT, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
lock = threading.Lock()
replies = {}

def send(obj):
    b = json.dumps(obj).encode()
    with lock:
        proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
        proc.stdin.flush()

def reader():
    while True:
        h = {}
        while True:
            line = proc.stdout.readline()
            if not line:
                return
            line = line.decode().strip()
            if not line:
                break
            k, v = line.split(':', 1)
            h[k.lower()] = v.strip()
        m = json.loads(proc.stdout.read(int(h['content-length'])))
        if 'method' in m:
            if 'id' in m:
                send({'jsonrpc': '2.0', 'id': m['id'], 'result': None})
            continue
        replies[m['id']] = m
threading.Thread(target=reader, daemon=True).start()

rid = [0]
def request(method, params):
    rid[0] += 1
    i = rid[0]
    send({'jsonrpc': '2.0', 'id': i, 'method': method, 'params': params})
    end = time.time() + 30
    while i not in replies and time.time() < end:
        time.sleep(0.005)
    return replies.pop(i, None)

def pos(l, c):
    return {'line': l, 'character': c}

version = [1]
def replace_line(l, old_len, text):
    version[0] += 1
    send({'jsonrpc': '2.0', 'method': 'textDocument/didChange',
          'params': {'textDocument': {'uri': URI, 'version': version[0]},
                     'contentChanges': [{'range': {'start': pos(l, 0), 'end': pos(l, old_len)},
                                         'text': text}]}})

def type_at(l, col, s):
    for ch in s:
        time.sleep(0.03)
        version[0] += 1
        send({'jsonrpc': '2.0', 'method': 'textDocument/didChange',
              'params': {'textDocument': {'uri': URI, 'version': version[0]},
                         'contentChanges': [{'range': {'start': pos(l, col), 'end': pos(l, col)},
                                             'text': ch}]}})
        col += 1
    return col

def complete(l, col):
    r = request('textDocument/completion', {'textDocument': {'uri': URI}, 'position': pos(l, col)})
    return [i['label'] for i in ((r or {}).get('result') or {}).get('items', [])]

request('initialize', {'rootUri': 'file://' + ROOT, 'capabilities': {}})
send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})
send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen',
      'params': {'textDocument': {'uri': URI, 'languageId': 'd', 'version': 1, 'text': TEXT}}})
time.sleep(0.8)
lines = TEXT.split('\n')

# 1) `img`, pause (the idle pass analyses a statement missing its `;`), `.`
hl = lines.index('    // HERE')
replace_line(hl, len(lines[hl]), '    ')
col = type_at(hl, 4, 'img')
time.sleep(0.8) # past the debounce: the half-typed text is analysed
col = type_at(hl, col, '.')
labels = complete(hl, col)
check('dot-after-idle-on-broken-text', 'width' in labels and 'height' in labels, str(labels[:6]))
col = type_at(hl, col, 'w')
time.sleep(0.8)
labels = complete(hl, col)
check('member-prefix-after-idle', 'width' in labels, str(labels[:6]))
# Restore the line (clean text again).
replace_line(hl, col, '    // HERE')
time.sleep(0.8)

# 2) local type declarations
ll = lines.index('    // LOCALS')
replace_line(ll, len(lines[ll]), '    ')
col = type_at(ll, 4, 'L')
labels = complete(ll, col)
check('local-type-decls',
      all(n in labels for n in ('LData', 'LKind', 'LAlias', 'LClass')) and 'LLater' not in labels,
      str(sorted(labels)[:10]))
replace_line(ll, col, '    ')
col = type_at(ll, 4, 'LKind.')
labels = complete(ll, col)
check('local-enum-members', 'first' in labels and 'second' in labels, str(labels[:6]))

check('alive', proc.poll() is None)
proc.terminate()
try:
    proc.wait(timeout=2)
except Exception:
    proc.kill()
shutil.rmtree(ROOT, ignore_errors=True)
print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
