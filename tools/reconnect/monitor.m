// Пассивный монитор: ничего не открывает и не подключает — только печатает
// состояние DS4 и наличие его HID-интерфейса. ./monitor [секунды]
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/hid/IOHIDManager.h>

static IOBluetoothDevice *dev(void){
  BluetoothDeviceAddress a; unsigned char *b=(unsigned char*)&a;
  unsigned v[6];
  const char *s = getenv("DS4_ADDRESS");
  if (!s) s = "AA:BB:CC:DD:EE:FF";
  if(sscanf(s,"%x:%x:%x:%x:%x:%x",&v[0],&v[1],&v[2],&v[3],&v[4],&v[5])!=6) return nil;
  for(int i=0;i<6;i++) b[i]=(unsigned char)v[i];
  return [IOBluetoothDevice withAddress:&a];
}
static int hidCount(void){
  IOHIDManagerRef m=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
  NSDictionary *match=@{@kIOHIDVendorIDKey:@(0x054C),@kIOHIDProductIDKey:@(0x09CC)};
  IOHIDManagerSetDeviceMatching(m,(__bridge CFDictionaryRef)match);
  IOHIDManagerOpen(m,kIOHIDOptionsTypeNone);
  CFSetRef s=IOHIDManagerCopyDevices(m);
  int n=s?(int)CFSetGetCount(s):0;
  if(s) CFRelease(s);
  IOHIDManagerClose(m,kIOHIDOptionsTypeNone); CFRelease(m);
  return n;
}
int main(int argc,char**argv){@autoreleasepool{
  setvbuf(stdout,NULL,_IONBF,0);
  int secs=argc>1?atoi(argv[1]):60;
  int up=0, drops=0, prev=-1;
  for(int t=0;t<secs;t++){
    IOBluetoothDevice*d=dev();
    int c=d.isConnected, h=hidCount();
    if(prev==1 && c==0) drops++;
    prev=c;
    if(c) up++;
    printf("[%3ds] %s  hid=%d  drops=%d\n", t, c?"CONNECTED":"---", h, drops);
    sleep(1);
  }
  printf("\nитого: подключён %d c из %d, обрывов: %d\n", up, secs, drops);
  return 0;
}}
