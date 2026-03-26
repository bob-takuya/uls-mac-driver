/*
 * ULS CUPS Backend for macOS
 *
 * CUPS backend that receives PDF print jobs and sends them to ULS laser cutters.
 * Registered as "uls" backend, creates virtual printer "ULS VLS 6.0".
 *
 * Flow: CUPS receives PDF -> this backend parses with ULSPDFParser ->
 *       applies pen mapping -> sends via uls_usb.c
 *
 * Usage (by CUPS):
 *   uls                              - List available devices
 *   uls job-id user title copies options [file]  - Process print job
 *
 * Build:
 *   make cups
 *
 * Install:
 *   sudo make install-cups
 *
 * Copyright (c) 2026 Contributors - MIT License
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <signal.h>

#include "uls_usb.h"
#include "uls_job.h"

/* CUPS Backend exit codes (from cups/backend.h) */
#define CUPS_BACKEND_OK             0
#define CUPS_BACKEND_FAILED         1
#define CUPS_BACKEND_AUTH_REQUIRED  2
#define CUPS_BACKEND_HOLD           3
#define CUPS_BACKEND_STOP           4
#define CUPS_BACKEND_CANCEL         5
#define CUPS_BACKEND_RETRY          6
#define CUPS_BACKEND_RETRY_CURRENT  7

/* Backend name and version */
#define ULS_BACKEND_NAME    "uls"
#define ULS_BACKEND_VERSION "1.0"

/* Temporary file for print job */
#define ULS_TEMP_DIR        "/tmp"
#define ULS_TEMP_PREFIX     "uls_print_"

/* Settings file path (user-configurable pen settings) */
#define ULS_SETTINGS_FILE   "/Library/Application Support/ULS/default_settings.las"

/* Log to CUPS error log (stderr) */
#define LOG_DEBUG(fmt, ...) fprintf(stderr, "DEBUG: " fmt "\n", ##__VA_ARGS__)
#define LOG_INFO(fmt, ...)  fprintf(stderr, "INFO: " fmt "\n", ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) fprintf(stderr, "ERROR: " fmt "\n", ##__VA_ARGS__)
#define LOG_STATE(state)    fprintf(stderr, "STATE: %s\n", state)

/* Global for signal handler */
static volatile sig_atomic_t g_cancelled = 0;

static void signal_handler(int sig) {
    (void)sig;
    g_cancelled = 1;
}

/*
 * Print device discovery information (called with no arguments)
 * CUPS calls this to enumerate available devices.
 */
static int list_devices(void) {
    ULSDeviceInfo *devices = NULL;
    int count = 0;

    ULSError err = uls_find_devices(&devices, &count);

    if (err == ULS_SUCCESS && count > 0) {
        for (int i = 0; i < count; i++) {
            /* Format: device-class URI "make model" "info" "device-id" "location" */
            printf("direct %s://%s \"ULS\" \"%s\" \"ULS Laser Cutter\" \"\"\n",
                   ULS_BACKEND_NAME,
                   devices[i].serialNumber[0] ? devices[i].serialNumber : "default",
                   uls_model_string(devices[i].model));
        }
        uls_free_device_list(devices, count);
    } else {
        /* Always advertise at least one device so the printer can be set up */
        printf("direct %s://default \"ULS\" \"VLS 6.0\" \"ULS Virtual Laser Cutter\" \"\"\n",
               ULS_BACKEND_NAME);
    }

    return CUPS_BACKEND_OK;
}

/*
 * Create a temporary file with a unique name
 */
static char* create_temp_file(void) {
    static char path[256];
    snprintf(path, sizeof(path), "%s/%sXXXXXX.pdf", ULS_TEMP_DIR, ULS_TEMP_PREFIX);
    int fd = mkstemps(path, 4);
    if (fd < 0) {
        LOG_ERROR("Cannot create temp file: %s", strerror(errno));
        return NULL;
    }
    close(fd);
    return path;
}

/*
 * Copy stdin to a temporary file (CUPS sends job data via stdin if no filename)
 */
static int copy_stdin_to_file(const char *filepath) {
    FILE *fp = fopen(filepath, "wb");
    if (!fp) {
        LOG_ERROR("Cannot create temp file %s: %s", filepath, strerror(errno));
        return -1;
    }

    char buffer[8192];
    ssize_t bytes;

    while ((bytes = read(STDIN_FILENO, buffer, sizeof(buffer))) > 0) {
        if (fwrite(buffer, 1, bytes, fp) != (size_t)bytes) {
            LOG_ERROR("Write error: %s", strerror(errno));
            fclose(fp);
            unlink(filepath);
            return -1;
        }
    }

    fclose(fp);

    if (bytes < 0) {
        LOG_ERROR("Read error: %s", strerror(errno));
        unlink(filepath);
        return -1;
    }

    return 0;
}

/*
 * Parse a key=value option and apply to settings
 */
static void apply_option(const char *key, const char *value, ULSPrinterSettings *settings) {
    if (!key || !value || !settings) return;

    /* Global power override */
    if (strcasecmp(key, "power") == 0) {
        int power = atoi(value);
        if (power >= 0 && power <= 100) {
            for (int i = 0; i < ULS_PEN_COLOR_COUNT; i++) {
                settings->pens[i].power = (uint8_t)power;
            }
        }
        return;
    }

    /* Global speed override */
    if (strcasecmp(key, "speed") == 0) {
        int speed = atoi(value);
        if (speed >= 0 && speed <= 100) {
            for (int i = 0; i < ULS_PEN_COLOR_COUNT; i++) {
                settings->pens[i].speed = (uint8_t)speed;
            }
        }
        return;
    }

    /* Print mode */
    if (strcasecmp(key, "print-mode") == 0) {
        if (strcasecmp(value, "normal") == 0) {
            settings->printMode = ULS_PRINT_MODE_NORMAL;
        } else if (strcasecmp(value, "clipart") == 0) {
            settings->printMode = ULS_PRINT_MODE_CLIPART;
        } else if (strcasecmp(value, "3d") == 0) {
            settings->printMode = ULS_PRINT_MODE_3D;
        } else if (strcasecmp(value, "rubber-stamp") == 0) {
            settings->printMode = ULS_PRINT_MODE_RUBBER_STAMP;
        }
        return;
    }

    /* Image density */
    if (strcasecmp(key, "image-density") == 0) {
        int density = atoi(value);
        if (density >= 1 && density <= 8) {
            settings->imageDensity = (ULSImageDensity)density;
        }
        return;
    }

    /* Gas assist mode */
    if (strcasecmp(key, "gas-assist") == 0) {
        if (strcasecmp(value, "auto") == 0) {
            settings->gasAssistMode = ULS_GAS_ASSIST_AUTO;
        } else if (strcasecmp(value, "manual") == 0) {
            settings->gasAssistMode = ULS_GAS_ASSIST_MANUAL;
        }
        return;
    }

    /* Per-color settings: pen-{color}-{power|speed|ppi|mode} */
    const char *colors[] = {"black", "red", "green", "yellow", "blue", "magenta", "cyan", "orange"};

    for (int i = 0; i < ULS_PEN_COLOR_COUNT; i++) {
        char prefix[32];
        snprintf(prefix, sizeof(prefix), "pen-%s-", colors[i]);
        size_t prefix_len = strlen(prefix);

        if (strncasecmp(key, prefix, prefix_len) == 0) {
            const char *setting = key + prefix_len;

            if (strcasecmp(setting, "power") == 0) {
                int power = atoi(value);
                if (power >= 0 && power <= 100) {
                    settings->pens[i].power = (uint8_t)power;
                }
            } else if (strcasecmp(setting, "speed") == 0) {
                int speed = atoi(value);
                if (speed >= 0 && speed <= 100) {
                    settings->pens[i].speed = (uint8_t)speed;
                }
            } else if (strcasecmp(setting, "ppi") == 0) {
                int ppi = atoi(value);
                if (ppi >= 1 && ppi <= 1000) {
                    settings->pens[i].ppi = (uint16_t)ppi;
                }
            } else if (strcasecmp(setting, "mode") == 0) {
                if (strcasecmp(value, "rast-vect") == 0 || strcasecmp(value, "rast/vect") == 0) {
                    settings->pens[i].mode = ULS_PEN_MODE_RAST_VECT;
                } else if (strcasecmp(value, "rast") == 0) {
                    settings->pens[i].mode = ULS_PEN_MODE_RAST;
                } else if (strcasecmp(value, "vect") == 0) {
                    settings->pens[i].mode = ULS_PEN_MODE_VECT;
                } else if (strcasecmp(value, "skip") == 0) {
                    settings->pens[i].mode = ULS_PEN_MODE_SKIP;
                }
            } else if (strcasecmp(setting, "gas") == 0) {
                settings->pens[i].gasAssist = (strcasecmp(value, "on") == 0 ||
                                                strcasecmp(value, "true") == 0 ||
                                                strcasecmp(value, "1") == 0);
            }
            return;
        }
    }
}

/*
 * Parse CUPS options string into printer settings
 * Options are space-separated key=value pairs
 */
static void parse_cups_options(const char *options_str, ULSPrinterSettings *settings) {
    if (!options_str || !settings) return;

    char *opts = strdup(options_str);
    if (!opts) return;

    char *saveptr = NULL;
    char *token = strtok_r(opts, " ", &saveptr);

    while (token) {
        char *eq = strchr(token, '=');
        if (eq) {
            *eq = '\0';
            apply_option(token, eq + 1, settings);
        }
        token = strtok_r(NULL, " ", &saveptr);
    }

    free(opts);
}

/*
 * Process a print job
 */
static int process_job(const char *job_id, const char *user, const char *title,
                       int copies, const char *options_str, const char *filename) {
    int result = CUPS_BACKEND_FAILED;
    ULSDevice *device = NULL;
    ULSJob *job = NULL;
    ULSPrinterSettings *settings = NULL;
    char *temp_file = NULL;
    const char *pdf_file = filename;

    LOG_INFO("Processing job %s from %s: \"%s\" (%d copies)",
             job_id, user, title, copies);

    /* If no filename, copy stdin to temp file */
    if (!filename || filename[0] == '\0') {
        temp_file = create_temp_file();
        if (!temp_file) {
            return CUPS_BACKEND_FAILED;
        }
        if (copy_stdin_to_file(temp_file) < 0) {
            unlink(temp_file);
            return CUPS_BACKEND_FAILED;
        }
        pdf_file = temp_file;
        LOG_DEBUG("Job data saved to %s", temp_file);
    }

    /* Setup signal handlers */
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);

    /* Find and connect to device */
    ULSDeviceInfo *devices = NULL;
    int count = 0;

    ULSError err = uls_find_devices(&devices, &count);
    if (err != ULS_SUCCESS || count == 0) {
        LOG_ERROR("No ULS device found");
        LOG_STATE("-media-empty +offline");
        result = CUPS_BACKEND_RETRY;
        goto cleanup;
    }

    device = uls_open_device(devices[0].vendorId, devices[0].productId);
    uls_free_device_list(devices, count);

    if (!device) {
        LOG_ERROR("Failed to open ULS device");
        LOG_STATE("+offline");
        result = CUPS_BACKEND_RETRY;
        goto cleanup;
    }

    LOG_STATE("-offline");
    LOG_INFO("Connected to %s", uls_model_string(device->info.model));

    /* Create printer settings */
    settings = uls_printer_settings_create();

    /* Try to load default settings file */
    if (access(ULS_SETTINGS_FILE, R_OK) == 0) {
        if (uls_printer_settings_load(settings, ULS_SETTINGS_FILE) == ULS_SUCCESS) {
            LOG_INFO("Loaded settings from %s", ULS_SETTINGS_FILE);
        }
    }

    /* Apply CUPS options */
    parse_cups_options(options_str, settings);

    /* Process each copy */
    for (int copy = 1; copy <= copies && !g_cancelled; copy++) {
        if (copies > 1) {
            LOG_INFO("Processing copy %d of %d", copy, copies);
        }

        /* Create job from PDF */
        job = uls_job_create(title);
        if (!job) {
            LOG_ERROR("Failed to create job");
            result = CUPS_BACKEND_FAILED;
            goto cleanup;
        }

        /* Parse PDF (page 0 = first page) */
        err = uls_job_import_pdf(job, pdf_file, 0);
        if (err != ULS_SUCCESS) {
            LOG_ERROR("Failed to parse PDF: %s", uls_error_string(err));
            result = CUPS_BACKEND_FAILED;
            goto cleanup;
        }

        /* Apply pen settings */
        uls_job_apply_printer_settings(job, settings);

        /* Log job info */
        float minX, minY, maxX, maxY;
        uls_job_get_bounds(job, &minX, &minY, &maxX, &maxY);
        LOG_INFO("Job bounds: (%.2f\", %.2f\") to (%.2f\", %.2f\")",
                 minX, minY, maxX, maxY);

        float estTime;
        uls_job_get_estimated_time(job, &estTime);
        LOG_INFO("Estimated time: %.1f seconds", estTime);

        /* Compile and run job */
        err = uls_job_compile(job);
        if (err != ULS_SUCCESS) {
            LOG_ERROR("Failed to compile job: %s", uls_error_string(err));
            result = CUPS_BACKEND_FAILED;
            goto cleanup;
        }

        if (g_cancelled) {
            LOG_INFO("Job cancelled by user");
            result = CUPS_BACKEND_CANCEL;
            goto cleanup;
        }

        /* Send job to device */
        LOG_INFO("Sending job to laser...");
        LOG_STATE("+processing");

        err = uls_job_run(job, device);
        if (err != ULS_SUCCESS) {
            LOG_ERROR("Failed to run job: %s", uls_error_string(err));
            LOG_STATE("-processing");
            result = CUPS_BACKEND_FAILED;
            goto cleanup;
        }

        LOG_STATE("-processing");
        LOG_INFO("Job completed successfully");

        /* Clean up job for next copy */
        uls_job_destroy(job);
        job = NULL;
    }

    if (g_cancelled) {
        result = CUPS_BACKEND_CANCEL;
    } else {
        result = CUPS_BACKEND_OK;
    }

cleanup:
    if (job) {
        uls_job_destroy(job);
    }
    if (settings) {
        uls_printer_settings_destroy(settings);
    }
    if (device) {
        uls_close_device(device);
    }
    if (temp_file) {
        unlink(temp_file);
    }

    return result;
}

/*
 * Main entry point
 *
 * CUPS backend calling conventions:
 *   argc == 1: List devices
 *   argc == 6 or 7: Process print job
 *     argv[1] = job-id
 *     argv[2] = user
 *     argv[3] = title
 *     argv[4] = copies
 *     argv[5] = options
 *     argv[6] = filename (optional, if not present read from stdin)
 */
int main(int argc, char *argv[]) {
    /* Ensure we have proper permissions info */
    setbuf(stderr, NULL);

    /* List devices when called with no arguments */
    if (argc == 1) {
        return list_devices();
    }

    /* Validate arguments */
    if (argc < 6 || argc > 7) {
        fprintf(stderr, "Usage: %s job-id user title copies options [file]\n", argv[0]);
        fprintf(stderr, "       %s                                 (device discovery)\n", argv[0]);
        return CUPS_BACKEND_FAILED;
    }

    const char *job_id = argv[1];
    const char *user = argv[2];
    const char *title = argv[3];
    int copies = atoi(argv[4]);
    const char *options_str = argv[5];
    const char *filename = (argc == 7) ? argv[6] : NULL;

    /* Ensure at least 1 copy */
    if (copies < 1) copies = 1;

    /* Process the print job */
    return process_job(job_id, user, title, copies, options_str, filename);
}
