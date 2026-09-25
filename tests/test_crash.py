import json, os, select, subprocess, sys, tempfile, time

# Crash recovery. An op that throws (e.g. a frontend assert) is logged with its
# op, message and stack; the engine drops its dmd levels, which restores a clean
# frontend, and the server keeps serving in the same process.
# `DMD_LSP_CRASH_TEST=1` makes the first `analyze` throw an Error; `=segv`
# makes it fault (a null write), which druntime turns into an Error.
# Usage: test_crash.py [1|segv]
BIN = './dmd-lsp'

WORK = tempfile.mkdtemp(prefix='dmd-lsp-crash-')
ROOT = os.path.join(WORK, 'croot.d')
with open(ROOT, 'w') as f:
    f.write('module croot;\nint f(int x) { return x + 1; }\n')
URI = 'file://' + ROOT
ERR = os.path.join(WORK, 'stderr.txt')

MODE = sys.argv[1] if len(sys.argv) > 1 else '1'
env = dict(os.environ, DMD_LSP_CRASH_TEST=MODE)
proc = subprocess.Popen([BIN, '--import=' + WORK, '--debounce-ms=0'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=open(ERR, 'w'), env=env)


def send(obj):
    b = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    proc.stdin.flush()


def read_msg(timeout=30):
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


fails = []


def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)


send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None, "capabilities": {}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1,
                                 "text": open(ROOT).read()}}})
# The first analyze throws; the front end retries once, on a clean engine.
diag = None
end = time.time() + 20
while time.time() < end:
    m = read_msg(1.0)
    if m and m.get('method') == 'textDocument/publishDiagnostics':
        diag = m
        break
check('recovered-diagnostics', diag is not None and diag['params']['diagnostics'] == [],
      str(diag)[:200])
# Still serving: a hover on `f`.
send({"jsonrpc": "2.0", "id": 7, "method": "textDocument/hover",
      "params": {"textDocument": {"uri": URI}, "position": {"line": 1, "character": 4}}})
hov = None
end = time.time() + 20
while time.time() < end:
    m = read_msg(1.0)
    if m and m.get('id') == 7:
        hov = m
        break
check('serves-after-crash', hov is not None and hov.get('result') is not None, str(hov)[:200])
alive = proc.poll() is None
proc.stdin.close()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
err = open(ERR).read()
print('--- stderr ---')
for line in err.splitlines()[-12:]:
    print(line)
check('logs-failed-op', 'op FAILED op=analyze' in err, '')
check('logs-message', ('intentional crash test' if MODE != 'segv' else 'memory fault') in err, '')
check('logs-stack', '  ??:?' in err or 'serveRequest' in err or '  at ' in err, '')
check('same-process', alive, 'server exited')
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
