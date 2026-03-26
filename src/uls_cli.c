/*
 * ULS Laser Control Command Line Interface
 * macOS Driver Implementation
 *
 * Usage:
 *   uls-cli list                    - List connected devices
 *   uls-cli status                  - Get device status
 *   uls-cli home                    - Home the laser head
 *   uls-cli move <x> <y>            - Move to position (inches)
 *   uls-cli power <0-100>           - Set laser power
 *   uls-cli speed <0-100>           - Set laser speed
 *   uls-cli run <file.svg>          - Run job from file
 *   uls-cli test                    - Draw test pattern
 */

#include "uls_usb.h"
#include "uls_job.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

/* Global printer settings */
static ULSPrinterSettings *gSettings = NULL;

static void print_usage(const char *program) {
    printf("ULS Laser Control CLI\n");
    printf("\n");
    printf("Usage: %s <command> [arguments]\n", program);
    printf("\n");
    printf("Device Commands:\n");
    printf("  list                    List connected ULS devices\n");
    printf("  status                  Get current device status\n");
    printf("  home                    Home the laser head\n");
    printf("  move <x> <y>            Move to position (inches)\n");
    printf("  power <0-100>           Set laser power percentage\n");
    printf("  speed <0-100>           Set laser speed percentage\n");
    printf("  ppi <value>             Set pulses per inch\n");
    printf("  run <file>              Run job from SVG/PDF file\n");
    printf("  test                    Draw a test pattern\n");
    printf("  version                 Get firmware version\n");
    printf("  debug                   Live debug status monitoring\n");
    printf("\n");
    printf("Pen Settings Commands:\n");
    printf("  pens                    Show all 8 pen color settings\n");
    printf("  pen <color> <power> <speed> <ppi>  Set pen color settings\n");
    printf("  pen-mode <color> <mode> Set pen mode (rast-vect/rast/vect/skip)\n");
    printf("  save-settings <file>    Save settings to .LAS file\n");
    printf("  load-settings <file>    Load settings from .LAS file\n");
    printf("\n");
    printf("Colors: black, red, green, yellow, blue, magenta, cyan, orange\n");
    printf("\n");
    printf("Examples:\n");
    printf("  %s list\n", program);
    printf("  %s home\n", program);
    printf("  %s move 5.0 3.0\n", program);
    printf("  %s power 50\n", program);
    printf("  %s run design.svg\n", program);
    printf("  %s pens\n", program);
    printf("  %s pen red 75 40 500\n", program);
    printf("  %s pen-mode red vect\n", program);
    printf("  %s debug\n", program);
}

static ULSDevice* connect_first_device(void) {
    ULSDeviceInfo *devices = NULL;
    int count = 0;

    ULSError err = uls_find_devices(&devices, &count);
    if (err != ULS_SUCCESS || count == 0) {
        printf("Error: No ULS device found\n");
        return NULL;
    }

    printf("Connecting to %s...\n", uls_model_string(devices[0].model));
    ULSDevice *device = uls_open_device(devices[0].vendorId, devices[0].productId);

    uls_free_device_list(devices, count);

    if (!device) {
        printf("Error: Failed to open device\n");
        return NULL;
    }

    printf("Connected!\n");
    return device;
}

static int cmd_list(void) {
    ULSDeviceInfo *devices = NULL;
    int count = 0;

    ULSError err = uls_find_devices(&devices, &count);

    if (err != ULS_SUCCESS || count == 0) {
        printf("No ULS devices found.\n");
        return 1;
    }

    printf("Found %d device(s):\n", count);
    for (int i = 0; i < count; i++) {
        printf("  %d. %s (VID: 0x%04X, PID: 0x%04X)\n",
               i + 1,
               uls_model_string(devices[i].model),
               devices[i].vendorId,
               devices[i].productId);
        printf("     State: %s\n", uls_state_string(devices[i].state));
        if (devices[i].serialNumber[0]) {
            printf("     Serial: %s\n", devices[i].serialNumber);
        }
    }

    uls_free_device_list(devices, count);
    return 0;
}

static int cmd_status(void) {
    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    ULSDeviceState state;
    ULSError err = uls_get_status(device, &state);

    if (err == ULS_SUCCESS) {
        printf("Device Status: %s\n", uls_state_string(state));
    }

    float x, y, z;
    err = uls_get_position(device, &x, &y, &z);
    if (err == ULS_SUCCESS) {
        printf("Position: X=%.3f\" Y=%.3f\" Z=%.3f\"\n", x, y, z);
    }

    char version[64];
    err = uls_get_firmware_version(device, version, sizeof(version));
    if (err == ULS_SUCCESS) {
        printf("Firmware: %s\n", version);
    }

    uls_close_device(device);
    return 0;
}

static int cmd_home(void) {
    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("Homing...\n");
    ULSError err = uls_home(device);

    if (err == ULS_SUCCESS) {
        printf("Homing complete.\n");
    } else {
        printf("Error: %s\n", uls_error_string(err));
    }

    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

static int cmd_move(float x, float y) {
    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("Moving to X=%.3f\" Y=%.3f\"...\n", x, y);
    ULSError err = uls_move_to(device, x, y);

    if (err == ULS_SUCCESS) {
        printf("Move complete.\n");
    } else {
        printf("Error: %s\n", uls_error_string(err));
    }

    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

static int cmd_power(int power) {
    if (power < 0 || power > 100) {
        printf("Error: Power must be 0-100\n");
        return 1;
    }

    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("Setting power to %d%%...\n", power);
    ULSError err = uls_set_power(device, (uint8_t)power);

    if (err == ULS_SUCCESS) {
        printf("Power set.\n");
    } else {
        printf("Error: %s\n", uls_error_string(err));
    }

    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

static int cmd_speed(int speed) {
    if (speed < 0 || speed > 100) {
        printf("Error: Speed must be 0-100\n");
        return 1;
    }

    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("Setting speed to %d%%...\n", speed);
    ULSError err = uls_set_speed(device, (uint8_t)speed);

    if (err == ULS_SUCCESS) {
        printf("Speed set.\n");
    } else {
        printf("Error: %s\n", uls_error_string(err));
    }

    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

static int cmd_ppi(int ppi) {
    if (ppi < 1 || ppi > 2000) {
        printf("Error: PPI must be 1-2000\n");
        return 1;
    }

    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("Setting PPI to %d...\n", ppi);
    ULSError err = uls_set_ppi(device, (uint16_t)ppi);

    if (err == ULS_SUCCESS) {
        printf("PPI set.\n");
    } else {
        printf("Error: %s\n", uls_error_string(err));
    }

    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

static int cmd_run(const char *filename) {
    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("Loading job from %s...\n", filename);

    ULSJob *job = uls_job_create(filename);
    if (!job) {
        printf("Error: Failed to create job\n");
        uls_close_device(device);
        return 1;
    }

    ULSError err;
    const char *ext = strrchr(filename, '.');
    if (ext && strcasecmp(ext, ".svg") == 0) {
        err = uls_job_import_svg(job, filename);
    } else if (ext && strcasecmp(ext, ".pdf") == 0) {
        err = uls_job_import_pdf(job, filename, 0);
    } else {
        printf("Error: Unsupported file format. Use .svg or .pdf\n");
        uls_job_destroy(job);
        uls_close_device(device);
        return 1;
    }

    if (err != ULS_SUCCESS) {
        printf("Error loading file: %s\n", uls_error_string(err));
        uls_job_destroy(job);
        uls_close_device(device);
        return 1;
    }

    float minX, minY, maxX, maxY;
    uls_job_get_bounds(job, &minX, &minY, &maxX, &maxY);
    printf("Job bounds: (%.2f\", %.2f\") to (%.2f\", %.2f\")\n", minX, minY, maxX, maxY);

    float estTime;
    uls_job_get_estimated_time(job, &estTime);
    printf("Estimated time: %.1f seconds\n", estTime);

    printf("Compiling job...\n");
    err = uls_job_compile(job);
    if (err != ULS_SUCCESS) {
        printf("Error compiling job: %s\n", uls_error_string(err));
        uls_job_destroy(job);
        uls_close_device(device);
        return 1;
    }

    printf("Running job...\n");
    err = uls_job_run(job, device);
    if (err != ULS_SUCCESS) {
        printf("Error running job: %s\n", uls_error_string(err));
    } else {
        printf("Job started successfully.\n");
    }

    uls_job_destroy(job);
    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

static int cmd_test(void) {
    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("Creating test pattern...\n");

    ULSJob *job = uls_job_create("test_pattern");
    if (!job) {
        printf("Error: Failed to create job\n");
        uls_close_device(device);
        return 1;
    }

    /* Create a test pattern: square, circle, and some lines */
    ULSVectorPath *path1 = uls_path_create();
    uls_path_set_laser(path1, 50, 50, 500);
    uls_path_add_rectangle(path1, 1.0f, 1.0f, 2.0f, 2.0f);
    uls_job_add_path(job, path1);

    ULSVectorPath *path2 = uls_path_create();
    uls_path_set_laser(path2, 50, 50, 500);
    uls_path_add_circle(path2, 5.0f, 2.0f, 1.0f);
    uls_job_add_path(job, path2);

    ULSVectorPath *path3 = uls_path_create();
    uls_path_set_laser(path3, 30, 80, 300);
    uls_path_move_to(path3, 1.0f, 4.0f);
    uls_path_line_to(path3, 6.0f, 4.0f);
    uls_job_add_path(job, path3);

    float minX, minY, maxX, maxY;
    uls_job_get_bounds(job, &minX, &minY, &maxX, &maxY);
    printf("Test pattern bounds: (%.2f\", %.2f\") to (%.2f\", %.2f\")\n", minX, minY, maxX, maxY);

    printf("Compiling and running...\n");
    ULSError err = uls_job_run(job, device);

    if (err == ULS_SUCCESS) {
        printf("Test pattern running.\n");
    } else {
        printf("Error: %s\n", uls_error_string(err));
    }

    uls_job_destroy(job);
    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

static int cmd_version(void) {
    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    char version[64];
    ULSError err = uls_get_firmware_version(device, version, sizeof(version));

    if (err == ULS_SUCCESS) {
        printf("Firmware Version: %s\n", version);
    } else {
        printf("Error: %s\n", uls_error_string(err));
    }

    uls_close_device(device);
    return (err == ULS_SUCCESS) ? 0 : 1;
}

/* Parse color name to ULSPenColor */
static int parse_color(const char *name, ULSPenColor *color) {
    if (strcasecmp(name, "black") == 0) { *color = ULS_PEN_COLOR_BLACK; return 1; }
    if (strcasecmp(name, "red") == 0) { *color = ULS_PEN_COLOR_RED; return 1; }
    if (strcasecmp(name, "green") == 0) { *color = ULS_PEN_COLOR_GREEN; return 1; }
    if (strcasecmp(name, "yellow") == 0) { *color = ULS_PEN_COLOR_YELLOW; return 1; }
    if (strcasecmp(name, "blue") == 0) { *color = ULS_PEN_COLOR_BLUE; return 1; }
    if (strcasecmp(name, "magenta") == 0) { *color = ULS_PEN_COLOR_MAGENTA; return 1; }
    if (strcasecmp(name, "cyan") == 0) { *color = ULS_PEN_COLOR_CYAN; return 1; }
    if (strcasecmp(name, "orange") == 0) { *color = ULS_PEN_COLOR_ORANGE; return 1; }
    return 0;
}

/* Parse pen mode string */
static int parse_mode(const char *name, ULSPenMode *mode) {
    if (strcasecmp(name, "rast-vect") == 0 || strcasecmp(name, "rast/vect") == 0) {
        *mode = ULS_PEN_MODE_RAST_VECT; return 1;
    }
    if (strcasecmp(name, "rast") == 0) { *mode = ULS_PEN_MODE_RAST; return 1; }
    if (strcasecmp(name, "vect") == 0) { *mode = ULS_PEN_MODE_VECT; return 1; }
    if (strcasecmp(name, "skip") == 0) { *mode = ULS_PEN_MODE_SKIP; return 1; }
    return 0;
}

/* Initialize global settings */
static void ensure_settings(void) {
    if (!gSettings) {
        gSettings = uls_printer_settings_create();
    }
}

/* Show all pen settings */
static int cmd_pens(void) {
    ensure_settings();

    printf("\n8-Color Pen Settings:\n");
    printf("--------------------------------------------------------------\n");
    printf("%-10s %-12s %6s %6s %6s\n", "Color", "Mode", "Power", "Speed", "PPI");
    printf("--------------------------------------------------------------\n");

    for (int i = 0; i < ULS_PEN_COLOR_COUNT; i++) {
        printf("%-10s %-12s %5d%% %5d%% %6d\n",
               uls_pen_color_string((ULSPenColor)i),
               uls_pen_mode_string(gSettings->pens[i].mode),
               gSettings->pens[i].power,
               gSettings->pens[i].speed,
               gSettings->pens[i].ppi);
    }

    printf("--------------------------------------------------------------\n");
    printf("\nGlobal Settings:\n");
    printf("  Print Mode:     %s\n", uls_print_mode_string(gSettings->printMode));
    printf("  Image Density:  %d\n", gSettings->imageDensity);
    printf("  Gas Assist:     %s\n", gSettings->gasAssistMode == ULS_GAS_ASSIST_AUTO ? "Auto" : "Manual");
    printf("\n");

    return 0;
}

/* Set pen settings */
static int cmd_pen(const char *colorName, int power, int speed, int ppi) {
    ensure_settings();

    ULSPenColor color;
    if (!parse_color(colorName, &color)) {
        printf("Error: Unknown color '%s'\n", colorName);
        printf("Valid colors: black, red, green, yellow, blue, magenta, cyan, orange\n");
        return 1;
    }

    if (power < 0 || power > 100) {
        printf("Error: Power must be 0-100\n");
        return 1;
    }
    if (speed < 0 || speed > 100) {
        printf("Error: Speed must be 0-100\n");
        return 1;
    }
    if (ppi < 1 || ppi > 1000) {
        printf("Error: PPI must be 1-1000\n");
        return 1;
    }

    uls_pen_set_power(gSettings, color, (uint8_t)power);
    uls_pen_set_speed(gSettings, color, (uint8_t)speed);
    uls_pen_set_ppi(gSettings, color, (uint16_t)ppi);

    printf("Set %s: Power=%d%%, Speed=%d%%, PPI=%d\n",
           uls_pen_color_string(color), power, speed, ppi);

    return 0;
}

/* Set pen mode */
static int cmd_pen_mode(const char *colorName, const char *modeName) {
    ensure_settings();

    ULSPenColor color;
    if (!parse_color(colorName, &color)) {
        printf("Error: Unknown color '%s'\n", colorName);
        return 1;
    }

    ULSPenMode mode;
    if (!parse_mode(modeName, &mode)) {
        printf("Error: Unknown mode '%s'\n", modeName);
        printf("Valid modes: rast-vect, rast, vect, skip\n");
        return 1;
    }

    uls_pen_set_mode(gSettings, color, mode);
    printf("Set %s mode to %s\n", uls_pen_color_string(color), uls_pen_mode_string(mode));

    return 0;
}

/* Save settings to file */
static int cmd_save_settings(const char *filepath) {
    ensure_settings();

    ULSError err = uls_printer_settings_save(gSettings, filepath);
    if (err == ULS_SUCCESS) {
        printf("Settings saved to %s\n", filepath);
        return 0;
    } else {
        printf("Error saving settings: %s\n", uls_error_string(err));
        return 1;
    }
}

/* Load settings from file */
static int cmd_load_settings(const char *filepath) {
    ensure_settings();

    ULSError err = uls_printer_settings_load(gSettings, filepath);
    if (err == ULS_SUCCESS) {
        printf("Settings loaded from %s\n", filepath);
        cmd_pens();  /* Show loaded settings */
        return 0;
    } else {
        printf("Error loading settings: %s\n", uls_error_string(err));
        return 1;
    }
}

/* Live debug status monitoring */
static int cmd_debug(void) {
    ULSDevice *device = connect_first_device();
    if (!device) return 1;

    printf("\n");
    printf("=== ULS Debug Mode ===\n");
    printf("Press Ctrl+C to exit\n");
    printf("\n");

    /* Get initial info */
    char version[64] = {0};
    ULSError err = uls_get_firmware_version(device, version, sizeof(version));
    if (err == ULS_SUCCESS) {
        printf("Firmware: %s\n", version);
    }
    printf("Model: %s\n", uls_model_string(device->info.model));
    printf("\n");

    /* Live polling loop */
    printf("%-12s %-10s %-10s %-10s %-15s\n",
           "Time", "X (in)", "Y (in)", "Z (in)", "State");
    printf("--------------------------------------------------------------\n");

    while (1) {
        float x = 0, y = 0, z = 0;
        ULSDeviceState state = ULS_STATE_DISCONNECTED;

        err = uls_get_position(device, &x, &y, &z);
        uls_get_status(device, &state);

        /* Get current time */
        time_t now = time(NULL);
        struct tm *tm_info = localtime(&now);
        char time_str[16];
        strftime(time_str, sizeof(time_str), "%H:%M:%S", tm_info);

        /* Print status line (carriage return to overwrite) */
        printf("\r%-12s %-10.3f %-10.3f %-10.3f %-15s",
               time_str, x, y, z, uls_state_string(state));
        fflush(stdout);

        /* Check for disconnect */
        if (err == ULS_ERROR_NOT_CONNECTED || err == ULS_ERROR_IO) {
            printf("\n\nDevice disconnected!\n");
            break;
        }

        /* Poll every 500ms */
        usleep(500000);
    }

    uls_close_device(device);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    const char *cmd = argv[1];
    int result = 0;

    if (strcmp(cmd, "list") == 0) {
        result = cmd_list();
    } else if (strcmp(cmd, "status") == 0) {
        result = cmd_status();
    } else if (strcmp(cmd, "home") == 0) {
        result = cmd_home();
    } else if (strcmp(cmd, "move") == 0) {
        if (argc < 4) {
            printf("Usage: %s move <x> <y>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_move(atof(argv[2]), atof(argv[3]));
        }
    } else if (strcmp(cmd, "power") == 0) {
        if (argc < 3) {
            printf("Usage: %s power <0-100>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_power(atoi(argv[2]));
        }
    } else if (strcmp(cmd, "speed") == 0) {
        if (argc < 3) {
            printf("Usage: %s speed <0-100>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_speed(atoi(argv[2]));
        }
    } else if (strcmp(cmd, "ppi") == 0) {
        if (argc < 3) {
            printf("Usage: %s ppi <value>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_ppi(atoi(argv[2]));
        }
    } else if (strcmp(cmd, "run") == 0) {
        if (argc < 3) {
            printf("Usage: %s run <file>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_run(argv[2]);
        }
    } else if (strcmp(cmd, "test") == 0) {
        result = cmd_test();
    } else if (strcmp(cmd, "version") == 0) {
        result = cmd_version();
    } else if (strcmp(cmd, "debug") == 0) {
        result = cmd_debug();
    } else if (strcmp(cmd, "pens") == 0) {
        result = cmd_pens();
    } else if (strcmp(cmd, "pen") == 0) {
        if (argc < 6) {
            printf("Usage: %s pen <color> <power> <speed> <ppi>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_pen(argv[2], atoi(argv[3]), atoi(argv[4]), atoi(argv[5]));
        }
    } else if (strcmp(cmd, "pen-mode") == 0) {
        if (argc < 4) {
            printf("Usage: %s pen-mode <color> <mode>\n", argv[0]);
            printf("Modes: rast-vect, rast, vect, skip\n");
            result = 1;
        } else {
            result = cmd_pen_mode(argv[2], argv[3]);
        }
    } else if (strcmp(cmd, "save-settings") == 0) {
        if (argc < 3) {
            printf("Usage: %s save-settings <file.las>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_save_settings(argv[2]);
        }
    } else if (strcmp(cmd, "load-settings") == 0) {
        if (argc < 3) {
            printf("Usage: %s load-settings <file.las>\n", argv[0]);
            result = 1;
        } else {
            result = cmd_load_settings(argv[2]);
        }
    } else if (strcmp(cmd, "help") == 0 || strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0) {
        print_usage(argv[0]);
        result = 0;
    } else {
        printf("Unknown command: %s\n", cmd);
        print_usage(argv[0]);
        result = 1;
    }

    /* Clean up */
    if (gSettings) {
        uls_printer_settings_destroy(gSettings);
    }

    return result;
}
