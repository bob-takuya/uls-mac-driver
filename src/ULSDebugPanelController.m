/*
 * ULS Debug Panel Controller - Enhanced Diagnostics Implementation
 * Comprehensive device debugging and first-connection diagnostics
 *
 * Copyright (c) 2026 Contributors - MIT License
 */

#import "ULSDebugPanelController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/* Helper macro for Auto Layout */
#define ALOFF(v) (v).translatesAutoresizingMaskIntoConstraints = NO

/* Constants */
#define DEBUG_REFRESH_INTERVAL 0.5
#define MAX_TRAFFIC_LOG_ENTRIES 1000
#define TRAFFIC_LOG_HEX_BYTES_PER_LINE 16

/* C callback bridge - forward declaration */
static void usb_log_callback_bridge(ULSLogDirection direction, const uint8_t *data,
                                     size_t length, ULSError result, void *userContext);

/* Global reference for C callback */
static ULSDebugPanelController *gActiveDebugPanel = nil;

#pragma mark - ULSDiagnosticStepInfo Implementation

@implementation ULSDiagnosticStepInfo
- (instancetype)initWithStep:(ULSDiagnosticStep)step name:(NSString *)name {
    self = [super init];
    if (self) {
        _step = step;
        _name = [name copy];
        _state = ULSDiagnosticStateNotStarted;
        _detail = @"";
        _errorCode = ULS_SUCCESS;
    }
    return self;
}
@end

#pragma mark - ULSTrafficLogEntry Implementation

@implementation ULSTrafficLogEntry
- (instancetype)init {
    self = [super init];
    if (self) {
        _timestamp = [NSDate date];
    }
    return self;
}
@end

#pragma mark - ULSDebugPanelController Implementation

@implementation ULSDebugPanelController {
    /* Private ivars */
    NSView *_view;

    /* Diagnostic checklist */
    NSTableView *_diagnosticTableView;
    NSScrollView *_diagnosticScrollView;
    NSMutableArray<ULSDiagnosticStepInfo *> *_diagnosticSteps;
    NSButton *_runDiagnosticsButton;
    NSProgressIndicator *_diagnosticsProgress;
    BOOL _isDiagnosticsRunning;

    /* Traffic log */
    NSTableView *_trafficTableView;
    NSScrollView *_trafficScrollView;
    NSMutableArray<ULSTrafficLogEntry *> *_trafficLog;
    NSButton *_clearLogButton;
    NSButton *_exportLogButton;
    NSButton *_autoScrollToggle;

    /* Status bar */
    NSView *_statusBarView;
    NSTextField *_usbStatusLabel;
    NSTextField *_positionLabel;
    NSTextField *_stateLabel;
    NSTextField *_lastErrorLabel;

    /* Command console */
    NSTextField *_hexInputField;
    NSButton *_sendButton;

    /* Internal state */
    NSDateFormatter *_timestampFormatter;
    NSDateFormatter *_fullTimestampFormatter;
    ULSError _lastError;
    NSString *_lastErrorString;
}

#pragma mark - Properties

- (NSView *)view { return _view; }
- (NSTableView *)diagnosticTableView { return _diagnosticTableView; }
- (NSMutableArray<ULSDiagnosticStepInfo *> *)diagnosticSteps { return _diagnosticSteps; }
- (NSButton *)runDiagnosticsButton { return _runDiagnosticsButton; }
- (NSProgressIndicator *)diagnosticsProgress { return _diagnosticsProgress; }
- (BOOL)isDiagnosticsRunning { return _isDiagnosticsRunning; }
- (NSTableView *)trafficTableView { return _trafficTableView; }
- (NSMutableArray<ULSTrafficLogEntry *> *)trafficLog { return _trafficLog; }
- (NSScrollView *)trafficScrollView { return _trafficScrollView; }
- (NSButton *)clearLogButton { return _clearLogButton; }
- (NSButton *)exportLogButton { return _exportLogButton; }
- (NSButton *)autoScrollToggle { return _autoScrollToggle; }
- (NSView *)statusBarView { return _statusBarView; }
- (NSTextField *)usbStatusLabel { return _usbStatusLabel; }
- (NSTextField *)positionLabel { return _positionLabel; }
- (NSTextField *)stateLabel { return _stateLabel; }
- (NSTextField *)lastErrorLabel { return _lastErrorLabel; }
- (NSTextField *)hexInputField { return _hexInputField; }
- (NSButton *)sendButton { return _sendButton; }

- (BOOL)isConnected {
    return _device != NULL && _device->isOpen;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxTrafficLogEntries = MAX_TRAFFIC_LOG_ENTRIES;
        _autoScrollEnabled = YES;
        _lastError = ULS_SUCCESS;
        _lastErrorString = @"None";

        /* Timestamp formatters */
        _timestampFormatter = [[NSDateFormatter alloc] init];
        _timestampFormatter.dateFormat = @"HH:mm:ss.SSS";

        _fullTimestampFormatter = [[NSDateFormatter alloc] init];
        _fullTimestampFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";

        /* Initialize diagnostic steps */
        [self initializeDiagnosticSteps];

        /* Initialize traffic log */
        _trafficLog = [NSMutableArray array];

        /* Setup UI */
        [self setupUI];

        /* Register as active debug panel for callbacks */
        gActiveDebugPanel = self;
    }
    return self;
}

- (void)dealloc {
    [self stopAutoRefresh];
    uls_clear_log_callback();
    if (gActiveDebugPanel == self) {
        gActiveDebugPanel = nil;
    }
}

- (void)initializeDiagnosticSteps {
    _diagnosticSteps = [NSMutableArray array];

    NSArray *stepNames = @[
        @"1. IOKit framework loaded",
        @"2. USB device search (vendor 0x10C3)",
        @"3. Device found",
        @"4. Device interface opened",
        @"5. Interface claimed",
        @"6. Bulk endpoints found (EP_OUT 0x02, EP_IN 0x81)",
        @"7. Firmware version query",
        @"8. Status query",
        @"9. Position query",
        @"10. Job compile",
        @"11. Job send"
    ];

    for (NSUInteger i = 0; i < stepNames.count; i++) {
        ULSDiagnosticStepInfo *info = [[ULSDiagnosticStepInfo alloc]
                                        initWithStep:(ULSDiagnosticStep)i
                                        name:stepNames[i]];
        [_diagnosticSteps addObject:info];
    }
}

#pragma mark - UI Setup

- (NSTextField *)makeLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    ALOFF(label);
    return label;
}

- (NSTextField *)makeBoldLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont boldSystemFontOfSize:12];
    ALOFF(label);
    return label;
}

- (NSTextField *)makeMonoLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    ALOFF(label);
    return label;
}

- (NSButton *)makeButton:(NSString *)title action:(SEL)action {
    NSButton *btn = [NSButton buttonWithTitle:title target:self action:action];
    ALOFF(btn);
    return btn;
}

- (void)setupUI {
    /* Main container view */
    _view = [[NSView alloc] init];
    ALOFF(_view);

    /* === Diagnostic Checklist Panel (top) === */
    NSBox *diagnosticBox = [[NSBox alloc] init];
    diagnosticBox.title = @"Diagnostic Checklist";
    diagnosticBox.boxType = NSBoxPrimary;
    ALOFF(diagnosticBox);
    [_view addSubview:diagnosticBox];

    NSView *diagnosticContent = [[NSView alloc] init];
    ALOFF(diagnosticContent);
    diagnosticBox.contentView = diagnosticContent;

    [self setupDiagnosticTableInView:diagnosticContent];

    /* Run Diagnostics button and progress */
    _runDiagnosticsButton = [self makeButton:@"Run Diagnostics" action:@selector(runDiagnostics:)];
    _runDiagnosticsButton.bezelStyle = NSBezelStyleRounded;
    [diagnosticContent addSubview:_runDiagnosticsButton];

    _diagnosticsProgress = [[NSProgressIndicator alloc] init];
    _diagnosticsProgress.style = NSProgressIndicatorStyleBar;
    _diagnosticsProgress.indeterminate = NO;
    _diagnosticsProgress.minValue = 0;
    _diagnosticsProgress.maxValue = ULSDiagStepCount;
    _diagnosticsProgress.hidden = YES;
    ALOFF(_diagnosticsProgress);
    [diagnosticContent addSubview:_diagnosticsProgress];

    NSButton *copyReportButton = [self makeButton:@"Copy Report" action:@selector(copyDiagnosticReport:)];
    [diagnosticContent addSubview:copyReportButton];

    NSButton *saveReportButton = [self makeButton:@"Save Report..." action:@selector(saveDiagnosticReport:)];
    [diagnosticContent addSubview:saveReportButton];

    /* === USB Traffic Log (middle) === */
    NSBox *trafficBox = [[NSBox alloc] init];
    trafficBox.title = @"USB Traffic Log";
    trafficBox.boxType = NSBoxPrimary;
    ALOFF(trafficBox);
    [_view addSubview:trafficBox];

    NSView *trafficContent = [[NSView alloc] init];
    ALOFF(trafficContent);
    trafficBox.contentView = trafficContent;

    [self setupTrafficLogInView:trafficContent];

    /* === Command Console === */
    NSBox *consoleBox = [[NSBox alloc] init];
    consoleBox.title = @"Command Console";
    consoleBox.boxType = NSBoxPrimary;
    ALOFF(consoleBox);
    [_view addSubview:consoleBox];

    NSView *consoleContent = [[NSView alloc] init];
    ALOFF(consoleContent);
    consoleBox.contentView = consoleContent;

    [self setupCommandConsoleInView:consoleContent];

    /* === Live Status Bar (bottom) === */
    [self setupStatusBar];
    [_view addSubview:_statusBarView];

    /* === Main Layout === */
    [NSLayoutConstraint activateConstraints:@[
        /* Diagnostic panel at top */
        [diagnosticBox.topAnchor constraintEqualToAnchor:_view.topAnchor constant:8],
        [diagnosticBox.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],
        [diagnosticBox.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],
        [diagnosticBox.heightAnchor constraintEqualToConstant:280],

        /* Traffic log in middle */
        [trafficBox.topAnchor constraintEqualToAnchor:diagnosticBox.bottomAnchor constant:8],
        [trafficBox.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],
        [trafficBox.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],

        /* Console below traffic */
        [consoleBox.topAnchor constraintEqualToAnchor:trafficBox.bottomAnchor constant:8],
        [consoleBox.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],
        [consoleBox.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],
        [consoleBox.heightAnchor constraintEqualToConstant:80],

        /* Status bar at bottom */
        [_statusBarView.topAnchor constraintEqualToAnchor:consoleBox.bottomAnchor constant:8],
        [_statusBarView.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],
        [_statusBarView.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],
        [_statusBarView.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-8],
        [_statusBarView.heightAnchor constraintEqualToConstant:60],

        /* Diagnostic content layout */
        [_diagnosticScrollView.topAnchor constraintEqualToAnchor:diagnosticContent.topAnchor constant:8],
        [_diagnosticScrollView.leadingAnchor constraintEqualToAnchor:diagnosticContent.leadingAnchor constant:8],
        [_diagnosticScrollView.trailingAnchor constraintEqualToAnchor:diagnosticContent.trailingAnchor constant:-8],
        [_diagnosticScrollView.bottomAnchor constraintEqualToAnchor:_runDiagnosticsButton.topAnchor constant:-8],

        [_runDiagnosticsButton.leadingAnchor constraintEqualToAnchor:diagnosticContent.leadingAnchor constant:8],
        [_runDiagnosticsButton.bottomAnchor constraintEqualToAnchor:diagnosticContent.bottomAnchor constant:-8],
        [_runDiagnosticsButton.widthAnchor constraintEqualToConstant:120],

        [_diagnosticsProgress.leadingAnchor constraintEqualToAnchor:_runDiagnosticsButton.trailingAnchor constant:8],
        [_diagnosticsProgress.centerYAnchor constraintEqualToAnchor:_runDiagnosticsButton.centerYAnchor],
        [_diagnosticsProgress.widthAnchor constraintEqualToConstant:150],

        [copyReportButton.trailingAnchor constraintEqualToAnchor:saveReportButton.leadingAnchor constant:-8],
        [copyReportButton.centerYAnchor constraintEqualToAnchor:_runDiagnosticsButton.centerYAnchor],

        [saveReportButton.trailingAnchor constraintEqualToAnchor:diagnosticContent.trailingAnchor constant:-8],
        [saveReportButton.centerYAnchor constraintEqualToAnchor:_runDiagnosticsButton.centerYAnchor],
    ]];

    [self logMessage:@"Debug panel initialized. Connect to a device to start monitoring."];
}

- (void)setupDiagnosticTableInView:(NSView *)container {
    _diagnosticScrollView = [[NSScrollView alloc] init];
    _diagnosticScrollView.hasVerticalScroller = YES;
    _diagnosticScrollView.borderType = NSBezelBorder;
    ALOFF(_diagnosticScrollView);
    [container addSubview:_diagnosticScrollView];

    _diagnosticTableView = [[NSTableView alloc] init];
    _diagnosticTableView.usesAlternatingRowBackgroundColors = YES;
    _diagnosticTableView.rowHeight = 22;

    /* Status column (icon) */
    NSTableColumn *statusCol = [[NSTableColumn alloc] initWithIdentifier:@"status"];
    statusCol.title = @"";
    statusCol.width = 30;
    statusCol.minWidth = 30;
    statusCol.maxWidth = 30;
    [_diagnosticTableView addTableColumn:statusCol];

    /* Step name column */
    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"Step";
    nameCol.width = 280;
    nameCol.minWidth = 200;
    [_diagnosticTableView addTableColumn:nameCol];

    /* Detail column */
    NSTableColumn *detailCol = [[NSTableColumn alloc] initWithIdentifier:@"detail"];
    detailCol.title = @"Details";
    detailCol.width = 250;
    detailCol.minWidth = 100;
    [_diagnosticTableView addTableColumn:detailCol];

    _diagnosticTableView.delegate = self;
    _diagnosticTableView.dataSource = self;

    _diagnosticScrollView.documentView = _diagnosticTableView;
}

- (void)setupTrafficLogInView:(NSView *)container {
    _trafficScrollView = [[NSScrollView alloc] init];
    _trafficScrollView.hasVerticalScroller = YES;
    _trafficScrollView.hasHorizontalScroller = YES;
    _trafficScrollView.borderType = NSBezelBorder;
    ALOFF(_trafficScrollView);
    [container addSubview:_trafficScrollView];

    _trafficTableView = [[NSTableView alloc] init];
    _trafficTableView.usesAlternatingRowBackgroundColors = YES;
    _trafficTableView.rowHeight = 18;
    _trafficTableView.allowsColumnReordering = NO;

    /* Timestamp column */
    NSTableColumn *timeCol = [[NSTableColumn alloc] initWithIdentifier:@"time"];
    timeCol.title = @"Time";
    timeCol.width = 90;
    timeCol.minWidth = 90;
    [_trafficTableView addTableColumn:timeCol];

    /* Direction column */
    NSTableColumn *dirCol = [[NSTableColumn alloc] initWithIdentifier:@"dir"];
    dirCol.title = @"Dir";
    dirCol.width = 30;
    dirCol.minWidth = 30;
    [_trafficTableView addTableColumn:dirCol];

    /* Hex dump column */
    NSTableColumn *hexCol = [[NSTableColumn alloc] initWithIdentifier:@"hex"];
    hexCol.title = @"Data (Hex)";
    hexCol.width = 300;
    hexCol.minWidth = 100;
    [_trafficTableView addTableColumn:hexCol];

    /* Decoded meaning column */
    NSTableColumn *meaningCol = [[NSTableColumn alloc] initWithIdentifier:@"meaning"];
    meaningCol.title = @"Decoded";
    meaningCol.width = 200;
    meaningCol.minWidth = 80;
    [_trafficTableView addTableColumn:meaningCol];

    _trafficTableView.delegate = self;
    _trafficTableView.dataSource = self;

    _trafficScrollView.documentView = _trafficTableView;

    /* Buttons row */
    _clearLogButton = [self makeButton:@"Clear" action:@selector(clearLog:)];
    [container addSubview:_clearLogButton];

    _exportLogButton = [self makeButton:@"Export..." action:@selector(exportLog:)];
    [container addSubview:_exportLogButton];

    _autoScrollToggle = [NSButton checkboxWithTitle:@"Auto-scroll" target:self action:@selector(toggleAutoScroll:)];
    _autoScrollToggle.state = NSControlStateValueOn;
    ALOFF(_autoScrollToggle);
    [container addSubview:_autoScrollToggle];

    [NSLayoutConstraint activateConstraints:@[
        [_trafficScrollView.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [_trafficScrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [_trafficScrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [_trafficScrollView.bottomAnchor constraintEqualToAnchor:_clearLogButton.topAnchor constant:-8],
        [_trafficScrollView.heightAnchor constraintGreaterThanOrEqualToConstant:120],

        [_clearLogButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [_clearLogButton.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        [_exportLogButton.leadingAnchor constraintEqualToAnchor:_clearLogButton.trailingAnchor constant:8],
        [_exportLogButton.centerYAnchor constraintEqualToAnchor:_clearLogButton.centerYAnchor],

        [_autoScrollToggle.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [_autoScrollToggle.centerYAnchor constraintEqualToAnchor:_clearLogButton.centerYAnchor],
    ]];
}

- (void)setupCommandConsoleInView:(NSView *)container {
    NSTextField *hexLabel = [self makeLabel:@"Hex Command:"];
    [container addSubview:hexLabel];

    _hexInputField = [[NSTextField alloc] init];
    _hexInputField.placeholderString = @"01 02 03 04 (space-separated hex bytes)";
    _hexInputField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    ALOFF(_hexInputField);
    [container addSubview:_hexInputField];

    _sendButton = [self makeButton:@"Send" action:@selector(sendHexCommand:)];
    _sendButton.bezelStyle = NSBezelStyleRounded;
    [container addSubview:_sendButton];

    NSTextField *warningLabel = [self makeLabel:@"Note: Laser firing commands (0x04, 0x05) are blocked for safety."];
    warningLabel.textColor = [NSColor systemOrangeColor];
    warningLabel.font = [NSFont systemFontOfSize:10];
    [container addSubview:warningLabel];

    [NSLayoutConstraint activateConstraints:@[
        [hexLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [hexLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],

        [_hexInputField.centerYAnchor constraintEqualToAnchor:hexLabel.centerYAnchor],
        [_hexInputField.leadingAnchor constraintEqualToAnchor:hexLabel.trailingAnchor constant:8],
        [_hexInputField.trailingAnchor constraintEqualToAnchor:_sendButton.leadingAnchor constant:-8],

        [_sendButton.centerYAnchor constraintEqualToAnchor:hexLabel.centerYAnchor],
        [_sendButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [_sendButton.widthAnchor constraintEqualToConstant:60],

        [warningLabel.topAnchor constraintEqualToAnchor:hexLabel.bottomAnchor constant:4],
        [warningLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [warningLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
    ]];
}

- (void)setupStatusBar {
    _statusBarView = [[NSView alloc] init];
    _statusBarView.wantsLayer = YES;
    _statusBarView.layer.backgroundColor = [[NSColor controlBackgroundColor] CGColor];
    _statusBarView.layer.cornerRadius = 6;
    _statusBarView.layer.borderWidth = 1;
    _statusBarView.layer.borderColor = [[NSColor separatorColor] CGColor];
    ALOFF(_statusBarView);

    /* USB status */
    NSTextField *usbTitle = [self makeBoldLabel:@"USB:"];
    [_statusBarView addSubview:usbTitle];

    _usbStatusLabel = [self makeMonoLabel:@"Disconnected"];
    _usbStatusLabel.textColor = [NSColor systemRedColor];
    [_statusBarView addSubview:_usbStatusLabel];

    /* Position */
    NSTextField *posTitle = [self makeBoldLabel:@"Position:"];
    [_statusBarView addSubview:posTitle];

    _positionLabel = [self makeMonoLabel:@"X=-.---\" Y=-.---\" Z=-.---\""];
    [_statusBarView addSubview:_positionLabel];

    /* State */
    NSTextField *stateTitle = [self makeBoldLabel:@"State:"];
    [_statusBarView addSubview:stateTitle];

    _stateLabel = [self makeMonoLabel:@"--"];
    [_statusBarView addSubview:_stateLabel];

    /* Last error */
    NSTextField *errorTitle = [self makeBoldLabel:@"Last Error:"];
    [_statusBarView addSubview:errorTitle];

    _lastErrorLabel = [self makeMonoLabel:@"None"];
    [_statusBarView addSubview:_lastErrorLabel];

    [NSLayoutConstraint activateConstraints:@[
        /* First row */
        [usbTitle.topAnchor constraintEqualToAnchor:_statusBarView.topAnchor constant:8],
        [usbTitle.leadingAnchor constraintEqualToAnchor:_statusBarView.leadingAnchor constant:12],

        [_usbStatusLabel.centerYAnchor constraintEqualToAnchor:usbTitle.centerYAnchor],
        [_usbStatusLabel.leadingAnchor constraintEqualToAnchor:usbTitle.trailingAnchor constant:4],

        [posTitle.centerYAnchor constraintEqualToAnchor:usbTitle.centerYAnchor],
        [posTitle.leadingAnchor constraintEqualToAnchor:_usbStatusLabel.trailingAnchor constant:20],

        [_positionLabel.centerYAnchor constraintEqualToAnchor:posTitle.centerYAnchor],
        [_positionLabel.leadingAnchor constraintEqualToAnchor:posTitle.trailingAnchor constant:4],

        /* Second row */
        [stateTitle.topAnchor constraintEqualToAnchor:usbTitle.bottomAnchor constant:6],
        [stateTitle.leadingAnchor constraintEqualToAnchor:_statusBarView.leadingAnchor constant:12],

        [_stateLabel.centerYAnchor constraintEqualToAnchor:stateTitle.centerYAnchor],
        [_stateLabel.leadingAnchor constraintEqualToAnchor:stateTitle.trailingAnchor constant:4],

        [errorTitle.centerYAnchor constraintEqualToAnchor:stateTitle.centerYAnchor],
        [errorTitle.leadingAnchor constraintEqualToAnchor:_stateLabel.trailingAnchor constant:20],

        [_lastErrorLabel.centerYAnchor constraintEqualToAnchor:errorTitle.centerYAnchor],
        [_lastErrorLabel.leadingAnchor constraintEqualToAnchor:errorTitle.trailingAnchor constant:4],
    ]];
}

#pragma mark - Device Management

- (void)setDevice:(ULSDevice *)device {
    _device = device;

    if (device) {
        [self logMessage:[NSString stringWithFormat:@"Device connected: %s (PID: 0x%04X)",
                          uls_model_string(device->info.model), device->info.productId]];

        /* Register USB traffic logging callback */
        uls_set_log_callback(usb_log_callback_bridge, (__bridge void *)self);

        /* Start auto-refresh */
        [self startAutoRefresh];
    } else {
        [self logMessage:@"Device disconnected"];
        uls_clear_log_callback();
        [self stopAutoRefresh];
    }

    [self refreshStatus];
}

#pragma mark - Auto Refresh

- (void)startAutoRefresh {
    if (self.refreshTimer) return;

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:DEBUG_REFRESH_INTERVAL
                                                         target:self
                                                       selector:@selector(refreshStatus)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)stopAutoRefresh {
    if (self.refreshTimer) {
        [self.refreshTimer invalidate];
        self.refreshTimer = nil;
    }
}

#pragma mark - Status Refresh

- (void)refreshStatus {
    if (!self.isConnected) {
        _usbStatusLabel.stringValue = @"Disconnected";
        _usbStatusLabel.textColor = [NSColor systemRedColor];
        _positionLabel.stringValue = @"X=-.---\" Y=-.---\" Z=-.---\"";
        _positionLabel.textColor = [NSColor secondaryLabelColor];
        _stateLabel.stringValue = @"--";
        _stateLabel.textColor = [NSColor secondaryLabelColor];
        _sendButton.enabled = NO;
        return;
    }

    /* USB status */
    _usbStatusLabel.stringValue = [NSString stringWithFormat:@"Connected (%s)",
                                   uls_model_string(_device->info.model)];
    _usbStatusLabel.textColor = [NSColor systemGreenColor];
    _sendButton.enabled = YES;

    /* Position */
    float x = 0, y = 0, z = 0;
    ULSError err = uls_get_position(_device, &x, &y, &z);
    if (err == ULS_SUCCESS) {
        _positionLabel.stringValue = [NSString stringWithFormat:@"X=%.3f\" Y=%.3f\" Z=%.3f\"", x, y, z];
        _positionLabel.textColor = [NSColor labelColor];
    } else {
        _positionLabel.stringValue = @"X=?.???\" Y=?.???\" Z=?.???\"";
        _positionLabel.textColor = [NSColor systemOrangeColor];
        [self recordError:err];
    }

    /* Device state */
    ULSDeviceState state = ULS_STATE_DISCONNECTED;
    err = uls_get_status(_device, &state);
    if (err == ULS_SUCCESS) {
        _stateLabel.stringValue = [NSString stringWithUTF8String:uls_state_string(state)];

        switch (state) {
            case ULS_STATE_READY:
                _stateLabel.textColor = [NSColor systemGreenColor];
                break;
            case ULS_STATE_BUSY:
                _stateLabel.textColor = [NSColor systemOrangeColor];
                break;
            case ULS_STATE_ERROR:
                _stateLabel.textColor = [NSColor systemRedColor];
                break;
            case ULS_STATE_BOOTLOADER:
                _stateLabel.textColor = [NSColor systemPurpleColor];
                break;
            default:
                _stateLabel.textColor = [NSColor secondaryLabelColor];
                break;
        }
    } else {
        _stateLabel.stringValue = @"Unknown";
        _stateLabel.textColor = [NSColor secondaryLabelColor];
        [self recordError:err];
    }
}

- (void)recordError:(ULSError)error {
    if (error != ULS_SUCCESS) {
        _lastError = error;
        _lastErrorString = [NSString stringWithFormat:@"%d: %s", error, uls_error_string(error)];
        _lastErrorLabel.stringValue = _lastErrorString;
        _lastErrorLabel.textColor = [NSColor systemRedColor];
    }
}

#pragma mark - Diagnostic Checklist

- (void)resetDiagnostics {
    for (ULSDiagnosticStepInfo *info in _diagnosticSteps) {
        info.state = ULSDiagnosticStateNotStarted;
        info.detail = @"";
        info.errorCode = ULS_SUCCESS;
        info.timestamp = nil;
    }
    [_diagnosticTableView reloadData];
}

- (void)setDiagnosticStep:(ULSDiagnosticStep)step state:(ULSDiagnosticState)state {
    [self setDiagnosticStep:step state:state detail:nil];
}

- (void)setDiagnosticStep:(ULSDiagnosticStep)step state:(ULSDiagnosticState)state detail:(NSString *)detail {
    if (step >= _diagnosticSteps.count) return;

    ULSDiagnosticStepInfo *info = _diagnosticSteps[step];
    info.state = state;
    info.timestamp = [NSDate date];
    if (detail) info.detail = detail;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_diagnosticTableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:step]
                                              columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 3)]];
        self->_diagnosticsProgress.doubleValue = step + 1;
    });
}

- (void)setDiagnosticStep:(ULSDiagnosticStep)step state:(ULSDiagnosticState)state error:(ULSError)error {
    NSString *detail = [NSString stringWithFormat:@"Error %d: %s", error, uls_error_string(error)];
    [self setDiagnosticStep:step state:state detail:detail];

    if (step < _diagnosticSteps.count) {
        _diagnosticSteps[step].errorCode = error;
    }
}

- (IBAction)runDiagnostics:(id)sender {
    if (_isDiagnosticsRunning) return;

    _isDiagnosticsRunning = YES;
    _runDiagnosticsButton.enabled = NO;
    _diagnosticsProgress.hidden = NO;
    _diagnosticsProgress.doubleValue = 0;

    [self resetDiagnostics];
    [self logMessage:@"=== Starting Diagnostics ==="];

    /* Run diagnostics on background thread */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runDiagnosticsSequence];

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_isDiagnosticsRunning = NO;
            self->_runDiagnosticsButton.enabled = YES;
            self->_diagnosticsProgress.hidden = YES;
            [self logMessage:@"=== Diagnostics Complete ==="];
        });
    });
}

- (void)runDiagnosticsSequence {
    /* Step 1: IOKit framework loaded */
    [self setDiagnosticStep:ULSDiagStepIOKitLoaded state:ULSDiagnosticStateInProgress];
    /* IOKit is always available if we compiled successfully */
    [self setDiagnosticStep:ULSDiagStepIOKitLoaded state:ULSDiagnosticStateSuccess
                     detail:@"IOKit.framework available"];

    /* Step 2: USB device search */
    [self setDiagnosticStep:ULSDiagStepUSBDeviceSearch state:ULSDiagnosticStateInProgress];
    ULSDeviceInfo *devices = NULL;
    int deviceCount = 0;
    ULSError err = uls_find_devices(&devices, &deviceCount);

    if (err == ULS_SUCCESS && deviceCount > 0) {
        [self setDiagnosticStep:ULSDiagStepUSBDeviceSearch state:ULSDiagnosticStateSuccess
                         detail:[NSString stringWithFormat:@"Found %d device(s)", deviceCount]];
    } else if (err == ULS_ERROR_NOT_FOUND) {
        [self setDiagnosticStep:ULSDiagStepUSBDeviceSearch state:ULSDiagnosticStateFailed
                         detail:@"No ULS devices found (vendor 0x10C3)"];
        uls_free_device_list(devices, deviceCount);
        return;
    } else {
        [self setDiagnosticStep:ULSDiagStepUSBDeviceSearch state:ULSDiagnosticStateFailed error:err];
        uls_free_device_list(devices, deviceCount);
        return;
    }

    /* Step 3: Device found */
    [self setDiagnosticStep:ULSDiagStepDeviceFound state:ULSDiagnosticStateInProgress];
    ULSDeviceInfo *firstDevice = &devices[0];
    NSString *deviceDetail = [NSString stringWithFormat:@"PID=0x%04X, Model=%s, Serial=%s",
                              firstDevice->productId,
                              uls_model_string(firstDevice->model),
                              firstDevice->serialNumber[0] ? firstDevice->serialNumber : "(none)"];
    [self setDiagnosticStep:ULSDiagStepDeviceFound state:ULSDiagnosticStateSuccess detail:deviceDetail];

    /* Steps 4-6: Only if we have a device handle */
    if (!self.isConnected) {
        /* Try to open the device */
        ULSDevice *testDevice = uls_open_device(firstDevice->vendorId, firstDevice->productId);

        if (testDevice) {
            /* Step 4: Interface opened */
            [self setDiagnosticStep:ULSDiagStepInterfaceOpened state:ULSDiagnosticStateSuccess
                             detail:@"Device interface acquired"];

            /* Step 5: Interface claimed */
            [self setDiagnosticStep:ULSDiagStepInterfaceClaimed state:ULSDiagnosticStateSuccess
                             detail:@"Interface opened successfully"];

            /* Step 6: Bulk endpoints */
            [self setDiagnosticStep:ULSDiagStepBulkEndpointsFound state:ULSDiagnosticStateInProgress];
            if (testDevice->bulkOutPipe > 0 && testDevice->bulkInPipe > 0) {
                [self setDiagnosticStep:ULSDiagStepBulkEndpointsFound state:ULSDiagnosticStateSuccess
                                 detail:[NSString stringWithFormat:@"OUT pipe=%d, IN pipe=%d",
                                         testDevice->bulkOutPipe, testDevice->bulkInPipe]];
            } else {
                [self setDiagnosticStep:ULSDiagStepBulkEndpointsFound state:ULSDiagnosticStateFailed
                                 detail:@"Bulk endpoints not found"];
            }

            /* Step 7: Firmware version */
            [self setDiagnosticStep:ULSDiagStepFirmwareQuery state:ULSDiagnosticStateInProgress];
            char version[64] = {0};
            err = uls_get_firmware_version(testDevice, version, sizeof(version));
            if (err == ULS_SUCCESS && version[0]) {
                [self setDiagnosticStep:ULSDiagStepFirmwareQuery state:ULSDiagnosticStateSuccess
                                 detail:[NSString stringWithUTF8String:version]];
            } else {
                [self setDiagnosticStep:ULSDiagStepFirmwareQuery state:ULSDiagnosticStateFailed error:err];
            }

            /* Step 8: Status query */
            [self setDiagnosticStep:ULSDiagStepStatusQuery state:ULSDiagnosticStateInProgress];
            ULSDeviceState state = ULS_STATE_DISCONNECTED;
            err = uls_get_status(testDevice, &state);
            if (err == ULS_SUCCESS) {
                [self setDiagnosticStep:ULSDiagStepStatusQuery state:ULSDiagnosticStateSuccess
                                 detail:[NSString stringWithUTF8String:uls_state_string(state)]];
            } else {
                [self setDiagnosticStep:ULSDiagStepStatusQuery state:ULSDiagnosticStateFailed error:err];
            }

            /* Step 9: Position query */
            [self setDiagnosticStep:ULSDiagStepPositionQuery state:ULSDiagnosticStateInProgress];
            float x = 0, y = 0, z = 0;
            err = uls_get_position(testDevice, &x, &y, &z);
            if (err == ULS_SUCCESS) {
                [self setDiagnosticStep:ULSDiagStepPositionQuery state:ULSDiagnosticStateSuccess
                                 detail:[NSString stringWithFormat:@"X=%.3f Y=%.3f Z=%.3f", x, y, z]];
            } else {
                [self setDiagnosticStep:ULSDiagStepPositionQuery state:ULSDiagnosticStateFailed error:err];
            }

            uls_close_device(testDevice);
        } else {
            [self setDiagnosticStep:ULSDiagStepInterfaceOpened state:ULSDiagnosticStateFailed
                             detail:@"Failed to open device interface"];
        }
    } else {
        /* Use existing device connection */
        [self setDiagnosticStep:ULSDiagStepInterfaceOpened state:ULSDiagnosticStateSuccess
                         detail:@"Already connected"];
        [self setDiagnosticStep:ULSDiagStepInterfaceClaimed state:ULSDiagnosticStateSuccess
                         detail:@"Already claimed"];

        /* Step 6: Bulk endpoints */
        if (_device->bulkOutPipe > 0 && _device->bulkInPipe > 0) {
            [self setDiagnosticStep:ULSDiagStepBulkEndpointsFound state:ULSDiagnosticStateSuccess
                             detail:[NSString stringWithFormat:@"OUT pipe=%d, IN pipe=%d",
                                     _device->bulkOutPipe, _device->bulkInPipe]];
        } else {
            [self setDiagnosticStep:ULSDiagStepBulkEndpointsFound state:ULSDiagnosticStateFailed
                             detail:@"Bulk endpoints not found"];
        }

        /* Step 7: Firmware version */
        [self setDiagnosticStep:ULSDiagStepFirmwareQuery state:ULSDiagnosticStateInProgress];
        char version[64] = {0};
        err = uls_get_firmware_version(_device, version, sizeof(version));
        if (err == ULS_SUCCESS && version[0]) {
            [self setDiagnosticStep:ULSDiagStepFirmwareQuery state:ULSDiagnosticStateSuccess
                             detail:[NSString stringWithUTF8String:version]];
        } else {
            [self setDiagnosticStep:ULSDiagStepFirmwareQuery state:ULSDiagnosticStateFailed error:err];
        }

        /* Step 8: Status query */
        [self setDiagnosticStep:ULSDiagStepStatusQuery state:ULSDiagnosticStateInProgress];
        ULSDeviceState state = ULS_STATE_DISCONNECTED;
        err = uls_get_status(_device, &state);
        if (err == ULS_SUCCESS) {
            [self setDiagnosticStep:ULSDiagStepStatusQuery state:ULSDiagnosticStateSuccess
                             detail:[NSString stringWithUTF8String:uls_state_string(state)]];
        } else {
            [self setDiagnosticStep:ULSDiagStepStatusQuery state:ULSDiagnosticStateFailed error:err];
        }

        /* Step 9: Position query */
        [self setDiagnosticStep:ULSDiagStepPositionQuery state:ULSDiagnosticStateInProgress];
        float x = 0, y = 0, z = 0;
        err = uls_get_position(_device, &x, &y, &z);
        if (err == ULS_SUCCESS) {
            [self setDiagnosticStep:ULSDiagStepPositionQuery state:ULSDiagnosticStateSuccess
                             detail:[NSString stringWithFormat:@"X=%.3f Y=%.3f Z=%.3f", x, y, z]];
        } else {
            [self setDiagnosticStep:ULSDiagStepPositionQuery state:ULSDiagnosticStateFailed error:err];
        }
    }

    /* Step 10: Job compile (test job) */
    [self setDiagnosticStep:ULSDiagStepJobCompile state:ULSDiagnosticStateInProgress];
    ULSJob *testJob = uls_job_create("diagnostic_test");
    if (testJob) {
        ULSVectorPath *path = uls_path_create();
        if (path) {
            uls_path_add_rectangle(path, 1.0f, 1.0f, 1.0f, 1.0f);
            uls_job_add_path(testJob, path);

            err = uls_job_compile(testJob);
            if (err == ULS_SUCCESS && testJob->compiledDataSize > 0) {
                [self setDiagnosticStep:ULSDiagStepJobCompile state:ULSDiagnosticStateSuccess
                                 detail:[NSString stringWithFormat:@"Compiled %zu bytes", testJob->compiledDataSize]];
            } else {
                [self setDiagnosticStep:ULSDiagStepJobCompile state:ULSDiagnosticStateFailed error:err];
            }
        }
        uls_job_destroy(testJob);
    } else {
        [self setDiagnosticStep:ULSDiagStepJobCompile state:ULSDiagnosticStateFailed
                         detail:@"Failed to create test job"];
    }

    /* Step 11: Job send (skip if no device or if previous steps failed) */
    [self setDiagnosticStep:ULSDiagStepJobSend state:ULSDiagnosticStateNotStarted
                     detail:@"Skipped (requires manual test)"];

    uls_free_device_list(devices, deviceCount);
}

#pragma mark - Traffic Log

- (void)logTrafficOutgoing:(const uint8_t *)data length:(size_t)length result:(ULSError)result {
    ULSTrafficLogEntry *entry = [[ULSTrafficLogEntry alloc] init];
    entry.isOutgoing = YES;
    entry.data = [NSData dataWithBytes:data length:length];
    entry.result = result;
    entry.decodedMeaning = [self decodeCommand:data length:length isOutgoing:YES];

    [self addTrafficEntry:entry];
}

- (void)logTrafficIncoming:(const uint8_t *)data length:(size_t)length result:(ULSError)result {
    ULSTrafficLogEntry *entry = [[ULSTrafficLogEntry alloc] init];
    entry.isOutgoing = NO;
    entry.data = [NSData dataWithBytes:data length:length];
    entry.result = result;
    entry.decodedMeaning = [self decodeCommand:data length:length isOutgoing:NO];

    [self addTrafficEntry:entry];
}

- (void)addTrafficEntry:(ULSTrafficLogEntry *)entry {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_trafficLog addObject:entry];

        /* Ring buffer: remove oldest entries if over limit */
        while (self->_trafficLog.count > self->_maxTrafficLogEntries) {
            [self->_trafficLog removeObjectAtIndex:0];
        }

        [self->_trafficTableView reloadData];

        /* Auto-scroll to bottom */
        if (self->_autoScrollEnabled && self->_trafficLog.count > 0) {
            [self->_trafficTableView scrollRowToVisible:self->_trafficLog.count - 1];
        }
    });
}

- (NSString *)decodeCommand:(const uint8_t *)data length:(size_t)length isOutgoing:(BOOL)isOutgoing {
    if (length == 0) return @"";

    if (isOutgoing) {
        const char *cmdName = uls_command_string(data[0]);
        if (cmdName) {
            NSMutableString *decoded = [NSMutableString stringWithFormat:@"%s", cmdName];

            /* Decode parameters for known commands */
            if (data[0] == ULS_CMD_SET_POWER && length >= 2) {
                [decoded appendFormat:@" %d%%", data[1]];
            } else if (data[0] == ULS_CMD_SET_SPEED && length >= 2) {
                [decoded appendFormat:@" %d%%", data[1]];
            } else if (data[0] == ULS_CMD_SET_PPI && length >= 3) {
                uint16_t ppi = (data[1] << 8) | data[2];
                [decoded appendFormat:@" %d", ppi];
            } else if (data[0] == ULS_CMD_MOVE && length >= 12) {
                int32_t x, y;
                memcpy(&x, data + 4, 4);
                memcpy(&y, data + 8, 4);
                [decoded appendFormat:@" X=%.3f Y=%.3f", x / 1000.0f, y / 1000.0f];
            }

            return decoded;
        }
    } else {
        /* Decode response */
        if (length >= 1) {
            switch (data[0]) {
                case 0x00: return @"STATUS: READY";
                case 0x01: return @"STATUS: BUSY";
                case 0xFF: return @"STATUS: ERROR";
                default: break;
            }
        }
    }

    return @"";
}

- (void)logMessage:(NSString *)message {
    ULSTrafficLogEntry *entry = [[ULSTrafficLogEntry alloc] init];
    entry.isOutgoing = YES;
    entry.data = nil;
    entry.decodedMeaning = message;
    entry.result = ULS_SUCCESS;

    [self addTrafficEntry:entry];
}

- (IBAction)clearLog:(id)sender {
    [_trafficLog removeAllObjects];
    [_trafficTableView reloadData];
    [self logMessage:@"Log cleared"];
}

- (IBAction)exportLog:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Traffic Log";
    panel.nameFieldStringValue = @"uls_traffic_log.txt";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"txt"]];

    [panel beginSheetModalForWindow:_view.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSString *logContent = [self formatTrafficLogForExport];
            NSError *error = nil;
            BOOL success = [logContent writeToURL:panel.URL
                                       atomically:YES
                                         encoding:NSUTF8StringEncoding
                                            error:&error];
            if (success) {
                [self logMessage:[NSString stringWithFormat:@"Log exported to %@", panel.URL.path]];
            } else {
                [self logMessage:[NSString stringWithFormat:@"Export failed: %@", error.localizedDescription]];
            }
        }
    }];
}

- (NSString *)formatTrafficLogForExport {
    NSMutableString *output = [NSMutableString string];
    [output appendString:@"ULS USB Traffic Log\n"];
    [output appendFormat:@"Exported: %@\n", [_fullTimestampFormatter stringFromDate:[NSDate date]]];
    [output appendString:@"================================================================================\n\n"];

    for (ULSTrafficLogEntry *entry in _trafficLog) {
        NSString *timestamp = [_timestampFormatter stringFromDate:entry.timestamp];
        NSString *direction = entry.isOutgoing ? @"TX" : @"RX";

        if (entry.data) {
            NSString *hexStr = [self hexStringFromData:entry.data];
            [output appendFormat:@"[%@] %@: %@", timestamp, direction, hexStr];
            if (entry.decodedMeaning.length > 0) {
                [output appendFormat:@"  ; %@", entry.decodedMeaning];
            }
        } else {
            [output appendFormat:@"[%@] %@", timestamp, entry.decodedMeaning];
        }
        [output appendString:@"\n"];
    }

    return output;
}

- (IBAction)toggleAutoScroll:(id)sender {
    _autoScrollEnabled = (_autoScrollToggle.state == NSControlStateValueOn);
}

#pragma mark - Command Console

- (IBAction)sendHexCommand:(id)sender {
    if (!self.isConnected) {
        [self logMessage:@"ERROR: No device connected"];
        return;
    }

    NSString *hexString = _hexInputField.stringValue;
    if (hexString.length == 0) {
        [self logMessage:@"ERROR: No command entered"];
        return;
    }

    /* Parse hex string */
    NSMutableData *data = [NSMutableData data];
    NSScanner *scanner = [NSScanner scannerWithString:hexString];

    while (!scanner.atEnd) {
        unsigned int byte;
        if ([scanner scanHexInt:&byte]) {
            if (byte > 0xFF) {
                [self logMessage:[NSString stringWithFormat:@"ERROR: Invalid byte value: 0x%X", byte]];
                return;
            }
            uint8_t b = (uint8_t)byte;
            [data appendBytes:&b length:1];
        } else {
            [scanner scanCharactersFromSet:
                [[NSCharacterSet alphanumericCharacterSet] invertedSet] intoString:nil];
        }
    }

    if (data.length == 0) {
        [self logMessage:@"ERROR: No valid hex bytes found"];
        return;
    }

    /* Safety check: Block laser firing commands */
    const uint8_t *bytes = data.bytes;
    if (data.length > 0 && (bytes[0] == ULS_CMD_LASER_ON || bytes[0] == ULS_CMD_LASER_OFF)) {
        [self logMessage:@"BLOCKED: Laser firing commands are disabled in debug panel for safety"];
        return;
    }

    /* Send command */
    size_t bytesWritten = 0;
    ULSError err = uls_bulk_write(_device, bytes, data.length, &bytesWritten);

    if (err != ULS_SUCCESS) {
        [self logMessage:[NSString stringWithFormat:@"ERROR: Write failed: %s", uls_error_string(err)]];
        [self recordError:err];
        return;
    }

    /* Try to read response */
    uint8_t response[256];
    size_t bytesRead = 0;
    err = uls_bulk_read(_device, response, sizeof(response), &bytesRead);

    if (err == ULS_ERROR_TIMEOUT) {
        [self logMessage:@"No response (timeout)"];
    } else if (err != ULS_SUCCESS) {
        [self logMessage:[NSString stringWithFormat:@"Read error: %s", uls_error_string(err)]];
        [self recordError:err];
    }

    /* Clear input */
    _hexInputField.stringValue = @"";
}

#pragma mark - Diagnostic Report

- (NSString *)generateDiagnosticReport {
    NSMutableString *report = [NSMutableString string];

    [report appendString:@"================================================================================\n"];
    [report appendString:@"ULS Laser Cutter - Diagnostic Report\n"];
    [report appendString:@"================================================================================\n\n"];

    [report appendFormat:@"Generated: %@\n", [_fullTimestampFormatter stringFromDate:[NSDate date]]];
    [report appendFormat:@"macOS Version: %@\n", [[NSProcessInfo processInfo] operatingSystemVersionString]];
    [report appendString:@"\n"];

    /* Device info */
    [report appendString:@"DEVICE INFORMATION\n"];
    [report appendString:@"------------------\n"];
    if (self.isConnected) {
        [report appendFormat:@"Model: %s\n", uls_model_string(_device->info.model)];
        [report appendFormat:@"Product ID: 0x%04X\n", _device->info.productId];
        [report appendFormat:@"Serial: %s\n", _device->info.serialNumber[0] ? _device->info.serialNumber : "(none)"];
        [report appendFormat:@"Firmware: %s\n", _device->info.firmwareVersion[0] ? _device->info.firmwareVersion : "(unknown)"];
        [report appendFormat:@"State: %s\n", uls_state_string(_device->info.state)];
    } else {
        [report appendString:@"Status: Not connected\n"];
    }
    [report appendString:@"\n"];

    /* Diagnostic checklist */
    [report appendString:@"DIAGNOSTIC CHECKLIST\n"];
    [report appendString:@"--------------------\n"];

    for (ULSDiagnosticStepInfo *info in _diagnosticSteps) {
        NSString *stateStr;
        switch (info.state) {
            case ULSDiagnosticStateNotStarted: stateStr = @"[ ]"; break;
            case ULSDiagnosticStateInProgress: stateStr = @"[~]"; break;
            case ULSDiagnosticStateSuccess:    stateStr = @"[+]"; break;
            case ULSDiagnosticStateFailed:     stateStr = @"[X]"; break;
        }

        [report appendFormat:@"%@ %@", stateStr, info.name];
        if (info.detail.length > 0) {
            [report appendFormat:@"\n     -> %@", info.detail];
        }
        [report appendString:@"\n"];
    }
    [report appendString:@"\n"];

    /* Last error */
    [report appendString:@"LAST ERROR\n"];
    [report appendString:@"----------\n"];
    [report appendFormat:@"%@\n\n", _lastErrorString];

    /* Recent traffic (last 20 entries) */
    [report appendString:@"RECENT USB TRAFFIC (last 20 entries)\n"];
    [report appendString:@"------------------------------------\n"];

    NSUInteger startIdx = _trafficLog.count > 20 ? _trafficLog.count - 20 : 0;
    for (NSUInteger i = startIdx; i < _trafficLog.count; i++) {
        ULSTrafficLogEntry *entry = _trafficLog[i];
        NSString *timestamp = [_timestampFormatter stringFromDate:entry.timestamp];
        NSString *direction = entry.isOutgoing ? @"TX" : @"RX";

        if (entry.data) {
            NSString *hexStr = [self hexStringFromData:entry.data];
            [report appendFormat:@"[%@] %@: %@", timestamp, direction, hexStr];
            if (entry.decodedMeaning.length > 0) {
                [report appendFormat:@"  ; %@", entry.decodedMeaning];
            }
        } else {
            [report appendFormat:@"[%@] %@", timestamp, entry.decodedMeaning];
        }
        [report appendString:@"\n"];
    }

    [report appendString:@"\n================================================================================\n"];
    [report appendString:@"End of Diagnostic Report\n"];
    [report appendString:@"================================================================================\n"];

    return report;
}

- (IBAction)copyDiagnosticReport:(id)sender {
    NSString *report = [self generateDiagnosticReport];
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:report forType:NSPasteboardTypeString];
    [self logMessage:@"Diagnostic report copied to clipboard"];
}

- (IBAction)saveDiagnosticReport:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Save Diagnostic Report";

    NSDateFormatter *fileFmt = [[NSDateFormatter alloc] init];
    fileFmt.dateFormat = @"yyyyMMdd_HHmmss";
    panel.nameFieldStringValue = [NSString stringWithFormat:@"uls_diagnostic_%@.txt",
                                   [fileFmt stringFromDate:[NSDate date]]];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"txt"]];

    [panel beginSheetModalForWindow:_view.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSString *report = [self generateDiagnosticReport];
            NSError *error = nil;
            BOOL success = [report writeToURL:panel.URL
                                   atomically:YES
                                     encoding:NSUTF8StringEncoding
                                        error:&error];
            if (success) {
                [self logMessage:[NSString stringWithFormat:@"Report saved to %@", panel.URL.path]];
            } else {
                [self logMessage:[NSString stringWithFormat:@"Save failed: %@", error.localizedDescription]];
            }
        }
    }];
}

#pragma mark - USB Traffic Callback

- (void)usbTrafficCallback:(ULSLogDirection)direction
                      data:(const uint8_t *)data
                    length:(size_t)length
                    result:(ULSError)result {
    if (direction == ULS_LOG_DIR_OUT) {
        [self logTrafficOutgoing:data length:length result:result];
    } else {
        [self logTrafficIncoming:data length:length result:result];
    }
}

#pragma mark - Utility Methods

- (NSString *)hexStringFromData:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSMutableString *hexStr = [NSMutableString string];

    for (NSUInteger i = 0; i < data.length && i < 32; i++) {
        [hexStr appendFormat:@"%02X ", bytes[i]];
    }

    if (data.length > 32) {
        [hexStr appendFormat:@"... (%lu more)", (unsigned long)(data.length - 32)];
    }

    return hexStr;
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == _diagnosticTableView) {
        return _diagnosticSteps.count;
    } else if (tableView == _trafficTableView) {
        return _trafficLog.count;
    }
    return 0;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *identifier = tableColumn.identifier;

    NSTextField *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[NSTextField alloc] init];
        cell.identifier = identifier;
        cell.bordered = NO;
        cell.drawsBackground = NO;
        cell.editable = NO;
        cell.selectable = YES;
        cell.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    }

    if (tableView == _diagnosticTableView) {
        ULSDiagnosticStepInfo *info = _diagnosticSteps[row];

        if ([identifier isEqualToString:@"status"]) {
            switch (info.state) {
                case ULSDiagnosticStateNotStarted:
                    cell.stringValue = @"\u2B1C";  /* White square */
                    cell.textColor = [NSColor grayColor];
                    break;
                case ULSDiagnosticStateInProgress:
                    cell.stringValue = @"\U0001F7E1";  /* Yellow circle */
                    cell.textColor = [NSColor systemYellowColor];
                    break;
                case ULSDiagnosticStateSuccess:
                    cell.stringValue = @"\u2705";  /* Green check */
                    cell.textColor = [NSColor systemGreenColor];
                    break;
                case ULSDiagnosticStateFailed:
                    cell.stringValue = @"\u274C";  /* Red X */
                    cell.textColor = [NSColor systemRedColor];
                    break;
            }
        } else if ([identifier isEqualToString:@"name"]) {
            cell.stringValue = info.name;
            cell.textColor = [NSColor labelColor];
        } else if ([identifier isEqualToString:@"detail"]) {
            cell.stringValue = info.detail ?: @"";
            if (info.state == ULSDiagnosticStateFailed) {
                cell.textColor = [NSColor systemRedColor];
            } else {
                cell.textColor = [NSColor secondaryLabelColor];
            }
        }
    } else if (tableView == _trafficTableView) {
        ULSTrafficLogEntry *entry = _trafficLog[row];

        if ([identifier isEqualToString:@"time"]) {
            cell.stringValue = [_timestampFormatter stringFromDate:entry.timestamp];
            cell.textColor = [NSColor secondaryLabelColor];
        } else if ([identifier isEqualToString:@"dir"]) {
            if (entry.data) {
                cell.stringValue = entry.isOutgoing ? @"\u2192" : @"\u2190";
                cell.textColor = entry.isOutgoing ? [NSColor systemBlueColor] : [NSColor systemGreenColor];
            } else {
                cell.stringValue = @"\u2022";
                cell.textColor = [NSColor secondaryLabelColor];
            }
        } else if ([identifier isEqualToString:@"hex"]) {
            if (entry.data) {
                cell.stringValue = [self hexStringFromData:entry.data];
                if (entry.result != ULS_SUCCESS) {
                    cell.textColor = [NSColor systemRedColor];
                } else {
                    cell.textColor = entry.isOutgoing ? [NSColor systemBlueColor] : [NSColor systemGreenColor];
                }
            } else {
                cell.stringValue = @"";
            }
        } else if ([identifier isEqualToString:@"meaning"]) {
            cell.stringValue = entry.decodedMeaning ?: @"";
            cell.textColor = [NSColor labelColor];
        }
    }

    return cell;
}

@end

#pragma mark - C Callback Bridge

static void usb_log_callback_bridge(ULSLogDirection direction, const uint8_t *data,
                                     size_t length, ULSError result, void *userContext) {
    ULSDebugPanelController *controller = (__bridge ULSDebugPanelController *)userContext;
    if (controller) {
        [controller usbTrafficCallback:direction data:data length:length result:result];
    }
}
