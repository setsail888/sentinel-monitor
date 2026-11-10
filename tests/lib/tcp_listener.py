#!/usr/bin/env python3
"""回环 TCP 监听：接受连接后立即关闭。仅用于测试。"""
import argparse
import socket
import threading
import time

ap = argparse.ArgumentParser()
ap.add_argument('--port', type=int, required=True)
args = ap.parse_args()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', args.port))
s.listen(16)


def accept_loop():
    while True:
        try:
            c, _ = s.accept()
        except OSError:
            return
        c.close()


threading.Thread(target=accept_loop, daemon=True).start()
while True:
    time.sleep(3600)
