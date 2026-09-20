import json, os, select, subprocess, sys, tempfile, time

# Memory regression. Two invariants:
#  * acyclic editing (the root is imported by nothing) stays on the flat
#    in-place path — no respawn, RSS roughly flat;
#  * cyclic editing (the root has a resident importer) must reclaim at the
#    process boundary — the worker is respawned and RSS stays bounded instead
#    of pinning one replaced universe per edit.
# The pool (one worker per root) is the default; `rss` sums the worker
# processes, not the thin server.
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

def worker_pids():
    out = []
    try:
        kids = subprocess.run(['pgrep', '-P', str(proc.pid)],
                              capture_output=True, text=True).stdout.split()
        for k in kids:
            out.append(k)
            out += subprocess.run(['pgrep', '-P', k],
                                  capture_output=True, text=True).stdout.split()
    except Exception:
        pass
    return set(out)

def rss_kb(pid):
    try:
        with open('/proc/%s/status' % pid) as f:
            for l in f:
                if l.startswith('VmRSS'):
                    return int(l.split()[1])
    except Exception:
        pass
    return 0

def total_rss():
    return sum(rss_kb(p) for p in worker_pids())

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
base = total_rss()
pids0 = worker_pids()
bad = text
for i in range(30):
    bad = bad.replace('int fn0(int x)', 'int fn0_%d(int x)' % i, 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 2 + i},
                     "contentChanges": [{"text": bad}]}})
    read_msg()
peak = total_rss()
growth = peak - base
print('acyclic base=%d kB peak=%d kB growth=%d kB' % (base, peak, growth))
check('memory-bounded-acyclic', growth < 30 * 1024, 'growth=%d kB' % growth)
check('acyclic-no-respawn', worker_pids() == pids0, str(worker_pids() ^ pids0))
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
cbase = total_rss()
initial = worker_pids()
seen = set(initial)
worst = cbase
cur = abase
for i in range(40):
    cur = cur.replace('int aFn()', 'int aFn_%d()' % i, 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": 'file://' + ca, "version": 2 + i},
                     "contentChanges": [{"text": cur}]}})
    read_msg()
    time.sleep(0.05)
    seen |= worker_pids()
    worst = max(worst, total_rss())
cgrowth = worst - cbase
print('cyclic base=%d kB worst=%d kB growth=%d kB' % (cbase, worst, cgrowth))
check('memory-bounded-cyclic', cgrowth < 60 * 1024, 'growth=%d kB' % cgrowth)
check('cyclic-respawned', len(seen) > len(initial),
      'distinct workers seen=%d initial=%d' % (len(seen), len(initial)))
check('alive2', proc.poll() is None, '')

proc.stdin.close()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()

print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
