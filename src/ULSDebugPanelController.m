/*
 * ULS Debug Panel Controller Implementation
 * Provides device debugging and diagnostics interface
 *
 * Copyright (c) 2026 Contributors - MIT License
 */

#import "ULSDebugPanelController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/* Helper macro for Auto Layout */
#define ALOFF(v) (v).translatesAutoresizingMaskIntoConstraints = NO

/* Refresh interval in seconds */
#define DEBUG_REFRESH_INTERVAL 0.5

@implementation ULSDebugPanelController {
    NSView *_view;
    NSTextField *_connectionStatusLabel;
    NSTextField *_firmwareVersionLabel;
    NSTextField *_positionLabel;
    NSTextField *_deviceStateLabel;
    NSTextField *_errorFlagsLabel;
    NSTextField *_hexInputField;
    NSTextView *_trafficLogView;
    NSScrollView *_trafficLogScrollView;
    NSButton *_sendButton;
    NSButton *_clearLogButton;
    NSButton *_exportLogButton;
    NSMutableString *_logBuffer;
    NSDateFormatter *_timestampFormatter;
}

#pragma mark - Properties

- (NSView *)view { return _view; }
- (NSTextField *)connectionStatusLabel { return _connectionStatusLabel; }
- (NSTextField *)firmwareVersionLabel { return _firmwareVersionLabel; }
- (NSTextField *)positionLabel { return _positionLabel; }
- (NSTextField *)deviceStateLabel { return _deviceStateLabel; }
- (NSTextField *)errorFlagsLabel { return _errorFlagsLabel; }
- (NSTextField *)hexInputField { return _hexInputField; }
- (NSTextView *)trafficLogView { return _trafficLogView; }
- (NSScrollView *)trafficLogScrollView { return _trafficLogScrollView; }
- (NSButton *)sendButton { return _sendButton; }
- (NSButton *)clearLogButton { return _clearLogButton; }
- (NSButton *)exportLogButton { return _exportLogButton; }

- (BOOL)isConnected {
    return _device != NULL && _device->isOpen;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        _logBuffer = [NSMutableString string];
        _timestampFormatter = [[NSDateFormatter alloc] init];
        _timestampFormatter.dateFormat = @"HH:mm:ss.SSS";

        [self setupUI];
    }
    return self;
}

- (void)dealloc {
    [self stopAutoRefresh];
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

- (NSTextField *)makeValueLabel:(NSString *)text {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.textColor = [NSColor secondaryLabelColor];
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

    /* === Status Section === */
    NSBox *statusBox = [[NSBox alloc] init];
    statusBox.title = @"Device Status";
    statusBox.boxType = NSBoxPrimary;
    ALOFF(statusBox);
    [_view addSubview:statusBox];

    NSView *statusContent = [[NSView alloc] init];
    ALOFF(statusContent);
    statusBox.contentView = statusContent;

    /* Status labels */
    NSTextField *connLabel = [self makeLabel:@"Connection:"];
    _connectionStatusLabel = [self makeValueLabel:@"Disconnected"];

    NSTextField *fwLabel = [self makeLabel:@"Firmware:"];
    _firmwareVersionLabel = [self makeValueLabel:@"--"];

    NSTextField *posLabel = [self makeLabel:@"Position:"];
    _positionLabel = [self makeValueLabel:@"X: --  Y: --  Z: --"];

    NSTextField *stateLabel = [self makeLabel:@"State:"];
    _deviceStateLabel = [self makeValueLabel:@"Unknown"];

    NSTextField *errorLabel = [self makeLabel:@"Error Flags:"];
    _errorFlagsLabel = [self makeValueLabel:@"None"];

    [statusContent addSubview:connLabel];
    [statusContent addSubview:_connectionStatusLabel];
    [statusContent addSubview:fwLabel];
    [statusContent addSubview:_firmwareVersionLabel];
    [statusContent addSubview:posLabel];
    [statusContent addSubview:_positionLabel];
    [statusContent addSubview:stateLabel];
    [statusContent addSubview:_deviceStateLabel];
    [statusContent addSubview:errorLabel];
    [statusContent addSubview:_errorFlagsLabel];

    /* Status layout */
    CGFloat leftColWidth = 85;
    [NSLayoutConstraint activateConstraints:@[
        [connLabel.topAnchor constraintEqualToAnchor:statusContent.topAnchor constant:8],
        [connLabel.leadingAnchor constraintEqualToAnchor:statusContent.leadingAnchor constant:8],
        [connLabel.widthAnchor constraintEqualToConstant:leftColWidth],
        [_connectionStatusLabel.centerYAnchor constraintEqualToAnchor:connLabel.centerYAnchor],
        [_connectionStatusLabel.leadingAnchor constraintEqualToAnchor:connLabel.trailingAnchor constant:4],

        [fwLabel.topAnchor constraintEqualToAnchor:connLabel.bottomAnchor constant:6],
        [fwLabel.leadingAnchor constraintEqualToAnchor:connLabel.leadingAnchor],
        [fwLabel.widthAnchor constraintEqualToConstant:leftColWidth],
        [_firmwareVersionLabel.centerYAnchor constraintEqualToAnchor:fwLabel.centerYAnchor],
        [_firmwareVersionLabel.leadingAnchor constraintEqualToAnchor:fwLabel.trailingAnchor constant:4],

        [posLabel.topAnchor constraintEqualToAnchor:fwLabel.bottomAnchor constant:6],
        [posLabel.leadingAnchor constraintEqualToAnchor:connLabel.leadingAnchor],
        [posLabel.widthAnchor constraintEqualToConstant:leftColWidth],
        [_positionLabel.centerYAnchor constraintEqualToAnchor:posLabel.centerYAnchor],
        [_positionLabel.leadingAnchor constraintEqualToAnchor:posLabel.trailingAnchor constant:4],

        [stateLabel.topAnchor constraintEqualToAnchor:posLabel.bottomAnchor constant:6],
        [stateLabel.leadingAnchor constraintEqualToAnchor:connLabel.leadingAnchor],
        [stateLabel.widthAnchor constraintEqualToConstant:leftColWidth],
        [_deviceStateLabel.centerYAnchor constraintEqualToAnchor:stateLabel.centerYAnchor],
        [_deviceStateLabel.leadingAnchor constraintEqualToAnchor:stateLabel.trailingAnchor constant:4],

        [errorLabel.topAnchor constraintEqualToAnchor:stateLabel.bottomAnchor constant:6],
        [errorLabel.leadingAnchor constraintEqualToAnchor:connLabel.leadingAnchor],
        [errorLabel.widthAnchor constraintEqualToConstant:leftColWidth],
        [_errorFlagsLabel.centerYAnchor constraintEqualToAnchor:errorLabel.centerYAnchor],
        [_errorFlagsLabel.leadingAnchor constraintEqualToAnchor:errorLabel.trailingAnchor constant:4],
        [_errorFlagsLabel.bottomAnchor constraintEqualToAnchor:statusContent.bottomAnchor constant:-8],
    ]];

    /* === Command Console Section === */
    NSBox *consoleBox = [[NSBox alloc] init];
    consoleBox.title = @"Command Console";
    consoleBox.boxType = NSBoxPrimary;
    ALOFF(consoleBox);
    [_view addSubview:consoleBox];

    NSView *consoleContent = [[NSView alloc] init];
    ALOFF(consoleContent);
    consoleBox.contentView = consoleContent;

    /* Hex input row */
    NSTextField *hexLabel = [self makeLabel:@"Hex Command:"];

    _hexInputField = [[NSTextField alloc] init];
    _hexInputField.placeholderString = @"01 02 03 04 (space-separated hex bytes)";
    _hexInputField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    ALOFF(_hexInputField);

    _sendButton = [self makeButton:@"Send" action:@selector(sendHexCommand:)];
    _sendButton.bezelStyle = NSBezelStyleRounded;

    [consoleContent addSubview:hexLabel];
    [consoleContent addSubview:_hexInputField];
    [consoleContent addSubview:_sendButton];

    /* Warning label */
    NSTextField *warningLabel = [self makeLabel:@"Note: Laser firing commands are blocked for safety."];
    warningLabel.textColor = [NSColor systemOrangeColor];
    warningLabel.font = [NSFont systemFontOfSize:10];
    [consoleContent addSubview:warningLabel];

    /* Traffic log */
    _trafficLogScrollView = [[NSScrollView alloc] init];
    _trafficLogScrollView.hasVerticalScroller = YES;
    _trafficLogScrollView.hasHorizontalScroller = YES;
    _trafficLogScrollView.autohidesScrollers = YES;
    _trafficLogScrollView.borderType = NSBezelBorder;
    ALOFF(_trafficLogScrollView);

    _trafficLogView = [[NSTextView alloc] init];
    _trafficLogView.editable = NO;
    _trafficLogView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    _trafficLogView.backgroundColor = [NSColor textBackgroundColor];
    _trafficLogView.textContainerInset = NSMakeSize(4, 4);
    _trafficLogView.minSize = NSMakeSize(0, 100);
    _trafficLogView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _trafficLogView.verticallyResizable = YES;
    _trafficLogView.horizontallyResizable = YES;
    _trafficLogView.textContainer.widthTracksTextView = NO;
    _trafficLogView.textContainer.containerSize = NSMakeSize(FLT_MAX, FLT_MAX);

    _trafficLogScrollView.documentView = _trafficLogView;
    [consoleContent addSubview:_trafficLogScrollView];

    /* Button row */
    _clearLogButton = [self makeButton:@"Clear Log" action:@selector(clearLog:)];
    _exportLogButton = [self makeButton:@"Export Log..." action:@selector(exportLog:)];

    [consoleContent addSubview:_clearLogButton];
    [consoleContent addSubview:_exportLogButton];

    /* Console layout */
    [NSLayoutConstraint activateConstraints:@[
        [hexLabel.topAnchor constraintEqualToAnchor:consoleContent.topAnchor constant:8],
        [hexLabel.leadingAnchor constraintEqualToAnchor:consoleContent.leadingAnchor constant:8],

        [_hexInputField.centerYAnchor constraintEqualToAnchor:hexLabel.centerYAnchor],
        [_hexInputField.leadingAnchor constraintEqualToAnchor:hexLabel.trailingAnchor constant:8],
        [_hexInputField.trailingAnchor constraintEqualToAnchor:_sendButton.leadingAnchor constant:-8],

        [_sendButton.centerYAnchor constraintEqualToAnchor:hexLabel.centerYAnchor],
        [_sendButton.trailingAnchor constraintEqualToAnchor:consoleContent.trailingAnchor constant:-8],
        [_sendButton.widthAnchor constraintEqualToConstant:60],

        [warningLabel.topAnchor constraintEqualToAnchor:hexLabel.bottomAnchor constant:4],
        [warningLabel.leadingAnchor constraintEqualToAnchor:consoleContent.leadingAnchor constant:8],

        [_trafficLogScrollView.topAnchor constraintEqualToAnchor:warningLabel.bottomAnchor constant:8],
        [_trafficLogScrollView.leadingAnchor constraintEqualToAnchor:consoleContent.leadingAnchor constant:8],
        [_trafficLogScrollView.trailingAnchor constraintEqualToAnchor:consoleContent.trailingAnchor constant:-8],
        [_trafficLogScrollView.heightAnchor constraintGreaterThanOrEqualToConstant:150],

        [_clearLogButton.topAnchor constraintEqualToAnchor:_trafficLogScrollView.bottomAnchor constant:8],
        [_clearLogButton.leadingAnchor constraintEqualToAnchor:consoleContent.leadingAnchor constant:8],
        [_clearLogButton.bottomAnchor constraintEqualToAnchor:consoleContent.bottomAnchor constant:-8],

        [_exportLogButton.centerYAnchor constraintEqualToAnchor:_clearLogButton.centerYAnchor],
        [_exportLogButton.leadingAnchor constraintEqualToAnchor:_clearLogButton.trailingAnchor constant:8],
    ]];

    /* === Main Layout === */
    [NSLayoutConstraint activateConstraints:@[
        [statusBox.topAnchor constraintEqualToAnchor:_view.topAnchor constant:8],
        [statusBox.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],
        [statusBox.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],

        [consoleBox.topAnchor constraintEqualToAnchor:statusBox.bottomAnchor constant:12],
        [consoleBox.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor constant:8],
        [consoleBox.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor constant:-8],
        [consoleBox.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-8],
    ]];

    /* Initial log message */
    [self logMessage:@"Debug panel initialized. Connect to a device to start monitoring."];
}

#pragma mark - Device Management

- (void)setDevice:(ULSDevice *)device {
    _device = device;
    [self refreshStatus];

    if (device) {
        [self logMessage:[NSString stringWithFormat:@"Device connected: %s",
                          uls_model_string(device->info.model)]];
    } else {
        [self logMessage:@"Device disconnected"];
    }
}

#pragma mark - Auto Refresh

- (void)startAutoRefresh {
    if (self.refreshTimer) return;

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:DEBUG_REFRESH_INTERVAL
                                                         target:self
                                                       selector:@selector(refreshStatus)
                                                       userInfo:nil
                                                        repeats:YES];
    [self logMessage:@"Auto-refresh started"];
}

- (void)stopAutoRefresh {
    if (self.refreshTimer) {
        [self.refreshTimer invalidate];
        self.refreshTimer = nil;
        [self logMessage:@"Auto-refresh stopped"];
    }
}

#pragma mark - Status Refresh

- (void)refreshStatus {
    if (!_device || !_device->isOpen) {
        _connectionStatusLabel.stringValue = @"Disconnected";
        _connectionStatusLabel.textColor = [NSColor systemRedColor];
        _firmwareVersionLabel.stringValue = @"--";
        _positionLabel.stringValue = @"X: --  Y: --  Z: --";
        _deviceStateLabel.stringValue = @"Unknown";
        _errorFlagsLabel.stringValue = @"--";
        _sendButton.enabled = NO;
        return;
    }

    /* Connection status */
    _connectionStatusLabel.stringValue = [NSString stringWithFormat:@"Connected (%s)",
                                          uls_model_string(_device->info.model)];
    _connectionStatusLabel.textColor = [NSColor systemGreenColor];
    _sendButton.enabled = YES;

    /* Firmware version */
    char version[64] = {0};
    ULSError err = uls_get_firmware_version(_device, version, sizeof(version));
    if (err == ULS_SUCCESS && version[0]) {
        _firmwareVersionLabel.stringValue = [NSString stringWithUTF8String:version];
    } else {
        _firmwareVersionLabel.stringValue = @"(unavailable)";
    }

    /* Position */
    float x = 0, y = 0, z = 0;
    err = uls_get_position(_device, &x, &y, &z);
    if (err == ULS_SUCCESS) {
        _positionLabel.stringValue = [NSString stringWithFormat:@"X: %.3f\"  Y: %.3f\"  Z: %.3f\"", x, y, z];
    } else {
        _positionLabel.stringValue = @"X: --  Y: --  Z: --";
    }

    /* Device state */
    ULSDeviceState state = ULS_STATE_DISCONNECTED;
    err = uls_get_status(_device, &state);
    if (err == ULS_SUCCESS) {
        _deviceStateLabel.stringValue = [NSString stringWithUTF8String:uls_state_string(state)];

        /* Color-code state */
        switch (state) {
            case ULS_STATE_READY:
                _deviceStateLabel.textColor = [NSColor systemGreenColor];
                break;
            case ULS_STATE_BUSY:
                _deviceStateLabel.textColor = [NSColor systemOrangeColor];
                break;
            case ULS_STATE_ERROR:
                _deviceStateLabel.textColor = [NSColor systemRedColor];
                break;
            default:
                _deviceStateLabel.textColor = [NSColor secondaryLabelColor];
                break;
        }
    } else {
        _deviceStateLabel.stringValue = @"Unknown";
        _deviceStateLabel.textColor = [NSColor secondaryLabelColor];
    }

    /* Error flags (placeholder - would need protocol knowledge to decode) */
    _errorFlagsLabel.stringValue = (state == ULS_STATE_ERROR) ? @"Error detected" : @"None";
    _errorFlagsLabel.textColor = (state == ULS_STATE_ERROR) ?
        [NSColor systemRedColor] : [NSColor secondaryLabelColor];
}

#pragma mark - Command Console

- (void)sendHexCommand:(id)sender {
    (void)sender;

    if (!_device || !_device->isOpen) {
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
            /* Skip non-hex characters */
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
    [self logSentData:bytes length:data.length];

    size_t bytesWritten = 0;
    ULSError err = uls_bulk_write(_device, bytes, data.length, &bytesWritten);

    if (err != ULS_SUCCESS) {
        [self logMessage:[NSString stringWithFormat:@"ERROR: Write failed: %s", uls_error_string(err)]];
        return;
    }

    [self logMessage:[NSString stringWithFormat:@"Sent %zu bytes", bytesWritten]];

    /* Try to read response */
    uint8_t response[256];
    size_t bytesRead = 0;
    err = uls_bulk_read(_device, response, sizeof(response), &bytesRead);

    if (err == ULS_SUCCESS && bytesRead > 0) {
        [self logReceivedData:response length:bytesRead];
    } else if (err == ULS_ERROR_TIMEOUT) {
        [self logMessage:@"No response (timeout)"];
    } else if (err != ULS_SUCCESS) {
        [self logMessage:[NSString stringWithFormat:@"Read error: %s", uls_error_string(err)]];
    }

    /* Clear input for next command */
    _hexInputField.stringValue = @"";
}

- (void)clearLog:(id)sender {
    (void)sender;
    [_logBuffer setString:@""];
    _trafficLogView.string = @"";
    [self logMessage:@"Log cleared"];
}

- (void)exportLog:(id)sender {
    (void)sender;

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Debug Log";
    panel.nameFieldStringValue = @"uls_debug_log.txt";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"txt"]];

    [panel beginSheetModalForWindow:_view.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *error = nil;
            BOOL success = [self->_logBuffer writeToURL:panel.URL
                                             atomically:YES
                                               encoding:NSUTF8StringEncoding
                                                  error:&error];
            if (success) {
                [self logMessage:[NSString stringWithFormat:@"Log exported to %@", panel.URL.path]];
            } else {
                [self logMessage:[NSString stringWithFormat:@"ERROR: Export failed: %@",
                                  error.localizedDescription]];
            }
        }
    }];
}

#pragma mark - Logging

- (void)logMessage:(NSString *)message {
    NSString *timestamp = [_timestampFormatter stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    [_logBuffer appendString:line];

    /* Append to text view */
    NSAttributedString *attrStr = [[NSAttributedString alloc]
        initWithString:line
        attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor labelColor]
        }];

    [_trafficLogView.textStorage appendAttributedString:attrStr];

    /* Scroll to bottom */
    [_trafficLogView scrollRangeToVisible:NSMakeRange(_trafficLogView.string.length, 0)];
}

- (void)logSentData:(const uint8_t *)data length:(size_t)length {
    NSMutableString *hexStr = [NSMutableString stringWithString:@"TX: "];
    for (size_t i = 0; i < length; i++) {
        [hexStr appendFormat:@"%02X ", data[i]];
    }
    [self logMessage:hexStr];
}

- (void)logReceivedData:(const uint8_t *)data length:(size_t)length {
    NSMutableString *hexStr = [NSMutableString stringWithString:@"RX: "];
    for (size_t i = 0; i < length; i++) {
        [hexStr appendFormat:@"%02X ", data[i]];
    }
    [self logMessage:hexStr];
}

@end
