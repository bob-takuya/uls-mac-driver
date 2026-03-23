/*
 * ULS Laser Control for macOS
 * Main Window Controller Header
 */

#import <Cocoa/Cocoa.h>
#include "uls_usb.h"
#include "uls_job.h"

@interface ULSMainWindowController : NSWindowController <NSWindowDelegate, NSTabViewDelegate>

// Device connection
@property (assign, nonatomic) ULSDevice *device;
@property (assign, nonatomic) BOOL isConnected;

// Current job
@property (assign, nonatomic) ULSJob *currentJob;

// Printer settings (8-color pen mapping)
@property (assign, nonatomic) ULSPrinterSettings *printerSettings;

// UI Elements - Main
@property (strong, nonatomic) NSTextField *statusLabel;
@property (strong, nonatomic) NSTextField *deviceLabel;
@property (strong, nonatomic) NSTextField *positionLabel;
@property (strong, nonatomic) NSProgressIndicator *progressIndicator;
@property (strong, nonatomic) NSSlider *powerSlider;
@property (strong, nonatomic) NSSlider *speedSlider;
@property (strong, nonatomic) NSTextField *powerLabel;
@property (strong, nonatomic) NSTextField *speedLabel;
@property (strong, nonatomic) NSPopUpButton *materialPopup;
@property (strong, nonatomic) NSView *previewView;
@property (strong, nonatomic) NSButton *connectButton;
@property (strong, nonatomic) NSButton *homeButton;
@property (strong, nonatomic) NSButton *startButton;
@property (strong, nonatomic) NSButton *pauseButton;
@property (strong, nonatomic) NSButton *stopButton;
@property (strong, nonatomic) NSTabView *settingsTabView;
@property (strong, nonatomic) NSSegmentedControl *modeControl;

// UI Elements - Global Settings
@property (strong, nonatomic) NSPopUpButton *printModePopup;
@property (strong, nonatomic) NSPopUpButton *imageDensityPopup;
@property (strong, nonatomic) NSPopUpButton *gasAssistModePopup;

// UI Elements - Engraving Field
@property (strong, nonatomic) NSTextField *pageWidthField;
@property (strong, nonatomic) NSTextField *pageHeightField;
@property (strong, nonatomic) NSPopUpButton *orientationPopup;

// UI Elements - Time Estimate
@property (strong, nonatomic) NSTextField *estimatedTimeLabel;
@property (strong, nonatomic) NSTextField *elapsedTimeLabel;

// UI Elements - Jog
@property (strong, nonatomic) NSPopUpButton *jogDistancePopup;

// Actions
- (IBAction)connectLaser:(id)sender;
- (IBAction)disconnectLaser:(id)sender;
- (IBAction)homeLaser:(id)sender;
- (IBAction)startJob:(id)sender;
- (IBAction)pauseJob:(id)sender;
- (IBAction)stopJob:(id)sender;
- (IBAction)importSVG:(id)sender;
- (IBAction)powerSliderChanged:(id)sender;
- (IBAction)speedSliderChanged:(id)sender;
- (IBAction)powerFieldChanged:(id)sender;
- (IBAction)speedFieldChanged:(id)sender;
- (IBAction)materialChanged:(id)sender;

// Jog controls
- (IBAction)jogLeft:(id)sender;
- (IBAction)jogRight:(id)sender;
- (IBAction)jogUp:(id)sender;
- (IBAction)jogDown:(id)sender;

// Interaction mode
- (IBAction)interactionModeChanged:(id)sender;

// Pen Settings actions
- (IBAction)penModeChanged:(id)sender;
- (IBAction)penPowerChanged:(id)sender;
- (IBAction)penSpeedChanged:(id)sender;
- (IBAction)penPowerFieldChanged:(id)sender;
- (IBAction)penSpeedFieldChanged:(id)sender;
- (IBAction)penPPIChanged:(id)sender;
- (IBAction)penGasAssistChanged:(id)sender;

// Global Settings actions
- (IBAction)printModeChanged:(id)sender;
- (IBAction)imageDensityChanged:(id)sender;
- (IBAction)gasAssistModeChanged:(id)sender;

// Settings file actions
- (IBAction)saveSettings:(id)sender;
- (IBAction)loadSettings:(id)sender;
- (IBAction)resetSettings:(id)sender;

// Engraving Field actions
- (IBAction)pageSizeChanged:(id)sender;
- (IBAction)orientationChanged:(id)sender;

// Jog distance
- (IBAction)jogDistanceChanged:(id)sender;

@end
