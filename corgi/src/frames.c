// Frames: the main thread puts each presented frame in a slot (a copy of an
// IOSurface on macOS, Ghostty's own readback buffer on Linux); a worker
// converts it to top-first RGBA and publishes it only if its pixels changed
// (Ghostty redraws an idle screen on its 600 ms cursor timer).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "host.h"
#include "image.h"

#define NSLOTS 4  // copies waiting for the worker
#define SUB_QUEUE 8  // frames queued per /frames reader before it skips
#define POOL 6  // released frame buffers kept for reuse

typedef struct {
  uint8_t *copy;  // owned copy, for frames without release
  size_t cap;
  const uint8_t *pixels;
  size_t stride;
  bool bgra, bottom_up;
  void (*release)(void *ctx);
  void *release_ctx;
  uint32_t width, height;
  uint64_t seq, time_unix_ns, time_mono_ns, gpu_readback_ns;
} slot;

typedef struct {
  uint64_t count, sum_ns, max_ns, last_ns;
} timing;

struct subscriber {
  frame *queue[SUB_QUEUE];
  int n;
  uint32_t skipped;
  subscriber *next;
};

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queued = PTHREAD_COND_INITIALIZER;
static pthread_cond_t published = PTHREAD_COND_INITIALIZER;
static slot slots[NSLOTS];
static int free_slots[NSLOTS], n_free;
static int queue[NSLOTS], n_queued;
static uint64_t drawn_seq;
static frame *latest;
static uint64_t last_publish_mono;
static subscriber *subs;
static char colorspace[64];
static struct {
  uint64_t drawn, published, identical, overrun;
} counts;
static timing t_tap, t_convert, t_readback, t_gpu_readback;

static pthread_mutex_t pool_mu = PTHREAD_MUTEX_INITIALIZER;
static frame *pool[POOL];
static int n_pool;

static void timing_add(timing *t, uint64_t ns) {
  t->count++;
  t->sum_ns += ns;
  t->last_ns = ns;
  if (ns > t->max_ns) t->max_ns = ns;
}

static frame *frame_alloc(uint32_t width, uint32_t height) {
  size_t need = (size_t)width * height * 4;
  frame *f = NULL;
  pthread_mutex_lock(&pool_mu);
  if (n_pool) f = pool[--n_pool];
  pthread_mutex_unlock(&pool_mu);
  if (!f) f = calloc(1, sizeof *f);
  if (f->cap < need) {
    free(f->rgba);
    f->rgba = malloc(need);
    f->cap = need;
  }
  atomic_store(&f->refs, 1);
  f->width = width;
  f->height = height;
  return f;
}

void frame_release(frame *f) {
  if (!f || atomic_fetch_sub(&f->refs, 1) != 1) return;
  pthread_mutex_lock(&pool_mu);
  if (n_pool < POOL) {
    pool[n_pool++] = f;
    f = NULL;
  }
  pthread_mutex_unlock(&pool_mu);
  if (f) {
    free(f->rgba);
    free(f);
  }
}

static frame *frame_ref(frame *f) {
  if (f) atomic_fetch_add(&f->refs, 1);
  return f;
}

static void slot_release(slot *sl) {
  if (sl->release) sl->release(sl->release_ctx);
  sl->release = NULL;
}

void frames_on_present(const host_frame *f) {
  uint64_t start = mono_ns();
  pthread_mutex_lock(&mu);
  int s;
  if (n_free) {
    s = free_slots[--n_free];
  } else {
    // The worker is behind: replace the newest waiting frame.
    s = queue[--n_queued];
    slot_release(&slots[s]);
    counts.overrun++;
  }
  uint64_t seq = ++drawn_seq;
  counts.drawn++;
  if (f->colorspace) snprintf(colorspace, sizeof colorspace, "%s", f->colorspace);
  pthread_mutex_unlock(&mu);

  slot *sl = &slots[s];
  if (f->release) {
    sl->pixels = f->pixels;
    sl->stride = f->stride;
  } else {
    size_t row = (size_t)f->width * 4, need = row * f->height;
    if (sl->cap < need) {
      free(sl->copy);
      sl->copy = malloc(need);
      sl->cap = need;
    }
    for (uint32_t y = 0; y < f->height; y++) memcpy(sl->copy + y * row, f->pixels + y * f->stride, row);
    sl->pixels = sl->copy;
    sl->stride = row;
  }
  sl->bgra = f->bgra;
  sl->bottom_up = f->bottom_up;
  sl->release = f->release;
  sl->release_ctx = f->release_ctx;
  sl->width = f->width;
  sl->height = f->height;
  sl->seq = seq;
  sl->gpu_readback_ns = f->gpu_readback_ns;
  sl->time_unix_ns = realtime_ns();
  sl->time_mono_ns = mono_ns();

  pthread_mutex_lock(&mu);
  queue[n_queued++] = s;
  timing_add(&t_tap, sl->time_mono_ns - start);
  if (f->gpu_readback_ns) timing_add(&t_gpu_readback, f->gpu_readback_ns);
  pthread_cond_signal(&queued);
  pthread_mutex_unlock(&mu);
}

// Top-first RGBA from a slot.
static void slot_to_rgba(const slot *sl, uint8_t *out) {
  if (sl->bgra) {
    image_bgra_to_rgba(sl->pixels, sl->stride, sl->width, sl->height, opt.convert_p3, out);
    return;
  }
  size_t row = (size_t)sl->width * 4;
  for (uint32_t y = 0; y < sl->height; y++) {
    uint32_t from = sl->bottom_up ? sl->height - 1 - y : y;
    memcpy(out + y * row, sl->pixels + from * sl->stride, row);
  }
}

static void *worker(void *arg) {
  (void)arg;
  for (;;) {
    pthread_mutex_lock(&mu);
    while (!n_queued) pthread_cond_wait(&queued, &mu);
    int s = queue[0];
    memmove(queue, queue + 1, sizeof *queue * (size_t)--n_queued);
    frame *prev = latest;  // only this thread replaces latest
    uint64_t tap_ns = t_tap.last_ns;
    pthread_mutex_unlock(&mu);

    slot *sl = &slots[s];
    uint64_t t0 = mono_ns();
    frame *f = frame_alloc(sl->width, sl->height);
    slot_to_rgba(sl, f->rgba);
    bool same = prev && prev->width == f->width && prev->height == f->height &&
                !memcmp(prev->rgba, f->rgba, (size_t)f->width * f->height * 4);
    uint64_t t1 = mono_ns();
    f->seq = sl->seq;
    f->time_unix_ns = sl->time_unix_ns;
    f->time_mono_ns = sl->time_mono_ns;

    pthread_mutex_lock(&mu);
    slot_release(sl);
    free_slots[n_free++] = s;
    timing_add(&t_convert, t1 - t0);
    timing_add(&t_readback, sl->gpu_readback_ns + tap_ns + (t1 - t0));
    if (same) {
      counts.identical++;
      pthread_mutex_unlock(&mu);
      frame_release(f);
      continue;
    }
    counts.published++;
    latest = f;
    last_publish_mono = f->time_mono_ns;
    for (subscriber *sub = subs; sub; sub = sub->next) {
      if (sub->n == SUB_QUEUE) {
        frame_release(sub->queue[0]);
        memmove(sub->queue, sub->queue + 1, sizeof *sub->queue * (SUB_QUEUE - 1));
        sub->n--;
        sub->skipped++;
      }
      sub->queue[sub->n++] = frame_ref(f);
    }
    pthread_cond_broadcast(&published);
    pthread_mutex_unlock(&mu);
    frame_release(prev);
  }
  return NULL;
}

static void deadline_in(struct timespec *deadline, uint64_t timeout_ms) {
  clock_gettime(CLOCK_REALTIME, deadline);
  uint64_t ns = (uint64_t)deadline->tv_nsec + (timeout_ms % 1000) * 1000000ull;
  deadline->tv_sec += (time_t)(timeout_ms / 1000 + ns / 1000000000ull);
  deadline->tv_nsec = (long)(ns % 1000000000ull);
}

void frames_start(void) {
  for (int i = 0; i < NSLOTS; i++) free_slots[n_free++] = i;
  pthread_t t;
  pthread_create(&t, NULL, worker, NULL);
  pthread_detach(t);
}

uint64_t frames_drawn_seq(void) {
  pthread_mutex_lock(&mu);
  uint64_t seq = drawn_seq;
  pthread_mutex_unlock(&mu);
  return seq;
}

frame *frames_latest(void) {
  pthread_mutex_lock(&mu);
  frame *f = frame_ref(latest);
  pthread_mutex_unlock(&mu);
  return f;
}

bool frames_settle(uint64_t quiet_ms, uint64_t timeout_ms, uint64_t *seq) {
  uint64_t start = mono_ns(), quiet = quiet_ms * 1000000ull, limit = start + timeout_ms * 1000000ull;
  pthread_mutex_lock(&mu);
  for (;;) {
    uint64_t now = mono_ns();
    // Quiet since the later of the last change and the request.
    uint64_t since = last_publish_mono > start ? last_publish_mono : start;
    if (now - since >= quiet || now >= limit) break;
    uint64_t until = since + quiet < limit ? since + quiet : limit;
    struct timespec deadline;
    deadline_in(&deadline, (until - now + 999999) / 1000000);
    pthread_cond_timedwait(&published, &mu, &deadline);
  }
  uint64_t since = last_publish_mono > start ? last_publish_mono : start;
  bool settled = mono_ns() - since >= quiet;
  *seq = latest ? latest->seq : 0;
  pthread_mutex_unlock(&mu);
  return settled;
}

frame *frames_wait(uint64_t after, uint64_t timeout_ms) {
  struct timespec deadline;
  deadline_in(&deadline, timeout_ms);
  pthread_mutex_lock(&mu);
  while (!latest || latest->seq <= after)
    if (pthread_cond_timedwait(&published, &mu, &deadline)) break;
  frame *f = latest && latest->seq > after ? frame_ref(latest) : NULL;
  pthread_mutex_unlock(&mu);
  return f;
}

subscriber *frames_subscribe(bool have_after, uint64_t after) {
  subscriber *s = calloc(1, sizeof *s);
  pthread_mutex_lock(&mu);
  if (latest && (!have_after || latest->seq > after)) s->queue[s->n++] = frame_ref(latest);
  s->next = subs;
  subs = s;
  pthread_mutex_unlock(&mu);
  return s;
}

frame *frames_next(subscriber *s, uint32_t *skipped, uint64_t timeout_ms) {
  struct timespec deadline;
  deadline_in(&deadline, timeout_ms);
  pthread_mutex_lock(&mu);
  while (!s->n)
    if (pthread_cond_timedwait(&published, &mu, &deadline)) break;
  if (!s->n) {
    pthread_mutex_unlock(&mu);
    return NULL;
  }
  frame *f = s->queue[0];
  memmove(s->queue, s->queue + 1, sizeof *s->queue * (size_t)--s->n);
  *skipped = s->skipped;
  s->skipped = 0;
  pthread_mutex_unlock(&mu);
  return f;
}

void frames_unsubscribe(subscriber *s) {
  pthread_mutex_lock(&mu);
  for (subscriber **p = &subs; *p; p = &(*p)->next)
    if (*p == s) {
      *p = s->next;
      break;
    }
  pthread_mutex_unlock(&mu);
  for (int i = 0; i < s->n; i++) frame_release(s->queue[i]);
  free(s);
}

static void timing_json(char *buf, size_t cap, size_t *used, const char *name, const timing *t) {
  *used += (size_t)snprintf(buf + *used, cap - *used,
                            "\"%s\":{\"frames\":%llu,\"last_us\":%llu,\"avg_us\":%llu,\"max_us\":%llu}", name,
                            (unsigned long long)t->count, (unsigned long long)(t->last_ns / 1000),
                            (unsigned long long)(t->count ? t->sum_ns / t->count / 1000 : 0),
                            (unsigned long long)(t->max_ns / 1000));
}

void frames_stats_json(char *buf, size_t cap, size_t *used) {
  pthread_mutex_lock(&mu);
  if (latest)
    *used += (size_t)snprintf(buf + *used, cap - *used,
                              "\"frame\":{\"seq\":%llu,\"width\":%u,\"height\":%u,\"time_unix_ns\":%llu},",
                              (unsigned long long)latest->seq, latest->width, latest->height,
                              (unsigned long long)latest->time_unix_ns);
  else
    *used += (size_t)snprintf(buf + *used, cap - *used, "\"frame\":null,");
  timing_json(buf, cap, used, "readback", &t_readback);
  (*used)--;  // reopen the readback object
  *used += (size_t)snprintf(buf + *used, cap - *used, ",\"unchanged\":%llu}", (unsigned long long)counts.identical);
  *used += (size_t)snprintf(buf + *used, cap - *used,
                            ",\"frames\":{\"drawn\":%llu,\"published\":%llu,\"identical\":%llu,\"overrun\":%llu,"
                            "\"surface_colorspace\":\"%s\",\"pixels\":\"%s\",",
                            (unsigned long long)counts.drawn, (unsigned long long)counts.published,
                            (unsigned long long)counts.identical, (unsigned long long)counts.overrun, colorspace,
                            opt.convert_p3 ? "converted from Display P3 to sRGB" : "unconverted (sRGB values)");
  timing_json(buf, cap, used, "tap", &t_tap);
  *used += (size_t)snprintf(buf + *used, cap - *used, ",");
  timing_json(buf, cap, used, "convert", &t_convert);
  *used += (size_t)snprintf(buf + *used, cap - *used, ",");
  timing_json(buf, cap, used, "gpu_readback", &t_gpu_readback);
  *used += (size_t)snprintf(buf + *used, cap - *used, "}");
  pthread_mutex_unlock(&mu);
}
