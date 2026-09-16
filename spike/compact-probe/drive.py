import os, pty, select, sys, time, signal, subprocess, json

CWD = sys.argv[1]
SETTINGS = sys.argv[2]
LOG = sys.argv[3]
SCRIPT = json.loads(sys.argv[4])   # list of {"wait":secs} or {"send":"text"}
EXTRA_ENV = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
EXTRA_ARGS = json.loads(sys.argv[6]) if len(sys.argv) > 6 else []

env = dict(os.environ)
env.update(EXTRA_ENV)
env["TERM"] = "xterm-256color"
env.pop("CLAUDE_CODE_SSE_PORT", None)
env.pop("CLAUDECODE", None)
env.pop("CLAUDE_CODE_ENTRYPOINT", None)
for k in list(env):
    if k.startswith("CLAUDE_CODE_CHILD") or k in ("CLAUDE_CODE_SESSION_ID","CLAUDE_SESSION_ID"):
        env.pop(k, None)
env["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"

pid, fd = pty.fork()
if pid == 0:
    os.chdir(CWD)
    argv = ["claude"] + ([] if SETTINGS=="-" else ["--settings", SETTINGS, "--debug"]) + EXTRA_ARGS
    os.execvpe("claude", argv, env)

import fcntl, termios, struct
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))

out = open(LOG, "wb")
def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                return False
            if not d:
                return False
            out.write(d); out.flush()
    return True

for step in SCRIPT:
    if "wait" in step:
        if not pump(step["wait"]):
            break
    if "send" in step:
        os.write(fd, step["send"].encode())
    if "log" in step:
        sys.stderr.write("[step] %s\n" % step["log"]); sys.stderr.flush()

pump(3)
try:
    os.kill(pid, signal.SIGKILL)
except Exception:
    pass
out.close()
print("done")
