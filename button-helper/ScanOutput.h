#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>

BOOL SJValidFormat(NSString *value);
BOOL SJValidQuality(NSString *value);

// One instance per batch; originals remain in job until publication succeeds.
@interface SJScanOutput : NSObject
@property(nonatomic,readonly) NSUInteger pageCount;
- (instancetype)initWithJob:(NSURL *)job format:(NSString *)format quality:(NSString *)quality;
- (BOOL)addImageAtURL:(NSURL *)url error:(NSError **)error;
- (NSURL *)saveToFolder:(NSURL *)folder partial:(BOOL)partial error:(NSError **)error;
@end

int SJOutputSelfTest(void);
