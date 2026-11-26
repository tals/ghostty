// macOS pieces of ghostty-host that speak Objective-C or Core Foundation:
// keeping App Nap and timer coalescing away, naming a surface's color space,
// and listing a process's windows.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#include <stdio.h>

static id activity;

// Keep App Nap and timer coalescing away from the render and IO threads.
void ghostty_host_begin_activity(void) {
  activity = [[NSProcessInfo processInfo]
      beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
                        reason:@"ghostty-host renders frames headlessly"];
}

// The color space Ghostty tagged a surface with (Target.zig), by name.
void ghostty_host_iosurface_colorspace(IOSurfaceRef surface, char *out, size_t len) {
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

// Windows the window server knows for pid, as JSON objects joined by commas.
void ghostty_host_windows_json(int pid, char *out, size_t out_len) {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  int count = 0;
  size_t used = 0;
  if (out_len) out[0] = 0;
  for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
    if ([info[(id)kCGWindowOwnerPID] intValue] != pid) continue;
    count++;
    NSDictionary *b = info[(id)kCGWindowBounds];
    int n = snprintf(out + used, out_len - used,
                     "%s{\"number\":%d,\"layer\":%d,\"onscreen\":%s,\"bounds\":[%d,%d,%d,%d]}",
                     count > 1 ? "," : "", [info[(id)kCGWindowNumber] intValue],
                     [info[(id)kCGWindowLayer] intValue],
                     [info[(id)kCGWindowIsOnscreen] boolValue] ? "true" : "false", [b[@"X"] intValue],
                     [b[@"Y"] intValue], [b[@"Width"] intValue], [b[@"Height"] intValue]);
    if (n > 0 && used + (size_t)n < out_len) used += (size_t)n;
  }
  if (list) CFRelease(list);
}
