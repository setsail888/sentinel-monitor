#!/usr/bin/env python3
"""假面板：实现探针要用的 getProbeTasks + reportProbe。

只监听回环地址。每次请求记一行 JSON 到 --record 文件
（含 parsed 的 action/args 与 raw 原始请求体）。
模式（只影响 reportProbe；getProbeTasks 始终 200）：
  ok         始终 200
  flaky2     前 2 次 reportProbe 返回 500，之后 200
  alwaysfail reportProbe 始终 500
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument('--port', type=int, required=True)
ap.add_argument('--mode', default='ok', choices=['ok', 'flaky2', 'alwaysfail'])
ap.add_argument('--tasks-file', default='')
ap.add_argument('--record', default='')
ap.add_argument('--delay', type=float, default=0)
args = ap.parse_args()

state = {'report_attempts': 0, 'tasks_text': ''}
if args.tasks_file:
    with open(args.tasks_file, encoding='utf-8') as f:
        state['tasks_text'] = f.read()


def record(obj):
    if args.record:
        with open(args.record, 'a', encoding='utf-8') as f:
            f.write(json.dumps(obj, ensure_ascii=False) + '\n')


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n).decode('utf-8', 'replace')
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        action = body.get('action')
        record({'action': action, 'args': body.get('args'), 'raw': raw})
        if action == 'getProbeTasks':
            self._send(200, {'tasksText': state['tasks_text']})
        elif action == 'reportProbe':
            if args.delay:
                time.sleep(args.delay)
            state['report_attempts'] += 1
            if args.mode == 'alwaysfail':
                self._send(500, {'error': 'fail'})
            elif args.mode == 'flaky2' and state['report_attempts'] <= 2:
                self._send(500, {'error': 'fail'})
            else:
                self._send(200, {'ok': True})
        else:
            self._send(400, {'error': 'unknown action'})


ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer(('127.0.0.1', args.port), H).serve_forever()
