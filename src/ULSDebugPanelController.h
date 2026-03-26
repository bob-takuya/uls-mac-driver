/*
 * ULS Debug Panel Controller - Enhanced Diagnostics Interface
 * Provides comprehensive device debugging and first-connection diagnostics
 *
 * Features:
 * - Diagnostic Checklist Panel: Real-time color-coded step tracking
 * - USB Traffic Log: Timestamped, decoded hex traffic with ring buffer
 * - Live Status Bar: Continuous position/state polling
 * - Run Diagnostics: Sequential test with exportable report
 *
 * Copyright (c) 2026 Contributors - MIT License
 */

#import <Cocoa/Cocoa.h>
#include "uls_usb.h"
#include "uls_job.h"

/* Diagnostic step states */
typedef NS_ENUM(NSInteger, ULSDiagnosticState) {
    ULSDiagnosticStateNotStarted = 0,   /* Grey - not started */
    ULSDiagnosticStateInProgress,        /* Yellow - in progress */
    ULSDiagnosticStateSuccess,           /* Green - success */
    ULSDiagnosticStateFailed             /* Red - failed */
};

/* Diagnostic step identifiers */
typedef NS_ENUM(NSInteger, ULSDiagnosticStep) {
    ULSDiagStepIOKitLoaded = 0,
    ULSDiagStepUSBDeviceSearch,
    ULSDiagStepDeviceFound,
    ULSDiagStepInterfaceOpened,
    ULSDiagStepInterfaceClaimed,
    ULSDiagStepBulkEndpointsFound,
    ULSDiagStepFirmwareQuery,
    ULSDiagStepStatusQuery,
    ULSDiagStepPositionQuery,
    ULSDiagStepJobCompile,
    ULSDiagStepJobSend,
    ULSDiagStepCount
};

/* Single diagnostic step info */
@interface ULSDiagnosticStepInfo : NSObject
@property (nonatomic, assign) ULSDiagnosticStep step;
@property (nonatomic, assign) ULSDiagnosticState state;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;       /* Additional info (e.g., PID, error code) */
@property (nonatomic, assign) ULSError errorCode;
@property (nonatomic, copy) NSDate *timestamp;
@end

/* Traffic log entry */
@interface ULSTrafficLogEntry : NSObject
@property (nonatomic, copy) NSDate *timestamp;
@property (nonatomic, assign) BOOL isOutgoing;      /* YES = TX (outgoing), NO = RX (incoming) */
@property (nonatomic, strong) NSData *data;
@property (nonatomic, copy) NSString *decodedMeaning;
@property (nonatomic, assign) ULSError result;
@end

@interface ULSDebugPanelController : NSObject <NSTableViewDelegate, NSTableViewDataSource>

/* Device reference (weak, managed by main controller) */
@property (assign, nonatomic) ULSDevice *device;
@property (assign, nonatomic, readonly) BOOL isConnected;

/* Main view containing all debug UI */
@property (strong, nonatomic, readonly) NSView *view;

/* === Diagnostic Checklist Panel (top) === */
@property (strong, nonatomic, readonly) NSTableView *diagnosticTableView;
@property (strong, nonatomic, readonly) NSMutableArray<ULSDiagnosticStepInfo *> *diagnosticSteps;
@property (strong, nonatomic, readonly) NSButton *runDiagnosticsButton;
@property (strong, nonatomic, readonly) NSProgressIndicator *diagnosticsProgress;
@property (assign, nonatomic, readonly) BOOL isDiagnosticsRunning;

/* === USB Traffic Log (middle) === */
@property (strong, nonatomic, readonly) NSTableView *trafficTableView;
@property (strong, nonatomic, readonly) NSMutableArray<ULSTrafficLogEntry *> *trafficLog;
@property (strong, nonatomic, readonly) NSScrollView *trafficScrollView;
@property (strong, nonatomic, readonly) NSButton *clearLogButton;
@property (strong, nonatomic, readonly) NSButton *exportLogButton;
@property (strong, nonatomic, readonly) NSButton *autoScrollToggle;
@property (assign, nonatomic) BOOL autoScrollEnabled;

/* === Live Status Bar (bottom) === */
@property (strong, nonatomic, readonly) NSView *statusBarView;
@property (strong, nonatomic, readonly) NSTextField *usbStatusLabel;
@property (strong, nonatomic, readonly) NSTextField *positionLabel;
@property (strong, nonatomic, readonly) NSTextField *stateLabel;
@property (strong, nonatomic, readonly) NSTextField *lastErrorLabel;

/* === Command Console === */
@property (strong, nonatomic, readonly) NSTextField *hexInputField;
@property (strong, nonatomic, readonly) NSButton *sendButton;

/* Refresh timer */
@property (strong, nonatomic) NSTimer *refreshTimer;

/* Traffic log ring buffer settings */
@property (assign, nonatomic) NSUInteger maxTrafficLogEntries;  /* Default: 1000 */

/* Initialize with default UI */
- (instancetype)init;

/* Update device connection */
- (void)setDevice:(ULSDevice *)device;

/* Start/stop automatic status refresh (500ms interval) */
- (void)startAutoRefresh;
- (void)stopAutoRefresh;

/* Manual status refresh */
- (void)refreshStatus;

/* === Diagnostic Checklist === */
- (void)resetDiagnostics;
- (void)setDiagnosticStep:(ULSDiagnosticStep)step state:(ULSDiagnosticState)state;
- (void)setDiagnosticStep:(ULSDiagnosticStep)step state:(ULSDiagnosticState)state detail:(NSString *)detail;
- (void)setDiagnosticStep:(ULSDiagnosticStep)step state:(ULSDiagnosticState)state error:(ULSError)error;
- (IBAction)runDiagnostics:(id)sender;

/* === Traffic Log === */
- (void)logTrafficOutgoing:(const uint8_t *)data length:(size_t)length result:(ULSError)result;
- (void)logTrafficIncoming:(const uint8_t *)data length:(size_t)length result:(ULSError)result;
- (void)logMessage:(NSString *)message;
- (IBAction)clearLog:(id)sender;
- (IBAction)exportLog:(id)sender;
- (IBAction)toggleAutoScroll:(id)sender;

/* === Command Console === */
- (IBAction)sendHexCommand:(id)sender;

/* === Diagnostic Report === */
- (NSString *)generateDiagnosticReport;
- (IBAction)copyDiagnosticReport:(id)sender;
- (IBAction)saveDiagnosticReport:(id)sender;

/* USB traffic callback (called from C layer) */
- (void)usbTrafficCallback:(ULSLogDirection)direction
                      data:(const uint8_t *)data
                    length:(size_t)length
                    result:(ULSError)result;

@end
