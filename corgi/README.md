# ghostty-host

A windowless Ghostty v1.4.0, on macOS and Linux. It runs a command in a
Ghostty surface that has no window, takes scripted keys and mouse input,
reports the pointer shape, and hands out every changed frame Ghostty's
renderer draws, from memory over HTTP on a Unix socket. On macOS that is the
Metal renderer with no view or window; on Linux, the OpenGL renderer on a
surfaceless EGL display, with no X server, Wayland compositor or GPU
required.

Corgi's capture tool (`tools/ghostty_screenshot.ts`) runs its terminals in
it. It is Ghostty's own `headless` apprt (`src/apprt/headless`), built from
this fork with `-Dapp-runtime=headless` the way the GTK app is built with
`gtk`, so it uses Ghostty's internals directly rather than the embedding API
(see The Ghostty patch).

## Build

`corgi/build.ts` runs `zig build -Dapp-runtime=headless` for each target and
packs the `ghostty-host` it installs with Ghostty's resources and license
into `corgi/out/ghostty-host-VERSION-TARGET.tar.gz`. It needs Bun and Zig
0.17.0 (`$ZIG` or `zig` on PATH):

```sh
bun corgi/build.ts                  # every target this machine builds
bun corgi/build.ts linux-x86_64     # one: macos-aarch64, linux-x86_64 or linux-aarch64
```

macOS arm64 builds on a Mac, with Xcode for the Metal shaders.

Linux x86_64 and arm64 cross-compile on any machine with Zig, against glibc
2.28. A package holds `ghostty-host` and `share/`; Ghostty's dependencies are
linked in. It links against a stand-in `libEGL.so.1`
(`src/apprt/headless/egl_stub.c`), so that it links on any OS and the
machine's own libEGL (from libglvnd, with Mesa or NVIDIA behind it) loads at
run time.

A debug build for trying a change: `zig build -Dapp-runtime=headless`, then
`zig-out/bin/ghostty-host`.

The host finds Ghostty's resources in `share/ghostty` beside it.

### Releasing

Corgi pins a version in its `scripts/ghostty-host`, which downloads the build
from `https://corgi.computer/ghostty-host/VERSION/` on first use. Versions
follow Corgi's releases: the UTC datetime of the publish and the commit's first
12 hex digits, such as `20261126T031500Z-638b2c112abc`. To release, commit on
the `corgi` branch, push it, and on a Mac run

```sh
bun corgi/build.ts --publish
```

It builds every target, uploads the archives and `SHA256SUMS` to
`ghostty-host/VERSION/` in Corgi's release bucket (the config and credentials
`bun run publish` uses), refuses to replace a published file with other
bytes, and checks each through the public URL; `--upload` resumes an
interrupted upload. Then, in Corgi, run the command it prints,
`bun scripts/pin_ghostty_host.ts VERSION`, and commit the change to
`scripts/ghostty-host`.

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
| `GET /status` | pid, focus, held modifiers, size (width, height, scale, cell size, columns, rows, padding), latest frame, shape, readback cost, frame counts (`drawn`, `published`, `identical`, `overrun`) and timings (`tap`, the hand-off copy; `convert`; `gpu_readback`), input timings (`input_us`), tty, and the window server's windows for this pid (always `[]`) |
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
| `POST /toast` | `{"text":"Opened","strong":"corgi.computer/docs","x":520,"y":546,"ms":2500}` shows a blue pill with rounded ends and `text`, then `strong` in bold, for `ms` (default 2500), shortened with "…" to fit. It sits on the row above frame pixel `x`,`y` (below it on the top row), or at the bottom right without one, and grows in and out. Corgi's captures show what a click opened this way. |
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

`src/apprt/headless.zig` is the apprt: the `App` and `Surface` Ghostty's core
calls, the actions it handles, and the frames the renderer hands it. The host
around it is in `src/apprt/headless/`: `main.zig` (options, config, startup
and geometry), `loop.zig` (the main thread), `frames.zig` (the frame worker
and subscribers), `http.zig`, `input.zig`, `shape.zig` (pointer shape
history), `image.zig` (color conversion and PNG) and `clock.zig`.
`platform_macos.m` holds the few Objective-C and Core Foundation calls
(App Nap, a surface's color space name, the window list).

## The Ghostty patch

The host's own code is all new files. Ghostty's files change in a few
places, each a hook for the `headless` runtime:

- `apprt/runtime.zig`, `apprt.zig`: the `headless` runtime and its apprt.
  `config/Config.zig` lists it among the runtimes with no apprt defaults.
- `main_ghostty.zig`: the `headless` executable runs the host's `main`,
  which takes its own options rather than Ghostty's CLI.
- `global.zig`: like the library, it logs to stderr only with `GHOSTTY_LOG`.
- `build/GhosttyExe.zig`, `build/SharedDeps.zig`: the executable is named
  `ghostty-host`; on macOS it links Metal and compiles `platform_macos.m`,
  on Linux it compiles glad's EGL loader and links the stand-in libEGL.
- `renderer/Metal.zig`: with the headless apprt there is no view. The
  renderer takes its size from the surface and hands each finished frame's
  IOSurface to it in `present`, on Metal's completion handler.
- `termio/Exec.zig`: the apprt may supply the passwd lookup for the macOS
  `login(1)` wrapper; the host's has no user name unless `--login`.
- `renderer/Thread.zig`: pacing for a surface with no display link (below).
- `renderer/OpenGL.zig`: the time each CPU readback takes.
- `build.zig`, `build/SharedDeps.zig`: Linux installs Ghostty's resources,
  and the OpenGL bindings build for the target, so Linux cross-compiles.

Pacing: the surface asks for a frame interval (`--fps`). A wakeup renders at
once if an interval has passed since the last paced frame, else arms a timer
for when it has; wakeups in between coalesce into that frame. A steady
stream of wakeups keeps the cadence; after a quiet spell the next frame
draws at once. The host turns vsync off, so both platforms pace this way
with or without a display.

## How it works on macOS

- **Surface.** The surface has no view. Its size comes from the
  `initial_size` action Ghostty sends for `window-width`/`window-height`, so
  the grid is exact, and the Metal renderer draws into its IOSurface targets
  at that size. Nothing occludes it, so it stays visible.
- **Frames.** Metal's completion handler hands the finished IOSurface to the
  host, which locks it read-only, copies it and returns, before the renderer
  can reuse it. No frame goes through Core Animation or the main thread. A
  worker converts BGRA to RGBA, compares with the previous frame, and
  publishes it only if the pixels changed. An idle screen still redraws on
  Ghostty's 600 ms cursor timer; those frames are counted as `identical` and
  not published.
- **Off screen.** There is no `NSApplication`, view or window;
  `CGWindowListCopyWindowInfo` lists none for the process. An `NSProcessInfo`
  activity keeps App Nap away, and the main thread and request threads run
  at the user-interactive QoS a window's main thread gets.
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
  has no user name, and the host's apprt hands Exec one without, unless
  `--login`. Ghostty then runs `/bin/sh -c "exec CMD"`, and CMD's parent is
  the host.

## How it works on Linux

- **Surface.** Ghostty opens a surfaceless EGL display; libglvnd picks the
  first vendor that supports it (NVIDIA when its driver is installed, else
  Mesa, which falls back to llvmpipe when it can't open `/dev/dri`). Set
  `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json`
  to force Mesa. No `DISPLAY` or `WAYLAND_DISPLAY` is needed, and the host
  opens no X or Wayland socket.
- **Frames.** The surface reports presentation as unhealthy, so the OpenGL
  renderer reads each frame back into CPU memory instead of exporting a
  DMABUF. On the render action the main thread takes the frame and lends
  Ghostty's buffer to the worker, copying nothing; the worker flips the rows
  to top first while it copies, compares, publishes, and frees the buffer.
  Ghostty renders into an sRGB target and reads it back unchanged, so pixels
  are the configured colors.
- **Command.** Ghostty on Linux runs `/bin/sh -c "exec CMD"` itself, with
  no login wrapper.

On both, one main thread runs queued calls in order: ticks from Ghostty's
wakeups, and input ops from HTTP threads, which wait for theirs. Keys go to
Ghostty as its own key events, from its table of W3C codes. Inherited
`GHOSTTY_*` variables are removed (a parent Ghostty's
`GHOSTTY_RESOURCES_DIR` points into its own resources) before Ghostty reads
the environment, and `GHOSTTY_RESOURCES_DIR` points at `share/ghostty` beside
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

2026-11-25, from `tools/prove.py`, against the C host this replaced (built
on the C embedding API with an `NSView` on macOS). "yes" is `yes` with a
70-character line scrolling 120x36 at `--font-size 16`, with a `/frames`
reader attached and 60 `/mouse` moves a second from another process.
Medians of 3 runs (macOS) and 2 runs (Linux) of the new host, against 4 of
the old.

Machines: Apple M3, macOS 15.8. nocap: Ubuntu 24.04, AMD EPYC 7C13 (256
threads), NVIDIA RTX 6000 Ada, no `DISPLAY` or `WAYLAND_DISPLAY`. Mesa's
llvmpipe was not measured again.

The same on both, as before:

- Idle for 3 s: 5 frames drawn (cursor timer), 0 published.
- Pointer shape: `text` at start, `default` with `?1003h`, `text` after
  `?1003l`, `pointer` after `OSC 22;pointer`, `text` after `OSC 22;`.
- Colors: red `(255,0,0)`, green `(0,255,0)`, blue `(0,0,255)`, background
  `(40,44,52)`. macOS `--color convert`: green `(3,255,0)`.
- Keys, as the program's raw tty reads them: 23 of 23 exact, including
  `ctrl+a`, `ctrl+alt+a`, `alt+x`, F1, F5, F12, `shift+F5`, `ctrl+F12`,
  `ctrl+Left`, `shift+Tab`, `é` typed and as key text.
- Mouse reports: 9 of 9 SGR sequences at the cells under the pixels sent.
- A command exiting with 7: the host exits 7 and leaves no socket.
- A frame of the same screen matches the old host's to within one pixel's
  anti-aliasing.
- No window: `CGWindowListCopyWindowInfo` lists none for the host.

| new (old) | macOS | Linux NVIDIA |
| --- | --- | --- |
| `/mouse` round trip, idle, median | 0.42 ms (0.32) | 0.94 ms (0.84) |
| link highlight frame after the move | 1.6 ms (2.2) | 4.7 ms (4.9) |
| yes 1x: drawn / published per s | 60 / 57 (60 / 58) | 60 / 60 (60 / 60) |
| yes 1x: hand-off copy, avg | 0.42 ms on Metal's thread (0.40 on the main thread) | none (none) |
| yes 1x: convert or flip + compare, worker, avg | 1.2 ms (1.2) | 3.5 ms (2.3) |
| yes 1x: `/mouse` median / p99 | 0.32 / 0.84 ms (0.34 / 1.66) | 0.78 / 3.2 ms (0.76 / 1.7) |
| yes 1x: `/frames` reader (Python) | 57 fps (50) | 59 fps (60) |
| yes 1x: host CPU | 171% (238%) | 226% (206%) |
| yes 2x: drawn per s | 60 (60) | 30-60 (30-60) |
| yes 2x: `/mouse` max | 0.9 ms (2.6) | 3.7 ms (14.6) |
| yes 2x: host CPU | 193% (272%) | 240% (275%) |

On macOS frames no longer pass through Core Animation and the main thread,
which is where the CPU went: about 70 points less with yes scrolling. On
Linux the worker's compare is slower: Zig 0.16 and later compile it for the
release's baseline CPU without loop vectorization, and their scalar `memcmp`
takes the place of glibc's, so the host compares with `std.mem.eql`'s SSE2
vectors, row by row while each row is in cache. At 2x the NVIDIA render
thread is busy the whole time, and the rate varied from 30 to 60 frames a
second between runs on both hosts.

Before pacing, with vsync off or with no display, the renderer drew about
2,500 frames/s at 415% CPU on macOS.

## Risks and gaps

- The host is built against Ghostty's internals: the apprt interface its
  core calls (`App`, `Surface`, `performAction`), `Surface` fields such as
  `size`, `core_surface.keyCallback` and the other input entry points, the
  renderer's `takeFrame`, `input.keycodes`, and `Config`. A Ghostty update
  that changes them breaks the build, which is where it should break; the
  `initial_size` math in `Surface.recomputeInitialSize` is the one internal
  that would change quietly, so `tools/prove.py` stays the regression check.
- Linux: the readback is synchronous on Ghostty's render thread. Large frames
  on a GPU cap the frame rate (30-60 fps at 3130x2062 on the NVIDIA card);
  reading back through pixel buffer objects a frame later would take that off
  the render thread, at the cost of a frame of latency and a larger patch.
- Linux: the latest-frame slot keeps only the newest frame, so if the main
  thread falls behind, frames are replaced before the host sees them and
  aren't counted as drawn.
- Linux: llvmpipe uses a thread per core (up to 32 here) and most of the CPU;
  `LP_NUM_THREADS` limits it.
- macOS: the frame copy runs on Metal's completion handler, so a slow copy
  (a 2x frame, about 0.8 ms) delays that frame's completion; the renderer
  draws the next one into another of its three targets meanwhile.
- No clipboard: reads find nothing, and writes, including Kitty clipboard
  writes, are refused.
- Padding in `/status` comes from `--config window-padding-x/y` (default 2
  points per side); with a config file setting it, the host splits the
  total padding evenly.
- Links highlight and turn the pointer only with ctrl (Linux) or command
  (macOS) held, as in Ghostty; hold it with `/key` `press`, since `mods` on
  each `/mouse` event releases it again after the event.
