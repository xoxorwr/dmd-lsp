import json, subprocess, sys, tempfile, os, shutil

# Implicit `this`: an aggregate's fields/methods are in scope inside a member
# function even though they are not locals. `renderer.` must resolve the field
# and complete its type's members, and it must keep working when the aggregate
# has a semantic error (a missing type) — a compile error elsewhere must not
# blank completion. A local of the same name shadows the field.

BIN = './dmd-lsp'

SRC = '''module sc;

struct UIRenderer
{
    int clip_depth;
    int current_sort_key;
    void begin(int w, int h) {}
}

struct Other
{
    int marker_field;
}

struct UIContext
{
    UIRenderer renderer;
    int somefield;
    NoSuchType* bad; // undefined: must not stop completion

    void draw()
    {
        renderer.
    }

    void self()
    {
        this.
    }

    void plain()
    {
        somef
    }

    void shadow()
    {
        Other renderer;
        renderer.
    }
}
'''


def run(text, markers):
    root = tempfile.mkdtemp(prefix='dmd-lsp-field-')
    path = os.path.join(root, 'sc.d')
    open(path, 'w').write(text)
    uri = 'file://' + path
    proc = subprocess.Popen([BIN, '--stdio', '--debounce-ms=0', '--import=' + root],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)

    def send(obj):
        body = json.dumps(obj).encode()
        proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
        proc.stdin.flush()

    def read():
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

    def complete(line, ch):
        send({"jsonrpc": "2.0", "id": 900, "method": "textDocument/completion",
              "params": {"textDocument": {"uri": uri},
                         "position": {"line": line, "character": ch}}})
        while True:
            m = read()
            if m.get('id') == 900:
                it = m['result']
                return [i['label'] for i in (it.get('items', []) if isinstance(it, dict) else it)]

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"rootUri": None, "capabilities": {},
                     "initializationOptions": {"importPaths": [root]}}})
    read()
    send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
    send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
          "params": {"textDocument": {"uri": uri, "languageId": "d",
                                     "version": 1, "text": text}}})
    read()

    lines = text.split('\n')
    out = {}
    for name, spec in markers.items():
        marker, nth = spec if isinstance(spec, tuple) else (spec, 0)
        ln = [i for i, l in enumerate(lines) if marker in l][nth]
        out[name] = complete(ln, len(lines[ln]))
    proc.stdin.close()
    proc.wait(timeout=5)
    shutil.rmtree(root, ignore_errors=True)
    return out


fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)


r = run(SRC, {'field': 'renderer.', 'this': 'this.', 'plain': 'somef'})

check('field-dotted-members', 'clip_depth' in r['field'] and 'begin' in r['field'],
      str(sorted(set(r['field']))[:8]))
check('this-own-members', 'renderer' in r['this'] and 'draw' in r['this'],
      str(sorted(set(r['this']))[:8]))
check('field-plain-name', 'somefield' in r['plain'],
      str(sorted(set(r['plain']))[:8]))

# The shadowed case: a local `Other renderer` must win over the field, so the
# field's `clip_depth` must not appear and the local's member must.
r2 = run(SRC, {'shadow': ('renderer.', 1)})
check('field-shadowed-local-wins',
      'marker_field' in r2['shadow'] and 'clip_depth' not in r2['shadow'],
      str(sorted(set(r2['shadow']))[:8]))

print('FAILURES:', fails if fails else 'none')
sys.exit(1 if fails else 0)
