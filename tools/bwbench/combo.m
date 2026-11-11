// combo.m — делят ли вход и выход DS4 один бюджет опроса.
// Меряем вход в трёх режимах: простой, насыщенный выход, насыщенный выход крупными отчётами.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

static volatile int inCount = 0; static volatile long inBytes = 0;
static void inCB(void *c, IOReturn r, void *s, IOHIDReportType t, uint32_t rid, uint8_t *rep, CFIndex len) {
    inCount++; inBytes += len;
}
static IOHIDDeviceRef gDev;

static IOHIDDeviceRef findDS4(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *m = @{ @kIOHIDVendorIDKey: @0x054C, @kIOHIDProductIDKey: @0x09CC };
    IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)m);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    IOHIDDeviceRef dev = NULL;
    if (set) {
        CFIndex n = CFSetGetCount(set);
        IOHIDDeviceRef *arr = calloc(n, sizeof(IOHIDDeviceRef));
        CFSetGetValues(set, (const void **)arr);
        for (CFIndex i = 0; i < n; i++) {
            CFTypeRef t = IOHIDDeviceGetProperty(arr[i], CFSTR("Transport"));
            if (t && CFGetTypeID(t)==CFStringGetTypeID() && [(__bridge NSString*)t isEqualToString:@"Bluetooth"]) { dev=arr[i]; break; }
        }
        free(arr); CFRelease(set);
    }
    return dev;
}

/// Пишет отчёты secs секунд, попутно считает вход.
static void run(const char *label, int len, uint8_t rid, double secs, int outOnly) {
    inCount = 0; inBytes = 0;
    uint8_t *b = calloc(1, len);
    int ok = 0, k = 0;
    double t0 = CFAbsoluteTimeGetCurrent(), end = t0 + secs;
    while (CFAbsoluteTimeGetCurrent() < end) {
        if (!outOnly) {
            memset(b, 0, len); b[0]=rid; b[1]=0x40; b[2]=0xA0;
            b[3]=k&0xFF; b[4]=(k>>8)&0xFF; b[5]=0x02;
            uint32_t crc = crcOf(b, len-4, 0xA2); memcpy(b+len-4, &crc, 4);
            if (IOHIDDeviceSetReport(gDev, kIOHIDReportTypeOutput, rid, b, len)==kIOReturnSuccess) ok++;
            k++;
        } else {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
        }
    }
    double dt = CFAbsoluteTimeGetCurrent()-t0;
    free(b);
    printf("%-34s вход %5.1f отч/с (%5.2f КБ/с)   выход %5.2f КБ/с\n",
           label, inCount/dt, inBytes/dt/1024.0, ok*(double)len/dt/1024.0);
}

int main(void) { @autoreleasepool {
    crcInit();
    gDev = findDS4();
    if (!gDev) { printf("нет DS4\n"); return 1; }
    static uint8_t buf[4096];
    IOHIDDeviceRegisterInputReportCallback(gDev, buf, sizeof(buf), inCB, NULL);
    IOHIDDeviceScheduleWithRunLoop(gDev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    [NSThread sleepForTimeInterval:0.5];

    run("A. только вход", 78, 0x11, 4.0, 1);
    run("B. вход + выход 0x18 (526 B)", 526, 0x18, 4.0, 0);
    run("C. вход + выход 0x12 (142 B)", 142, 0x12, 4.0, 0);
    run("D. только вход (повтор)", 78, 0x11, 4.0, 1);
    IOHIDDeviceUnscheduleFromRunLoop(gDev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
}}
