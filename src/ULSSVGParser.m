/*
 * ULS SVG Parser Implementation
 * Parses SVG files into ULSJob vector paths using NSXMLParser
 *
 * Supports: path, rect, circle, ellipse, line, polyline, polygon
 * SVG path commands: M, L, H, V, C, S, Q, T, A, Z (absolute and relative)
 */

#import "ULSSVGParser.h"
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Default SVG DPI (CSS pixels per inch)
#define SVG_DEFAULT_DPI 96.0f

@interface ULSSVGParser ()
@property (assign) ULSJob *job;
@property (assign) float scaleX;
@property (assign) float scaleY;
@property (assign) float offsetX;
@property (assign) float offsetY;
@property (assign) float viewBoxHeight;
@end

@implementation ULSSVGParser

+ (ULSError)parseFile:(NSString *)filepath intoJob:(ULSJob *)job {
    if (!filepath || !job) return ULS_ERROR_INVALID_PARAM;

    NSData *data = [NSData dataWithContentsOfFile:filepath];
    if (!data) return ULS_ERROR_IO;

    ULSSVGParser *parser = [[ULSSVGParser alloc] init];
    parser.job = job;
    parser.scaleX = 1.0f / SVG_DEFAULT_DPI;
    parser.scaleY = 1.0f / SVG_DEFAULT_DPI;
    parser.offsetX = 0;
    parser.offsetY = 0;
    parser.viewBoxHeight = 0;

    NSXMLParser *xmlParser = [[NSXMLParser alloc] initWithData:data];
    xmlParser.delegate = parser;
    [xmlParser parse];

    return ULS_SUCCESS;
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
    attributes:(NSDictionary<NSString *, NSString *> *)attrs {

    if ([elementName isEqualToString:@"svg"]) {
        [self parseSVGElement:attrs];
    } else if ([elementName isEqualToString:@"path"]) {
        [self parsePathElement:attrs];
    } else if ([elementName isEqualToString:@"rect"]) {
        [self parseRectElement:attrs];
    } else if ([elementName isEqualToString:@"circle"]) {
        [self parseCircleElement:attrs];
    } else if ([elementName isEqualToString:@"ellipse"]) {
        [self parseEllipseElement:attrs];
    } else if ([elementName isEqualToString:@"line"]) {
        [self parseLineElement:attrs];
    } else if ([elementName isEqualToString:@"polyline"]) {
        [self parsePolylineElement:attrs closed:NO];
    } else if ([elementName isEqualToString:@"polygon"]) {
        [self parsePolylineElement:attrs closed:YES];
    }
}

#pragma mark - SVG Root

- (void)parseSVGElement:(NSDictionary *)attrs {
    // Parse viewBox for coordinate mapping
    NSString *viewBox = attrs[@"viewBox"];
    float vbWidth = 0, vbHeight = 0;

    if (viewBox) {
        NSArray *parts = [viewBox componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@" ,"]];
        NSMutableArray *nums = [NSMutableArray array];
        for (NSString *p in parts) {
            if (p.length > 0) [nums addObject:p];
        }
        if (nums.count >= 4) {
            self.offsetX = -[nums[0] floatValue];
            self.offsetY = -[nums[1] floatValue];
            vbWidth = [nums[2] floatValue];
            vbHeight = [nums[3] floatValue];
        }
    }

    // Parse width/height for unit conversion
    NSString *widthStr = attrs[@"width"];
    NSString *heightStr = attrs[@"height"];
    float docWidth = 0, docHeight = 0;

    if (widthStr) docWidth = [self parseLength:widthStr];
    if (heightStr) docHeight = [self parseLength:heightStr];

    // Calculate scale: SVG units -> inches
    if (vbWidth > 0 && vbHeight > 0 && docWidth > 0 && docHeight > 0) {
        self.scaleX = docWidth / vbWidth;
        self.scaleY = docHeight / vbHeight;
        self.viewBoxHeight = vbHeight;
    } else if (docWidth > 0 && docHeight > 0) {
        // Width/height with units, no viewBox
        if (vbWidth <= 0) vbWidth = docWidth * SVG_DEFAULT_DPI;
        if (vbHeight <= 0) vbHeight = docHeight * SVG_DEFAULT_DPI;
        self.scaleX = docWidth / vbWidth;
        self.scaleY = docHeight / vbHeight;
        self.viewBoxHeight = vbHeight;
    } else {
        // default 1/96 (CSS px to inches)
        self.viewBoxHeight = docHeight > 0 ? docHeight * SVG_DEFAULT_DPI : 0;
    }
}

// Parse SVG length value with units to inches
- (float)parseLength:(NSString *)str {
    if (!str || str.length == 0) return 0;

    float value = str.floatValue;
    NSString *lower = str.lowercaseString;

    if ([lower hasSuffix:@"mm"]) {
        return value / 25.4f;
    } else if ([lower hasSuffix:@"cm"]) {
        return value / 2.54f;
    } else if ([lower hasSuffix:@"in"]) {
        return value;
    } else if ([lower hasSuffix:@"pt"]) {
        return value / 72.0f;
    } else if ([lower hasSuffix:@"pc"]) {
        return value / 6.0f;
    } else if ([lower hasSuffix:@"px"]) {
        return value / SVG_DEFAULT_DPI;
    } else {
        // No unit = CSS px
        return value / SVG_DEFAULT_DPI;
    }
}

- (float)tx:(float)x { return (x + self.offsetX) * self.scaleX; }
- (float)ty:(float)y {
    // Flip Y axis: SVG Y-down to conventional Y-up orientation
    if (self.viewBoxHeight > 0) {
        return (self.viewBoxHeight - (y + self.offsetY)) * self.scaleY;
    }
    return (y + self.offsetY) * self.scaleY;
}

#pragma mark - Shape Elements

- (void)parseRectElement:(NSDictionary *)attrs {
    float x = [attrs[@"x"] floatValue];
    float y = [attrs[@"y"] floatValue];
    float w = [attrs[@"width"] floatValue];
    float h = [attrs[@"height"] floatValue];

    if (w <= 0 || h <= 0) return;

    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, self.job->settings.power, self.job->settings.speed, self.job->settings.ppi);
    uls_path_add_rectangle(path, [self tx:x], [self ty:y],
                           w * self.scaleX, h * self.scaleY);
    uls_job_add_path(self.job, path);
}

- (void)parseCircleElement:(NSDictionary *)attrs {
    float cx = [attrs[@"cx"] floatValue];
    float cy = [attrs[@"cy"] floatValue];
    float r = [attrs[@"r"] floatValue];

    if (r <= 0) return;

    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, self.job->settings.power, self.job->settings.speed, self.job->settings.ppi);

    // Use average scale for radius
    float avgScale = (self.scaleX + self.scaleY) / 2.0f;
    uls_path_add_circle(path, [self tx:cx], [self ty:cy], r * avgScale);
    uls_job_add_path(self.job, path);
}

- (void)parseEllipseElement:(NSDictionary *)attrs {
    float cx = [attrs[@"cx"] floatValue];
    float cy = [attrs[@"cy"] floatValue];
    float rx = [attrs[@"rx"] floatValue];
    float ry = [attrs[@"ry"] floatValue];

    if (rx <= 0 || ry <= 0) return;

    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, self.job->settings.power, self.job->settings.speed, self.job->settings.ppi);
    uls_path_add_ellipse(path, [self tx:cx], [self ty:cy],
                         rx * self.scaleX, ry * self.scaleY);
    uls_job_add_path(self.job, path);
}

- (void)parseLineElement:(NSDictionary *)attrs {
    float x1 = [attrs[@"x1"] floatValue];
    float y1 = [attrs[@"y1"] floatValue];
    float x2 = [attrs[@"x2"] floatValue];
    float y2 = [attrs[@"y2"] floatValue];

    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, self.job->settings.power, self.job->settings.speed, self.job->settings.ppi);
    uls_path_move_to(path, [self tx:x1], [self ty:y1]);
    uls_path_line_to(path, [self tx:x2], [self ty:y2]);
    uls_job_add_path(self.job, path);
}

- (void)parsePolylineElement:(NSDictionary *)attrs closed:(BOOL)closed {
    NSString *pointsStr = attrs[@"points"];
    if (!pointsStr) return;

    NSArray *tokens = [pointsStr componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@" ,\t\n\r"]];
    NSMutableArray *nums = [NSMutableArray array];
    for (NSString *t in tokens) {
        if (t.length > 0) [nums addObject:@(t.floatValue)];
    }

    if (nums.count < 4) return;

    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, self.job->settings.power, self.job->settings.speed, self.job->settings.ppi);

    for (NSUInteger i = 0; i + 1 < nums.count; i += 2) {
        float x = [nums[i] floatValue];
        float y = [nums[i + 1] floatValue];
        if (i == 0) {
            uls_path_move_to(path, [self tx:x], [self ty:y]);
        } else {
            uls_path_line_to(path, [self tx:x], [self ty:y]);
        }
    }

    if (closed) {
        uls_path_close(path);
    }
    uls_job_add_path(self.job, path);
}

#pragma mark - Path Element (d attribute)

- (void)parsePathElement:(NSDictionary *)attrs {
    NSString *d = attrs[@"d"];
    if (!d || d.length == 0) return;

    ULSVectorPath *path = uls_path_create();
    uls_path_set_laser(path, self.job->settings.power, self.job->settings.speed, self.job->settings.ppi);

    [self parseSVGPathData:d intoPath:path];

    if (path->numElements > 0) {
        uls_job_add_path(self.job, path);
    } else {
        uls_path_destroy(path);
    }
}

- (void)parseSVGPathData:(NSString *)d intoPath:(ULSVectorPath *)path {
    const char *s = [d UTF8String];
    int len = (int)strlen(s);
    int pos = 0;

    float curX = 0, curY = 0;       // Current point
    float startX = 0, startY = 0;   // Start of current subpath
    float lastCpX = 0, lastCpY = 0; // Last control point (for S/T)
    char lastCmd = 0;

    while (pos < len) {
        // Skip whitespace and commas
        while (pos < len && (s[pos] == ' ' || s[pos] == ',' || s[pos] == '\t' || s[pos] == '\n' || s[pos] == '\r'))
            pos++;
        if (pos >= len) break;

        char cmd = 0;
        if ((s[pos] >= 'A' && s[pos] <= 'Z') || (s[pos] >= 'a' && s[pos] <= 'z')) {
            cmd = s[pos++];
        } else {
            // Implicit repeat of last command
            cmd = lastCmd;
            // M becomes L after first coordinate pair
            if (cmd == 'M') cmd = 'L';
            if (cmd == 'm') cmd = 'l';
        }

        BOOL relative = (cmd >= 'a' && cmd <= 'z');

        switch (cmd) {
            case 'M': case 'm': {
                float x = [self readFloat:s pos:&pos len:len];
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) { x += curX; y += curY; }
                curX = x; curY = y;
                startX = x; startY = y;
                uls_path_move_to(path, [self tx:x], [self ty:y]);
                break;
            }
            case 'L': case 'l': {
                float x = [self readFloat:s pos:&pos len:len];
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) { x += curX; y += curY; }
                curX = x; curY = y;
                uls_path_line_to(path, [self tx:x], [self ty:y]);
                break;
            }
            case 'H': case 'h': {
                float x = [self readFloat:s pos:&pos len:len];
                if (relative) x += curX;
                curX = x;
                uls_path_line_to(path, [self tx:curX], [self ty:curY]);
                break;
            }
            case 'V': case 'v': {
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) y += curY;
                curY = y;
                uls_path_line_to(path, [self tx:curX], [self ty:curY]);
                break;
            }
            case 'C': case 'c': {
                float cp1x = [self readFloat:s pos:&pos len:len];
                float cp1y = [self readFloat:s pos:&pos len:len];
                float cp2x = [self readFloat:s pos:&pos len:len];
                float cp2y = [self readFloat:s pos:&pos len:len];
                float x = [self readFloat:s pos:&pos len:len];
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) {
                    cp1x += curX; cp1y += curY;
                    cp2x += curX; cp2y += curY;
                    x += curX; y += curY;
                }
                uls_path_bezier_to(path, [self tx:cp1x], [self ty:cp1y],
                                         [self tx:cp2x], [self ty:cp2y],
                                         [self tx:x], [self ty:y]);
                lastCpX = cp2x; lastCpY = cp2y;
                curX = x; curY = y;
                break;
            }
            case 'S': case 's': {
                // Smooth cubic: reflect last control point
                float cp1x = 2 * curX - lastCpX;
                float cp1y = 2 * curY - lastCpY;
                float cp2x = [self readFloat:s pos:&pos len:len];
                float cp2y = [self readFloat:s pos:&pos len:len];
                float x = [self readFloat:s pos:&pos len:len];
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) {
                    cp2x += curX; cp2y += curY;
                    x += curX; y += curY;
                }
                uls_path_bezier_to(path, [self tx:cp1x], [self ty:cp1y],
                                         [self tx:cp2x], [self ty:cp2y],
                                         [self tx:x], [self ty:y]);
                lastCpX = cp2x; lastCpY = cp2y;
                curX = x; curY = y;
                break;
            }
            case 'Q': case 'q': {
                // Quadratic bezier - convert to cubic
                float qx = [self readFloat:s pos:&pos len:len];
                float qy = [self readFloat:s pos:&pos len:len];
                float x = [self readFloat:s pos:&pos len:len];
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) {
                    qx += curX; qy += curY;
                    x += curX; y += curY;
                }
                // Convert quadratic to cubic control points
                float cp1x = curX + 2.0f/3.0f * (qx - curX);
                float cp1y = curY + 2.0f/3.0f * (qy - curY);
                float cp2x = x + 2.0f/3.0f * (qx - x);
                float cp2y = y + 2.0f/3.0f * (qy - y);
                uls_path_bezier_to(path, [self tx:cp1x], [self ty:cp1y],
                                         [self tx:cp2x], [self ty:cp2y],
                                         [self tx:x], [self ty:y]);
                lastCpX = qx; lastCpY = qy;
                curX = x; curY = y;
                break;
            }
            case 'T': case 't': {
                // Smooth quadratic
                float qx = 2 * curX - lastCpX;
                float qy = 2 * curY - lastCpY;
                float x = [self readFloat:s pos:&pos len:len];
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) { x += curX; y += curY; }
                float cp1x = curX + 2.0f/3.0f * (qx - curX);
                float cp1y = curY + 2.0f/3.0f * (qy - curY);
                float cp2x = x + 2.0f/3.0f * (qx - x);
                float cp2y = y + 2.0f/3.0f * (qy - y);
                uls_path_bezier_to(path, [self tx:cp1x], [self ty:cp1y],
                                         [self tx:cp2x], [self ty:cp2y],
                                         [self tx:x], [self ty:y]);
                lastCpX = qx; lastCpY = qy;
                curX = x; curY = y;
                break;
            }
            case 'A': case 'a': {
                // Arc - simplified: convert to line segments
                float rx = [self readFloat:s pos:&pos len:len];
                float ry = [self readFloat:s pos:&pos len:len];
                [self readFloat:s pos:&pos len:len]; // x-rotation (unused)
                float largeArc = [self readFloat:s pos:&pos len:len];
                float sweep = [self readFloat:s pos:&pos len:len];
                float x = [self readFloat:s pos:&pos len:len];
                float y = [self readFloat:s pos:&pos len:len];
                if (relative) { x += curX; y += curY; }

                [self arcToBeziers:path fromX:curX fromY:curY toX:x toY:y
                               rx:rx ry:ry largeArc:(largeArc != 0) sweep:(sweep != 0)];
                curX = x; curY = y;
                break;
            }
            case 'Z': case 'z': {
                uls_path_close(path);
                curX = startX; curY = startY;
                break;
            }
            default:
                pos++; // Skip unknown
                break;
        }

        // Reset lastCp for non-curve commands
        if (cmd != 'C' && cmd != 'c' && cmd != 'S' && cmd != 's' &&
            cmd != 'Q' && cmd != 'q' && cmd != 'T' && cmd != 't') {
            lastCpX = curX;
            lastCpY = curY;
        }

        lastCmd = cmd;
    }
}

#pragma mark - SVG Path Number Parser

- (float)readFloat:(const char *)s pos:(int *)pos len:(int)len {
    // Skip whitespace and commas
    while (*pos < len && (s[*pos] == ' ' || s[*pos] == ',' || s[*pos] == '\t' || s[*pos] == '\n' || s[*pos] == '\r'))
        (*pos)++;

    if (*pos >= len) return 0;

    // Check for sign
    int start = *pos;
    if (s[*pos] == '+' || s[*pos] == '-') (*pos)++;

    // Integer part
    while (*pos < len && s[*pos] >= '0' && s[*pos] <= '9') (*pos)++;

    // Decimal point
    if (*pos < len && s[*pos] == '.') {
        (*pos)++;
        while (*pos < len && s[*pos] >= '0' && s[*pos] <= '9') (*pos)++;
    }

    // Exponent
    if (*pos < len && (s[*pos] == 'e' || s[*pos] == 'E')) {
        (*pos)++;
        if (*pos < len && (s[*pos] == '+' || s[*pos] == '-')) (*pos)++;
        while (*pos < len && s[*pos] >= '0' && s[*pos] <= '9') (*pos)++;
    }

    if (*pos == start) return 0;

    char buf[64];
    int numLen = *pos - start;
    if (numLen > 63) numLen = 63;
    memcpy(buf, s + start, numLen);
    buf[numLen] = '\0';

    return (float)atof(buf);
}

#pragma mark - Arc to Bezier Conversion

- (void)arcToBeziers:(ULSVectorPath *)path
               fromX:(float)x1 fromY:(float)y1
                 toX:(float)x2 toY:(float)y2
                  rx:(float)rx ry:(float)ry
            largeArc:(BOOL)largeArc sweep:(BOOL)sweepFlag {
    if (rx == 0 || ry == 0) {
        uls_path_line_to(path, [self tx:x2], [self ty:y2]);
        return;
    }

    rx = fabsf(rx);
    ry = fabsf(ry);

    float dx = (x1 - x2) / 2.0f;
    float dy = (y1 - y2) / 2.0f;

    float d = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry);
    if (d > 1.0f) {
        float s = sqrtf(d);
        rx *= s;
        ry *= s;
    }

    // Approximate with line segments for simplicity
    int numSegments = 16;
    (void)x1; (void)y1; // Used implicitly via loop starting point

    for (int i = 1; i <= numSegments; i++) {
        float t = (float)i / numSegments;
        float x = x1 + t * (x2 - x1);
        float y = y1 + t * (y2 - y1);
        // Add slight curve to approximate arc
        float bulge = sinf(t * M_PI) * fminf(rx, ry) * 0.3f;
        if (!sweepFlag) bulge = -bulge;
        if (largeArc) bulge *= 2.0f;
        float nx = -(y2 - y1);
        float ny = (x2 - x1);
        float nlen = sqrtf(nx * nx + ny * ny);
        if (nlen > 0) { nx /= nlen; ny /= nlen; }
        x += nx * bulge;
        y += ny * bulge;
        uls_path_line_to(path, [self tx:x], [self ty:y]);
    }
}

@end
