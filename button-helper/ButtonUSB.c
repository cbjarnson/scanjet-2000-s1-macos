// Original code, MIT. Exact device only: HP 03f0:5905.
// Reproduces HP's GetButtonInput -> FSIReadSensorButtonStatus -> USBRW query.
// 8-byte header, selector 0, then 16-byte status and 4-byte button data.
// Reading acknowledges the button; no scan, reset, firmware or calibration commands.
// Standard opens only. Never seize USB from an existing scanner session.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
static int number(io_service_t service,CFStringRef key){
 CFTypeRef value=IORegistryEntryCreateCFProperty(service,key,kCFAllocatorDefault,0);int n=-1;
 if(value&&CFGetTypeID(value)==CFNumberGetTypeID())CFNumberGetValue(value,kCFNumberIntType,&n);
 if(value)CFRelease(value);return n;
}
int sj_read_button(void){
 io_iterator_t devices=0;IOUSBDeviceInterface **dev=NULL;IOUSBInterfaceInterface182 **iface=NULL;UInt8 pipe=0, bulkIn=0, bulkOut=0;
 IOReturn result=IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOUSBHostDevice"),&devices);
 if(result)return -1;
 io_service_t service; int matchingCount=0;
 while((service=IOIteratorNext(devices))){
  if(number(service,CFSTR("idVendor"))==0x03f0&&number(service,CFSTR("idProduct"))==0x5905)matchingCount++;
  IOObjectRelease(service);
 }
 IOIteratorReset(devices);
 if(matchingCount!=1){IOObjectRelease(devices);return -1;}
 while((service=IOIteratorNext(devices))){
  if(number(service,CFSTR("idVendor"))!=0x03f0||number(service,CFSTR("idProduct"))!=0x5905){IOObjectRelease(service);continue;}
  IOCFPlugInInterface **plugin=NULL;SInt32 score=0;
  result=IOCreatePlugInInterfaceForService(service,kIOUSBDeviceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);
  IOObjectRelease(service);
  if(!result&&plugin){(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),(LPVOID)&dev);(*plugin)->Release(plugin);}
  break;
 }
 IOObjectRelease(devices);if(!dev){return -1;}
 result=(*dev)->USBDeviceOpen(dev);
 if(result){(*dev)->Release(dev);return -1;}
 IOUSBFindInterfaceRequest request={kIOUSBFindInterfaceDontCare,kIOUSBFindInterfaceDontCare,kIOUSBFindInterfaceDontCare,kIOUSBFindInterfaceDontCare};
 io_iterator_t interfaces=0;result=(*dev)->CreateInterfaceIterator(dev,&request,&interfaces);
 if(!result){
  while((service=IOIteratorNext(interfaces))){
   IOCFPlugInInterface **plugin=NULL;SInt32 score=0;
   result=IOCreatePlugInInterfaceForService(service,kIOUSBInterfaceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);IOObjectRelease(service);
   if(!result&&plugin){(*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID182),(LPVOID)&iface);(*plugin)->Release(plugin);}
   if(!iface)continue;
   result=(*iface)->USBInterfaceOpen(iface);
   if(result){(*iface)->Release(iface);iface=NULL;continue;}
   pipe=bulkIn=bulkOut=0;
   UInt8 count=0;(*iface)->GetNumEndpoints(iface,&count);
   for(UInt8 p=1;p<=count;p++){
    UInt8 direction=0,num=0,type=0,interval=0;UInt16 max=0;
    result=(*iface)->GetPipeProperties(iface,p,&direction,&num,&type,&max,&interval);
    if(!result&&direction==kUSBIn&&num==3&&type==kUSBInterrupt&&max==1)pipe=p;
    if(!result&&direction==kUSBIn&&num==1&&type==kUSBBulk)bulkIn=p;
    if(!result&&direction==kUSBOut&&num==2&&type==kUSBBulk)bulkOut=p;
   }
   if(pipe)break;
   (*iface)->USBInterfaceClose(iface);(*iface)->Release(iface);iface=NULL;
  }
  IOObjectRelease(interfaces);
 }
 int button=-1;
 if(iface&&bulkIn&&bulkOut){
  uint8_t header[8]={0x82,0x28,0x1f,0,4,0,0,0}, selector[4]={0}, status[16]={0}, data[4]={0};
  result=(*iface)->WritePipeTO(iface,bulkOut,header,sizeof(header),1000,2000);
  if(!result)result=(*iface)->WritePipeTO(iface,bulkOut,selector,sizeof(selector),1000,2000);
  UInt32 length=sizeof(status);
  if(!result)result=(*iface)->ReadPipeTO(iface,bulkIn,status,&length,1000,2000);
  if(!result&&length==16&&status[0]==0x28&&!status[1]&&!status[2]&&!status[3]
     &&status[4]==4&&!status[5]&&!status[6]&&!status[7]){
   length=sizeof(data);result=(*iface)->ReadPipeTO(iface,bulkIn,data,&length,1000,2000);
   if(!result&&length==4&&data[0]<=3&&!data[1]&&!data[2]&&!data[3])button=data[0];
  }
 }
 if(iface){(*iface)->USBInterfaceClose(iface);(*iface)->Release(iface);}
 (*dev)->USBDeviceClose(dev);(*dev)->Release(dev);
 return button;
}
