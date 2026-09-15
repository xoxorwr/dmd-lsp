import json, subprocess, sys

# LSP clients may send incremental contentChanges (with a `range`) even
# though we advertise full sync. Treating a range's `text` as the whole
# document replaces the buffer with a fragment, which shows up as bogus
# top-of-file errors (e.g. dmd's "must start with BOM or ASCII character").

BIN = './dmd-lsp'
URI = 'file:///tmp/synctest.d'

proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0'], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

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

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

def open_doc(text):
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": URI, "languageId": "d",
                                      "version": 1, "text": text}}})
    return [d['message'] for d in read_msg()['params']['diagnostics']]

def change(rng, text):
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": 2},
                     "contentChanges": [{"range": rng, "text": text}]}})
    return [d['message'] for d in read_msg()['params']['diagnostics']]

def rng(sl, sc, el, ec):
    return {"start": {"line": sl, "character": sc}, "end": {"line": el, "character": ec}}

send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

base = 'module synctest;\nvoid main()\n{\n    int x;\n}\n'
check('open-clean', open_doc(base) == [], '')

# No-op range replacement: the document must stay intact.
check('incremental-noop-replace', change(rng(0, 0, 0, 6), 'module') == [], '')

# Range insertion into the body: composed onto the full document, still clean.
check('incremental-insert', change(rng(2, 4, 2, 4), 'int y;\n    ') == [], '')

# Non-ASCII insertion mid-file must not produce a top-of-file BOM error.
msgs = change(rng(1, 0, 1, 0), '// \u4e00\n')
check('no-bogus-bom-error', not any('must start with BOM' in m for m in msgs), str(msgs))

# Full-text change (no range) still replaces the document.
send({"jsonrpc": "2.0", "method": "textDocument/didChange",
      "params": {"textDocument": {"uri": URI, "version": 3},
                 "contentChanges": [{"text": 'module synctest;\nvoid main(){}\n'}]}})
msgs = [d['message'] for d in read_msg()['params']['diagnostics']]
check('full-text-change', msgs == [], str(msgs))

# didSave without a `text` field used to pass the session's own buffer back
# through sessionUpdate (which frees it) and then analyze the freed memory,
# producing random top-of-file errors like "must start with BOM ... not \xC8".
for i in range(4):
    send({"jsonrpc": "2.0", "method": "textDocument/didSave",
          "params": {"textDocument": {"uri": URI}}})
    msgs = [d['message'] for d in read_msg()['params']['diagnostics']]
    check('save-no-text-%d' % i, msgs == [], str(msgs))

# didSave carrying explicit text still works.
send({"jsonrpc": "2.0", "method": "textDocument/didSave",
      "params": {"textDocument": {"uri": URI}, "text": base}})
msgs = [d['message'] for d in read_msg()['params']['diagnostics']]
check('save-with-text', msgs == [], str(msgs))

send({"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": {}})
read_msg()
send({"jsonrpc": "2.0", "method": "exit", "params": {}})
proc.stdin.close()
proc.wait(timeout=5)

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
