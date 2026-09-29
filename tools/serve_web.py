#!/usr/bin/env python3
"""Local development HTTP server with Cross-Origin Isolation headers and CORS proxy.

Godot 4 multi-threaded Web exports require SharedArrayBuffer, which modern
browsers only allow when the page is Cross-Origin Isolated via:
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp

This server also includes a built-in companion CORS proxy endpoint at:
  /cors-proxy?url=<target_url>
allowing the HTML5 web build to download online levels and music from RobTop,
GDBrowser, and GDHistory without browser CORS errors.
"""

import argparse
import os
import sys
import urllib.parse
import urllib.request
from http.server import HTTPServer, SimpleHTTPRequestHandler


class CrossOriginIsolationHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS, HEAD")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path.startswith("/cors-proxy"):
            self._handle_proxy("GET")
            return
        super().do_GET()

    def do_POST(self):
        if self.path.startswith("/cors-proxy"):
            self._handle_proxy("POST")
            return
        self.send_error(404, "Not Found")

    def _extract_target_url(self) -> str:
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        if "url" in qs and qs["url"]:
            return qs["url"][0]
        # Alternative path style: /cors-proxy/https://...
        path_part = parsed.path[len("/cors-proxy"):]
        if path_part.startswith("/"):
            path_part = path_part[1:]
        if path_part.startswith("http://") or path_part.startswith("https://"):
            return path_part
        return ""

    def _handle_proxy(self, method: str):
        target_url = self._extract_target_url()
        if not target_url:
            self.send_response(400)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"Missing target url parameter (?url=...)")
            return

        body = None
        if method == "POST":
            content_length = int(self.headers.get("Content-Length", 0))
            if content_length > 0:
                body = self.rfile.read(content_length)

        headers = {}
        content_type = self.headers.get("Content-Type")
        if content_type:
            headers["Content-Type"] = content_type
        # RobTop requires an empty or missing user-agent
        if "boomlings.com" not in target_url:
            headers["User-Agent"] = "Godot-Dash-Web/1.0"
        else:
            headers["User-Agent"] = ""

        try:
            req = urllib.request.Request(target_url, data=body, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_data = resp.read()
                self.send_response(resp.status)
                resp_content_type = resp.headers.get("Content-Type", "text/plain")
                self.send_header("Content-Type", resp_content_type)
                self.send_header("Content-Length", str(len(resp_data)))
                self.end_headers()
                self.wfile.write(resp_data)
        except urllib.error.HTTPError as e:
            err_data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "text/plain"))
            self.send_header("Content-Length", str(len(err_data)))
            self.end_headers()
            self.wfile.write(err_data)
        except Exception as e:
            msg = str(e).encode("utf-8")
            self.send_response(502)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)


def main():
    parser = argparse.ArgumentParser(description="Serve Godot Web export with COOP/COEP headers and CORS proxy.")
    parser.add_argument("--dir", default="export/Web", help="Directory to serve (default: export/Web)")
    parser.add_argument("--port", type=int, default=8060, help="Port to listen on (default: 8060)")
    parser.add_argument("--host", default="0.0.0.0", help="Host address (default: 0.0.0.0)")
    args = parser.parse_args()

    serve_dir = os.path.abspath(args.dir)
    if not os.path.isdir(serve_dir):
        print(f"Directory {serve_dir} does not exist. Creating it...")
        os.makedirs(serve_dir, exist_ok=True)

    handler = lambda *h_args, **h_kwargs: CrossOriginIsolationHandler(
        *h_args, directory=serve_dir, **h_kwargs
    )

    server = HTTPServer((args.host, args.port), handler)
    print(f"Serving {serve_dir} on http://{args.host}:{args.port} with Cross-Origin Isolation and CORS proxy (/cors-proxy?url=)...")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
