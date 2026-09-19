#!/usr/bin/env python3
"""Stand-in for the Agent Board HTTP server: /hooks + /mcp on a fixed port.

Modes:
  serve     -- answer normally
  blackhole -- accept the TCP connection, then never write a byte (a live SSH
               tunnel whose far end is gone)
"""
import json, os, sys, socket, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("BOARD_PORT", "8791"))
TOKEN = os.environ.get("BOARD_TOKEN", "spiketoken")
LOG = os.environ.get("BOARD_LOG", "/tmp/board-events.jsonl")

def rec(**kw):
    kw["t"] = time.time()
    kw["iso"] = time.strftime("%H:%M:%S", time.localtime()) + ".%03d" % int((time.time() % 1) * 1000)
    with open(LOG, "a") as f:
        f.write(json.dumps(kw) + "\n")
    print(kw["iso"], kw.get("kind"), kw.get("event") or kw.get("method") or "", flush=True)

PING_TOOL = {
    "name": "agent_board_ping",
    "description": "Ping Agent Board. Returns a pong containing the message you sent.",
    "inputSchema": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]},
}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass

    def _json(self, status, obj, extra_headers=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra_headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        rec(kind="mcp-delete", path=self.path)
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()

    def do_GET(self):
        self.send_response(405); self.send_header("Content-Length", "0"); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        if self.path.startswith("/hooks"):
            if "token=" + TOKEN not in self.path:
                rec(kind="hook-unauthorized", path=self.path)
                return self._json(401, {})
            try: p = json.loads(raw)
            except Exception: p = {}
            rec(kind="hook", event=p.get("hook_event_name"), session=p.get("session_id"),
                tool=(p.get("tool_name") or None), transcript=p.get("transcript_path"))
            return self._json(200, {})
        if self.path.startswith("/mcp"):
            if self.headers.get("Authorization") != "Bearer " + TOKEN:
                rec(kind="mcp-unauthorized")
                return self._json(401, {})
            try: msg = json.loads(raw)
            except Exception:
                return self._json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            batch = isinstance(msg, list)
            msgs = msg if batch else [msg]
            out = []
            saw_init = False
            for m in msgs:
                method = m.get("method")
                rec(kind="mcp", method=method, id=m.get("id"),
                    mcp_session=self.headers.get("Mcp-Session-Id"),
                    args=json.dumps(m.get("params", {}).get("arguments", {})) if method == "tools/call" else None)
                if method == "initialize": saw_init = True
                if "id" not in m: continue
                r = self.dispatch(m, method)
                if r: out.append(r)
            if not out:
                self.send_response(202); self.send_header("Content-Length", "0"); self.end_headers(); return
            hdrs = {"Mcp-Session-Id": str(uuid.uuid4())} if saw_init else {}
            return self._json(200, out if batch else out[0], hdrs)
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()

    def dispatch(self, m, method):
        i = m["id"]; p = m.get("params", {})
        def ok(r): return {"jsonrpc": "2.0", "id": i, "result": r}
        def err(c, s): return {"jsonrpc": "2.0", "id": i, "error": {"code": c, "message": s}}
        if method == "initialize":
            v = p.get("protocolVersion", "")
            sup = ["2024-11-05", "2025-03-26", "2025-06-18"]
            return ok({"protocolVersion": v if v in sup else "2025-06-18",
                       "capabilities": {"tools": {}},
                       "serverInfo": {"name": "agent-board-stand-in", "version": "0.0.1"}})
        if method == "ping": return ok({})
        if method == "tools/list": return ok({"tools": [PING_TOOL]})
        if method == "tools/call":
            if p.get("name") != "agent_board_ping": return err(-32602, "Unknown tool")
            msgv = p.get("arguments", {}).get("message", "")
            return ok({"content": [{"type": "text", "text": "pong from agent board: %s" % msgv}], "isError": False})
        return err(-32601, "Method not found")

def blackhole():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT)); s.listen(64)
    rec(kind="blackhole-up", port=PORT)
    held = []
    while True:
        c, a = s.accept()
        rec(kind="blackhole-accept", peer=a[1])
        held.append(c)  # never read, never write, never close

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if mode == "blackhole":
        blackhole()
    else:
        srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
        srv.allow_reuse_address = True
        rec(kind="server-up", port=PORT)
        srv.serve_forever()
