/*
 * ULS SVG Parser
 * Parses SVG files into ULSJob vector paths
 */

#import <Foundation/Foundation.h>
#include "uls_job.h"

@interface ULSSVGParser : NSObject <NSXMLParserDelegate>
+ (ULSError)parseFile:(NSString *)filepath intoJob:(ULSJob *)job;
@end
