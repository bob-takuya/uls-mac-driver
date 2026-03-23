/*
 * ULS (Universal Laser Systems) Job Processing Implementation
 * macOS Driver Implementation
 */

#include "uls_job.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define INITIAL_PATH_CAPACITY 64
#define INITIAL_JOB_CAPACITY 16

/* Internal command codes for compiled job data */
#define CMD_HEADER          0x00
#define CMD_MOVE_ABS        0x01
#define CMD_LINE_ABS        0x02
#define CMD_BEZIER_ABS      0x03
#define CMD_ARC_ABS         0x04
#define CMD_SET_POWER       0x10
#define CMD_SET_SPEED       0x11
#define CMD_SET_PPI         0x12
#define CMD_LASER_ON        0x20
#define CMD_LASER_OFF       0x21
#define CMD_RASTER_START    0x30
#define CMD_RASTER_LINE     0x31
#define CMD_RASTER_END      0x32
#define CMD_JOB_END         0xFF

/* Create a new job */
ULSJob* uls_job_create(const char *name) {
    ULSJob *job = (ULSJob *)calloc(1, sizeof(ULSJob));
    if (!job) return NULL;

    if (name) {
        strncpy(job->name, name, sizeof(job->name) - 1);
    }

    job->vectorPathCapacity = INITIAL_JOB_CAPACITY;
    job->vectorPaths = (ULSVectorPath **)malloc(job->vectorPathCapacity * sizeof(ULSVectorPath *));

    job->rasterImageCapacity = INITIAL_JOB_CAPACITY;
    job->rasterImages = (ULSRasterImage **)malloc(job->rasterImageCapacity * sizeof(ULSRasterImage *));

    /* Default settings */
    job->settings.power = 50;
    job->settings.speed = 50;
    job->settings.ppi = 500;
    job->settings.focusOffset = 0.0f;
    job->settings.airAssist = true;
    job->settings.material = ULS_MATERIAL_CUSTOM;

    /* Initialize bounds to invalid state */
    job->minX = job->minY = INFINITY;
    job->maxX = job->maxY = -INFINITY;

    return job;
}

/* Destroy a job */
void uls_job_destroy(ULSJob *job) {
    if (!job) return;

    for (int i = 0; i < job->numVectorPaths; i++) {
        uls_path_destroy(job->vectorPaths[i]);
    }
    free(job->vectorPaths);

    for (int i = 0; i < job->numRasterImages; i++) {
        uls_raster_destroy(job->rasterImages[i]);
    }
    free(job->rasterImages);

    if (job->compiledData) {
        free(job->compiledData);
    }

    free(job);
}

/* Set job settings */
void uls_job_set_settings(ULSJob *job, const ULSLaserSettings *settings) {
    if (!job || !settings) return;
    memcpy(&job->settings, settings, sizeof(ULSLaserSettings));
}

/* Create a vector path */
ULSVectorPath* uls_path_create(void) {
    ULSVectorPath *path = (ULSVectorPath *)calloc(1, sizeof(ULSVectorPath));
    if (!path) return NULL;

    path->capacity = INITIAL_PATH_CAPACITY;
    path->elements = (ULSPathElement *)malloc(path->capacity * sizeof(ULSPathElement));
    if (!path->elements) {
        free(path);
        return NULL;
    }

    /* Default settings */
    path->power = 50;
    path->speed = 50;
    path->ppi = 500;

    return path;
}

/* Destroy a vector path */
void uls_path_destroy(ULSVectorPath *path) {
    if (!path) return;
    if (path->elements) free(path->elements);
    free(path);
}

/* Helper to add element to path */
static void path_add_element(ULSVectorPath *path, ULSPathElement *element) {
    if (path->numElements >= path->capacity) {
        path->capacity *= 2;
        path->elements = (ULSPathElement *)realloc(path->elements,
                                                    path->capacity * sizeof(ULSPathElement));
    }
    memcpy(&path->elements[path->numElements++], element, sizeof(ULSPathElement));
}

/* Move to position */
void uls_path_move_to(ULSVectorPath *path, float x, float y) {
    if (!path) return;

    ULSPathElement el = {0};
    el.op = ULS_PATH_OP_MOVE;
    el.points[0].x = x;
    el.points[0].y = y;
    el.numPoints = 1;

    path_add_element(path, &el);
}

/* Line to position */
void uls_path_line_to(ULSVectorPath *path, float x, float y) {
    if (!path) return;

    ULSPathElement el = {0};
    el.op = ULS_PATH_OP_LINE;
    el.points[0].x = x;
    el.points[0].y = y;
    el.numPoints = 1;

    path_add_element(path, &el);
}

/* Bezier curve to position */
void uls_path_bezier_to(ULSVectorPath *path, float cp1x, float cp1y,
                         float cp2x, float cp2y, float x, float y) {
    if (!path) return;

    ULSPathElement el = {0};
    el.op = ULS_PATH_OP_BEZIER;
    el.points[0].x = cp1x;
    el.points[0].y = cp1y;
    el.points[1].x = cp2x;
    el.points[1].y = cp2y;
    el.points[2].x = x;
    el.points[2].y = y;
    el.numPoints = 3;

    path_add_element(path, &el);
}

/* Arc to position */
void uls_path_arc_to(ULSVectorPath *path, float cx, float cy,
                      float radius, float startAngle, float endAngle) {
    if (!path) return;

    /* Convert arc to bezier segments */
    float angleSpan = endAngle - startAngle;
    int numSegments = (int)ceil(fabs(angleSpan) / (M_PI / 2.0)) + 1;
    float angleStep = angleSpan / numSegments;

    for (int i = 0; i < numSegments; i++) {
        float a1 = startAngle + i * angleStep;
        float a2 = startAngle + (i + 1) * angleStep;

        /* Calculate bezier control points for arc segment */
        float x1 = cx + radius * cos(a1);
        float y1 = cy + radius * sin(a1);
        float x2 = cx + radius * cos(a2);
        float y2 = cy + radius * sin(a2);

        float alpha = sin(a2 - a1) * (sqrt(4 + 3 * pow(tan((a2 - a1) / 2), 2)) - 1) / 3;

        float cp1x = x1 + alpha * (-radius * sin(a1));
        float cp1y = y1 + alpha * (radius * cos(a1));
        float cp2x = x2 - alpha * (-radius * sin(a2));
        float cp2y = y2 - alpha * (radius * cos(a2));

        if (i == 0) {
            uls_path_move_to(path, x1, y1);
        }
        uls_path_bezier_to(path, cp1x, cp1y, cp2x, cp2y, x2, y2);
    }
}

/* Close path */
void uls_path_close(ULSVectorPath *path) {
    if (!path) return;

    ULSPathElement el = {0};
    el.op = ULS_PATH_OP_CLOSE;
    el.numPoints = 0;
    path->closed = true;

    path_add_element(path, &el);
}

/* Set laser parameters for path */
void uls_path_set_laser(ULSVectorPath *path, uint8_t power, uint8_t speed, uint16_t ppi) {
    if (!path) return;
    path->power = power > 100 ? 100 : power;
    path->speed = speed > 100 ? 100 : speed;
    path->ppi = ppi;
}

/* Add path to job */
void uls_job_add_path(ULSJob *job, ULSVectorPath *path) {
    if (!job || !path) return;

    if (job->numVectorPaths >= job->vectorPathCapacity) {
        job->vectorPathCapacity *= 2;
        job->vectorPaths = (ULSVectorPath **)realloc(job->vectorPaths,
                                                      job->vectorPathCapacity * sizeof(ULSVectorPath *));
    }

    job->vectorPaths[job->numVectorPaths++] = path;
    job->type = (job->numRasterImages > 0) ? ULS_JOB_TYPE_COMBINED : ULS_JOB_TYPE_VECTOR;
    job->isCompiled = false;

    /* Update bounds */
    for (int i = 0; i < path->numElements; i++) {
        ULSPathElement *el = &path->elements[i];
        for (int j = 0; j < el->numPoints; j++) {
            if (el->points[j].x < job->minX) job->minX = el->points[j].x;
            if (el->points[j].y < job->minY) job->minY = el->points[j].y;
            if (el->points[j].x > job->maxX) job->maxX = el->points[j].x;
            if (el->points[j].y > job->maxY) job->maxY = el->points[j].y;
        }
    }
}

/* Shape helpers */
void uls_path_add_rectangle(ULSVectorPath *path, float x, float y, float width, float height) {
    if (!path) return;

    uls_path_move_to(path, x, y);
    uls_path_line_to(path, x + width, y);
    uls_path_line_to(path, x + width, y + height);
    uls_path_line_to(path, x, y + height);
    uls_path_close(path);
}

void uls_path_add_circle(ULSVectorPath *path, float cx, float cy, float radius) {
    uls_path_add_ellipse(path, cx, cy, radius, radius);
}

void uls_path_add_ellipse(ULSVectorPath *path, float cx, float cy, float rx, float ry) {
    if (!path) return;

    /* Approximate ellipse with 4 bezier curves */
    float kappa = 0.5522847498f; /* (4/3)*tan(pi/8) */

    uls_path_move_to(path, cx + rx, cy);
    uls_path_bezier_to(path, cx + rx, cy + ry * kappa,
                        cx + rx * kappa, cy + ry, cx, cy + ry);
    uls_path_bezier_to(path, cx - rx * kappa, cy + ry,
                        cx - rx, cy + ry * kappa, cx - rx, cy);
    uls_path_bezier_to(path, cx - rx, cy - ry * kappa,
                        cx - rx * kappa, cy - ry, cx, cy - ry);
    uls_path_bezier_to(path, cx + rx * kappa, cy - ry,
                        cx + rx, cy - ry * kappa, cx + rx, cy);
    uls_path_close(path);
}

void uls_path_add_rounded_rect(ULSVectorPath *path, float x, float y,
                                float width, float height, float radius) {
    if (!path) return;

    float kappa = 0.5522847498f;

    uls_path_move_to(path, x + radius, y);
    uls_path_line_to(path, x + width - radius, y);
    uls_path_bezier_to(path, x + width - radius + radius * kappa, y,
                        x + width, y + radius - radius * kappa,
                        x + width, y + radius);
    uls_path_line_to(path, x + width, y + height - radius);
    uls_path_bezier_to(path, x + width, y + height - radius + radius * kappa,
                        x + width - radius + radius * kappa, y + height,
                        x + width - radius, y + height);
    uls_path_line_to(path, x + radius, y + height);
    uls_path_bezier_to(path, x + radius - radius * kappa, y + height,
                        x, y + height - radius + radius * kappa,
                        x, y + height - radius);
    uls_path_line_to(path, x, y + radius);
    uls_path_bezier_to(path, x, y + radius - radius * kappa,
                        x + radius - radius * kappa, y,
                        x + radius, y);
    uls_path_close(path);
}

/* Create raster image */
ULSRasterImage* uls_raster_create(int width, int height, int bitsPerPixel) {
    ULSRasterImage *image = (ULSRasterImage *)calloc(1, sizeof(ULSRasterImage));
    if (!image) return NULL;

    image->width = width;
    image->height = height;
    image->bitsPerPixel = bitsPerPixel;
    image->dpi = 300.0f;
    image->power = 50;
    image->speed = 50;
    image->colorMode = ULS_COLOR_MODE_DITHER;

    int bytesPerRow = (width * bitsPerPixel + 7) / 8;
    image->data = (uint8_t *)calloc(bytesPerRow * height, 1);
    if (!image->data) {
        free(image);
        return NULL;
    }

    return image;
}

/* Destroy raster image */
void uls_raster_destroy(ULSRasterImage *image) {
    if (!image) return;
    if (image->data) free(image->data);
    free(image);
}

/* Set raster origin */
void uls_raster_set_origin(ULSRasterImage *image, float x, float y) {
    if (!image) return;
    image->originX = x;
    image->originY = y;
}

/* Set raster DPI */
void uls_raster_set_dpi(ULSRasterImage *image, float dpi) {
    if (!image) return;
    image->dpi = dpi;
}

/* Set raster laser parameters */
void uls_raster_set_laser(ULSRasterImage *image, uint8_t power, uint8_t speed) {
    if (!image) return;
    image->power = power > 100 ? 100 : power;
    image->speed = speed > 100 ? 100 : speed;
}

/* Set color mode */
void uls_raster_set_color_mode(ULSRasterImage *image, ULSColorMode mode) {
    if (!image) return;
    image->colorMode = mode;
}

/* Add raster to job */
void uls_job_add_raster(ULSJob *job, ULSRasterImage *image) {
    if (!job || !image) return;

    if (job->numRasterImages >= job->rasterImageCapacity) {
        job->rasterImageCapacity *= 2;
        job->rasterImages = (ULSRasterImage **)realloc(job->rasterImages,
                                                        job->rasterImageCapacity * sizeof(ULSRasterImage *));
    }

    job->rasterImages[job->numRasterImages++] = image;
    job->type = (job->numVectorPaths > 0) ? ULS_JOB_TYPE_COMBINED : ULS_JOB_TYPE_RASTER;
    job->isCompiled = false;

    /* Update bounds */
    float width = image->width / image->dpi;
    float height = image->height / image->dpi;

    if (image->originX < job->minX) job->minX = image->originX;
    if (image->originY < job->minY) job->minY = image->originY;
    if (image->originX + width > job->maxX) job->maxX = image->originX + width;
    if (image->originY + height > job->maxY) job->maxY = image->originY + height;
}

/* Helper to add command to compiled buffer */
static void add_command(uint8_t **buffer, size_t *size, size_t *capacity,
                        uint8_t cmd, const void *data, size_t dataLen) {
    size_t needed = 1 + dataLen;
    if (*size + needed > *capacity) {
        *capacity *= 2;
        *buffer = (uint8_t *)realloc(*buffer, *capacity);
    }

    (*buffer)[(*size)++] = cmd;
    if (data && dataLen > 0) {
        memcpy(*buffer + *size, data, dataLen);
        *size += dataLen;
    }
}

/* Helper to convert float to device units */
static int32_t float_to_units(float value) {
    return (int32_t)(value * 1000.0f);  /* 1000 DPI native resolution */
}

/* Compile job to device commands */
ULSError uls_job_compile(ULSJob *job) {
    if (!job) return ULS_ERROR_INVALID_PARAM;

    if (job->compiledData) {
        free(job->compiledData);
        job->compiledData = NULL;
    }

    size_t capacity = 4096;
    size_t size = 0;
    uint8_t *buffer = (uint8_t *)malloc(capacity);

    /* Job header */
    uint8_t header[16] = {0};
    header[0] = 'U';
    header[1] = 'L';
    header[2] = 'S';
    header[3] = 0x01;  /* Version */
    add_command(&buffer, &size, &capacity, CMD_HEADER, header, sizeof(header));

    /* Process vector paths */
    for (int i = 0; i < job->numVectorPaths; i++) {
        ULSVectorPath *path = job->vectorPaths[i];

        /* Set laser parameters */
        add_command(&buffer, &size, &capacity, CMD_SET_POWER, &path->power, 1);
        add_command(&buffer, &size, &capacity, CMD_SET_SPEED, &path->speed, 1);

        uint8_t ppiData[2] = {(path->ppi >> 8) & 0xFF, path->ppi & 0xFF};
        add_command(&buffer, &size, &capacity, CMD_SET_PPI, ppiData, 2);

        bool laserOn = false;

        for (int j = 0; j < path->numElements; j++) {
            ULSPathElement *el = &path->elements[j];
            int32_t coords[8];

            switch (el->op) {
                case ULS_PATH_OP_MOVE:
                    if (laserOn) {
                        add_command(&buffer, &size, &capacity, CMD_LASER_OFF, NULL, 0);
                        laserOn = false;
                    }
                    coords[0] = float_to_units(el->points[0].x);
                    coords[1] = float_to_units(el->points[0].y);
                    add_command(&buffer, &size, &capacity, CMD_MOVE_ABS, coords, 8);
                    break;

                case ULS_PATH_OP_LINE:
                    if (!laserOn) {
                        add_command(&buffer, &size, &capacity, CMD_LASER_ON, NULL, 0);
                        laserOn = true;
                    }
                    coords[0] = float_to_units(el->points[0].x);
                    coords[1] = float_to_units(el->points[0].y);
                    add_command(&buffer, &size, &capacity, CMD_LINE_ABS, coords, 8);
                    break;

                case ULS_PATH_OP_BEZIER:
                    if (!laserOn) {
                        add_command(&buffer, &size, &capacity, CMD_LASER_ON, NULL, 0);
                        laserOn = true;
                    }
                    coords[0] = float_to_units(el->points[0].x);
                    coords[1] = float_to_units(el->points[0].y);
                    coords[2] = float_to_units(el->points[1].x);
                    coords[3] = float_to_units(el->points[1].y);
                    coords[4] = float_to_units(el->points[2].x);
                    coords[5] = float_to_units(el->points[2].y);
                    add_command(&buffer, &size, &capacity, CMD_BEZIER_ABS, coords, 24);
                    break;

                case ULS_PATH_OP_CLOSE:
                    /* Line back to start if needed */
                    if (path->numElements > 0 && path->elements[0].op == ULS_PATH_OP_MOVE) {
                        coords[0] = float_to_units(path->elements[0].points[0].x);
                        coords[1] = float_to_units(path->elements[0].points[0].y);
                        add_command(&buffer, &size, &capacity, CMD_LINE_ABS, coords, 8);
                    }
                    add_command(&buffer, &size, &capacity, CMD_LASER_OFF, NULL, 0);
                    laserOn = false;
                    break;

                default:
                    break;
            }
        }

        if (laserOn) {
            add_command(&buffer, &size, &capacity, CMD_LASER_OFF, NULL, 0);
        }
    }

    /* Process raster images */
    for (int i = 0; i < job->numRasterImages; i++) {
        ULSRasterImage *image = job->rasterImages[i];

        add_command(&buffer, &size, &capacity, CMD_SET_POWER, &image->power, 1);
        add_command(&buffer, &size, &capacity, CMD_SET_SPEED, &image->speed, 1);

        /* Raster header */
        uint8_t rasterHeader[16];
        int32_t originX = float_to_units(image->originX);
        int32_t originY = float_to_units(image->originY);
        memcpy(rasterHeader, &originX, 4);
        memcpy(rasterHeader + 4, &originY, 4);
        memcpy(rasterHeader + 8, &image->width, 4);
        memcpy(rasterHeader + 12, &image->height, 4);
        add_command(&buffer, &size, &capacity, CMD_RASTER_START, rasterHeader, 16);

        /* Send raster lines */
        int bytesPerRow = (image->width * image->bitsPerPixel + 7) / 8;
        for (int y = 0; y < image->height; y++) {
            uint8_t *rowData = image->data + y * bytesPerRow;

            /* Line header with Y coordinate */
            int32_t lineY = float_to_units(image->originY + y / image->dpi);
            add_command(&buffer, &size, &capacity, CMD_RASTER_LINE, &lineY, 4);

            /* Ensure buffer has space for row data */
            if (size + bytesPerRow + 4 > capacity) {
                capacity = size + bytesPerRow + 4096;
                buffer = (uint8_t *)realloc(buffer, capacity);
            }

            /* Add row length and data */
            uint16_t rowLen = (uint16_t)bytesPerRow;
            memcpy(buffer + size, &rowLen, 2);
            size += 2;
            memcpy(buffer + size, rowData, bytesPerRow);
            size += bytesPerRow;
        }

        add_command(&buffer, &size, &capacity, CMD_RASTER_END, NULL, 0);
    }

    /* Job end marker */
    add_command(&buffer, &size, &capacity, CMD_JOB_END, NULL, 0);

    job->compiledData = buffer;
    job->compiledDataSize = size;
    job->isCompiled = true;

    return ULS_SUCCESS;
}

/* ============================================
 * Simulation Engine
 * ============================================ */

/* Compute time for trapezoidal velocity profile move */
static float motion_time(float distance, float maxVelocity, float accel) {
    if (distance <= 0 || maxVelocity <= 0) return 0;
    float t_accel = maxVelocity / accel;
    float d_accel = 0.5f * accel * t_accel * t_accel;

    if (2.0f * d_accel >= distance) {
        /* Triangle profile: can't reach max velocity */
        return 2.0f * sqrtf(distance / accel);
    } else {
        /* Trapezoidal profile */
        float d_cruise = distance - 2.0f * d_accel;
        return 2.0f * t_accel + d_cruise / maxVelocity;
    }
}

static float point_distance(float x1, float y1, float x2, float y2) {
    float dx = x2 - x1, dy = y2 - y1;
    return sqrtf(dx * dx + dy * dy);
}

/* Add point to simulation, growing buffer as needed */
static void sim_add_point(ULSSimulation *sim, float x, float y, float time, bool laserOn) {
    if (sim->numPoints >= sim->capacity) {
        sim->capacity *= 2;
        sim->points = (ULSSimPoint *)realloc(sim->points, sim->capacity * sizeof(ULSSimPoint));
    }
    ULSSimPoint *pt = &sim->points[sim->numPoints++];
    pt->x = x;
    pt->y = y;
    pt->time = time;
    pt->laserOn = laserOn;
}

/* Pending cut point for batched time computation */
typedef struct {
    float x, y;
    float distFromPrev;
} SimCutPoint;

/* Flush a batch of cutting points: compute total time and distribute proportionally */
static void sim_flush_cut_batch(ULSSimulation *sim, SimCutPoint *pts, int count,
                                 float totalDist, float cutSpeed, float *curTime) {
    if (count == 0 || totalDist <= 0) return;

    float totalTime = motion_time(totalDist, cutSpeed, ULS_SIM_ACCEL_IPS2);

    for (int i = 0; i < count; i++) {
        float fraction = pts[i].distFromPrev / totalDist;
        *curTime += totalTime * fraction;
        sim_add_point(sim, pts[i].x, pts[i].y, *curTime, true);
    }
}

/* Create simulation trace from a job */
ULSSimulation* uls_job_simulate(ULSJob *job) {
    if (!job) return NULL;

    ULSSimulation *sim = (ULSSimulation *)calloc(1, sizeof(ULSSimulation));
    if (!sim) return NULL;

    sim->capacity = 2048;
    sim->points = (ULSSimPoint *)malloc(sim->capacity * sizeof(ULSSimPoint));
    if (!sim->points) { free(sim); return NULL; }

    float curX = 0, curY = 0;
    float curTime = 0;

    /* Initial position (home) */
    sim_add_point(sim, 0, 0, 0, false);

    /* Temporary buffer for batched cutting points */
    int cutBatchCap = 256;
    SimCutPoint *cutBatch = (SimCutPoint *)malloc(cutBatchCap * sizeof(SimCutPoint));
    int cutBatchCount = 0;
    float cutBatchDist = 0;

#define FLUSH_CUT_BATCH() do { \
    if (cutBatchCount > 0) { \
        sim_flush_cut_batch(sim, cutBatch, cutBatchCount, cutBatchDist, cutSpeed, &curTime); \
        cutBatchCount = 0; \
        cutBatchDist = 0; \
    } \
} while(0)

#define ADD_CUT_POINT(px, py, dist) do { \
    if (cutBatchCount >= cutBatchCap) { \
        cutBatchCap *= 2; \
        cutBatch = (SimCutPoint *)realloc(cutBatch, cutBatchCap * sizeof(SimCutPoint)); \
    } \
    cutBatch[cutBatchCount].x = (px); \
    cutBatch[cutBatchCount].y = (py); \
    cutBatch[cutBatchCount].distFromPrev = (dist); \
    cutBatchCount++; \
    cutBatchDist += (dist); \
} while(0)

    /* Process vector paths */
    for (int p = 0; p < job->numVectorPaths; p++) {
        ULSVectorPath *path = job->vectorPaths[p];
        float cutSpeed = ULS_SIM_MAX_CUT_IPS * (path->speed / 100.0f);
        if (cutSpeed < 0.5f) cutSpeed = 0.5f;

        cutBatchCount = 0;
        cutBatchDist = 0;

        for (int e = 0; e < path->numElements; e++) {
            ULSPathElement *el = &path->elements[e];

            switch (el->op) {
                case ULS_PATH_OP_MOVE: {
                    /* Flush any pending cutting batch */
                    FLUSH_CUT_BATCH();

                    /* Rapid traverse (laser off) */
                    float dist = point_distance(curX, curY, el->points[0].x, el->points[0].y);
                    float dt = motion_time(dist, ULS_SIM_MAX_RAPID_IPS, ULS_SIM_ACCEL_IPS2);
                    curTime += dt;
                    curX = el->points[0].x;
                    curY = el->points[0].y;
                    sim_add_point(sim, curX, curY, curTime, false);
                    break;
                }

                case ULS_PATH_OP_LINE: {
                    float dist = point_distance(curX, curY, el->points[0].x, el->points[0].y);
                    ADD_CUT_POINT(el->points[0].x, el->points[0].y, dist);
                    curX = el->points[0].x;
                    curY = el->points[0].y;
                    break;
                }

                case ULS_PATH_OP_BEZIER: {
                    /* Subdivide cubic bezier into line segments */
                    float bx0 = curX, by0 = curY;
                    float bx1 = el->points[0].x, by1 = el->points[0].y;
                    float bx2 = el->points[1].x, by2 = el->points[1].y;
                    float bx3 = el->points[2].x, by3 = el->points[2].y;

                    for (int s = 1; s <= ULS_SIM_BEZIER_SUBDIV; s++) {
                        float t = (float)s / ULS_SIM_BEZIER_SUBDIV;
                        float mt = 1.0f - t;
                        float x = mt*mt*mt*bx0 + 3*mt*mt*t*bx1 + 3*mt*t*t*bx2 + t*t*t*bx3;
                        float y = mt*mt*mt*by0 + 3*mt*mt*t*by1 + 3*mt*t*t*by2 + t*t*t*by3;

                        float dist = point_distance(curX, curY, x, y);
                        ADD_CUT_POINT(x, y, dist);
                        curX = x;
                        curY = y;
                    }
                    break;
                }

                case ULS_PATH_OP_CLOSE: {
                    /* Close path: line back to the first MOVE in this path */
                    if (path->numElements > 0 && path->elements[0].op == ULS_PATH_OP_MOVE) {
                        float destX = path->elements[0].points[0].x;
                        float destY = path->elements[0].points[0].y;
                        float dist = point_distance(curX, curY, destX, destY);
                        ADD_CUT_POINT(destX, destY, dist);
                        curX = destX;
                        curY = destY;
                    }
                    break;
                }

                default:
                    break;
            }
        }

        /* Flush remaining cutting batch for this path */
        FLUSH_CUT_BATCH();
    }

    /* Process raster images (bidirectional scanning) */
    for (int i = 0; i < job->numRasterImages; i++) {
        ULSRasterImage *image = job->rasterImages[i];
        float rasterSpeed = ULS_SIM_MAX_CUT_IPS * (image->speed / 100.0f);
        if (rasterSpeed < 0.5f) rasterSpeed = 0.5f;

        float widthInches = image->width / image->dpi;
        float heightInches = image->height / image->dpi;
        int numLines = image->height;
        if (numLines < 1) numLines = 1;
        float lineSpacing = heightInches / numLines;

        for (int line = 0; line < numLines; line++) {
            float lineY = image->originY + line * lineSpacing;
            float startX, endX;

            /* Bidirectional: alternate scan direction */
            if (line % 2 == 0) {
                startX = image->originX;
                endX = image->originX + widthInches;
            } else {
                startX = image->originX + widthInches;
                endX = image->originX;
            }

            /* Rapid move to scan line start */
            float dist = point_distance(curX, curY, startX, lineY);
            float dt = motion_time(dist, ULS_SIM_MAX_RAPID_IPS, ULS_SIM_ACCEL_IPS2);
            curTime += dt;
            curX = startX;
            curY = lineY;
            sim_add_point(sim, curX, curY, curTime, false);

            /* Scan across (laser on) */
            dist = fabsf(endX - startX);
            dt = motion_time(dist, rasterSpeed, ULS_SIM_ACCEL_IPS2);
            curTime += dt;
            curX = endX;
            sim_add_point(sim, curX, curY, curTime, true);
        }
    }

#undef FLUSH_CUT_BATCH
#undef ADD_CUT_POINT

    free(cutBatch);
    sim->totalTime = curTime;
    return sim;
}

/* Destroy simulation */
void uls_simulation_destroy(ULSSimulation *sim) {
    if (!sim) return;
    if (sim->points) free(sim->points);
    free(sim);
}

/* Binary search: find index of last point with time <= target */
int uls_simulation_index_at_time(ULSSimulation *sim, float time) {
    if (!sim || sim->numPoints == 0) return 0;
    if (time <= 0) return 0;
    if (time >= sim->totalTime) return sim->numPoints - 1;

    int lo = 0, hi = sim->numPoints - 1;
    while (lo < hi) {
        int mid = (lo + hi + 1) / 2;
        if (sim->points[mid].time <= time) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    return lo;
}

/* Interpolate position at a given time */
void uls_simulation_get_position(ULSSimulation *sim, float time,
                                  float *x, float *y, bool *laserOn) {
    if (!sim || sim->numPoints == 0) {
        if (x) *x = 0;
        if (y) *y = 0;
        if (laserOn) *laserOn = false;
        return;
    }

    int idx = uls_simulation_index_at_time(sim, time);

    if (idx >= sim->numPoints - 1) {
        /* At or past end */
        ULSSimPoint *pt = &sim->points[sim->numPoints - 1];
        if (x) *x = pt->x;
        if (y) *y = pt->y;
        if (laserOn) *laserOn = pt->laserOn;
        return;
    }

    /* Interpolate between idx and idx+1 */
    ULSSimPoint *a = &sim->points[idx];
    ULSSimPoint *b = &sim->points[idx + 1];
    float dt = b->time - a->time;
    float frac = (dt > 0) ? (time - a->time) / dt : 0;

    if (x) *x = a->x + (b->x - a->x) * frac;
    if (y) *y = a->y + (b->y - a->y) * frac;
    if (laserOn) *laserOn = b->laserOn;
}

/* Get job bounds */
ULSError uls_job_get_bounds(ULSJob *job, float *minX, float *minY, float *maxX, float *maxY) {
    if (!job) return ULS_ERROR_INVALID_PARAM;

    if (minX) *minX = job->minX;
    if (minY) *minY = job->minY;
    if (maxX) *maxX = job->maxX;
    if (maxY) *maxY = job->maxY;

    return ULS_SUCCESS;
}

/* Estimate job time using simulation */
ULSError uls_job_get_estimated_time(ULSJob *job, float *seconds) {
    if (!job || !seconds) return ULS_ERROR_INVALID_PARAM;

    ULSSimulation *sim = uls_job_simulate(job);
    if (!sim) {
        *seconds = 0;
        return ULS_ERROR_UNKNOWN;
    }

    *seconds = sim->totalTime;
    uls_simulation_destroy(sim);

    return ULS_SUCCESS;
}

/* Send job to device */
ULSError uls_job_send(ULSJob *job, ULSDevice *device) {
    if (!job || !device) return ULS_ERROR_INVALID_PARAM;

    if (!job->isCompiled) {
        ULSError err = uls_job_compile(job);
        if (err != ULS_SUCCESS) return err;
    }

    return uls_send_job_data(device, job->compiledData, job->compiledDataSize);
}

/* Send and run job */
ULSError uls_job_run(ULSJob *job, ULSDevice *device) {
    ULSError err = uls_job_send(job, device);
    if (err != ULS_SUCCESS) return err;

    return uls_start_job(device);
}

/* Material presets */
void uls_get_material_settings(ULSMaterialType material, ULSModelType model, ULSLaserSettings *settings) {
    if (!settings) return;

    /* Default values */
    settings->power = 50;
    settings->speed = 50;
    settings->ppi = 500;
    settings->focusOffset = 0.0f;
    settings->airAssist = true;
    settings->material = material;

    /* Material-specific defaults (approximate, should be calibrated per machine) */
    switch (material) {
        case ULS_MATERIAL_ACRYLIC:
            settings->power = 80;
            settings->speed = 20;
            settings->ppi = 500;
            break;

        case ULS_MATERIAL_WOOD:
            settings->power = 60;
            settings->speed = 40;
            settings->ppi = 500;
            break;

        case ULS_MATERIAL_PAPER:
            settings->power = 20;
            settings->speed = 80;
            settings->ppi = 300;
            break;

        case ULS_MATERIAL_LEATHER:
            settings->power = 40;
            settings->speed = 50;
            settings->ppi = 500;
            break;

        case ULS_MATERIAL_FABRIC:
            settings->power = 30;
            settings->speed = 60;
            settings->ppi = 300;
            break;

        case ULS_MATERIAL_RUBBER:
            settings->power = 70;
            settings->speed = 30;
            settings->ppi = 500;
            break;

        case ULS_MATERIAL_GLASS:
            settings->power = 90;
            settings->speed = 10;
            settings->ppi = 500;
            settings->airAssist = false;
            break;

        case ULS_MATERIAL_METAL_MARKING:
            settings->power = 95;
            settings->speed = 10;
            settings->ppi = 1000;
            break;

        case ULS_MATERIAL_STONE:
            settings->power = 85;
            settings->speed = 15;
            settings->ppi = 500;
            break;

        default:
            break;
    }
}

/* Set progress callback */
void uls_job_set_progress_callback(ULSJob *job, ULSJobProgressCallback callback, void *userContext) {
    if (!job) return;
    job->progressCallback = callback;
    job->progressUserContext = userContext;
}

/* Load raster from file (BMP support) */
ULSRasterImage* uls_raster_load_from_file(const char *filepath) {
    if (!filepath) return NULL;

    FILE *fp = fopen(filepath, "rb");
    if (!fp) return NULL;

    /* Read entire file into memory */
    fseek(fp, 0, SEEK_END);
    long fileSize = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (fileSize <= 0 || fileSize > 100 * 1024 * 1024) {
        fclose(fp);
        return NULL;  /* File too large or empty */
    }

    uint8_t *fileData = (uint8_t *)malloc(fileSize);
    if (!fileData) {
        fclose(fp);
        return NULL;
    }

    if ((long)fread(fileData, 1, fileSize, fp) != fileSize) {
        free(fileData);
        fclose(fp);
        return NULL;
    }
    fclose(fp);

    ULSRasterImage *image = uls_raster_load_from_memory(fileData, fileSize);
    free(fileData);
    return image;
}

/* Load raster from memory (BMP format) */
ULSRasterImage* uls_raster_load_from_memory(const uint8_t *data, size_t dataSize) {
    if (!data || dataSize < 54) return NULL;

    /* Check BMP signature */
    if (data[0] != 'B' || data[1] != 'M') return NULL;

    /* Parse BMP header */
    uint32_t dataOffset = *(uint32_t *)(data + 10);
    int32_t width = *(int32_t *)(data + 18);
    int32_t height = *(int32_t *)(data + 22);
    uint16_t bitsPerPixel = *(uint16_t *)(data + 28);
    uint32_t compression = *(uint32_t *)(data + 30);

    if (width <= 0 || width > 65536) return NULL;
    if (height == 0 || abs(height) > 65536) return NULL;
    if (compression != 0) return NULL;  /* Only uncompressed BMP */

    /* Support 1, 8, and 24 bit BMP */
    int outputBpp;
    if (bitsPerPixel == 1) {
        outputBpp = 1;
    } else if (bitsPerPixel == 8) {
        outputBpp = 8;
    } else if (bitsPerPixel == 24 || bitsPerPixel == 32) {
        outputBpp = 8;  /* Convert to grayscale */
    } else {
        return NULL;
    }

    bool topDown = (height < 0);
    int absHeight = abs(height);

    ULSRasterImage *image = uls_raster_create(width, absHeight, outputBpp);
    if (!image) return NULL;

    int srcRowBytes = ((width * bitsPerPixel + 31) / 32) * 4;  /* BMP rows are 4-byte aligned */
    int dstRowBytes = (width * outputBpp + 7) / 8;

    for (int y = 0; y < absHeight; y++) {
        int srcRow = topDown ? y : (absHeight - 1 - y);
        const uint8_t *srcLine = data + dataOffset + srcRow * srcRowBytes;
        uint8_t *dstLine = image->data + y * dstRowBytes;

        if (dataOffset + srcRow * srcRowBytes + srcRowBytes > dataSize) break;

        if (bitsPerPixel == 1) {
            memcpy(dstLine, srcLine, dstRowBytes);
        } else if (bitsPerPixel == 8) {
            memcpy(dstLine, srcLine, width);
        } else if (bitsPerPixel == 24) {
            /* Convert BGR to grayscale */
            for (int x = 0; x < width; x++) {
                uint8_t b = srcLine[x * 3];
                uint8_t g = srcLine[x * 3 + 1];
                uint8_t r = srcLine[x * 3 + 2];
                dstLine[x] = (uint8_t)(0.299f * r + 0.587f * g + 0.114f * b);
            }
        } else if (bitsPerPixel == 32) {
            /* Convert BGRA to grayscale */
            for (int x = 0; x < width; x++) {
                uint8_t b = srcLine[x * 4];
                uint8_t g = srcLine[x * 4 + 1];
                uint8_t r = srcLine[x * 4 + 2];
                dstLine[x] = (uint8_t)(0.299f * r + 0.587f * g + 0.114f * b);
            }
        }
    }

    return image;
}

/* SVG import (C-level stub - GUI uses ULSSVGParser.m directly) */
ULSError uls_job_import_svg(ULSJob *job, const char *filepath) {
    if (!job || !filepath) return ULS_ERROR_INVALID_PARAM;

    /* The macOS GUI uses ULSSVGParser (Objective-C NSXMLParser) for full SVG import.
     * This C function creates a placeholder for CLI/test usage. */
    (void)filepath;

    ULSVectorPath *path = uls_path_create();
    if (!path) return ULS_ERROR_UNKNOWN;

    uls_path_set_laser(path, job->settings.power, job->settings.speed, job->settings.ppi);
    uls_path_add_rectangle(path, 0.5f, 0.5f, 3.0f, 2.0f);
    uls_job_add_path(job, path);

    return ULS_SUCCESS;
}

/* PDF import (not yet implemented - requires Quartz/PDFKit in Objective-C) */
ULSError uls_job_import_pdf(ULSJob *job, const char *filepath, int pageNumber) {
    if (!job || !filepath) return ULS_ERROR_INVALID_PARAM;
    (void)filepath;
    (void)pageNumber;

    /* PDF import requires Objective-C frameworks (Quartz/PDFKit).
     * Not available from pure C code. Use the GUI import path. */
    return ULS_ERROR_INVALID_PARAM;
}

/* ============================================
 * Printer Settings API (8-color pen mapping)
 * ============================================ */

/* Create default printer settings */
ULSPrinterSettings* uls_printer_settings_create(void) {
    ULSPrinterSettings *settings = (ULSPrinterSettings *)calloc(1, sizeof(ULSPrinterSettings));
    if (settings) {
        uls_printer_settings_reset(settings);
    }
    return settings;
}

/* Destroy printer settings */
void uls_printer_settings_destroy(ULSPrinterSettings *settings) {
    if (settings) free(settings);
}

/* Initialize settings with defaults */
void uls_printer_settings_reset(ULSPrinterSettings *settings) {
    if (!settings) return;

    memset(settings, 0, sizeof(ULSPrinterSettings));

    /* Initialize all 8 pen colors with defaults */
    for (int i = 0; i < ULS_PEN_COLOR_COUNT; i++) {
        settings->pens[i].mode = ULS_PEN_MODE_RAST_VECT;
        settings->pens[i].power = ULS_DEFAULT_POWER;
        settings->pens[i].speed = ULS_DEFAULT_SPEED;
        settings->pens[i].ppi = ULS_DEFAULT_PPI;
        settings->pens[i].gasAssist = true;
    }

    /* Global settings */
    settings->printMode = ULS_PRINT_MODE_NORMAL;
    settings->imageDensity = ULS_IMAGE_DENSITY_6;
    settings->gasAssistMode = ULS_GAS_ASSIST_AUTO;
    settings->material = ULS_MATERIAL_CUSTOM;
    settings->materialThickness = 0.125f;  /* 1/8 inch default */
    settings->focusOffset = 0.0f;
    settings->dualBeam = false;
    settings->lensType = 1;  /* 2.0" lens default */
    settings->pageWidth = 24.0f;
    settings->pageHeight = 12.0f;

    strncpy(settings->presetName, "Default", sizeof(settings->presetName) - 1);
}

/* Copy settings */
void uls_printer_settings_copy(ULSPrinterSettings *dest, const ULSPrinterSettings *src) {
    if (!dest || !src) return;
    memcpy(dest, src, sizeof(ULSPrinterSettings));
}

/* Per-pen configuration */
void uls_pen_set_mode(ULSPrinterSettings *settings, ULSPenColor color, ULSPenMode mode) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return;
    settings->pens[color].mode = mode;
}

void uls_pen_set_power(ULSPrinterSettings *settings, ULSPenColor color, uint8_t power) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return;
    settings->pens[color].power = power > 100 ? 100 : power;
}

void uls_pen_set_speed(ULSPrinterSettings *settings, ULSPenColor color, uint8_t speed) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return;
    settings->pens[color].speed = speed > 100 ? 100 : speed;
}

void uls_pen_set_ppi(ULSPrinterSettings *settings, ULSPenColor color, uint16_t ppi) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return;
    if (ppi < 1) ppi = 1;
    if (ppi > 1000) ppi = 1000;
    settings->pens[color].ppi = ppi;
}

void uls_pen_set_gas_assist(ULSPrinterSettings *settings, ULSPenColor color, bool enabled) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return;
    settings->pens[color].gasAssist = enabled;
}

void uls_pen_set_all(ULSPrinterSettings *settings, ULSPenColor color,
                     ULSPenMode mode, uint8_t power, uint8_t speed, uint16_t ppi, bool gasAssist) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return;
    settings->pens[color].mode = mode;
    settings->pens[color].power = power > 100 ? 100 : power;
    settings->pens[color].speed = speed > 100 ? 100 : speed;
    settings->pens[color].ppi = (ppi < 1) ? 1 : (ppi > 1000 ? 1000 : ppi);
    settings->pens[color].gasAssist = gasAssist;
}

/* Get pen settings */
ULSPenMode uls_pen_get_mode(const ULSPrinterSettings *settings, ULSPenColor color) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return ULS_PEN_MODE_RAST_VECT;
    return settings->pens[color].mode;
}

uint8_t uls_pen_get_power(const ULSPrinterSettings *settings, ULSPenColor color) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return ULS_DEFAULT_POWER;
    return settings->pens[color].power;
}

uint8_t uls_pen_get_speed(const ULSPrinterSettings *settings, ULSPenColor color) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return ULS_DEFAULT_SPEED;
    return settings->pens[color].speed;
}

uint16_t uls_pen_get_ppi(const ULSPrinterSettings *settings, ULSPenColor color) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return ULS_DEFAULT_PPI;
    return settings->pens[color].ppi;
}

bool uls_pen_get_gas_assist(const ULSPrinterSettings *settings, ULSPenColor color) {
    if (!settings || color >= ULS_PEN_COLOR_COUNT) return true;
    return settings->pens[color].gasAssist;
}

/* String constants */
const char* uls_pen_color_string(ULSPenColor color) {
    static const char *names[] = {
        "Black", "Red", "Green", "Yellow",
        "Blue", "Magenta", "Cyan", "Orange"
    };
    if (color < ULS_PEN_COLOR_COUNT) return names[color];
    return "Unknown";
}

const char* uls_pen_mode_string(ULSPenMode mode) {
    switch (mode) {
        case ULS_PEN_MODE_RAST_VECT: return "RAST/VECT";
        case ULS_PEN_MODE_RAST:      return "RAST";
        case ULS_PEN_MODE_VECT:      return "VECT";
        case ULS_PEN_MODE_SKIP:      return "SKIP";
        default:                     return "Unknown";
    }
}

const char* uls_print_mode_string(ULSPrintMode mode) {
    switch (mode) {
        case ULS_PRINT_MODE_NORMAL:       return "Normal";
        case ULS_PRINT_MODE_CLIPART:      return "Clipart";
        case ULS_PRINT_MODE_3D:           return "3D";
        case ULS_PRINT_MODE_RUBBER_STAMP: return "Rubber Stamp";
        default:                          return "Unknown";
    }
}

/* Color matching - find closest pen color for RGB */
ULSPenColor uls_match_color_to_pen(uint8_t r, uint8_t g, uint8_t b) {
    /* RGB values for the 8 standard pen colors */
    static const struct {
        uint8_t r, g, b;
    } pen_colors[ULS_PEN_COLOR_COUNT] = {
        {0, 0, 0},       /* Black */
        {255, 0, 0},     /* Red */
        {0, 255, 0},     /* Green */
        {255, 255, 0},   /* Yellow */
        {0, 0, 255},     /* Blue */
        {255, 0, 255},   /* Magenta */
        {0, 255, 255},   /* Cyan */
        {255, 128, 0}    /* Orange */
    };

    int minDist = INT32_MAX;
    ULSPenColor closest = ULS_PEN_COLOR_BLACK;

    for (int i = 0; i < ULS_PEN_COLOR_COUNT; i++) {
        int dr = (int)r - pen_colors[i].r;
        int dg = (int)g - pen_colors[i].g;
        int db = (int)b - pen_colors[i].b;
        int dist = dr * dr + dg * dg + db * db;

        if (dist < minDist) {
            minDist = dist;
            closest = (ULSPenColor)i;
        }
    }

    return closest;
}

/* .LAS file format header */
#define LAS_FILE_MAGIC 0x5341554C  /* "LUAS" in little-endian */
#define LAS_FILE_VERSION 1

/* Save settings to .LAS file */
ULSError uls_printer_settings_save(const ULSPrinterSettings *settings, const char *filepath) {
    if (!settings || !filepath) return ULS_ERROR_INVALID_PARAM;

    FILE *fp = fopen(filepath, "wb");
    if (!fp) return ULS_ERROR_IO;

    /* Write header */
    uint32_t magic = LAS_FILE_MAGIC;
    uint32_t version = LAS_FILE_VERSION;
    fwrite(&magic, sizeof(uint32_t), 1, fp);
    fwrite(&version, sizeof(uint32_t), 1, fp);

    /* Write settings structure */
    fwrite(settings, sizeof(ULSPrinterSettings), 1, fp);

    fclose(fp);
    return ULS_SUCCESS;
}

/* Load settings from .LAS file */
ULSError uls_printer_settings_load(ULSPrinterSettings *settings, const char *filepath) {
    if (!settings || !filepath) return ULS_ERROR_INVALID_PARAM;

    FILE *fp = fopen(filepath, "rb");
    if (!fp) return ULS_ERROR_IO;

    /* Verify header */
    uint32_t magic, version;
    if (fread(&magic, sizeof(uint32_t), 1, fp) != 1 ||
        fread(&version, sizeof(uint32_t), 1, fp) != 1) {
        fclose(fp);
        return ULS_ERROR_IO;
    }

    if (magic != LAS_FILE_MAGIC) {
        fclose(fp);
        return ULS_ERROR_INVALID_PARAM;  /* Not a valid .LAS file */
    }

    if (version > LAS_FILE_VERSION) {
        fclose(fp);
        return ULS_ERROR_INVALID_PARAM;  /* Newer version */
    }

    /* Read settings */
    if (fread(settings, sizeof(ULSPrinterSettings), 1, fp) != 1) {
        fclose(fp);
        return ULS_ERROR_IO;
    }

    fclose(fp);
    return ULS_SUCCESS;
}

/* Apply material preset to all pens */
void uls_printer_settings_apply_material(ULSPrinterSettings *settings,
                                          ULSMaterialType material, ULSModelType model) {
    if (!settings) return;

    ULSLaserSettings matSettings;
    uls_get_material_settings(material, model, &matSettings);

    /* Apply to all pens (typically, material settings affect all colors) */
    for (int i = 0; i < ULS_PEN_COLOR_COUNT; i++) {
        settings->pens[i].power = matSettings.power;
        settings->pens[i].speed = matSettings.speed;
        settings->pens[i].ppi = matSettings.ppi;
        settings->pens[i].gasAssist = matSettings.airAssist;
    }

    settings->material = material;
    settings->focusOffset = matSettings.focusOffset;
}

/* Apply printer settings to a job */
void uls_job_apply_printer_settings(ULSJob *job, const ULSPrinterSettings *settings) {
    if (!job || !settings) return;

    /* Copy base settings from black pen (default for most operations) */
    job->settings.power = settings->pens[ULS_PEN_COLOR_BLACK].power;
    job->settings.speed = settings->pens[ULS_PEN_COLOR_BLACK].speed;
    job->settings.ppi = settings->pens[ULS_PEN_COLOR_BLACK].ppi;
    job->settings.airAssist = settings->pens[ULS_PEN_COLOR_BLACK].gasAssist;
    job->settings.focusOffset = settings->focusOffset;
    job->settings.material = settings->material;
}
