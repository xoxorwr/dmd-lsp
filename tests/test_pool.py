import json, os, subprocess, sys, tempfile, time

# The worker pool holds up to `maxWorkers` single-root workers, LRU-evicted.
# Opening more distinct roots than the cap must not grow the pool, and
# revisiting a warm root must not spawn a new worker.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

if not os.path.isdir('/proc'):
    print('SKIP pool (no /proc)')
    sys.exit(0)

root = tempfile.mkdtemp(prefix='pool-')
names = ['a', 'b', 'c', 'd', 'e']
paths = []
for n in names:
    p = os.path.join(root, n + '.d')
    open(p, 'w').write('module %s;\nstruct S { int x; }\nS make%s() { return S(); }\n' % (n, n))
    paths.append(p)
uris = ['file://' + p for p in paths]

proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + root],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL)

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

def workers():
    """Direct children of the server (the pool workers)."""
    count = 0
    for e in os.listdir('/proc'):
        if not e.isdigit():
            continue
        try:
            st = open('/proc/%s/status' % e).read()
        except OSError:
            continue
        ppid = [l for l in st.split('\n') if l.startswith('PPid:')]
        if ppid and int(ppid[0].split()[1]) == proc.pid:
            count += 1
    return count

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": 'file://' + root, "capabilities": {},
                 "initializationOptions": {"maxWorkers": 2}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

for i, uri in enumerate(uris):
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": uri, "languageId": "d",
                                     "version": 1, "text": open(paths[i]).read()}}})
    read_msg()  # diagnostics
    w = workers()
    check('workers-after-%d' % (i + 1), w == min(i + 1, 2), 'workers=%d' % w)

# Revisit the first root: it was evicted when c.d was opened. The pool must
# stay at the cap (one eviction + one spawn), not grow.
send({"jsonrpc": "2.0", "id": 9, "method": "textDocument/hover",
      "params": {"textDocument": {"uri": uris[0]},
                 "position": {"line": 1, "character": 8}}})
read_msg()
w = workers()
check('workers-after-revisit', w <= 2, 'workers=%d' % w)

send({"jsonrpc": "2.0", "id": 4, "method": "shutdown", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
proc.stdin.close()
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
time.sleep(0.3)
left = 0
for e in os.listdir('/proc'):
    if not e.isdigit():
        continue
    try:
        st = open('/proc/%s/status' % e).read()
    except OSError:
        continue
    ppid = [l for l in st.split('\n') if l.startswith('PPid:')]
    if ppid and int(ppid[0].split()[1]) == proc.pid:
        left += 1
check('workers-reaped-on-exit', left == 0, 'left=%d' % left)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
