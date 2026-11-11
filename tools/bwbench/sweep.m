// sweep.m — точная граница «мгновенно / 30 мс» и пропускная способность
// входящего потока DS4 (доказательство, что линк быстрее 5 КБ/с).

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

static volatile int inCount = 0;
static volatile long inBytes = 0;
static void inCB(void *ctx, IOReturn r, void *s, IOHIDReportType t, uint32_t rid,
                 uint8_t *rep, CFIndex len) { inCount++; inBytes += len; }

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
            if (t && CFGetTypeID(t) == CFStringGetTypeID() &&
                [(__bridge NSString *)t isEqualToString:@"Bluetooth"]) { dev = arr[i]; break; }
        }
        free(arr); CFRelease(set);
    }
    return dev;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        crcInit();
        IOHIDDeviceRef dev = findDS4();
        if (!dev) { printf("DS4 не найден\n"); return 1; }
        int mode = argc > 1 ? atoi(argv[1]) : 1;

        if (mode == 1) {
            printf("=== входящий поток DS4 (линк) ===\n");
            static uint8_t buf[4096];
            IOHIDDeviceRegisterInputReportCallback(dev, buf, sizeof(buf), inCB, NULL);
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            inCount = 0; inBytes = 0;
            double t0 = CFAbsoluteTimeGetCurrent();
            while (CFAbsoluteTimeGetCurrent() - t0 < 5.0) {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
            }
            double dt = CFAbsoluteTimeGetCurrent() - t0;
            printf("  %.1f отчётов/с, %.2f КБ/с входящих\n", inCount / dt, inBytes / dt / 1024.0);
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        } else if (mode == 2) {
            printf("=== тонкий свип размера: ищем обрыв (300 записей) ===\n");
            printf("%-5s %-10s %-9s %-9s\n", "B", "мс/отчёт", "отч/с", "КБ/с");
            for (int len = 76; len <= 140; len += 4) {
                uint8_t *b = calloc(1, len);
                int ok = 0;
                double t0 = CFAbsoluteTimeGetCurrent();
                for (int k = 0; k < 300; k++) {
                    memset(b, 0, len); b[0] = 0x12; b[1] = 0x40; b[2] = 0xA0;
                    b[3] = k & 0xFF; b[4] = (k >> 8) & 0xFF; b[5] = 0x02;
                    uint32_t crc = crcOf(b, len - 4, 0xA2); memcpy(b + len - 4, &crc, 4);
                    if (IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x12, b, len) == kIOReturnSuccess) ok++;
                }
                double dt = CFAbsoluteTimeGetCurrent() - t0;
                printf("%-5d %-10.2f %-9.1f %-9.2f\n", len, dt / ok * 1000, ok / dt, ok * (double)len / dt / 1024.0);
                free(b);
            }
        }
    }
    return 0;
}
