#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>

static void ValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    IOHIDElementRef element = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    CFIndex integer = IOHIDValueGetIntegerValue(value);
    if (integer != 0) {
        printf("HID page=0x%x usage=0x%x value=%ld\n", page, usage, (long)integer);
        fflush(stdout);
    }
}

int main(void) {
    @autoreleasepool {
        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSDictionary *match = @{
            @kIOHIDVendorIDKey: @0x3554,
            @kIOHIDProductIDKey: @0xf503
        };
        IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);
        IOHIDManagerRegisterInputValueCallback(manager, ValueCallback, NULL);
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOReturn result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        printf("HIDOpen=0x%x\nREADY: press both side buttons several times (20 seconds)\n", result);
        fflush(stdout);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:20.0]];
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        printf("DONE\n");
        fflush(stdout);
    }
    return 0;
}
