// pkttype.m — найти HCI connection handle и проверить, поднимает ли
// многослотовый packet type пропускную способность выхода DS4.
//
// Замеры показали бюджет ~1 пакет 3-DH1 (83 B) за ~15.7 мс в каждую сторону.
// Если сменить тип пакета на DH5/DM5 (339/183 B), выход должен вырасти в 2-4 раза.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOBluetooth/IOBluetooth.h>

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
            if (t && CFGetTypeID(t) == CFStringGetTypeID() &&
                [(__bridge NSString *)t isEqualToString:@"Bluetooth"]) { dev = arr[i]; break; }
        }
        free(arr); CFRelease(set);
    }
    return dev;
}

typedef IOReturn (*PacketFn)(id, SEL, UInt16, UInt16, void *);
typedef IOReturn (*PolicyReadFn)(id, SEL, UInt16, UInt16 *);

static double measureOutput(IOHIDDeviceRef dev, int len, uint8_t rid, double secs, int *okOut) {
    uint8_t *b = calloc(1, len);
    int ok = 0;
    double t0 = CFAbsoluteTimeGetCurrent(), end = t0 + secs;
    int k = 0;
    while (CFAbsoluteTimeGetCurrent() < end) {
        memset(b, 0, len); b[0] = rid; b[1] = 0x40; b[2] = 0xA0;
        b[3] = k & 0xFF; b[4] = (k >> 8) & 0xFF; b[5] = 0x02;
        uint32_t crc = crcOf(b, len - 4, 0xA2); memcpy(b + len - 4, &crc, 4);
        if (IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, rid, b, len) == kIOReturnSuccess) ok++;
        k++;
    }
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    free(b);
    if (okOut) *okOut = ok;
    return ok * (double)len / dt / 1024.0;
}

int main(void) {
    @autoreleasepool {
        crcInit();
        IOHIDDeviceRef dev = findDS4();
        if (!dev) { printf("DS4 (HID) не найден\n"); return 1; }
        IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
        SEL pr = NSSelectorFromString(@"BluetoothHCIReadLinkPolicySettings:outLinkPolicySettings:");
        if (![hc respondsToSelector:pr]) { printf("нет ReadLinkPolicySettings\n"); return 1; }
        PolicyReadFn readPolicy = (PolicyReadFn)[hc methodForSelector:pr];

        printf("=== поиск HCI handle (0..40) ===\n");
        int found = -1;
        for (unsigned h = 0; h <= 40; h++) {
            UInt16 policy = 0xFFFF;
            IOReturn r = readPolicy(hc, pr, (UInt16)h, &policy);
            if (r == kIOReturnSuccess) {
                printf("  handle 0x%04X -> policy 0x%04X\n", h, policy);
                if (found < 0) found = (int)h;
            } else if (r != -536870212 && r != -536870199) {
                // печатаем неожиданные коды, чтобы не пропустить сигнал
                printf("  handle 0x%04X -> %d\n", h, r);
            }
        }
        if (found < 0) { printf("handle не найден по ReadLinkPolicySettings\n"); return 1; }
        UInt16 h = (UInt16)found;
        printf("используем handle 0x%04X\n\n", h);

        SEL pt = NSSelectorFromString(@"BluetoothHCIChangeConnectionPacketType:inPacketType:outConnectionPacketTypeChangedResults:");
        PacketFn setPkt = [hc respondsToSelector:pt] ? (PacketFn)[hc methodForSelector:pt] : NULL;
        if (!setPkt) { printf("нет ChangeConnectionPacketType\n"); return 1; }

        double kb = 0;
        printf("[до] 0x18 526 B: %.2f КБ/с\n", (kb = measureOutput(dev, 526, 0x18, 4.0, NULL)));

        UInt16 masks[] = {0x0018, 0x00F8, 0x0CF8, 0xC000, 0xCC00, 0xCC18, 0x0CF8};
        const char *names[] = {"DH1/DM1", "DH1..DH3", "DH1..3DH3", "DH5/DM5",
                               "DH1/DH3/DH5", "все", "DH1..3DH3 (повтор)"};
        for (int i = 0; i < 7; i++) {
            unsigned char out[8] = {0};
            IOReturn r = setPkt(hc, pt, h, masks[i], out);
            [NSThread sleepForTimeInterval:1.2];
            double v = measureOutput(dev, 526, 0x18, 4.0, NULL);
            printf("[%s mask=0x%04X r=%d] %.2f КБ/с  (было %.2f)\n", names[i], masks[i], r, v, kb);
        }

        printf("\nвозвращаю все пакеты (0xCC18) — безопасный дефолт\n");
        unsigned char out[8] = {0};
        setPkt(hc, pt, h, 0xCC18, out);
    }
    return 0;
}
