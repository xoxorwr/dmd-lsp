import json, os, select, subprocess, sys, tempfile

# Regression: a trivia-only save (e.g. adding a blank line) must not re-analyse.
# In a cyclic project the in-place root re-parse left importers holding stale
# symbols, so a blank line made a valid call report "not callable". Trivia is
# detected with a significant-token fingerprint (comments/whitespace are not
# tokens; literal contents are), so a real edit still analyzes.
BIN = './dmd-lsp'
WORK = tempfile.mkdtemp(prefix='dmd-lsp-trivia-')

with open(os.path.join(WORK, 'a.d'), 'w') as f:
    f.write('module a;\nimport b;\nstruct EA {}\n'
            'void fn(EA* e, B* b) {}\n')
B = os.path.join(WORK, 'b.d')
with open(B, 'w') as f:
    f.write('module b;\nimport a;\nstruct B { EA e; }\n'
            'void g(B* b)\n{\n    fn(&b.e, b);\n}\n')
GOOD = open(B).read()
URI = 'file://' + B

proc = subprocess.Popen([BIN, '--import=' + WORK, '--debounce-ms=0'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)

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

def ready(timeout):
    return bool(select.select([proc.stdout], [], [], timeout)[0])

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

def save(text):
    send({"jsonrpc": "2.0", "method": "textDocument/didSave",
          "params": {"textDocument": {"uri": URI}, "text": text}})

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None, "capabilities": {}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
      "params": {"textDocument": {"uri": URI, "languageId": "d",
                                 "version": 1, "text": GOOD}}})
check('trivia-open-clean', read_msg()['params']['diagnostics'] == [], '')

# add a blank line + save: no re-analysis, so no diagnostics are published
save(GOOD + '\n')
check('trivia-blankline-silent', not ready(1.0), '')

# remove it + save, then a real semantic edit: diagnostics flow again
save(GOOD)
check('trivia-revert-arrives', ready(5), '')
d = read_msg()['params']['diagnostics']
check('trivia-revert-clean', d == [], str(d))

save(GOOD.replace('fn(&b.e, b);', 'fn(&b.e, 1);'))
check('trivia-real-edit-arrives', ready(5), '')
msgs = [x['message'] for x in read_msg()['params']['diagnostics']]
check('trivia-real-edit-diag', any('not callable' in m for m in msgs), str(msgs))

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
