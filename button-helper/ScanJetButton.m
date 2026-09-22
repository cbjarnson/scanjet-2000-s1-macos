// Original code, MIT. Uses the installed HP ICA driver without modifying it.
#import <AppKit/AppKit.h>
#import <ImageCaptureCore/ImageCaptureCore.h>
#import <PDFKit/PDFKit.h>
#import <ImageIO/ImageIO.h>
#import "ScanOutput.h"
#import "ProcessingQueue.h"
#import "ScannerRecovery.h"
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
@property NSMutableArray<NSString *> *capturedPages;
@property NSDictionary *processing;
@property NSArray<NSButton *> *processingButtons;
@property NSTextField *processingLabel;
@property NSButton *retryButton;
@property NSTimer *queueTimer;
@property NSTask *processor;
@property NSString *format,*quality;
@property NSPopUpButton *formatPicker,*qualityPicker;
@property NSMenuItem *formatMenu,*qualityMenu;
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
@property NSTimer *stallTimer,*closeTimer;
@property NSButton *recoveryButton;
@property NSMenuItem *recoveryItem;
@property BOOL recovering,needsRecovery;
@property NSTask *recoveryTask;
@property NSTimer *recoveryTimer;
@property NSDate *recoveryDeadline;
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
    [prefs registerDefaults:@{@"duplex":@YES,@"buttons":@YES,@"format":@"pdf",@"quality":@"balanced"}];
    NSString *saved=[prefs stringForKey:@"folder"];
    self.folder=saved?[NSURL fileURLWithPath:saved isDirectory:YES]:
       [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Scans" isDirectory:YES];
    self.duplex=[prefs boolForKey:@"duplex"];self.buttons=[prefs boolForKey:@"buttons"];
    self.needsRecovery=[prefs boolForKey:@"needsRecovery"];if(self.needsRecovery)self.buttons=NO;
    self.format=SJValidFormat([prefs stringForKey:@"format"])?[prefs stringForKey:@"format"]:@"pdf";
    self.quality=SJValidQuality([prefs stringForKey:@"quality"])?[prefs stringForKey:@"quality"]:@"balanced";
    NSMutableDictionary *processing=[NSMutableDictionary new];
    for(NSString *key in @[@"blank",@"deskew",@"clean",@"ocr",@"rotate"])processing[key]=@([prefs boolForKey:key]);
    self.processing=processing;
    self.item=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.title=@"ScanJet";self.item.button.toolTip=@"ScanJet Button — fresh document per batch";
    self.menu=[NSMenu new];self.menu.autoenablesItems=NO;self.item.menu=self.menu;
    self.stateItem=[self add:@"Connecting…" action:NULL];self.stateItem.enabled=NO;
    [self add:@"Show controls…" action:@selector(showControls:)];
    self.scanItem=[self add:@"Scan a new document" action:@selector(manualScan:)];
    self.cancelItem=[self add:@"Cancel scan" action:@selector(cancel:)];
    self.recoveryItem=[self add:@"Recover after jam…" action:@selector(recoverScanner:)];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.buttonItem=[self add:@"Use front Scan button" action:@selector(toggleButtons:)];
    self.duplexItem=[self add:@"Scan both sides" action:@selector(toggleDuplex:)];
    self.formatMenu=[self add:@"Save as" action:NULL];self.formatMenu.submenu=[NSMenu new];self.formatMenu.submenu.autoenablesItems=NO;
    for(NSString *title in @[@"PDF — one document",@"JPEG — one image per side"]){
        NSMenuItem *entry=[[NSMenuItem alloc] initWithTitle:title action:@selector(changeFormat:) keyEquivalent:@""];
        entry.target=self;entry.representedObject=self.formatMenu.submenu.itemArray.count==0?@"pdf":@"jpeg";[self.formatMenu.submenu addItem:entry];
    }
    self.qualityMenu=[self add:@"File size" action:NULL];self.qualityMenu.submenu=[NSMenu new];self.qualityMenu.submenu.autoenablesItems=NO;
    NSArray *qualities=@[@"small",@"balanced",@"high"];
    for(NSString *title in @[@"Smallest",@"Balanced",@"Higher quality"]){
        NSMenuItem *entry=[[NSMenuItem alloc] initWithTitle:title action:@selector(changeQuality:) keyEquivalent:@""];
        entry.target=self;entry.representedObject=qualities[self.qualityMenu.submenu.itemArray.count];[self.qualityMenu.submenu addItem:entry];
    }
    NSMenuItem *quality=[self add:@"Color · 300 dpi · US Letter" action:NULL];quality.enabled=NO;
    [self.menu addItem:NSMenuItem.separatorItem];
    self.folderItem=[self add:@"" action:NULL];self.folderItem.enabled=NO;
    [self add:@"Choose save folder…" action:@selector(chooseFolder:)];
    [self add:@"Open save folder" action:@selector(openFolder:)];
    [self add:@"Show latest scan" action:@selector(showLast:)];
    [self add:@"Show original scans" action:@selector(showOriginals:)];
    [self.menu addItem:NSMenuItem.separatorItem];
    self.quitItem=[self add:@"Quit ScanJet Button" action:@selector(quit:)];
    [self buildWindow];
    __weak ScanJetApp *weak=self;
    self.queueTimer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){[weak refreshQueue];}];
    [NSRunLoop.mainRunLoop addTimer:self.queueTimer forMode:NSRunLoopCommonModes];
    [self refreshQueue];
    [self update:self.needsRecovery?@"Scanner needs recovery — use Recover after jam":(self.buttons?@"Checking scanner…":@"Front button paused — manual scan available")];[self schedulePoll:0.1];[self showControls:nil];
}
- (void)buildWindow {
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,500,700)
         styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"ScanJet Button";self.window.releasedWhenClosed=NO;[self.window center];
    NSView *view=self.window.contentView;
    NSTextField *title=[NSTextField labelWithString:@"A fresh scan with each press"];
    title.font=[NSFont boldSystemFontOfSize:20];title.frame=NSMakeRect(24,645,452,30);[view addSubview:title];
    NSTextField *subtitle=[NSTextField wrappingLabelWithString:@"Load your pages, then press the scanner’s front Scan button. You can close this window; ScanJet stays in the menu bar."];
    subtitle.frame=NSMakeRect(24,593,452,46);[view addSubview:subtitle];
    self.statusLabel=[NSTextField wrappingLabelWithString:@"Checking scanner…"];
    self.statusLabel.font=[NSFont boldSystemFontOfSize:13];self.statusLabel.frame=NSMakeRect(24,553,452,32);[view addSubview:self.statusLabel];
    self.listenButton=[NSButton checkboxWithTitle:@"Use front Scan button" target:self action:@selector(toggleButtons:)];
    self.listenButton.frame=NSMakeRect(24,517,225,24);[view addSubview:self.listenButton];
    self.duplexButton=[NSButton checkboxWithTitle:@"Scan both sides" target:self action:@selector(toggleDuplex:)];
    self.duplexButton.frame=NSMakeRect(275,517,200,24);[view addSubview:self.duplexButton];
    NSTextField *formatLabel=[NSTextField labelWithString:@"Save as"];formatLabel.frame=NSMakeRect(24,478,90,22);[view addSubview:formatLabel];
    self.formatPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(116,474,358,28) pullsDown:NO];
    [self.formatPicker addItemsWithTitles:@[@"PDF — one document",@"JPEG — one image per side"]];
    self.formatPicker.target=self;self.formatPicker.action=@selector(changeFormat:);[view addSubview:self.formatPicker];
    NSTextField *sizeLabel=[NSTextField labelWithString:@"File size"];sizeLabel.frame=NSMakeRect(24,438,90,22);[view addSubview:sizeLabel];
    self.qualityPicker=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(116,434,358,28) pullsDown:NO];
    [self.qualityPicker addItemsWithTitles:@[@"Smallest",@"Balanced (recommended)",@"Higher quality"]];
    self.qualityPicker.target=self;self.qualityPicker.action=@selector(changeQuality:);[view addSubview:self.qualityPicker];
    NSTextField *hint=[NSTextField wrappingLabelWithString:@"All sizes keep 300 dpi. Smaller files use stronger compression. JPEG saves numbered images in a new folder for each batch."];
    hint.textColor=NSColor.secondaryLabelColor;hint.font=[NSFont systemFontOfSize:11];hint.frame=NSMakeRect(24,385,452,40);[view addSubview:hint];
    NSTextField *heading=[NSTextField labelWithString:@"After scanning — in the background"];
    heading.font=[NSFont boldSystemFontOfSize:13];heading.frame=NSMakeRect(24,356,452,22);[view addSubview:heading];
    NSArray *titles=@[@"Remove blank pages",@"Straighten pages (deskew)",@"Clean specks and noise",@"Searchable PDF (OCR)",@"Auto-rotate PDF pages"];
    NSArray *keys=@[@"blank",@"deskew",@"clean",@"ocr",@"rotate"];
    NSMutableArray *buttons=[NSMutableArray new];
    for(NSUInteger i=0;i<titles.count;i++){
        NSButton *button=[NSButton checkboxWithTitle:titles[i] target:self action:@selector(changeProcessing:)];
        button.identifier=keys[i];button.frame=NSMakeRect(i==3||i==4?267:24,i==0?327:(i==1||i==4?297:267),225,24);
        [view addSubview:button];[buttons addObject:button];
    }
    self.processingButtons=buttons;
    NSTextField *processingHint=[NSTextField wrappingLabelWithString:@"Originals are kept in Original scans. Review cleaned pages for faint marks. Deskew, cleanup, rotation and OCR apply to PDFs; OCR uses English."];
    processingHint.font=[NSFont systemFontOfSize:11];processingHint.textColor=NSColor.secondaryLabelColor;
    processingHint.frame=NSMakeRect(24,217,452,42);[view addSubview:processingHint];
    self.processingLabel=[NSTextField wrappingLabelWithString:@"Processing queue is empty"];
    self.processingLabel.frame=NSMakeRect(24,177,452,36);[view addSubview:self.processingLabel];
    self.retryButton=[NSButton buttonWithTitle:@"Retry processing" target:self action:@selector(retryProcessing:)];
    self.retryButton.frame=NSMakeRect(18,142,155,30);[view addSubview:self.retryButton];
    NSButton *originals=[NSButton buttonWithTitle:@"Original scans" target:self action:@selector(showOriginals:)];
    originals.frame=NSMakeRect(177,142,145,30);[view addSubview:originals];
    self.folderLabel=[NSTextField labelWithString:@""];self.folderLabel.frame=NSMakeRect(24,121,452,22);
    self.folderLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;[view addSubview:self.folderLabel];
    NSButton *choose=[NSButton buttonWithTitle:@"Choose folder…" target:self action:@selector(chooseFolder:)];
    choose.frame=NSMakeRect(18,82,145,32);[view addSubview:choose];
    NSButton *show=[NSButton buttonWithTitle:@"Open folder" target:self action:@selector(openFolder:)];
    show.frame=NSMakeRect(162,82,125,32);[view addSubview:show];
    self.recoveryButton=[NSButton buttonWithTitle:@"Recover after jam…" target:self action:@selector(recoverScanner:)];
    self.recoveryButton.frame=NSMakeRect(300,82,180,32);
    self.recoveryButton.toolTip=@"Stop a stalled capture, reconnect this scanner's USB connection, and check readiness. OCR and queued files keep running.";
    [view addSubview:self.recoveryButton];
    self.scanButton=[NSButton buttonWithTitle:@"Scan new document" target:self action:@selector(manualScan:)];
    self.scanButton.frame=NSMakeRect(284,24,192,34);[view addSubview:self.scanButton];
    self.cancelButton=[NSButton buttonWithTitle:@"Cancel scan" target:self action:@selector(cancel:)];
    self.cancelButton.frame=NSMakeRect(18,24,135,34);[view addSubview:self.cancelButton];
}
- (void)showControls:(id)sender {[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {[self showControls:nil];return YES;}
- (void)update:(NSString *)text {
    if(self.recovering&&!self.workerMode)text=@"Recovering scanner connection…";
    self.state=text;self.stateItem.title=text;
    BOOL available=!self.busy&&!self.recovering;
    self.item.button.title=self.busy?@"ScanJet • Scanning":@"ScanJet";
    self.scanItem.enabled=available&&!self.needsRecovery;self.cancelItem.enabled=self.busy&&self.scanStarted&&!self.finishing;
    self.duplexItem.enabled=available;self.buttonItem.enabled=available&&!self.needsRecovery;self.quitItem.enabled=available;
    self.recoveryButton.enabled=!self.recovering;self.recoveryItem.enabled=!self.recovering;
    self.duplexItem.state=self.duplex?NSControlStateValueOn:NSControlStateValueOff;
    self.buttonItem.state=self.buttons?NSControlStateValueOn:NSControlStateValueOff;
    self.folderItem.title=[NSString stringWithFormat:@"Save to: %@",self.folder.path.stringByAbbreviatingWithTildeInPath];
    self.statusLabel.stringValue=text;self.folderLabel.stringValue=self.folderItem.title;
    self.scanButton.enabled=self.scanItem.enabled;self.cancelButton.enabled=self.cancelItem.enabled;
    self.listenButton.enabled=self.buttonItem.enabled;self.duplexButton.enabled=available;
    self.listenButton.state=self.buttonItem.state;self.duplexButton.state=self.duplexItem.state;
    [self.formatPicker selectItemAtIndex:[self.format isEqual:@"jpeg"]?1:0];
    [self.qualityPicker selectItemAtIndex:[@[@"small",@"balanced",@"high"] indexOfObject:self.quality]];
    self.formatPicker.enabled=!self.busy;self.qualityPicker.enabled=!self.busy;
    self.formatMenu.enabled=!self.busy;self.qualityMenu.enabled=!self.busy;
    for(NSMenuItem *entry in self.formatMenu.submenu.itemArray){entry.state=[entry.representedObject isEqual:self.format]?NSControlStateValueOn:NSControlStateValueOff;entry.enabled=!self.busy;}
    for(NSMenuItem *entry in self.qualityMenu.submenu.itemArray){entry.state=[entry.representedObject isEqual:self.quality]?NSControlStateValueOn:NSControlStateValueOff;entry.enabled=!self.busy;}
    for(NSButton *button in self.processingButtons){
        button.state=[self.processing[button.identifier] boolValue]?NSControlStateValueOn:NSControlStateValueOff;
        button.enabled=!self.busy&&([button.identifier isEqual:@"blank"]||[self.format isEqual:@"pdf"]);
    }
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
            if(value<0){self.armed=NO;if(![self.state hasPrefix:@"Scanner unavailable"])[self update:@"Scanner unavailable — use Recover after jam"];}
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
    if(self.busy||(!self.workerMode&&(self.recovering||self.needsRecovery)))return;
    self.busy=YES;self.armed=NO;self.scanStarted=NO;self.finishing=NO;self.selecting=NO;self.deviceReady=NO;self.configured=NO;self.pageError=nil;
    [self.pollTimer invalidate];[self update:@"Opening scanner…"];
    // Serialize manual clicks with a USB poll that may still be returning.
    [self openWhenUSBReleased];
}
- (void)openWhenUSBReleased {
    // Recovery can be clicked while a manual scan is waiting for a USB poll.
    // Cancel that pending launch so recovery never starts a new acquisition.
    if(!self.workerMode&&self.recovering){self.busy=NO;self.scanStarted=NO;return;}
    if(self.polling){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self openWhenUSBReleased];});return;}
    if(!self.workerMode){[self launchWorker];return;}
    NSError *error=nil;NSFileManager *fm=NSFileManager.defaultManager;
    self.jobFolder=self.folder;
    if(![fm createDirectoryAtURL:self.jobFolder withIntermediateDirectories:YES attributes:nil error:&error]){[self finish:error];return;}
    NSURL *work=[self.jobFolder URLByAppendingPathComponent:@".scanjet-work" isDirectory:YES];
    self.job=[work URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    if(![fm createDirectoryAtURL:self.job withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){[self finish:error];return;}
    self.capturedPages=[NSMutableArray new];
    self.browser=[ICDeviceBrowser new];self.browser.delegate=self;
    self.browser.browsedDeviceTypeMask=(ICDeviceTypeMask)(ICDeviceTypeMaskScanner|ICDeviceLocationTypeMaskLocal);
    [self.browser start];
    __weak ScanJetApp *weak=self;
    self.openTimer=[NSTimer scheduledTimerWithTimeInterval:30 repeats:NO block:^(NSTimer *t){
        [weak finish:Failure(@"The scanner did not become ready. Clear any jam, close both sides of the feeder cover, then use Recover after jam. Close other scanner apps if they are open.")];
    }];
}
- (void)launchWorker {
    // ImageCaptureCore failed to reconnect after stop/start in the same process
    // on the tested macOS 27 build. Keep one ICA lifetime per batch instead.
    self.worker=[NSTask new];self.worker.executableURL=NSBundle.mainBundle.executableURL;
    NSString *settings=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:self.processing options:0 error:nil] encoding:NSUTF8StringEncoding];
    self.worker.arguments=@[@"--scan-worker",self.folder.path,self.duplex?@"duplex":@"simplex",self.format,self.quality,settings];
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
    NSString *message=error.length?error:[NSString stringWithFormat:@"Captured %@ pages — ready for the next scan",result[@"pages"]?:@0];
    self.workerPipe=nil;self.worker=nil;self.workerBuffer=nil;
    self.busy=NO;self.scanStarted=NO;self.finishing=NO;self.armed=NO;
    if(error.length){self.needsRecovery=YES;self.buttons=NO;[NSUserDefaults.standardUserDefaults setBool:YES forKey:@"needsRecovery"];}
    [self update:message];[self schedulePoll:1.5];[self refreshQueue];
    if(error.length&&!self.recovering){
        NSAlert *alert=[NSAlert new];alert.messageText=@"Scan needs attention";
        alert.informativeText=message;[alert addButtonWithTitle:@"Recover after jam"];[alert addButtonWithTitle:@"Later"];
        [NSApp activateIgnoringOtherApps:YES];if([alert runModal]==NSAlertFirstButtonReturn)[self recoverScanner:nil];
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
    [self resetStallTimer];
    [self.scanner requestScan];
}
- (void)resetStallTimer {
    [self.stallTimer invalidate];__weak ScanJetApp *weak=self;
    self.stallTimer=[NSTimer scheduledTimerWithTimeInterval:120 repeats:NO block:^(NSTimer *timer){
        ScanJetApp *app=weak;
        if(app.busy&&!app.finishing){[app.scanner cancelScan];[app finish:Failure(@"No page arrived for two minutes. Check for a paper jam and close the feeder cover. Received pages are retained.")];}
    }];
}
- (void)scannerDevice:(ICScannerDevice *)scanner didScanToURL:(NSURL *)url {
    if(!self.busy||self.finishing)return;
    [self resetStallTimer];
    [self.capturedPages addObject:url.path];
    [self update:[NSString stringWithFormat:@"Scanning — %lu pages received",(unsigned long)self.capturedPages.count]];
}
- (void)scannerDevice:(ICScannerDevice *)scanner didCompleteScanWithError:(NSError *)error {[self finish:self.pageError?:error];}
- (void)device:(ICDevice *)device didEncounterError:(NSError *)error {
    if(error&&!self.finishing){if(self.scanStarted)[self.scanner cancelScan];[self finish:error];}
}
- (void)cancel:(id)sender {
    if(!self.workerMode){if(self.worker.running){[self.worker interrupt];[self update:@"Cancelling scan…"];}return;}
    if(self.scanStarted&&!self.finishing){self.pageError=Failure(@"Scan cancelled. Any received pages are saved with INCOMPLETE in the name.");[self.scanner cancelScan];[self finish:self.pageError];}
}
- (void)finish:(NSError *)error {
    if(!self.busy||self.finishing)return;
    self.finishing=YES;[self.openTimer invalidate];[self.stallTimer invalidate];
    NSError *queueError=nil;NSURL *manifest=nil;
    if(self.capturedPages.count){
        NSMutableDictionary *settings=[self.processing mutableCopy];settings[@"format"]=self.format;settings[@"quality"]=self.quality;
        manifest=SJEnqueueScan(self.job,self.jobFolder,self.capturedPages,settings,error.localizedDescription,&queueError);
    }
    if(queueError)error=queueError;
    if(!manifest&&!error)error=Failure(@"No pages received. Load the feeder and try again.");
    self.workerResult=@{@"event":@"done",@"pages":@(self.capturedPages.count),@"queued":manifest.path?:@"",@"error":error.localizedDescription?:@""};
    [self update:error?error.localizedDescription:@"Pages queued — releasing scanner"];
    if(self.scanner.hasOpenSession){
        __weak ScanJetApp *weak=self;
        self.closeTimer=[NSTimer scheduledTimerWithTimeInterval:6 repeats:NO block:^(NSTimer *timer){
            ScanJetApp *app=weak;if(!app.finishing)return;
            NSMutableDictionary *result=[app.workerResult mutableCopy];
            if(![result[@"error"] length])result[@"error"]=@"The scanner did not close its session. Restart it before scanning again; captured pages remain queued.";
            app.workerResult=result;[app releaseScanner];
        }];
        [self.scanner requestCloseSession];
    }else [self releaseScanner];
}
- (void)device:(ICDevice *)device didCloseSessionWithError:(NSError *)error {
    if(!self.finishing){[self finish:error?:Failure(@"The scan session closed unexpectedly.")];return;}
    [self releaseScanner];
}
- (void)releaseScanner {
    [self.closeTimer invalidate];[self.stallTimer invalidate];
    [self.browser stop];self.browser.delegate=nil;self.browser=nil;self.scanner.delegate=nil;self.scanner=nil;
    self.busy=NO;self.finishing=NO;self.scanStarted=NO;self.job=nil;
    if(self.workerMode){
        [self.cancelTimer invalidate];Emit(self.workerResult?:@{@"event":@"done",@"error":@"Scanner session ended without a result."});
        [NSApp terminate:nil];return;
    }
    [self update:self.state];[self schedulePoll:1.5];
}
- (void)toggleButtons:(id)sender {
    if(self.recovering||self.needsRecovery)return;
    self.buttons=!self.buttons;self.armed=NO;
    [NSUserDefaults.standardUserDefaults setBool:self.buttons forKey:@"buttons"];
    [self.pollTimer invalidate];[self update:self.buttons?@"Checking scanner…":@"Front button paused — manual scan available"];
    [self schedulePoll:0.1];
}
- (void)toggleDuplex:(id)sender {
    self.duplex=!self.duplex;[NSUserDefaults.standardUserDefaults setBool:self.duplex forKey:@"duplex"];[self update:self.state];
}
- (void)changeFormat:(id)sender {
    if(self.busy)return;
    self.format=[sender isKindOfClass:NSMenuItem.class]?[(NSMenuItem *)sender representedObject]: (self.formatPicker.indexOfSelectedItem==1?@"jpeg":@"pdf");
    [NSUserDefaults.standardUserDefaults setObject:self.format forKey:@"format"];[self update:self.state];
}
- (void)changeQuality:(id)sender {
    if(self.busy)return;
    self.quality=[sender isKindOfClass:NSMenuItem.class]?[(NSMenuItem *)sender representedObject]:@[@"small",@"balanced",@"high"][self.qualityPicker.indexOfSelectedItem];
    [NSUserDefaults.standardUserDefaults setObject:self.quality forKey:@"quality"];[self update:self.state];
}
- (void)recoverScanner:(id)sender {
    if(self.recovering)return;
    self.recovering=YES;self.needsRecovery=YES;self.buttons=NO;self.armed=NO;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"needsRecovery"];
    [self.pollTimer invalidate];[self update:@"Recovering scanner connection…"];
    if(self.worker.running)[self.worker interrupt];
    self.recoveryDeadline=[NSDate dateWithTimeIntervalSinceNow:12];[self recoverWhenIdle];
}
- (void)recoverWhenIdle {
    if(!self.recovering)return;
    if(self.busy||self.polling){
        if(self.recoveryDeadline.timeIntervalSinceNow<=0){
            if(self.worker.running)kill(self.worker.processIdentifier,SIGKILL);
            [self recoveryFinished:@{@"ok":@NO,@"message":@"The old scan did not close. Any raw pages are retained. Press Recover after jam again after the capture has stopped."}];return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self recoverWhenIdle];});return;
    }
    NSTask *task=[NSTask new];self.recoveryTask=task;task.executableURL=NSBundle.mainBundle.executableURL;task.arguments=@[@"--recover-scanner"];
    NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;task.standardError=[NSFileHandle fileHandleWithNullDevice];
    __weak ScanJetApp *weak=self;
    task.terminationHandler=^(NSTask *finished){
        NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];
        id result=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if(![result isKindOfClass:NSDictionary.class])result=@{@"ok":@NO,@"message":@"Recovery could not finish. Unplug scanner power and USB for 30 seconds, reconnect, then try recovery again."};
        dispatch_async(dispatch_get_main_queue(),^{ScanJetApp *app=weak;if(app.recoveryTask==finished)[app recoveryFinished:result];});
    };
    NSError *error=nil;
    if(![task launchAndReturnError:&error]){task.terminationHandler=nil;[self recoveryFinished:@{@"ok":@NO,@"message":error.localizedDescription}];return;}
    self.recoveryTimer=[NSTimer scheduledTimerWithTimeInterval:45 repeats:NO block:^(NSTimer *timer){
        if(task.running)[task terminate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{if(task.running)kill(task.processIdentifier,SIGKILL);});
    }];
}
- (void)recoveryFinished:(NSDictionary *)result {
    [self.recoveryTimer invalidate];self.recoveryTask=nil;self.recovering=NO;
    BOOL ok=[result[@"ok"] boolValue];self.needsRecovery=!ok;
    [NSUserDefaults.standardUserDefaults setBool:!ok forKey:@"needsRecovery"];
    self.buttons=ok&&[NSUserDefaults.standardUserDefaults boolForKey:@"buttons"];self.armed=NO;
    [self update:ok?@"Connection ready — check the red light before scanning":@"Recovery needs attention — scanner remains paused"];
    if(ok)[self schedulePoll:1.5];
    else {
        NSAlert *alert=[NSAlert new];alert.messageText=@"Scanner recovery";alert.informativeText=result[@"message"]?:@"The scanner did not become ready.";
        [alert addButtonWithTitle:@"OK"];[NSApp activateIgnoringOtherApps:YES];[alert runModal];
    }
}
- (void)changeProcessing:(NSButton *)sender {
    if(self.busy)return;
    NSMutableDictionary *settings=[self.processing mutableCopy];settings[sender.identifier]=@(sender.state==NSControlStateValueOn);self.processing=settings;
    [NSUserDefaults.standardUserDefaults setBool:[settings[sender.identifier] boolValue] forKey:sender.identifier];[self update:self.state];
}
- (void)refreshQueue {
    if(self.workerMode)return;
    NSArray *jobs=SJQueueJobs();NSUInteger pending=0,failed=0;NSDictionary *next=nil,*latest=nil,*failure=nil;
    for(NSDictionary *job in jobs){
        NSString *state=job[@"state"];
        if([state isEqual:@"queued"]||[state isEqual:@"processing"]){pending++;if(!next)next=job;}
        if([state isEqual:@"failed"]){failed++;failure=job;}
        if([state isEqual:@"done"])latest=job;
    }
    if(latest[@"output"])self.lastOutput=[NSURL fileURLWithPath:latest[@"output"]];
    self.retryButton.enabled=failed>0;
    if(pending)self.processingLabel.stringValue=[NSString stringWithFormat:@"%lu batch%@ processing or waiting. You can scan again.%@",(unsigned long)pending,pending==1?@"":@"es",failed?@" Some batches need retry.":@""];
    else if(failed)self.processingLabel.stringValue=[NSString stringWithFormat:@"%lu batch%@ need retry. %@",(unsigned long)failed,failed==1?@"":@"es",failure[@"error"]?:@"Originals are retained."];
    else if(latest)self.processingLabel.stringValue=[NSString stringWithFormat:@"Latest: %@ pages saved, %lu blank removed.%@",latest[@"outputPages"]?:@0,(unsigned long)[latest[@"removedPages"] count],latest[@"notice"]?@" Review this batch.":@""];
    else self.processingLabel.stringValue=@"Processing queue is empty. New scans process in the background.";
    self.processingLabel.toolTip=self.processingLabel.stringValue;
    if(next&&!self.processor.running&&SJQueueAvailable()){
        self.processor=[NSTask new];self.processor.executableURL=NSBundle.mainBundle.executableURL;
        self.processor.arguments=@[@"--process-job",next[@"manifest"]];
        self.processor.standardOutput=[NSFileHandle fileHandleWithNullDevice];self.processor.standardError=[NSFileHandle fileHandleWithNullDevice];
        NSError *error=nil;if(![self.processor launchAndReturnError:&error])self.processingLabel.stringValue=error.localizedDescription;
    }
}
- (void)retryProcessing:(id)sender {SJRetryFailedJobs();[self refreshQueue];}
- (void)showOriginals:(id)sender {
    NSURL *folder=[self.folder URLByAppendingPathComponent:@"Original scans"];
    if([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil])
        [NSWorkspace.sharedWorkspace openURL:folder];
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

int main(int argc,const char **argv) {@autoreleasepool {
    if(argc==2&&strcmp(argv[1],"--self-test")==0)return SJOutputSelfTest()|SJRecoverySelfTest();
    if(argc==2&&strcmp(argv[1],"--recover-scanner")==0)return SJRecoverScanner();
    if(argc==3&&strcmp(argv[1],"--process-job")==0)return SJProcessJob([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]]);
    if(argc>1&&(argc!=7||strcmp(argv[1],"--scan-worker")!=0))return 2;
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    ScanJetApp *delegate=[ScanJetApp new];
    if(argc==7&&strcmp(argv[1],"--scan-worker")==0){
        delegate.workerMode=YES;delegate.folder=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]] isDirectory:YES];
        delegate.duplex=strcmp(argv[3],"duplex")==0;
        delegate.format=[NSString stringWithUTF8String:argv[4]];delegate.quality=[NSString stringWithUTF8String:argv[5]];
        NSData *settings=[[NSString stringWithUTF8String:argv[6]] dataUsingEncoding:NSUTF8StringEncoding];
        delegate.processing=[NSJSONSerialization JSONObjectWithData:settings options:0 error:nil];
        if(![delegate.processing isKindOfClass:NSDictionary.class]||!SJValidFormat(delegate.format)||!SJValidQuality(delegate.quality))return 2;
    }
    NSApp.delegate=delegate;[NSApp run];return 0;
}}
