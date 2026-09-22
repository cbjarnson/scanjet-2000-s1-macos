// Original code, MIT. No HP firmware, calibration, motor, or vendor commands.
#import "ScannerRecovery.h"
#import <AppKit/AppKit.h>
#import <ImageCaptureCore/ImageCaptureCore.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>

static const char *DriverPath="/Library/Image Capture/Devices/HP Scanner 4.app/Contents/MacOS/HP Scanner 4";
static BOOL IsDriver(const char *path,uid_t owner,uid_t user) {return owner==user&&strcmp(path,DriverPath)==0;}
static BOOL MatchesDriver(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE]={0};struct proc_bsdinfo info={0};
    return proc_pidpath(pid,path,sizeof(path))>0&&proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)&&IsDriver(path,info.pbi_uid,getuid());
}
static NSString *StopIdleDriver(void) {
    for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications){
        NSString *path=app.bundleURL.path;
        if([path isEqual:@"/System/Applications/Image Capture.app"]||[path isEqual:@"/Library/Printers/hp/Utilities/HP Utility.app"])
            return @"Close Image Capture and HP Utility, then press Recover after jam again. Any unsaved work in those apps is left alone.";
    }
    int count=proc_listallpids(NULL,0);if(count<=0)return @"Could not inspect the scanner service.";
    NSMutableData *storage=[NSMutableData dataWithLength:(count+64)*sizeof(pid_t)];
    int length=proc_listallpids(storage.mutableBytes,(int)storage.length);pid_t *pids=storage.mutableBytes;
    for(int i=0;i<MIN(length,(int)storage.length/(int)sizeof(pid_t));i++){
        pid_t pid=pids[i];if(!MatchesDriver(pid))continue;
        if(kill(pid,SIGTERM)!=0)return @"Could not stop the old scanner session. Close other scanner apps and retry.";
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
        while(MatchesDriver(pid)&&deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:0.1];
        // Match path and owner again immediately before affecting a PID.
        if(MatchesDriver(pid)&&kill(pid,SIGKILL)!=0)return @"The old scanner session could not be released.";
    }
    return nil;
}
static int Number(io_service_t service,CFStringRef key) {
    CFTypeRef value=IORegistryEntryCreateCFProperty(service,key,kCFAllocatorDefault,0);int n=-1;
    if(value&&CFGetTypeID(value)==CFNumberGetTypeID())CFNumberGetValue(value,kCFNumberIntType,&n);
    if(value)CFRelease(value);return n;
}
static BOOL IsScanner(io_service_t service) {return Number(service,CFSTR("idVendor"))==0x03f0&&Number(service,CFSTR("idProduct"))==0x5905;}
static NSString *ReconnectUSB(void) {
    io_iterator_t devices=0;IOReturn result=IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&devices);
    if(result)return @"USB devices could not be inspected.";
    io_service_t service;int count=0;
    while((service=IOIteratorNext(devices))){if(IsScanner(service))count++;IOObjectRelease(service);}
    IOIteratorReset(devices);
    if(count!=1){IOObjectRelease(devices);return count?@"Connect only one ScanJet 2000 s1 before recovery.":@"Scanner not connected. Check power and USB, then press Recover after jam again.";}
    IOUSBDeviceInterface187 **device=NULL;
    while((service=IOIteratorNext(devices))){
        if(!IsScanner(service)){IOObjectRelease(service);continue;}
        IOCFPlugInInterface **plugin=NULL;SInt32 score=0;
        result=IOCreatePlugInInterfaceForService(service,kIOUSBDeviceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);IOObjectRelease(service);
        if(!result&&plugin){(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID187),(LPVOID)&device);(*plugin)->Release(plugin);}break;
    }
    IOObjectRelease(devices);
    if(!device)return @"Could not open the scanner USB connection.";
    result=(*device)->USBDeviceOpen(device); // Normal exclusive open; never seize.
    if(result){(*device)->Release(device);return @"The scanner USB connection is busy. Close other scanner apps and retry.";}
    // Apple's documented software unplug/replug. Zero options: no capture bit,
    // root privileges, firmware changes, or effects on other USB devices.
    result=(*device)->USBDeviceReEnumerate(device,0);
    (*device)->USBDeviceClose(device);(*device)->Release(device);
    if(result)return [NSString stringWithFormat:@"USB reconnect failed (0x%08x). Unplug the scanner's power and USB for 30 seconds, reconnect, and retry.",result];
    return nil;
}

@interface RecoveryProbe : NSObject <ICDeviceBrowserDelegate,ICScannerDeviceDelegate>
@property ICScannerDevice *scanner;
@property BOOL deviceReady,ready,closing,closed,done;
@property NSString *failure;
@end
@implementation RecoveryProbe
- (void)deviceBrowser:(ICDeviceBrowser *)browser didAddDevice:(ICDevice *)device moreComing:(BOOL)more {
    if(!self.scanner&&device.usbVendorID==0x03f0&&device.usbProductID==0x5905&&[device isKindOfClass:ICScannerDevice.class]){
        self.scanner=(id)device;device.delegate=self;[device requestOpenSession];
    }
}
- (void)deviceBrowser:(ICDeviceBrowser *)browser didRemoveDevice:(ICDevice *)device moreGoing:(BOOL)more {if(device==self.scanner)[self didRemoveDevice:device];}
- (void)didRemoveDevice:(ICDevice *)device {if(!self.done){self.failure=@"Scanner disconnected during recovery.";self.done=YES;}}
- (void)device:(ICDevice *)device didOpenSessionWithError:(NSError *)error {if(error){self.failure=error.localizedDescription;self.done=YES;}}
- (void)deviceDidBecomeReady:(ICDevice *)device {self.deviceReady=YES;}
- (void)scannerDevice:(ICScannerDevice *)scanner didSelectFunctionalUnit:(ICScannerFunctionalUnit *)unit error:(NSError *)error {if(error){self.failure=error.localizedDescription;self.done=YES;}}
- (void)device:(ICDevice *)device didEncounterError:(NSError *)error {if(error&&!self.done){self.failure=error.localizedDescription;self.done=YES;}}
- (void)device:(ICDevice *)device didCloseSessionWithError:(NSError *)error {
    if(error)self.failure=error.localizedDescription;
    self.closed=error==nil;self.done=YES;
}
@end
static NSString *CheckReadiness(void) {
    RecoveryProbe *probe=[RecoveryProbe new];ICDeviceBrowser *browser=[ICDeviceBrowser new];browser.delegate=probe;
    browser.browsedDeviceTypeMask=(ICDeviceTypeMask)(ICDeviceTypeMaskScanner|ICDeviceLocationTypeMaskLocal);[browser start];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];BOOL selecting=NO;
    while(!probe.done&&deadline.timeIntervalSinceNow>0){
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        ICScannerFunctionalUnit *unit=probe.scanner.selectedFunctionalUnit;
        if(probe.deviceReady&&!probe.closing){
            if(unit.type!=ICScannerFunctionalUnitTypeDocumentFeeder&&!selecting&&[probe.scanner.availableFunctionalUnitTypes containsObject:@(ICScannerFunctionalUnitTypeDocumentFeeder)]){
                selecting=YES;[probe.scanner requestSelectFunctionalUnit:ICScannerFunctionalUnitTypeDocumentFeeder];
            }
            if(unit.type==ICScannerFunctionalUnitTypeDocumentFeeder&&probe.scanner.hasOpenSession&&(unit.state&ICScannerFunctionalUnitStateReady)){
                probe.ready=YES;probe.closing=YES;deadline=[NSDate dateWithTimeIntervalSinceNow:6];[probe.scanner requestCloseSession];
            }
        }
    }
    BOOL success=probe.ready&&probe.closed&&!probe.failure;
    NSString *failure=probe.failure?:@"The scanner is still not ready. Remove paper scraps and latch both sides of the cover. Unplug power and USB for 30 seconds, reconnect, and retry. If the light blinks with power only, the scanner needs physical attention.";
    // Closing discovery intentionally removes devices; do not report a new fault.
    probe.done=YES;probe.scanner.delegate=nil;browser.delegate=nil;
    if(probe.scanner.hasOpenSession)[probe.scanner requestCloseSession];[browser stop];
    return success?nil:failure;
}
int SJRecoverScanner(void) {@autoreleasepool {
    NSString *failure=StopIdleDriver();BOOL reconnected=NO;
    if(!failure){failure=ReconnectUSB();reconnected=failure==nil;}
    if(!failure){[NSThread sleepForTimeInterval:3];failure=CheckReadiness();}
    NSDictionary *result=@{@"ok":@(failure==nil),@"usbReconnected":@(reconnected),@"message":failure?:@"Scanner connection is ready. Check that the red light is off before scanning."};
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);return failure?1:0;
}}
int SJRecoverySelfTest(void) {
    BOOL pass=IsDriver(DriverPath,501,501)&&!IsDriver(DriverPath,0,501)&&
        !IsDriver("/Library/Image Capture/Devices/HP Scanner 3.app/Contents/MacOS/HP Scanner 3",501,501)&&
        !IsDriver("/tmp/HP Scanner 4",501,501)&&!IsDriver("/usr/bin/python3",501,501);
    printf("recovery_process_scope=%s\n",pass?"PASS":"FAIL");return pass?0:1;
}
