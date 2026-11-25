#!/usr/bin/env python3
"""Runs ghostty-host through the prototype's checks and prints what it saw.

    python3 tools/prove.py OUT_DIR

Saves a few small PNGs (fetched with ?format=png, encoded in memory by the
host), two mp4s and the byte logs of the key and mouse checks in OUT_DIR.
Nothing else is written there.
"""
import atexit
import json
import os
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from client import Host, host_binary  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOST = host_binary()
WINLIST = os.path.join(ROOT, "out/macos-aarch64/winlist")
OUT = os.path.abspath(sys.argv[1])
os.makedirs(OUT, exist_ok=True)
MACOS = sys.platform == "darwin"
HELLO = ["sh", "-c", 'printf "hello\\n"; exec sleep 600']

# Logs every read from its raw tty as (monotonic time, length, bytes).
RECORDER = """
import os, struct, sys, time, tty
tty.setraw(0)
log = open(sys.argv[1], "ab", buffering=0)
while True:
    d = os.read(0, 4096)
    if not d:
        break
    log.write(struct.pack("<dI", time.monotonic(), len(d)) + d)
"""


def front_app():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    out = subprocess.run(["lsappinfo", "info", "-only", "name", asn], capture_output=True, text=True).stdout
    return out.strip().split("=")[-1].strip('"')


started = []


@atexit.register
def _cleanup():
    for p, d in started:
        if p.poll() is None:
            p.kill()
            p.wait()
        shutil.rmtree(d, ignore_errors=True)


def start(name, args, command):
    d = f"/tmp/gh-prove-{name}"
    subprocess.run(["rm", "-rf", d])
    p = subprocess.Popen([HOST, "--dir", d] + args + ["--"] + command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True)
    started.append((p, d))
    ready = json.loads(p.stdout.readline())  # printed after DIR/socket is written
    h = Host.from_dir(d)
    h.proc, h.ready, h.dir = p, ready, d
    return h


def stop(h):
    try:
        h.quit()
    except Exception:
        pass
    h.proc.wait(timeout=10)


def save_png(h, name, after=None):
    data = h.png(after=after) if after is not None else h.png()
    path = os.path.join(OUT, name)
    with open(path, "wb") as f:
        f.write(data)
    return path


def tty_write(h, s):
    with open(h.status()["tty"], "w") as f:
        f.write(s)


def ms_stats(values):
    v = sorted(values)
    return {"median": round(v[len(v) // 2], 2), "p95": round(v[int(len(v) * 0.95)], 2), "max": round(v[-1], 2)}


class Recorder:
    """A host whose command logs the bytes its tty receives."""

    def __init__(self, name, args):
        self.log = os.path.join(OUT, f"{name}.bytes")
        if os.path.exists(self.log):
            os.unlink(self.log)
        self.h = start(name, args, [sys.executable, "-c", RECORDER, self.log])
        self.h.settle(after=0)
        self.pos = 0
        deadline = time.monotonic() + 5
        while not os.path.exists(self.log) and time.monotonic() < deadline:
            time.sleep(0.01)

    def reads(self):
        """(time, bytes) for every read since the last call."""
        with open(self.log, "rb") as f:
            f.seek(self.pos)
            data = f.read()
        out, i = [], 0
        while i + 12 <= len(data):
            t, n = struct.unpack("<dI", data[i:i + 12])
            if i + 12 + n > len(data):
                break
            out.append((t, data[i + 12:i + 12 + n]))
            i += 12 + n
        self.pos += i
        return out

    def wait_bytes(self, n_min, timeout=2.0, trail=0.05):
        got, deadline = [], time.monotonic() + timeout
        while time.monotonic() < deadline:
            got += self.reads()
            if sum(len(b) for _, b in got) >= n_min:
                break
            time.sleep(0.002)
        time.sleep(trail)  # anything that trails
        return got + self.reads()


report = {"platform": sys.platform}

# --- 1-4: the hello command ---------------------------------------------------------
before = front_app() if MACOS else None
a = start("a", ["--size", "80x24", "--font-size", "14", "--config", "cursor-style-blink=false"], HELLO)
first = a.settle(after=0)
if MACOS:
    report["front_app"] = {"before": before, "after_start": front_app()}
    report["windows"] = subprocess.run([WINLIST, str(a.ready["pid"])], capture_output=True, text=True).stdout.strip()
else:
    report["display_env"] = {k: os.environ.get(k) for k in ("DISPLAY", "WAYLAND_DISPLAY")}
    report["windows"] = a.status()["windows"]
    # Unix sockets the host has open, by path: only its own, no X or Wayland.
    pid = a.ready["pid"]
    inodes = {os.readlink(f"/proc/{pid}/fd/{fd}")[8:-1] for fd in os.listdir(f"/proc/{pid}/fd")
              if os.readlink(f"/proc/{pid}/fd/{fd}").startswith("socket:")}
    paths = set()
    for line in open("/proc/net/unix").read().splitlines()[1:]:
        f = line.split()
        if f[6] in inodes:
            paths.add(f[7] if len(f) > 7 else "(unnamed)")
    report["unix_sockets"] = sorted(paths)
report["hello"] = {"ready": a.ready, "png": save_png(a, "1-hello.png")}

# Idle: Ghostty redraws every 600 ms for the cursor timer; identical frames aren't published.
s0 = a.status()["frames"]
time.sleep(3)
s1 = a.status()["frames"]
report["idle_3s"] = {k: s1[k] - s0[k] for k in ("drawn", "published", "identical")}

n = a.type("typed: Hello, World! ~/a_b-c (1+2)=3 é\n")["frame"]
a.key("ctrl+l")  # echoed by the tty as ^L
f = a.settle(after=n)
report["typed"] = {"png": save_png(a, "2-typed.png")}

shapes = {"start": a.shape()["shape"]}
seq = a.shape()["seq"]
tty_write(a, "\x1b[?1003h\x1b[?1006h")
shapes["tracking_on"] = a.shape(after=seq)["shape"]
n = a.mouse("move", x=100, y=50)["frame"]
a.mouse("move", x=300, y=200)
a.mouse("click", x=300, y=200)
a.mouse("click", x=40, y=100, button="right")
a.mouse("scroll", x=40, y=100, dy=1)
a.settle(after=n)
report["mouse"] = {"png": save_png(a, "3-mouse.png")}
seq = a.shape()["seq"]
tty_write(a, "\x1b[?1003l")
shapes["tracking_off"] = a.shape(after=seq)["shape"]
seq = a.shape()["seq"]
tty_write(a, "\x1b]22;pointer\x07")
shapes["osc22_pointer"] = a.shape(after=seq)["shape"]
seq = a.shape()["seq"]
tty_write(a, "\x1b]22;\x07")
shapes["osc22_reset"] = a.shape(after=seq)["shape"]
report["shapes"] = shapes
report["shape_changes"] = a.shape(after=0)["changes"]

# --- 5: colors -------------------------------------------------------------------------
BLOCK = "\x1b[2J\x1b[H\x1b[48;2;255;0;0m    \x1b[0m\x1b[48;2;0;255;0m    \x1b[0m\x1b[48;2;0;0;255m    \x1b[0m\n"


def sample_colors(h):
    n = h.status()["frame"]["seq"]
    tty_write(h, BLOCK)
    f = h.settle(after=n)
    st = h.status()["size"]
    y = st["padding"]["top"] + st["cell_height"] // 2
    x0 = st["padding"]["left"] + st["cell_width"] * 2
    w4 = st["cell_width"] * 4
    return {"red": f.pixel(x0, y), "green": f.pixel(x0 + w4, y), "blue": f.pixel(x0 + 2 * w4, y),
            "background": f.pixel(f.width // 2, f.height - st["padding"]["bottom"] - st["cell_height"] // 2)}


report["colors_passthrough"] = sample_colors(a)
report["colors_png"] = save_png(a, "4-colors.png")
stop(a)

if MACOS:
    c = start("c", ["--size", "80x24", "--font-size", "14", "--color", "convert"], HELLO)
    c.settle(after=0)
    report["colors_convert"] = sample_colors(c)
    report["convert_status"] = c.status()["frames"]["pixels"]
    stop(c)

# --- 6: keys, as the program reads them -------------------------------------------------
KEYS = [
    ({"key": "ctrl+a"}, b"\x01"),
    ({"key": "ctrl+c"}, b"\x03"),
    ({"key": "ctrl+z"}, b"\x1a"),
    ({"key": "alt+x"}, b"\x1bx"),
    ({"key": "alt+b"}, b"\x1bb"),
    ({"key": "ctrl+alt+a"}, b"\x1b\x01"),
    ({"key": "F1"}, b"\x1bOP"),
    ({"key": "F5"}, b"\x1b[15~"),
    ({"key": "F12"}, b"\x1b[24~"),
    ({"key": "shift+F5"}, b"\x1b[15;2~"),
    ({"key": "ctrl+F12"}, b"\x1b[24;5~"),
    ({"key": "Up"}, b"\x1b[A"),
    ({"key": "ctrl+Left"}, b"\x1b[1;5D"),
    ({"key": "Home"}, b"\x1b[H"),
    ({"key": "Page_Down"}, b"\x1b[6~"),
    ({"key": "shift+Tab"}, b"\x1b[Z"),
    ({"key": "Return"}, b"\r"),
    ({"key": "BackSpace"}, b"\x7f"),
    ({"key": "Escape"}, b"\x1b"),
    ({"key": "A"}, b"A"),
    ({"key": "a", "text": "é"}, "é".encode()),
    ({"type": "é"}, "é".encode()),
    ({"type": "Hi! ~"}, b"Hi! ~"),
]
k = Recorder("6-keys", ["--size", "80x24", "--font-size", "14"])
keys = {}
for req, want in KEYS:
    if "type" in req:
        k.h.type(req["type"])
        name = "type " + req["type"]
    else:
        k.h.json("POST", "/key", req)
        name = req["key"] + (f" text={req['text']}" if "text" in req else "")
    got = b"".join(b for _, b in k.wait_bytes(len(want)))
    keys[name] = "ok" if got == want else f"got {got!r}, want {want!r}"
report["keys"] = keys
report["keys_ok"] = [sum(v == "ok" for v in keys.values()), len(keys)]
stop(k.h)

# --- 7: mouse reports at the right cells, and a glide -----------------------------------
m = Recorder("7-mouse", ["--size", "80x24", "--font-size", "14", "--config", "cursor-style-blink=false"])
st = m.h.status()["size"]
cw, ch, pl, pt = st["cell_width"], st["cell_height"], st["padding"]["left"], st["padding"]["top"]


def sgr(b, x, y, up=False):
    return f"\x1b[<{b};{(x - pl) // cw + 1};{(y - pt) // ch + 1}{'m' if up else 'M'}".encode()


seq = m.h.shape()["seq"]
tty_write(m.h, "\x1b[?1003h\x1b[?1006h")
m.h.shape(after=seq, timeout_ms=2000)
m.wait_bytes(10**9, timeout=0.1)
steps = [
    ({"action": "move", "x": 100, "y": 50}, sgr(35, 100, 50)),
    ({"action": "move", "x": 300, "y": 200}, sgr(35, 300, 200)),
    ({"action": "click", "x": 300, "y": 200}, sgr(0, 300, 200) + sgr(0, 300, 200, up=True)),
    ({"action": "click", "x": 40, "y": 100, "button": "right"},
     sgr(35, 40, 100) + sgr(2, 40, 100) + sgr(2, 40, 100, up=True)),
    # A wheel step scrolls 3 lines (Ghostty's mouse-scroll-multiplier, discrete:3).
    ({"action": "scroll", "x": 40, "y": 100, "dy": 1}, sgr(64, 40, 100) * 3),
    ({"action": "scroll", "x": 40, "y": 100, "dy": -1}, sgr(65, 40, 100) * 3),
    ({"action": "press", "x": 500, "y": 300, "mods": "ctrl"}, sgr(35 + 16, 500, 300) + sgr(16, 500, 300)),
    ({"action": "move", "x": 520, "y": 330}, sgr(32, 520, 330)),
    ({"action": "release", "x": 520, "y": 330}, sgr(0, 520, 330, up=True)),
]
reports = {}
for req, want in steps:
    m.h.json("POST", "/mouse", req)
    got = b"".join(b for _, b in m.wait_bytes(len(want)))
    reports[json.dumps(req)] = "ok" if got == want else f"got {got!r}, want {want!r}"
report["mouse_reports"] = reports
report["mouse_reports_ok"] = [sum(v == "ok" for v in reports.values()), len(reports)]

# A glide: 60 moves a second along row 5, as a caller animating a pointer
# sends them. Each report's arrival is timed against its request.
m.wait_bytes(10**9, timeout=0.1)
lat, sent = [], []
y = pt + ch * 4 + ch // 2
t_next = time.monotonic()
for i in range(60):
    t0 = time.monotonic()
    m.h.mouse("move", x=pl + cw // 2 + i * cw, y=y)
    lat.append((time.monotonic() - t0) * 1000)
    sent.append(t0)
    t_next += 1 / 60
    time.sleep(max(0, t_next - time.monotonic()))
times = [t for t, b in m.wait_bytes(10**9, timeout=0.3) for _ in range(b.count(b"\x1b[<"))]
delays = [(times[i] - sent[i]) * 1000 for i in range(min(len(times), len(sent)))]
report["glide_reports"] = {"moves": len(sent), "reports": len(times), "request_ms": ms_stats(lat),
                           "report_after_request_ms": ms_stats(delays) if delays else None}
stop(m.h)

# Without tracking, with the link modifier held (ctrl, or command on macOS):
# the pointer shape and the link highlight follow a glide over an OSC 8 link.
LINK_KEY = "MetaLeft" if MACOS else "ControlLeft"
g = start("g", ["--size", "80x24", "--font-size", "14", "--config", "cursor-style-blink=false"], HELLO)
g.settle(after=0)
n = g.status()["frame"]["seq"]
tty_write(g, "\x1b[2J\x1b[H\n\n  plain text \x1b]8;;https://example.com\x07a linked phrase here\x1b]8;;\x07 more\n")
g.settle(after=n)
st = g.status()["size"]
cw, ch, pl, pt = st["cell_width"], st["cell_height"], st["padding"]["left"], st["padding"]["top"]
y = pt + ch * 2 + ch // 2
LINK = range(13, 33)  # columns of "a linked phrase here"
g.json("POST", "/key", {"key": LINK_KEY, "action": "press"})
seq0 = g.shape()["seq"]
lat, entered, left = [], None, None
t_next = time.monotonic()
for col in range(0, 45):
    t0 = time.time()
    g.mouse("move", x=pl + col * cw + cw // 2, y=y)
    lat.append((time.time() - t0) * 1000)
    if col == LINK[0]:
        entered = t0
    if col == LINK[-1] + 1:
        left = t0
    t_next += 1 / 60
    time.sleep(max(0, t_next - time.monotonic()))
changes = g.shape(after=seq0, timeout_ms=0)["changes"]
into = next((c for c in changes if c["shape"] == "pointer"), None)
out = next((c for c in changes if c["shape"] != "pointer" and into and c["seq"] > into["seq"]), None)
glide = {
    "moves": len(lat),
    "request_ms": ms_stats(lat),
    "shapes": [c["shape"] for c in changes],
    "pointer_after_entering_ms": round((into["time_unix_ns"] / 1e9 - entered) * 1000, 2) if into else None,
    "text_after_leaving_ms": round((out["time_unix_ns"] / 1e9 - left) * 1000, 2) if out else None,
}
# The highlight: the first frame drawn after a move onto the link.
g.mouse("leave")
time.sleep(0.3)
f_out = g.frame()
t0 = time.time()
n = g.mouse("move", x=pl + LINK[3] * cw, y=y)["frame"]
f_in = g.frame(after=n, timeout_ms=2000)
glide["highlight_frame_ms"] = round((f_in.time_unix_ns / 1e9 - t0) * 1000, 2)
rows = slice((pt + ch * 2) * f_in.stride, (pt + ch * 3) * f_in.stride)
glide["highlight_changed_link_row"] = f_in.data[rows] != f_out.data[rows]
glide["png"] = save_png(g, "8-link-hover.png")
g.json("POST", "/key", {"key": LINK_KEY, "action": "release"})
report["glide_link"] = glide
stop(g)

# --- 8: cat -v plus the child's environment ----------------------------------------------
# As if launched from inside another Ghostty.
os.environ.update(GHOSTTY_RESOURCES_DIR="/Applications/Ghostty.app/Contents/Resources/ghostty",
                  GHOSTTY_SHELL_FEATURES="leaked")
b = start("b", ["--size", "100x30", "--font-size", "14", "--config", "cursor-style-blink=false"],
          ["/bin/bash", "--noprofile", "--norc"])
del os.environ["GHOSTTY_SHELL_FEATURES"]
b.settle(after=0)
b.type("PS1='$ '; clear; env | grep -E '^(GHOSTTY|TERM)' | sort; ps -o pid,ppid,args -p $$,$PPID\n")
n = b.type("printf '\\e[?1003h\\e[?1006h'; stty -echo -icanon; cat -v\n")["frame"]
b.settle(after=n)
n = b.mouse("move", x=10, y=10)["frame"]
b.mouse("move", x=200, y=100)
b.mouse("click", x=400, y=300)
b.mouse("click", x=120, y=60, button="right")
b.mouse("scroll", x=120, y=60, dy=-1)
b.settle(after=n)
report["catv"] = {"png": save_png(b, "5-catv-env.png")}
stop(b)

# --- 9: the host goes when its command does, with its exit code -------------------------
x = start("x", [], ["sh", "-c", "sleep 0.5; exit 7"])
code = x.proc.wait(timeout=10)
report["command_exit"] = {"host_exit_code": code, "socket_left": os.path.exists(x.path),
                          "socket_file_left": os.path.exists(os.path.join(x.dir, "socket"))}

# --- 10: ffmpeg straight from GET /frames?format=raw&fps=60 ------------------------------
e = start("e", ["--size", "80x24", "--font-size", "14"], ["/bin/bash", "--noprofile", "--norc"])
e.settle(after=0)
w, hgt = e.ready["width"], e.ready["height"]
mp4 = os.path.join(OUT, "6-pipe.mp4")
curl = subprocess.Popen(["curl", "-sN", "--unix-socket", e.path, "http://x/frames?format=raw&fps=60"],
                        stdout=subprocess.PIPE)
ff = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pixel_format", "rgba",
                       "-video_size", f"{w}x{hgt}", "-framerate", "60", "-i", "-", "-t", "3",
                       "-pix_fmt", "yuv420p", mp4], stdin=curl.stdout)
t0 = time.monotonic()
time.sleep(0.5)
e.type("for i in $(seq 1 25); do echo line $i; sleep 0.1; done\n")
ff.wait(timeout=30)
elapsed = time.monotonic() - t0
curl.kill()
curl.wait()
probe = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_entries",
                        "stream=width,height,nb_read_frames,r_frame_rate", "-of", "json", mp4],
                       capture_output=True, text=True).stdout
report["ffmpeg_pipe"] = {"mp4": mp4, "probe": json.loads(probe)["streams"][0], "wall_s": round(elapsed, 2)}
stop(e)

# --- 11: cost and frame rate while text scrolls, with ffmpeg at 60 fps -------------------
from bench import bench  # noqa: E402

report["bench_1x"] = bench(["--size", "120x36", "--font-size", "16"], 4, "d1",
                           video_path=os.path.join(OUT, "7-yes-60fps.mp4"))
report["bench_2x"] = bench(["--size", "120x36", "--font-size", "16", "--scale", "2"], 4, "d2")

print(json.dumps(report, indent=1))
