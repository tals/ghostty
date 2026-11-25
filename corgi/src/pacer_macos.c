// A display link that needs no display.
//
// With vsync (Ghostty's default) the renderer draws when its CVDisplayLink
// fires and skips draws on terminal wakeups. Without one, as when the Mac has
// no active display (asleep, locked, lid closed: CVDisplayLinkCreate fails),
// it draws on every wakeup: thousands of frames a second while text
// scrolls. libghostty is linked statically, so these definitions are the
// seven CVDisplayLink calls it makes (pkg/macos/video/display_link.zig);
// AppKit and Core Animation keep their own. The link ticks at a fixed rate
// on a dispatch timer, starting and stopping when Ghostty says.
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>

#include "host.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

struct __CVDisplayLink {
  dispatch_source_t timer;
  CVDisplayLinkOutputCallback callback;
  void *ctx;
  bool running;
};

static void tick(void *ctx) {
  CVDisplayLinkRef link = ctx;
  CVTimeStamp now = {.version = 0, .hostTime = mono_ns()};
  CVOptionFlags out = 0;
  if (link->callback) link->callback(link, &now, &now, 0, &out, link->ctx);
}

CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *out) {
  CVDisplayLinkRef link = calloc(1, sizeof *link);
  dispatch_queue_t queue = dispatch_queue_create("ghostty-host.pacer", DISPATCH_QUEUE_SERIAL);
  link->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, queue);
  uint64_t period = (uint64_t)(1e9 / opt.fps);
  dispatch_source_set_timer(link->timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)period), period, 0);
  dispatch_set_context(link->timer, link);
  dispatch_source_set_event_handler_f(link->timer, tick);
  dispatch_release(queue);  // the source keeps it
  *out = link;
  return kCVReturnSuccess;
}

CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef link, CVDisplayLinkOutputCallback callback, void *ctx) {
  link->callback = callback;
  link->ctx = ctx;
  return kCVReturnSuccess;
}

CVReturn CVDisplayLinkSetCurrentCGDisplay(CVDisplayLinkRef link, CGDirectDisplayID display) {
  (void)link, (void)display;
  return kCVReturnSuccess;
}

CVReturn CVDisplayLinkStart(CVDisplayLinkRef link) {
  if (!link->running) {
    link->running = true;
    dispatch_resume(link->timer);
  }
  return kCVReturnSuccess;
}

CVReturn CVDisplayLinkStop(CVDisplayLinkRef link) {
  if (link->running) {
    link->running = false;
    dispatch_suspend(link->timer);
  }
  return kCVReturnSuccess;
}

Boolean CVDisplayLinkIsRunning(CVDisplayLinkRef link) { return link->running; }

void CVDisplayLinkRelease(CVDisplayLinkRef link) {
  if (!link) return;
  // Freed by the cancel handler, after any tick in flight. A source must be
  // resumed before it is cancelled.
  dispatch_source_set_cancel_handler_f(link->timer, free);
  if (!link->running) dispatch_resume(link->timer);
  dispatch_source_cancel(link->timer);
  dispatch_release(link->timer);
}
