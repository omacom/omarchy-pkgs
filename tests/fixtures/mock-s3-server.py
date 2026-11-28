#!/usr/bin/env python3
"""Minimal local mock S3 server for tests/publish-artifact.sh."""

import http.server
import os
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(self.server.mode_path) as f:
            mode = f.read().strip()
        if mode == "empty":
            body = (
                b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                b"<Name>omarchy-pkgs</Name><Prefix>edge/x86_64/</Prefix>"
                b"<KeyCount>0</KeyCount><MaxKeys>1000</MaxKeys>"
                b"<IsTruncated>false</IsTruncated></ListBucketResult>"
            )
            self.send_response(200)
        elif mode == "404":
            body = b"<Error><Code>NoSuchBucket</Code><Message>No such bucket</Message></Error>"
            self.send_response(404)
        else:
            body = b"<Error><Code>InternalError</Code><Message>Internal Error</Message></Error>"
            self.send_response(500)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    mode_path, port_path = sys.argv[1], sys.argv[2]
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.mode_path = mode_path
    tmp_path = f"{port_path}.tmp"
    with open(tmp_path, "w") as f:
        f.write(str(srv.server_address[1]))
    os.replace(tmp_path, port_path)
    srv.serve_forever()


if __name__ == "__main__":
    main()
