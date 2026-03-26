/*
 * ULS Laser Control for macOS
 * Main Window Controller Implementation
 * Auto Layout based UI
 */

#import "ULSMainWindowController.h"
#import "ULSSVGParser.h"
#import "ULSPDFParser.h"
#import "ULSDebugPanelController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Helper macro for Auto Layout
#define ALOFF(v) (v).translatesAutoresizingMaskIntoConstraints = NO

// Forward declarations for preview callbacks
@interface ULSMainWindowController (PreviewCallbacks)
- (void)moveToolToX:(float)x y:(float)y;
- (void)designPositionChangedToX:(float)x y:(float)y;
@end

// === Interaction Mode ===

typedef NS_ENUM(NSInteger, ULSInteractionMode) {
    ULSInteractionModeDesign = 0,
    ULSInteractionModeJog = 1
};

// === Operation State (safety management) ===

typedef NS_ENUM(NSInteger, ULSOperationState) {
    ULSOperationStateIdle = 0,
    ULSOperationStateRunning,
    ULSOperationStatePaused
};

// === ULSPreviewView: Custom preview with tool position crosshair and click-to-move ===

@interface ULSPreviewView : NSView
@property (assign) float toolX;
@property (assign) float toolY;
@property (assign) float pageWidth;
@property (assign) float pageHeight;
@property (assign) float designOffsetX;
@property (assign) float designOffsetY;
@property (assign) ULSInteractionMode interactionMode;
@property (assign) ULSJob *currentJob;
@property (weak) ULSMainWindowController *controller;
// Simulation playback
@property (assign) ULSSimulation *simulation;
@property (assign) int simCurrentIndex;
@property (assign) BOOL simulating;
@end

@implementation ULSPreviewView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSRect bounds = self.bounds;

    // Outer background (darker gray to frame the engraving field)
    [[NSColor colorWithWhite:0.82 alpha:1] setFill];
    NSRectFill(bounds);

    if (self.pageWidth <= 0 || self.pageHeight <= 0) return;

    // Calculate scale to fit engraving field in view
    CGFloat margin = 30;
    CGFloat availW = bounds.size.width - 2 * margin;
    CGFloat availH = bounds.size.height - 2 * margin;
    if (availW <= 0 || availH <= 0) return;

    CGFloat scaleX = availW / self.pageWidth;
    CGFloat scaleY = availH / self.pageHeight;
    CGFloat scale = MIN(scaleX, scaleY);

    CGFloat fieldW = self.pageWidth * scale;
    CGFloat fieldH = self.pageHeight * scale;
    CGFloat originX = (bounds.size.width - fieldW) / 2;
    CGFloat originY = (bounds.size.height - fieldH) / 2;

    // Drop shadow for engraving field (flipped view: positive height = down)
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowOffset = NSMakeSize(2, 2);
    shadow.shadowBlurRadius = 4;
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
    [NSGraphicsContext saveGraphicsState];
    [shadow set];
    [[NSColor whiteColor] setFill];
    NSRect fieldRect = NSMakeRect(originX, originY, fieldW, fieldH);
    NSRectFill(fieldRect);
    [NSGraphicsContext restoreGraphicsState];

    // Engraving field background (light gray)
    [[NSColor colorWithWhite:0.94 alpha:1] setFill];
    NSRectFill(fieldRect);

    // Grid lines (every inch)
    [[NSColor colorWithWhite:0.85 alpha:1] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    grid.lineWidth = 0.5;
    for (float ix = 1; ix < self.pageWidth; ix += 1.0f) {
        CGFloat sx = originX + ix * scale;
        [grid moveToPoint:NSMakePoint(sx, originY)];
        [grid lineToPoint:NSMakePoint(sx, originY + fieldH)];
    }
    for (float iy = 1; iy < self.pageHeight; iy += 1.0f) {
        CGFloat sy = originY + iy * scale;
        [grid moveToPoint:NSMakePoint(originX, sy)];
        [grid lineToPoint:NSMakePoint(originX + fieldW, sy)];
    }
    [grid stroke];

    // Field border
    [[NSColor colorWithWhite:0.5 alpha:1] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:fieldRect];
    border.lineWidth = 1.0;
    [border stroke];

    // Axis labels
    {
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.3 alpha:1]
        };
        float xStep = self.pageWidth > 12 ? 4.0f : 2.0f;
        for (float ix = 0; ix <= self.pageWidth; ix += xStep) {
            CGFloat sx = originX + ix * scale;
            NSString *lbl = [NSString stringWithFormat:@"%.0f\"", ix];
            [lbl drawAtPoint:NSMakePoint(sx - 4, originY + fieldH + 3) withAttributes:attrs];
        }
        float yStep = self.pageHeight > 12 ? 4.0f : 2.0f;
        for (float iy = 0; iy <= self.pageHeight; iy += yStep) {
            CGFloat sy = originY + iy * scale;
            NSString *lbl = [NSString stringWithFormat:@"%.0f\"", iy];
            [lbl drawAtPoint:NSMakePoint(originX - 18, sy - 5) withAttributes:attrs];
        }
    }

    // === Draw job paths ===
    if (self.currentJob && self.currentJob->numVectorPaths > 0) {
        // Clip to engraving field
        [NSGraphicsContext saveGraphicsState];
        NSBezierPath *clipPath = [NSBezierPath bezierPathWithRect:fieldRect];
        [clipPath addClip];

        CGFloat jobOffX = originX + self.designOffsetX * scale;
        CGFloat jobOffY = originY + self.designOffsetY * scale;

        for (int p = 0; p < self.currentJob->numVectorPaths; p++) {
            ULSVectorPath *vpath = self.currentJob->vectorPaths[p];
            if (!vpath || vpath->numElements == 0) continue;

            NSBezierPath *bp = [NSBezierPath bezierPath];
            bp.lineWidth = 1.0;

            for (int e = 0; e < vpath->numElements; e++) {
                ULSPathElement *elem = &vpath->elements[e];
                switch (elem->op) {
                    case ULS_PATH_OP_MOVE:
                        [bp moveToPoint:NSMakePoint(
                            jobOffX + elem->points[0].x * scale,
                            jobOffY + elem->points[0].y * scale)];
                        break;
                    case ULS_PATH_OP_LINE:
                        [bp lineToPoint:NSMakePoint(
                            jobOffX + elem->points[0].x * scale,
                            jobOffY + elem->points[0].y * scale)];
                        break;
                    case ULS_PATH_OP_BEZIER:
                        [bp curveToPoint:NSMakePoint(
                            jobOffX + elem->points[2].x * scale,
                            jobOffY + elem->points[2].y * scale)
                            controlPoint1:NSMakePoint(
                                jobOffX + elem->points[0].x * scale,
                                jobOffY + elem->points[0].y * scale)
                            controlPoint2:NSMakePoint(
                                jobOffX + elem->points[1].x * scale,
                                jobOffY + elem->points[1].y * scale)];
                        break;
                    case ULS_PATH_OP_CLOSE:
                        [bp closePath];
                        break;
                    default:
                        break;
                }
            }

            [[NSColor blackColor] setStroke];
            [bp stroke];
        }

        [NSGraphicsContext restoreGraphicsState];
    }

    // Design origin marker (blue cross)
    {
        CGFloat dx = originX + self.designOffsetX * scale;
        CGFloat dy = originY + self.designOffsetY * scale;
        if (dx >= originX && dx <= originX + fieldW && dy >= originY && dy <= originY + fieldH) {
            [[NSColor systemBlueColor] setStroke];
            NSBezierPath *dm = [NSBezierPath bezierPath];
            dm.lineWidth = 1.0;
            CGFloat sz = 7;
            [dm moveToPoint:NSMakePoint(dx - sz, dy)];
            [dm lineToPoint:NSMakePoint(dx + sz, dy)];
            [dm moveToPoint:NSMakePoint(dx, dy - sz)];
            [dm lineToPoint:NSMakePoint(dx, dy + sz)];
            [dm stroke];

            if (self.interactionMode == ULSInteractionModeDesign) {
                NSDictionary *attrs = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:8],
                    NSForegroundColorAttributeName: [NSColor systemBlueColor]
                };
                NSString *posText = [NSString stringWithFormat:@"Origin %.1f, %.1f",
                                     self.designOffsetX, self.designOffsetY];
                [posText drawAtPoint:NSMakePoint(dx + sz + 3, dy - 5) withAttributes:attrs];
            }
        }
    }

    // === Simulation trace ===
    if (self.simulating && self.simulation && self.simCurrentIndex > 0) {
        [NSGraphicsContext saveGraphicsState];
        NSBezierPath *clipSim = [NSBezierPath bezierPathWithRect:fieldRect];
        [clipSim addClip];

        NSBezierPath *rapidPath = [NSBezierPath bezierPath];
        rapidPath.lineWidth = 0.5;
        NSBezierPath *cutPath = [NSBezierPath bezierPath];
        cutPath.lineWidth = 2.0;

        ULSSimPoint *pts = self.simulation->points;
        int maxIdx = self.simCurrentIndex;
        if (maxIdx >= self.simulation->numPoints) maxIdx = self.simulation->numPoints - 1;

        for (int i = 1; i <= maxIdx; i++) {
            CGFloat x0 = originX + pts[i-1].x * scale;
            CGFloat y0 = originY + pts[i-1].y * scale;
            CGFloat x1 = originX + pts[i].x * scale;
            CGFloat y1 = originY + pts[i].y * scale;

            if (pts[i].laserOn) {
                [cutPath moveToPoint:NSMakePoint(x0, y0)];
                [cutPath lineToPoint:NSMakePoint(x1, y1)];
            } else {
                [rapidPath moveToPoint:NSMakePoint(x0, y0)];
                [rapidPath lineToPoint:NSMakePoint(x1, y1)];
            }
        }

        // Draw rapid moves (gray dashed)
        [[NSColor colorWithWhite:0.6 alpha:0.5] setStroke];
        CGFloat dash[] = {3, 3};
        [rapidPath setLineDash:dash count:2 phase:0];
        [rapidPath stroke];

        // Draw cutting moves (bright red)
        [[NSColor colorWithRed:1.0 green:0.2 blue:0.0 alpha:0.9] setStroke];
        [cutPath stroke];

        [NSGraphicsContext restoreGraphicsState];
    }

    // Tool position crosshair (red)
    {
        CGFloat tx = originX + self.toolX * scale;
        CGFloat ty = originY + self.toolY * scale;
        [[NSColor systemRedColor] setStroke];
        NSBezierPath *ch = [NSBezierPath bezierPath];
        ch.lineWidth = 1.5;
        CGFloat sz = 12;

        // Horizontal line
        [ch moveToPoint:NSMakePoint(tx - sz, ty)];
        [ch lineToPoint:NSMakePoint(tx + sz, ty)];
        // Vertical line
        [ch moveToPoint:NSMakePoint(tx, ty - sz)];
        [ch lineToPoint:NSMakePoint(tx, ty + sz)];
        [ch stroke];

        // Position coordinates near crosshair
        NSString *posText = [NSString stringWithFormat:@"%.2f, %.2f", self.toolX, self.toolY];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor systemRedColor]
        };
        [posText drawAtPoint:NSMakePoint(tx + sz + 3, ty - 5) withAttributes:attrs];
    }

    // Mode indicator (top-left of field)
    {
        NSString *modeText = self.interactionMode == ULSInteractionModeJog ? @"MODE: JOG" : @"MODE: DESIGN";
        NSColor *modeColor = self.interactionMode == ULSInteractionModeJog ?
            [NSColor systemRedColor] : [NSColor systemBlueColor];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
            NSForegroundColorAttributeName: modeColor
        };
        [modeText drawAtPoint:NSMakePoint(originX + 4, originY + 4) withAttributes:attrs];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect bounds = self.bounds;

    if (self.pageWidth <= 0 || self.pageHeight <= 0) return;

    CGFloat margin = 30;
    CGFloat availW = bounds.size.width - 2 * margin;
    CGFloat availH = bounds.size.height - 2 * margin;
    if (availW <= 0 || availH <= 0) return;

    CGFloat scaleX = availW / self.pageWidth;
    CGFloat scaleY = availH / self.pageHeight;
    CGFloat scale = MIN(scaleX, scaleY);

    CGFloat fieldW = self.pageWidth * scale;
    CGFloat fieldH = self.pageHeight * scale;
    CGFloat originX = (bounds.size.width - fieldW) / 2;
    CGFloat originY = (bounds.size.height - fieldH) / 2;

    // Convert to field coordinates (inches)
    CGFloat fieldX = (loc.x - originX) / scale;
    CGFloat fieldY = (loc.y - originY) / scale;

    // Clamp to field bounds
    if (fieldX < 0) fieldX = 0;
    if (fieldX > self.pageWidth) fieldX = self.pageWidth;
    if (fieldY < 0) fieldY = 0;
    if (fieldY > self.pageHeight) fieldY = self.pageHeight;

    if (self.interactionMode == ULSInteractionModeJog) {
        [self.controller moveToolToX:(float)fieldX y:(float)fieldY];
    } else {
        self.designOffsetX = (float)fieldX;
        self.designOffsetY = (float)fieldY;
        [self.controller designPositionChangedToX:(float)fieldX y:(float)fieldY];
    }
    [self setNeedsDisplay:YES];
}

@end

// === Main Window Controller ===

@implementation ULSMainWindowController {
    NSButton *_penModeButtons[8];
    NSSlider *_penPowerSliders[8];
    NSSlider *_penSpeedSliders[8];
    NSTextField *_penPPIFields[8];
    NSButton *_penGasAssistCheckboxes[8];
    NSTextField *_penPowerFields[8];
    NSTextField *_penSpeedFields[8];

    float _jogDistance;
    ULSInteractionMode _interactionMode;
    float _designOffsetX;
    float _designOffsetY;

    // Safety state management
    ULSOperationState _operationState;
    NSTimer *_progressTimer;
    NSDate *_jobStartTime;

    // Jog buttons (stored for disabling during operation)
    NSButton *_jogButtons[4]; // Up, Down, Left, Right

    // Simulation playback
    ULSSimulation *_simulation;
    NSTimer *_simTimer;
    float _simTime;
    float _simPlaybackSpeed;
    NSButton *_simulateButton;
    NSPopUpButton *_simSpeedPopup;
}

#pragma mark - Init

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 1100, 800);
    NSUInteger styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                           NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"ULS Laser Control";
    window.minSize = NSMakeSize(900, 600);

    self = [super initWithWindow:window];
    if (self) {
        self.printerSettings = uls_printer_settings_create();
        _jogDistance = 0.5f;
        _interactionMode = ULSInteractionModeJog;
        _designOffsetX = 0;
        _designOffsetY = 0;
        _operationState = ULSOperationStateIdle;
        _simPlaybackSpeed = 10.0f;

        [self setupUI];
        [self updateUIState];
        [self updatePenSettingsUI];
    }
    return self;
}

#pragma mark - UI Construction Helpers

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

- (NSButton *)makeButton:(NSString *)title action:(SEL)action {
    NSButton *btn = [NSButton buttonWithTitle:title target:self action:action];
    ALOFF(btn);
    return btn;
}

- (NSTextField *)makeEditableField:(CGFloat)width {
    NSTextField *field = [[NSTextField alloc] init];
    ALOFF(field);
    [field.widthAnchor constraintEqualToConstant:width].active = YES;
    return field;
}

- (NSTextField *)makeCompactEditableField:(CGFloat)width tag:(int)tag action:(SEL)action {
    NSTextField *field = [[NSTextField alloc] init];
    field.font = [NSFont systemFontOfSize:9];
    field.alignment = NSTextAlignmentRight;
    field.tag = tag;
    field.target = self;
    field.action = action;
    ALOFF(field);
    [field.widthAnchor constraintEqualToConstant:width].active = YES;
    return field;
}

#pragma mark - Main Layout

- (void)setupUI {
    NSView *contentView = self.window.contentView;

    // === Top status bar ===
    NSStackView *statusBar = [self buildStatusBar];
    ALOFF(statusBar);
    [contentView addSubview:statusBar];

    NSBox *divider = [[NSBox alloc] init];
    divider.boxType = NSBoxSeparator;
    ALOFF(divider);
    [contentView addSubview:divider];

    // === Bottom bar (transport + progress + buttons) ===
    NSStackView *bottomBar = [self buildBottomBar];
    ALOFF(bottomBar);
    [contentView addSubview:bottomBar];

    // === Main split: preview (left) + controls (right) ===
    // Preview area (custom view with crosshair + click-to-move)
    ULSPreviewView *preview = [[ULSPreviewView alloc] init];
    preview.wantsLayer = YES;
    preview.layer.borderWidth = 1;
    preview.layer.borderColor = [[NSColor gridColor] CGColor];
    preview.pageWidth = 24.0f;
    preview.pageHeight = 12.0f;
    preview.interactionMode = _interactionMode;
    preview.controller = self;
    ALOFF(preview);
    self.previewView = preview;

    // Mode selector overlay on preview (Design / Jog)
    self.modeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Design", @"Jog"]
        trackingMode:NSSegmentSwitchTrackingSelectOne
        target:self
        action:@selector(interactionModeChanged:)];
    self.modeControl.selectedSegment = 1; // Default: Jog
    ALOFF(self.modeControl);
    [self.previewView addSubview:self.modeControl];

    // Right control panel inside a scroll view
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    ALOFF(scrollView);

    // Build the control panel content
    NSView *controlContent = [self buildControlPanel];
    scrollView.documentView = controlContent;

    // Constrain controlContent width to scrollView's clip view width
    NSClipView *clipView = scrollView.contentView;
    ALOFF(controlContent);
    [NSLayoutConstraint activateConstraints:@[
        [controlContent.topAnchor constraintEqualToAnchor:clipView.topAnchor],
        [controlContent.leadingAnchor constraintEqualToAnchor:clipView.leadingAnchor],
        [controlContent.trailingAnchor constraintEqualToAnchor:clipView.trailingAnchor],
    ]];

    // Put preview and scroll view side by side
    [contentView addSubview:self.previewView];
    [contentView addSubview:scrollView];

    // === Constraints ===
    CGFloat m = 12;

    [NSLayoutConstraint activateConstraints:@[
        // Status bar
        [statusBar.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:m],
        [statusBar.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:m],
        [statusBar.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-m],

        // Divider
        [divider.topAnchor constraintEqualToAnchor:statusBar.bottomAnchor constant:6],
        [divider.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:m],
        [divider.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-m],
        [divider.heightAnchor constraintEqualToConstant:1],

        // Preview
        [self.previewView.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:m],
        [self.previewView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:m],
        [self.previewView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:-m],
        [self.previewView.widthAnchor constraintGreaterThanOrEqualToConstant:300],

        // Mode selector overlay (top-right of preview)
        [self.modeControl.topAnchor constraintEqualToAnchor:self.previewView.topAnchor constant:8],
        [self.modeControl.trailingAnchor constraintEqualToAnchor:self.previewView.trailingAnchor constant:-8],

        // Scroll view (right panel)
        [scrollView.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:m],
        [scrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-m],
        [scrollView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:-m],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.previewView.trailingAnchor constant:m],
        [scrollView.widthAnchor constraintEqualToConstant:280],

        // Bottom bar
        [bottomBar.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:m],
        [bottomBar.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-m],
        [bottomBar.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-m],
    ]];

    [self.window center];
}

#pragma mark - Status Bar

- (NSStackView *)buildStatusBar {
    self.statusLabel = [self makeLabel:@"Status: Disconnected"];
    self.statusLabel.font = [NSFont boldSystemFontOfSize:13];

    self.deviceLabel = [self makeLabel:@"Device: None"];
    self.positionLabel = [self makeLabel:@"Position: X: 0.00 Y: 0.00"];

    NSStackView *stack = [NSStackView stackViewWithViews:@[self.statusLabel, self.deviceLabel, self.positionLabel]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.distribution = NSStackViewDistributionFillEqually;
    stack.spacing = 10;
    return stack;
}

#pragma mark - Bottom Bar (Transport + Timeline + File Operations)

- (NSStackView *)buildBottomBar {
    // Row 1: Transport controls + Simulate + Progress bar + Time display
    self.startButton = [self makeButton:@"Start" action:@selector(startJob:)];
    self.pauseButton = [self makeButton:@"Pause" action:@selector(pauseJob:)];
    self.stopButton = [self makeButton:@"Stop" action:@selector(stopJob:)];

    _simulateButton = [self makeButton:@"Simulate" action:@selector(simulateJob:)];

    _simSpeedPopup = [[NSPopUpButton alloc] init];
    [_simSpeedPopup addItemsWithTitles:@[@"1x", @"2x", @"5x", @"10x", @"50x"]];
    [_simSpeedPopup selectItemAtIndex:3]; // Default: 10x
    _simSpeedPopup.target = self;
    _simSpeedPopup.action = @selector(simSpeedChanged:);
    _simSpeedPopup.font = [NSFont systemFontOfSize:10];
    ALOFF(_simSpeedPopup);
    [_simSpeedPopup.widthAnchor constraintEqualToConstant:55].active = YES;

    NSStackView *transportBtns = [NSStackView stackViewWithViews:@[
        self.startButton, self.pauseButton, self.stopButton, _simulateButton, _simSpeedPopup]];
    transportBtns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    transportBtns.spacing = 4;
    ALOFF(transportBtns);

    self.progressIndicator = [[NSProgressIndicator alloc] init];
    self.progressIndicator.style = NSProgressIndicatorStyleBar;
    self.progressIndicator.minValue = 0;
    self.progressIndicator.maxValue = 100;
    self.progressIndicator.doubleValue = 0;
    ALOFF(self.progressIndicator);

    self.estimatedTimeLabel = [self makeLabel:@"Est: --:--"];
    self.estimatedTimeLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [self.estimatedTimeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:70].active = YES;

    self.elapsedTimeLabel = [self makeLabel:@"0:00"];
    self.elapsedTimeLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [self.elapsedTimeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;

    NSTextField *slashLabel = [self makeLabel:@"/"];
    slashLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];

    NSStackView *timeRow = [NSStackView stackViewWithViews:@[self.elapsedTimeLabel, slashLabel, self.estimatedTimeLabel]];
    timeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    timeRow.spacing = 2;
    ALOFF(timeRow);

    NSStackView *timeline = [NSStackView stackViewWithViews:@[transportBtns, self.progressIndicator, timeRow]];
    timeline.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    timeline.spacing = 8;
    ALOFF(timeline);

    // Make progress bar fill remaining space
    [self.progressIndicator setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [transportBtns setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [timeRow setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    // Row 2: File operation buttons
    NSButton *importBtn = [self makeButton:@"Import SVG/PDF..." action:@selector(importSVG:)];
    NSButton *saveBtn = [self makeButton:@"Save Settings..." action:@selector(saveSettings:)];
    NSButton *loadBtn = [self makeButton:@"Load Settings..." action:@selector(loadSettings:)];
    NSButton *resetBtn = [self makeButton:@"Reset" action:@selector(resetSettings:)];

    NSStackView *fileButtons = [NSStackView stackViewWithViews:@[importBtn, saveBtn, loadBtn, resetBtn]];
    fileButtons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fileButtons.spacing = 8;
    ALOFF(fileButtons);

    NSStackView *stack = [NSStackView stackViewWithViews:@[timeline, fileButtons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    return stack;
}

#pragma mark - Control Panel

- (NSView *)buildControlPanel {
    NSView *panel = [[NSView alloc] init];
    ALOFF(panel);

    NSMutableArray *sections = [NSMutableArray array];

    // 1. Connection
    [sections addObject:[self buildConnectionSection]];
    [sections addObject:[self makeSeparator]];

    // 2. Laser Control (Home only - Start/Stop/Pause moved to bottom bar)
    [sections addObject:[self buildLaserControlSection]];
    [sections addObject:[self makeSeparator]];

    // 3. Jog Control
    [sections addObject:[self buildJogSection]];
    [sections addObject:[self makeSeparator]];

    // 3b. Focus / Z-Axis
    [sections addObject:[self buildFocusSection]];
    [sections addObject:[self makeSeparator]];

    // 4. Settings
    [sections addObject:[self buildSettingsSection]];
    [sections addObject:[self makeSeparator]];

    // 5. Tab View (Pens + Global)
    [sections addObject:[self buildTabViewSection]];

    NSStackView *stack = [NSStackView stackViewWithViews:sections];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    ALOFF(stack);

    [panel addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-8],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-8],
    ]];

    return panel;
}

- (NSBox *)makeSeparator {
    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    ALOFF(sep);
    [sep.widthAnchor constraintGreaterThanOrEqualToConstant:240].active = YES;
    return sep;
}

#pragma mark - Connection Section

- (NSView *)buildConnectionSection {
    NSTextField *title = [self makeBoldLabel:@"Connection"];

    self.connectButton = [self makeButton:@"Connect" action:@selector(connectLaser:)];
    NSButton *disconnectBtn = [self makeButton:@"Disconnect" action:@selector(disconnectLaser:)];

    NSStackView *btnRow = [NSStackView stackViewWithViews:@[self.connectButton, disconnectBtn]];
    btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btnRow.spacing = 8;
    ALOFF(btnRow);

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, btnRow]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    ALOFF(stack);
    return stack;
}

#pragma mark - Laser Control Section (Home only)

- (NSView *)buildLaserControlSection {
    NSTextField *title = [self makeBoldLabel:@"Laser Control"];

    self.homeButton = [self makeButton:@"Home" action:@selector(homeLaser:)];

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, self.homeButton]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    ALOFF(stack);
    return stack;
}

#pragma mark - Jog Section

- (NSView *)buildJogSection {
    NSTextField *title = [self makeBoldLabel:@"Jog Control"];

    // Step distance
    NSTextField *stepLabel = [self makeLabel:@"Step:"];
    self.jogDistancePopup = [[NSPopUpButton alloc] init];
    [self.jogDistancePopup addItemsWithTitles:@[@"0.01\"", @"0.05\"", @"0.1\"", @"0.25\"", @"0.5\"", @"1.0\""]];
    [self.jogDistancePopup selectItemAtIndex:4];
    self.jogDistancePopup.target = self;
    self.jogDistancePopup.action = @selector(jogDistanceChanged:);
    ALOFF(self.jogDistancePopup);

    NSStackView *stepRow = [NSStackView stackViewWithViews:@[stepLabel, self.jogDistancePopup]];
    stepRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stepRow.spacing = 4;
    ALOFF(stepRow);

    // Arrow buttons in a grid-like arrangement
    NSButton *upBtn = [self makeButton:@"  ↑  " action:@selector(jogUp:)];
    NSButton *downBtn = [self makeButton:@"  ↓  " action:@selector(jogDown:)];
    NSButton *leftBtn = [self makeButton:@"  ←  " action:@selector(jogLeft:)];
    NSButton *rightBtn = [self makeButton:@"  →  " action:@selector(jogRight:)];

    // Store jog button references for safety state management
    _jogButtons[0] = upBtn;
    _jogButtons[1] = downBtn;
    _jogButtons[2] = leftBtn;
    _jogButtons[3] = rightBtn;

    // Middle row: Left [space] Right
    NSView *spacer = [[NSView alloc] init];
    ALOFF(spacer);
    [spacer.widthAnchor constraintEqualToConstant:40].active = YES;

    NSStackView *midRow = [NSStackView stackViewWithViews:@[leftBtn, spacer, rightBtn]];
    midRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    midRow.spacing = 4;
    ALOFF(midRow);

    // Center up/down using alignment
    NSStackView *jogGrid = [NSStackView stackViewWithViews:@[upBtn, midRow, downBtn]];
    jogGrid.orientation = NSUserInterfaceLayoutOrientationVertical;
    jogGrid.alignment = NSLayoutAttributeCenterX;
    jogGrid.spacing = 2;
    ALOFF(jogGrid);

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, stepRow, jogGrid]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    ALOFF(stack);
    return stack;
}

#pragma mark - Focus / Z-Axis Section

- (NSView *)buildFocusSection {
    NSTextField *title = [self makeBoldLabel:@"Focus / Z-Axis"];

    // Focus offset slider: -0.5" to +0.5"
    NSTextField *offsetTitle = [self makeLabel:@"Focus Offset:"];
    self.focusOffsetSlider = [[NSSlider alloc] init];
    self.focusOffsetSlider.minValue = -50;  // stored as 1/100 inch
    self.focusOffsetSlider.maxValue = 50;
    self.focusOffsetSlider.intValue = 0;
    self.focusOffsetSlider.continuous = YES;
    self.focusOffsetSlider.target = self;
    self.focusOffsetSlider.action = @selector(focusOffsetChanged:);
    ALOFF(self.focusOffsetSlider);
    [self.focusOffsetSlider.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;

    self.focusOffsetLabel = [[NSTextField alloc] init];
    self.focusOffsetLabel.floatValue = 0.0f;
    self.focusOffsetLabel.font = [NSFont systemFontOfSize:12];
    self.focusOffsetLabel.alignment = NSTextAlignmentRight;
    self.focusOffsetLabel.target = self;
    self.focusOffsetLabel.action = @selector(focusOffsetFieldChanged:);
    ALOFF(self.focusOffsetLabel);
    [self.focusOffsetLabel.widthAnchor constraintEqualToConstant:45].active = YES;

    NSTextField *inLabel = [self makeLabel:@"in"];

    NSStackView *sliderRow = [NSStackView stackViewWithViews:@[offsetTitle, self.focusOffsetSlider, self.focusOffsetLabel, inLabel]];
    sliderRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    sliderRow.spacing = 4;
    ALOFF(sliderRow);

    // Set Focus button
    NSButton *setFocusBtn = [self makeButton:@"Set Focus" action:@selector(setFocus:)];

    // Material thickness helper
    NSTextField *thickLabel = [self makeLabel:@"Material Thickness:"];
    NSTextField *thickField = [[NSTextField alloc] init];
    thickField.floatValue = 0.125f;
    thickField.font = [NSFont systemFontOfSize:12];
    thickField.alignment = NSTextAlignmentRight;
    thickField.target = self;
    thickField.action = @selector(materialThicknessChanged:);
    ALOFF(thickField);
    [thickField.widthAnchor constraintEqualToConstant:45].active = YES;
    NSTextField *inLabel2 = [self makeLabel:@"in"];

    NSStackView *thickRow = [NSStackView stackViewWithViews:@[thickLabel, thickField, inLabel2]];
    thickRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    thickRow.spacing = 4;
    ALOFF(thickRow);

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, sliderRow, setFocusBtn, thickRow]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    ALOFF(stack);
    return stack;
}

#pragma mark - Settings Section (Material, Power, Speed with numeric input)

- (NSView *)buildSettingsSection {
    NSTextField *title = [self makeBoldLabel:@"Settings"];

    // Material
    NSTextField *matLabel = [self makeLabel:@"Material:"];
    self.materialPopup = [[NSPopUpButton alloc] init];
    [self.materialPopup addItemsWithTitles:@[@"Custom", @"Acrylic", @"Wood", @"Paper",
                                              @"Leather", @"Fabric", @"Rubber", @"Glass",
                                              @"Metal Marking", @"Stone"]];
    self.materialPopup.target = self;
    self.materialPopup.action = @selector(materialChanged:);
    ALOFF(self.materialPopup);

    NSStackView *matRow = [NSStackView stackViewWithViews:@[matLabel, self.materialPopup]];
    matRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    matRow.spacing = 4;
    ALOFF(matRow);

    // Power: label + editable field + slider
    NSTextField *pwrTitle = [self makeLabel:@"Power:"];
    self.powerLabel = [[NSTextField alloc] init];
    self.powerLabel.intValue = 50;
    self.powerLabel.font = [NSFont systemFontOfSize:12];
    self.powerLabel.alignment = NSTextAlignmentRight;
    self.powerLabel.target = self;
    self.powerLabel.action = @selector(powerFieldChanged:);
    ALOFF(self.powerLabel);
    [self.powerLabel.widthAnchor constraintEqualToConstant:40].active = YES;
    NSTextField *pwrPercent = [self makeLabel:@"%"];

    NSStackView *pwrLabelRow = [NSStackView stackViewWithViews:@[pwrTitle, self.powerLabel, pwrPercent]];
    pwrLabelRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pwrLabelRow.spacing = 2;
    ALOFF(pwrLabelRow);

    self.powerSlider = [[NSSlider alloc] init];
    self.powerSlider.minValue = 0;
    self.powerSlider.maxValue = 100;
    self.powerSlider.intValue = 50;
    self.powerSlider.target = self;
    self.powerSlider.action = @selector(powerSliderChanged:);
    ALOFF(self.powerSlider);
    [self.powerSlider.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;

    // Speed: label + editable field + slider
    NSTextField *spdTitle = [self makeLabel:@"Speed:"];
    self.speedLabel = [[NSTextField alloc] init];
    self.speedLabel.intValue = 50;
    self.speedLabel.font = [NSFont systemFontOfSize:12];
    self.speedLabel.alignment = NSTextAlignmentRight;
    self.speedLabel.target = self;
    self.speedLabel.action = @selector(speedFieldChanged:);
    ALOFF(self.speedLabel);
    [self.speedLabel.widthAnchor constraintEqualToConstant:40].active = YES;
    NSTextField *spdPercent = [self makeLabel:@"%"];

    NSStackView *spdLabelRow = [NSStackView stackViewWithViews:@[spdTitle, self.speedLabel, spdPercent]];
    spdLabelRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    spdLabelRow.spacing = 2;
    ALOFF(spdLabelRow);

    self.speedSlider = [[NSSlider alloc] init];
    self.speedSlider.minValue = 0;
    self.speedSlider.maxValue = 100;
    self.speedSlider.intValue = 50;
    self.speedSlider.target = self;
    self.speedSlider.action = @selector(speedSliderChanged:);
    ALOFF(self.speedSlider);
    [self.speedSlider.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, matRow, pwrLabelRow, self.powerSlider, spdLabelRow, self.speedSlider]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    ALOFF(stack);
    return stack;
}

#pragma mark - Tab View Section (Pen Colors + Global)

- (NSView *)buildTabViewSection {
    self.settingsTabView = [[NSTabView alloc] init];
    self.settingsTabView.tabViewType = NSTopTabsBezelBorder;
    self.settingsTabView.controlSize = NSControlSizeSmall;
    ALOFF(self.settingsTabView);
    [self.settingsTabView.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    [self.settingsTabView.heightAnchor constraintEqualToConstant:320].active = YES;

    NSTabViewItem *penTab = [[NSTabViewItem alloc] initWithIdentifier:@"pens"];
    penTab.label = @"Pen Colors";
    [self setupPenSettingsTab:penTab];
    [self.settingsTabView addTabViewItem:penTab];

    NSTabViewItem *globalTab = [[NSTabViewItem alloc] initWithIdentifier:@"global"];
    globalTab.label = @"Global";
    [self setupGlobalSettingsTab:globalTab];
    [self.settingsTabView addTabViewItem:globalTab];

    NSTabViewItem *debugTab = [[NSTabViewItem alloc] initWithIdentifier:@"debug"];
    debugTab.label = @"Debug";
    [self setupDebugTab:debugTab];
    [self.settingsTabView addTabViewItem:debugTab];

    return self.settingsTabView;
}

#pragma mark - Pen Settings Tab

- (void)setupPenSettingsTab:(NSTabViewItem *)tab {
    NSView *container = tab.view;

    NSMutableArray *rows = [NSMutableArray array];

    // Header
    NSStackView *header = [self penRowWithColorBox:nil name:@"Color" mode:@"Mode" power:@"Pwr%" speed:@"Spd%" ppi:@"PPI" index:-1];
    [rows addObject:header];

    NSArray *colorNames = @[@"Black", @"Red", @"Green", @"Yellow", @"Blue", @"Magenta", @"Cyan", @"Orange"];
    NSArray *colors = @[
        [NSColor blackColor],
        [NSColor redColor],
        [NSColor colorWithRed:0 green:0.7 blue:0 alpha:1],
        [NSColor colorWithRed:0.8 green:0.8 blue:0 alpha:1],
        [NSColor blueColor],
        [NSColor magentaColor],
        [NSColor cyanColor],
        [NSColor orangeColor]
    ];

    for (int i = 0; i < 8; i++) {
        NSStackView *row = [self penRowWithColorBox:colors[i] name:colorNames[i] mode:nil power:nil speed:nil ppi:nil index:i];
        [rows addObject:row];
    }

    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 2;
    ALOFF(stack);

    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:4],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:4],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-4],
    ]];
}

- (NSStackView *)penRowWithColorBox:(NSColor *)color name:(NSString *)name mode:(NSString *)mode power:(NSString *)power speed:(NSString *)speed ppi:(NSString *)ppi index:(int)idx {

    NSMutableArray *items = [NSMutableArray array];

    if (idx < 0) {
        // Header row - labels only
        NSTextField *nameL = [self makeLabel:name];
        nameL.font = [NSFont boldSystemFontOfSize:9];
        [nameL.widthAnchor constraintEqualToConstant:52].active = YES;
        [items addObject:nameL];

        NSTextField *modeL = [self makeLabel:mode];
        modeL.font = [NSFont boldSystemFontOfSize:9];
        [modeL.widthAnchor constraintEqualToConstant:56].active = YES;
        [items addObject:modeL];

        NSTextField *pwrL = [self makeLabel:power];
        pwrL.font = [NSFont boldSystemFontOfSize:9];
        [pwrL.widthAnchor constraintEqualToConstant:50].active = YES;
        [items addObject:pwrL];

        NSTextField *spdL = [self makeLabel:speed];
        spdL.font = [NSFont boldSystemFontOfSize:9];
        [spdL.widthAnchor constraintEqualToConstant:50].active = YES;
        [items addObject:spdL];

        NSTextField *ppiL = [self makeLabel:ppi];
        ppiL.font = [NSFont boldSystemFontOfSize:9];
        [ppiL.widthAnchor constraintEqualToConstant:38].active = YES;
        [items addObject:ppiL];
    } else {
        // Color box + name
        NSView *colorBox = [[NSView alloc] init];
        colorBox.wantsLayer = YES;
        colorBox.layer.backgroundColor = [color CGColor];
        colorBox.layer.borderWidth = 1;
        colorBox.layer.borderColor = [[NSColor grayColor] CGColor];
        ALOFF(colorBox);
        [colorBox.widthAnchor constraintEqualToConstant:12].active = YES;
        [colorBox.heightAnchor constraintEqualToConstant:12].active = YES;

        NSTextField *nameLabel = [self makeLabel:name];
        nameLabel.font = [NSFont systemFontOfSize:9];

        NSStackView *nameStack = [NSStackView stackViewWithViews:@[colorBox, nameLabel]];
        nameStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        nameStack.spacing = 2;
        ALOFF(nameStack);
        [nameStack.widthAnchor constraintEqualToConstant:52].active = YES;
        [items addObject:nameStack];

        // Mode button
        NSButton *modeBtn = [[NSButton alloc] init];
        modeBtn.title = @"R/V";
        modeBtn.bezelStyle = NSBezelStyleSmallSquare;
        modeBtn.font = [NSFont systemFontOfSize:8];
        modeBtn.tag = idx;
        modeBtn.target = self;
        modeBtn.action = @selector(penModeChanged:);
        ALOFF(modeBtn);
        [modeBtn.widthAnchor constraintEqualToConstant:56].active = YES;
        [modeBtn.heightAnchor constraintEqualToConstant:20].active = YES;
        _penModeButtons[idx] = modeBtn;
        [items addObject:modeBtn];

        // Power: slider + editable field
        NSSlider *pwrSlider = [[NSSlider alloc] init];
        pwrSlider.minValue = 0;
        pwrSlider.maxValue = 100;
        pwrSlider.intValue = 50;
        pwrSlider.tag = idx;
        pwrSlider.target = self;
        pwrSlider.action = @selector(penPowerChanged:);
        ALOFF(pwrSlider);
        [pwrSlider.widthAnchor constraintEqualToConstant:28].active = YES;
        _penPowerSliders[idx] = pwrSlider;

        NSTextField *pwrField = [self makeCompactEditableField:22 tag:idx action:@selector(penPowerFieldChanged:)];
        pwrField.intValue = 50;
        _penPowerFields[idx] = pwrField;

        NSStackView *pwrStack = [NSStackView stackViewWithViews:@[pwrSlider, pwrField]];
        pwrStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        pwrStack.spacing = 0;
        ALOFF(pwrStack);
        [pwrStack.widthAnchor constraintEqualToConstant:50].active = YES;
        [items addObject:pwrStack];

        // Speed: slider + editable field
        NSSlider *spdSlider = [[NSSlider alloc] init];
        spdSlider.minValue = 0;
        spdSlider.maxValue = 100;
        spdSlider.intValue = 50;
        spdSlider.tag = idx;
        spdSlider.target = self;
        spdSlider.action = @selector(penSpeedChanged:);
        ALOFF(spdSlider);
        [spdSlider.widthAnchor constraintEqualToConstant:28].active = YES;
        _penSpeedSliders[idx] = spdSlider;

        NSTextField *spdField = [self makeCompactEditableField:22 tag:idx action:@selector(penSpeedFieldChanged:)];
        spdField.intValue = 50;
        _penSpeedFields[idx] = spdField;

        NSStackView *spdStack = [NSStackView stackViewWithViews:@[spdSlider, spdField]];
        spdStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        spdStack.spacing = 0;
        ALOFF(spdStack);
        [spdStack.widthAnchor constraintEqualToConstant:50].active = YES;
        [items addObject:spdStack];

        // PPI field
        NSTextField *ppiField = [[NSTextField alloc] init];
        ppiField.intValue = 500;
        ppiField.tag = idx;
        ppiField.target = self;
        ppiField.action = @selector(penPPIChanged:);
        ppiField.font = [NSFont systemFontOfSize:9];
        ALOFF(ppiField);
        [ppiField.widthAnchor constraintEqualToConstant:38].active = YES;
        _penPPIFields[idx] = ppiField;
        [items addObject:ppiField];
    }

    NSStackView *row = [NSStackView stackViewWithViews:items];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 3;
    ALOFF(row);
    return row;
}

#pragma mark - Global Settings Tab

- (void)setupGlobalSettingsTab:(NSTabViewItem *)tab {
    NSView *container = tab.view;
    NSMutableArray *rows = [NSMutableArray array];

    // Print Mode
    {
        NSTextField *label = [self makeLabel:@"Print Mode:"];
        self.printModePopup = [[NSPopUpButton alloc] init];
        [self.printModePopup addItemsWithTitles:@[@"Normal", @"Clipart", @"3D", @"Rubber Stamp"]];
        self.printModePopup.target = self;
        self.printModePopup.action = @selector(printModeChanged:);
        ALOFF(self.printModePopup);

        NSStackView *row = [NSStackView stackViewWithViews:@[label, self.printModePopup]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 4;
        ALOFF(row);
        [rows addObject:row];
    }

    // Image Density
    {
        NSTextField *label = [self makeLabel:@"Image Density:"];
        self.imageDensityPopup = [[NSPopUpButton alloc] init];
        [self.imageDensityPopup addItemsWithTitles:@[@"1 (Fast)", @"2", @"3", @"4", @"5", @"6 (Std)", @"7", @"8 (High)"]];
        [self.imageDensityPopup selectItemAtIndex:5];
        self.imageDensityPopup.target = self;
        self.imageDensityPopup.action = @selector(imageDensityChanged:);
        ALOFF(self.imageDensityPopup);

        NSStackView *row = [NSStackView stackViewWithViews:@[label, self.imageDensityPopup]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 4;
        ALOFF(row);
        [rows addObject:row];
    }

    // Gas Assist
    {
        NSTextField *label = [self makeLabel:@"Gas Assist:"];
        self.gasAssistModePopup = [[NSPopUpButton alloc] init];
        [self.gasAssistModePopup addItemsWithTitles:@[@"Manual", @"Auto"]];
        [self.gasAssistModePopup selectItemAtIndex:1];
        self.gasAssistModePopup.target = self;
        self.gasAssistModePopup.action = @selector(gasAssistModeChanged:);
        ALOFF(self.gasAssistModePopup);

        NSStackView *row = [NSStackView stackViewWithViews:@[label, self.gasAssistModePopup]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 4;
        ALOFF(row);
        [rows addObject:row];
    }

    // Separator
    [rows addObject:[self makeSeparator]];

    // Engraving Field
    {
        NSTextField *title = [self makeBoldLabel:@"Engraving Field"];
        [rows addObject:title];

        NSTextField *wLabel = [self makeLabel:@"Width (in):"];
        self.pageWidthField = [self makeEditableField:50];
        self.pageWidthField.floatValue = 24.0;
        self.pageWidthField.target = self;
        self.pageWidthField.action = @selector(pageSizeChanged:);

        NSTextField *hLabel = [self makeLabel:@"Height:"];
        self.pageHeightField = [self makeEditableField:50];
        self.pageHeightField.floatValue = 12.0;
        self.pageHeightField.target = self;
        self.pageHeightField.action = @selector(pageSizeChanged:);

        NSStackView *sizeRow = [NSStackView stackViewWithViews:@[wLabel, self.pageWidthField, hLabel, self.pageHeightField]];
        sizeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        sizeRow.spacing = 4;
        ALOFF(sizeRow);
        [rows addObject:sizeRow];

        NSTextField *oLabel = [self makeLabel:@"Orientation:"];
        self.orientationPopup = [[NSPopUpButton alloc] init];
        [self.orientationPopup addItemsWithTitles:@[@"Landscape", @"Portrait"]];
        self.orientationPopup.target = self;
        self.orientationPopup.action = @selector(orientationChanged:);
        ALOFF(self.orientationPopup);

        NSStackView *oRow = [NSStackView stackViewWithViews:@[oLabel, self.orientationPopup]];
        oRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        oRow.spacing = 4;
        ALOFF(oRow);
        [rows addObject:oRow];
    }

    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    ALOFF(stack);

    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
    ]];
}

#pragma mark - Debug Tab

- (void)setupDebugTab:(NSTabViewItem *)tab {
    NSView *container = tab.view;

    /* Create the debug panel controller */
    self.debugPanelController = [[ULSDebugPanelController alloc] init];

    /* Add its view to the tab */
    NSView *debugView = self.debugPanelController.view;
    [container addSubview:debugView];

    /* Constrain debug view to fill container */
    [NSLayoutConstraint activateConstraints:@[
        [debugView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [debugView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [debugView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [debugView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
}

#pragma mark - UI State (with safety management)

- (void)updateUIState {
    BOOL connected = self.isConnected;
    BOOL idle = (_operationState == ULSOperationStateIdle);
    BOOL running = (_operationState == ULSOperationStateRunning);
    BOOL paused = (_operationState == ULSOperationStatePaused);
    BOOL simulating = (_simTimer != nil);

    // Connection controls
    self.connectButton.enabled = !connected && !simulating;

    // Laser control
    self.homeButton.enabled = connected && idle && !simulating;

    // Transport controls
    self.startButton.enabled = connected && (idle || paused) && self.currentJob != NULL && !simulating;
    self.startButton.title = paused ? @"Resume" : @"Start";
    self.pauseButton.enabled = (connected && running) || simulating;
    self.stopButton.enabled = (connected && (running || paused)) || simulating;

    // Simulate button
    _simulateButton.enabled = self.currentJob != NULL && idle && !simulating;

    // Jog controls - disabled during operation or simulation
    for (int i = 0; i < 4; i++) {
        if (_jogButtons[i]) _jogButtons[i].enabled = connected && idle && !simulating;
    }
    self.jogDistancePopup.enabled = connected && idle && !simulating;
    self.modeControl.enabled = idle && !simulating;

    // Settings controls - disabled during operation or simulation
    self.powerSlider.enabled = connected && idle && !simulating;
    self.speedSlider.enabled = connected && idle && !simulating;
    self.materialPopup.enabled = idle && !simulating;

    // Preview click interaction disabled during operation
    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    if (running || paused || simulating) {
        preview.interactionMode = ULSInteractionModeDesign;
    }

    // Status display
    if (simulating) {
        self.statusLabel.stringValue = @"Status: Simulating";
        self.statusLabel.textColor = [NSColor systemPurpleColor];
    } else if (connected) {
        if (running) {
            self.statusLabel.stringValue = @"Status: Running";
            self.statusLabel.textColor = [NSColor systemOrangeColor];
        } else if (paused) {
            self.statusLabel.stringValue = @"Status: Paused";
            self.statusLabel.textColor = [NSColor systemYellowColor];
        } else {
            self.statusLabel.stringValue = @"Status: Connected";
            self.statusLabel.textColor = [NSColor systemGreenColor];
        }
    } else {
        self.statusLabel.stringValue = @"Status: Disconnected";
        self.statusLabel.textColor = [NSColor labelColor];
        self.deviceLabel.stringValue = @"Device: None";
        self.positionLabel.stringValue = @"Position: X: 0.00 Y: 0.00";
    }
}

#pragma mark - Actions

- (IBAction)connectLaser:(id)sender {
    ULSDeviceInfo *devices = NULL;
    int count = 0;

    ULSError err = uls_find_devices(&devices, &count);
    if (err == ULS_SUCCESS && count > 0) {
        self.device = uls_open_device(devices[0].vendorId, devices[0].productId);
        if (self.device) {
            self.isConnected = YES;
            self.deviceLabel.stringValue = [NSString stringWithFormat:@"Device: %s",
                                            uls_model_string(devices[0].model)];
            [NSTimer scheduledTimerWithTimeInterval:0.5
                                             target:self
                                           selector:@selector(updatePosition:)
                                           userInfo:nil
                                            repeats:YES];
            /* Update debug panel with device */
            [self.debugPanelController setDevice:self.device];
            [self.debugPanelController startAutoRefresh];
        }
        uls_free_device_list(devices, count);
    } else {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Device Found";
        alert.informativeText = @"No ULS laser device was found. Please check the USB connection and try again.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
    [self updateUIState];
}

- (IBAction)disconnectLaser:(id)sender {
    // Safety: don't disconnect while running
    if (_operationState != ULSOperationStateIdle) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Operation In Progress";
        alert.informativeText = @"Stop the current operation before disconnecting.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        return;
    }

    if (self.device) {
        /* Stop debug panel refresh before closing */
        [self.debugPanelController stopAutoRefresh];
        [self.debugPanelController setDevice:NULL];

        uls_close_device(self.device);
        self.device = NULL;
        self.isConnected = NO;
    }
    [self updateUIState];
}

- (IBAction)homeLaser:(id)sender {
    if (self.device && _operationState == ULSOperationStateIdle) {
        ULSError err = uls_home(self.device);
        if (err != ULS_SUCCESS) {
            [self showError:@"Home Failed" message:uls_error_string(err)];
        }
    }
}

- (IBAction)startJob:(id)sender {
    if (!self.device || !self.currentJob) return;

    if (_operationState == ULSOperationStatePaused) {
        // Resume
        ULSError err = uls_resume_job(self.device);
        if (err != ULS_SUCCESS) {
            [self showError:@"Resume Failed" message:uls_error_string(err)];
            return;
        }
        _operationState = ULSOperationStateRunning;
        [self updateUIState];
        return;
    }

    // Safety: check device state before starting
    ULSDeviceState state;
    ULSError err = uls_get_status(self.device, &state);
    if (err != ULS_SUCCESS) {
        [self showError:@"Status Check Failed" message:uls_error_string(err)];
        return;
    }
    if (state == ULS_STATE_BUSY) {
        [self showError:@"Device Busy" message:"The device is currently busy. Please wait or stop the current operation."];
        return;
    }
    if (state == ULS_STATE_ERROR) {
        [self showError:@"Device Error" message:"The device is in an error state. Please check the device and try again."];
        return;
    }

    // Compile job if needed
    if (!self.currentJob->isCompiled) {
        err = uls_job_compile(self.currentJob);
        if (err != ULS_SUCCESS) {
            [self showError:@"Compilation Failed" message:uls_error_string(err)];
            return;
        }
    }

    // Send job data
    err = uls_job_send(self.currentJob, self.device);
    if (err != ULS_SUCCESS) {
        [self showError:@"Send Failed" message:uls_error_string(err)];
        return;
    }

    // Start job
    err = uls_start_job(self.device);
    if (err != ULS_SUCCESS) {
        [self showError:@"Start Failed" message:uls_error_string(err)];
        return;
    }

    _operationState = ULSOperationStateRunning;
    _jobStartTime = [NSDate date];
    self.progressIndicator.doubleValue = 0;
    self.elapsedTimeLabel.stringValue = @"0:00";

    // Start progress monitoring timer
    _progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                     target:self
                                                   selector:@selector(updateJobProgress:)
                                                   userInfo:nil
                                                    repeats:YES];
    [self updateUIState];
}

- (IBAction)pauseJob:(id)sender {
    // Pause simulation
    if (_simTimer) {
        [_simTimer invalidate];
        _simTimer = nil;
        [self updateUIState];
        return;
    }

    if (self.device && _operationState == ULSOperationStateRunning) {
        ULSError err = uls_pause_job(self.device);
        if (err != ULS_SUCCESS) {
            [self showError:@"Pause Failed" message:uls_error_string(err)];
            return;
        }
        _operationState = ULSOperationStatePaused;
        [self updateUIState];
    }
}

- (IBAction)stopJob:(id)sender {
    // Stop simulation
    if (_simTimer || _simulation) {
        [self stopSimulation];
        return;
    }

    if (self.device && (_operationState == ULSOperationStateRunning || _operationState == ULSOperationStatePaused)) {
        ULSError err = uls_stop_job(self.device);
        if (err != ULS_SUCCESS) {
            [self showError:@"Stop Failed" message:uls_error_string(err)];
        }
        [self jobCompleted];
    }
}

#pragma mark - Simulation Playback

- (void)simulateJob:(id)sender {
    if (!self.currentJob || _simTimer) return;

    // Create simulation from current job
    if (_simulation) {
        uls_simulation_destroy(_simulation);
        _simulation = NULL;
    }
    _simulation = uls_job_simulate(self.currentJob);
    if (!_simulation || _simulation->numPoints == 0) {
        [self showError:@"Simulation Failed" message:"No path data to simulate."];
        return;
    }

    // Setup preview for simulation
    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    preview.simulation = _simulation;
    preview.simCurrentIndex = 0;
    preview.simulating = YES;

    _simTime = 0;
    self.progressIndicator.doubleValue = 0;
    self.elapsedTimeLabel.stringValue = @"0:00";

    // Show total simulation time
    int totalMin = (int)(_simulation->totalTime / 60);
    int totalSec = (int)_simulation->totalTime % 60;
    self.estimatedTimeLabel.stringValue = [NSString stringWithFormat:@"Est: %d:%02d", totalMin, totalSec];

    // Start animation timer (~60fps)
    _simTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                 target:self
                                               selector:@selector(updateSimulation:)
                                               userInfo:nil
                                                repeats:YES];
    [self updateUIState];
}

- (void)updateSimulation:(NSTimer *)timer {
    if (!_simulation) {
        [self stopSimulation];
        return;
    }

    // Advance simulation time
    float dt = (1.0f / 60.0f) * _simPlaybackSpeed;
    _simTime += dt;

    if (_simTime >= _simulation->totalTime) {
        _simTime = _simulation->totalTime;
        // Simulation complete
        [self simulationCompleted];
        return;
    }

    // Update progress bar
    double progress = (_simTime / _simulation->totalTime) * 100.0;
    self.progressIndicator.doubleValue = progress;

    // Update elapsed time display (simulation time)
    int minutes = (int)(_simTime / 60);
    int seconds = (int)_simTime % 60;
    self.elapsedTimeLabel.stringValue = [NSString stringWithFormat:@"%d:%02d", minutes, seconds];

    // Update crosshair position from simulation
    float sx, sy;
    bool laserOn;
    uls_simulation_get_position(_simulation, _simTime, &sx, &sy, &laserOn);

    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    preview.toolX = sx;
    preview.toolY = sy;
    preview.simCurrentIndex = uls_simulation_index_at_time(_simulation, _simTime);

    self.positionLabel.stringValue = [NSString stringWithFormat:@"Position: X: %.2f Y: %.2f%s",
                                      sx, sy, laserOn ? " [LASER]" : ""];

    [preview setNeedsDisplay:YES];
}

- (void)stopSimulation {
    [_simTimer invalidate];
    _simTimer = nil;

    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    preview.simulating = NO;
    preview.simulation = NULL;
    preview.simCurrentIndex = 0;

    if (_simulation) {
        uls_simulation_destroy(_simulation);
        _simulation = NULL;
    }

    // Restore mode
    preview.interactionMode = _interactionMode;
    [preview setNeedsDisplay:YES];
    [self updateUIState];
}

- (void)simulationCompleted {
    [_simTimer invalidate];
    _simTimer = nil;

    self.progressIndicator.doubleValue = 100;

    int minutes = (int)(_simulation->totalTime / 60);
    int seconds = (int)_simulation->totalTime % 60;
    self.elapsedTimeLabel.stringValue = [NSString stringWithFormat:@"%d:%02d", minutes, seconds];

    // Leave trace visible for a moment, then clean up
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_simTimer) { // Only cleanup if not restarted
            [self stopSimulation];
        }
    });

    [self updateUIState];
}

- (void)simSpeedChanged:(id)sender {
    float speeds[] = {1.0f, 2.0f, 5.0f, 10.0f, 50.0f};
    NSInteger idx = _simSpeedPopup.indexOfSelectedItem;
    if (idx >= 0 && idx < 5) {
        _simPlaybackSpeed = speeds[idx];
    }
}

#pragma mark - Job Progress Monitoring

- (void)updateJobProgress:(NSTimer *)timer {
    if (!self.device || !self.isConnected || _operationState == ULSOperationStateIdle) {
        [self jobCompleted];
        return;
    }

    // Update elapsed time
    NSTimeInterval elapsed = -[_jobStartTime timeIntervalSinceNow];
    int minutes = (int)(elapsed / 60);
    int seconds = (int)elapsed % 60;
    self.elapsedTimeLabel.stringValue = [NSString stringWithFormat:@"%d:%02d", minutes, seconds];

    // Update progress bar (estimate based on elapsed time vs estimated total)
    float estimatedSeconds = 0;
    uls_job_get_estimated_time(self.currentJob, &estimatedSeconds);
    if (estimatedSeconds > 0) {
        double progress = (elapsed / estimatedSeconds) * 100.0;
        if (progress > 100) progress = 99; // Don't show 100% until actually done
        self.progressIndicator.doubleValue = progress;
    }

    // Poll device state
    ULSDeviceState state;
    ULSError err = uls_get_status(self.device, &state);
    if (err == ULS_SUCCESS) {
        if (state == ULS_STATE_READY && _operationState == ULSOperationStateRunning) {
            // Job completed
            [self jobCompleted];
        } else if (state == ULS_STATE_ERROR) {
            [self jobError];
        }
    }
}

- (void)jobCompleted {
    [_progressTimer invalidate];
    _progressTimer = nil;
    _operationState = ULSOperationStateIdle;
    self.progressIndicator.doubleValue = 100;

    if (_jobStartTime) {
        NSTimeInterval elapsed = -[_jobStartTime timeIntervalSinceNow];
        int minutes = (int)(elapsed / 60);
        int seconds = (int)elapsed % 60;
        self.elapsedTimeLabel.stringValue = [NSString stringWithFormat:@"%d:%02d", minutes, seconds];
    }

    _jobStartTime = nil;
    [self updateUIState];

    // Restore mode
    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    preview.interactionMode = _interactionMode;
    [preview setNeedsDisplay:YES];
}

- (void)jobError {
    [_progressTimer invalidate];
    _progressTimer = nil;
    _operationState = ULSOperationStateIdle;
    _jobStartTime = nil;
    [self updateUIState];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Job Error";
    alert.informativeText = @"The laser device reported an error during operation. Please check the device.";
    alert.alertStyle = NSAlertStyleCritical;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (IBAction)importSVG:(id)sender {
    // Safety: don't import during operation
    if (_operationState != ULSOperationStateIdle) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"svg"],
        [UTType typeWithFilenameExtension:@"pdf"]
    ];
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            [self loadJobFromFile:panel.URL.path];
        }
    }];
}

- (void)loadJobFromFile:(NSString *)path {
    if (self.currentJob) {
        uls_job_destroy(self.currentJob);
    }
    self.currentJob = uls_job_create([path.lastPathComponent UTF8String]);

    NSString *ext = path.pathExtension.lowercaseString;
    ULSError err;
    if ([ext isEqualToString:@"svg"]) {
        err = [ULSSVGParser parseFile:path intoJob:self.currentJob];
    } else if ([ext isEqualToString:@"pdf"]) {
        err = [ULSPDFParser parseFile:path pageNumber:0 intoJob:self.currentJob];
    } else {
        err = ULS_ERROR_INVALID_PARAM;
    }

    if (err != ULS_SUCCESS) {
        [self showError:@"Import Failed" message:uls_error_string(err)];
        uls_job_destroy(self.currentJob);
        self.currentJob = NULL;
    } else {
        [self updatePreview];
        [self updateEstimatedTime];
    }
    [self updateUIState];
}

- (IBAction)powerSliderChanged:(id)sender {
    int power = self.powerSlider.intValue;
    self.powerLabel.intValue = power;
    if (self.device) {
        uls_set_power(self.device, (uint8_t)power);
    }
}

- (IBAction)speedSliderChanged:(id)sender {
    int speed = self.speedSlider.intValue;
    self.speedLabel.intValue = speed;
    if (self.device) {
        uls_set_speed(self.device, (uint8_t)speed);
    }
    [self updateEstimatedTime];
}

- (IBAction)powerFieldChanged:(id)sender {
    int power = self.powerLabel.intValue;
    if (power < 0) power = 0;
    if (power > 100) power = 100;
    self.powerLabel.intValue = power;
    self.powerSlider.intValue = power;
    if (self.device) {
        uls_set_power(self.device, (uint8_t)power);
    }
}

- (IBAction)speedFieldChanged:(id)sender {
    int speed = self.speedLabel.intValue;
    if (speed < 0) speed = 0;
    if (speed > 100) speed = 100;
    self.speedLabel.intValue = speed;
    self.speedSlider.intValue = speed;
    if (self.device) {
        uls_set_speed(self.device, (uint8_t)speed);
    }
    [self updateEstimatedTime];
}

- (IBAction)materialChanged:(id)sender {
    ULSMaterialType material = (ULSMaterialType)self.materialPopup.indexOfSelectedItem;
    ULSLaserSettings settings;
    uls_get_material_settings(material, self.device ? self.device->info.model : ULS_MODEL_UNKNOWN, &settings);
    self.powerSlider.intValue = settings.power;
    self.speedSlider.intValue = settings.speed;
    [self powerSliderChanged:nil];
    [self speedSliderChanged:nil];
}

#pragma mark - Interaction Mode

- (IBAction)interactionModeChanged:(id)sender {
    NSSegmentedControl *control = (NSSegmentedControl *)sender;
    _interactionMode = (ULSInteractionMode)control.selectedSegment;
    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    preview.interactionMode = _interactionMode;
    [preview setNeedsDisplay:YES];
}

#pragma mark - Jog Controls

- (IBAction)jogDistanceChanged:(id)sender {
    float distances[] = {0.01f, 0.05f, 0.1f, 0.25f, 0.5f, 1.0f};
    NSInteger idx = self.jogDistancePopup.indexOfSelectedItem;
    if (idx >= 0 && idx < 6) {
        _jogDistance = distances[idx];
    }
}

- (IBAction)jogLeft:(id)sender {
    if (self.device && _operationState == ULSOperationStateIdle) {
        float x, y, z;
        uls_get_position(self.device, &x, &y, &z);
        float newX = x - _jogDistance;
        uls_move_to(self.device, newX, y);
        [self updateToolPositionDisplay:newX y:y];
    }
}

- (IBAction)jogRight:(id)sender {
    if (self.device && _operationState == ULSOperationStateIdle) {
        float x, y, z;
        uls_get_position(self.device, &x, &y, &z);
        float newX = x + _jogDistance;
        uls_move_to(self.device, newX, y);
        [self updateToolPositionDisplay:newX y:y];
    }
}

- (IBAction)jogUp:(id)sender {
    if (self.device && _operationState == ULSOperationStateIdle) {
        float x, y, z;
        uls_get_position(self.device, &x, &y, &z);
        float newY = y - _jogDistance;
        uls_move_to(self.device, x, newY);
        [self updateToolPositionDisplay:x y:newY];
    }
}

- (IBAction)jogDown:(id)sender {
    if (self.device && _operationState == ULSOperationStateIdle) {
        float x, y, z;
        uls_get_position(self.device, &x, &y, &z);
        float newY = y + _jogDistance;
        uls_move_to(self.device, x, newY);
        [self updateToolPositionDisplay:x y:newY];
    }
}

#pragma mark - Focus / Z-Axis Actions

- (IBAction)focusOffsetChanged:(id)sender {
    float offset = self.focusOffsetSlider.intValue / 100.0f;
    self.focusOffsetLabel.floatValue = offset;
    if (self.printerSettings) {
        self.printerSettings->focusOffset = offset;
    }
}

- (IBAction)focusOffsetFieldChanged:(id)sender {
    float offset = self.focusOffsetLabel.floatValue;
    if (offset < -0.5f) offset = -0.5f;
    if (offset > 0.5f)  offset = 0.5f;
    self.focusOffsetLabel.floatValue = offset;
    self.focusOffsetSlider.intValue = (int)(offset * 100);
    if (self.printerSettings) {
        self.printerSettings->focusOffset = offset;
    }
}

- (IBAction)setFocus:(id)sender {
    if (!self.device || !self.isConnected || _operationState != ULSOperationStateIdle) return;

    float offset = self.focusOffsetSlider.intValue / 100.0f;
    // Z is passed as the third component; ULS devices interpret this as focus offset
    // We use uls_move_to with current XY and Z encoded in a control transfer
    // For now, store in printer settings and apply to next job
    if (self.printerSettings) {
        self.printerSettings->focusOffset = offset;
        self.printerSettings->materialThickness = self.printerSettings->materialThickness; // unchanged
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Focus Set";
    alert.informativeText = [NSString stringWithFormat:@"Focus offset set to %.3f inches.\nThis will be applied to the next job.", offset];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (IBAction)materialThicknessChanged:(id)sender {
    NSTextField *field = (NSTextField *)sender;
    float thickness = field.floatValue;
    if (thickness < 0) thickness = 0;
    if (thickness > 4.0f) thickness = 4.0f;
    field.floatValue = thickness;

    if (self.printerSettings) {
        self.printerSettings->materialThickness = thickness;
        // Auto-set focus offset to half the material thickness (standard for cutting)
        float autoOffset = thickness / 2.0f;
        if (autoOffset > 0.5f) autoOffset = 0.5f;
        self.printerSettings->focusOffset = autoOffset;
        self.focusOffsetSlider.intValue = (int)(autoOffset * 100);
        self.focusOffsetLabel.floatValue = autoOffset;
    }
}

#pragma mark - Preview Callbacks

- (void)moveToolToX:(float)x y:(float)y {
    // Safety: don't move tool during operation
    if (_operationState != ULSOperationStateIdle) return;

    if (self.device && self.isConnected) {
        uls_move_to(self.device, x, y);
    }
    [self updateToolPositionDisplay:x y:y];
}

- (void)designPositionChangedToX:(float)x y:(float)y {
    _designOffsetX = x;
    _designOffsetY = y;
    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    preview.designOffsetX = x;
    preview.designOffsetY = y;
    [preview setNeedsDisplay:YES];
}

#pragma mark - Helpers

- (void)updateToolPositionDisplay:(float)x y:(float)y {
    self.positionLabel.stringValue = [NSString stringWithFormat:@"Position: X: %.2f Y: %.2f", x, y];
    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    preview.toolX = x;
    preview.toolY = y;
    [preview setNeedsDisplay:YES];
}

- (void)updatePosition:(NSTimer *)timer {
    if (self.device && self.isConnected) {
        float x, y, z;
        if (uls_get_position(self.device, &x, &y, &z) == ULS_SUCCESS) {
            [self updateToolPositionDisplay:x y:y];
        }
    }
}

- (void)updatePreview {
    ULSPreviewView *preview = (ULSPreviewView *)self.previewView;
    if (self.printerSettings) {
        preview.pageWidth = self.printerSettings->pageWidth;
        preview.pageHeight = self.printerSettings->pageHeight;
    }
    preview.currentJob = self.currentJob;
    preview.designOffsetX = _designOffsetX;
    preview.designOffsetY = _designOffsetY;
    [preview setNeedsDisplay:YES];
}

- (void)showError:(NSString *)title message:(const char *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = [NSString stringWithUTF8String:message];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

#pragma mark - Pen Settings Actions

- (void)updatePenSettingsUI {
    if (!self.printerSettings) return;

    NSString *modeStrings[] = {@"R/V", @"RAST", @"VECT", @"SKIP"};

    for (int i = 0; i < 8; i++) {
        ULSPenSettings *pen = &self.printerSettings->pens[i];

        _penModeButtons[i].title = modeStrings[pen->mode];

        _penPowerSliders[i].intValue = pen->power;
        _penPowerFields[i].intValue = pen->power;

        _penSpeedSliders[i].intValue = pen->speed;
        _penSpeedFields[i].intValue = pen->speed;

        _penPPIFields[i].intValue = pen->ppi;
    }

    [self.printModePopup selectItemAtIndex:self.printerSettings->printMode];
    [self.imageDensityPopup selectItemAtIndex:self.printerSettings->imageDensity - 1];
    [self.gasAssistModePopup selectItemAtIndex:self.printerSettings->gasAssistMode];
}

- (IBAction)penModeChanged:(id)sender {
    NSButton *btn = (NSButton *)sender;
    int colorIndex = (int)btn.tag;

    ULSPenMode currentMode = self.printerSettings->pens[colorIndex].mode;
    ULSPenMode newMode = (currentMode + 1) % 4;
    uls_pen_set_mode(self.printerSettings, (ULSPenColor)colorIndex, newMode);

    NSString *modeStrings[] = {@"R/V", @"RAST", @"VECT", @"SKIP"};
    btn.title = modeStrings[newMode];
}

- (IBAction)penPowerChanged:(id)sender {
    NSSlider *slider = (NSSlider *)sender;
    int colorIndex = (int)slider.tag;
    int power = slider.intValue;
    uls_pen_set_power(self.printerSettings, (ULSPenColor)colorIndex, power);
    _penPowerFields[colorIndex].intValue = power;
}

- (IBAction)penPowerFieldChanged:(id)sender {
    NSTextField *field = (NSTextField *)sender;
    int colorIndex = (int)field.tag;
    int power = field.intValue;
    if (power < 0) power = 0;
    if (power > 100) power = 100;
    field.intValue = power;
    _penPowerSliders[colorIndex].intValue = power;
    uls_pen_set_power(self.printerSettings, (ULSPenColor)colorIndex, power);
}

- (IBAction)penSpeedChanged:(id)sender {
    NSSlider *slider = (NSSlider *)sender;
    int colorIndex = (int)slider.tag;
    int speed = slider.intValue;
    uls_pen_set_speed(self.printerSettings, (ULSPenColor)colorIndex, speed);
    _penSpeedFields[colorIndex].intValue = speed;
}

- (IBAction)penSpeedFieldChanged:(id)sender {
    NSTextField *field = (NSTextField *)sender;
    int colorIndex = (int)field.tag;
    int speed = field.intValue;
    if (speed < 0) speed = 0;
    if (speed > 100) speed = 100;
    field.intValue = speed;
    _penSpeedSliders[colorIndex].intValue = speed;
    uls_pen_set_speed(self.printerSettings, (ULSPenColor)colorIndex, speed);
}

- (IBAction)penPPIChanged:(id)sender {
    NSTextField *field = (NSTextField *)sender;
    int colorIndex = (int)field.tag;
    int ppi = field.intValue;
    if (ppi < 1) ppi = 1;
    if (ppi > 1000) ppi = 1000;
    field.intValue = ppi;
    uls_pen_set_ppi(self.printerSettings, (ULSPenColor)colorIndex, ppi);
}

- (IBAction)penGasAssistChanged:(id)sender {
    NSButton *checkbox = (NSButton *)sender;
    int colorIndex = (int)checkbox.tag;
    uls_pen_set_gas_assist(self.printerSettings, (ULSPenColor)colorIndex, checkbox.state == NSControlStateValueOn);
}

#pragma mark - Global Settings Actions

- (IBAction)printModeChanged:(id)sender {
    self.printerSettings->printMode = (ULSPrintMode)self.printModePopup.indexOfSelectedItem;
}

- (IBAction)imageDensityChanged:(id)sender {
    self.printerSettings->imageDensity = (ULSImageDensity)(self.imageDensityPopup.indexOfSelectedItem + 1);
}

- (IBAction)gasAssistModeChanged:(id)sender {
    self.printerSettings->gasAssistMode = (ULSGasAssistMode)self.gasAssistModePopup.indexOfSelectedItem;
}

#pragma mark - Settings File Actions

- (IBAction)saveSettings:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"las"]];
    panel.nameFieldStringValue = @"settings.las";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            ULSError err = uls_printer_settings_save(self.printerSettings, [panel.URL.path UTF8String]);
            if (err != ULS_SUCCESS) {
                [self showError:@"Save Failed" message:uls_error_string(err)];
            }
        }
    }];
}

- (IBAction)loadSettings:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"las"]];
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            ULSError err = uls_printer_settings_load(self.printerSettings, [panel.URL.path UTF8String]);
            if (err == ULS_SUCCESS) {
                [self updatePenSettingsUI];
            } else {
                [self showError:@"Load Failed" message:uls_error_string(err)];
            }
        }
    }];
}

- (IBAction)resetSettings:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Reset Settings?";
    alert.informativeText = @"This will reset all settings to their default values.";
    [alert addButtonWithTitle:@"Reset"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSAlertFirstButtonReturn) {
            uls_printer_settings_reset(self.printerSettings);
            [self updatePenSettingsUI];
        }
    }];
}

#pragma mark - Engraving Field Actions

- (IBAction)pageSizeChanged:(id)sender {
    float width = self.pageWidthField.floatValue;
    float height = self.pageHeightField.floatValue;

    if (width < 1.0f) width = 1.0f;
    if (width > 48.0f) width = 48.0f;
    if (height < 1.0f) height = 1.0f;
    if (height > 36.0f) height = 36.0f;

    self.pageWidthField.floatValue = width;
    self.pageHeightField.floatValue = height;

    if (self.printerSettings) {
        self.printerSettings->pageWidth = width;
        self.printerSettings->pageHeight = height;
    }
    [self updatePreview];
    [self updateEstimatedTime];
}

- (IBAction)orientationChanged:(id)sender {
    float width = self.pageWidthField.floatValue;
    float height = self.pageHeightField.floatValue;

    BOOL isLandscape = (self.orientationPopup.indexOfSelectedItem == 0);
    BOOL needsSwap = (isLandscape && height > width) || (!isLandscape && width > height);

    if (needsSwap) {
        self.pageWidthField.floatValue = height;
        self.pageHeightField.floatValue = width;
        [self pageSizeChanged:nil];
    }
}

#pragma mark - Time Estimation (Simulation-based)

- (void)updateEstimatedTime {
    if (!self.currentJob) {
        self.estimatedTimeLabel.stringValue = @"Est: --:--";
        return;
    }

    float totalSeconds = 0;
    ULSError err = uls_job_get_estimated_time(self.currentJob, &totalSeconds);
    if (err != ULS_SUCCESS || totalSeconds <= 0) {
        self.estimatedTimeLabel.stringValue = @"Est: --:--";
        return;
    }

    int minutes = (int)(totalSeconds / 60);
    int seconds = (int)totalSeconds % 60;
    self.estimatedTimeLabel.stringValue = [NSString stringWithFormat:@"Est: %d:%02d", minutes, seconds];
}

#pragma mark - Cleanup

- (void)dealloc {
    [_progressTimer invalidate];
    [_simTimer invalidate];

    if (_simulation) {
        uls_simulation_destroy(_simulation);
    }
    if (self.currentJob) {
        uls_job_destroy(self.currentJob);
    }
    if (self.device) {
        uls_close_device(self.device);
    }
    if (self.printerSettings) {
        uls_printer_settings_destroy(self.printerSettings);
    }
}

@end
