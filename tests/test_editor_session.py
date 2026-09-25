import json, os, select, subprocess, sys, tempfile, time

BIN = './dmd-lsp'
WORK = tempfile.mkdtemp(prefix='dmd-lsp-editor-')
ROOT = os.path.join(WORK, 'app.d')

initial_content = """module app;

struct User {
    string name;
    int age;
    int id;
}

int calculateScore(int a, int b) {
    int total = a + b;
    return total;
}

void main() {
    User u;
    u.name = "alice";
    u.age = 30;
    int score = calculateScore(u.age, 10);
}
"""

with open(ROOT, 'w') as f:
    f.write(initial_content)

URI = 'file://' + ROOT

proc = subprocess.Popen([BIN, '--import=' + WORK, '--debounce-ms=50'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)

def send(obj):
    b = json.dumps(obj).encode()
    proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(b) + b)
    proc.stdin.flush()

def read_msg(timeout=10):
    r, _, _ = select.select([proc.stdout], [], [], timeout)
    if not r:
        return None
    h = {}
    while True:
        line = proc.stdout.readline().decode().strip()
        if not line:
            break
        if ':' in line:
            k, v = line.split(':', 1)
            h[k.strip().lower()] = v.strip()
    if 'content-length' not in h:
        return None
    n = int(h['content-length'])
    data = b''
    while len(data) < n:
        chunk = proc.stdout.read(n - len(data))
        if not chunk:
            break
        data += chunk
    return json.loads(data.decode())

def drain_messages(timeout=0.1):
    msgs = []
    while True:
        r, _, _ = select.select([proc.stdout], [], [], timeout)
        if not r:
            break
        m = read_msg(0.5)
        if m:
            msgs.append(m)
        else:
            break
    return msgs

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
        with open(f'/proc/{pid}/status') as f:
            for l in f:
                if l.startswith('VmRSS'):
                    return int(l.split()[1])
    except Exception:
        pass
    return 0

def total_rss():
    return sum(rss_kb(p) for p in worker_pids())

# 1. Initialize
send({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "rootUri": "file://" + WORK,
        "capabilities": {
            "textDocument": {
                "semanticTokens": {
                    "requests": {"full": True}
                },
                "completion": {
                    "completionItem": {"snippetSupport": True}
                }
            }
        }
    }
})
init_resp = read_msg()
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

# 2. Open document
send({
    "jsonrpc": "2.0", "method": "textDocument/didOpen",
    "params": {
        "textDocument": {
            "uri": URI,
            "languageId": "d",
            "version": 1,
            "text": initial_content
        }
    }
})
# wait for publishDiagnostics or responses
drain_messages(0.2)

pids0 = worker_pids()
base_rss = total_rss()
print(f"Base RSS: {base_rss} kB, Worker PIDs: {pids0}")

# 3. Simulate realistic editing loop:
# User typing in `main()`, requesting completion, semanticTokens, highlight, hover, and debounced lint.
current_text = initial_content
req_id = 100

rss_history = []

for i in range(100):
    # didChange: edit inside main function body
    version = 2 + i
    var_name = f"val_{i % 5}"
    # replace previous edit
    old_stmt = f"    int val_{(i - 1) % 5} = {i - 1};" if i > 0 else "    int score = calculateScore(u.age, 10);"
    new_stmt = f"    int {var_name} = {i};\n    int score = calculateScore(u.age, {var_name});" if i == 0 else f"    int {var_name} = {i};"
    new_text = current_text.replace(old_stmt, new_stmt)
    current_text = new_text
    
    send({
        "jsonrpc": "2.0", "method": "textDocument/didChange",
        "params": {
            "textDocument": {"uri": URI, "version": version},
            "contentChanges": [{"text": new_text}]
        }
    })
    
    # Immediately VSCode asks for semantic tokens
    req_id += 1
    send({
        "jsonrpc": "2.0", "id": req_id, "method": "textDocument/semanticTokens/full",
        "params": {"textDocument": {"uri": URI}}
    })
    
    # VSCode asks for completion at the variable position (line 18, col 20)
    req_id += 1
    send({
        "jsonrpc": "2.0", "id": req_id, "method": "textDocument/completion",
        "params": {
            "textDocument": {"uri": URI},
            "position": {"line": 18, "character": 15}
        }
    })

    # VSCode asks for documentHighlight at `u` (line 15, col 7)
    req_id += 1
    send({
        "jsonrpc": "2.0", "id": req_id, "method": "textDocument/documentHighlight",
        "params": {
            "textDocument": {"uri": URI},
            "position": {"line": 15, "character": 7}
        }
    })

    # VSCode asks for hover
    req_id += 1
    send({
        "jsonrpc": "2.0", "id": req_id, "method": "textDocument/hover",
        "params": {
            "textDocument": {"uri": URI},
            "position": {"line": 15, "character": 7}
        }
    })

    # Read responses for these requests
    for _ in range(4):
        read_msg(5)
    
    # Wait for debounce timer (50ms) to fire so flushPending -> lint runs!
    time.sleep(0.07)
    drain_messages(0.05)
    
    current_rss = total_rss()
    rss_history.append(current_rss)
    if (i + 1) % 10 == 0 or (48 <= i + 1 <= 53) or (98 <= i + 1 <= 103):
        print(f"Cycle {i+1}: RSS = {current_rss} kB (+{current_rss - base_rss} kB)")

peak_rss = max(rss_history)
final_rss = rss_history[-1]
growth = final_rss - base_rss
pids_final = worker_pids()

print(f"\nFinal Summary:")
print(f"Base RSS: {base_rss} kB")
print(f"Peak RSS: {peak_rss} kB")
print(f"Final RSS: {final_rss} kB")
print(f"Net Growth: {growth} kB")
print(f"Worker PIDs start: {pids0}, end: {pids_final}")

proc.terminate()
try:
    proc.wait(timeout=2)
except Exception:
    proc.kill()
