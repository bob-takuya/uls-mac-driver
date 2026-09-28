# ULS Laser Control for macOS

An experimental, unofficial macOS app / CLI / CUPS backend for Universal Laser Systems (ULS) laser cutters, talking to the machine over USB via IOKit.

Mac から ULS レーザーカッターを直接動かすための非公式ドライバの試作（USB プロトコルは推測ベース・実機動作未確認）。

## Status

**Prototype / not working on real hardware yet.** The UI, file import and settings model are built, but the USB job protocol is a *guess*: opcodes, job header and handshake have not been verified against a real ULS machine or a USB capture of the Windows driver (see the `TODO (Windows Driver Audit)` blocks in `src/uls_job.c` and `src/uls_usb.c`). Do not expect a job sent from this tool to cut anything.

✅ **Works (without hardware)**
- Builds as a Cocoa app (`make app`), CLI (`make cli`) and CUPS backend (`make cups`) with only Xcode Command Line Tools
- Hardware-free unit tests (`make test`, `src/test_uls.c`) for paths, bounds, job compile, pen settings, color matching, presets
- GUI: SVG import (`ULSSVGParser.m`, NSXMLParser) and PDF import (`ULSPDFParser.m`, Quartz) with preview
- 8-color pen mapping model (power / speed / PPI / mode per color) and save/load of settings to a `.las` file
- Debug panel: USB device search, diagnostic checklist, TX/RX hex log, hex command console

🚧 **Partial or rough**
- USB device discovery/open by vendor ID `0x10C3` and a small table of product IDs (PLS / VLS 360 / ILS / VLS 230) — not confirmed on a real device
- Job compilation: emits a self-invented binary stream (`'U','L','S'` header, opcodes `0x01`…`0xFF`); no checksum, bounds or Z-offset
- Job run: sends data then START_JOB, with no ACK waiting, status polling, pause/resume or error recovery
- Color → pen matching is plain nearest-RGB (no white/background skip, no tolerance)
- Print mode, image density and gas-assist values are stored in settings but not encoded into the job stream

📝 **Not implemented yet**
- Verified ULS protocol (device init sequence, real opcodes, raster encoding) — needs a USB capture of the official driver
- Raster engraving from the GUI (raster data structures exist in the C API only)
- Vector-vs-raster separation by stroke width and pen modes RAST_VECT / RAST / VECT / SKIP during compilation
- CLI `run` with real files: SVG import in C is a stub that adds a fixed 3"×2" rectangle; PDF import in C always returns an error
- **CUPS printing**: the backend calls the C `uls_job_import_pdf()`, which is not implemented, so every print job currently fails at the parse step

⚠️ **Known issues & limitations**
- Untested on any physical ULS laser; supported-model list below reflects the product-ID table, not tested machines
- macOS only (IOKit, Cocoa, Quartz)
- CUPS install writes to system locations and needs `sudo`; uninstall with `sudo make uninstall-cups`
- The `.las` file is this project's own format, not guaranteed compatible with the official ULS driver's files

## Background

Written in 2026-03 as an attempt to drive a ULS laser cutter directly from a Mac instead of going through the Windows-only official driver. Development stopped after the protocol audit showed the missing pieces listed above.

## Target Devices (by USB product ID table, untested)

- **PLS Series** (Platform Laser System)
- **VLS Series** (VersaLaser) — VLS 230, VLS 360 family
- **ILS Series** (Industrial Laser System)

## Building

### Requirements

- macOS 11.0 or later
- Xcode Command Line Tools

### Build Commands

```bash
make all            # app + CLI
make app            # macOS application only (build/ULSLaserControl.app)
make cli            # command-line tool only (build/uls-cli)
make test           # hardware-free unit tests
sudo make install   # install app to /Applications
make cups           # CUPS backend (see Status: printing does not work yet)
sudo make install-cups
sudo make uninstall-cups
make clean
```

## Usage

### GUI Application

1. Launch the built app (`build/ULSLaserControl.app`)
2. Click "Connect" (requires a ULS device on USB)
3. Import an SVG or PDF file
4. Adjust power, speed and pen settings
5. Click "Start" — note that the job format is unverified (see Status)

The Debug panel is the most useful part today: it shows whether the device is found, which interface/endpoints open, and logs raw USB traffic.

### Command Line

```bash
./build/uls-cli list                       # list connected devices
./build/uls-cli status                     # device status
./build/uls-cli home                       # home the head
./build/uls-cli move 5.0 3.0               # move (inches)
./build/uls-cli power 50                   # 0-100 %
./build/uls-cli speed 50                   # 0-100 %
./build/uls-cli test                       # send a test pattern
./build/uls-cli pens                       # show pen settings
./build/uls-cli pen red 75 40 500          # power, speed, PPI
./build/uls-cli pen-mode red vect          # rast-vect | rast | vect | skip
./build/uls-cli save-settings settings.las
./build/uls-cli load-settings settings.las
./build/uls-cli debug                      # live status monitor
./build/uls-cli run design.svg             # currently sends a placeholder rectangle (C SVG import is a stub)
```

### CUPS Virtual Printer (not functional yet)

`sudo make install-cups` registers a printer named **"ULS VLS 6.0"** with a PPD exposing print mode, image density and per-color pen options. The backend is wired up, but PDF parsing from the C backend is not implemented, so jobs fail. Fixing this means linking the backend against `ULSPDFParser.m` instead of the C stub.

## API Usage

```c
#include "uls_usb.h"
#include "uls_job.h"

ULSDeviceInfo *devices;
int count;
uls_find_devices(&devices, &count);
ULSDevice *device = uls_open_device(devices[0].vendorId, devices[0].productId);

ULSJob *job = uls_job_create("my_job");
ULSVectorPath *path = uls_path_create();
uls_path_set_laser(path, 50, 50, 500);           // power, speed, PPI
uls_path_add_rectangle(path, 1.0f, 1.0f, 2.0f, 2.0f);
uls_job_add_path(job, path);

uls_job_run(job, device);                        // protocol unverified

uls_job_destroy(job);
uls_close_device(device);
```

Pen settings: `uls_printer_settings_create()`, `uls_pen_set_mode/power/speed/ppi()`, `uls_printer_settings_save/load()`, `uls_match_color_to_pen(r, g, b)` — see `include/uls_job.h`.

## Project Structure

```
uls-mac-driver/
├── include/            uls_usb.h (USB API), uls_job.h (job / pen API)
├── src/
│   ├── uls_usb.c       USB via IOKit
│   ├── uls_job.c       job model + compiler (protocol TODOs documented here)
│   ├── uls_cli.c       command-line tool
│   ├── test_uls.c      hardware-free tests
│   ├── main.m, ULSAppDelegate.*, ULSMainWindowController.*
│   ├── ULSDebugPanelController.*   debug / diagnostics panel
│   ├── ULSSVGParser.*  SVG import (GUI)
│   └── ULSPDFParser.*  PDF import (GUI, Quartz)
├── cups/               uls_cups_backend.c, ULS-VLS60.ppd
├── scripts/            gen_icon.py, install_cups.sh
└── Makefile
```

## Technical Notes

- USB bulk transfers via IOKit USBLib, vendor ID `0x10C3`
- Coordinates in inches, origin top-left, Y down, internal resolution 1000 DPI
- The command codes and header in `uls_job.c` are placeholders pending a protocol capture

## Related

Part of a small series of Mac tools for fabrication machines by the same author:

- [neje_controller](https://github.com/bob-takuya/neje_controller) — Tauri controller for NEJE laser engraver + Silhouette CAMEO 5
- [cameo-cut](https://github.com/bob-takuya/cameo-cut) — Python/PyQt6 controller for Silhouette Cameo 5

## Safety

Laser cutters are Class 4 laser devices. Wear eye protection, never leave the machine unattended, ensure ventilation and keep a fire extinguisher nearby. Sending unverified commands to a laser can cause unexpected motion or firing.

## License

MIT — see [LICENSE](LICENSE).

ULS, PLS, VLS and ILS are trademarks of Universal Laser Systems, Inc. This is an unofficial project, not affiliated with, endorsed by or supported by Universal Laser Systems, Inc. It is not based on any proprietary source code or documentation. Use entirely at your own risk; the authors accept no liability for damage to equipment or injury.
