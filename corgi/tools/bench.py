#!/usr/bin/env python3
"""Measures ghostty-host while `yes` scrolls: frame rates, per-frame cost,
main-thread and /mouse latency and CPU, with a GET /frames reader attached
and optionally GET /frames?format=raw&fps=60 piped into ffmpeg.

    python3 tools/bench.py [SECONDS] [--video OUT.mp4] -- HOST_ARGS...
"""
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import zlib

sys.path.insert(0, os.path.dirname(__file__))
from client import Host, _Conn, host_binary, read_gcf1  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TICK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100


def cpu_seconds(pid):
    if os.path.exists(f"/proc/{pid}/stat"):
        fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / TICK
    t = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    secs = 0.0
    for p in t.replace("-", ":").split(":"):
        secs = secs * 60 + float(p)
    return secs


def thread_cpu(pid):
    """CPU seconds per thread name (Linux only)."""
    out = {}
    if not os.path.isdir(f"/proc/{pid}/task"):
        return out
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            stat = open(f"/proc/{pid}/task/{tid}/stat").read()
        except OSError:
            continue
        name = re.sub(r"-\d+$", "-*", stat[stat.index("(") + 1:stat.rindex(")")])
        fields = stat.rsplit(")", 1)[1].split()
        out[name] = out.get(name, 0) + (int(fields[11]) + int(fields[12])) / TICK
    return out


def raw_frames(path, fps):
    """Yields frames from GET /frames?format=raw&fps=N, chunking removed."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.sendall(f"GET /frames?format=raw&fps={fps} HTTP/1.1\r\nHost: x\r\n\r\n".encode())
    f = s.makefile("rb", buffering=1 << 20)
    headers = {}
    while True:
        line = f.readline().strip()
        if not line:
            break
        if b":" in line:
            k, v = line.split(b":", 1)
            headers[k.strip().lower().decode()] = v.strip().decode()
    size = int(headers["x-frame-width"]) * int(headers["x-frame-height"]) * 4
    buf = bytearray()
    try:
        while True:
            n = int(f.readline().strip(), 16)
            if n == 0:
                return
            buf += f.read(n)
            f.readline()
            while len(buf) >= size:
                yield bytes(buf[:size])
                del buf[:size]
    finally:
        s.close()


def video(h, w, hgt, mp4, seconds, out):
    """Pipes GET /frames?format=raw&fps=60 into ffmpeg for `seconds`."""
    ff = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pixel_format", "rgba",
                           "-video_size", f"{w}x{hgt}", "-framerate", "60", "-i", "-", "-c:v", "libx264",
                           "-preset", "veryfast", "-pix_fmt", "yuv420p", mp4], stdin=subprocess.PIPE)
    want = int(seconds * 60)
    frames, distinct, last, gaps = 0, 0, None, []
    t0 = prev = time.monotonic()
    for px in raw_frames(h.path, 60):
        now = time.monotonic()
        gaps.append(now - prev)
        prev = now
        crc = zlib.crc32(px)
        distinct += crc != last
        last = crc
        ff.stdin.write(px)
        frames += 1
        if frames == want:
            break
    elapsed = time.monotonic() - t0
    ff.stdin.close()
    ff.wait()
    probe = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-count_frames", "-show_entries", "stream=width,height,nb_read_frames,r_frame_rate",
         "-of", "json", mp4], capture_output=True, text=True).stdout)["streams"][0]
    worst = max(range(1, len(gaps)), key=lambda i: gaps[i])
    gaps = sorted(gaps[1:])
    out.update({"mp4": mp4, "frames": frames, "wall_s": round(elapsed, 2), "fps": round(frames / elapsed, 1),
                "distinct_frames": distinct, "max_gap_ms": round(gaps[-1] * 1000, 1), "max_gap_at_frame": worst,
                "p99_gap_ms": round(gaps[int(len(gaps) * 0.99)] * 1000, 1), "probe": probe})


# A glide at 60 moves a second along the middle row, with a main-thread round
# trip that changes nothing every 200 ms. It runs in its own process so the
# /frames readers here don't hold its interpreter lock.
GLIDE = """
import json, sys, time
sys.path.insert(0, sys.argv[1])
from client import Host
h, seconds = Host(sys.argv[2]), float(sys.argv[3])
st = h.status()["size"]
mouse, focus, k = [], [], 0
t0 = t_next = time.monotonic()
while time.monotonic() - t0 < seconds:
    x = st["padding"]["left"] + (k % st["columns"]) * st["cell_width"] + 1
    a = time.monotonic()
    h.mouse("move", x=x, y=st["height"] // 2)
    mouse.append((time.monotonic() - a) * 1000)
    if k % 12 == 0:
        a = time.monotonic()
        h.focus(True)
        focus.append((time.monotonic() - a) * 1000)
    k += 1
    t_next += 1 / 60
    time.sleep(max(0, t_next - time.monotonic()))
print(json.dumps({"mouse": mouse, "focus": focus}))
"""


def bench(args, seconds=4.0, name="bench", video_path=None):
    d = f"/tmp/gh-{name}"
    subprocess.run(["rm", "-rf", d])
    proc = subprocess.Popen([host_binary(), "--dir", d] + args +
                            ["--", "/bin/bash", "--noprofile", "--norc"], stdout=subprocess.PIPE, text=True)
    ready = json.loads(proc.stdout.readline())
    h = Host.from_dir(d)
    h.settle(after=0)
    got = {"frames": 0, "bytes": 0, "skipped": 0}
    done = threading.Event()

    def reader():
        conn = _Conn(h.path, 60)
        conn.request("GET", "/frames")
        try:
            for hd, px in read_gcf1(conn.getresponse()):
                if done.is_set():
                    break
                got["frames"] += 1
                got["bytes"] += 64 + len(px)
                got["skipped"] += hd["skipped"]
        except Exception:
            pass  # the host quit mid-stream
        conn.close()

    threading.Thread(target=reader, daemon=True).start()
    time.sleep(0.3)
    h.type("yes 'scrolling text 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ'\n")
    time.sleep(0.5)
    vid = {}
    if video_path:
        vt = threading.Thread(target=video, args=(h, ready["width"], ready["height"], video_path, seconds, vid),
                              daemon=True)
        vt.start()
    s0, c0, tc0, t0, g0 = h.status(), cpu_seconds(proc.pid), thread_cpu(proc.pid), time.monotonic(), dict(got)
    glide = json.loads(subprocess.run([sys.executable, "-c", GLIDE, os.path.dirname(os.path.abspath(__file__)), h.path,
                                       str(seconds)], capture_output=True, text=True, check=True).stdout)
    lat, mouse = glide["focus"], glide["mouse"]
    s1, c1, tc1, t1, g1 = h.status(), cpu_seconds(proc.pid), thread_cpu(proc.pid), time.monotonic(), dict(got)
    if video_path:
        vt.join(timeout=seconds + 30)
    h.key("ctrl+c")
    done.set()
    span = t1 - t0
    rate = lambda k: round((s1["frames"][k] - s0["frames"][k]) / span, 1)  # noqa: E731
    lat.sort()
    mouse.sort()
    out = {
        "args": " ".join(args),
        "frame": [ready["width"], ready["height"]],
        "window_s": round(span, 2),
        "drawn_per_s": rate("drawn"),
        "published_per_s": rate("published"),
        "unchanged_per_s": rate("identical"),
        "overrun_per_s": rate("overrun"),
        "gpu_readback_us": s1["frames"]["gpu_readback"],
        "tap_on_main_us": s1["frames"]["tap"],
        "convert_compare_us": s1["frames"]["convert"],
        "readback_us": s1["readback"],
        "stream": {"frames_per_s": round((g1["frames"] - g0["frames"]) / span, 1),
                   "MB_per_s": round((g1["bytes"] - g0["bytes"]) / span / 1e6, 1),
                   "skipped": g1["skipped"] - g0["skipped"]},
        "main_thread_latency_ms": {"median": round(lat[len(lat) // 2], 2), "max": round(lat[-1], 2)},
        "mouse_move_ms": {"moves": len(mouse), "median": round(mouse[len(mouse) // 2], 2),
                          "p99": round(mouse[int(len(mouse) * 0.99)], 2), "max": round(mouse[-1], 2)},
        "mouse_on_main_us": s1.get("input_us", {}).get("mouse"),
        "host_cpu_percent": round((c1 - c0) / span * 100),
    }
    if tc1:
        out["thread_cpu_percent"] = {n: round((tc1[n] - tc0.get(n, 0)) / span * 100)
                                     for n in sorted(tc1, key=lambda n: tc0.get(n, 0) - tc1[n])
                                     if tc1[n] - tc0.get(n, 0) >= 0.01 * span}
    if vid:
        out["video_60fps"] = vid
    try:
        h.quit()
    except Exception:
        pass
    proc.wait(timeout=10)
    return out


if __name__ == "__main__":
    argv = sys.argv[1:]
    seconds, mp4 = 4.0, None
    while argv and argv[0] != "--":
        a = argv.pop(0)
        if a == "--video":
            mp4 = argv.pop(0)
        else:
            seconds = float(a)
    if argv and argv[0] == "--":
        argv.pop(0)
    print(json.dumps(bench(argv, seconds, video_path=mp4), indent=1))
