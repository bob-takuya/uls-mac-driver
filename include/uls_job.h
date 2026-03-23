/*
 * ULS (Universal Laser Systems) Job Processing Header
 * macOS Driver Implementation
 *
 * Handles laser job creation, vector/raster processing, and job submission
 */

#ifndef ULS_JOB_H
#define ULS_JOB_H

#include "uls_usb.h"
#include <stdint.h>
#include <stdbool.h>

/* Job Types */
typedef enum {
    ULS_JOB_TYPE_VECTOR,
    ULS_JOB_TYPE_RASTER,
    ULS_JOB_TYPE_COMBINED
} ULSJobType;

/* Pen Mode - Controls how each color is processed */
typedef enum {
    ULS_PEN_MODE_RAST_VECT = 0,  /* Raster fills, Vector outlines (default) */
    ULS_PEN_MODE_RAST,           /* Raster everything (fills and outlines) */
    ULS_PEN_MODE_VECT,           /* Vector only (hairline outlines, skip fills) */
    ULS_PEN_MODE_SKIP            /* Skip this color entirely */
} ULSPenMode;

/* Print Mode - Global processing mode */
typedef enum {
    ULS_PRINT_MODE_NORMAL = 0,   /* Standard color-mapped processing */
    ULS_PRINT_MODE_CLIPART,      /* Raster everything as grayscale */
    ULS_PRINT_MODE_3D,           /* 3D depth engraving from grayscale */
    ULS_PRINT_MODE_RUBBER_STAMP  /* Rubber stamp mode (inverted) */
} ULSPrintMode;

/* Image Density levels (1-8) */
typedef enum {
    ULS_IMAGE_DENSITY_1 = 1,     /* Fastest, lowest quality */
    ULS_IMAGE_DENSITY_2 = 2,
    ULS_IMAGE_DENSITY_3 = 3,
    ULS_IMAGE_DENSITY_4 = 4,
    ULS_IMAGE_DENSITY_5 = 5,
    ULS_IMAGE_DENSITY_6 = 6,     /* Standard quality */
    ULS_IMAGE_DENSITY_7 = 7,     /* Dual Beam only */
    ULS_IMAGE_DENSITY_8 = 8      /* Highest quality, Dual Beam only */
} ULSImageDensity;

/* Pen Color indices (8 colors for color mapping) */
typedef enum {
    ULS_PEN_COLOR_BLACK = 0,
    ULS_PEN_COLOR_RED,
    ULS_PEN_COLOR_GREEN,
    ULS_PEN_COLOR_YELLOW,
    ULS_PEN_COLOR_BLUE,
    ULS_PEN_COLOR_MAGENTA,
    ULS_PEN_COLOR_CYAN,
    ULS_PEN_COLOR_ORANGE,
    ULS_PEN_COLOR_COUNT          /* Total number of pen colors = 8 */
} ULSPenColor;

/* Gas Assist mode */
typedef enum {
    ULS_GAS_ASSIST_MANUAL = 0,   /* Manual control (always on or off) */
    ULS_GAS_ASSIST_AUTO          /* Computer controlled per pen color */
} ULSGasAssistMode;

/* Settings for a single pen color */
typedef struct {
    ULSPenMode mode;             /* Processing mode for this color */
    uint8_t power;               /* 0-100% power */
    uint8_t speed;               /* 0-100% speed */
    uint16_t ppi;                /* Pulses per inch (1-1000) */
    bool gasAssist;              /* Enable gas assist for this color */
} ULSPenSettings;

/* Material Types (affects default power/speed settings) */
typedef enum {
    ULS_MATERIAL_CUSTOM = 0,
    ULS_MATERIAL_ACRYLIC,
    ULS_MATERIAL_WOOD,
    ULS_MATERIAL_PAPER,
    ULS_MATERIAL_LEATHER,
    ULS_MATERIAL_FABRIC,
    ULS_MATERIAL_RUBBER,
    ULS_MATERIAL_GLASS,
    ULS_MATERIAL_METAL_MARKING,
    ULS_MATERIAL_STONE
} ULSMaterialType;

/* Color Mapping Mode (for raster operations) */
typedef enum {
    ULS_COLOR_MODE_BW,          /* Black and white threshold */
    ULS_COLOR_MODE_GRAYSCALE,   /* Grayscale with power modulation */
    ULS_COLOR_MODE_DITHER,      /* Floyd-Steinberg dithering */
    ULS_COLOR_MODE_HALFTONE     /* Halftone pattern */
} ULSColorMode;

/* Vector Path Operation */
typedef enum {
    ULS_PATH_OP_MOVE,
    ULS_PATH_OP_LINE,
    ULS_PATH_OP_BEZIER,
    ULS_PATH_OP_ARC,
    ULS_PATH_OP_CLOSE
} ULSPathOperation;

/* Point structure */
typedef struct {
    float x;
    float y;
} ULSPoint;

/* Path element */
typedef struct {
    ULSPathOperation op;
    ULSPoint points[4];  /* Max 4 control points for bezier */
    int numPoints;
} ULSPathElement;

/* Vector path */
typedef struct {
    ULSPathElement *elements;
    int numElements;
    int capacity;
    uint8_t power;
    uint8_t speed;
    uint16_t ppi;
    bool closed;
} ULSVectorPath;

/* Raster image */
typedef struct {
    uint8_t *data;
    int width;
    int height;
    int bitsPerPixel;
    float dpi;
    float originX;
    float originY;
    uint8_t power;
    uint8_t speed;
    ULSColorMode colorMode;
} ULSRasterImage;

/* Laser settings (simple, for backwards compatibility) */
typedef struct {
    uint8_t power;          /* 0-100% */
    uint8_t speed;          /* 0-100% */
    uint16_t ppi;           /* Pulses per inch (vector mode) */
    float focusOffset;      /* Z offset for material thickness */
    bool airAssist;
    ULSMaterialType material;
} ULSLaserSettings;

/* Complete printer driver settings (matches Windows driver functionality) */
typedef struct {
    /* 8 pen color settings */
    ULSPenSettings pens[ULS_PEN_COLOR_COUNT];

    /* Global settings */
    ULSPrintMode printMode;
    ULSImageDensity imageDensity;
    ULSGasAssistMode gasAssistMode;

    /* Material and focus */
    ULSMaterialType material;
    float materialThickness;    /* Material thickness in inches */
    float focusOffset;          /* Additional Z offset */

    /* SuperSpeed options */
    bool dualBeam;              /* Enable dual beam (SuperSpeed only) */
    uint8_t lensType;           /* 0=1.5", 1=2.0", 2=2.5", 3=4.0" */

    /* Page settings */
    float pageWidth;            /* Page width in inches */
    float pageHeight;           /* Page height in inches */

    /* Name for saving/loading */
    char presetName[128];
} ULSPrinterSettings;

/* Default pen settings */
#define ULS_DEFAULT_POWER     50
#define ULS_DEFAULT_SPEED     50
#define ULS_DEFAULT_PPI       500

/* Job structure */
typedef struct ULSJob {
    char name[256];
    ULSJobType type;
    ULSLaserSettings settings;

    /* Vector data */
    ULSVectorPath **vectorPaths;
    int numVectorPaths;
    int vectorPathCapacity;

    /* Raster data */
    ULSRasterImage **rasterImages;
    int numRasterImages;
    int rasterImageCapacity;

    /* Bounding box */
    float minX, minY;
    float maxX, maxY;

    /* Job state */
    bool isCompiled;
    uint8_t *compiledData;
    size_t compiledDataSize;

    /* Progress callback */
    void (*progressCallback)(struct ULSJob *job, float progress, void *userContext);
    void *progressUserContext;
} ULSJob;

/* Job creation and management */
ULSJob* uls_job_create(const char *name);
void uls_job_destroy(ULSJob *job);
void uls_job_set_settings(ULSJob *job, const ULSLaserSettings *settings);

/* Vector operations */
ULSVectorPath* uls_path_create(void);
void uls_path_destroy(ULSVectorPath *path);
void uls_path_move_to(ULSVectorPath *path, float x, float y);
void uls_path_line_to(ULSVectorPath *path, float x, float y);
void uls_path_bezier_to(ULSVectorPath *path, float cp1x, float cp1y,
                         float cp2x, float cp2y, float x, float y);
void uls_path_arc_to(ULSVectorPath *path, float cx, float cy,
                      float radius, float startAngle, float endAngle);
void uls_path_close(ULSVectorPath *path);
void uls_path_set_laser(ULSVectorPath *path, uint8_t power, uint8_t speed, uint16_t ppi);
void uls_job_add_path(ULSJob *job, ULSVectorPath *path);

/* Shape helpers */
void uls_path_add_rectangle(ULSVectorPath *path, float x, float y, float width, float height);
void uls_path_add_circle(ULSVectorPath *path, float cx, float cy, float radius);
void uls_path_add_ellipse(ULSVectorPath *path, float cx, float cy, float rx, float ry);
void uls_path_add_rounded_rect(ULSVectorPath *path, float x, float y,
                                float width, float height, float radius);

/* Raster operations */
ULSRasterImage* uls_raster_create(int width, int height, int bitsPerPixel);
ULSRasterImage* uls_raster_load_from_file(const char *filepath);
ULSRasterImage* uls_raster_load_from_memory(const uint8_t *data, size_t dataSize);
void uls_raster_destroy(ULSRasterImage *image);
void uls_raster_set_origin(ULSRasterImage *image, float x, float y);
void uls_raster_set_dpi(ULSRasterImage *image, float dpi);
void uls_raster_set_laser(ULSRasterImage *image, uint8_t power, uint8_t speed);
void uls_raster_set_color_mode(ULSRasterImage *image, ULSColorMode mode);
void uls_job_add_raster(ULSJob *job, ULSRasterImage *image);

/* SVG/PDF import */
ULSError uls_job_import_svg(ULSJob *job, const char *filepath);
ULSError uls_job_import_pdf(ULSJob *job, const char *filepath, int pageNumber);

/* Job compilation and execution */
ULSError uls_job_compile(ULSJob *job);
ULSError uls_job_get_bounds(ULSJob *job, float *minX, float *minY, float *maxX, float *maxY);
ULSError uls_job_get_estimated_time(ULSJob *job, float *seconds);
ULSError uls_job_send(ULSJob *job, ULSDevice *device);
ULSError uls_job_run(ULSJob *job, ULSDevice *device);

/* Job progress callback */
typedef void (*ULSJobProgressCallback)(ULSJob *job, float progress, void *userContext);
void uls_job_set_progress_callback(ULSJob *job, ULSJobProgressCallback callback, void *userContext);

/* ============================================
 * Simulation Engine
 * ============================================
 * Traces the tool path with realistic motion physics
 * (trapezoidal velocity profile with acceleration).
 * Used for both accurate time estimation and animated playback.
 */

/* Simulation waypoint */
typedef struct {
    float x, y;        /* Position in inches */
    float time;         /* Cumulative time in seconds */
    bool laserOn;       /* Laser firing state */
} ULSSimPoint;

/* Simulation result */
typedef struct {
    ULSSimPoint *points;
    int numPoints;
    int capacity;
    float totalTime;    /* Total job time in seconds */
} ULSSimulation;

/* Machine physics constants */
#define ULS_SIM_MAX_RAPID_IPS    60.0f    /* Rapid traverse speed (in/s) */
#define ULS_SIM_MAX_CUT_IPS     50.0f    /* Max cutting speed at 100% (in/s) */
#define ULS_SIM_ACCEL_IPS2     500.0f    /* Acceleration (in/s²) */
#define ULS_SIM_BEZIER_SUBDIV      8     /* Bezier curve subdivisions */

/* Create a simulation trace from a job */
ULSSimulation* uls_job_simulate(ULSJob *job);

/* Destroy simulation */
void uls_simulation_destroy(ULSSimulation *sim);

/* Interpolate position at a given time */
void uls_simulation_get_position(ULSSimulation *sim, float time,
                                  float *x, float *y, bool *laserOn);

/* Get simulation point index for a given time (binary search) */
int uls_simulation_index_at_time(ULSSimulation *sim, float time);

/* Material presets */
void uls_get_material_settings(ULSMaterialType material, ULSModelType model, ULSLaserSettings *settings);

/* ============================================
 * Printer Settings API (8-color pen mapping)
 * ============================================ */

/* Create default printer settings */
ULSPrinterSettings* uls_printer_settings_create(void);
void uls_printer_settings_destroy(ULSPrinterSettings *settings);

/* Initialize settings with defaults */
void uls_printer_settings_reset(ULSPrinterSettings *settings);

/* Copy settings */
void uls_printer_settings_copy(ULSPrinterSettings *dest, const ULSPrinterSettings *src);

/* Per-pen configuration */
void uls_pen_set_mode(ULSPrinterSettings *settings, ULSPenColor color, ULSPenMode mode);
void uls_pen_set_power(ULSPrinterSettings *settings, ULSPenColor color, uint8_t power);
void uls_pen_set_speed(ULSPrinterSettings *settings, ULSPenColor color, uint8_t speed);
void uls_pen_set_ppi(ULSPrinterSettings *settings, ULSPenColor color, uint16_t ppi);
void uls_pen_set_gas_assist(ULSPrinterSettings *settings, ULSPenColor color, bool enabled);
void uls_pen_set_all(ULSPrinterSettings *settings, ULSPenColor color,
                     ULSPenMode mode, uint8_t power, uint8_t speed, uint16_t ppi, bool gasAssist);

/* Get pen settings */
ULSPenMode uls_pen_get_mode(const ULSPrinterSettings *settings, ULSPenColor color);
uint8_t uls_pen_get_power(const ULSPrinterSettings *settings, ULSPenColor color);
uint8_t uls_pen_get_speed(const ULSPrinterSettings *settings, ULSPenColor color);
uint16_t uls_pen_get_ppi(const ULSPrinterSettings *settings, ULSPenColor color);
bool uls_pen_get_gas_assist(const ULSPrinterSettings *settings, ULSPenColor color);

/* Save/Load settings (.LAS file format) */
ULSError uls_printer_settings_save(const ULSPrinterSettings *settings, const char *filepath);
ULSError uls_printer_settings_load(ULSPrinterSettings *settings, const char *filepath);

/* Apply material preset to all pens */
void uls_printer_settings_apply_material(ULSPrinterSettings *settings,
                                          ULSMaterialType material, ULSModelType model);

/* Get color name string */
const char* uls_pen_color_string(ULSPenColor color);
const char* uls_pen_mode_string(ULSPenMode mode);
const char* uls_print_mode_string(ULSPrintMode mode);

/* Color matching - find closest pen color for RGB */
ULSPenColor uls_match_color_to_pen(uint8_t r, uint8_t g, uint8_t b);

/* Apply printer settings to a job */
void uls_job_apply_printer_settings(ULSJob *job, const ULSPrinterSettings *settings);

#endif /* ULS_JOB_H */
