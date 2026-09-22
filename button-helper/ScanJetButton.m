// Original code, MIT. Uses the installed HP ICA driver without modifying it.
#import <AppKit/AppKit.h>
#import <ImageCaptureCore/ImageCaptureCore.h>
#import <PDFKit/PDFKit.h>
#import <ImageIO/ImageIO.h>
#include <stdio.h>
#include <errno.h>
#include <signal.h>
extern int sj_read_button(void);
static volatile sig_atomic_t cancelRequested=0;
static void HandleCancel(int signalNumber){cancelRequested=1;}
static void Emit(NSDictionary *event){
    NSData *data=[NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if(data){fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);}
}

static NSError *Failure(NSString *text) {
    return [NSError errorWithDomain:@"ScanJetButton" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];
}
static PDFPage *PageFromImage(NSURL *url) {
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    if(!source)return nil;
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,NULL);CFRelease(source);
    if(!image)return nil;
    NSMutableData *data=[NSMutableData data];
    CGDataConsumerRef sink=CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)data);
    CGRect paper=CGRectMake(0,0,612,792);
    CGContextRef context=CGPDFContextCreate(sink,&paper,NULL);CGDataConsumerRelease(sink);
    if(!context){CGImageRelease(image);return nil;}
    CGPDFContextBeginPage(context,NULL);
    CGFloat width=CGImageGetWidth(image)*72.0/300.0,height=CGImageGetHeight(image)*72.0/300.0;
    CGContextDrawImage(context,CGRectMake(0,792-height,width,height),image);
    CGPDFContextEndPage(context);CGPDFContextClose(context);CGContextRelease(context);CGImageRelease(image);
    PDFDocument *pdf=[[PDFDocument alloc] initWithData:data];
    return [[pdf pageAtIndex:0] copy];
}
// A fresh job gets its own directory and document. Never append to a previous PDF.
static NSURL *SavePDF(PDFDocument *pdf,NSURL *job,NSURL *folder,BOOL partial,NSError **error) {
    if(pdf.pageCount==0){if(error)*error=Failure(@"No pages were received.");return nil;}
    NSData *data=pdf.dataRepresentation;
    PDFDocument *check=data?[[PDFDocument alloc] initWithData:data]:nil;
    if(check.pageCount!=pdf.pageCount){if(error)*error=Failure(@"The PDF could not be verified. Original pages are retained.");return nil;}
    NSURL *staging=[job URLByAppendingPathComponent:@"assembled.pdf"];
    if(![data writeToURL:staging options:NSDataWritingAtomic error:error])return nil;
    NSDateFormatter *format=[NSDateFormatter new];format.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.dateFormat=@"yyyy-MM-dd HH.mm.ss";
    NSString *name=[NSString stringWithFormat:@"Scan %@ %@%@.pdf",[format stringFromDate:NSDate.date],
                    [NSUUID.UUID.UUIDString substringToIndex:8],partial?@" INCOMPLETE":@""];
    NSURL *output=[folder URLByAppendingPathComponent:name];
    if(renamex_np(staging.fileSystemRepresentation,output.fileSystemRepresentation,RENAME_EXCL)!=0){
        if(error)*error=Failure([NSString stringWithFormat:@"Could not save the PDF (%s). Original pages are retained.",strerror(errno)]);
        return nil;
    }
    return output;
}

@interface ScanJetApp : NSObject <NSApplicationDelegate,ICDeviceBrowserDelegate,ICScannerDeviceDelegate>
@property NSStatusItem *item;
@property NSMenu *menu;
@property NSMenuItem *stateItem,*scanItem,*cancelItem,*duplexItem,*buttonItem,*folderItem,*quitItem;
@property NSWindow *window;
@property NSTextField *statusLabel,*folderLabel;
@property NSButton *scanButton,*cancelButton,*duplexButton,*listenButton;
@property NSURL *folder,*job,*jobFolder,*lastOutput;
@property ICDeviceBrowser *browser;
@property ICScannerDevice *scanner;
@property PDFDocument *document;
@property NSTimer *pollTimer,*openTimer;
@property BOOL duplex,buttons,busy,polling,armed,scanStarted,finishing,selecting,deviceReady,configured;
@property NSString *state;
@property NSError *pageError;
@property BOOL workerMode;
@property NSTask *worker;
@property NSPipe *workerPipe;
@property NSMutableData *workerBuffer;
@property NSDictionary *workerResult;
@property NSTimer *cancelTimer;
@end

@implementation ScanJetApp
- (NSMenuItem *)add:(NSString *)name action:(SEL)action {
    NSMenuItem *entry=[[NSMenuItem alloc] initWithTitle:name action:action keyEquivalent:@""];
    entry.target=self;[self.menu addItem:entry];return entry;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if(self.workerMode){
        signal(SIGINT,HandleCancel);signal(SIGTERM,HandleCancel);
        self.buttons=NO;
        self.cancelTimer=[NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer){
            if(cancelRequested){cancelRequested=0;if(self.scanStarted)[self cancel:nil];else [self finish:Failure(@"Scan cancelled before acquisition.")];}
        }];
        [self startScan];return;
    }
    NSUserDefaults *prefs=NSUserDefaults.standardUserDefaults;
    [prefs registerDefaults:@{@"duplex":@YES,@"buttons":@YES}];
    NSString *saved=[prefs stringForKey:@"folder"];
    self.folder=saved?[NSURL fileURLWithPath:saved isDirectory:YES]:
       [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Scans" isDirectory:YES];
    self.duplex=[prefs boolForKey:@"duplex"];self.buttons=[prefs boolForKey:@"buttons"];
    self.item=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title=@"ScanJet";self.item.button.toolTip=@"ScanJet Button — fresh PDF per batch";
    self.menu=[NSMenu new];self.menu.autoenablesItems=NO;self.item.menu=self.menu;
    self.stateItem=[self add:@"Connecting…" action:NULL];self.stateItem.enabled=NO;
    [self add:@"Show controls…" action:@selector(showControls:)];
    self.scanItem=[self add:@"Scan a new document" action:@selector(manualScan:)];
    self.cancelItem=[self add:@"Cancel scan" action:@selector(cancel:)];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.buttonItem=[self add:@"Use front Scan button" action:@selector(toggleButtons:)];
    self.duplexItem=[self add:@"Scan both sides" action:@selector(toggleDuplex:)];
    NSMenuItem *quality=[self add:@"Color · 300 dpi · US Letter · PDF" action:NULL];quality.enabled=NO;
    [self.menu addItem:NSMenuItem.separatorItem];
    self.folderItem=[self add:@"" action:NULL];self.folderItem.enabled=NO;
    [self add:@"Choose save folder…" action:@selector(chooseFolder:)];
    [self add:@"Open save folder" action:@selector(openFolder:)];
    [self add:@"Show latest PDF" action:@selector(showLast:)];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.quitItem=[self add:@"Quit ScanJet Button" action:@selector(quit:)];
    [self buildWindow];[self update:@"Checking scanner…"];[self schedulePoll:0.1];[self showControls:nil];
}
- (void)buildWindow {
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,460,335)
         styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"ScanJet Button";self.window.releasedWhenClosed=NO;[self.window center];
    NSView *view=self.window.contentView;
    NSTextField *title=[NSTextField labelWithString:@"A fresh PDF with each press"];
    title.font=[NSFont boldSystemFontOfSize:20];title.frame=NSMakeRect(24,280,412,30);[view addSubview:title];
    NSTextField *subtitle=[NSTextField wrappingLabelWithString:@"Load your pages, then press the scanner’s front Scan button. You can close this window; ScanJet stays in the menu bar."];
    subtitle.frame=NSMakeRect(24,228,412,46);[view addSubview:subtitle];
    self.statusLabel=[NSTextField wrappingLabelWithString:@"Checking scanner…"];
    self.statusLabel.font=[NSFont boldSystemFontOfSize:13];self.statusLabel.frame=NSMakeRect(24,188,412,32);[view addSubview:self.statusLabel];
    self.listenButton=[NSButton checkboxWithTitle:@"Use front Scan button" target:self action:@selector(toggleButtons:)];
    self.listenButton.frame=NSMakeRect(24,152,225,24);[view addSubview:self.listenButton];
    self.duplexButton=[NSButton checkboxWithTitle:@"Scan both sides" target:self action:@selector(toggleDuplex:)];
    self.duplexButton.frame=NSMakeRect(255,152,180,24);[view addSubview:self.duplexButton];
    self.folderLabel=[NSTextField labelWithString:@""];self.folderLabel.frame=NSMakeRect(24,121,412,22);
    self.folderLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;[view addSubview:self.folderLabel];
    NSButton *choose=[NSButton buttonWithTitle:@"Choose folder…" target:self action:@selector(chooseFolder:)];
    choose.frame=NSMakeRect(18,82,145,32);[view addSubview:choose];
    NSButton *show=[NSButton buttonWithTitle:@"Open folder" target:self action:@selector(openFolder:)];
    show.frame=NSMakeRect(162,82,125,32);[view addSubview:show];
    self.scanButton=[NSButton buttonWithTitle:@"Scan new document" target:self action:@selector(manualScan:)];
    self.scanButton.frame=NSMakeRect(244,24,192,34);[view addSubview:self.scanButton];
    self.cancelButton=[NSButton buttonWithTitle:@"Cancel scan" target:self action:@selector(cancel:)];
    self.cancelButton.frame=NSMakeRect(18,24,135,34);[view addSubview:self.cancelButton];
}
- (void)showControls:(id)sender {[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {[self showControls:nil];return YES;}
- (void)update:(NSString *)text {
    self.state=text;self.stateItem.title=text;
    self.item.button.title=self.busy?@"ScanJet • Scanning":@"ScanJet";
    self.scanItem.enabled=!self.busy;self.cancelItem.enabled=self.busy&&self.scanStarted&&!self.finishing;
    self.duplexItem.enabled=!self.busy;self.buttonItem.enabled=!self.busy;self.quitItem.enabled=!self.busy;
    self.duplexItem.state=self.duplex?NSControlStateValueOn:NSControlStateValueOff;
    self.buttonItem.state=self.buttons?NSControlStateValueOn:NSControlStateValueOff;
    self.folderItem.title=[NSString stringWithFormat:@"Save to: %@",self.folder.path.stringByAbbreviatingWithTildeInPath];
    self.statusLabel.stringValue=text;self.folderLabel.stringValue=self.folderItem.title;
    self.scanButton.enabled=!self.busy;self.cancelButton.enabled=self.cancelItem.enabled;
    self.listenButton.enabled=!self.busy;self.duplexButton.enabled=!self.busy;
    self.listenButton.state=self.buttonItem.state;self.duplexButton.state=self.duplexItem.state;
    if(self.workerMode)Emit(@{@"event":@"progress",@"message":text});
    NSLog(@"%@",text);
}
- (void)schedulePoll:(NSTimeInterval)delay {
    [self.pollTimer invalidate];
    if(!self.buttons||self.busy)return;
    __weak ScanJetApp *weak=self;
    self.pollTimer=[NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer){[weak poll];}];
    [NSRunLoop.mainRunLoop addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}
- (void)poll {
    if(self.polling||self.busy||!self.buttons)return;
    self.polling=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        int value=sj_read_button(); // Returns only after releasing both USB handles.
        dispatch_async(dispatch_get_main_queue(),^{
            self.polling=NO;
            if(self.busy||!self.buttons)return;
            if(value<0){self.armed=NO;if(![self.state hasPrefix:@"Scanner unavailable"])[self update:@"Scanner unavailable — close other scan apps"];}
            else if(value==0){self.armed=YES;if([self.state hasPrefix:@"Checking"]||[self.state hasPrefix:@"Scanner unavailable"])[self update:@"Ready — press the front Scan button"];}
            else if(value==1&&self.armed){self.armed=NO;[self startScan];return;}
            // Cancel/unknown combinations never start an acquisition. After launch,
            // pause, reconnect or a completed scan, require idle before a fresh press.
            [self schedulePoll:value<0?3:0.75];
        });
    });
}
- (void)manualScan:(id)sender {[self startScan];}
- (void)startScan {
    if(self.busy)return;
    self.busy=YES;self.armed=NO;self.scanStarted=NO;self.finishing=NO;self.selecting=NO;self.deviceReady=NO;self.configured=NO;self.pageError=nil;
    [self.pollTimer invalidate];[self update:@"Opening scanner…"];
    // Serialize manual clicks with a USB poll that may still be returning.
    [self openWhenUSBReleased];
}
- (void)openWhenUSBReleased {
    if(self.polling){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self openWhenUSBReleased];});return;}
    if(!self.workerMode){[self launchWorker];return;}
    NSError *error=nil;NSFileManager *fm=NSFileManager.defaultManager;
    self.jobFolder=self.folder;
    if(![fm createDirectoryAtURL:self.jobFolder withIntermediateDirectories:YES attributes:nil error:&error]){[self finish:error];return;}
    NSURL *work=[self.jobFolder URLByAppendingPathComponent:@".scanjet-work" isDirectory:YES];
    self.job=[work URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if(![fm createDirectoryAtURL:self.job withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){[self finish:error];return;}
    self.document=[PDFDocument new];
    self.browser=[ICDeviceBrowser new];self.browser.delegate=self;
    self.browser.browsedDeviceTypeMask=(ICDeviceTypeMask)(ICDeviceTypeMaskScanner|ICDeviceLocationTypeMaskLocal);
    [self.browser start];
    __weak ScanJetApp *weak=self;
    self.openTimer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *t){
        [weak finish:Failure(@"The scanner did not become ready. Close Image Capture and HP Utility, then try again.")];
    }];
}
- (void)launchWorker {
    // ImageCaptureCore failed to reconnect after stop/start in the same process
    // on the tested macOS 27 build. Keep one ICA lifetime per batch instead.
    self.worker=[NSTask new];self.worker.executableURL=NSBundle.mainBundle.executableURL;
    self.worker.arguments=@[@"--scan-worker",self.folder.path,self.duplex?@"duplex":@"simplex"];
    self.workerPipe=[NSPipe pipe];self.worker.standardOutput=self.workerPipe;
    self.worker.standardError=[NSFileHandle fileHandleWithNullDevice];
    self.workerBuffer=[NSMutableData data];self.workerResult=nil;
    self.scanStarted=YES;[self update:@"Opening scanner…"];
    __weak ScanJetApp *weak=self;
    NSFileHandle *reader=self.workerPipe.fileHandleForReading;
    reader.readabilityHandler=^(NSFileHandle *handle){
        NSData *chunk=handle.availableData;
        dispatch_async(dispatch_get_main_queue(),^{
            ScanJetApp *app=weak;if(!app)return;
            if(chunk.length){
                [app.workerBuffer appendData:chunk];
                while(YES){
                    NSRange newline=[app.workerBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0,app.workerBuffer.length)];
                    if(newline.location==NSNotFound)break;
                    NSData *line=[app.workerBuffer subdataWithRange:NSMakeRange(0,newline.location)];
                    [app.workerBuffer replaceBytesInRange:NSMakeRange(0,newline.location+1) withBytes:NULL length:0];
                    NSDictionary *event=[NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                    if([event[@"event"] isEqual:@"progress"])[app update:event[@"message"]];
                    if([event[@"event"] isEqual:@"done"])app.workerResult=event;
                }
            }else{handle.readabilityHandler=nil;[app workerFinished];}
        });
    };
    NSError *error=nil;
    if(![self.worker launchAndReturnError:&error]){
        reader.readabilityHandler=nil;self.workerResult=@{@"error":error.localizedDescription};[self workerFinished];
    }
}
- (void)workerFinished {
    if(!self.busy||self.workerMode)return;
    NSDictionary *result=self.workerResult;
    NSString *error=result[@"error"];
    if(!result)error=@"The scan process stopped unexpectedly. Any received page files remain in .scanjet-work under the save folder.";
    NSString *path=result[@"output"];
    if(path.length)self.lastOutput=[NSURL fileURLWithPath:path];
    NSString *message=error.length?error:[NSString stringWithFormat:@"Saved %@ pages — ready for a new document",result[@"pages"]?:@0];
    self.workerPipe=nil;self.worker=nil;self.workerBuffer=nil;
    self.busy=NO;self.scanStarted=NO;self.finishing=NO;self.armed=NO;
    [self update:message];[self schedulePoll:1.5];
    if(error.length){
        NSAlert *alert=[NSAlert new];alert.messageText=@"Scan needs attention";
        alert.informativeText=message;[alert addButtonWithTitle:@"OK"];
        [NSApp activateIgnoringOtherApps:YES];[alert runModal];
    }
}
- (void)deviceBrowser:(ICDeviceBrowser *)browser didAddDevice:(ICDevice *)device moreComing:(BOOL)more {
    if(self.busy&&!self.finishing&&!self.scanner&&[device isKindOfClass:ICScannerDevice.class]&&
       device.usbVendorID==0x03f0&&device.usbProductID==0x5905&&[device.name isEqualToString:@"HP ScanJet Pro 2000 s1"]){
        self.scanner=(id)device;device.delegate=self;[device requestOpenSession];
    }
}
- (void)deviceBrowser:(ICDeviceBrowser *)browser didRemoveDevice:(ICDevice *)device moreGoing:(BOOL)more {
    if(device==self.scanner&&!self.finishing)[self finish:Failure(@"The scanner was disconnected. Any received pages have been retained.")];
}
- (void)didRemoveDevice:(ICDevice *)device {if(device==self.scanner&&!self.finishing)[self finish:Failure(@"The scanner was disconnected.")];}
- (void)device:(ICDevice *)device didOpenSessionWithError:(NSError *)error {if(error)[self finish:error];}
- (void)deviceDidBecomeReady:(ICDevice *)device {
    self.deviceReady=YES;
    // ImageCaptureCore completes scanner-specific readiness after this delegate returns.
    dispatch_async(dispatch_get_main_queue(),^{[self prepareScan];});
}
- (void)scannerDevice:(ICScannerDevice *)scanner didSelectFunctionalUnit:(ICScannerFunctionalUnit *)unit error:(NSError *)error {
    if(error){[self finish:error];return;}
    self.selecting=NO;
    if(self.deviceReady)dispatch_async(dispatch_get_main_queue(),^{[self prepareScan];});
}
- (void)prepareScan {
    if(!self.busy||!self.deviceReady||self.finishing||self.scanStarted||self.selecting)return;
    ICScannerFunctionalUnit *unit=self.scanner.selectedFunctionalUnit;
    if(![unit isKindOfClass:ICScannerFunctionalUnitDocumentFeeder.class]){
        if(![self.scanner.availableFunctionalUnitTypes containsObject:@(ICScannerFunctionalUnitTypeDocumentFeeder)]){[self finish:Failure(@"The document feeder is unavailable.")];return;}
        self.selecting=YES;[self.scanner requestSelectFunctionalUnit:ICScannerFunctionalUnitTypeDocumentFeeder];return;
    }
    ICScannerFunctionalUnitDocumentFeeder *feeder=(id)unit;
    if(self.configured){[self beginAcquisitionWhenReady];return;}
    if(![unit.supportedResolutions containsIndex:300]||![feeder.supportedDocumentTypes containsIndex:ICScannerDocumentTypeUSLetter]||
       (self.duplex&&!feeder.supportsDuplexScanning)){
        [self finish:Failure(@"This scanner did not report support for the requested scan settings.")];return;
    }
    unit.measurementUnit=ICScannerMeasurementUnitInches;unit.resolution=300;
    unit.pixelDataType=ICScannerPixelDataTypeRGB;unit.bitDepth=ICScannerBitDepth8Bits;
    feeder.documentType=ICScannerDocumentTypeUSLetter;
    unit.scanArea=NSMakeRect(0,0,8.5,11);feeder.duplexScanningEnabled=self.duplex;
    feeder.oddPageOrientation=ICEXIFOrientation1;feeder.evenPageOrientation=ICEXIFOrientation1;
    self.scanner.transferMode=ICScannerTransferModeFileBased;
    self.scanner.downloadsDirectory=self.job;self.scanner.documentName=@"page";self.scanner.documentUTI=@"public.tiff";
    if(unit.resolution!=300||unit.pixelDataType!=ICScannerPixelDataTypeRGB||unit.bitDepth!=ICScannerBitDepth8Bits||feeder.duplexScanningEnabled!=self.duplex){
        [self finish:Failure(@"The driver could not apply the scan settings.")];return;
    }
    self.configured=YES;
    // Let the driver's setting changes settle before starting the acquisition.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self beginAcquisitionWhenReady];});
}
- (void)beginAcquisitionWhenReady {
    if(!self.busy||self.finishing||self.scanStarted||!self.configured)return;
    ICScannerFunctionalUnitState state=self.scanner.selectedFunctionalUnit.state;
    NSLog(@"Acquisition readiness: session=%d unitState=%lu",self.scanner.hasOpenSession,(unsigned long)state);
    if(!self.scanner.hasOpenSession||(state&ICScannerFunctionalUnitStateReady)==0){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self beginAcquisitionWhenReady];});return;
    }
    [self.openTimer invalidate];self.scanStarted=YES;[self update:@"Scanning — 0 pages received"];
    [self.scanner requestScan];
}
- (void)scannerDevice:(ICScannerDevice *)scanner didScanToURL:(NSURL *)url {
    if(!self.busy||self.finishing)return;
    PDFPage *page=PageFromImage(url);
    if(!page){self.pageError=Failure(@"A scanned page could not be read. Original files have been retained.");[scanner cancelScan];return;}
    [self.document insertPage:page atIndex:self.document.pageCount];
    [self update:[NSString stringWithFormat:@"Scanning — %lu pages received",(unsigned long)self.document.pageCount]];
}
- (void)scannerDevice:(ICScannerDevice *)scanner didCompleteScanWithError:(NSError *)error {[self finish:self.pageError?:error];}
- (void)device:(ICDevice *)device didEncounterError:(NSError *)error {
    if(!self.scanStarted)[self finish:error];else NSLog(@"Scanner reported: %@",error.localizedDescription);
}
- (void)cancel:(id)sender {
    if(!self.workerMode){if(self.worker.running){[self.worker interrupt];[self update:@"Cancelling scan…"];}return;}
    if(self.scanStarted&&!self.finishing){self.pageError=Failure(@"Scan cancelled. Any received pages are saved as an INCOMPLETE PDF.");[self.scanner cancelScan];[self update:@"Cancelling scan…"];}
}
- (void)finish:(NSError *)error {
    if(!self.busy||self.finishing)return;
    self.finishing=YES;[self.openTimer invalidate];
    NSError *saveError=nil;NSURL *output=nil;
    if(self.document.pageCount)output=SavePDF(self.document,self.job,self.jobFolder,error!=nil,&saveError);
    if(saveError)error=saveError;
    if(output){self.lastOutput=output;NSLog(@"Saved %lu pages: %@",(unsigned long)self.document.pageCount,output.lastPathComponent);}
    if(!output&&!error)error=Failure(@"No pages received. Load the feeder and try again.");
    if(output&&!error)[NSFileManager.defaultManager removeItemAtURL:self.job error:nil];
    NSString *message=error?error.localizedDescription:[NSString stringWithFormat:@"Saved %lu pages — ready for a new document",(unsigned long)self.document.pageCount];
    self.workerResult=@{@"event":@"done",@"pages":@(self.document.pageCount),@"output":output.path?:@"",@"error":error.localizedDescription?:@""};
    [self update:message];
    self.document=nil;
    if(self.scanner.hasOpenSession)[self.scanner requestCloseSession];
    else [self releaseScanner];
    if(error&&!self.workerMode){
        // An alert is reserved for a failed user-triggered scan, never idle polling.
        dispatch_async(dispatch_get_main_queue(),^{
            NSAlert *alert=[NSAlert new];alert.messageText=@"Scan needs attention";
            alert.informativeText=output?[message stringByAppendingString:@"\nThe received pages are in an INCOMPLETE PDF in your save folder."]:
                [message stringByAppendingString:@"\nAny original page files are kept in the save folder’s .scanjet-work directory."];
            [alert addButtonWithTitle:@"OK"];[NSApp activateIgnoringOtherApps:YES];[alert runModal];
        });
    }
}
- (void)device:(ICDevice *)device didCloseSessionWithError:(NSError *)error {
    if(!self.finishing){[self finish:error?:Failure(@"The scan session closed unexpectedly.")];return;}
    [self releaseScanner];
}
- (void)releaseScanner {
    [self.browser stop];self.browser.delegate=nil;self.browser=nil;self.scanner.delegate=nil;self.scanner=nil;
    self.busy=NO;self.finishing=NO;self.scanStarted=NO;self.job=nil;
    if(self.workerMode){
        [self.cancelTimer invalidate];Emit(self.workerResult?:@{@"event":@"done",@"error":@"Scanner session ended without a result."});
        [NSApp terminate:nil];return;
    }
    [self update:self.state];[self schedulePoll:1.5];
}
- (void)toggleButtons:(id)sender {
    self.buttons=!self.buttons;self.armed=NO;
    [NSUserDefaults.standardUserDefaults setBool:self.buttons forKey:@"buttons"];
    [self.pollTimer invalidate];[self update:self.buttons?@"Checking scanner…":@"Front button paused — manual scan available"];
    [self schedulePoll:0.1];
}
- (void)toggleDuplex:(id)sender {
    self.duplex=!self.duplex;[NSUserDefaults.standardUserDefaults setBool:self.duplex forKey:@"duplex"];[self update:self.state];
}
- (void)chooseFolder:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.canChooseFiles=NO;panel.canChooseDirectories=YES;
    panel.canCreateDirectories=YES;panel.allowsMultipleSelection=NO;panel.prompt=@"Save scans here";panel.directoryURL=self.folder;
    [NSApp activateIgnoringOtherApps:YES];
    if([panel runModal]==NSModalResponseOK){self.folder=panel.URL;[NSUserDefaults.standardUserDefaults setObject:self.folder.path forKey:@"folder"];[self update:self.state];}
}
- (void)openFolder:(id)sender {
    NSError *error=nil;
    if([NSFileManager.defaultManager createDirectoryAtURL:self.folder withIntermediateDirectories:YES attributes:nil error:&error])[NSWorkspace.sharedWorkspace openURL:self.folder];
}
- (void)showLast:(id)sender {if(self.lastOutput)[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[self.lastOutput]];else [self openFolder:sender];}
- (void)quit:(id)sender {if(!self.busy)[NSApp terminate:nil];}
@end

static int SelfTest(void) {
    NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
    NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error];
    PDFDocument *a=[PDFDocument new],*b=[PDFDocument new];
    [a insertPage:[PDFPage new] atIndex:0];[a insertPage:[PDFPage new] atIndex:1];[b insertPage:[PDFPage new] atIndex:0];
    NSURL *first=SavePDF(a,root,root,NO,&error),*second=SavePDF(b,root,root,NO,&error),*partial=SavePDF(b,root,root,YES,&error);
    BOOL pass=first&&second&&partial&&![first isEqual:second]&&[[PDFDocument alloc] initWithURL:first].pageCount==2&&
        [[PDFDocument alloc] initWithURL:second].pageCount==1&&[partial.lastPathComponent containsString:@"INCOMPLETE"];
    NSError *emptyError=nil;pass=pass&&SavePDF([PDFDocument new],root,root,NO,&emptyError)==nil&&emptyError!=nil;
    printf("separate_documents_and_partial_output=%s\n",pass?"PASS":"FAIL");
    if(error)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
    [fm removeItemAtURL:root error:nil];return pass?0:1;
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc==2&&strcmp(argv[1],"--self-test")==0)return SelfTest();
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    ScanJetApp *delegate=[ScanJetApp new];
    if(argc==4&&strcmp(argv[1],"--scan-worker")==0){
        delegate.workerMode=YES;delegate.folder=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        delegate.duplex=strcmp(argv[3],"duplex")==0;
    }
    NSApp.delegate=delegate;[NSApp run];return 0;
}}
