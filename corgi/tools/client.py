"""A small client for ghostty-host's HTTP API over its Unix socket.
Standard library only.

    from client import Host
    h = Host("/tmp/gh/ghostty.sock")
    n = h.type("ls\\n")["frame"]
    f = h.frame(after=n)            # raw RGBA, waits for a frame drawn after the input
    f.pixel(10, 10)                 # (r, g, b, a)
    png = h.png()                   # encoded in memory by the host
"""
import glob
import http.client
import json
import os
import socket
import struct


def host_binary():
    """$GHOSTTY_HOST, else the newest package corgi/build.ts made in corgi/out."""
    if os.environ.get("GHOSTTY_HOST"):
        return os.environ["GHOSTTY_HOST"]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    built = glob.glob(os.path.join(root, "out/*/ghostty-host-*/ghostty-host"))
    if not built:
        raise SystemExit("no ghostty-host: run bun corgi/build.ts, or set GHOSTTY_HOST")
    return max(built, key=os.path.getmtime)


class _Conn(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("ghostty-host", timeout=timeout)
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


class Frame:
    def __init__(self, headers, data):
        self.seq = int(headers["x-frame-seq"])
        self.width = int(headers["x-frame-width"])
        self.height = int(headers["x-frame-height"])
        self.stride = int(headers.get("x-frame-stride", self.width * 4))
        self.time_unix_ns = int(headers["x-frame-time-unix-ns"])
        self.data = data

    def pixel(self, x, y):
        i = y * self.stride + x * 4
        return tuple(self.data[i : i + 4])


class Host:
    def __init__(self, socket_path, timeout=30):
        self.path = socket_path
        self.timeout = timeout

    @classmethod
    def from_dir(cls, directory, **kw):
        with open(f"{directory}/socket") as f:
            return cls(f.read().strip(), **kw)

    def request(self, method, path, body=None):
        conn = _Conn(self.path, self.timeout)
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json"} if data is not None else {}
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        return resp.status, {k.lower(): v for k, v in resp.getheaders()}, payload

    def json(self, method, path, body=None):
        status, _, payload = self.request(method, path, body)
        out = json.loads(payload)
        if status != 200:
            raise RuntimeError(f"{method} {path}: {status} {out}")
        return out

    def status(self):
        return self.json("GET", "/status")

    def shape(self, after=None, timeout_ms=10000):
        q = f"?after={after}&timeout_ms={timeout_ms}" if after is not None else ""
        return self.json("GET", "/shape" + q)

    def key(self, key, **kw):
        return self.json("POST", "/key", dict(kw, key=key))

    def type(self, text):
        return self.json("POST", "/type", {"text": text})

    def mouse(self, action="move", **kw):
        return self.json("POST", "/mouse", dict(kw, action=action))

    def focus(self, focused):
        return self.json("POST", "/focus", {"focused": focused})

    def _get_frame(self, after, timeout_ms, fmt):
        q = [f"format={fmt}"]
        if after is not None:
            q += [f"after={after}", f"timeout_ms={timeout_ms}"]
        status, headers, payload = self.request("GET", "/frame?" + "&".join(q))
        if status != 200:
            raise TimeoutError(payload.decode()) if status == 504 else RuntimeError(payload.decode())
        return headers, payload

    def frame(self, after=None, timeout_ms=10000):
        return Frame(*self._get_frame(after, timeout_ms, "rgba"))

    def png(self, after=None, timeout_ms=10000):
        return self._get_frame(after, timeout_ms, "png")[1]

    def settle(self, after=None, quiet_ms=400, timeout_ms=10000):
        """Waits for a frame after `after`, then until none follows for quiet_ms."""
        f = self.frame(after=after, timeout_ms=timeout_ms)
        while True:
            try:
                f = self.frame(after=f.seq, timeout_ms=quiet_ms)
            except TimeoutError:
                return f

    def settle_wait(self, quiet_ms=500, timeout_ms=10000):
        return self.json("GET", f"/settle?quiet_ms={quiet_ms}&timeout_ms={timeout_ms}")

    def quit(self):
        return self.json("POST", "/quit", {})


def read_gcf1(stream):
    """Yields (header dict, pixels) from a GET /frames body (chunking removed)."""
    while True:
        head = stream.read(64)
        if len(head) < 64:
            return
        magic, size, w, h, stride, fmt, seq, t_unix, t_mono, skipped, _, nbytes = struct.unpack(
            "<4sIIIIIQqqIIQ", head
        )
        assert magic == b"GCF1" and size == 64, head
        pixels = stream.read(nbytes)
        yield dict(width=w, height=h, stride=stride, format=fmt, seq=seq, time_unix_ns=t_unix,
                   time_mono_ns=t_mono, skipped=skipped), pixels
