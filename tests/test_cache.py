import json, os, subprocess, sys, tempfile

# Universe-cache regression: identical requests are served from the live
# universe (hit), edits and dep changes rebuild. Correctness only.
BIN = './dmd-lsp'
WORK = tempfile.mkdtemp(prefix='dmd-lsp-cache-')

with open(os.path.join(WORK, 'cdep.d'), 'w') as f:
    f.write('module cdep;\nstruct Item { int keep; int drop; }\n')
with open(os.path.join(WORK, 'cextra.d'), 'w') as f:
    f.write('module cextra;\nstruct Extra { int e; }\n')
with open(os.path.join(WORK, 'croot.d'), 'w') as f:
    f.write('module croot;\nimport cdep;\nimport cextra;\n'
            'void main() {\n    Item it;\n    auto q = it.keep;\n}\n')
ROOT = os.path.join(WORK, 'croot.d')
URI = 'file://' + ROOT

proc = subprocess.Popen([BIN, '--import=' + WORK, '--debounce-ms=0'], stdin=subprocess.PIPE,
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

def open_doc(text, ver=1):
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": URI, "languageId": "d",
                                     "version": ver, "text": text}}})
    return [d['message'] for d in read_msg()['params']['diagnostics']]

def change_doc(text, ver):
    send({"jsonrpc": "2.0", "method": "textDocument/didChange",
          "params": {"textDocument": {"uri": URI, "version": ver},
                     "contentChanges": [{"text": text}]}})
    return [d['message'] for d in read_msg()['params']['diagnostics']]

def complete(line0, marker):
    lines = open(ROOT).read().split('\n')
    idx = lines[line0].index(marker) + len(marker)
    send({"jsonrpc": "2.0", "id": 100, "method": "textDocument/completion",
          "params": {"textDocument": {"uri": URI},
                     "position": {"line": line0, "character": idx}}})
    return [i['label'] for i in read_msg()['result']['items']]

def code_actions():
    send({"jsonrpc": "2.0", "id": 101, "method": "textDocument/codeAction",
          "params": {"textDocument": {"uri": URI},
                     "range": {"start": {"line": 0, "character": 0},
                               "end": {"line": 0, "character": 0}},
                     "context": {"diagnostics": []}}})
    return read_msg()['result']

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"rootUri": None, "capabilities": {}}})
read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

text = open(ROOT).read()
d = open_doc(text)
check('cache-open-hints-only', all('unused import' in m for m in d), str(d))

# repeated identical completions: same results (served from live universe)
first = complete(5, 'it.k')
second = complete(5, 'it.k')
check('cache-hit-consistent', first == second and 'keep' in first, str(first[:6]))

# codeAction served from cached analysis (module_ nulled, lint pinned)
acts = code_actions()
check('cache-codeaction', any('cextra' in a.get('title', '') for a in acts),
      str([a.get('title') for a in acts]))

# edit with a new (syntax) error: lint updates live. Semantic errors are a
# save/open concern now (the debounced keypress path is parse-only).
bad = text.replace('it.keep', 'it.keep;\n    string s = "unterminated;')
d = change_doc(bad, 2)
open(ROOT, 'w').write(bad)
check('cache-edit-rebuilds', any('unterminated' in m for m in d), str(d))

# revert: clean again (modulo the unused-import hint)
d = change_doc(text, 3)
open(ROOT, 'w').write(text)
check('cache-revert-clean', all('unused import' in m for m in d), str(d))

# semantic diagnostics are a save/open concern: the debounced keypress path is
# parse-only, so they must not appear live, and must appear after save
sem = text.replace('it.keep', 'it.keep;\n    nosuch_xyz;')
d = change_doc(sem, 5)
check('edit-no-semantic-live', not any('nosuch_xyz' in m for m in d), str(d))
send({"jsonrpc": "2.0", "method": "textDocument/didSave",
      "params": {"textDocument": {"uri": URI}, "text": sem}})
d = [x['message'] for x in read_msg()['params']['diagnostics']]
check('save-semantic-diags', any('nosuch_xyz' in m for m in d), str(d))

# dep changed on disk, root text identical: rebuild picks it up
with open(os.path.join(WORK, 'cdep.d'), 'w') as f:
    f.write('module cdep;\nstruct Item { int keep; int fresh; }\n')
d = change_doc(text, 4)
check('cache-depchange-nostale-err', not any('drop' in m and 'no property' in m for m in d), str(d))
items = complete(5, 'it.')
check('cache-depchange-members', 'fresh' in items and 'drop' not in items, str(items[:8]))

print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
