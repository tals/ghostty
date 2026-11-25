// Shared state and module interfaces for ghostty-host.
#pragma once
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#define GHOSTTY_STATIC
#include <ghostty.h>

#include "json.h"

// main.c ---------------------------------------------------------------------

typedef struct {
  const char *socket_path;  // --socket, or DIR/ghostty.sock, or a /tmp fallback
  const char *dir;
  int cols, rows;
  double font_size;  // points at 96 dpi, as Ghostty on Linux takes them
  double scale;
  double fps;
  bool convert_p3;  // --color convert (macOS); default passthrough
  bool login;  // --login: keep Ghostty's macOS login(1) wrapper
  const char *cwd;
  const char *config_files[32];
  int n_config_files;
  const char *config_lines[64];
  int n_config_lines;
  char **command;
  int n_command;
} options;

extern options opt;
extern ghostty_app_t app;
extern ghostty_surface_t surface;

// Frame size, padding and grid, fixed at startup.
typedef struct {
  uint32_t width, height;
  uint32_t pad_top, pad_bottom, pad_left, pad_right;
  ghostty_surface_size_s grid;
  char tty[64];
} geometry;
extern geometry geo;
extern atomic_bool tty_known;  // geo.tty is set

#ifdef __APPLE__
#define HOST_MONO_CLOCK CLOCK_UPTIME_RAW
#else
#define HOST_MONO_CLOCK CLOCK_MONOTONIC
#endif

static inline uint64_t clock_ns(clockid_t clock) {
  struct timespec t;
  clock_gettime(clock, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static inline uint64_t realtime_ns(void) { return clock_ns(CLOCK_REALTIME); }
static inline uint64_t mono_ns(void) { return clock_ns(HOST_MONO_CLOCK); }

// The pointer shape Ghostty last asked for, with a history of changes.
// shape_json waits up to timeout_ms for a change after `after`.
void shape_json(char *buf, size_t cap, bool have_after, uint64_t after, uint64_t timeout_ms);
void shape_brief_json(char *buf, size_t cap, size_t *used);
const char *shape_name(int shape);

// platform_macos.m, platform_linux.c ------------------------------------------
// The main thread's loop, the surface's platform and how frames come out.

void platform_init(void);  // before ghostty_init
void platform_run(void);  // the main loop, until platform_stop
void platform_stop(void);  // any thread
void platform_async(void (*fn)(void *), void *ctx);  // runs fn on the main thread soon; any thread
void platform_sync(void (*fn)(void *), void *ctx);  // runs fn on the main thread and waits; not on it
// Fills in the surface config's platform before ghostty_surface_new.
void platform_surface_config(ghostty_surface_config_s *sc);
// Called once the frame size is known, before frames are wanted.
bool platform_surface_ready(uint32_t width, uint32_t height, char *err, size_t err_len);
// GHOSTTY_ACTION_RENDER: a frame is waiting. Main thread.
void platform_on_render(void);
// Windows the window server knows for pid, as JSON objects joined by commas.
void platform_windows_json(int pid, char *out, size_t out_len);

// frames.c -------------------------------------------------------------------

// A frame Ghostty presented, as the platform layer hands it over on the
// main thread.
typedef struct {
  const uint8_t *pixels;
  size_t stride;
  uint32_t width, height;
  bool bgra;  // else RGBA
  bool bottom_up;  // rows bottom first
  uint64_t gpu_readback_ns;  // time Ghostty spent reading it back, 0 if unknown
  const char *colorspace;
  // With release, the pixels stay valid until the worker calls
  // release(release_ctx), so nothing is copied on the main thread. Without,
  // they are copied during the call.
  void (*release)(void *ctx);
  void *release_ctx;
} host_frame;

// A published frame: premultiplied RGBA, immutable, reference counted.
typedef struct frame {
  atomic_int refs;
  uint8_t *rgba;
  size_t cap;
  uint32_t width, height;
  uint64_t seq, time_unix_ns, time_mono_ns;
} frame;

typedef struct subscriber subscriber;

void frames_start(void);
void frames_on_present(const host_frame *f);  // main thread
uint64_t frames_drawn_seq(void);  // seq of the last frame Ghostty presented
frame *frames_latest(void);  // referenced, or NULL before the first frame
frame *frames_wait(uint64_t after, uint64_t timeout_ms);  // referenced, NULL on timeout
void frame_release(frame *f);
subscriber *frames_subscribe(bool have_after, uint64_t after);
frame *frames_next(subscriber *s, uint32_t *skipped, uint64_t timeout_ms);  // referenced, or NULL
void frames_unsubscribe(subscriber *s);
void frames_stats_json(char *buf, size_t cap, size_t *used);
// Waits until no frame has been published for quiet_ms; false at timeout_ms.
bool frames_settle(uint64_t quiet_ms, uint64_t timeout_ms, uint64_t *seq);

// input.c --------------------------------------------------------------------
// Each op runs on the main thread (platform_sync) and writes a JSON reply.

typedef struct {
  const jval *body;
  int status;
  char *out;
  size_t cap;
} op;

void op_key(void *o);
void op_type(void *o);
void op_mouse(void *o);
void op_focus(void *o);
void op_action(void *o);
void op_quit(void *o);

// Focus and held modifiers, readable from any thread.
void input_state_json(char *buf, size_t cap, size_t *used);

// http.c ---------------------------------------------------------------------

void http_start(const char *socket_path);
