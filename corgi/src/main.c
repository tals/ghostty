// ghostty-host: runs a command in a windowless libghostty surface, takes
// scripted keys and mouse input over HTTP on a Unix socket, reports the
// pointer shape, and hands out every rendered frame's pixels.
//
//   ghostty-host (--dir DIR | --socket PATH) [--size COLSxROWS] [--font-size N] -- COMMAND ...
//
// See README.md for the API. Platform parts are in platform_macos.m and
// platform_linux.c.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#include "host.h"

#ifndef DEFAULT_RESOURCES_DIR
#define DEFAULT_RESOURCES_DIR ""
#endif

options opt = {.cols = 80, .rows = 24, .scale = 1, .fps = 60};

// The dpi Ghostty turns points into pixels with at scale 1 (font.face.default_dpi).
#ifdef __APPLE__
#define GHOSTTY_DPI 72.0
#else
#define GHOSTTY_DPI 96.0
#endif
ghostty_app_t app;
ghostty_surface_t surface;
geometry geo;

static uint32_t initial_w, initial_h;
static char socket_path_buf[sizeof(((struct sockaddr_un *)0)->sun_path)];
static char socket_file[4096];  // DIR/socket, naming the socket in use

static void die(const char *fmt, const char *arg) {
  fprintf(stderr, "ghostty-host: ");
  fprintf(stderr, fmt, arg);
  fprintf(stderr, "\n");
  exit(1);
}

// --- Pointer shape --------------------------------------------------------------

static const char *const SHAPE_NAMES[] = {
    "default", "context-menu", "help", "pointer", "progress", "wait", "cell", "crosshair",
    "text", "vertical-text", "alias", "copy", "move", "no-drop", "not-allowed", "grab",
    "grabbing", "all-scroll", "col-resize", "row-resize", "n-resize", "e-resize", "s-resize",
    "w-resize", "ne-resize", "nw-resize", "se-resize", "sw-resize", "ew-resize", "ns-resize",
    "nesw-resize", "nwse-resize", "zoom-in", "zoom-out",
};

const char *shape_name(int shape) {
  if (shape >= 0 && (size_t)shape < sizeof SHAPE_NAMES / sizeof *SHAPE_NAMES) return SHAPE_NAMES[shape];
  return "unknown";
}

#define SHAPE_HISTORY 256

typedef struct {
  uint64_t seq;
  int shape;
  bool visible;
  uint64_t time_unix_ns;
} shape_state;

static pthread_mutex_t shape_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t shape_changed = PTHREAD_COND_INITIALIZER;
// Ghostty's terminal starts at text and reports only changes; the macOS
// app's view starts with the I-beam too.
static shape_state shape_now = {.seq = 0, .shape = GHOSTTY_MOUSE_SHAPE_TEXT, .visible = true};
static shape_state shape_history[SHAPE_HISTORY];

// Ghostty asks for a shape on every key and mouse move; keep real changes.
static void shape_record(int shape, int visible) {
  pthread_mutex_lock(&shape_mu);
  if ((shape < 0 || shape == shape_now.shape) && (visible < 0 || visible == shape_now.visible)) {
    pthread_mutex_unlock(&shape_mu);
    return;
  }
  if (shape >= 0) shape_now.shape = shape;
  if (visible >= 0) shape_now.visible = visible;
  shape_now.seq++;
  shape_now.time_unix_ns = realtime_ns();
  shape_history[shape_now.seq % SHAPE_HISTORY] = shape_now;
  pthread_cond_broadcast(&shape_changed);
  pthread_mutex_unlock(&shape_mu);
}

static void shape_entry(char *buf, size_t cap, size_t *used, const shape_state *s, bool with_time) {
  *used += (size_t)snprintf(buf + *used, cap - *used, "{\"seq\":%llu,\"shape\":\"%s\",\"visible\":%s",
                            (unsigned long long)s->seq, shape_name(s->shape), s->visible ? "true" : "false");
  if (with_time)
    *used += (size_t)snprintf(buf + *used, cap - *used, ",\"time_unix_ns\":%llu", (unsigned long long)s->time_unix_ns);
  *used += (size_t)snprintf(buf + *used, cap - *used, "}");
}

void shape_brief_json(char *buf, size_t cap, size_t *used) {
  pthread_mutex_lock(&shape_mu);
  shape_entry(buf, cap, used, &shape_now, false);
  pthread_mutex_unlock(&shape_mu);
}

void shape_json(char *buf, size_t cap, bool have_after, uint64_t after, uint64_t timeout_ms) {
  pthread_mutex_lock(&shape_mu);
  if (have_after && shape_now.seq <= after) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    uint64_t ns = (uint64_t)deadline.tv_nsec + (timeout_ms % 1000) * 1000000ull;
    deadline.tv_sec += (time_t)(timeout_ms / 1000 + ns / 1000000000ull);
    deadline.tv_nsec = (long)(ns % 1000000000ull);
    while (shape_now.seq <= after)
      if (pthread_cond_timedwait(&shape_changed, &shape_mu, &deadline)) break;
  }
  size_t used = (size_t)snprintf(buf, cap, "{\"seq\":%llu,\"shape\":\"%s\",\"visible\":%s,\"changes\":[",
                                 (unsigned long long)shape_now.seq, shape_name(shape_now.shape),
                                 shape_now.visible ? "true" : "false");
  uint64_t first = after + 1;
  if (shape_now.seq >= SHAPE_HISTORY && first <= shape_now.seq - SHAPE_HISTORY) first = shape_now.seq - SHAPE_HISTORY + 1;
  if (first == 0) first = 1;
  for (uint64_t s = first; s <= shape_now.seq; s++) {
    if (s > first) used += (size_t)snprintf(buf + used, cap - used, ",");
    shape_entry(buf, cap, &used, &shape_history[s % SHAPE_HISTORY], true);
  }
  snprintf(buf + used, cap - used, "]}");
  pthread_mutex_unlock(&shape_mu);
}

// --- Ghostty runtime callbacks -----------------------------------------------------

static atomic_bool tick_pending;
static int exit_code;  // the command's, once it exits

atomic_bool tty_known;

// The pty opens after ghostty_surface_new returns; note its name once known.
static void learn_tty(void) {
  ghostty_string_s tty = ghostty_surface_tty_name(surface);
  if (tty.ptr && tty.len) {
    snprintf(geo.tty, sizeof geo.tty, "%.*s", (int)tty.len, tty.ptr);
    atomic_store_explicit(&tty_known, true, memory_order_release);
  }
  ghostty_string_free(tty);
}

static void tick(void *ctx) {
  (void)ctx;
  atomic_store(&tick_pending, false);
  ghostty_app_tick(app);
  if (surface && !atomic_load(&tty_known)) learn_tty();
}

static void on_wakeup(void *ud) {
  (void)ud;
  // Any thread. Tick on the main thread, as Ghostty.App.swift does.
  if (!atomic_exchange(&tick_pending, true)) platform_async(tick, NULL);
}

static bool on_action(ghostty_app_t a, ghostty_target_s target, ghostty_action_s action) {
  (void)a, (void)target;
  switch (action.tag) {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      shape_record((int)action.action.mouse_shape, -1);
      return true;
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
      shape_record(-1, action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE);
      return true;
    case GHOSTTY_ACTION_INITIAL_SIZE:
      initial_w = action.action.initial_size.width;
      initial_h = action.action.initial_size.height;
      return true;
    case GHOSTTY_ACTION_RENDER:
      platform_on_render();
      return true;
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      // Handled: Ghostty would otherwise print its own exit banner. The host
      // goes when its command does, as a Ghostty window closes.
      exit_code = (int)action.action.child_exited.exit_code;
      fprintf(stderr, "ghostty-host: command exited with code %d\n", exit_code);
      platform_stop();
      return true;
    default:
      return false;
  }
}

static ghostty_clipboard_read_result_e on_read_clipboard(void *ud, ghostty_clipboard_e loc, void *state,
                                                         const char *const *mimes, size_t n, bool list) {
  (void)ud, (void)loc, (void)state, (void)mimes, (void)n, (void)list;
  return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE;
}

static void on_confirm_read_clipboard(void *ud, const ghostty_clipboard_confirm_s *c, void *state,
                                      ghostty_clipboard_request_e req) {
  (void)ud, (void)c, (void)state, (void)req;
}

static void on_write_clipboard(void *ud, ghostty_clipboard_e loc, const ghostty_clipboard_content_s *c, size_t n,
                               bool confirm) {
  (void)ud, (void)loc, (void)c, (void)n, (void)confirm;
}

static void on_close_surface(void *ud, bool process_alive) { (void)ud, (void)process_alive; }

// --- Startup -----------------------------------------------------------------------

static void usage(void) {
  fprintf(stderr,
          "usage: ghostty-host (--dir DIR | --socket PATH) [options] [-- COMMAND ...]\n"
          "  --dir DIR            serve on DIR/ghostty.sock, or /tmp/ghostty-host-PID.sock when\n"
          "                       that is too long; DIR/socket names the one in use\n"
          "  --socket PATH        serve on PATH\n"
          "  --size COLSxROWS     terminal grid; default 80x24\n"
          "  --font-size N        font size in points at 96 dpi, as Ghostty on Linux takes it\n"
          "  --scale S            backing scale; default 1 (frame pixels = points)\n"
          "  --config KEY=VALUE   a Ghostty config line; repeatable, applied last\n"
          "  --config-file PATH   a Ghostty config file; repeatable\n"
          "  --color MODE         macOS: passthrough (default): Ghostty skips its sRGB-to-P3\n"
          "                       step, so pixels are the configured sRGB colors\n"
          "                       convert: Ghostty's macOS pipeline, converted back to sRGB\n"
          "  --fps N              Ghostty's draw rate while the screen changes; default 60\n"
          "                       (macOS: window-vsync=false draws on every update instead)\n"
          "  --cwd DIR            working directory for the command\n"
          "  --login              macOS: run the command through login(1) as Ghostty.app does\n"
          "The host exits with the command's exit code when the command exits.\n");
  exit(2);
}

static void parse_args(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
#define NEXT() (i + 1 < argc ? argv[++i] : (usage(), ""))
    if (!strcmp(a, "--")) {
      opt.command = argv + i + 1;
      opt.n_command = argc - i - 1;
      break;
    } else if (!strcmp(a, "--socket")) opt.socket_path = NEXT();
    else if (!strcmp(a, "--dir")) opt.dir = NEXT();
    else if (!strcmp(a, "--size")) {
      if (sscanf(NEXT(), "%dx%d", &opt.cols, &opt.rows) != 2 || opt.cols < 1 || opt.rows < 1) usage();
    } else if (!strcmp(a, "--font-size")) opt.font_size = atof(NEXT());
    else if (!strcmp(a, "--scale")) opt.scale = atof(NEXT());
    else if (!strcmp(a, "--config")) {
      if (opt.n_config_lines == 64) usage();
      opt.config_lines[opt.n_config_lines++] = NEXT();
    } else if (!strcmp(a, "--config-file")) {
      if (opt.n_config_files == 32) usage();
      opt.config_files[opt.n_config_files++] = NEXT();
    } else if (!strcmp(a, "--color")) {
      const char *m = NEXT();
      if (!strcmp(m, "convert")) opt.convert_p3 = true;
      else if (!strcmp(m, "passthrough")) opt.convert_p3 = false;
      else usage();
    } else if (!strcmp(a, "--fps")) {
      opt.fps = atof(NEXT());
      if (opt.fps < 1 || opt.fps > 1000) usage();
    } else if (!strcmp(a, "--cwd")) opt.cwd = NEXT();
    else if (!strcmp(a, "--login")) opt.login = true;
    else usage();
#undef NEXT
  }
  if (!opt.socket_path == !opt.dir || opt.scale < 1) usage();
#ifndef __APPLE__
  if (opt.convert_p3) fprintf(stderr, "ghostty-host: --color convert is for macOS; frames are sRGB here\n");
  if (opt.login) fprintf(stderr, "ghostty-host: --login is for macOS; Ghostty never uses login(1) here\n");
  opt.convert_p3 = opt.login = false;
#endif
}

// Unix socket paths are limited to 104 bytes on macOS, 108 on Linux.
static void choose_socket(void) {
  if (opt.socket_path) {
    if (strlen(opt.socket_path) >= sizeof socket_path_buf) die("socket path is over 103 bytes: %s", opt.socket_path);
    return;
  }
  if (mkdir(opt.dir, 0700) < 0 && errno != EEXIST) die("cannot create %s", opt.dir);
  int n = snprintf(socket_path_buf, sizeof socket_path_buf, "%s/ghostty.sock", opt.dir);
  if (n < 0 || (size_t)n >= sizeof socket_path_buf)
    snprintf(socket_path_buf, sizeof socket_path_buf, "/tmp/ghostty-host-%d.sock", getpid());
  opt.socket_path = socket_path_buf;
  snprintf(socket_file, sizeof socket_file, "%s/socket", opt.dir);
}

// Written once the socket listens, as ghostty-capture does.
static void write_socket_file(void) {
  if (!socket_file[0]) return;
  FILE *f = fopen(socket_file, "w");
  if (!f) die("cannot write %s", socket_file);
  fprintf(f, "%s\n", opt.socket_path);
  fclose(f);
}

static void cleanup(void) {
  unlink(opt.socket_path);
  if (socket_file[0]) unlink(socket_file);
}

// Ghostty's resources (themes, shell integration, and terminfo beside them)
// in share/ghostty next to the executable, as a release packs them.
static bool bundled_resources(char *out, size_t size) {
  char exe[PATH_MAX];
#ifdef __APPLE__
  uint32_t n = sizeof exe;
  if (_NSGetExecutablePath(exe, &n)) return false;
#else
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n <= 0) return false;
  exe[n] = 0;
#endif
  char real[PATH_MAX];
  if (!realpath(exe, real)) return false;
  char *slash = strrchr(real, '/');
  if (!slash) return false;
  *slash = 0;
  struct stat st;
  return snprintf(out, size, "%s/share/ghostty", real) < (int)size && !stat(out, &st) && S_ISDIR(st.st_mode);
}

// A parent Ghostty leaks GHOSTTY_RESOURCES_DIR (pointing into its own app
// bundle) and shell-integration variables. Ghostty snapshots the environment
// in ghostty_init, so clean it first.
static void clean_environment(void) {
  extern char **environ;
  for (bool again = true; again;) {
    again = false;
    for (char **e = environ; *e; e++) {
      if (strncmp(*e, "GHOSTTY_", 8) || !strncmp(*e, "GHOSTTY_LOG=", 12)) continue;
      char name[256];
      snprintf(name, sizeof name, "%.*s", (int)(strchr(*e, '=') - *e), *e);
      unsetenv(name);
      again = true;
      break;
    }
  }
  char resources[PATH_MAX];
  if (bundled_resources(resources, sizeof resources)) setenv("GHOSTTY_RESOURCES_DIR", resources, 1);
  else if (DEFAULT_RESOURCES_DIR[0]) setenv("GHOSTTY_RESOURCES_DIR", DEFAULT_RESOURCES_DIR, 1);
}

// Joins argv into one /bin/sh command line, each word single-quoted.
static char *shell_join(const char *prefix, char **words, int n) {
  size_t cap = strlen(prefix) + 1;
  for (int i = 0; i < n; i++) cap += strlen(words[i]) * 4 + 3;
  char *out = malloc(cap), *p = out;
  p += sprintf(p, "%s", prefix);
  for (int i = 0; i < n; i++) {
    if (i) *p++ = ' ';
    *p++ = '\'';
    for (const char *s = words[i]; *s; s++) {
      if (*s == '\'') {
        memcpy(p, "'\\''", 4);
        p += 4;
      } else {
        *p++ = *s;
      }
    }
    *p++ = '\'';
  }
  *p = 0;
  return out;
}

static void load_config_text(ghostty_config_t config, const char *text) {
  char path[] = "/tmp/ghostty-host-config.XXXXXX";
  int fd = mkstemp(path);
  if (fd < 0) die("cannot create a config file in %s", "/tmp");
  size_t len = strlen(text);
  if (write(fd, text, len) != (ssize_t)len) die("cannot write %s", path);
  close(fd);
  ghostty_config_load_file(config, path);
  unlink(path);
}

// window-padding-x/y as given with --config: "N" or "LEFT,RIGHT".
static void config_padding(const char *key, uint32_t *a, uint32_t *b) {
  for (int i = 0; i < opt.n_config_lines; i++) {
    const char *line = opt.config_lines[i];
    size_t klen = strlen(key);
    if (strncmp(line, key, klen) || line[klen] != '=') continue;
    unsigned x, y;
    int n = sscanf(line + klen + 1, "%u,%u", &x, &y);
    if (n >= 1) *a = *b = x;
    if (n == 2) *b = y;
  }
}

static ghostty_config_t build_config(void) {
  ghostty_config_t config = ghostty_config_new();
  char base[1024];
  int n = snprintf(base, sizeof base,
                   "# ghostty-host defaults; --config-file and --config apply after these.\n"
                   "window-width = %d\n"
                   "window-height = %d\n",
                   opt.cols, opt.rows);
  // --font-size is points at 96 dpi everywhere, so the same size gives the
  // same cells; Ghostty on macOS takes them at 72 dpi.
  if (opt.font_size > 0)
    n += snprintf(base + n, sizeof base - (size_t)n, "font-size = %g\n", opt.font_size * 96.0 / GHOSTTY_DPI);
#ifdef __APPLE__
  // Ghostty converts sRGB colors to Display P3 in its shaders unless told the
  // colors already are P3. Then the target's bytes are the configured values.
  if (!opt.convert_p3) snprintf(base + n, sizeof base - (size_t)n, "window-colorspace = display-p3\n");
#endif
  load_config_text(config, base);
  for (int i = 0; i < opt.n_config_files; i++) ghostty_config_load_file(config, opt.config_files[i]);
  if (opt.n_config_lines) {
    size_t cap = 1;
    for (int i = 0; i < opt.n_config_lines; i++) cap += strlen(opt.config_lines[i]) + 4;
    char *text = malloc(cap), *p = text;
    for (int i = 0; i < opt.n_config_lines; i++) {
      const char *line = opt.config_lines[i], *eq = strchr(line, '=');
      if (!eq) die("--config wants KEY=VALUE, got %s", line);
      p += sprintf(p, "%.*s = %s\n", (int)(eq - line), line, eq + 1);
    }
    load_config_text(config, text);
    free(text);
  }
  ghostty_config_finalize(config);
  uint32_t diags = ghostty_config_diagnostics_count(config);
  for (uint32_t i = 0; i < diags; i++)
    fprintf(stderr, "ghostty-host: config: %s\n", ghostty_config_get_diagnostic(config, i).message);
  return config;
}

static void on_signal(int sig) {
  (void)sig;
  cleanup();
  _exit(0);
}

int main(int argc, char **argv) {
  parse_args(argc, argv);
  choose_socket();
  signal(SIGPIPE, SIG_IGN);
  // Shells ignore SIGINT in background jobs; leave ignored signals ignored.
  int sigs[] = {SIGINT, SIGTERM, SIGHUP};
  for (int i = 0; i < 3; i++) {
    struct sigaction old;
    if (sigaction(sigs[i], NULL, &old) == 0 && old.sa_handler == SIG_DFL) signal(sigs[i], on_signal);
  }
  clean_environment();
  platform_init();
  char *ghostty_argv[] = {argv[0], NULL};
  if (ghostty_init(1, ghostty_argv) != GHOSTTY_SUCCESS) die("ghostty_init failed%s", "");

  ghostty_config_t config = build_config();
  ghostty_runtime_config_s runtime = {
      .wakeup_cb = on_wakeup,
      .action_cb = on_action,
      .read_clipboard_cb = on_read_clipboard,
      .confirm_read_clipboard_cb = on_confirm_read_clipboard,
      .write_clipboard_cb = on_write_clipboard,
      .close_surface_cb = on_close_surface,
  };
  app = ghostty_app_new(&runtime, config);
  if (!app) die("ghostty_app_new failed%s", "");
  ghostty_app_set_focus(app, true);
  frames_start();

  ghostty_surface_config_s sc = ghostty_surface_config_new();
  platform_surface_config(&sc);
  sc.scale_factor = opt.scale;
  sc.working_directory = opt.cwd;
  // Ghostty runs this with /bin/sh -c (with --login, inside login and bash).
  sc.command = opt.n_command ? shell_join("exec ", opt.command, opt.n_command) : NULL;
  sc.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;
  surface = ghostty_surface_new(app, &sc);
  if (!surface) die("ghostty_surface_new failed%s", "");

  // window-width/height make Ghostty report the window size for the grid
  // (Surface.recomputeInitialSize): ceil(cells / scale) + padding in pixels.
  // Undo the scale on the cells to get the framebuffer size.
  ghostty_surface_size_s size = ghostty_surface_size(surface);
  uint32_t cw = size.cell_width_px, ch = size.cell_height_px;
  if (!initial_w || !cw) die("Ghostty reported no initial size%s", "");
  uint32_t pad_w = initial_w - (uint32_t)ceil(opt.cols * cw / opt.scale);
  uint32_t pad_h = initial_h - (uint32_t)ceil(opt.rows * ch / opt.scale);
  geo.width = (uint32_t)opt.cols * cw + pad_w;
  geo.height = (uint32_t)opt.rows * ch + pad_h;
  // Ghostty's default padding is 2 points per side; --config can change it.
  uint32_t px[2] = {2, 2}, py[2] = {2, 2};
  config_padding("window-padding-x", &px[0], &px[1]);
  config_padding("window-padding-y", &py[0], &py[1]);
  double pt = opt.scale * GHOSTTY_DPI / 72;
  geo.pad_left = (uint32_t)floor(px[0] * pt);
  geo.pad_right = (uint32_t)floor(px[1] * pt);
  geo.pad_top = (uint32_t)floor(py[0] * pt);
  geo.pad_bottom = (uint32_t)floor(py[1] * pt);
  if (geo.pad_left + geo.pad_right != pad_w) geo.pad_left = pad_w / 2, geo.pad_right = pad_w - pad_w / 2;
  if (geo.pad_top + geo.pad_bottom != pad_h) geo.pad_top = pad_h / 2, geo.pad_bottom = pad_h - pad_h / 2;
  char err[256];
  if (!platform_surface_ready(geo.width, geo.height, err, sizeof err)) die("%s", err);
  ghostty_surface_set_size(surface, geo.width, geo.height);
  ghostty_surface_set_focus(surface, true);

  size = geo.grid = ghostty_surface_size(surface);
  learn_tty();
  if (size.columns != opt.cols || size.rows != opt.rows)
    fprintf(stderr, "ghostty-host: asked for %dx%d cells, Ghostty made %ux%u\n", opt.cols, opt.rows, size.columns,
            size.rows);

  http_start(opt.socket_path);
  write_socket_file();
  printf("{\"ready\":true,\"socket\":\"%s\",\"pid\":%d,\"width\":%u,\"height\":%u,\"columns\":%u,\"rows\":%u,"
         "\"cell_width\":%u,\"cell_height\":%u}\n",
         opt.socket_path, getpid(), geo.width, geo.height, size.columns, size.rows, size.cell_width_px,
         size.cell_height_px);
  fflush(stdout);

  platform_run();
  cleanup();
  ghostty_surface_free(surface);
  ghostty_app_free(app);
  return exit_code;
}
