/*
 * ULS PDF Parser Implementation
 * Parses PDF files into ULSJob vector paths using Quartz
 *
 * Each PDF path stream is iterated via CGPDFOperatorTable callbacks.
 * Paths are collected and flushed to ULSVectorPath on stroke/fill operators.
 */

#import "ULSPDFParser.h"
#import <Quartz/Quartz.h>
#include <math.h>

/* PDF points per inch (PostScript standard) */
#define PDF_POINTS_PER_INCH 72.0f

/* Parser context (passed through CGPDFOperatorTable) */
typedef struct {
    ULSJob       *job;
    CGAffineTransform ctm;       /* Current transformation matrix */

    /* Path being built */
    ULSVectorPath *currentPath;
    float          pathStartX;   /* For closepath */
    float          pathStartY;
    float          curX;
    float          curY;

    float          pageHeight;   /* PDF page height in points (for Y-flip) */
} PDFParserContext;

/* ============================================================
 * Coordinate helpers
 * PDF origin is bottom-left, ULS origin is top-left, so Y is flipped.
 * ============================================================ */

/* tx/ty: apply CTM and convert PDF points → inches, with Y-flip */
static float tx(PDFParserContext *ctx, float x, float y) {
    CGPoint pt = CGPointApplyAffineTransform(CGPointMake(x, y), ctx->ctm);
    return (float)(pt.x / PDF_POINTS_PER_INCH);
}

static float ty(PDFParserContext *ctx, float x, float y) {
    /* Flip Y: PDF origin is bottom-left, ULS origin is top-left */
    float flipped_y = ctx->pageHeight - y;
    CGPoint pt = CGPointApplyAffineTransform(CGPointMake(x, flipped_y), ctx->ctm);
    return (float)(fabs(pt.y) / PDF_POINTS_PER_INCH);
}

/* ============================================================
 * Path management
 * ============================================================ */

static void ensure_path(PDFParserContext *ctx) {
    if (!ctx->currentPath) {
        ctx->currentPath = uls_path_create();
        uls_path_set_laser(ctx->currentPath,
                           ctx->job->settings.power,
                           ctx->job->settings.speed,
                           ctx->job->settings.ppi);
    }
}

static void flush_path(PDFParserContext *ctx) {
    if (ctx->currentPath && ctx->currentPath->numElements > 0) {
        uls_job_add_path(ctx->job, ctx->currentPath);
        ctx->currentPath = NULL;
    } else if (ctx->currentPath) {
        uls_path_destroy(ctx->currentPath);
        ctx->currentPath = NULL;
    }
}

/* ============================================================
 * PDF Operator callbacks
 * ============================================================ */

/* m – moveto */
static void op_m(CGPDFScannerRef scanner, void *info) {
    PDFParserContext *ctx = (PDFParserContext *)info;
    CGPDFReal x, y;
    if (!CGPDFScannerPopNumber(scanner, &y)) return;
    if (!CGPDFScannerPopNumber(scanner, &x)) return;

    ensure_path(ctx);
    float fx = tx(ctx, (float)x, (float)y);
    float fy = ty(ctx, (float)x, (float)y);
    uls_path_move_to(ctx->currentPath, fx, fy);
    ctx->curX = (float)x;
    ctx->curY = (float)y;
    ctx->pathStartX = (float)x;
    ctx->pathStartY = (float)y;
}

/* l – lineto */
static void op_l(CGPDFScannerRef scanner, void *info) {
    PDFParserContext *ctx = (PDFParserContext *)info;
    CGPDFReal x, y;
    if (!CGPDFScannerPopNumber(scanner, &y)) return;
    if (!CGPDFScannerPopNumber(scanner, &x)) return;

    ensure_path(ctx);
    uls_path_line_to(ctx->currentPath,
                     tx(ctx, (float)x, (float)y),
                     ty(ctx, (float)x, (float)y));
    ctx->curX = (float)x;
    ctx->curY = (float)y;
}

/* c – curveto (x1,y1, x2,y2, x3,y3) */
static void op_c(CGPDFScannerRef scanner, void *info) {
    PDFParserContext *ctx = (PDFParserContext *)info;
    CGPDFReal x3, y3, x2, y2, x1, y1;
    if (!CGPDFScannerPopNumber(scanner, &y3)) return;
    if (!CGPDFScannerPopNumber(scanner, &x3)) return;
    if (!CGPDFScannerPopNumber(scanner, &y2)) return;
    if (!CGPDFScannerPopNumber(scanner, &x2)) return;
    if (!CGPDFScannerPopNumber(scanner, &y1)) return;
    if (!CGPDFScannerPopNumber(scanner, &x1)) return;

    ensure_path(ctx);
    uls_path_bezier_to(ctx->currentPath,
                       tx(ctx, (float)x1, (float)y1), ty(ctx, (float)x1, (float)y1),
                       tx(ctx, (float)x2, (float)y2), ty(ctx, (float)x2, (float)y2),
                       tx(ctx, (float)x3, (float)y3), ty(ctx, (float)x3, (float)y3));
    ctx->curX = (float)x3;
    ctx->curY = (float)y3;
}

/* v – curveto (cp1 = current point) */
static void op_v(CGPDFScannerRef scanner, void *info) {
    PDFParserContext *ctx = (PDFParserContext *)info;
    CGPDFReal x3, y3, x2, y2;
    if (!CGPDFScannerPopNumber(scanner, &y3)) return;
    if (!CGPDFScannerPopNumber(scanner, &x3)) return;
    if (!CGPDFScannerPopNumber(scanner, &y2)) return;
    if (!CGPDFScannerPopNumber(scanner, &x2)) return;

    ensure_path(ctx);
    /* cp1 = current point */
    uls_path_bezier_to(ctx->currentPath,
                       tx(ctx, ctx->curX, ctx->curY), ty(ctx, ctx->curX, ctx->curY),
                       tx(ctx, (float)x2, (float)y2), ty(ctx, (float)x2, (float)y2),
                       tx(ctx, (float)x3, (float)y3), ty(ctx, (float)x3, (float)y3));
    ctx->curX = (float)x3;
    ctx->curY = (float)y3;
}

/* y – curveto (cp2 = final point) */
static void op_y(CGPDFScannerRef scanner, void *info) {
    PDFParserContext *ctx = (PDFParserContext *)info;
    CGPDFReal x3, y3, x1, y1;
    if (!CGPDFScannerPopNumber(scanner, &y3)) return;
    if (!CGPDFScannerPopNumber(scanner, &x3)) return;
    if (!CGPDFScannerPopNumber(scanner, &y1)) return;
    if (!CGPDFScannerPopNumber(scanner, &x1)) return;

    ensure_path(ctx);
    /* cp2 = end point */
    uls_path_bezier_to(ctx->currentPath,
                       tx(ctx, (float)x1, (float)y1), ty(ctx, (float)x1, (float)y1),
                       tx(ctx, (float)x3, (float)y3), ty(ctx, (float)x3, (float)y3),
                       tx(ctx, (float)x3, (float)y3), ty(ctx, (float)x3, (float)y3));
    ctx->curX = (float)x3;
    ctx->curY = (float)y3;
}

/* h – closepath */
static void op_h(CGPDFScannerRef scanner, void *info) {
    (void)scanner;
    PDFParserContext *ctx = (PDFParserContext *)info;
    if (ctx->currentPath) {
        uls_path_close(ctx->currentPath);
    }
    ctx->curX = ctx->pathStartX;
    ctx->curY = ctx->pathStartY;
}

/* re – rectangle (x y w h) */
static void op_re(CGPDFScannerRef scanner, void *info) {
    PDFParserContext *ctx = (PDFParserContext *)info;
    CGPDFReal h, w, y, x;
    if (!CGPDFScannerPopNumber(scanner, &h)) return;
    if (!CGPDFScannerPopNumber(scanner, &w)) return;
    if (!CGPDFScannerPopNumber(scanner, &y)) return;
    if (!CGPDFScannerPopNumber(scanner, &x)) return;

    ensure_path(ctx);

    /* Rectangle: add as moveto + 3 lineto + close */
    float x0 = tx(ctx, (float)x, (float)y);
    float y0 = ty(ctx, (float)x, (float)y);
    float x1r = tx(ctx, (float)(x+w), (float)y);
    float y1r = ty(ctx, (float)(x+w), (float)y);
    float x2r = tx(ctx, (float)(x+w), (float)(y+h));
    float y2r = ty(ctx, (float)(x+w), (float)(y+h));
    float x3r = tx(ctx, (float)x, (float)(y+h));
    float y3r = ty(ctx, (float)x, (float)(y+h));

    uls_path_move_to(ctx->currentPath, x0, y0);
    uls_path_line_to(ctx->currentPath, x1r, y1r);
    uls_path_line_to(ctx->currentPath, x2r, y2r);
    uls_path_line_to(ctx->currentPath, x3r, y3r);
    uls_path_close(ctx->currentPath);
}

/* S/s – stroke path (uppercase = no closepath first) */
static void op_S(CGPDFScannerRef scanner, void *info) {
    (void)scanner;
    PDFParserContext *ctx = (PDFParserContext *)info;
    flush_path(ctx);
}

/* F/f – fill path (we still record the path for cutting) */
static void op_F(CGPDFScannerRef scanner, void *info) {
    (void)scanner;
    PDFParserContext *ctx = (PDFParserContext *)info;
    flush_path(ctx);
}

/* B/b – fill+stroke */
static void op_B(CGPDFScannerRef scanner, void *info) {
    (void)scanner;
    PDFParserContext *ctx = (PDFParserContext *)info;
    flush_path(ctx);
}

/* n – path but no paint (discard) */
static void op_n(CGPDFScannerRef scanner, void *info) {
    (void)scanner;
    PDFParserContext *ctx = (PDFParserContext *)info;
    if (ctx->currentPath) {
        uls_path_destroy(ctx->currentPath);
        ctx->currentPath = NULL;
    }
}

/* cm – concat matrix */
static void op_cm(CGPDFScannerRef scanner, void *info) {
    PDFParserContext *ctx = (PDFParserContext *)info;
    CGPDFReal a, b, c, d, e, f;
    if (!CGPDFScannerPopNumber(scanner, &f)) return;
    if (!CGPDFScannerPopNumber(scanner, &e)) return;
    if (!CGPDFScannerPopNumber(scanner, &d)) return;
    if (!CGPDFScannerPopNumber(scanner, &c)) return;
    if (!CGPDFScannerPopNumber(scanner, &b)) return;
    if (!CGPDFScannerPopNumber(scanner, &a)) return;

    CGAffineTransform m = CGAffineTransformMake(a, b, c, d, e, f);
    ctx->ctm = CGAffineTransformConcat(m, ctx->ctm);
}

/* ============================================================
 * Main parser
 * ============================================================ */

@implementation ULSPDFParser

+ (ULSError)parseFile:(NSString *)filepath pageNumber:(int)page intoJob:(ULSJob *)job {
    if (!filepath || !job) return ULS_ERROR_INVALID_PARAM;

    /* Open PDF document */
    NSURL *url = [NSURL fileURLWithPath:filepath];
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    if (!doc) {
        return ULS_ERROR_IO;
    }

    /* PDF pages are 1-indexed in Quartz */
    size_t numPages = CGPDFDocumentGetNumberOfPages(doc);
    if (numPages == 0) {
        CGPDFDocumentRelease(doc);
        return ULS_ERROR_INVALID_PARAM;
    }

    int pageIndex = (page < 0) ? 1 : (page + 1);
    if ((size_t)pageIndex > numPages) pageIndex = 1;

    CGPDFPageRef pdfPage = CGPDFDocumentGetPage(doc, pageIndex);
    if (!pdfPage) {
        CGPDFDocumentRelease(doc);
        return ULS_ERROR_INVALID_PARAM;
    }

    /* Get page dimensions */
    CGRect mediaBox = CGPDFPageGetBoxRect(pdfPage, kCGPDFMediaBox);
    float pageHeight = (float)mediaBox.size.height;

    /* Set up operator table */
    CGPDFOperatorTableRef table = CGPDFOperatorTableCreate();

    /* Path construction */
    CGPDFOperatorTableSetCallback(table, "m",  op_m);
    CGPDFOperatorTableSetCallback(table, "l",  op_l);
    CGPDFOperatorTableSetCallback(table, "c",  op_c);
    CGPDFOperatorTableSetCallback(table, "v",  op_v);
    CGPDFOperatorTableSetCallback(table, "y",  op_y);
    CGPDFOperatorTableSetCallback(table, "h",  op_h);
    CGPDFOperatorTableSetCallback(table, "re", op_re);

    /* Path painting */
    CGPDFOperatorTableSetCallback(table, "S",  op_S);
    CGPDFOperatorTableSetCallback(table, "s",  op_S);  /* close+stroke */
    CGPDFOperatorTableSetCallback(table, "F",  op_F);
    CGPDFOperatorTableSetCallback(table, "f",  op_F);
    CGPDFOperatorTableSetCallback(table, "f*", op_F);
    CGPDFOperatorTableSetCallback(table, "B",  op_B);
    CGPDFOperatorTableSetCallback(table, "B*", op_B);
    CGPDFOperatorTableSetCallback(table, "b",  op_B);
    CGPDFOperatorTableSetCallback(table, "b*", op_B);
    CGPDFOperatorTableSetCallback(table, "n",  op_n);

    /* Graphics state */
    CGPDFOperatorTableSetCallback(table, "cm", op_cm);

    /* Build context */
    PDFParserContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.job = job;
    ctx.ctm = CGAffineTransformIdentity;
    ctx.currentPath = NULL;
    ctx.pageHeight = pageHeight;

    /* Scan the content stream */
    CGPDFContentStreamRef cs = CGPDFContentStreamCreateWithPage(pdfPage);
    CGPDFScannerRef scanner = CGPDFScannerCreate(cs, table, &ctx);
    CGPDFScannerScan(scanner);

    /* Flush any remaining path */
    flush_path(&ctx);

    /* Cleanup */
    CGPDFScannerRelease(scanner);
    CGPDFContentStreamRelease(cs);
    CGPDFOperatorTableRelease(table);
    CGPDFDocumentRelease(doc);

    return ULS_SUCCESS;
}

@end
