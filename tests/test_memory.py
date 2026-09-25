import json, os, select, subprocess, sys, tempfile, time

# Memory regression for the in-process engine (docs/design.md, "Memory
# levels"). Everything runs in the server process; there are no workers. The
# invariants:
#  * the server never spawns a process;
#  * acyclic editing (the root is imported by nothing) stays flat;
#  * cyclic editing (the root's importer is re-analysed with it) stays flat;
#  * switching between roots stays flat: a superseded analysis is unmapped
#    with its level, whatever still pointed into it.
# RSS is the server's own.
BIN = './dmd-lsp'

WORK = tempfile.mkdtemp(prefix='dmd-lsp-mem-')
with open(os.path.join(WORK, 'mdep.d'), 'w') as f:
    f.write('module mdep;\nstruct Item { int a; int b; }\nint touch(int x) { return x + 1; }\n')
body = '\n'.join('int fn%d(int x) { return x + %d; }' % (i, i) for i in range(1200))
ROOT = os.path.join(WORK, 'mroot.d')
with open(ROOT, 'w') as f:
    f.write('module mroot;\nimport mdep;\nstruct S { Item it; }\n' + body + '\n')
URI = 'file://' + ROOT

proc = subprocess.Popen([BIN, '--import=' + WORK, '--debounce-ms=0'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL)

def send(obj):
    b = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    proc.stdin.flush()

def read_msg(timeout=120):
    r, _, _ = select.select([proc.stdout], [], [], timeout)
    if not r:
        return None
    h = {}
    while True:
        line = proc.stdout.readline().decode().strip()
        if not line:
            break
        k, v = line.split(':', 1)
        h[k.strip().lower()] = v.strip()
    n = int(h['content-length'])
    data = b''
    while len(data) < n:
        data += proc.stdout.read(n - len(data))
    return json.loads(data)

def children():
    try:
        return subprocess.run(['pgrep', '-P', str(proc.pid)],
                              capture_output=True, text=True).stdout.split()
    except Exception:
        return []

def rss_kb():
    try:
        with open('/proc/%d/status' % proc.pid) as f:
            for l in f:
                if l.startswith('VmRSS'):
                    return int(l.split()[1])
    except Exception:
        pass
    return 0

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None, "capabilities": {}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# ---- acyclic: the root is imported by nothing, so it stays in place ----
text = open(ROOT).read()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": text}}})
read_msg()
time.sleep(0.5)
# Warm up (first overlays, first collections), then measure.
bad = text
for i in range(5):
    bad = bad.replace('int fn0(int x)', 'int fn0_w%d(int x)' % i, 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 100 + i},
                     "contentChanges": [{"text": bad}]}})
    read_msg()
base = rss_kb()
for i in range(60):
    bad = bad.replace('int fn0(int x)', 'int fn0_%d(int x)' % i, 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 2 + i},
                     "contentChanges": [{"text": bad}]}})
    read_msg()
peak = rss_kb()
growth = peak - base
print('acyclic base=%d kB peak=%d kB growth=%d kB' % (base, peak, growth))
check('memory-flat-acyclic', growth < 8 * 1024, 'growth=%d kB' % growth)
check('acyclic-in-process', not children(), str(children()))
check('alive', proc.poll() is None, '')

# ---- cyclic: a imports b and b imports a, so a's root has a resident importer ----
ca, cb = os.path.join(WORK, 'cyc_a.d'), os.path.join(WORK, 'cyc_b.d')
abase = ('module cyc_a;\nimport cyc_b;\nint aFn() { return 1; }\n')
bbase = ('module cyc_b;\nimport cyc_a;\nint bFn() { return 2; }\n')
open(ca, 'w').write(abase)
open(cb, 'w').write(bbase)
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": 'file://' + ca, "languageId": "d",
                                 "version": 1, "text": abase}}})
read_msg()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": 'file://' + cb, "languageId": "d",
                                 "version": 1, "text": bbase}}})
read_msg()
time.sleep(0.5)
cur = abase
for i in range(5):
    cur = cur.replace('int aFn()', 'int aFn_w%d()' % i, 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": 'file://' + ca, "version": 100 + i},
                     "contentChanges": [{"text": cur}]}})
    read_msg()
cbase = rss_kb()
worst = cbase
for i in range(60):
    cur = cur.replace('int aFn()', 'int aFn_%d()' % i, 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": 'file://' + ca, "version": 2 + i},
                     "contentChanges": [{"text": cur}]}})
    read_msg()
    worst = max(worst, rss_kb())
cgrowth = worst - cbase
print('cyclic base=%d kB worst=%d kB growth=%d kB' % (cbase, worst, cgrowth))
check('memory-flat-cyclic', cgrowth < 8 * 1024, 'growth=%d kB' % cgrowth)
check('alive2', proc.poll() is None, '')

# ---- root switching: alternate between the documents, editing each ----
def edit(uri, text, v):
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": uri, "version": v},
                     "contentChanges": [{"text": text}]}})
    read_msg()

sbase = rss_kb()
sworst = sbase
for i in range(40):
    edit(URI, bad + '\n// %d\n' % i, 1000 + i)
    edit('file://' + cb, bbase + '\n// %d\n' % i, 1000 + i)
    edit('file://' + ca, cur + '\n// %d\n' % i, 1000 + i)
    sworst = max(sworst, rss_kb())
sgrowth = sworst - sbase
print('switch base=%d kB worst=%d kB growth=%d kB' % (sbase, sworst, sgrowth))
check('memory-flat-switching', sgrowth < 12 * 1024, 'growth=%d kB' % sgrowth)
check('never-spawned', not children(), str(children()))
check('alive3', proc.poll() is None, '')

proc.stdin.close()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()

print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
