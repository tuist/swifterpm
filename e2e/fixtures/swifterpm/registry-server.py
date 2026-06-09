import http.server
import json
import pathlib
import socketserver
import sys
import urllib.parse

registry_dir = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def send_json(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/identifiers":
            self.send_json({"identifiers": ["example.registryfoo"]})
            return
        if parsed.path == "/example/registryfoo":
            if (registry_dir / "no-releases").exists():
                self.send_json({"releases": {}})
                return
            self.send_json({"releases": {"1.0.0": {}}})
            return
        if parsed.path == "/example/registryfoo/1.0.0":
            checksum = (registry_dir / "checksum.txt").read_text().strip()
            self.send_json({
                "resources": [
                    {
                        "name": "source-archive",
                        "type": "application/zip",
                        "checksum": checksum,
                    }
                ]
            })
            return
        if parsed.path == "/example/registryfoo/1.0.0.zip":
            data = (registry_dir / "registryfoo.zip").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()


with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    print(httpd.server_address[1], flush=True)
    httpd.serve_forever()
