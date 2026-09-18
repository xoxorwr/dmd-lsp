import json, os, select, shutil, subprocess, sys, tempfile

# dls.json project config: root-relative importPaths, precedence
# (CLI/editor > file > defaults), debounceMs, save-reload, malformed file.
BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)

class Daemon:
    def __init__(self, args):
        # bufsize=0: select() must see every byte; buffered readahead
        # would hide queued messages from it and misalign the stream.
        self.proc = subprocess.Popen([BIN] + args, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, bufsize=0)

    def send(self, obj):
        body = json.dumps(obj).encode()
        self.proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body) + body)
        self.proc.stdin.flush()

    def read_msg(self):
        headers = {}
        while True:
            line = self.proc.stdout.readline().decode().strip()
            if not line:
                break
            k, v = line.split(':', 1)
            headers[k.strip().lower()] = v.strip()
        n = int(headers['content-length'])
        data = b''
        while len(data) < n:
            data += self.proc.stdout.read(n - len(data))
        return json.loads(data)

    def ready(self, timeout):
        r, _, _ = select.select([self.proc.stdout], [], [], timeout)
        return bool(r)

    def drain(self, timeout):
        """Collect all messages arriving within timeout of each other."""
        out = []
        while self.ready(timeout):
            out.append(self.read_msg())
        return out

    def init(self, root=None, options=None, watch=False):
        caps = {}
        if watch:
            caps["workspace"] = {
                "didChangeWatchedFiles": {"dynamicRegistration": True}}
        params = {"rootUri": None, "capabilities": caps}
        if root:
            params["rootUri"] = 'file://' + root
        if options:
            params["initializationOptions"] = options
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": params})
        r = self.read_msg()
        assert r['result']['serverInfo']['version'] == '0.3.0', r
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
        if watch:
            # Dynamic registration arrives after `initialized` (a dls.json
            # notice may precede it); answer the request so the server stops
            # expecting a reply.
            for _ in range(5):
                reg = self.read_msg()
                if reg.get('method') == 'client/registerCapability':
                    self.watch = reg
                    self.send({"jsonrpc": "2.0", "id": reg['id'],
                               "result": None})
                    break
            else:
                raise AssertionError('no watch registration: %r' % (reg,))

    def open_doc(self, path, text, ver=1):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                   "params": {"textDocument": {"uri": 'file://' + path,
                                              "languageId": "d",
                                              "version": ver, "text": text}}})

    def complete(self, path, line0, marker):
        lines = open(path).read().split('\n')
        idx = lines[line0].index(marker) + len(marker)
        self.send({"jsonrpc": "2.0", "id": 100,
                   "method": "textDocument/completion",
                   "params": {"textDocument": {"uri": 'file://' + path},
                              "position": {"line": line0,
                                           "character": idx}}})
        return [i['label'] for i in self.read_msg()['result']['items']]

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


def mkroot(files):
    root = tempfile.mkdtemp(prefix='dmd-lsp-cfg-')
    for rel, content in files.items():
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w') as f:
            f.write(content)
    return root


# 1. bare daemon + dls.json: second-listed dir resolves, Log notice fires
root = mkroot({
    'dls.json': '{"importPaths": ["src/", "sandbox/"]}',
    'sandbox/mylib.d': 'module mylib;\nstruct Helper { int alpha; }\n',
    'app.d': 'module app;\nimport mylib;\nvoid main() {\n    Helper h;\n    auto q = h.alpha;\n}\n',
})
d = Daemon(['--import=/nonexistent-xyz', '--debounce-ms=0'])
d.init(root=root)
notices = d.drain(1.0)
check('cfg-loaded-notice',
      any(m.get('method') == 'window/showMessage' and
          'dls.json: 2 import paths' in m['params']['message'] for m in notices),
      str([m.get('params') for m in notices if m.get('method')]));
d.open_doc(root + '/app.d', open(root + '/app.d').read())
diags = d.read_msg()['params']['diagnostics']
check('cfg-dep-resolves', diags == [], str(diags))
check('cfg-completion', 'alpha' in d.complete(root + '/app.d', 4, 'h.al'),
      '')
d.close()

# 2. no dls.json: silent, dep unresolved
root2 = mkroot({
    'mylib.d': 'module mylib;\nstruct Helper { int alpha; }\n',
    'app.d': 'module app;\nimport mylib;\nvoid main() {\n    Helper h;\n    auto q = h.alpha;\n}\n',
})
d = Daemon(['--debounce-ms=0'])
d.init(root=root2)
check('cfg-absent-silent', not d.ready(0.3), '')
d.open_doc(root2 + '/app.d', open(root2 + '/app.d').read())
diags = d.read_msg()['params']['diagnostics']
check('cfg-absent-unresolved', any('mylib' in m for m in
      [x['message'] for x in diags]), str(diags))
d.close()

# 3/4. precedence: CLI and editor settings both beat the file
pfx = {
    'dls.json': '{"importPaths": ["fromfile/"]}',
    'fromfile/cdep.d': 'module cdep;\nstruct Item { int fromFile; }\n',
    'fromcli/cdep.d': 'module cdep;\nstruct Item { int fromCli; }\n',
    'fromeditor/cdep.d': 'module cdep;\nstruct Item { int fromEditor; }\n',
    'main.d': 'module mainf;\nimport cdep;\nvoid f() {\n    Item it;\n    auto q = it.q;\n}\n',
}
root3 = mkroot(pfx)
d = Daemon(['--import=' + root3 + '/fromcli', '--debounce-ms=0'])
d.init(root=root3)
d.drain(1.0)
d.open_doc(root3 + '/main.d', open(root3 + '/main.d').read())
d.read_msg()
items = d.complete(root3 + '/main.d', 4, 'it.')
check('cfg-cli-beats-file', 'fromCli' in items and 'fromFile' not in items,
      str(items[:6]))
d.close()

d = Daemon(['--debounce-ms=0'])
d.init(root=root3,
       options={"importPaths": [root3 + '/fromeditor']})
d.drain(1.0)
d.open_doc(root3 + '/main.d', open(root3 + '/main.d').read())
d.read_msg()
items = d.complete(root3 + '/main.d', 4, 'it.')
check('cfg-editor-beats-file', 'fromEditor' in items and 'fromFile' not in items,
      str(items[:6]))
d.close()

# 5. debounceMs from file shortens the delay (arrival < default floor)
root5 = mkroot({
    'dls.json': '{"debounceMs": 80}',
    'a.d': 'module a;\nvoid main() {\n    int ok = 1;\n}\n',
})
d = Daemon([])
d.init(root=root5)
d.drain(1.0)
t = open(root5 + '/a.d').read()
d.open_doc(root5 + '/a.d', t)
d.read_msg()
bad = t.replace('int ok = 1;', 'int ok = 1;\n    zz_missing zz_missing zz_missing;')
d.send({"jsonrpc": "2.0", "method": "textDocument/didChange",
        "params": {"textDocument": {"uri": 'file://' + root5 + '/a.d',
                                   "version": 2},
                   "contentChanges": [{"text": bad}]}})
check('cfg-debounce-from-file', d.ready(0.25), '')
msgs = [x['message'] for x in d.read_msg()['params']['diagnostics']]
check('cfg-debounce-diags', any('zz_missing' in m for m in msgs), str(msgs))
d.close()

# 6. CLI --debounce-ms=0 beats a huge file value
root6 = mkroot({
    'dls.json': '{"debounceMs": 5000}',
    'a.d': 'module a;\nvoid main() {\n    int ok = 1;\n}\n',
})
d = Daemon(['--debounce-ms=0'])
d.init(root=root6)
d.drain(1.0)
t = open(root6 + '/a.d').read()
d.open_doc(root6 + '/a.d', t)
d.read_msg()
bad = t.replace('int ok = 1;', 'int ok = 1;\n    qq_missing;')
d.send({"jsonrpc": "2.0", "method": "textDocument/didChange",
        "params": {"textDocument": {"uri": 'file://' + root6 + '/a.d',
                                   "version": 2},
                   "contentChanges": [{"text": bad}]}})
check('cfg-cli-debounce-wins', d.ready(2.0), '')
d.read_msg()
d.close()

# 7. malformed dls.json: Error notice, server stays alive
root7 = mkroot({
    'dls.json': '{"importPaths": [oops',
    'a.d': 'module a;\nvoid main() {\n    int ok = 1;\n}\n',
})
d = Daemon(['--debounce-ms=0'])
d.init(root=root7)
notices = d.drain(1.0)
check('cfg-malformed-error',
      any(m.get('method') == 'window/showMessage' and
          m['params'].get('type') == 1 for m in notices),
      str([m.get('params') for m in notices if m.get('method')]))
d.open_doc(root7 + '/a.d', open(root7 + '/a.d').read())
diags = d.read_msg()['params']['diagnostics']
check('cfg-malformed-alive', diags == [], str(diags))
d.close()

# 8. didSave on dls.json reloads (new dir resolves, no D squiggles on JSON)
root8 = mkroot({
    'dls.json': '{"importPaths": ["libs/"]}',
    'libs/dep1.d': 'module dep1;\nstruct D1 { int one; }\n',
    'app.d': 'module app;\nimport dep1;\nvoid main() {\n    D1 d;\n    auto q = d.one;\n}\n',
})
d = Daemon(['--debounce-ms=0'])
d.init(root=root8)
d.drain(1.0)
d.open_doc(root8 + '/app.d', open(root8 + '/app.d').read())
d.read_msg()
check('cfg-reload-base', 'one' in d.complete(root8 + '/app.d', 4, 'd.o'), '')
os.makedirs(os.path.join(root8, 'more'))
with open(os.path.join(root8, 'more/dep2.d'), 'w') as f:
    f.write('module dep2;\nstruct D2 { int two; }\n')
with open(os.path.join(root8, 'dls.json'), 'w') as f:
    f.write('{"importPaths": ["libs/", "more/"]}')
d.send({"jsonrpc": "2.0", "method": "textDocument/didSave",
        "params": {"textDocument": {"uri": 'file://' + root8 + '/dls.json'}}})
msgs = d.drain(1.0)
check('cfg-reload-notice',
      any(m.get('method') == 'window/showMessage' and
          'dls.json: 2 import paths' in m['params']['message'] for m in msgs),
      str([m.get('params') for m in msgs if m.get('method')]))
check('cfg-reload-no-json-diags',
      not any(m.get('method') == 'textDocument/publishDiagnostics' and
              'dls.json' in m['params']['uri'] for m in msgs),
      str([m.get('method') for m in msgs]))
with open(os.path.join(root8, 'app.d'), 'w') as f:
    f.write('module app;\nimport dep2;\nvoid main() {\n    D2 d;\n    auto q = d.two;\n}\n')
d.open_doc(root8 + '/app.d', open(root8 + '/app.d').read())
diags = d.read_msg()['params']['diagnostics']
check('cfg-reload-resolves', diags == [], str(diags))
d.close()

# 9. dmd flags from dls.json: -preview=rvaluerefparam enables rvalue->ref
app_src = ('module app;\n'
           'struct W { int x; }\n'
           'void use(ref W w) {}\n'
           'W makeW() { return W(); }\n'
           'void f() { use(makeW()); }\n')
root9 = mkroot({'app.d': app_src})
d = Daemon(['--debounce-ms=0'])
d.init(root=root9)
d.drain(1.0)
d.open_doc(root9 + '/app.d', open(root9 + '/app.d').read())
msgs = [x['message'] for x in d.read_msg()['params']['diagnostics']]
check('cfg-flags-off-error', any('not callable' in m for m in msgs), str(msgs))
d.close()

root9b = mkroot({
    'dls.json': '{"flags": ["-preview=rvaluerefparam"]}',
    'app.d': app_src,
})
d = Daemon(['--debounce-ms=0'])
d.init(root=root9b)
d.drain(1.0)
d.open_doc(root9b + '/app.d', open(root9b + '/app.d').read())
msgs = [x['message'] for x in d.read_msg()['params']['diagnostics']]
check('cfg-flags-on-clean', not any('not callable' in m for m in msgs), str(msgs))
d.close()

# 10. workspace/didChangeWatchedFiles reloads the root dls.json without a
# save/open (the client watches; the file may be closed or edited externally).
# Nested dls.json files are ignored (server is single-root).
root10 = mkroot({
    'dls.json': '{"importPaths": ["libs/"]}',
    'libs/dep1.d': 'module dep1;\nstruct D1 { int one; }\n',
    'app.d': 'module app;\nimport dep1;\nvoid main() {\n    D1 d;\n    auto q = d.one;\n}\n',
})
d = Daemon(['--debounce-ms=0'])
d.init(root=root10, watch=True)
d.drain(1.0)
check('cfg-watch-registers',
      d.watch['params']['registrations'][0]['registerOptions']['watchers'][0]
      ['globPattern'] == '**/dls.json',
      str(d.watch['params']))
d.open_doc(root10 + '/app.d', open(root10 + '/app.d').read())
d.read_msg()
check('cfg-watch-base', 'one' in d.complete(root10 + '/app.d', 4, 'd.o'), '')
os.makedirs(os.path.join(root10, 'more'))
with open(os.path.join(root10, 'more/dep2.d'), 'w') as f:
    f.write('module dep2;\nstruct D2 { int two; }\n')
with open(os.path.join(root10, 'dls.json'), 'w') as f:
    f.write('{"importPaths": ["libs/", "more/"]}')
d.send({"jsonrpc": "2.0", "method": "workspace/didChangeWatchedFiles",
        "params": {"changes": [{"uri": 'file://' + root10 + '/dls.json',
                                "type": 2}]}})
msgs = d.drain(1.0)
check('cfg-watch-reload-notice',
      any(m.get('method') == 'window/showMessage' and
          'dls.json: 2 import paths' in m['params']['message'] for m in msgs),
      str([m.get('params') for m in msgs if m.get('method')]))
with open(os.path.join(root10, 'app.d'), 'w') as f:
    f.write('module app;\nimport dep2;\nvoid main() {\n    D2 d;\n    auto q = d.two;\n}\n')
d.open_doc(root10 + '/app.d', open(root10 + '/app.d').read())
diags = d.read_msg()['params']['diagnostics']
check('cfg-watch-resolves', diags == [], str(diags))
# deleting the config drops it and falls back to the defaults layer
os.remove(os.path.join(root10, 'dls.json'))
d.send({"jsonrpc": "2.0", "method": "workspace/didChangeWatchedFiles",
        "params": {"changes": [{"uri": 'file://' + root10 + '/dls.json',
                                "type": 3}]}})
msgs = d.drain(1.0)
check('cfg-watch-delete-notice',
      any(m.get('method') == 'window/showMessage' and
          'removed' in m['params']['message'] for m in msgs),
      str([m.get('params') for m in msgs if m.get('method')]))
# nested config change must not reload the root
os.makedirs(os.path.join(root10, 'nested'))
with open(os.path.join(root10, 'nested/dls.json'), 'w') as f:
    f.write('{"importPaths": ["nope/"]}')
d.send({"jsonrpc": "2.0", "method": "workspace/didChangeWatchedFiles",
        "params": {"changes": [{"uri": 'file://' + root10 +
                               '/nested/dls.json', "type": 1}]}})
msgs = d.drain(0.5)
check('cfg-watch-nested-ignored',
      not any(m.get('method') == 'window/showMessage' and
              'dls.json:' in m['params']['message'] for m in msgs),
      str([m.get('params') for m in msgs if m.get('method')]))
d.close()

print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
