// Lists the window server's windows for a process, from outside it.
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics tools/winlist.m -o build/winlist
//   build/winlist PID
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2) {
      fprintf(stderr, "usage: winlist PID\n");
      return 2;
    }
    int pid = atoi(argv[1]);
    NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
    int mine = 0;
    NSMutableSet *owners = [NSMutableSet set];
    for (NSDictionary *w in all) {
      [owners addObject:w[(id)kCGWindowOwnerPID]];
      if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
      mine++;
      printf("window %d layer %d onscreen %d bounds %s name %s\n", [w[(id)kCGWindowNumber] intValue],
             [w[(id)kCGWindowLayer] intValue], [w[(id)kCGWindowIsOnscreen] boolValue],
             [[w[(id)kCGWindowBounds] description] UTF8String], [[w[(id)kCGWindowName] description] UTF8String]);
    }
    printf("CGWindowListCopyWindowInfo(kCGWindowListOptionAll): %lu windows from %lu processes; %d for pid %d\n",
           (unsigned long)all.count, (unsigned long)owners.count, mine, pid);
  }
  return 0;
}
