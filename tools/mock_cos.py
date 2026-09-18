#!/usr/bin/env python3
"""
本地 mock：同时扮演「签发临时密钥的后端」和「腾讯云 COS」。

用途：在没有腾讯云账号的情况下，把客户端整条上传链路（取密钥 → 分片上传
→ 进度回调 → 暂停续传 → 合并）真实跑通。签名照常计算，只是这里不校验。

真实环境下把 cosSTSURL / cosEndpoint 换成你的 SCF 函数和 COS 域名即可，
客户端代码不用改。

    python3 tools/mock_cos.py [port]

端点：
    GET  /sts                                 临时密钥（JSON）
    POST /<key>?uploads                       初始化分片 → UploadId
    PUT  /<key>?partNumber=N&uploadId=X       上传第 N 片 → ETag
    POST /<key>?uploadId=X                    合并分片
    GET  /__log                               收到的请求流水（JSON），自检用
"""

import json
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

# uploadId -> {"key": str, "parts": {number: size}, "completed": bool}
SESSIONS = {}
# 按顺序记下每一片，续传测试要据此确认「第 1 片没有被重传」
PART_LOG = []
REQUEST_LOG = []
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # 默认会把每个请求打到 stderr，自检输出已经够吵了，关掉
        pass

    # ---------- 工具 ----------

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _send(self, status, body=b"", content_type="application/xml", extra_headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _record(self, method, path, query, note=""):
        with LOCK:
            REQUEST_LOG.append({
                "method": method,
                "path": path,
                "query": {k: v[0] for k, v in query.items()},
                "auth": (self.headers.get("Authorization") or "")[:60],
                "token": bool(self.headers.get("x-cos-security-token")),
                "note": note,
                "at": time.time(),
            })

    # ---------- 路由 ----------

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)

        if parsed.path == "/sts":
            self._record("GET", parsed.path, query)
            expires = int(time.time()) + 3600
            # 两种常见结构都带上，客户端只用得着其中一份，
            # 顺便当作对客户端「宽容解析」的验证
            self._send(200, json.dumps({
                "credentials": {
                    "tmpSecretId": "AKIDMOCK" + uuid.uuid4().hex[:12].upper(),
                    "tmpSecretKey": uuid.uuid4().hex,
                    "sessionToken": "MOCKTOKEN" + uuid.uuid4().hex,
                },
                "startTime": int(time.time()),
                "expiredTime": expires,
                "Response": {
                    "Credentials": {
                        "TmpSecretId": "AKIDMOCK" + uuid.uuid4().hex[:12].upper(),
                        "TmpSecretKey": uuid.uuid4().hex,
                        "Token": "MOCKTOKEN" + uuid.uuid4().hex,
                    },
                    "ExpiredTime": expires,
                },
            }), content_type="application/json")
            return

        if parsed.path == "/__log":
            with LOCK:
                payload = {
                    "parts": list(PART_LOG),
                    "requests": list(REQUEST_LOG),
                    "sessions": {
                        uid: {
                            "key": s["key"],
                            "parts": {str(k): v for k, v in sorted(s["parts"].items())},
                            "completed": s["completed"],
                        }
                        for uid, s in SESSIONS.items()
                    },
                }
            self._send(200, json.dumps(payload), content_type="application/json")
            return

        if parsed.path == "/__reset":
            with LOCK:
                SESSIONS.clear()
                PART_LOG.clear()
                REQUEST_LOG.clear()
            self._send(200, json.dumps({"ok": True}), content_type="application/json")
            return

        self._send(404, "not found", content_type="text/plain")

    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        key = unquote(parsed.path.lstrip("/"))
        body = self._read_body()

        if "uploads" in query:
            upload_id = uuid.uuid4().hex
            with LOCK:
                SESSIONS[upload_id] = {"key": key, "parts": {}, "completed": False}
            self._record("POST", parsed.path, query, note=f"initiate {key}")
            self._send(200, (
                '<?xml version="1.0" encoding="UTF-8"?>'
                "<InitiateMultipartUploadResult>"
                f"<Bucket>mock</Bucket><Key>{key}</Key>"
                f"<UploadId>{upload_id}</UploadId>"
                "</InitiateMultipartUploadResult>"
            ))
            return

        if "uploadId" in query:
            upload_id = query["uploadId"][0]
            with LOCK:
                session = SESSIONS.get(upload_id)
                if session:
                    session["completed"] = True
                    part_summary = dict(sorted(session["parts"].items()))
                else:
                    part_summary = {}
            self._record("POST", parsed.path, query,
                         note=f"complete {len(part_summary)} parts")
            if "uploadId" not in query:
                self._send(400, "missing uploadId", content_type="text/plain")
                return
            self._send(200, (
                '<?xml version="1.0" encoding="UTF-8"?>'
                "<CompleteMultipartUploadResult>"
                f"<Location>mock/{key}</Location><Bucket>mock</Bucket><Key>{key}</Key>"
                "</CompleteMultipartUploadResult>"
            ))
            return

        self._send(404, "not found", content_type="text/plain")

    def do_PUT(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query, keep_blank_values=True)
        key = unquote(parsed.path.lstrip("/"))
        body = self._read_body()

        upload_id = query.get("uploadId", [None])[0]
        part_number = query.get("partNumber", [None])[0]

        if upload_id and part_number:
            number = int(part_number)
            etag = '"%s"' % uuid.uuid4().hex[:16]
            with LOCK:
                session = SESSIONS.setdefault(upload_id, {"key": key, "parts": {}, "completed": False})
                session["parts"][number] = len(body)
                PART_LOG.append({
                    "uploadId": upload_id,
                    "partNumber": number,
                    "bytes": len(body),
                    "at": time.time(),
                })
            self._record("PUT", parsed.path, query, note=f"part {number} {len(body)}B")
            self._send(200, b"", extra_headers={"ETag": etag})
            return

        # 单次 PUT（客户端没走分片上传时才会到这里）
        with LOCK:
            PART_LOG.append({"uploadId": None, "partNumber": 1, "bytes": len(body), "at": time.time()})
        self._record("PUT", parsed.path, query, note=f"single {len(body)}B")
        self._send(200, b"", extra_headers={"ETag": '"%s"' % uuid.uuid4().hex[:16]})

    def do_DELETE(self):
        self._send(204, b"")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"▶ mock COS/STS 已启动: http://127.0.0.1:{port}", flush=True)
    print(f"   STS:  http://127.0.0.1:{port}/sts", flush=True)
    print(f"   日志: http://127.0.0.1:{port}/__log", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n▶ 已停止", flush=True)


if __name__ == "__main__":
    main()
