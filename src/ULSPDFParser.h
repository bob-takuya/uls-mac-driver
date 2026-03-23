/*
 * ULS PDF Parser
 * Parses PDF files into ULSJob vector paths using Quartz / PDFKit
 *
 * Uses CGPDFDocument to extract vector paths from PDF pages.
 * Supports stroke/fill paths: moveto, lineto, curveto, closepath, rectangle.
 *
 * Coordinates are converted from PDF points (72 DPI) to inches.
 */

#import <Foundation/Foundation.h>
#include "uls_job.h"

@interface ULSPDFParser : NSObject

/**
 * Parse a PDF file page into ULS job vector paths.
 *
 * @param filepath  Absolute path to the .pdf file.
 * @param page      Page number (0-based). Pass 0 for the first page.
 * @param job       Target ULSJob to receive vector paths.
 * @return ULS_SUCCESS on success, error code otherwise.
 */
+ (ULSError)parseFile:(NSString *)filepath pageNumber:(int)page intoJob:(ULSJob *)job;

@end
