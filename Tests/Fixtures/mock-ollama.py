#!/usr/bin/env python3
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def do_GET(self):
        if self.path == "/api/version": self.send_json({"version": "test"})
        elif self.path == "/api/ps": self.send_json({"models": []})
        else: self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        request = json.loads(self.rfile.read(length) or b"{}")
        if self.path != "/api/generate": return self.send_error(404)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        tokens = (["working"] * 200) if request.get("prompt") == "slow" else ("hello", " world")
        try:
            for token in tokens:
                self.wfile.write((json.dumps({"response": token, "done": False}) + "\n").encode())
                self.wfile.flush(); time.sleep(.05 if request.get("prompt") == "slow" else .03)
        except (BrokenPipeError, ConnectionResetError):
            return
        final = {"done": True, "prompt_eval_count": 4, "eval_count": 2,
                 "total_duration": 100000000, "load_duration": 10000000,
                 "prompt_eval_duration": 20000000, "eval_duration": 60000000}
        self.wfile.write((json.dumps(final) + "\n").encode()); self.wfile.flush()

    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

ThreadingHTTPServer(("127.0.0.1", 11436), Handler).serve_forever()
