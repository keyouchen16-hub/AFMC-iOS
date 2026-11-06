#!/usr/bin/env python3
"""AFMC 主机桥接（M2-A 参考实现）。

手机 → 本服务 → TorrServer → 磁力视频流（Range/HTTP）→ AVPlayer。

环境变量：
  AFMC_HOST_TOKEN  可选；设置后所有请求必须带 X-AFMC-Token 头。
  AFMC_TS_URL      可选；TorrServer 地址，默认 http://127.0.0.1:8091。
  AFMC_TS_PORT     可选；TorrServer 对外端口，默认 8091。
"""
import json
import os
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TORRSERVER = os.environ.get("AFMC_TS_URL", "http://127.0.0.1:8091")
TS_PUBLIC_PORT = int(os.environ.get("AFMC_TS_PORT", "8091"))
TOKEN = os.environ.get("AFMC_HOST_TOKEN", "")
LIBRARY_FILE = os.environ.get("AFMC_LIBRARY_FILE", "/tmp/afmc-bbb/prefix.mp4")
VIDEO_EXT = (".mp4", ".mkv", ".webm", ".avi", ".mov")
RESOLVE_TIMEOUT = 60


def ts_post(path, payload):
    req = urllib.request.Request(
        TORRSERVER + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as response:
        return json.load(response)


def resolve(magnet):
    added = ts_post("/torrents", {"action": "add", "link": magnet, "save_to_db": False})
    hash_value = added.get("hash", "").lower()
    if len(hash_value) != 40 or any(c not in "0123456789abcdef" for c in hash_value):
        raise ValueError("引擎未返回有效资源哈希")
    deadline = time.monotonic() + RESOLVE_TIMEOUT
    torrent = added
    while True:
        if torrent.get("hash", "").lower() != hash_value:
            raise ValueError("种子状态与所选资源不一致")
        files = [f for f in (torrent.get("file_stats") or [])
                 if f["path"].lower().endswith(VIDEO_EXT)]
        if files:
            video = max(files, key=lambda f: f["length"])
            return hash_value, video["id"], video["path"], video["length"]
        if time.monotonic() >= deadline:
            raise TimeoutError("等待元数据超时")
        time.sleep(1)
        torrent = ts_post("/torrents", {"action": "get", "hash": hash_value})



class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        return not TOKEN or self.headers.get("X-AFMC-Token") == TOKEN

    def do_GET(self):
        if not self._authorized():
            self._json(401, {"error": "token required"})
            return
        if self.path.split("?", 1)[0] == "/library/bbb.mp4":
            self._serve_file(LIBRARY_FILE)
            return
        if self.path == "/health":
            try:
                info = ts_post("/torrents", {"action": "list"})
                self._json(200, {"status": "ok", "engine": "torrserver",
                                 "torrents": len(info), "auth": bool(TOKEN)})
            except Exception as exc:
                self._json(503, {"status": "engine-error", "error": str(exc)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            self._json(401, {"error": "token required"})
            return
        if self.path != "/resolve":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            magnet = payload.get("magnet", "").strip()
            if not magnet.startswith("magnet:"):
                self._json(400, {"error": "magnet required"})
                return
            hash_value, file_id, path, size = resolve(magnet)
            host = self.headers.get("Host", "127.0.0.1").split(":")[0]
            encoded = urllib.parse.quote(magnet, safe="")
            url = (f"http://{host}:{TS_PUBLIC_PORT}/play/{hash_value}/{file_id}"
                   f"?link={encoded}")
            self._json(200, {"hash": hash_value, "fileIndex": file_id,
                             "name": path, "size": size, "url": url})
        except TimeoutError as exc:
            self._json(504, {"error": str(exc)})
        except Exception as exc:
            self._json(500, {"error": str(exc)})

    def _serve_file(self, path):
        if not os.path.isfile(path):
            self._json(404, {"error": "测试片还没准备好"})
            return
        size = os.path.getsize(path)
        start, end = 0, size - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header:
            if not range_header.startswith("bytes="):
                self.send_error(416)
                return
            spec = range_header.split("=", 1)[1].split(",", 1)[0].strip()
            left, _, right = spec.partition("-")
            try:
                if left == "":
                    tail = int(right)
                    start = max(0, size - tail)
                else:
                    start = int(left)
                    end = int(right) if right else size - 1
            except ValueError:
                self.send_error(416)
                return
            end = min(end, size - 1)
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining:
                chunk = handle.read(min(256 * 1024, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"AFMC host bridge on http://0.0.0.0:8765 (auth={'token' if TOKEN else 'off'})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8765), Handler).serve_forever()
