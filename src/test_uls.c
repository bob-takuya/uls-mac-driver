/*
 * ULS Driver Test Program
 * Tests the driver functionality without requiring actual hardware
 */

#include "uls_usb.h"
#include "uls_job.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* Test counters */
static int tests_run = 0;
static int tests_passed = 0;

#define TEST(name) do { \
    printf("Testing: %s... ", name); \
    tests_run++; \
} while(0)

#define PASS() do { \
    printf("PASSED\n"); \
    tests_passed++; \
} while(0)

#define FAIL(msg) do { \
    printf("FAILED: %s\n", msg); \
} while(0)

/* Test utility functions */
void test_error_strings(void) {
    TEST("uls_error_string");

    const char *s1 = uls_error_string(ULS_SUCCESS);
    const char *s2 = uls_error_string(ULS_ERROR_NOT_FOUND);
    const char *s3 = uls_error_string(ULS_ERROR_TIMEOUT);

    if (s1 && s2 && s3 &&
        strcmp(s1, "Success") == 0 &&
        strcmp(s2, "Device not found") == 0) {
        PASS();
    } else {
        FAIL("Error string mismatch");
    }
}

void test_model_strings(void) {
    TEST("uls_model_string");

    const char *s1 = uls_model_string(ULS_MODEL_PLS);
    const char *s2 = uls_model_string(ULS_MODEL_VLS_360);
    const char *s3 = uls_model_string(ULS_MODEL_ILS);

    if (s1 && s2 && s3 &&
        strstr(s1, "PLS") != NULL &&
        strstr(s2, "VLS") != NULL &&
        strstr(s3, "ILS") != NULL) {
        PASS();
    } else {
        FAIL("Model string mismatch");
    }
}

void test_state_strings(void) {
    TEST("uls_state_string");

    const char *s1 = uls_state_string(ULS_STATE_READY);
    const char *s2 = uls_state_string(ULS_STATE_BUSY);
    const char *s3 = uls_state_string(ULS_STATE_ERROR);

    if (s1 && s2 && s3 &&
        strcmp(s1, "Ready") == 0 &&
        strcmp(s2, "Busy") == 0 &&
        strcmp(s3, "Error") == 0) {
        PASS();
    } else {
        FAIL("State string mismatch");
    }
}

/* Test job creation */
void test_job_create(void) {
    TEST("uls_job_create");

    ULSJob *job = uls_job_create("test_job");
    if (job != NULL) {
        if (strcmp(job->name, "test_job") == 0) {
            PASS();
        } else {
            FAIL("Job name mismatch");
        }
        uls_job_destroy(job);
    } else {
        FAIL("Failed to create job");
    }
}

void test_job_settings(void) {
    TEST("uls_job_set_settings");

    ULSJob *job = uls_job_create("settings_test");
    ULSLaserSettings settings = {
        .power = 75,
        .speed = 60,
        .ppi = 500,
        .focusOffset = 0.1f,
        .airAssist = true,
        .material = ULS_MATERIAL_WOOD
    };

    uls_job_set_settings(job, &settings);

    if (job->settings.power == 75 &&
        job->settings.speed == 60 &&
        job->settings.ppi == 500 &&
        job->settings.material == ULS_MATERIAL_WOOD) {
        PASS();
    } else {
        FAIL("Settings not applied correctly");
    }

    uls_job_destroy(job);
}

/* Test path creation */
void test_path_create(void) {
    TEST("uls_path_create");

    ULSVectorPath *path = uls_path_create();
    if (path != NULL) {
        if (path->numElements == 0 && path->capacity > 0) {
            PASS();
        } else {
            FAIL("Path initial state incorrect");
        }
        uls_path_destroy(path);
    } else {
        FAIL("Failed to create path");
    }
}

void test_path_move_to(void) {
    TEST("uls_path_move_to");

    ULSVectorPath *path = uls_path_create();
    uls_path_move_to(path, 5.0f, 3.0f);

    if (path->numElements == 1 &&
        path->elements[0].op == ULS_PATH_OP_MOVE &&
        path->elements[0].points[0].x == 5.0f &&
        path->elements[0].points[0].y == 3.0f) {
        PASS();
    } else {
        FAIL("Move to failed");
    }

    uls_path_destroy(path);
}

void test_path_line_to(void) {
    TEST("uls_path_line_to");

    ULSVectorPath *path = uls_path_create();
    uls_path_move_to(path, 0.0f, 0.0f);
    uls_path_line_to(path, 10.0f, 10.0f);

    if (path->numElements == 2 &&
        path->elements[1].op == ULS_PATH_OP_LINE &&
        path->elements[1].points[0].x == 10.0f) {
        PASS();
    } else {
        FAIL("Line to failed");
    }

    uls_path_destroy(path);
}

void test_path_rectangle(void) {
    TEST("uls_path_add_rectangle");

    ULSVectorPath *path = uls_path_create();
    uls_path_add_rectangle(path, 1.0f, 1.0f, 2.0f, 3.0f);

    /* Rectangle: move + 3 lines + close = 5 elements */
    if (path->numElements == 5 && path->closed) {
        PASS();
    } else {
        FAIL("Rectangle creation failed");
    }

    uls_path_destroy(path);
}

void test_path_circle(void) {
    TEST("uls_path_add_circle");

    ULSVectorPath *path = uls_path_create();
    uls_path_add_circle(path, 5.0f, 5.0f, 2.0f);

    /* Circle: move + 4 bezier curves + close = 6 elements */
    if (path->numElements == 6 && path->closed) {
        PASS();
    } else {
        FAIL("Circle creation failed");
    }

    uls_path_destroy(path);
}

void test_path_laser_settings(void) {
    TEST("uls_path_set_laser");

    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, 80, 40, 1000);

    if (path->power == 80 && path->speed == 40 && path->ppi == 1000) {
        PASS();
    } else {
        FAIL("Path laser settings failed");
    }

    uls_path_destroy(path);
}

/* Test job operations */
void test_job_add_path(void) {
    TEST("uls_job_add_path");

    ULSJob *job = uls_job_create("path_test");
    ULSVectorPath *path = uls_path_create();
    uls_path_add_rectangle(path, 0.0f, 0.0f, 5.0f, 5.0f);

    uls_job_add_path(job, path);

    if (job->numVectorPaths == 1 &&
        job->type == ULS_JOB_TYPE_VECTOR) {
        PASS();
    } else {
        FAIL("Add path failed");
    }

    uls_job_destroy(job);
}

void test_job_bounds(void) {
    TEST("uls_job_get_bounds");

    ULSJob *job = uls_job_create("bounds_test");
    ULSVectorPath *path = uls_path_create();
    uls_path_add_rectangle(path, 1.0f, 2.0f, 5.0f, 3.0f);
    uls_job_add_path(job, path);

    float minX, minY, maxX, maxY;
    uls_job_get_bounds(job, &minX, &minY, &maxX, &maxY);

    if (minX == 1.0f && minY == 2.0f &&
        maxX == 6.0f && maxY == 5.0f) {
        PASS();
    } else {
        FAIL("Bounds calculation incorrect");
    }

    uls_job_destroy(job);
}

void test_job_compile(void) {
    TEST("uls_job_compile");

    ULSJob *job = uls_job_create("compile_test");
    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, 50, 50, 500);
    uls_path_add_rectangle(path, 0.0f, 0.0f, 2.0f, 2.0f);
    uls_job_add_path(job, path);

    ULSError err = uls_job_compile(job);

    if (err == ULS_SUCCESS &&
        job->isCompiled &&
        job->compiledData != NULL &&
        job->compiledDataSize > 0) {
        PASS();
    } else {
        FAIL("Job compilation failed");
    }

    uls_job_destroy(job);
}

/* Test raster operations */
void test_raster_create(void) {
    TEST("uls_raster_create");

    ULSRasterImage *image = uls_raster_create(100, 100, 8);

    if (image != NULL &&
        image->width == 100 &&
        image->height == 100 &&
        image->bitsPerPixel == 8 &&
        image->data != NULL) {
        PASS();
    } else {
        FAIL("Raster creation failed");
    }

    uls_raster_destroy(image);
}

void test_raster_settings(void) {
    TEST("uls_raster_set_*");

    ULSRasterImage *image = uls_raster_create(50, 50, 8);
    uls_raster_set_origin(image, 1.0f, 2.0f);
    uls_raster_set_dpi(image, 600.0f);
    uls_raster_set_laser(image, 70, 30);
    uls_raster_set_color_mode(image, ULS_COLOR_MODE_DITHER);

    if (image->originX == 1.0f &&
        image->originY == 2.0f &&
        image->dpi == 600.0f &&
        image->power == 70 &&
        image->speed == 30 &&
        image->colorMode == ULS_COLOR_MODE_DITHER) {
        PASS();
    } else {
        FAIL("Raster settings failed");
    }

    uls_raster_destroy(image);
}

/* Test material presets */
void test_material_presets(void) {
    TEST("uls_get_material_settings");

    ULSLaserSettings settings;

    uls_get_material_settings(ULS_MATERIAL_ACRYLIC, ULS_MODEL_PLS, &settings);
    int acrylic_ok = settings.power > 50 && settings.speed < 50;

    uls_get_material_settings(ULS_MATERIAL_PAPER, ULS_MODEL_PLS, &settings);
    int paper_ok = settings.power < 50 && settings.speed > 50;

    if (acrylic_ok && paper_ok) {
        PASS();
    } else {
        FAIL("Material presets incorrect");
    }
}

/* Test printer settings creation */
void test_printer_settings_create(void) {
    TEST("uls_printer_settings_create");

    ULSPrinterSettings *settings = uls_printer_settings_create();
    if (settings != NULL) {
        /* Check defaults */
        if (settings->printMode == ULS_PRINT_MODE_NORMAL &&
            settings->imageDensity == ULS_IMAGE_DENSITY_6 &&
            settings->pens[0].power == ULS_DEFAULT_POWER) {
            PASS();
        } else {
            FAIL("Default settings incorrect");
        }
        uls_printer_settings_destroy(settings);
    } else {
        FAIL("Failed to create settings");
    }
}

/* Test pen settings */
void test_pen_settings(void) {
    TEST("uls_pen_set/get functions");

    ULSPrinterSettings *settings = uls_printer_settings_create();

    /* Set custom values for red pen */
    uls_pen_set_mode(settings, ULS_PEN_COLOR_RED, ULS_PEN_MODE_VECT);
    uls_pen_set_power(settings, ULS_PEN_COLOR_RED, 75);
    uls_pen_set_speed(settings, ULS_PEN_COLOR_RED, 30);
    uls_pen_set_ppi(settings, ULS_PEN_COLOR_RED, 800);
    uls_pen_set_gas_assist(settings, ULS_PEN_COLOR_RED, false);

    /* Verify */
    int ok = (uls_pen_get_mode(settings, ULS_PEN_COLOR_RED) == ULS_PEN_MODE_VECT &&
              uls_pen_get_power(settings, ULS_PEN_COLOR_RED) == 75 &&
              uls_pen_get_speed(settings, ULS_PEN_COLOR_RED) == 30 &&
              uls_pen_get_ppi(settings, ULS_PEN_COLOR_RED) == 800 &&
              uls_pen_get_gas_assist(settings, ULS_PEN_COLOR_RED) == false);

    if (ok) {
        PASS();
    } else {
        FAIL("Pen settings mismatch");
    }

    uls_printer_settings_destroy(settings);
}

/* Test color matching */
void test_color_matching(void) {
    TEST("uls_match_color_to_pen");

    int ok = 1;

    /* Pure colors should match exactly */
    ok &= (uls_match_color_to_pen(0, 0, 0) == ULS_PEN_COLOR_BLACK);
    ok &= (uls_match_color_to_pen(255, 0, 0) == ULS_PEN_COLOR_RED);
    ok &= (uls_match_color_to_pen(0, 255, 0) == ULS_PEN_COLOR_GREEN);
    ok &= (uls_match_color_to_pen(0, 0, 255) == ULS_PEN_COLOR_BLUE);
    ok &= (uls_match_color_to_pen(255, 255, 0) == ULS_PEN_COLOR_YELLOW);
    ok &= (uls_match_color_to_pen(255, 0, 255) == ULS_PEN_COLOR_MAGENTA);
    ok &= (uls_match_color_to_pen(0, 255, 255) == ULS_PEN_COLOR_CYAN);

    /* Close colors should match nearby pen */
    ok &= (uls_match_color_to_pen(200, 0, 0) == ULS_PEN_COLOR_RED);
    ok &= (uls_match_color_to_pen(10, 10, 10) == ULS_PEN_COLOR_BLACK);

    if (ok) {
        PASS();
    } else {
        FAIL("Color matching incorrect");
    }
}

/* Test pen mode and color strings */
void test_string_functions(void) {
    TEST("uls_pen_*_string functions");

    int ok = 1;

    ok &= (strcmp(uls_pen_color_string(ULS_PEN_COLOR_BLACK), "Black") == 0);
    ok &= (strcmp(uls_pen_color_string(ULS_PEN_COLOR_RED), "Red") == 0);
    ok &= (strcmp(uls_pen_mode_string(ULS_PEN_MODE_RAST_VECT), "RAST/VECT") == 0);
    ok &= (strcmp(uls_pen_mode_string(ULS_PEN_MODE_SKIP), "SKIP") == 0);
    ok &= (strcmp(uls_print_mode_string(ULS_PRINT_MODE_NORMAL), "Normal") == 0);
    ok &= (strcmp(uls_print_mode_string(ULS_PRINT_MODE_3D), "3D") == 0);

    if (ok) {
        PASS();
    } else {
        FAIL("String functions incorrect");
    }
}

/* Test settings copy */
void test_settings_copy(void) {
    TEST("uls_printer_settings_copy");

    ULSPrinterSettings *src = uls_printer_settings_create();
    ULSPrinterSettings *dest = uls_printer_settings_create();

    /* Modify source */
    uls_pen_set_power(src, ULS_PEN_COLOR_BLACK, 80);
    src->printMode = ULS_PRINT_MODE_3D;

    /* Copy */
    uls_printer_settings_copy(dest, src);

    /* Verify */
    int ok = (dest->pens[ULS_PEN_COLOR_BLACK].power == 80 &&
              dest->printMode == ULS_PRINT_MODE_3D);

    if (ok) {
        PASS();
    } else {
        FAIL("Settings copy failed");
    }

    uls_printer_settings_destroy(src);
    uls_printer_settings_destroy(dest);
}

/* Test device enumeration (will find no devices if none connected) */
void test_find_devices(void) {
    TEST("uls_find_devices (no device expected)");

    ULSDeviceInfo *devices = NULL;
    int count = 0;

    ULSError err = uls_find_devices(&devices, &count);

    /* Either success with devices or not found is acceptable */
    if (err == ULS_SUCCESS || err == ULS_ERROR_NOT_FOUND) {
        PASS();
        if (err == ULS_SUCCESS) {
            printf("    Note: Found %d device(s)\n", count);
            uls_free_device_list(devices, count);
        }
    } else {
        FAIL("Unexpected error from find_devices");
    }
}

/* Main test runner */
int main(void) {
    printf("===========================================\n");
    printf("    ULS Driver Test Suite\n");
    printf("===========================================\n\n");

    /* Utility tests */
    printf("--- Utility Functions ---\n");
    test_error_strings();
    test_model_strings();
    test_state_strings();
    printf("\n");

    /* Job tests */
    printf("--- Job Functions ---\n");
    test_job_create();
    test_job_settings();
    printf("\n");

    /* Path tests */
    printf("--- Path Functions ---\n");
    test_path_create();
    test_path_move_to();
    test_path_line_to();
    test_path_rectangle();
    test_path_circle();
    test_path_laser_settings();
    printf("\n");

    /* Job operation tests */
    printf("--- Job Operations ---\n");
    test_job_add_path();
    test_job_bounds();
    test_job_compile();
    printf("\n");

    /* Raster tests */
    printf("--- Raster Functions ---\n");
    test_raster_create();
    test_raster_settings();
    printf("\n");

    /* Material tests */
    printf("--- Material Presets ---\n");
    test_material_presets();
    printf("\n");

    /* Printer Settings (8-color pen mapping) tests */
    printf("--- Printer Settings (8-Color Pen Mapping) ---\n");
    test_printer_settings_create();
    test_pen_settings();
    test_color_matching();
    test_string_functions();
    test_settings_copy();
    printf("\n");

    /* Device tests */
    printf("--- Device Functions ---\n");
    test_find_devices();
    printf("\n");

    /* Summary */
    printf("===========================================\n");
    printf("    Results: %d/%d tests passed\n", tests_passed, tests_run);
    printf("===========================================\n");

    return (tests_passed == tests_run) ? 0 : 1;
}
