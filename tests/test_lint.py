import json, os, shutil, subprocess, sys, tempfile

# Lint (unused import / unused parameter) over the identifier scanner. The point
# is that string/comment/token-string text must never count as a use, and real
# uses (including inside code) must clear the hint.

BIN = './dmd-lsp'

fails = []
def check(name, cond, extra=''):
    print(('PASS ' if cond else 'FAIL ') + name, extra)
    if not cond:
        fails.append(name)


class Daemon:
    def __init__(self, args):
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

    def init(self, root):
        self.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                   "params": {"rootUri": 'file://' + root, "capabilities": {}}})
        self.read_msg()
        self.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

    def open_doc(self, path, text):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                   "params": {"textDocument": {"uri": 'file://' + path,
                                              "languageId": "d",
                                              "version": 1, "text": text}}})
        return [d['message'] for d in self.read_msg()['params']['diagnostics']]

    def change_doc(self, path, text, ver):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didChange",
                   "params": {"textDocument": {"uri": 'file://' + path,
                                              "version": ver},
                              "contentChanges": [{"text": text}]}})
        return [d['message'] for d in self.read_msg()['params']['diagnostics']]

    def save_doc(self, path, text):
        self.send({"jsonrpc": "2.0", "method": "textDocument/didSave",
                   "params": {"textDocument": {"uri": 'file://' + path},
                              "text": text}})
        return [d['message'] for d in self.read_msg()['params']['diagnostics']]

    def close(self):
        try:
            self.proc.kill()
        except Exception:
            pass


root = tempfile.mkdtemp(prefix='dmd-lsp-lint-')
open(os.path.join(root, 'usedmod.d'), 'w').write(
    'module usedmod;\nvoid usedFn() {}\n')
open(os.path.join(root, 'unusedmod.d'), 'w').write(
    'module unusedmod;\nint x;\n')

SRC = ('module lintedge;\n'
       'import usedmod;\n'
       'import unusedmod;\n'
       '\n'
       'void fn(int unusedParam)\n{\n'
       '    // unusedmod mentioned in a comment\n'
       '    auto s = `unusedmod in a backtick string`;\n'
       '    auto t = q{ unusedmod in a token string };\n'
       '    usedFn();\n'
       '}\n')
path = os.path.join(root, 'lintedge.d')
open(path, 'w').write(SRC)

d = Daemon(['--debounce-ms=0', '--import=' + root])
d.init(root)
diags = d.open_doc(path, SRC)
check('unused-import-hinted',
      any('unused import' in m and 'unusedmod' in m for m in diags), str(diags))
check('used-import-not-hinted',
      not any('unused import `usedmod`' in m for m in diags), str(diags))
check('unused-param-hinted',
      any('unused parameter' in m and 'unusedParam' in m for m in diags),
      str(diags))
# strings/comments must not have counted as a use (that is why the import is
# still flagged), and the real use of `usedmod` cleared its hint.
check('string-not-a-use', any('unusedmod' in m for m in diags), str(diags))

# Add a real use (via save: the live keypress path is parse-only) -> the
# unused-import hint must clear, while the still-unused parameter stays.
USED = SRC.replace('    usedFn();\n', '    usedFn();\n    unusedmod.x = 1;\n')
open(path, 'w').write(USED)
d.change_doc(path, USED, 2)
diags = d.save_doc(path, USED)
check('real-use-clears-hint',
      not any('unused import' in m for m in diags), str(diags))
check('param-still-hinted', any('unused parameter' in m for m in diags),
      str(diags))
d.close()

# Function-local imports are linted too: an unused `import` inside a body (or a
# nested block) is reported, a used one is not.
LOCAL = ('module locallint;\n'
         'void fn()\n{\n'
         '    import usedmod;\n'
         '    import unusedmod;\n'
         '    usedFn();\n'
         '}\n'
         'void fn2()\n{\n'
         '    if (true) { import unusedmod; }\n'
         '}\n'
         'void fn3()\n{\n'
         '    import unusedmod;\n'
         '    unusedmod.x = 1;\n'
         '}\n')
lp = os.path.join(root, 'locallint.d')
open(lp, 'w').write(LOCAL)
d3 = Daemon(['--debounce-ms=0', '--import=' + root])
d3.init(root)
ldiags = d3.open_doc(lp, LOCAL)
check('local-unused-import-hinted',
      any('unused import' in m and 'unusedmod' in m for m in ldiags), str(ldiags))
check('local-used-import-not-hinted',
      not any('unused import `usedmod`' in m for m in ldiags), str(ldiags))
# fn and fn2's unusedmod imports are flagged; fn3's is used.
check('local-import-count',
      sum(1 for m in ldiags if 'unusedmod' in m) == 2, str(ldiags))
d3.close()

# The unused-parameter hint must point at the parameter, not the line start.
d2 = Daemon(['--debounce-ms=0'])
r2 = tempfile.mkdtemp(prefix='dmd-lsp-lint2-')
p2 = os.path.join(r2, 'u.d')
d2.init(r2)
d2.send({"jsonrpc": "2.0", "method": "textDocument/didOpen",
         "params": {"textDocument": {"uri": 'file://' + p2, "languageId": "d",
                                     "version": 1,
                                     "text": 'module u;\nvoid f(int unusedParam) {}\n'}}})
hit = next((x for x in d2.read_msg()['params']['diagnostics']
            if x.get('code') == 'unused-param'), None)
check('unused-param-range',
      hit is not None and hit['range']['start'] == {'line': 1, 'character': 11},
      str(hit))
d2.close()

shutil.rmtree(root, ignore_errors=True)
shutil.rmtree(r2, ignore_errors=True)
print('FAILURES: %s' % (fails if fails else 'none'))
sys.exit(1 if fails else 0)
