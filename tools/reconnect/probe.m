// Диагностика: подключён ли DS4, публикуется ли его HID-интерфейс,
// какие сервисы видны. Печатает состояние раз в 500 мс.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/hid/IOHIDManager.h>

static IOBluetoothDevice *dev(void){
  BluetoothDeviceAddress a; unsigned char *b=(unsigned char*)&a;
  unsigned v[6]; const char *s = getenv("DS4_ADDRESS");
  if (!s) s = "AA:BB:CC:DD:EE:FF";
  if(sscanf(s,"%x:%x:%x:%x:%x:%x",&v[0],&v[1],&v[2],&v[3],&v[4],&v[5])!=6) return nil;
  for(int i=0;i<6;i++) b[i]=(unsigned char)v[i];
  return [IOBluetoothDevice withAddress:&a];
}

static int hidCount(void){
  IOHIDManagerRef m=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
  NSDictionary *match=@{@kIOHIDVendorIDKey:@(0x054C), @kIOHIDProductIDKey:@(0x09CC)};
  IOHIDManagerSetDeviceMatching(m,(__bridge CFDictionaryRef)match);
  IOHIDManagerOpen(m,kIOHIDOptionsTypeNone);
  CFSetRef set=IOHIDManagerCopyDevices(m);
  int n = set? (int)CFSetGetCount(set) : 0;
  if(set) CFRelease(set);
  IOHIDManagerClose(m,kIOHIDOptionsTypeNone);
  CFRelease(m);
  return n;
}

int main(int argc,char**argv){ @autoreleasepool{
  setvbuf(stdout,NULL,_IONBF,0);
  int tries = argc>1?atoi(argv[1]):1;
  IOBluetoothDevice *d=dev();
  if(!d){printf("нет устройства\n");return 1;}
  for(int t=0;t<tries;t++){
    BOOL c=d.isConnected;
    printf("[%2ds] connected=%d paired=%d hid_ifaces=%d  services=%s\n",
      t, c, d.isPaired, hidCount(),
      [[NSString stringWithFormat:@"%@", d.services] UTF8String]);
    if(!c){
      IOReturn r=[d openConnection];
      if(r!=kIOReturnSuccess) printf("      openConnection=0x%08x\n",r);
    }
    usleep(500000);
  }
  printf("--- final ---\n");
  printf("connected=%d hid_ifaces=%d\n", d.isConnected, hidCount());
  return 0;
}}
