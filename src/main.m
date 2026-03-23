/*
 * ULS Laser Control for macOS
 * Main Application Entry Point
 *
 * This is a native macOS application for controlling Universal Laser Systems
 * laser cutters/engravers.
 */

#import <Cocoa/Cocoa.h>
#import "ULSAppDelegate.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        ULSAppDelegate *delegate = [[ULSAppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
