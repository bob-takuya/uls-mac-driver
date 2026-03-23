# ULS Laser Control for macOS

A native macOS driver and control application for Universal Laser Systems (ULS) laser cutters and engravers.

## Supported Devices

- **PLS Series** (Platform Laser System)
  - PLS 3.50, 4.60, 4.75, 6.60, 6.75, 6.120, 6.150
- **VLS Series** (VersaLaser)
  - VLS 230, 350, 360, 460, 660
- **ILS Series** (Industrial Laser System)
  - ILS 9.75, 9.150, 12.75, 12.150

## Features

- Native macOS application with modern UI
- USB communication via IOKit framework
- Vector path support (lines, bezier curves, arcs)
- Raster image engraving
- Material presets for common materials
- Command-line interface for scripting
- Real-time position monitoring
- Job progress tracking
- **8-Color Pen Mapping System**
  - Black, Red, Green, Yellow, Blue, Magenta, Cyan, Orange
  - Individual Power%, Speed%, PPI settings per color
  - Pen modes: RAST/VECT, RAST, VECT, SKIP
  - Automatic RGB color matching
- **Print Modes**: Normal, Clipart, 3D, Rubber Stamp
- **Image Density**: 8 levels for raster quality control
- **Gas Assist Control**: Auto or Manual mode
- **Settings Persistence**: Save/Load settings in .LAS format

## Building

### Requirements

- macOS 11.0 or later
- Xcode Command Line Tools

### Build Commands

```bash
# Build everything (app + CLI)
make all

# Build only the macOS application
make app

# Build only the command-line tool
make cli

# Run tests
make test

# Install to /Applications
sudo make install

# Clean build files
make clean
```

## Usage

### GUI Application

1. Launch `ULS Laser Control.app`
2. Click "Connect" to connect to your laser
3. Import an SVG or PDF file
4. Adjust power, speed, and other settings
5. Click "Start" to run the job

### Command Line

```bash
# List connected devices
./build/uls-cli list

# Get device status
./build/uls-cli status

# Home the laser head
./build/uls-cli home

# Move to position (in inches)
./build/uls-cli move 5.0 3.0

# Set laser power (0-100%)
./build/uls-cli power 50

# Set laser speed (0-100%)
./build/uls-cli speed 50

# Run a job from file
./build/uls-cli run design.svg

# Run test pattern
./build/uls-cli test

# Show all pen settings
./build/uls-cli pens

# Set pen color settings (power, speed, PPI)
./build/uls-cli pen red 75 40 500

# Set pen mode (rast-vect, rast, vect, skip)
./build/uls-cli pen-mode red vect

# Save/Load settings
./build/uls-cli save-settings settings.las
./build/uls-cli load-settings settings.las
```

## API Usage

```c
#include "uls_usb.h"
#include "uls_job.h"

// Find and connect to device
ULSDeviceInfo *devices;
int count;
uls_find_devices(&devices, &count);

ULSDevice *device = uls_open_device(devices[0].vendorId, devices[0].productId);

// Create a job
ULSJob *job = uls_job_create("my_job");

// Create a path (2" x 2" rectangle at position 1", 1")
ULSVectorPath *path = uls_path_create();
uls_path_set_laser(path, 50, 50, 500);  // power, speed, PPI
uls_path_add_rectangle(path, 1.0f, 1.0f, 2.0f, 2.0f);
uls_job_add_path(job, path);

// Run the job
uls_job_run(job, device);

// Cleanup
uls_job_destroy(job);
uls_close_device(device);
```

### Using Printer Settings (8-Color Pen Mapping)

```c
#include "uls_job.h"

// Create printer settings
ULSPrinterSettings *settings = uls_printer_settings_create();

// Configure red pen for cutting
uls_pen_set_mode(settings, ULS_PEN_COLOR_RED, ULS_PEN_MODE_VECT);
uls_pen_set_power(settings, ULS_PEN_COLOR_RED, 75);
uls_pen_set_speed(settings, ULS_PEN_COLOR_RED, 40);
uls_pen_set_ppi(settings, ULS_PEN_COLOR_RED, 500);

// Configure blue pen for engraving
uls_pen_set_mode(settings, ULS_PEN_COLOR_BLUE, ULS_PEN_MODE_RAST);
uls_pen_set_power(settings, ULS_PEN_COLOR_BLUE, 30);
uls_pen_set_speed(settings, ULS_PEN_COLOR_BLUE, 80);

// Set global options
settings->printMode = ULS_PRINT_MODE_NORMAL;
settings->imageDensity = ULS_IMAGE_DENSITY_6;
settings->gasAssistMode = ULS_GAS_ASSIST_AUTO;

// Save to file
uls_printer_settings_save(settings, "my_settings.las");

// Load from file
ULSPrinterSettings *loaded = uls_printer_settings_create();
uls_printer_settings_load(loaded, "my_settings.las");

// Match RGB color to closest pen
ULSPenColor color = uls_match_color_to_pen(255, 0, 0);  // Returns ULS_PEN_COLOR_RED

// Cleanup
uls_printer_settings_destroy(settings);
uls_printer_settings_destroy(loaded);
```

## Project Structure

```
uls-mac-driver/
├── include/
│   ├── uls_usb.h          # USB communication API
│   └── uls_job.h          # Job processing API
├── src/
│   ├── uls_usb.c          # USB implementation (IOKit)
│   ├── uls_job.c          # Job processing implementation
│   ├── uls_cli.c          # Command-line interface
│   ├── test_uls.c         # Test suite
│   ├── main.m             # App entry point
│   ├── ULSAppDelegate.h/m
│   ├── ULSMainWindowController.h/m
│   ├── ULSSVGParser.h/m   # SVG import (all path commands)
│   └── ULSPDFParser.h/m   # PDF import (Quartz CGPDFDocument)
├── scripts/
│   └── gen_icon.py        # App icon generator (no deps)
├── Makefile
└── README.md
```

## Technical Details

### USB Communication

The driver communicates with ULS devices via USB bulk transfers:
- Vendor ID: 0x10C3
- Uses IOKit USBLib for macOS USB access
- Bulk OUT endpoint for commands and job data
- Bulk IN endpoint for status and position

### Coordinate System

- All coordinates are in inches
- Origin (0, 0) is at the top-left corner
- X increases to the right
- Y increases downward
- Internal resolution: 1000 DPI

### Job Format

Jobs are compiled to a binary format:
- Header with job metadata
- Laser parameter commands (power, speed, PPI)
- Path commands (move, line, bezier, arc)
- Raster data (for image engraving)
- Job end marker

## Safety Notes

**WARNING: Laser cutters are dangerous equipment. Always:**

- Wear appropriate eye protection
- Never leave the laser running unattended
- Ensure proper ventilation
- Keep a fire extinguisher nearby
- Follow all manufacturer safety guidelines

## License

### This Project

Copyright (c) 2026 Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.**

This project is licensed under the **MIT License**.

### Third-Party Rights

- **Universal Laser Systems, Inc.** — ULS, PLS, VLS, and ILS are trademarks of
  Universal Laser Systems, Inc. The ULS USB protocol was determined by
  observation and is not based on any proprietary source code or documentation.
  This project is **not affiliated with, endorsed by, or supported by** Universal
  Laser Systems, Inc.

- **Apple, Inc.** — macOS, IOKit, PDFKit, Quartz, Cocoa, and related frameworks
  are property of Apple Inc. Use of these frameworks is subject to Apple's
  developer license terms.

- **PDF format** — The Portable Document Format (PDF) is an open ISO standard
  (ISO 32000). PDF parsing in this project uses Apple's `Quartz` framework only
  (no third-party PDF libraries).

### Disclaimer

This is an unofficial, community-developed driver. It is **not endorsed by or
affiliated with Universal Laser Systems, Inc.** Use of this software:

- May void your device warranty
- Is entirely at your own risk
- Is not a substitute for proper training and safety procedures

The authors and contributors accept **no liability** for any damage to equipment,
data loss, personal injury, or any other harm resulting from the use of this
software. Always follow the safety guidelines provided by the manufacturer of
your laser cutter.

> **⚠️ Safety Notice:** Laser cutters are Class 4 laser devices. Improper
> operation can cause serious injury, fire, or death. Always operate within a
> properly ventilated enclosure, wear appropriate eye protection, and comply with
> all applicable local regulations.
