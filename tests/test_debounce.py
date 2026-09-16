import json, os, select, subprocess, sys, tempfile, time

# Debounce regression (default 500ms idle delay):
#  - didChange publishes nothing promptly; diagnostics arrive after idle
#  - a rapid burst of changes coalesces into exactly one publish
#  - completion during pending serves fresh results without publishing
BIN = './dmd-lsp'
WORK = tempfile.mkdtemp(prefix='dmd-lsp-debounce-')

with open(os.path.join(WORK, 'droot.d'), 'w') as f:
    f.write('module droot;\nvoid main() {\n    int ok = 1;\n}\n')
ROOT = os.path.join(WORK, 'droot.d')
URI = 'file://' + ROOT

# bufsize=0: select() must see every byte; buffered readahead would hide
# queued messages from it and misalign the stream.
proc = subprocess.Popen([BIN, '--import=' + WORK], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, bufsize=0)

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

def msg_ready(timeout):
    r, _, _ = select.select([proc.stdout], [], [], timeout)
    return bool(r)

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None, "capabilities": {}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# didOpen publishes promptly (no debounce on open)
text = open(ROOT).read()
send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": text}}})
check('debounce-open-prompt', msg_ready(5), '')
d = read_msg()
check('debounce-open-clean', d['params']['diagnostics'] == [], str(d['params']))

# didChange: silence within the debounce window, publish after idle
bad1 = text.replace('int ok = 1;', 'int ok = 1;\n    alpha_missing;')
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": URI, "version": 2},
                 "contentChanges": [{"text": bad1}]}})
check('debounce-silence', not msg_ready(0.15), '')
check('debounce-arrives', msg_ready(5), '')
d = read_msg()
msgs = [x['message'] for x in d['params']['diagnostics']]
check('debounce-publishes-change', any('alpha_missing' in m for m in msgs), str(msgs))

# burst of 3 rapid changes coalesces into exactly one publish (latest wins)
bad2 = text.replace('int ok = 1;', 'int ok = 1;\n    beta_missing;')
bad3 = text.replace('int ok = 1;', 'int ok = 1;\n    gamma_missing;')
bad4 = text.replace('int ok = 1;', 'int ok = 1;\n    delta_missing;')
for i, t in enumerate((bad2, bad3, bad4)):
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 3 + i},
                     "contentChanges": [{"text": t}]}})
check('debounce-burst-arrives', msg_ready(5), '')
d = read_msg()
msgs = [x['message'] for x in d['params']['diagnostics']]
check('debounce-coalesced-once', not msg_ready(0.6), '')
check('debounce-latest-wins',
      any('delta_missing' in m for m in msgs) and
      not any('beta_missing' in m or 'gamma_missing' in m for m in msgs),
      str(msgs))

# completion on pending text serves fresh results, publishes nothing itself
open(ROOT, 'w').write(bad4)
send({"jsonrpc": "2.0", "id": 100, "method": "textDocument/completion",
      "params": {"textDocument": {"uri": URI},
                 "position": {"line": 0, "character": 1}}})
check('debounce-completion-responds', msg_ready(5), '')
r = read_msg()
check('debounce-completion-ok', r.get('result') is not None, '')

print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
