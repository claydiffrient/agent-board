import os, pty, select, sys, time, signal, json, fcntl, termios, struct
CWD, SETTINGS, LOG = sys.argv[1], sys.argv[2], sys.argv[3]
SCRIPT = json.loads(open(sys.argv[4]).read())
EXTRA_ARGS = json.loads(sys.argv[5]) if len(sys.argv) > 5 else []
env = dict(os.environ)
env["TERM"] = "xterm-256color"
for k in list(env):
    if k.startswith("CLAUDE_CODE_CHILD") or k in ("CLAUDE_CODE_SSE_PORT","CLAUDECODE","CLAUDE_CODE_ENTRYPOINT","CLAUDE_CODE_SESSION_ID","CLAUDE_SESSION_ID","CLAUDE_JOB_DIR"):
        env.pop(k, None)
env["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"
pid, fd = pty.fork()
if pid == 0:
    os.chdir(CWD)
    os.execvpe("claude", ["claude", "--settings", SETTINGS] + EXTRA_ARGS, env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
out = open(LOG, "wb")
def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if fd in r:
            try: d = os.read(fd, 65536)
            except OSError: return False
            if not d: return False
            out.write(d); out.flush()
    return True
def write_all(b):
    # mirror a single write(2) that may block while the reader drains
    n = 0
    while n < len(b):
        r, w, _ = select.select([fd], [fd], [], 0.05)
        if fd in r:
            d = os.read(fd, 65536); out.write(d)
        if fd in w:
            n += os.write(fd, b[n:])
for step in SCRIPT:
    if "mark" in step:
        out.write(("\n@@MARK %s@@\n" % step["mark"]).encode()); out.flush()
        sys.stderr.write("[mark] %s\n" % step["mark"])
    if "send" in step:
        write_all(step["send"].encode())
    if "sendfile" in step:
        b = open(step["sendfile"], "rb").read()
        if "limit" in step: b = b[:step["limit"]]
        size = step.get("chunk")
        if size:
            t = b.decode()
            for i in range(0, len(t), size):
                write_all(t[i:i+size].encode()); pump(step.get("pause", 0.05))
        else:
            write_all(b)
    if "wait" in step:
        if not pump(step["wait"]): break
pump(2)
try: os.kill(pid, signal.SIGKILL)
except Exception: pass
out.close()
print("done")
