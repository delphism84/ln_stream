#!/usr/bin/env python3
import json
import os
import time
import threading
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    request_queue_size = 256


class HookHandler(BaseHTTPRequestHandler):
    # SRS HTTP API
    SRS_API = "http://127.0.0.1:1985/api/v1"

    # hard limits to avoid slowloris / huge bodies
    MAX_BODY_BYTES = 64 * 1024
    SOCKET_TIMEOUT_SEC = 2.0

    # IMPORTANT:
    # For unstable cameras/uploader, killing publishers from hooks can cause the uploader to stop permanently.
    # Make these behaviors configurable and default to OFF for safety.
    ENABLE_PUBLISH_HEALTHCHECK_KILL = os.environ.get("SRS_HOOKS_PUBLISH_HEALTHCHECK_KILL", "0") == "1"
    ENABLE_WATCHDOG_KILL = os.environ.get("SRS_HOOKS_WATCHDOG_KILL", "0") == "1"

    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')

    def do_GET(self):
        if self.path == "/healthz":
            body = b"ok"
            self.send_response(200)
            self._cors()
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self._cors()
        self.end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _read_json_body(self):
        try:
            try:
                self.connection.settimeout(self.SOCKET_TIMEOUT_SEC)
            except Exception:
                pass

            length = int(self.headers.get('Content-Length') or 0)
            if length <= 0:
                return {}
            if length > self.MAX_BODY_BYTES:
                # too large; don't block reading
                return {"_too_large": True, "_length": length}

            raw = self.rfile.read(length)
            if not raw:
                return {}
            return json.loads(raw.decode('utf-8') or '{}')
        except Exception:
            return {}

    def _srs_get_client(self, client_id: str):
        for url in (
            f"{self.SRS_API}/clients/{client_id}",
            f"{self.SRS_API}/clients/?id={client_id}",
        ):
            try:
                with urllib.request.urlopen(url, timeout=1.5) as resp:
                    j = json.loads(resp.read().decode('utf-8') or '{}')
                # /clients/{id} returns {code, client} sometimes; normalize
                if isinstance(j, dict) and j.get('client') and isinstance(j.get('client'), dict):
                    return j.get('client')
                if isinstance(j, dict) and j.get('id'):
                    return j
                if isinstance(j, dict) and j.get('clients'):
                    for c in (j.get('clients') or []):
                        if str(c.get('id')) == str(client_id):
                            return c
            except Exception:
                continue
        return None

    def _srs_list_clients(self, count: int = 5000):
        for url in (
            f"{self.SRS_API}/clients/?count={count}",
            f"{self.SRS_API}/clients/?count=10000",
            f"{self.SRS_API}/clients/",
        ):
            try:
                with urllib.request.urlopen(url, timeout=2.0) as resp:
                    j = json.loads(resp.read().decode('utf-8') or '{}')
                if isinstance(j, dict) and isinstance(j.get('clients'), list):
                    return j.get('clients') or []
            except Exception:
                continue
        return []

    def _srs_kill_client(self, client_id: str):
        for endpoint in (
            f"{self.SRS_API}/clients/{client_id}",
            f"{self.SRS_API}/clients/?id={client_id}",
        ):
            try:
                req = urllib.request.Request(endpoint, method="DELETE")
                urllib.request.urlopen(req, timeout=1.5).read()
                return True
            except Exception:
                continue
        return False

    def _maybe_kill_other_publishers_for_same_stream(self, *, client_id: str, stream_name: str, ip_addr: str):
        """
        When a publisher reconnects quickly, SRS may still keep the previous publisher session for the same stream,
        causing StreamBusy for the new attempt. To reduce manual SRS restarts, we proactively kill the *old* publisher,
        but only when it's clearly safe:
        - same IP tries to publish the same stream (most common reconnect case), or
        - old publisher looks dead (alive long but recv_30s ~ 0).
        """
        try:
            if not stream_name or not client_id:
                return

            clients = self._srs_list_clients()
            if not clients:
                return

            for c in clients:
                try:
                    if not c.get('publish'):
                        continue
                    if (c.get('name') or '') != stream_name:
                        continue
                    if str(c.get('id')) == str(client_id):
                        continue

                    old_cid = str(c.get('id') or '')
                    if not old_cid:
                        continue

                    c_ip = str(c.get('ip') or '')
                    kbps = c.get('kbps') or {}
                    alive = float(c.get('alive') or 0)
                    recv_30s = float(kbps.get('recv_30s') or 0)
                    send_30s = float(kbps.get('send_30s') or 0)

                    should_kill = (c_ip and ip_addr and c_ip == ip_addr) or (alive >= 60.0 and recv_30s < 0.05 and send_30s < 0.05)
                    if should_kill:
                        ok = self._srs_kill_client(old_cid)
                        print(f"[HOOKS] takeover: kill old publisher stream={stream_name} old_cid={old_cid} old_ip={c_ip} alive={alive:.1f}s recv_30s={recv_30s} ok={ok}")
                except Exception:
                    continue
        except Exception:
            return

    def _schedule_publish_healthcheck(self, client_id: str, delay_sec: float = 45.0, min_recv_kbps: float = 0.05):
        def _check():
            try:
                time.sleep(delay_sec)
                ci = self._srs_get_client(client_id)
                if not ci or not ci.get('publish'):
                    return

                alive = float(ci.get('alive', 0) or 0)
                kbps = ci.get('kbps') or {}
                recv_30s = float(kbps.get('recv_30s', 0) or 0)
                send_30s = float(kbps.get('send_30s', 0) or 0)
                recv_bytes = int(ci.get('recv_bytes', 0) or 0)

                # very lenient. only kill clearly dead sessions.
                if alive < 60.0:
                    if alive > 30.0 and recv_bytes == 0:
                        self._srs_kill_client(client_id)
                    elif alive > 45.0 and recv_30s < 0.05 and send_30s < 0.05:
                        self._srs_kill_client(client_id)
                    return

                if recv_bytes > 0 and recv_30s <= min_recv_kbps and send_30s <= min_recv_kbps:
                    self._srs_kill_client(client_id)
            except Exception:
                pass

        threading.Thread(target=_check, daemon=True).start()

    def do_POST(self):
        data = self._read_json_body()

        # If body too large, still respond quickly (do not block)
        if isinstance(data, dict) and data.get('_too_large'):
            body = json.dumps({"code": 0}).encode('utf-8')
            self.send_response(200)
            self._cors()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        app_name = (data.get('app') or 'live') if isinstance(data, dict) else 'live'
        stream_name = (data.get('stream') or '') if isinstance(data, dict) else ''
        client_id = (data.get('client_id') or data.get('client') or '') if isinstance(data, dict) else ''

        if self.path in ('/on_publish', '/on_unpublish'):
            if self.path == '/on_publish':
                ip_addr = (data.get('ip') or 'unknown') if isinstance(data, dict) else 'unknown'
                if stream_name:
                    print(f"[HOOKS] on_publish: client_id={client_id}, stream={stream_name}, app={app_name}, ip={ip_addr}")
                # If an old publisher session is still hanging around, proactively kill it so the next retry succeeds.
                if client_id and stream_name and ip_addr and ip_addr != 'unknown':
                    self._maybe_kill_other_publishers_for_same_stream(client_id=str(client_id), stream_name=str(stream_name), ip_addr=str(ip_addr))
                # Do NOT kill publishers by default. Poor cameras can stall and get kicked, and some uploaders won't retry.
                if client_id and self.ENABLE_PUBLISH_HEALTHCHECK_KILL:
                    self._schedule_publish_healthcheck(str(client_id), delay_sec=45.0, min_recv_kbps=0.05)
            else:
                if stream_name:
                    print(f"[HOOKS] on_unpublish: client_id={client_id}, stream={stream_name}, app={app_name}")

            body = json.dumps({"code": 0}).encode('utf-8')
            self.send_response(200)
            self._cors()
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self._cors()
        self.end_headers()


def start_watchdog(srs_api: str, interval_sec: float = 30.0, min_alive_sec: float = 60.0, min_recv_kbps: float = 0.05):
    def _loop():
        while True:
            try:
                with urllib.request.urlopen(f"{srs_api}/clients/", timeout=2.0) as resp:
                    j = json.loads(resp.read().decode('utf-8') or '{}')

                for c in (j.get('clients') or []):
                    try:
                        if not c.get('publish'):
                            continue
                        alive = float(c.get('alive', 0) or 0)
                        if alive < min_alive_sec:
                            continue
                        kbps = c.get('kbps') or {}
                        recv_30s = float(kbps.get('recv_30s', 0) or 0)
                        send_30s = float(kbps.get('send_30s', 0) or 0)
                        recv_bytes = int(c.get('recv_bytes', 0) or 0)
                        if recv_bytes > 0 and recv_30s <= min_recv_kbps and send_30s <= min_recv_kbps:
                            cid = c.get('id')
                            if cid:
                                for endpoint in (f"{srs_api}/clients/{cid}", f"{srs_api}/clients/?id={cid}"):
                                    try:
                                        req = urllib.request.Request(endpoint, method="DELETE")
                                        urllib.request.urlopen(req, timeout=1.5).read()
                                        break
                                    except Exception:
                                        continue
                    except Exception:
                        continue
            except Exception:
                pass
            time.sleep(interval_sec)

    threading.Thread(target=_loop, daemon=True).start()


def main():
    host = '0.0.0.0'
    port = 8085

    if HookHandler.ENABLE_WATCHDOG_KILL:
    start_watchdog(HookHandler.SRS_API, interval_sec=30.0, min_alive_sec=60.0, min_recv_kbps=0.05)
        print("[HOOKS] watchdog_kill=enabled")
    else:
        print("[HOOKS] watchdog_kill=disabled")

    httpd = ThreadingHTTPServer((host, port), HookHandler)
    print(f"srs hooks http listening on {host}:{port}")
    httpd.serve_forever()


if __name__ == '__main__':
    main()
