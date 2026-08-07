#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

static CGEventRef TapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) {
        int64_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
        printf("CGEVENT type=%s button=%lld\n", type == kCGEventOtherMouseDown ? "down" : "up", button);
        fflush(stdout);
    } else if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        printf("CGEVENT type=%s keycode=%lld flags=%llu\n", type == kCGEventKeyDown ? "keyDown" : "keyUp", keycode, (unsigned long long)CGEventGetFlags(event));
        fflush(stdout);
    } else if (type == kCGEventScrollWheel) {
        int64_t vertical = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        int64_t horizontal = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        printf("CGEVENT type=scroll vertical=%lld horizontal=%lld\n", vertical, horizontal);
        fflush(stdout);
    }
    return event;
}

int main(void) {
    @autoreleasepool {
        printf("InputMonitoring=%s\n", CGPreflightListenEventAccess() ? "allowed" : "not_allowed");
        fflush(stdout);
        CGEventMask mask = CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventScrollWheel);
        CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, TapCallback, NULL);
        if (tap) {
            CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
            printf("CGEventTap=active\n");
            fflush(stdout);
        } else {
            printf("CGEventTap=unavailable\n");
            fflush(stdout);
        }
        id monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp | NSEventMaskSystemDefined) handler:^(NSEvent *event) {
            printf("NSEVENT type=%ld button=%ld subtype=%d data1=%ld data2=%ld\n", (long)event.type, (long)event.buttonNumber, event.subtype, (long)event.data1, (long)event.data2);
            fflush(stdout);
        }];
        printf("READY: press only both side buttons several times (15 seconds)\n");
        fflush(stdout);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:15.0]];
        if (monitor) [NSEvent removeMonitor:monitor];
        printf("DONE\n");
        fflush(stdout);
    }
    return 0;
}
