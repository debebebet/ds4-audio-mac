// bwbench3.m — уточнение природы предела выхода DS4.
// 1) устойчивая скорость на малых отчётах (не 20, а 400 записей);
// 2) точная лестница по размерам (шаг 8 байт) — где меняется квант;
// 3) сколько даёт пауза между записями (drain vs transaction).

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

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
            if (!t || (CFGetTypeID(t) == CFStringGetTypeID() &&
                       [(__bridge NSString *)t isEqualToString:@"Bluetooth"])) { if (!dev) dev = arr[i]; }
        }
        free(arr); CFRelease(set);
    }
    return dev;
}

/// Пишет n отчётов длины len, возвращает секунды и число успешных.
static double run(IOHIDDeviceRef dev, int len, uint8_t rid, int n, int *okOut, double pauseMs) {
    uint8_t *b = calloc(1, len);
    int ok = 0;
    double t0 = CFAbsoluteTimeGetCurrent();
    for (int k = 0; k < n; k++) {
        memset(b, 0, len); b[0] = rid; b[1] = 0x40; b[2] = 0xA0;
        b[3] = k & 0xFF; b[4] = (k >> 8) & 0xFF; b[5] = 0x02;
        uint32_t crc = crcOf(b, len - 4, 0xA2); memcpy(b + len - 4, &crc, 4);
        if (IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, rid, b, len) == kIOReturnSuccess) ok++;
        if (pauseMs > 0) usleep((useconds_t)(pauseMs * 1000));
    }
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    free(b);
    if (okOut) *okOut = ok;
    return dt;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        crcInit();
        IOHIDDeviceRef dev = findDS4();
        if (!dev) { printf("DS4 не найден\n"); return 1; }
        int mode = argc > 1 ? atoi(argv[1]) : 1;

        if (mode == 1) {
            printf("=== 1. устойчивая скорость по размерам (400 записей) ===\n");
            printf("%-5s %-6s %-8s %-9s %-9s %-9s\n", "B", "ID", "ok", "секунд", "отч/с", "КБ/с");
            int lens[] = {78, 110, 142, 206, 270, 334, 398, 462, 526, 547};
            uint8_t ids[] = {0x11, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19};
            for (int i = 0; i < 10; i++) {
                int n = lens[i] <= 142 ? 400 : 120;
                int ok = 0;
                double dt = run(dev, lens[i], ids[i], n, &ok, 0);
                printf("%-5d 0x%-2x  %-8d %-9.2f %-9.1f %-9.2f\n",
                       lens[i], ids[i], ok, dt, ok / dt, ok * (double)lens[i] / dt / 1024.0);
            }
        } else if (mode == 2) {
            printf("=== 2. лестница по размеру (10 записей на точку, min-задержка) ===\n");
            printf("%-5s %-9s %-9s\n", "B", "мин.мс", "КБ/с(устойч.)");
            for (int len = 80; len <= 560; len += 16) {
                uint8_t *b = calloc(1, len);
                double mn = 1e9, t0 = CFAbsoluteTimeGetCurrent();
                for (int k = 0; k < 10; k++) {
                    memset(b, 0, len); b[0] = 0x14; b[1] = 0x40; b[2] = 0xA0;
                    b[3] = k & 0xFF; b[5] = 0x02;
                    uint32_t crc = crcOf(b, len - 4, 0xA2); memcpy(b + len - 4, &crc, 4);
                    double a = CFAbsoluteTimeGetCurrent();
                    IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x14, b, len);
                    double d = (CFAbsoluteTimeGetCurrent() - a) * 1000;
                    if (d < mn) mn = d;
                }
                double tot = CFAbsoluteTimeGetCurrent() - t0;
                printf("%-5d %-9.1f %-9.2f\n", len, mn, 10 * (double)len / tot / 1024.0);
                free(b);
            }
        } else if (mode == 3) {
            printf("=== 3. влияние паузы между записями (0x19, 547 B) ===\n");
            double pauses[] = {0, 10, 30, 50, 80, 105, 150};
            for (int i = 0; i < 7; i++) {
                int ok = 0;
                double dt = run(dev, 547, 0x19, 40, &ok, pauses[i]);
                printf("пауза %-5.0f мс -> %.1f отч/с, %.2f КБ/с\n",
                       pauses[i], ok / dt, ok * 547.0 / dt / 1024.0);
            }
        }
    }
    return 0;
}
