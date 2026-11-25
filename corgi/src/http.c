// HTTP/1.1 over a Unix socket, one thread per connection.
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>

#include "host.h"
#include "image.h"

static bool send_all(int fd, const void *buf, size_t len) {
  const char *p = buf;
  while (len) {
    ssize_t n = write(fd, p, len);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    p += n;
    len -= (size_t)n;
  }
  return true;
}

static bool send_iov(int fd, struct iovec *iov, int n) {
  while (n) {
    ssize_t w = writev(fd, iov, n);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) return false;
    while (n && (size_t)w >= iov->iov_len) {
      w -= (ssize_t)iov->iov_len;
      iov++;
      n--;
    }
    if (n) {
      iov->iov_base = (char *)iov->iov_base + w;
      iov->iov_len -= (size_t)w;
    }
  }
  return true;
}

static const char *reason(int status) {
  switch (status) {
    case 200: return "OK";
    case 404: return "Not Found";
    case 405: return "Method Not Allowed";
    case 503: return "Service Unavailable";
    case 504: return "Gateway Timeout";
    default: return "Bad Request";
  }
}

static void respond(int fd, int status, const char *type, const void *body, size_t len, const char *extra) {
  char head[1024];
  int n = snprintf(head, sizeof head,
                   "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n%s\r\n",
                   status, reason(status), type, len, extra ? extra : "");
  struct iovec iov[2] = {{head, (size_t)n}, {(void *)body, len}};
  send_iov(fd, iov, 2);
}

static void respond_json(int fd, int status, const char *json) {
  respond(fd, status, "application/json", json, strlen(json), NULL);
}

static void respond_error(int fd, int status, const char *msg) {
  char buf[512];
  size_t used = (size_t)snprintf(buf, sizeof buf, "{\"ok\":false,\"error\":");
  json_escape(buf, sizeof buf, &used, msg);
  snprintf(buf + used, sizeof buf - used, "}");
  respond_json(fd, status, buf);
}

static bool query_param(const char *query, const char *key, char *out, size_t cap) {
  size_t klen = strlen(key);
  for (const char *p = query; p && *p;) {
    if (!strncmp(p, key, klen) && p[klen] == '=') {
      const char *v = p + klen + 1;
      size_t n = strcspn(v, "&");
      snprintf(out, cap, "%.*s", (int)(n < cap ? n : cap - 1), v);
      return true;
    }
    p = strchr(p, '&');
    if (p) p++;
  }
  return false;
}

static bool query_u64(const char *query, const char *key, uint64_t *out) {
  char buf[32];
  if (!query_param(query, key, buf, sizeof buf)) return false;
  *out = strtoull(buf, NULL, 10);
  return true;
}

// --- Input timing ------------------------------------------------------------
// How long input ops wait for the main thread, and how long they take on it.

typedef struct {
  uint64_t ops, wait_sum, wait_max, run_sum, run_max;
} op_timing;

static pthread_mutex_t op_mu = PTHREAD_MUTEX_INITIALIZER;
static op_timing t_mouse, t_other;

typedef struct {
  void (*fn)(void *);
  op *o;
  uint64_t started, done;
} timed_op;

static void run_timed(void *ctx) {
  timed_op *t = ctx;
  t->started = mono_ns();
  t->fn(t->o);
  t->done = mono_ns();
}

static void run_op(void (*fn)(void *), op *o) {
  timed_op t = {.fn = fn, .o = o};
  uint64_t queued = mono_ns();
  platform_sync(run_timed, &t);
  uint64_t wait = t.started - queued, run = t.done - t.started;
  pthread_mutex_lock(&op_mu);
  op_timing *s = fn == op_mouse ? &t_mouse : &t_other;
  s->ops++;
  s->wait_sum += wait;
  s->run_sum += run;
  if (wait > s->wait_max) s->wait_max = wait;
  if (run > s->run_max) s->run_max = run;
  pthread_mutex_unlock(&op_mu);
}

static void op_timing_json(char *buf, size_t cap, size_t *used, const char *name, const op_timing *t) {
  uint64_t n = t->ops ? t->ops : 1;
  *used += (size_t)snprintf(buf + *used, cap - *used,
                            "\"%s\":{\"ops\":%llu,\"wait_avg\":%llu,\"wait_max\":%llu,\"run_avg\":%llu,\"run_max\":%llu}",
                            name, (unsigned long long)t->ops, (unsigned long long)(t->wait_sum / n / 1000),
                            (unsigned long long)(t->wait_max / 1000), (unsigned long long)(t->run_sum / n / 1000),
                            (unsigned long long)(t->run_max / 1000));
}

// --- GET -----------------------------------------------------------------------

// Answers without the main thread, which may be busy presenting frames.
static void handle_status(int fd) {
  char windows[2048];
  platform_windows_json(getpid(), windows, sizeof windows);
  char buf[8192];
  size_t used = (size_t)snprintf(buf, sizeof buf, "{\"pid\":%d,\"surface\":true,", getpid());
  input_state_json(buf, sizeof buf, &used);
  used += (size_t)snprintf(
      buf + used, sizeof buf - used,
      ",\"real_input\":false,"
      "\"size\":{\"width\":%u,\"height\":%u,\"scale\":%g,\"cell_width\":%u,\"cell_height\":%u,"
      "\"columns\":%u,\"rows\":%u,\"padding\":{\"top\":%u,\"bottom\":%u,\"left\":%u,\"right\":%u}},",
      geo.width, geo.height, opt.scale, geo.grid.cell_width_px, geo.grid.cell_height_px, geo.grid.columns,
      geo.grid.rows, geo.pad_top, geo.pad_bottom, geo.pad_left, geo.pad_right);
  frames_stats_json(buf, sizeof buf, &used);
  used += (size_t)snprintf(buf + used, sizeof buf - used, ",\"shape\":");
  shape_brief_json(buf, sizeof buf, &used);
  used += (size_t)snprintf(buf + used, sizeof buf - used, ",\"input_us\":{");
  pthread_mutex_lock(&op_mu);
  op_timing_json(buf, sizeof buf, &used, "mouse", &t_mouse);
  used += (size_t)snprintf(buf + used, sizeof buf - used, ",");
  op_timing_json(buf, sizeof buf, &used, "other", &t_other);
  pthread_mutex_unlock(&op_mu);
  used += (size_t)snprintf(buf + used, sizeof buf - used, "},\"tty\":\"%s\",\"windows\":[%s]}",
                           atomic_load_explicit(&tty_known, memory_order_acquire) ? geo.tty : "", windows);
  respond_json(fd, 200, buf);
}

static void frame_headers(char *extra, size_t cap, const frame *f) {
  snprintf(extra, cap,
           "x-frame-seq: %llu\r\nx-frame-width: %u\r\nx-frame-height: %u\r\nx-frame-stride: %u\r\n"
           "x-frame-format: rgba\r\nx-frame-time-unix-ns: %llu\r\nx-frame-time-mono-ns: %llu\r\n",
           (unsigned long long)f->seq, f->width, f->height, f->width * 4, (unsigned long long)f->time_unix_ns,
           (unsigned long long)f->time_mono_ns);
}

static void handle_frame(int fd, const char *query) {
  uint64_t after = 0, timeout_ms = 10000;
  bool have_after = query_u64(query, "after", &after);
  query_u64(query, "timeout_ms", &timeout_ms);
  char format[16] = "rgba";
  query_param(query, "format", format, sizeof format);
  if (strcmp(format, "rgba") && strcmp(format, "png")) return respond_error(fd, 400, "format is rgba or png");

  frame *f = have_after ? frames_wait(after, timeout_ms) : frames_latest();
  if (!f && !have_after) f = frames_wait(0, timeout_ms);
  if (!f) return respond_error(fd, 504, "no frame before the timeout");
  char extra[512];
  frame_headers(extra, sizeof extra, f);
  if (!strcmp(format, "png")) {
    // Encoded in memory, never written to disk.
    size_t len;
    uint8_t *png = image_png(f->rgba, f->width, f->height, 6, &len);
    respond(fd, 200, "image/png", png, len, extra);
    free(png);
  } else {
    respond(fd, 200, "application/octet-stream", f->rgba, (size_t)f->width * f->height * 4, extra);
  }
  frame_release(f);
}

static void put_le32(uint8_t *p, uint32_t v) {
  for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static void put_le64(uint8_t *p, uint64_t v) {
  for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static bool peer_closed(int fd) {
  struct pollfd p = {.fd = fd, .events = POLLIN};
  if (poll(&p, 1, 0) <= 0) return false;
  char c;
  return recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT) == 0 || (p.revents & (POLLHUP | POLLERR));
}

// One chunk: "<hex size>\r\n" header pixels "\r\n".
static bool send_chunk(int fd, const void *head, size_t head_len, const frame *f) {
  size_t pixels = (size_t)f->width * f->height * 4;
  char size[32];
  int n = snprintf(size, sizeof size, "%zx\r\n", head_len + pixels);
  struct iovec iov[4] = {{size, (size_t)n}, {(void *)head, head_len}, {f->rgba, pixels}, {"\r\n", 2}};
  return send_iov(fd, iov, 4);
}

// GET /frames: every published frame, GCF1 header + pixels, as ghostty-capture
// streams them. ?format=raw drops the headers; with &fps=N it repeats the
// latest frame at a constant rate, which ffmpeg's rawvideo input expects.
static void handle_frames(int fd, const char *query) {
  uint64_t after = 0, fps = 0;
  bool have_after = query_u64(query, "after", &after);
  query_u64(query, "fps", &fps);
  char format[16] = "gcf1";
  query_param(query, "format", format, sizeof format);
  bool raw = !strcmp(format, "raw");
  if (!raw && strcmp(format, "gcf1")) return respond_error(fd, 400, "format is gcf1 or raw");
  if (fps && !raw) return respond_error(fd, 400, "fps needs format=raw");
  if (fps > 240) return respond_error(fd, 400, "fps is at most 240");

  frame *first = frames_wait(0, 10000);
  if (!first) return respond_error(fd, 504, "no frame yet");
  char head[512];
  int n = snprintf(head, sizeof head,
                   "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n"
                   "Connection: close\r\nx-frame-format: %s\r\nx-frame-width: %u\r\nx-frame-height: %u\r\n"
                   "x-frame-pixel-format: rgba\r\n\r\n",
                   raw ? "raw" : "gcf1", first->width, first->height);
  frame_release(first);
  if (!send_all(fd, head, (size_t)n)) return;

  if (fps) {
    uint64_t period = 1000000000ull / fps, start = mono_ns();
    for (uint64_t k = 0;; k++) {
      uint64_t due = start + k * period, now = mono_ns();
      if (due > now) {
        struct timespec ts = {(time_t)((due - now) / 1000000000ull), (long)((due - now) % 1000000000ull)};
        nanosleep(&ts, NULL);
      }
      frame *f = frames_latest();
      bool ok = send_chunk(fd, NULL, 0, f);
      frame_release(f);
      if (!ok) break;
    }
  } else {
    subscriber *s = frames_subscribe(have_after, after);
    for (;;) {
      uint32_t skipped = 0;
      frame *f = frames_next(s, &skipped, 1000);
      if (!f) {
        if (peer_closed(fd)) break;
        continue;
      }
      uint8_t gcf[64] = {'G', 'C', 'F', '1'};
      put_le32(gcf + 4, 64);
      put_le32(gcf + 8, f->width);
      put_le32(gcf + 12, f->height);
      put_le32(gcf + 16, f->width * 4);
      put_le32(gcf + 20, 1);  // RGBA8, premultiplied alpha
      put_le64(gcf + 24, f->seq);
      put_le64(gcf + 32, f->time_unix_ns);
      put_le64(gcf + 40, f->time_mono_ns);
      put_le32(gcf + 48, skipped);
      put_le64(gcf + 56, (uint64_t)f->width * f->height * 4);
      bool ok = send_chunk(fd, raw ? NULL : gcf, raw ? 0 : 64, f);
      frame_release(f);
      if (!ok) break;
    }
    frames_unsubscribe(s);
  }
}

// --- Requests -------------------------------------------------------------------

typedef struct {
  const char *path;
  void (*fn)(void *);
} post_route;

static const post_route POSTS[] = {
    {"/key", op_key},     {"/type", op_type},     {"/mouse", op_mouse},
    {"/focus", op_focus}, {"/action", op_action}, {"/quit", op_quit},
};

static void *serve_conn(void *arg) {
  int fd = (int)(intptr_t)arg;
  size_t cap = (1 << 20) - 1, len = 0, content_length = 0;
  char *req = malloc(cap + 1), *body = NULL;
  for (;;) {
    ssize_t n = read(fd, req + len, cap - len);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) goto done;
    len += (size_t)n;
    req[len] = 0;
    char *end = strstr(req, "\r\n\r\n");
    if (!end) {
      if (len == cap) goto done;
      continue;
    }
    body = end + 4;
    char *cl = strcasestr(req, "\r\ncontent-length:");
    content_length = cl && cl < end ? strtoul(cl + 17, NULL, 10) : 0;
    if (content_length > cap - (size_t)(body - req)) {
      respond_error(fd, 400, "body too large");
      goto done;
    }
    while ((size_t)(req + len - body) < content_length) {
      n = read(fd, req + len, cap - len);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) goto done;
      len += (size_t)n;
    }
    body[content_length] = 0;
    break;
  }

  char method[16] = {0}, target[1024] = {0};
  if (sscanf(req, "%15s %1023s", method, target) != 2) {
    respond_error(fd, 400, "bad request line");
    goto done;
  }
  char *query = strchr(target, '?');
  if (query) *query++ = 0;
  bool get = !strcmp(method, "GET"), post = !strcmp(method, "POST");

  const post_route *route = NULL;
  for (size_t i = 0; i < sizeof POSTS / sizeof *POSTS; i++)
    if (!strcmp(target, POSTS[i].path)) route = &POSTS[i];
  bool get_path = !strcmp(target, "/status") || !strcmp(target, "/frame") || !strcmp(target, "/frames") ||
                  !strcmp(target, "/shape") || !strcmp(target, "/settle");

  if (get && !strcmp(target, "/status")) {
    handle_status(fd);
  } else if (get && !strcmp(target, "/frame")) {
    handle_frame(fd, query);
  } else if (get && !strcmp(target, "/frames")) {
    handle_frames(fd, query);
  } else if (get && !strcmp(target, "/settle")) {
    uint64_t quiet_ms = 500, timeout_ms = 10000, seq;
    query_u64(query, "quiet_ms", &quiet_ms);
    query_u64(query, "timeout_ms", &timeout_ms);
    bool settled = frames_settle(quiet_ms, timeout_ms, &seq);
    char buf[128];
    snprintf(buf, sizeof buf, "{\"settled\":%s,\"frame\":%llu}", settled ? "true" : "false",
             (unsigned long long)seq);
    respond_json(fd, 200, buf);
  } else if (get && !strcmp(target, "/shape")) {
    uint64_t after = 0, timeout_ms = 10000;
    bool have_after = query_u64(query, "after", &after);
    query_u64(query, "timeout_ms", &timeout_ms);
    char buf[32768];
    shape_json(buf, sizeof buf, have_after, after, timeout_ms);
    respond_json(fd, 200, buf);
  } else if (post && route) {
    const char *err = NULL;
    jval *json = content_length ? json_parse(body, content_length, &err) : json_parse("{}", 2, &err);
    bool ok_shape = json && (json->type == J_OBJ || (json->type == J_ARR && route->fn == op_mouse));
    if (!ok_shape) {
      respond_error(fd, 400, err ? err : "body must be a JSON object");
    } else {
      char out[1024];
      op o = {.body = json, .status = 500, .out = out, .cap = sizeof out};
      run_op(route->fn, &o);
      respond_json(fd, o.status, out);
    }
    json_free(json);
  } else if (route || get_path) {
    respond_error(fd, 405, "wrong method");
  } else {
    respond_error(fd, 404, "no such endpoint");
  }
done:
  free(req);
  close(fd);
  return NULL;
}

static int listen_fd = -1;

static void *server(void *arg) {
  (void)arg;
  for (;;) {
    int fd = accept(listen_fd, NULL, NULL);
    if (fd < 0) {
      if (errno == EINTR) continue;
      perror("ghostty-host: accept");
      return NULL;
    }
    pthread_t t;
    pthread_create(&t, NULL, serve_conn, (void *)(intptr_t)fd);
    pthread_detach(t);
  }
}

void http_start(const char *socket_path) {
  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  snprintf(addr.sun_path, sizeof addr.sun_path, "%s", socket_path);
  unlink(socket_path);
  listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listen_fd < 0 || bind(listen_fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(listen_fd, 64) < 0) {
    fprintf(stderr, "ghostty-host: cannot listen on %s: %s\n", socket_path, strerror(errno));
    exit(1);
  }
  pthread_t t;
  pthread_create(&t, NULL, server, NULL);
  pthread_detach(t);
}
