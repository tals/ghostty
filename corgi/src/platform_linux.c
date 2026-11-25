// Linux side of ghostty-host: a main loop of queued calls, and the headless
// surface (a libghostty patch, see patches/) that Ghostty's OpenGL renderer
// draws into its own targets on a surfaceless EGL display. Each frame comes
// back in CPU memory, bottom row first, through ghostty_surface_take_frame
// when Ghostty sends the render action. Ghostty paces the drawing at --fps,
// since nothing like a display link does it here.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "host.h"

// --- Main loop --------------------------------------------------------------------
//
// The main thread runs queued calls in order: ticks from Ghostty's wakeups
// and input ops from HTTP threads, which wait for theirs.

typedef struct call {
  void (*fn)(void *);
  void *ctx;
  bool sync, done;
  struct call *next;
} call;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;  // the main thread waits for calls
static pthread_cond_t ran = PTHREAD_COND_INITIALIZER;  // sync callers wait for theirs
static call *head, *tail;
static bool stopping;

void platform_init(void) {}

static void enqueue(call *c) {
  pthread_mutex_lock(&mu);
  if (tail) tail->next = c;
  else head = c;
  tail = c;
  pthread_cond_signal(&wake);
  pthread_mutex_unlock(&mu);
}

void platform_async(void (*fn)(void *), void *ctx) {
  call *c = calloc(1, sizeof *c);
  c->fn = fn;
  c->ctx = ctx;
  enqueue(c);
}

void platform_sync(void (*fn)(void *), void *ctx) {
  call c = {.fn = fn, .ctx = ctx, .sync = true};
  enqueue(&c);
  pthread_mutex_lock(&mu);
  while (!c.done) pthread_cond_wait(&ran, &mu);
  pthread_mutex_unlock(&mu);
}

void platform_run(void) {
  pthread_mutex_lock(&mu);
  while (!stopping) {
    if (!head) {
      pthread_cond_wait(&wake, &mu);
      continue;
    }
    call *c = head;
    head = c->next;
    if (!head) tail = NULL;
    pthread_mutex_unlock(&mu);
    c->fn(c->ctx);
    pthread_mutex_lock(&mu);
    if (c->sync) {
      c->done = true;
      pthread_cond_broadcast(&ran);
    } else {
      free(c);
    }
  }
  pthread_mutex_unlock(&mu);
}

// Calls still queued are dropped; sync callers stay blocked until exit.
void platform_stop(void) {
  pthread_mutex_lock(&mu);
  stopping = true;
  pthread_cond_signal(&wake);
  pthread_mutex_unlock(&mu);
}

// --- Surface ----------------------------------------------------------------------

void platform_surface_config(ghostty_surface_config_s *sc) {
  sc->platform_tag = GHOSTTY_PLATFORM_HEADLESS;
  sc->platform.headless.max_fps = opt.fps;
}

bool platform_surface_ready(uint32_t width, uint32_t height, char *err, size_t err_len) {
  (void)width, (void)height, (void)err, (void)err_len;
  return true;
}

static void release_frame(void *ctx) {
  ghostty_frame_s *f = ctx;
  ghostty_frame_free(f);
  free(f);
}

// The worker flips the rows while it copies the frame, then frees it.
void platform_on_render(void) {
  ghostty_frame_s *f = malloc(sizeof *f);
  if (!ghostty_surface_take_frame(surface, f)) {
    free(f);
    return;
  }
  host_frame frame = {
      .pixels = f->pixels,
      .stride = f->stride,
      .width = f->width,
      .height = f->height,
      .bottom_up = true,
      .gpu_readback_ns = f->readback_ns,
      .colorspace = "sRGB",
      .release = release_frame,
      .release_ctx = f,
  };
  frames_on_present(&frame);
}

// No window server: nothing to list.
void platform_windows_json(int pid, char *out, size_t out_len) {
  (void)pid;
  if (out_len) out[0] = 0;
}
