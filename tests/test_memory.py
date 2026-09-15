import json, os, subprocess, sys, tempfile

# Memory regression: the LSP front end must stay small no matter how many
# rebuilds happen. dmd's process-global state isn't fully reset by
# deinitializeDMD, so analysis runs in a forked worker (one universe per
# worker). If analysis ever moves back in-process, the parent RSS grows by
# roughly a universe per edit and this test fails hard.
BIN = './dmd-lsp'

WORK = tempfile.mkdtemp(prefix='dmd-lsp-mem-')
with open(os.path.join(WORK, 'mdep.d'), 'w') as f:
    f.write('module mdep;\nstruct Item { int a; int b; }\nint touch(int x) { return x + 1; }\n')
# A non-trivial root so a universe isn't tiny.
body = '\n'.join('int fn%d(int x) { return x + %d; }' % (i, i) for i in range(1200))
with open(os.path.join(WORK, 'mroot.d'), 'w') as f:
    f.write('module mroot;\nimport mdep;\nstruct S { Item it; }\n' + body + '\n')
ROOT = os.path.join(WORK, 'mroot.d')
URI = 'file://' + ROOT

proc = subprocess.Popen([BIN, '--import=' + WORK, '--debounce-ms=0'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL)

def send(obj):
    b = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    proc.stdin.flush()

def read_msg():
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

def rss_kb():
    with open('/proc/%d/status' % proc.pid) as f:
        for l in f:
            if l.startswith('VmRSS'):
                return int(l.split()[1])
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

text = open(ROOT).read()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": text}}})
read_msg()
base = rss_kb()

bad = text
for i in range(30):
    bad = bad.replace('int fn0(int x)', 'int fn0_%d(int x)' % i, 1)
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 2 + i},
                     "contentChanges": [{"text": bad}]}})
    read_msg()

peak = rss_kb()
growth = peak - base
print('base=%d kB peak=%d kB growth=%d kB' % (base, peak, growth))
check('memory-bounded', growth < 30 * 1024, 'growth=%d kB' % growth)
check('alive', proc.poll() is None, '')

print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
