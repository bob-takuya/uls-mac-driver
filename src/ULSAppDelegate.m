/*
 * ULS Laser Control for macOS
 * Application Delegate Implementation
 */

#import "ULSAppDelegate.h"

@implementation ULSAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Create and show main window
    self.mainWindowController = [[ULSMainWindowController alloc] init];
    [self.mainWindowController showWindow:self];
    [self.mainWindowController.window makeKeyAndOrderFront:nil];

    // Set up menu bar
    [self setupMenuBar];
}

- (void)setupMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // Application menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About ULS Laser Control"
                                                       action:@selector(showAboutPanel:)
                                                keyEquivalent:@""];
    aboutItem.target = self;
    [appMenu addItem:aboutItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"Preferences..."
                                                       action:@selector(showPreferences:)
                                                keyEquivalent:@","];
    prefsItem.target = self;
    [appMenu addItem:prefsItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit ULS Laser Control"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];

    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    // File menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open..."
                                                      action:@selector(openDocument:)
                                               keyEquivalent:@"o"];
    [fileMenu addItem:openItem];

    NSMenuItem *importItem = [[NSMenuItem alloc] initWithTitle:@"Import SVG..."
                                                        action:@selector(importSVG:)
                                                 keyEquivalent:@"i"];
    importItem.target = self.mainWindowController;
    [fileMenu addItem:importItem];

    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close"
                                                       action:@selector(performClose:)
                                                keyEquivalent:@"w"];
    [fileMenu addItem:closeItem];

    fileMenuItem.submenu = fileMenu;
    [mainMenu addItem:fileMenuItem];

    // Laser menu
    NSMenuItem *laserMenuItem = [[NSMenuItem alloc] init];
    NSMenu *laserMenu = [[NSMenu alloc] initWithTitle:@"Laser"];

    NSMenuItem *connectItem = [[NSMenuItem alloc] initWithTitle:@"Connect"
                                                         action:@selector(connectLaser:)
                                                  keyEquivalent:@""];
    connectItem.target = self.mainWindowController;
    [laserMenu addItem:connectItem];

    NSMenuItem *disconnectItem = [[NSMenuItem alloc] initWithTitle:@"Disconnect"
                                                            action:@selector(disconnectLaser:)
                                                     keyEquivalent:@""];
    disconnectItem.target = self.mainWindowController;
    [laserMenu addItem:disconnectItem];

    [laserMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *homeItem = [[NSMenuItem alloc] initWithTitle:@"Home"
                                                      action:@selector(homeLaser:)
                                               keyEquivalent:@"h"];
    homeItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    homeItem.target = self.mainWindowController;
    [laserMenu addItem:homeItem];

    NSMenuItem *startItem = [[NSMenuItem alloc] initWithTitle:@"Start Job"
                                                       action:@selector(startJob:)
                                                keyEquivalent:@"r"];
    startItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    startItem.target = self.mainWindowController;
    [laserMenu addItem:startItem];

    NSMenuItem *pauseItem = [[NSMenuItem alloc] initWithTitle:@"Pause Job"
                                                       action:@selector(pauseJob:)
                                                keyEquivalent:@"p"];
    pauseItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    pauseItem.target = self.mainWindowController;
    [laserMenu addItem:pauseItem];

    NSMenuItem *stopItem = [[NSMenuItem alloc] initWithTitle:@"Stop Job"
                                                      action:@selector(stopJob:)
                                               keyEquivalent:@"."];
    stopItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    stopItem.target = self.mainWindowController;
    [laserMenu addItem:stopItem];

    laserMenuItem.submenu = laserMenu;
    [mainMenu addItem:laserMenuItem];

    // Window menu
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

    NSMenuItem *minimizeItem = [[NSMenuItem alloc] initWithTitle:@"Minimize"
                                                          action:@selector(performMiniaturize:)
                                                   keyEquivalent:@"m"];
    [windowMenu addItem:minimizeItem];

    NSMenuItem *zoomItem = [[NSMenuItem alloc] initWithTitle:@"Zoom"
                                                      action:@selector(performZoom:)
                                               keyEquivalent:@""];
    [windowMenu addItem:zoomItem];

    windowMenuItem.submenu = windowMenu;
    [mainMenu addItem:windowMenuItem];

    // Help menu
    NSMenuItem *helpMenuItem = [[NSMenuItem alloc] init];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"ULS Laser Control Help"
                                                      action:@selector(showHelp:)
                                               keyEquivalent:@"?"];
    helpItem.target = self;
    [helpMenu addItem:helpItem];

    helpMenuItem.submenu = helpMenu;
    [mainMenu addItem:helpMenuItem];

    [[NSApplication sharedApplication] setMainMenu:mainMenu];
}

- (void)showAboutPanel:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"ULS Laser Control for macOS";
    alert.informativeText = @"Version 1.0\n\nA macOS driver for Universal Laser Systems laser cutters and engravers.\n\nBased on reverse engineering of the Windows driver for educational purposes.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)showPreferences:(id)sender {
    // Preferences window would be implemented here
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Preferences";
    alert.informativeText = @"Preferences panel coming soon.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)showHelp:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/"]];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    // Clean up
    [self.mainWindowController disconnectLaser:nil];
}

@end
