#!/usr/bin/env python3
"""Local development HTTP server with Cross-Origin Isolation headers.

Godot 4 multi-threaded Web exports require SharedArrayBuffer, which modern
browsers only allow when the page is Cross-Origin Isolated via:
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
"""

import argparse
import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler


class CrossOriginIsolationHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser(description="Serve Godot Web export with COOP/COEP headers.")
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
    print(f"Serving {serve_dir} on http://{args.host}:{args.port} with Cross-Origin Isolation...")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
