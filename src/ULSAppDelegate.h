/*
 * ULS Laser Control for macOS
 * Application Delegate Header
 */

#import <Cocoa/Cocoa.h>
#import "ULSMainWindowController.h"

@interface ULSAppDelegate : NSObject <NSApplicationDelegate>

@property (strong, nonatomic) ULSMainWindowController *mainWindowController;

@end
