# ghostty-host

A headless host for the full libghostty from Ghostty v1.4.0, on macOS and
Linux. It runs a command in a Ghostty surface that has no window, takes
scripted keys and mouse input, reports the pointer shape, and hands out every
changed frame Ghostty's renderer draws, from memory over HTTP on a Unix
socket. On macOS that is the Metal renderer behind an NSView with no window;
on Linux, the OpenGL renderer on a surfaceless EGL display, with no X server,
Wayland compositor or GPU required.

Corgi's capture tool (`tools/ghostty_screenshot.ts`) runs its terminals in
it. It lives here, in a Ghostty fork, because Linux needs a small patch to
libghostty (see The libghostty patch); macOS uses libghostty unchanged.

## Build

`corgi/build.ts` builds the libghostty in this tree for each target, compiles
the host against it, and packs each with Ghostty's resources and license into
`corgi/out/ghostty-host-VERSION-TARGET.tar.gz`. It needs Bun and Zig 0.17.0
(`$ZIG` or `zig` on PATH):

```sh
bun corgi/build.ts                  # every target this machine builds
bun corgi/build.ts linux-x86_64     # one: macos-aarch64, linux-x86_64 or linux-aarch64
```

macOS arm64 builds on a Mac, with Xcode for the Metal shaders: the
xcframework's `libghostty-internal.a`, linked with AppKit, Metal, QuartzCore,
IOSurface, CoreText, CoreVideo, CoreGraphics, Carbon, libc++ and zlib.

Linux x86_64 and arm64 cross-compile on any machine with Zig, against glibc
2.28. A package holds `ghostty-host`, `libghostty.so` (found through an
`$ORIGIN` rpath; the static archive lacks libxml2 and libc++) and `share/`.
The library leaves the glad GL and EGL loaders and libEGL to the program, as
Ghostty's own executable compiles them: the host compiles `vendor/glad`, and
links a stub named `libEGL.so.1` so that the machine's own libEGL (from
libglvnd, with Mesa or NVIDIA behind it) loads at run time. It calls zlib in
libghostty rather than linking another.

The host finds Ghostty's resources in `share/ghostty` beside it.

### Releasing

Corgi pins a version in its `scripts/ghostty-host`, which downloads the build
from `https://corgi.computer/ghostty-host/VERSION/` on first use. To release:
commit, tag `vX.Y.Z-corgi.N` (the Ghostty version, then a counter), and on a
Mac run

```sh
bun corgi/build.ts --publish
```

It builds every target, uploads the archives and `SHA256SUMS` to
`ghostty-host/VERSION/` in Corgi's release bucket (the config and credentials
`bun run publish` uses), refuses to replace a published file with other
bytes, and checks each through the public URL. Then put the version and
checksums in Corgi's `scripts/ghostty-host`.

## Run

```sh
corgi/out/macos-aarch64/ghostty-host-*/ghostty-host --dir /tmp/cap --size 120x36 --font-size 16 \
  --config cursor-style-blink=false -- sh -c 'printf "hello\n"; exec sleep 600'
S=$(cat /tmp/cap/socket)
curl -s --unix-socket "$S" -o shot.png 'http://x/frame?format=png'
```

It prints one JSON line when ready (`socket`, `pid`, `width`, `height`, grid).
When the command exits, the host removes its socket and `DIR/socket` and
exits with the command's exit code, as a Ghostty window closes with its
command. `POST /quit` exits 0.

| option | |
| --- | --- |
| `--dir DIR` | listen on `DIR/ghostty.sock`, or `/tmp/ghostty-host-PID.sock` when that path is too long for a socket (104 bytes on macOS, 108 on Linux); `DIR/socket` names the one in use. Both are removed on exit. |
| `--socket PATH` | listen on PATH instead |
| `--size COLSxROWS` | grid (default 80x24); the frame is sized to fit it exactly |
| `--font-size N` | points at 96 dpi on both platforms, see Font size |
| `--scale S` | backing scale (default 1; 2 for Retina-sized frames) |
| `--fps N` | Ghostty's draw rate while the screen changes (default 60), see Pacing |
| `--config KEY=VALUE` | any Ghostty config line, applied last; repeatable |
| `--config-file PATH` | a Ghostty config file; repeatable. Your own config is never loaded. |
| `--color passthrough\|convert` | macOS: see Colors (default passthrough). Linux frames are always sRGB. |
| `--cwd DIR` | working directory |
| `--login` | macOS: run the command through login(1) as Ghostty.app does. Ghostty on Linux never does. |

## API

Coordinates are frame pixels, origin top left. Input requests return after
the main thread handled the events, with `{"ok":true,"frame":N}`: N is the
last frame drawn before the input, so `GET /frame?after=N` waits for one
drawn after it. Errors: `{"ok":false,"error":"..."}` with 400, 404, 405 or
504 (timeout).

| request | |
| --- | --- |
| `GET /status` | pid, focus, held modifiers, size (width, height, scale, cell size, columns, rows, padding), latest frame, shape, readback cost, frame counts (`drawn`, `published`, `identical`, `overrun`) and timings (`tap` on the main thread, `convert`, `gpu_readback`), input timings (`input_us`), tty, and the window server's windows for this pid (always `[]`) |
| `GET /frame[?after=N&timeout_ms=T&format=png]` | latest frame as raw RGBA (`width*height*4`, top row first), or a PNG encoded in memory. Headers `x-frame-seq`, `-width`, `-height`, `-stride`, `-format`, `-time-unix-ns`, `-time-mono-ns`. With `after`, waits for a newer frame. |
| `GET /frames[?after=N]` | chunked stream of every published frame: 64-byte GCF1 header + pixels, until the client disconnects |
| `GET /frames?format=raw[&fps=N]` | bare RGBA for ffmpeg; with `fps` the latest frame goes out N times a second |
| `GET /settle?quiet_ms=500&timeout_ms=10000` | `{"settled":true,"frame":N}` once nothing changed for `quiet_ms` |
| `GET /shape[?after=N&timeout_ms=T]` | `{"seq","shape","visible","changes":[...]}`; CSS names (`text`, `default`, `pointer`, ...); waits for a change after N |
| `POST /key` | `{"key":"ctrl+b"}`, `{"key":["ctrl+b","c","Return","shift+Tab","Up"]}`, `{"key":"shift_left","action":"press"}`, `{"key":"a","text":"é"}`. Keybind syntax, W3C codes, Ghostty key names or X keysyms; `action` tap/press/release/repeat. Modifiers go down as their own keys; ones pressed with `press` stay held, also for the mouse. US layout, option as alt. |
| `POST /type` | `{"text":"echo hi\n"}` taps the US-layout keys for each character; other characters are committed as text |
| `POST /mouse` | `{"action":"move\|press\|release\|click\|scroll\|leave","x","y","button","count","mods","dx","dy","precise"}`, or an array of them (a drag). `dy` > 0 scrolls up. `mods` press and release their keys around each event; hold one across a glide with `/key` `press`. |
| `POST /focus` | `{"focused":false}` |
| `POST /action` | `{"action":"..."}` runs a Ghostty keybind action |
| `POST /quit` | stops the host |

`input_us` in `/status` gives, for mouse ops and for the other input ops,
the average and maximum time they waited for the main thread and ran on it.

GCF1 header, little-endian: `"GCF1"`, u32 header size (64), u32 width, u32
height, u32 stride, u32 format (1 = RGBA8, premultiplied alpha), u64 seq, i64
Unix ns, i64 monotonic ns (`CLOCK_UPTIME_RAW` on macOS, `CLOCK_MONOTONIC` on
Linux), u32 frames this stream skipped (a reader more than 8 frames behind
loses the oldest), u32 reserved, u64 pixel bytes. `seq` counts drawn frames,
so published seqs can skip.

```sh
curl -sN --unix-socket "$S" 'http://x/frames?format=raw&fps=60' |
  ffmpeg -f rawvideo -pixel_format rgba -video_size 1564x1012 -framerate 60 -i - \
    -c:v libx264 -pix_fmt yuv420p out.mp4
```

`tools/client.py` is a small Python client; `tools/prove.py OUT` runs the
checks below; `tools/bench.py [SECONDS] [--video OUT.mp4] -- ARGS` measures
a scrolling run. Both run `$GHOSTTY_HOST`, else the newest build in `corgi/out`.

## Layout

`main.c` (options, Ghostty config and callbacks, pointer shape), `frames.c`
(the frame worker and subscribers), `http.c`, `input.c`, `json.c` and
`image.c` are shared. Each platform implements the interface in `host.h`
(main loop, surface platform, frame hand-off): `platform_macos.m` and
`pacer_macos.c` on macOS, `platform_linux.c` on Linux.

## The libghostty patch

The commit "libghostty: add a headless platform for OpenGL surfaces": 170
lines added and 3 removed in 6 files. Ghostty v1.4.0's embedding API only knows macOS and iOS views; its
OpenGL renderer already draws without a display (`opengl/Device.zig` opens
`EGL_PLATFORM_SURFACELESS_MESA` and draws into its own targets), but no
embedder could create a surface for it. The patch adds:

- `GHOSTTY_PLATFORM_HEADLESS` (`ghostty.h`, `apprt/embedded.zig`): a surface
  with no view, accepted only when the library's renderer exports frames
  (OpenGL). A Metal library refuses it (`Metal.zig` marks the case
  unreachable). Its surface reports presentation as unhealthy, so
  `OpenGL.present()` reads each frame back into CPU memory
  (`readPixelsAlloc`) instead of exporting a DMABUF.
- `ghostty_surface_take_frame` / `ghostty_frame_free`: on
  `GHOSTTY_ACTION_RENDER` the embedder takes the latest frame from the
  renderer's latest-frame slot (`renderer.takeFrame()`, as GTK does): RGBA8,
  premultiplied alpha, bottom row first, with the time the readback took
  (`OpenGL.zig` measures it).
- Pacing (`renderer/Thread.zig`): `ghostty_platform_headless_s.max_fps`. A
  wakeup renders at once if a frame interval has passed since the last paced
  frame, else arms a timer for when it has; wakeups in between coalesce into
  that frame. A steady stream of wakeups keeps the cadence; after a quiet
  spell the next frame draws at once.
- `build.zig`: the Linux library build installs Ghostty's resources
  (terminfo, shell integration, themes), as the xcframework build does.

macOS behaves as before: macOS surfaces have no frame interval, so the
renderer thread takes the existing path, and the headless union member is a
double, the size of the existing view pointers. The macOS host doesn't use
any of the patch.

A second commit, "build: build the OpenGL bindings for the target", lets the
Linux library cross-compile from macOS: the OpenGL package was the one
dependency built for the build machine, and eglplatform.h makes
`EGL_DEFAULT_DISPLAY` an int on macOS but a pointer on Linux.

## How it works on macOS

- **Surface.** An `NSView` with no window is the surface's `nsview`
  (`GHOSTTY_PLATFORM_MACOS`). The Metal renderer makes it layer-hosting with
  its own `IOSurfaceLayer`. The view is sized from the `initial_size` action
  Ghostty sends for `window-width`/`window-height`, so the grid is exact.
  `ghostty_surface_set_occlusion` is never called, so the surface stays
  visible. `wakeup_cb` schedules `ghostty_app_tick` on the main queue.
- **Frames.** Ghostty sets each finished frame (an IOSurface) as the layer's
  `contents` on the main thread. The host moves that one layer instance onto
  a runtime subclass whose `-setContents:` locks the IOSurface read-only,
  copies it, and calls CALayer's. A worker converts BGRA to RGBA, compares
  with the previous frame, and publishes it only if the pixels changed. An
  idle screen still redraws on Ghostty's 600 ms cursor timer; those frames
  are counted as `identical` and not published.
- **Off screen.** `NSApplicationActivationPolicyProhibited` (no Dock icon,
  never active) and an `NSProcessInfo` activity against App Nap.
  `CGWindowListCopyWindowInfo` lists no window for the process.
- **Colors.** By default the host sets `window-colorspace = display-p3`.
  Ghostty's shaders then skip their sRGB-to-P3 step, and the P3-tagged
  surface holds the configured sRGB values unchanged, as OpenGL does on Linux
  (`#282c34` reads back as `#282c34`).
  `--color convert` keeps Ghostty's macOS pipeline and converts P3 back to
  sRGB on the CPU (D65 matrix, sRGB curve). That round trip through 8 bits is
  lossy for saturated colors: pure green came back as `(3,255,0)`.
- **Direct command.** On macOS, Exec.zig wraps every command in
  `/usr/bin/login -flp USER bash -c "exec -l CMD"`: "Last login" is printed
  first and CMD becomes a login shell. It skips that when the passwd entry
  has no user name. libghostty is linked statically, so the host's own
  `getpwuid_r` is the one it calls; it clears `pw_name` when a command is
  given. Ghostty then runs `/bin/sh -c "exec CMD"`, and CMD's parent is the
  host.
- **Pacing.** With vsync (Ghostty's default) the renderer draws when its
  `CVDisplayLink` fires and skips draws on terminal wakeups. With no active
  display (screen locked, asleep, lid closed) `CVDisplayLinkCreate` fails and
  Ghostty draws on every wakeup. The host defines the seven `CVDisplayLink*`
  functions libghostty calls as a dispatch timer at `--fps`, so the
  renderer is paced the same with or without a display. AppKit and Core
  Animation keep CoreVideo's.

## How it works on Linux

- **Surface.** A `GHOSTTY_PLATFORM_HEADLESS` surface with `max_fps = --fps`.
  Ghostty opens a surfaceless EGL display; libglvnd picks the first vendor
  that supports it (NVIDIA when its driver is installed, else Mesa, which
  falls back to llvmpipe when it can't open `/dev/dri`). Set
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`
  to force Mesa. No `DISPLAY` or `WAYLAND_DISPLAY` is needed, and the host
  opens no X or Wayland socket.
- **Frames.** On `GHOSTTY_ACTION_RENDER` the main thread takes the frame and
  lends Ghostty's buffer to the worker, copying nothing; the worker flips the
  rows to top first while it copies, compares, publishes, and frees the
  buffer. Ghostty renders into an sRGB target and reads it back unchanged, so
  pixels are the configured colors.
- **Main loop.** One thread runs queued calls in order: ticks from
  `wakeup_cb`, and input ops from HTTP threads, which wait for theirs. No
  AppKit or libdispatch.
- **Keys.** `/key` sends XKB keycodes (evdev + 8) from `src/keymap.h`.
- **Command.** Ghostty on Linux runs `/bin/sh -c "exec CMD"` itself, with
  no login wrapper.

Both platforms remove inherited `GHOSTTY_*` variables (a parent Ghostty's
`GHOSTTY_RESOURCES_DIR` points into its own resources) before
`ghostty_init`, and point `GHOSTTY_RESOURCES_DIR` at `share/ghostty` beside
the executable.

## Font size

Ghostty turns points into pixels at 72 dpi × scale on macOS and 96 dpi ×
scale elsewhere, as Ghostty GTK under Xvfb `-dpi 96` does. `--font-size N`
means N points at 96 dpi on both: the macOS host passes N × 96/72 to Ghostty.
A `font-size` given with `--config` or a config file is Ghostty's own points.

| `--font-size` | macOS cell | Linux cell |
| --- | --- | --- |
| 14 | 11x25 (scale 2: 22x49) | 11x25 (scale 2: 22x49) |
| 16 | 13x28 (scale 2: 26x56) | 13x28 (scale 2: 26x57) |

120x36 at 16 is 1564x1012 on both at scale 1. At scale 2 the frames differ
slightly: the cell height (CoreText and FreeType round the line height
differently) and Ghostty's default 2-point padding, 4 px per side on macOS
and 5 on Linux, since padding also follows the dpi.

## Measured

2026-11-25, from `tools/prove.py` and `tools/bench.py`. "yes" is `yes` with a
70-character line scrolling 120x36 at `--font-size 16`, with a `/frames`
reader attached and a glide of 60 `/mouse` moves a second from another
process.

Machines: Apple M3, macOS 15.8, screen locked (no active display). nocap:
Ubuntu 24.04, AMD EPYC 7C13 (256 threads), no `DISPLAY` or
`WAYLAND_DISPLAY`, no Xvfb in use; NVIDIA RTX 6000 Ada (driver 580.196.07),
or Mesa's llvmpipe (LLVM 20.1.2) forced through
`__EGL_VENDOR_LIBRARY_FILENAMES`.

The same on all three:

- Idle for 3 s: 5 frames drawn (cursor timer), 0 published.
- Pointer shape: `text` at start, `default` with `?1003h`, `text` after
  `?1003l`, `pointer` after `OSC 22;pointer`, `text` after `OSC 22;`.
- Colors: red `(255,0,0)`, green `(0,255,0)`, blue `(0,0,255)`, background
  `(40,44,52)`. macOS `--color convert`: green `(3,255,0)`.
- Keys, as the program's raw tty reads them: 23 of 23 exact, including
  `ctrl+a`, `ctrl+alt+a`, `alt+x`, F1, F5, F12, `shift+F5`, `ctrl+F12`,
  `ctrl+Left`, `shift+Tab`, `é` typed and as key text.
- Mouse reports: 9 of 9 SGR sequences at the cells under the pixels sent
  (moves, left and right clicks, wheel steps of 3 lines, a ctrl drag).
- A command exiting with 7: the host exits 7 and leaves no socket.
- `GET /frames?format=raw&fps=60 | ffmpeg -t 3`: 180 frames at 60/1 in 3.1 s.
- No window: macOS `CGWindowListCopyWindowInfo` listed 441 windows from 43
  processes, 0 for the host; on Linux the host's only named socket is its
  own.

Input, idle (60 moves a second, each a new cell):

| | macOS | Linux NVIDIA | Linux Mesa |
| --- | --- | --- | --- |
| `/mouse` round trip, median / max | 0.29 / 0.97 ms | 0.84 / 1.04 ms | 0.85 / 1.02 ms |
| mouse report read by the program, after the request (median / max) | 0.19 / 0.79 ms | 0.61 / 0.74 ms | 0.64 / 0.95 ms |
| shape `pointer` after entering an OSC 8 link (ctrl or command held) / `text` after leaving | 0.61 / 0.20 ms | 0.47 / 0.40 ms | 0.53 / 0.50 ms |
| link highlight frame drawn after the move | 1.5 ms | 4.7 ms | 3.8 ms |

Under yes:

| | macOS 1x | macOS 2x | NVIDIA 1x | NVIDIA 2x | Mesa 1x | Mesa 2x |
| --- | --- | --- | --- | --- | --- | --- |
| frame | 1564x1012 | 3128x2024 | 1564x1012 | 3130x2062 | 1564x1012 | 3130x2062 |
| drawn / published per s | 60 / 58 | 60 / 55 | 60 / 60 | 30 / 29 (30-60 across runs) | 60 / 60 | 57 / 57 |
| readback into CPU memory, avg (max) | 5 µs (31) lock | 5 µs (25) lock | 7.0 ms (12.5) | 32.7 ms (39) | 4.7 ms (8.5) | 12.0 ms (39) |
| copy on the main thread, avg (max) | 0.37 ms (1.2) | 0.83 ms (15) | none | none | none | none |
| convert or flip + compare, worker, avg | 1.4 ms | 5.4 ms | 2.0 ms | 4.4 ms | 2.1 ms | 5.8 ms |
| `/mouse` round trip, median / p99 / max | 0.31 / 0.55 / 0.88 ms | 0.28 / 1.9 / 5.4 ms | 0.78 / 2.9 / 3.5 ms | 0.75 / 1.3 / 2.2 ms | 0.80 / 1.4 / 2.1 ms | 0.66 / 6.7 / 7.7 ms |
| mouse op on the main thread: wait max / run max | 0.05 / 0.11 ms | 4.0 / 0.18 ms | 0.9 / 2.0 ms | 0.07 / 1.4 ms | 0.07 / 1.6 ms | 0.2 / 6.8 ms |
| `/frames` reader (Python) | 56 fps, 5 skipped | 25 fps, 124 skipped (reader-bound) | 60 fps, 0 skipped | 29 fps, 0 skipped | 60 fps, 0 skipped | 57 fps, 0 skipped |
| host CPU | 269% | 275% | 209% | 247% | 901% (llvmpipe 714%) | 1669% (llvmpipe 1432%) |

On Linux the readback time is the render thread blocked in `glReadPixels`,
which first waits for the GPU to finish drawing the frame: alone,
`glReadPixels` of these targets takes 1.0 ms (1x) and 3.8 ms (2x) on the
NVIDIA card. At 2x the NVIDIA render thread is busy the whole time and the
rate varied from 30 to 60 frames a second between runs. Ghostty's IO
threads (`io-gather` about 95%, `io-reader` about 30%) parse the output; the
host's own threads used about 25%.

Mouse moves take Ghostty's terminal lock, which its IO thread holds while it
parses output, so under yes a move can wait a few milliseconds on Linux
(run max above). On macOS the main thread copies each frame, and at 2x a
move can wait behind a copy.

`/frames?format=raw&fps=60` into ffmpeg (libx264 veryfast) for 240 frames
while yes scrolls: 60.0 fps in 4.00 s with 233 (NVIDIA) and 236 (Mesa)
distinct frames, gaps p99 20-22 ms, the longest at ffmpeg's start; ffprobe
reads 240 frames at 60/1. On the M3 the same pipeline managed 56 fps,
bound by the encoder and reader alongside yes.

Mesa with fewer cores (`taskset`, 1x): 4 cores drew 52 and published 45
frames a second at 311% CPU; 8 cores drew 60 at 403%.

Without pacing (`--config window-vsync=false` on macOS, or vsync with no
display before the pacer), the same run drew about 2,500 frames/s, used 415%
CPU, and main-thread round trips took 1.4 s (max 2.8 s): every present queues
a block on the main thread.

## Risks and gaps

- `ghostty.h` is internal and macOS-app-shaped; any release can change it,
  and the patch has to be carried forward. The macOS host also relies on
  internals the header doesn't promise: the `IOSurfaceLayer` class name and
  that frames arrive through `-setContents:` (`IOSurfaceLayer.zig`), the
  `initial_size` math in `Surface.recomputeInitialSize`, Exec.zig's
  no-user-name fallback, and the exact set of `CVDisplayLink*` calls in
  `pkg/macos/video`. A change to any of these breaks the host quietly, not at
  link time, so `tools/prove.py` is the regression check.
- macOS: Ghostty releases a swap-chain buffer when the GPU finishes, before
  the main thread runs `-setContents:`. If the main thread stalls for two
  frame intervals (33 ms at 60 fps), the renderer can redraw into the surface
  being copied. Pacing keeps that unlikely; unpaced it was likely.
- Linux: the readback is synchronous on Ghostty's render thread. Large frames
  on a GPU cap the frame rate (30-60 fps at 3130x2062 on the NVIDIA card);
  reading back through pixel buffer objects a frame later would take that off
  the render thread, at the cost of a frame of latency and a larger patch.
- Linux: the latest-frame slot keeps only the newest frame, so if the main
  thread falls behind, frames are replaced before the host sees them and
  aren't counted as drawn.
- Linux: the first frame can race the presentation-health report and come
  out as a DMABUF; the host drops it, and later frames are in memory.
- Linux: llvmpipe uses a thread per core (up to 32 here) and most of the CPU;
  `LP_NUM_THREADS` limits it.
- Hiding the passwd user name on macOS affects every Ghostty lookup of it,
  not only Exec's; today Exec is the only user on macOS.
- Padding in `/status` comes from `--config window-padding-x/y` (default 2
  points per side); with a config file setting it, the host splits the
  total padding evenly.
- Links highlight and turn the pointer only with ctrl (Linux) or command
  (macOS) held, as in Ghostty; hold it with `/key` `press`, since `mods` on
  each `/mouse` event releases it again after the event.
