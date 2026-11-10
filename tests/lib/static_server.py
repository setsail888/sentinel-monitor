#!/usr/bin/env python3
"""回环静态服务器：任何路径都返回 200；可选 TLS（--cert/--key）。
请求行记入 --log 文件。仅用于测试。"""
import argparse
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument('--port', type=int, required=True)
ap.add_argument('--cert', default='')
ap.add_argument('--key', default='')
ap.add_argument('--log', default='')
args = ap.parse_args()


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _handle(self):
        if args.log:
            with open(args.log, 'a', encoding='utf-8') as f:
                f.write(self.command + ' ' + self.path + '\n')
        body = b'ok'
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    do_GET = _handle
    do_HEAD = _handle
    do_POST = _handle


ThreadingHTTPServer.allow_reuse_address = True
srv = ThreadingHTTPServer(('127.0.0.1', args.port), H)
if args.cert:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(args.cert, args.key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
