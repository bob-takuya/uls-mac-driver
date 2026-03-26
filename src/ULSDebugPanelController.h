/*
 * ULS Debug Panel Controller
 * Provides device debugging and diagnostics interface
 *
 * Features:
 * - Live status: USB connection state, firmware version, X/Y/Z position, error flags
 * - Command console: hex input field, scrollable USB traffic log, Send/Clear buttons
 * - Export log button (saves .txt)
 * - No laser firing from this panel (safety)
 *
 * Copyright (c) 2026 Contributors - MIT License
 */

#import <Cocoa/Cocoa.h>
#include "uls_usb.h"

@interface ULSDebugPanelController : NSObject

/* Device reference (weak, managed by main controller) */
@property (assign, nonatomic) ULSDevice *device;
@property (assign, nonatomic, readonly) BOOL isConnected;

/* Main view containing all debug UI */
@property (strong, nonatomic, readonly) NSView *view;

/* Status labels */
@property (strong, nonatomic, readonly) NSTextField *connectionStatusLabel;
@property (strong, nonatomic, readonly) NSTextField *firmwareVersionLabel;
@property (strong, nonatomic, readonly) NSTextField *positionLabel;
@property (strong, nonatomic, readonly) NSTextField *deviceStateLabel;
@property (strong, nonatomic, readonly) NSTextField *errorFlagsLabel;

/* Command console */
@property (strong, nonatomic, readonly) NSTextField *hexInputField;
@property (strong, nonatomic, readonly) NSTextView *trafficLogView;
@property (strong, nonatomic, readonly) NSScrollView *trafficLogScrollView;
@property (strong, nonatomic, readonly) NSButton *sendButton;
@property (strong, nonatomic, readonly) NSButton *clearLogButton;
@property (strong, nonatomic, readonly) NSButton *exportLogButton;

/* Refresh timer */
@property (strong, nonatomic) NSTimer *refreshTimer;

/* Initialize with default UI */
- (instancetype)init;

/* Update device connection */
- (void)setDevice:(ULSDevice *)device;

/* Start/stop automatic status refresh */
- (void)startAutoRefresh;
- (void)stopAutoRefresh;

/* Manual status refresh */
- (void)refreshStatus;

/* Command console actions */
- (void)sendHexCommand:(id)sender;
- (void)clearLog:(id)sender;
- (void)exportLog:(id)sender;

/* Log a message to the traffic log */
- (void)logMessage:(NSString *)message;
- (void)logSentData:(const uint8_t *)data length:(size_t)length;
- (void)logReceivedData:(const uint8_t *)data length:(size_t)length;

@end
