#!/usr/bin/env python3
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    loaded_models = {}

    def log_message(self, *_): pass

    def do_GET(self):
        if self.path == "/api/version": self.send_json({"version": "test"})
        elif self.path == "/api/ps": self.send_json({"models": list(self.loaded_models.values())})
        elif self.path == "/api/tags": self.send_json({"models": [{"name": "mock", "size": 1024, "details": {"parameter_size": "test", "quantization_level": "Q4"}}]})
        else: self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        request = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/chat":
            system = "\n".join(message.get("content", "") for message in request.get("messages", [])
                               if message.get("role") == "system")
            if request.get("tools") and "current system date" in system and "live internet access" in system:
                content = "Live internet access is enabled and the current date was supplied by the proxy."
            elif request.get("tools"):
                content = "None of the provided functions are suitable."
            else:
                content = "Use value.replace(/\\)$/, '_red)')"
            return self.send_json({
                "message": {"role": "assistant", "content": content}, "done": True,
                "prompt_eval_count": 8, "eval_count": 4,
                "total_duration": 100000000, "eval_duration": 60000000
            })
        if self.path != "/api/generate": return self.send_error(404)
        if "keep_alive" in request and request["keep_alive"] in ("0", "-1"):
            return self.send_json({"error": "numeric keep_alive required"}, status=400)
        if "keep_alive" in request:
            time.sleep(.5)
            model = request.get("model", "?")
            if request["keep_alive"] == 0:
                self.loaded_models.pop(model, None)
            else:
                self.loaded_models[model] = {
                    "name": model, "size": 1024, "size_vram": 1024,
                    "expires_at": "9999-12-31T23:59:59Z" if request["keep_alive"] == -1 else "2026-08-21T14:00:00Z",
                    "details": {"quantization_level": "Q4"}
                }
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

    def send_json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

ThreadingHTTPServer(("127.0.0.1", 11436), Handler).serve_forever()
