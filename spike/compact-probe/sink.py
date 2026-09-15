import http.server, json, sqlite3, sys, threading, time, os

DB = sys.argv[1]
PORT = int(sys.argv[2])

conn = sqlite3.connect(DB, check_same_thread=False)
conn.execute("""CREATE TABLE IF NOT EXISTS hook_event (
  id INTEGER PRIMARY KEY,
  session_id TEXT,
  event TEXT NOT NULL,
  payload TEXT NOT NULL,
  at INTEGER NOT NULL
)""")
conn.commit()
lock = threading.Lock()

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n)
        try:
            o = json.loads(body)
        except Exception:
            o = {}
        with lock:
            conn.execute("INSERT INTO hook_event(session_id,event,payload,at) VALUES (?,?,?,?)",
                         (o.get("session_id",""), o.get("hook_event_name",""),
                          body.decode("utf-8","replace"), int(time.time()*1000)))
            conn.commit()
        self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
