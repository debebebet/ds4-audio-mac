// dualdev.m — можно ли удвоить поток, если писать в оба HID-интерфейса DS4.
//
// DS4 по BT публикуется как два IOHIDDevice (страницы 0x01 и 0xFF00).
// Если предел ~5.3 КБ/с — это очередь bluetoothd на устройство, то два
// независимых объекта дадут вдвое. Если это линк/сессия — сумма не изменится.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

static int collect(IOHIDDeviceRef *out, int max) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *m = @{ @kIOHIDVendorIDKey: @0x054C, @kIOHIDProductIDKey: @0x09CC };
    IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)m);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    int n = 0;
    if (set) {
        CFIndex c = CFSetGetCount(set);
        IOHIDDeviceRef *arr = calloc(c, sizeof(IOHIDDeviceRef));
        CFSetGetValues(set, (const void **)arr);
        for (CFIndex i = 0; i < c && n < max; i++) {
            CFTypeRef t = IOHIDDeviceGetProperty(arr[i], CFSTR("Transport"));
            if (t && CFGetTypeID(t) == CFStringGetTypeID() &&
                [(__bridge NSString *)t isEqualToString:@"Bluetooth"]) out[n++] = arr[i];
        }
        free(arr); CFRelease(set);
    }
    return n;
}

static double run(IOHIDDeviceRef dev, int len, uint8_t rid, int n, int *okOut) {
    uint8_t *b = calloc(1, len);
    int ok = 0;
    double t0 = CFAbsoluteTimeGetCurrent();
    for (int k = 0; k < n; k++) {
        memset(b, 0, len); b[0] = rid; b[1] = 0x40; b[2] = 0xA0;
        b[3] = k & 0xFF; b[4] = (k >> 8) & 0xFF; b[5] = 0x02;
        uint32_t crc = crcOf(b, len - 4, 0xA2); memcpy(b + len - 4, &crc, 4);
        if (IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, rid, b, len) == kIOReturnSuccess) ok++;
    }
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    free(b);
    if (okOut) *okOut = ok;
    return dt;
}

int main(void) {
    @autoreleasepool {
        crcInit();
        IOHIDDeviceRef devs[8];
        int n = collect(devs, 8);
        printf("HID-устройств DS4: %d\n", n);
        for (int i = 0; i < n; i++) {
            CFTypeRef pu = IOHIDDeviceGetProperty(devs[i], CFSTR("PrimaryUsagePage"));
            CFTypeRef u = IOHIDDeviceGetProperty(devs[i], CFSTR("PrimaryUsage"));
            CFTypeRef p = IOHIDDeviceGetProperty(devs[i], CFSTR("Product"));
            printf("  [%d] usagePage=%s usage=%s product=%s\n", i,
                   pu ? [(__bridge id)pu description].UTF8String : "?",
                   u ? [(__bridge id)u description].UTF8String : "?",
                   p ? [(__bridge id)p description].UTF8String : "?");
        }
        if (n < 1) return 1;

        int len = 526, ok = 0;
        double dt = run(devs[0], len, 0x18, 40, &ok);
        printf("\nодин объект: %d x %d B за %.2f c -> %.2f КБ/с\n", ok, len, dt, ok * (double)len / dt / 1024.0);
        if (n < 2) { printf("второго объекта нет\n"); return 0; }

        for (int i = 1; i < n; i++) {
            int ok2 = 0;
            double d2 = run(devs[i], len, 0x18, 40, &ok2);
            printf("объект [%d]: %d x %d B за %.2f c -> %.2f КБ/с\n", i, ok2, len, d2, ok2 * (double)len / d2 / 1024.0);
        }

        printf("\n=== два объекта параллельно ===\n");
        IOHIDDeviceRef *dp = calloc(n, sizeof(IOHIDDeviceRef));
        memcpy(dp, devs, n * sizeof(IOHIDDeviceRef));
        double t0 = CFAbsoluteTimeGetCurrent();
        dispatch_apply(n, DISPATCH_APPLY_AUTO, ^(size_t i) {
            int okk = 0;
            run(dp[i], len, 0x18, 40, &okk);
        });
        double dts = CFAbsoluteTimeGetCurrent() - t0;
        printf("%d x 40 x %d B за %.2f c -> %.2f КБ/с суммарно\n",
               n, len, dts, n * 40.0 * len / dts / 1024.0);
    }
    return 0;
}
