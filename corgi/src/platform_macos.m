// macOS side of ghostty-host: AppKit's main loop, the windowless NSView
// Ghostty's Metal renderer draws into, the setContents: tap on Ghostty's
// IOSurfaceLayer, and IOSurface reads. The display link stand-in is in
// pacer_macos.c.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pwd.h>

#include "host.h"

// --- Running the command directly ------------------------------------------------
//
// On macOS, Ghostty wraps every command in `/usr/bin/login -flp USER bash -c
// "exec -l CMD"` (termio/Exec.zig, execCommand): login prints "Last login"
// unless ~/.hushlogin exists, and the command becomes a login shell. Exec.zig
// skips the wrapper, and runs `/bin/sh -c CMD` as on Linux, when the passwd
// entry has no user name. libghostty is linked statically, so this definition
// is the getpwuid_r its passwd lookup calls; it hides the name and nothing else.

static bool hide_user_name;

int getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t len, struct passwd **out) {
  static int (*real)(uid_t, struct passwd *, char *, size_t, struct passwd **);
  if (!real) real = (int (*)(uid_t, struct passwd *, char *, size_t, struct passwd **))dlsym(RTLD_NEXT, "getpwuid_r");
  int r = real(uid, pw, buf, len, out);
  if (r == 0 && *out && hide_user_name) (*out)->pw_name = NULL;
  return r;
}

// --- Main loop --------------------------------------------------------------------

static id activity;
static NSView *view;

void platform_init(void) {
  hide_user_name = opt.n_command > 0 && !opt.login;
  [NSApplication sharedApplication];
  // No Dock icon, no menu bar, never activates.
  [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  // Keep App Nap and timer coalescing away from the render and IO threads.
  activity = [[NSProcessInfo processInfo]
      beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                        reason:@"ghostty-host renders frames headlessly"];
}

void platform_async(void (*fn)(void *), void *ctx) { dispatch_async_f(dispatch_get_main_queue(), ctx, fn); }

void platform_sync(void (*fn)(void *), void *ctx) { dispatch_sync_f(dispatch_get_main_queue(), ctx, fn); }

void platform_run(void) { [NSApp run]; }

void platform_stop(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp stop:nil];
    // stop: takes effect after the next event; post one.
    NSEvent *e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                    location:NSZeroPoint
                               modifierFlags:0
                                   timestamp:0
                                windowNumber:0
                                     context:nil
                                     subtype:0
                                       data1:0
                                       data2:0];
    [NSApp postEvent:e atStart:YES];
  });
}

// --- Surface ----------------------------------------------------------------------

void platform_surface_config(ghostty_surface_config_s *sc) {
  // The view matches the surface's initial 800x600 points until the grid
  // size is known.
  view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  sc->platform_tag = GHOSTTY_PLATFORM_MACOS;
  sc->platform.macos.nsview = (__bridge void *)view;
}

// Frames come through the setContents: tap, not the render action.
void platform_on_render(void) {}

// The tap. Ghostty sets each finished frame as the layer's contents on the
// main thread (IOSurfaceLayer.zig), through -setContents:. The tap reads
// the IOSurface while it is locked, then hands it on to CALayer.

static IMP original_set_contents;

// The color space Ghostty tagged the surface with (Target.zig), by name.
static void surface_colorspace(IOSurfaceRef surface, char *out, size_t len) {
  snprintf(out, len, "none");
  CFTypeRef plist = IOSurfaceCopyValue(surface, kIOSurfaceColorSpace);
  if (!plist) return;
  CGColorSpaceRef cs = CGColorSpaceCreateWithPropertyList(plist);
  CFRelease(plist);
  if (!cs) return;
  CFStringRef name = CGColorSpaceCopyName(cs);
  if (name) {
    CFStringGetCString(name, out, (CFIndex)len, kCFStringEncodingUTF8);
    CFRelease(name);
  } else {
    snprintf(out, len, "unnamed");
  }
  CGColorSpaceRelease(cs);
}

static void tap_set_contents(id self, SEL _cmd, id contents) {
  if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
    IOSurfaceRef surface = (__bridge IOSurfaceRef)contents;
    uint64_t start = mono_ns();
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
      // Ghostty keeps three surfaces; name each one's color space once.
      IOSurfaceID id = IOSurfaceGetID(surface);
      static struct { IOSurfaceID id; char name[64]; } seen[8];
      static unsigned next;
      unsigned i = 0;
      while (i < 8 && seen[i].id != id) i++;
      if (i == 8) {
        i = next++ % 8;
        seen[i].id = id;
        surface_colorspace(surface, seen[i].name, sizeof seen[i].name);
      }
      host_frame frame = {
          .pixels = IOSurfaceGetBaseAddress(surface),
          .stride = IOSurfaceGetBytesPerRow(surface),
          .width = (uint32_t)IOSurfaceGetWidth(surface),
          .height = (uint32_t)IOSurfaceGetHeight(surface),
          .bgra = true,
          .gpu_readback_ns = mono_ns() - start,  // the lock
          .colorspace = seen[i].name,
      };
      frames_on_present(&frame);
      IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    }
  }
  ((void (*)(id, SEL, id))original_set_contents)(self, _cmd, contents);
}

bool platform_surface_ready(uint32_t width, uint32_t height, char *err, size_t err_len) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [view setFrame:NSMakeRect(0, 0, width / opt.scale, height / opt.scale)];
  [CATransaction commit];

  CALayer *layer = view.layer;
  if (!layer) {
    snprintf(err, err_len, "the view has no layer");
    return false;
  }
  Class cls = object_getClass(layer);
  if (strcmp(class_getName(cls), "IOSurfaceLayer") != 0) {
    snprintf(err, err_len, "the view's layer is a %s, not Ghostty's IOSurfaceLayer",
             class_getName(cls));
    return false;
  }
  original_set_contents = class_getMethodImplementation(cls, @selector(setContents:));

  // Swizzle only this instance onto a subclass, so CALayer stays untouched.
  Class tap = objc_getClass("GhosttyHostIOSurfaceLayerTap");
  if (!tap) {
    tap = objc_allocateClassPair(cls, "GhosttyHostIOSurfaceLayerTap", 0);
    Method m = class_getInstanceMethod(cls, @selector(setContents:));
    class_addMethod(tap, @selector(setContents:), (IMP)tap_set_contents,
                    method_getTypeEncoding(m));
    objc_registerClassPair(tap);
  }
  object_setClass(layer, tap);
  return true;
}

void platform_windows_json(int pid, char *out, size_t out_len) {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  int count = 0;
  size_t used = 0;
  if (out_len) out[0] = 0;
  for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
    if ([info[(id)kCGWindowOwnerPID] intValue] != pid) continue;
    count++;
    NSDictionary *b = info[(id)kCGWindowBounds];
    int n = snprintf(out + used, out_len - used, "%s{\"number\":%d,\"layer\":%d,\"onscreen\":%s,\"bounds\":[%d,%d,%d,%d]}",
                     count > 1 ? "," : "", [info[(id)kCGWindowNumber] intValue],
                     [info[(id)kCGWindowLayer] intValue],
                     [info[(id)kCGWindowIsOnscreen] boolValue] ? "true" : "false",
                     [b[@"X"] intValue], [b[@"Y"] intValue], [b[@"Width"] intValue],
                     [b[@"Height"] intValue]);
    if (n > 0 && used + n < out_len) used += n;
  }
  if (list) CFRelease(list);
}
