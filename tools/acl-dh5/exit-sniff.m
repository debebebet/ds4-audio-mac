// exit-sniff.m — вывести DS4 из sniff-режима и померить результат.
//
// Лог bluetoothd показал: handle = 1, mode = 2 (sniff), interval = 15000 us.
// В sniff окно просыпается раз в 15 мс и обменивается ОДНИМ пакетом —
// именно это и даёт 5 КБ/с. Проверяем, что будет в active-режиме.
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOBluetooth/IOBluetooth.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}
static IOHIDDeviceRef gDev;

static IOHIDDeviceRef findDS4(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int vid=0x054C,pid=0x09CC;
    CFNumberRef nv=CFNumberCreate(NULL,kCFNumberIntType,&vid), np=CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFDictionarySetValue(m,CFSTR(kIOHIDVendorIDKey),nv);
    CFDictionarySetValue(m,CFSTR(kIOHIDProductIDKey),np);
    IOHIDManagerSetDeviceMatching(mgr,m);
    IOHIDManagerOpen(mgr,kIOHIDOptionsTypeNone);
    CFSetRef set=IOHIDManagerCopyDevices(mgr);
    IOHIDDeviceRef dev=NULL;
    if(set){CFIndex n=CFSetGetCount(set);IOHIDDeviceRef*a=calloc(n,sizeof(IOHIDDeviceRef));CFSetGetValues(set,(const void**)a);
        for(CFIndex i=0;i<n;i++){CFTypeRef t=IOHIDDeviceGetProperty(a[i],CFSTR("Transport"));
            if(t&&CFGetTypeID(t)==CFStringGetTypeID()&&CFStringCompare((CFStringRef)t,CFSTR("Bluetooth"),0)==0){dev=a[i];break;}}
        free(a);CFRelease(set);}
    return dev;
}

static double rate(int len, uint8_t rid, double secs) {
    uint8_t *b = calloc(1, len);
    int ok = 0, k = 0;
    double t0 = CFAbsoluteTimeGetCurrent(), end = t0 + secs;
    while (CFAbsoluteTimeGetCurrent() < end) {
        memset(b,0,len); b[0]=rid; b[1]=0x40; b[2]=0xA0;
        b[3]=k&0xFF; b[4]=(k>>8)&0xFF; b[5]=0x02;
        uint32_t crc=crcOf(b,len-4,0xA2); memcpy(b+len-4,&crc,4);
        if (IOHIDDeviceSetReport(gDev,kIOHIDReportTypeOutput,rid,b,len)==kIOReturnSuccess) ok++;
        k++;
    }
    double dt=CFAbsoluteTimeGetCurrent()-t0;
    free(b);
    printf("  %d B: %.2f отч/с, %.2f КБ/с\n", len, ok/dt, ok*(double)len/dt/1024.0);
    return ok*(double)len/dt/1024.0;
}

typedef IOReturn (*ExitFn)(id, SEL, UInt16, void *);
typedef IOReturn (*PolicyFn)(id, SEL, UInt16, UInt16);

int main(int argc, char **argv) {
    @autoreleasepool {
        crcInit();
        gDev = findDS4();
        if (!gDev) { printf("нет DS4\n"); return 1; }
        unsigned h = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 0) : 1;
        printf("HCI handle = %u (из лога bluetoothd)\n", h);

        IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
        SEL ex = NSSelectorFromString(@"BluetoothHCIExitSniffMode:outModeChangeResults:");
        if (![hc respondsToSelector:ex]) { printf("нет ExitSniffMode\n"); return 1; }
        ExitFn fExit = (ExitFn)[hc methodForSelector:ex];

        printf("\n[до]\n"); rate(526, 0x18, 2.0);

        printf("\n[ExitSniffMode(handle=%u)]\n", h);
        unsigned char out[8] = {0};
        IOReturn r = fExit(hc, ex, (UInt16)h, out);
        printf("  -> %d\n", r);
        [NSThread sleepForTimeInterval:1.0];
        printf("[после]\n"); rate(526, 0x18, 2.0);

        printf("\n[link policy = 0 (без sniff/hold/park)]\n");
        SEL wp = NSSelectorFromString(@"BluetoothHCIWriteLinkPolicySettings:inLinkPolicySettings:");
        if ([hc respondsToSelector:wp]) {
            IOReturn r2 = ((PolicyFn)[hc methodForSelector:wp])(hc, wp, (UInt16)h, 0);
            printf("  -> %d\n", r2);
            [NSThread sleepForTimeInterval:1.0];
            printf("[после]\n"); rate(526, 0x18, 2.0);
        }
        return 0;
    }
}
