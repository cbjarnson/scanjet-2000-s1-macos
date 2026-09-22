#import "ScanOutput.h"
#import <ImageIO/ImageIO.h>
#include <stdio.h>
#include <errno.h>

BOOL SJValidFormat(NSString *value){return [@[@"pdf",@"jpeg"] containsObject:value];}
BOOL SJValidQuality(NSString *value){return [@[@"small",@"balanced",@"high"] containsObject:value];}
static NSError *OutputError(NSString *text){return [NSError errorWithDomain:@"ScanJetOutput" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];}
static BOOL Fail(NSError **error,NSString *text){if(error)*error=OutputError(text);return NO;}
static NSData *JPEGData(CGImageRef image,NSString *quality){
    if(!image||!SJValidQuality(quality))return nil;
    double compression=[quality isEqual:@"small"]?0.50:([quality isEqual:@"high"]?0.95:0.80);
    NSMutableData *data=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,NULL);
    if(!destination)return nil;
    NSDictionary *properties=@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@(compression),
        (__bridge NSString *)kCGImagePropertyDPIWidth:@300,(__bridge NSString *)kCGImagePropertyDPIHeight:@300};
    CGImageDestinationAddImage(destination,image,(__bridge CFDictionaryRef)properties);
    BOOL ok=CGImageDestinationFinalize(destination);CFRelease(destination);return ok?data:nil;
}
static PDFPage *PageFromJPEG(NSData *data,CGSize paper){
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image=CGImageCreateWithJPEGDataProvider(provider,NULL,false,kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);if(!image)return nil;
    NSMutableData *pdfData=[NSMutableData data];
    CGDataConsumerRef sink=CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)pdfData);
    CGRect bounds=CGRectMake(0,0,paper.width,paper.height);
    CGContextRef context=CGPDFContextCreate(sink,&bounds,NULL);CGDataConsumerRelease(sink);
    if(!context){CGImageRelease(image);return nil;}
    CGPDFContextBeginPage(context,NULL);
    CGFloat width=CGImageGetWidth(image)*72.0/300.0,height=CGImageGetHeight(image)*72.0/300.0;
    // JPEG-backed CGImage preserves the compressed stream in the PDF.
    CGContextDrawImage(context,CGRectMake(0,paper.height-height,width,height),image);
    CGPDFContextEndPage(context);CGPDFContextClose(context);CGContextRelease(context);CGImageRelease(image);
    PDFDocument *pdf=[[PDFDocument alloc] initWithData:pdfData];return [[pdf pageAtIndex:0] copy];
}
static NSURL *Publish(NSURL *staging,NSURL *folder,NSString *format,BOOL partial,NSError **error){
    NSDateFormatter *date=[NSDateFormatter new];date.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];date.dateFormat=@"yyyy-MM-dd HH.mm.ss";
    NSString *name=[NSString stringWithFormat:@"Scan %@ %@%@%@",[date stringFromDate:NSDate.date],
        [NSUUID.UUID.UUIDString substringToIndex:8],partial?@" INCOMPLETE":@"",[format isEqual:@"pdf"]?@".pdf":@" JPEG"];
    NSURL *output=[folder URLByAppendingPathComponent:name];
    if(renamex_np(staging.fileSystemRepresentation,output.fileSystemRepresentation,RENAME_EXCL)!=0){
        Fail(error,[NSString stringWithFormat:@"Could not save the scan (%s). Original pages are retained.",strerror(errno)]);return nil;
    }
    return output;
}
@interface SJScanOutput ()
@property NSURL *job,*images;
@property NSString *format,*quality;
@property PDFDocument *pdf;
@property(nonatomic,readwrite) NSUInteger pageCount;
@property BOOL saved;
@end
@implementation SJScanOutput
- (instancetype)initWithJob:(NSURL *)job format:(NSString *)format quality:(NSString *)quality {
    if(!SJValidFormat(format)||!SJValidQuality(quality))return nil;
    if((self=[super init])){self.job=job;self.format=format;self.quality=quality;self.pdf=[PDFDocument new];self.images=[job URLByAppendingPathComponent:@"images" isDirectory:YES];}return self;
}
- (BOOL)addImage:(CGImageRef)image paper:(CGSize)paper error:(NSError **)error {
    if(self.saved)return Fail(error,@"This batch is already saved. Start a new document.");
    NSData *jpeg=JPEGData(image,self.quality);
    if(!jpeg)return Fail(error,@"Could not compress a scanned page. Original files are retained.");
    if([self.format isEqual:@"pdf"]){
        PDFPage *page=PageFromJPEG(jpeg,paper);
        if(!page)return Fail(error,@"Could not add a page to the PDF. Original files are retained.");
        [self.pdf insertPage:page atIndex:self.pdf.pageCount];
    }else{
        NSFileManager *fm=NSFileManager.defaultManager;
        if(![fm createDirectoryAtURL:self.images withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return NO;
        NSURL *file=[self.images URLByAppendingPathComponent:[NSString stringWithFormat:@"Page %04lu.jpg",(unsigned long)self.pageCount+1]];
        NSURL *staging=[self.job URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".jpg"]];
        if(![jpeg writeToURL:staging options:NSDataWritingAtomic error:error])return NO;
        CGImageSourceRef check=CGImageSourceCreateWithURL((__bridge CFURLRef)staging,NULL);
        CGImageRef decoded=check?CGImageSourceCreateImageAtIndex(check,0,NULL):NULL;
        BOOL valid=decoded&&CGImageGetWidth(decoded)==CGImageGetWidth(image)&&CGImageGetHeight(decoded)==CGImageGetHeight(image);
        if(decoded)CGImageRelease(decoded);if(check)CFRelease(check);
        if(!valid){[fm removeItemAtURL:staging error:nil];return Fail(error,@"An image could not be verified. Original files are retained.");}
        if(renamex_np(staging.fileSystemRepresentation,file.fileSystemRepresentation,RENAME_EXCL)!=0)
            return Fail(error,@"Could not save a numbered image. Original files are retained.");
    }
    self.pageCount++;return YES;
}
- (BOOL)addImageAtURL:(NSURL *)url error:(NSError **)error {
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    CGImageRef image=source?CGImageSourceCreateImageAtIndex(source,0,NULL):NULL;
    if(source)CFRelease(source);
    if(!image)return Fail(error,@"A scanned page could not be read. Original files are retained.");
    BOOL ok=[self addImage:image paper:CGSizeMake(612,792) error:error];CGImageRelease(image);return ok;
}
- (NSURL *)saveToFolder:(NSURL *)folder partial:(BOOL)partial error:(NSError **)error {
    if(self.saved||!self.pageCount){Fail(error,self.saved?@"This batch is already saved.":@"No pages were received.");return nil;}
    NSURL *staging=self.images;
    if([self.format isEqual:@"pdf"]){
        NSData *data=self.pdf.dataRepresentation;
        PDFDocument *check=data?[[PDFDocument alloc] initWithData:data]:nil;
        if(check.pageCount!=self.pageCount){Fail(error,@"The PDF could not be verified. Original pages are retained.");return nil;}
        staging=[self.job URLByAppendingPathComponent:@"assembled.pdf"];
        if(![data writeToURL:staging options:NSDataWritingAtomic error:error])return nil;
    }
    NSURL *output=Publish(staging,folder,self.format,partial,error);
    if(output)self.saved=YES;return output;
}
@end

static NSURL *NewJob(NSURL *folder,NSError **error){
    NSURL *job=[[folder URLByAppendingPathComponent:@".scanjet-work" isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    return [NSFileManager.defaultManager createDirectoryAtURL:job withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]?job:nil;
}
static void CheckJPEGStream(const char *key,CGPDFObjectRef value,void *context){
    CGPDFStreamRef stream=NULL;const char *filter=NULL;
    if(CGPDFObjectGetValue(value,kCGPDFObjectTypeStream,&stream)&&
       CGPDFDictionaryGetName(CGPDFStreamGetDictionary(stream),"Filter",&filter)&&strcmp(filter,"DCTDecode")==0)*(BOOL *)context=YES;
}
static BOOL PDFKeepsJPEG(NSURL *url){
    CGPDFDocumentRef doc=CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);if(!doc)return NO;
    BOOL all=CGPDFDocumentGetNumberOfPages(doc)>0;
    for(size_t i=1;i<=CGPDFDocumentGetNumberOfPages(doc);i++){
        CGPDFDictionaryRef resources=NULL,objects=NULL;BOOL jpeg=NO;
        if(CGPDFDictionaryGetDictionary(CGPDFPageGetDictionary(CGPDFDocumentGetPage(doc,i)),"Resources",&resources)&&
           CGPDFDictionaryGetDictionary(resources,"XObject",&objects))CGPDFDictionaryApplyFunction(objects,CheckJPEGStream,&jpeg);
        all=all&&jpeg;
    }
    CGPDFDocumentRelease(doc);return all;
}
int SJOutputSelfTest(void){@autoreleasepool {
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
    NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error];
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(NULL,600,800,8,2400,color,(CGBitmapInfo)kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(color);
    uint8_t *pixels=CGBitmapContextGetData(ctx);uint32_t seed=7;
    for(size_t i=0;i<600*800;i++){seed=seed*1664525+1013904223;uint8_t n=seed>>24;pixels[i*4]=n;pixels[i*4+1]=255-n;pixels[i*4+2]=n/2;pixels[i*4+3]=255;}
    CGImageRef first=CGBitmapContextCreateImage(ctx);
    CGContextSetRGBFillColor(ctx,1,1,1,1);CGContextFillRect(ctx,CGRectMake(0,0,600,800));
    CGImageRef second=CGBitmapContextCreateImage(ctx);CGContextRelease(ctx);
    BOOL pass=YES;
    NSData *small=JPEGData(first,@"small"),*balanced=JPEGData(first,@"balanced"),*high=JPEGData(first,@"high");
    pass=small.length<balanced.length&&balanced.length<high.length;
    for(NSString *format in @[@"pdf",@"jpeg"]){
        NSURL *job=NewJob(root,&error);SJScanOutput *batch=[[SJScanOutput alloc] initWithJob:job format:format quality:@"balanced"];
        BOOL added=[batch addImage:first paper:CGSizeMake(612,792) error:&error]&&[batch addImage:second paper:CGSizeMake(612,792) error:&error];
        pass=pass&&added;
        NSURL *output=[batch saveToFolder:root partial:NO error:&error];pass=pass&&output!=nil&&batch.pageCount==2;
        if(!output)break;
        if([format isEqual:@"pdf"]){PDFDocument *pdf=[[PDFDocument alloc] initWithURL:output];pass=pass&&pdf.pageCount==2&&NSEqualSizes([[pdf pageAtIndex:0] boundsForBox:kPDFDisplayBoxMediaBox].size,NSMakeSize(612,792))&&PDFKeepsJPEG(output);}
        else{
            NSArray *files=[fm contentsOfDirectoryAtPath:output.path error:&error];
            pass=pass&&files.count==2&&[files containsObject:@"Page 0001.jpg"]&&[files containsObject:@"Page 0002.jpg"];
            NSData *saved=[NSData dataWithContentsOfURL:[output URLByAppendingPathComponent:@"Page 0001.jpg"]];pass=pass&&[saved isEqualToData:balanced];
        }
        NSData *prior=[format isEqual:@"pdf"]?[NSData dataWithContentsOfURL:output]:[NSData dataWithContentsOfURL:[output URLByAppendingPathComponent:@"Page 0001.jpg"]];
        SJScanOutput *next=[[SJScanOutput alloc] initWithJob:NewJob(root,&error) format:format quality:@"small"];
        [next addImage:second paper:CGSizeMake(612,792) error:&error];NSURL *partial=[next saveToFolder:root partial:YES error:&error];
        pass=pass&&partial&&![partial isEqual:output]&&[partial.lastPathComponent containsString:@"INCOMPLETE"];
        NSData *after=[format isEqual:@"pdf"]?[NSData dataWithContentsOfURL:output]:[NSData dataWithContentsOfURL:[output URLByAppendingPathComponent:@"Page 0001.jpg"]];
        pass=pass&&[prior isEqual:after];
        NSError *expected=nil;pass=pass&&![batch saveToFolder:root partial:NO error:&expected]&&expected!=nil;
        SJScanOutput *empty=[[SJScanOutput alloc] initWithJob:NewJob(root,&error) format:format quality:@"balanced"];
        expected=nil;pass=pass&&![empty saveToFolder:root partial:NO error:&expected]&&expected!=nil;
        expected=nil;pass=pass&&![empty addImageAtURL:[root URLByAppendingPathComponent:@"missing.tiff"] error:&expected]&&empty.pageCount==0;
    }
    pass=pass&&!SJValidFormat(@"invalid")&&!SJValidQuality(@"invalid");
    CGImageRelease(first);CGImageRelease(second);
    printf("compression_formats_batch_isolation_partial_errors=%s sizes=%lu/%lu/%lu\n",pass?"PASS":"FAIL",(unsigned long)small.length,(unsigned long)balanced.length,(unsigned long)high.length);
    if(error)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
    [fm removeItemAtURL:root error:nil];return pass&&!error?0:1;
}}
