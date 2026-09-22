// Original code, MIT. External OCRmyPDF/unpaper are invoked, not bundled.
#import "ProcessingQueue.h"
#import "ScanOutput.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>

static NSError *Error(NSString *text) { return [NSError errorWithDomain:@"ScanJetProcessing" code:1 userInfo:@{NSLocalizedDescriptionKey:text}]; }
static BOOL MakeDirectory(NSURL *url,NSError **error) {
    return [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error];
}
NSURL *SJQueueDirectory(void) {
    // Used by the integration tests to isolate their synthetic jobs.
    NSString *override=NSProcessInfo.processInfo.environment[@"SCANJET_QUEUE_DIRECTORY"];
    if(override.length)return [NSURL fileURLWithPath:override isDirectory:YES];
    return [[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
             URLByAppendingPathComponent:@"ScanJet Button"] URLByAppendingPathComponent:@"Queue"];
}
NSString *SJProcessingTool(void) {
    for(NSString *path in @[@"/opt/homebrew/bin/ocrmypdf",@"/usr/local/bin/ocrmypdf",@"/opt/local/bin/ocrmypdf"])
        if([NSFileManager.defaultManager isExecutableFileAtPath:path])return path;
    return nil;
}
static BOOL Save(NSDictionary *record,NSURL *url,NSError **error) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingPrettyPrinted error:error];
    return data&&[data writeToURL:url options:NSDataWritingAtomic error:error];
}
static BOOL ValidRecord(NSDictionary *record,NSURL *manifest) {
    if(![manifest.URLByDeletingLastPathComponent.path.stringByStandardizingPath isEqual:SJQueueDirectory().path.stringByStandardizingPath])return NO;
    if(![record[@"version"] isEqual:@1]||![record[@"settings"] isKindOfClass:NSDictionary.class]||
       ![record[@"pages"] isKindOfClass:NSArray.class]||![record[@"job"] isKindOfClass:NSString.class]||
       ![record[@"folder"] isKindOfClass:NSString.class]||![record[@"name"] isKindOfClass:NSString.class])return NO;
    NSDictionary *settings=record[@"settings"];
    if(!SJValidFormat(settings[@"format"])||!SJValidQuality(settings[@"quality"]))return NO;
    NSString *job=[record[@"job"] stringByStandardizingPath];
    NSString *work=[[record[@"folder"] stringByAppendingPathComponent:@".scanjet-work"] stringByStandardizingPath];
    if(![job.stringByDeletingLastPathComponent isEqual:work]||![[NSUUID alloc] initWithUUIDString:job.lastPathComponent])return NO;
    if(![record[@"name"] isEqual:[record[@"name"] lastPathComponent]])return NO;
    for(NSString *page in record[@"pages"]){
        if(![page isKindOfClass:NSString.class]||![[page stringByStandardizingPath].stringByDeletingLastPathComponent isEqual:job])return NO;
    }
    return YES;
}
static NSMutableDictionary *Read(NSURL *url) {
    NSData *data=[NSData dataWithContentsOfURL:url];
    id value=data?[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]:nil;
    return [value isKindOfClass:NSMutableDictionary.class]?value:nil;
}
static int LockQueue(void) {
    if(!MakeDirectory(SJQueueDirectory(),nil))return -1;
    int fd=open([[SJQueueDirectory() URLByAppendingPathComponent:@".lock"] fileSystemRepresentation],O_CREAT|O_RDWR,0600);
    if(fd>=0&&flock(fd,LOCK_EX|LOCK_NB)!=0){close(fd);return -1;}
    // Child tools must not retain the lock after this worker exits.
    if(fd>=0)fcntl(fd,F_SETFD,FD_CLOEXEC);
    return fd;
}
BOOL SJQueueAvailable(void) { int fd=LockQueue();if(fd<0)return NO;close(fd);return YES; }
NSArray<NSDictionary *> *SJQueueJobs(void) {
    NSMutableArray *jobs=[NSMutableArray new];
    for(NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:SJQueueDirectory() includingPropertiesForKeys:nil options:0 error:nil]) {
        if(![url.pathExtension isEqual:@"json"])continue;
        NSMutableDictionary *record=Read(url);
        if(record&&record[@"state"]){record[@"manifest"]=url.path;[jobs addObject:record];}
    }
    return [jobs sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"created"] compare:b[@"created"]];}];
}
void SJRetryFailedJobs(void) {
    for(NSDictionary *record in SJQueueJobs())if([record[@"state"] isEqual:@"failed"]){
        NSMutableDictionary *next=[record mutableCopy];next[@"state"]=@"queued";
        [next removeObjectForKey:@"error"];[next removeObjectForKey:@"manifest"];
        Save(next,[NSURL fileURLWithPath:record[@"manifest"]],nil);
    }
}
NSURL *SJEnqueueScan(NSURL *job,NSURL *folder,NSArray<NSString *> *pages,NSDictionary *settings,NSString *scanError,NSError **error) {
    if(!pages.count){if(error)*error=Error(@"No pages were received.");return nil;}
    if(!MakeDirectory(SJQueueDirectory(),error))return nil;
    NSString *identifier=NSUUID.UUID.UUIDString;
    NSDateFormatter *date=[NSDateFormatter new];date.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];date.dateFormat=@"yyyy-MM-dd HH.mm.ss";
    NSString *name=[NSString stringWithFormat:@"Scan %@ %@%@",[date stringFromDate:NSDate.date],[identifier substringToIndex:8],scanError.length?@" INCOMPLETE":@""];
    NSMutableDictionary *record=[@{@"version":@1,@"id":identifier,@"created":@(NSDate.date.timeIntervalSince1970),@"name":name,
        @"state":@"queued",@"job":job.path,@"folder":folder.path,@"pages":[pages copy],@"settings":settings,
        @"scanError":scanError?:@""} mutableCopy];
    NSURL *manifest=[SJQueueDirectory() URLByAppendingPathComponent:[identifier stringByAppendingString:@".json"]];
    return Save(record,manifest,error)?manifest:nil;
}

// Conservative, full-page check. Faint writing, colored marks, and dark edges
// keep a page. Detection never deletes the recoverable original batch.
BOOL SJImageIsBlank(NSURL *url,NSError **error) {
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@1600};
    CGImageRef image=source?CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options):NULL;
    if(source)CFRelease(source);
    if(!image){if(error)*error=Error(@"A page could not be read for blank-page detection.");return NO;}
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),count=width*height;
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(NULL,width,height,8,width*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if(!context){CGImageRelease(image);if(error)*error=Error(@"Could not inspect a page.");return NO;}
    CGContextSetRGBFillColor(context,1,1,1,1);CGContextFillRect(context,CGRectMake(0,0,width,height));
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);CGImageRelease(image);
    unsigned char *p=CGBitmapContextGetData(context);size_t histogram[256]={0};
    for(size_t i=0;i<count;i++)histogram[(p[4*i]*77+p[4*i+1]*150+p[4*i+2]*29)>>8]++;
    size_t total=0;int background=255;
    for(int i=0;i<256;i++){total+=histogram[i];if(total>=count*0.8){background=i;break;}}
    size_t ink=0,colorMarks=0;int threshold=MIN(242,background-12);
    for(size_t i=0;i<count;i++){
        int r=p[4*i],g=p[4*i+1],b=p[4*i+2];
        if(((r*77+g*150+b*29)>>8)<threshold)ink++;
        if(MAX(r,MAX(g,b))-MIN(r,MIN(g,b))>25)colorMarks++;
    }
    CGContextRelease(context);
    return background>=235&&ink<=25&&colorMarks<=12;
}
static NSString *Digest(NSURL *url) {
    BOOL directory=NO;if(![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory])return nil;
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);
    NSArray *files=directory?[[NSFileManager.defaultManager contentsOfDirectoryAtPath:url.path error:nil] sortedArrayUsingSelector:@selector(compare:)]:@[@""];
    for(NSString *name in files){
        NSData *label=[name dataUsingEncoding:NSUTF8StringEncoding];CC_SHA256_Update(&ctx,label.bytes,(CC_LONG)label.length);
        NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:directory?[url URLByAppendingPathComponent:name]:url error:nil];if(!handle)return nil;
        NSData *data;while((data=[handle readDataOfLength:1024*1024]).length)CC_SHA256_Update(&ctx,data.bytes,(CC_LONG)data.length);
        [handle closeFile];
    }
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(bytes,&ctx);NSMutableString *result=[NSMutableString new];
    for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[result appendFormat:@"%02x",bytes[i]];return result;
}
// Record the hash and destination before rename. A crash after publication can
// then be recovered without duplicating or overwriting the user's document.
static NSURL *Recover(NSMutableDictionary *record,NSString *key,NSURL *manifest,NSError **error) {
    NSDictionary *prepared=record[[key stringByAppendingString:@"Prepared"]];
    if(!prepared)return nil;
    NSURL *destination=[NSURL fileURLWithPath:prepared[@"destination"]];
    if(![NSFileManager.defaultManager fileExistsAtPath:destination.path]){
        NSURL *staging=[NSURL fileURLWithPath:prepared[@"staging"]];
        if(![[Digest(staging) description] isEqual:prepared[@"sha256"]]){if(error)*error=Error(@"A staged scan changed or is missing. Originals are retained.");return nil;}
        if(renamex_np(staging.fileSystemRepresentation,destination.fileSystemRepresentation,RENAME_EXCL)!=0){if(error)*error=Error(@"Could not publish the scan. Originals are retained.");return nil;}
    }
    if(![Digest(destination) isEqual:prepared[@"sha256"]]){if(error)*error=Error(@"The destination already exists with different contents; it was left untouched.");return nil;}
    record[key]=destination.path;
    if(!Save(record,manifest,error))return nil;return destination;
}
static NSURL *Publish(NSURL *staging,NSURL *destination,NSMutableDictionary *record,NSString *key,NSURL *manifest,NSError **error) {
    NSString *hash=Digest(staging);if(!hash){if(error)*error=Error(@"Could not verify output.");return nil;}
    record[[key stringByAppendingString:@"Prepared"]]=@{@"staging":staging.path,@"destination":destination.path,@"sha256":hash};
    if(!Save(record,manifest,error))return nil;return Recover(record,key,manifest,error);
}
static NSURL *Assemble(NSArray *pages,NSDictionary *settings,NSURL *work,NSError **error) {
    if(!MakeDirectory(work,error))return nil;
    SJScanOutput *output=[[SJScanOutput alloc] initWithJob:work format:settings[@"format"] quality:settings[@"quality"]];
    if(!output){if(error)*error=Error(@"Invalid output settings.");return nil;}
    for(NSString *page in pages)@autoreleasepool{if(![output addImageAtURL:[NSURL fileURLWithPath:page] error:error])return nil;}
    return [output saveToFolder:work partial:NO error:error];
}
static BOOL RunTool(NSString *tool,NSArray *arguments,NSURL *log,NSError **error) {
    [NSFileManager.defaultManager createFileAtPath:log.path contents:nil attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *handle=[NSFileHandle fileHandleForWritingAtPath:log.path];
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:tool];task.arguments=arguments;
    NSMutableDictionary *env=[NSProcessInfo.processInfo.environment mutableCopy];env[@"PATH"]=@"/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin";
    env[@"OMP_THREAD_LIMIT"]=@"1";task.environment=env;task.standardOutput=handle;task.standardError=handle;
    if(![task launchAndReturnError:error]){[handle closeFile];return NO;}
    // Bound a stuck external tool without blocking the scanner or UI.
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3600];
    while(task.running&&deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:0.2];
    if(task.running){[task terminate];[NSThread sleepForTimeInterval:1];if(task.running)kill(task.processIdentifier,SIGKILL);}
    [task waitUntilExit];[handle closeFile];
    if(task.terminationStatus!=0){if(error)*error=Error([NSString stringWithFormat:@"PDF processing failed (code %d). Originals are retained; see the processing log and Retry processing.",task.terminationStatus]);return NO;}
    return YES;
}
static BOOL Process(NSMutableDictionary *record,NSURL *manifest,NSError **error) {
    NSDictionary *settings=record[@"settings"];NSArray *pages=record[@"pages"];
    NSURL *job=[NSURL fileURLWithPath:record[@"job"]],*folder=[NSURL fileURLWithPath:record[@"folder"]];
    BOOL pdf=[settings[@"format"] isEqual:@"pdf"],blank=[settings[@"blank"] boolValue];
    BOOL deskew=pdf&&[settings[@"deskew"] boolValue],clean=pdf&&[settings[@"clean"] boolValue],ocr=pdf&&[settings[@"ocr"] boolValue],rotate=pdf&&[settings[@"rotate"] boolValue];
    BOOL changes=blank||deskew||clean||ocr||rotate;
    if(!MakeDirectory(folder,error))return NO;
    if(record[@"outputPrepared"]){if(!Recover(record,@"output",manifest,error))return NO;return YES;}
    if(changes){
        if(record[@"originalPrepared"]){if(!Recover(record,@"original",manifest,error))return NO;}
        else {
            NSURL *originalFolder=[folder URLByAppendingPathComponent:@"Original scans"];
            if(!MakeDirectory(originalFolder,error))return NO;
            NSURL *staging=Assemble(pages,settings,[job URLByAppendingPathComponent:NSUUID.UUID.UUIDString],error);if(!staging)return NO;
            NSString *name=[record[@"name"] stringByAppendingString:pdf?@".pdf":@" JPEG"];
            if(!Publish(staging,[originalFolder URLByAppendingPathComponent:name],record,@"original",manifest,error))return NO;
        }
    }
    NSMutableArray *kept=[NSMutableArray new],*removed=[NSMutableArray new];
    for(NSUInteger i=0;i<pages.count;i++)@autoreleasepool{
        BOOL empty=blank?SJImageIsBlank([NSURL fileURLWithPath:pages[i]],error):NO;
        if(error&&*error)return NO;
        if(empty)[removed addObject:@(i+1)];else [kept addObject:pages[i]];
    }
    if(!kept.count){[kept addObjectsFromArray:pages];[removed removeAllObjects];record[@"notice"]=@"All pages looked blank; kept the entire batch for review.";}
    record[@"removedPages"]=removed;record[@"outputPages"]=@(kept.count);
    NSURL *work=[job URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *staging=Assemble(kept,settings,work,error);if(!staging)return NO;
    if(deskew||clean||ocr||rotate){
        NSString *tool=SJProcessingTool();
        if(!tool){if(error)*error=Error(@"Install OCRmyPDF 17 or newer and unpaper to use PDF processing. Originals are retained.");return NO;}
        NSURL *processed=[work URLByAppendingPathComponent:@"processed.pdf"];
        NSMutableArray *args=[@[@"--output-type",@"pdf",@"--jobs",@"1",@"--optimize",@"1",@"--no-overwrite"] mutableCopy];
        if(deskew)[args addObject:@"--deskew"];
        if(clean){
            [args addObject:@"--clean-final"];
            // Despeckle only. Masking/blur filters produced large white patches
            // on lightly tinted pages in our synthetic regression fixture.
            [args addObject:@"--unpaper-args=--layout none --no-mask-scan --no-border-scan --no-border-align --no-mask-center --no-grayfilter --no-blackfilter --no-blurfilter --no-deskew"];
        }
        if(rotate)[args addObject:@"--rotate-pages"];
        if(ocr)[args addObjectsFromArray:@[@"--language",@"eng"]];else [args addObjectsFromArray:@[@"--ocr-engine",@"none"]];
        [args addObjectsFromArray:@[staging.path,processed.path]];
        if(!RunTool(tool,args,[job URLByAppendingPathComponent:@"processing.log"],error))return NO;
        PDFDocument *check=[[PDFDocument alloc] initWithURL:processed];
        if(check.pageCount!=kept.count){if(error)*error=Error(@"Processed PDF page count did not match. Originals are retained.");return NO;}
        staging=processed;
    }
    NSString *name=[record[@"name"] stringByAppendingString:pdf?@".pdf":@" JPEG"];
    return Publish(staging,[folder URLByAppendingPathComponent:name],record,@"output",manifest,error)!=nil;
}
int SJProcessJob(NSURL *manifest) {@autoreleasepool {
    if(![manifest.URLByDeletingLastPathComponent.path.stringByStandardizingPath isEqual:SJQueueDirectory().path.stringByStandardizingPath])return 2;
    int fd=LockQueue();if(fd<0)return 75;
    NSMutableDictionary *record=Read(manifest);
    if(!record){close(fd);return 2;}
    if(!ValidRecord(record,manifest)){
        record[@"state"]=@"failed";record[@"error"]=@"The processing record is invalid; no scan files were changed.";
        Save(record,manifest,nil);close(fd);return 2;
    }
    if([record[@"state"] isEqual:@"done"]){close(fd);return 0;}
    setpriority(PRIO_PROCESS,0,10);
    NSError *error=nil;record[@"state"]=@"processing";
    BOOL ok=Save(record,manifest,&error);
    @try {if(ok)ok=Process(record,manifest,&error);}
    @catch(NSException *exception){ok=NO;error=Error(@"Processing was interrupted. Originals are retained; retry this batch.");}
    record[@"state"]=ok?@"done":@"failed";
    if(error)record[@"error"]=error.localizedDescription;else [record removeObjectForKey:@"error"];
    // Commit completion before discarding our own temporary raw files.
    BOOL saved=Save(record,manifest,nil);
    if(ok&&saved&&![record[@"scanError"] length])[NSFileManager.defaultManager removeItemAtPath:record[@"job"] error:nil];
    close(fd);return ok&&saved?0:1;
}}
