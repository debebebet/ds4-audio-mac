// linktest.m — проверка, заперт ли линк DS4 на маленьких ACL-пакетах.
//
// Если предел ~5 КБ/с — это «3-DH1 (83 B) раз в ~16 мс», то смена
// connection packet type на 5-slot (DH5/DM5) должна поднять И входной поток
// (сенсоры DS4), И выходной. Меряем частоту входящих отчётов до/после.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOBluetooth/IOBluetooth.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

static volatile int inputCount = 0;
static volatile int inputBytes = 0;

static void inputCB(void *ctx, IOReturn res, void *sender, IOHIDReportType type,
                    uint32_t rid, uint8_t *report, CFIndex len) {
    inputCount++;
    inputBytes += (int)len;
}

static IOHIDDeviceRef gDev = NULL;

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

static IOBluetoothDevice *findBT(void) {
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices])
        if ([[d nameOrAddress] containsString:@"DUALSHOCK"]) return d;
    return nil;
}

typedef IOReturn (*PacketTypeFn)(id, SEL, UInt16, UInt16, void *);
typedef IOReturn (*SimpleFn)(id, SEL, UInt16, void *);
typedef IOReturn (*ReadPolicyFn)(id, SEL, UInt16, UInt16 *);

static unsigned short handleOf(IOBluetoothDevice *d) {
    SEL s = NSSelectorFromString(@"connectionHandle");
    if (![d respondsToSelector:s]) return 0;
    typedef unsigned short (*Fn)(id, SEL);
    return ((Fn)[d methodForSelector:s])(d, s);
}

static void setPacketType(unsigned short h, UInt16 mask) {
    IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
    SEL s = NSSelectorFromString(@"BluetoothHCIChangeConnectionPacketType:inPacketType:outConnectionPacketTypeChangedResults:");
    if (![hc respondsToSelector:s]) { printf("   packet type: API нет\n"); return; }
    unsigned char out[8] = {0};
    IOReturn r = ((PacketTypeFn)[hc methodForSelector:s])(hc, s, h, mask, out);
    printf("   ChangeConnectionPacketType(0x%04X) -> %d\n", mask, r);
    [NSThread sleepForTimeInterval:1.0];
}

static void measureIO(double secs, int reportLen, uint8_t rid, double *outKBps, double *inRate) {
    // вход
    inputCount = 0; inputBytes = 0;
    // выход
    uint8_t *b = calloc(1, reportLen);
    int ok = 0;
    double t0 = CFAbsoluteTimeGetCurrent();
    double tend = t0 + secs;
    int k = 0;
    while (CFAbsoluteTimeGetCurrent() < tend) {
        memset(b, 0, reportLen); b[0] = rid; b[1] = 0x40; b[2] = 0xA0;
        b[3] = k & 0xFF; b[4] = (k >> 8) & 0xFF; b[5] = 0x02;
        uint32_t crc = crcOf(b, reportLen - 4, 0xA2); memcpy(b + reportLen - 4, &crc, 4);
        if (IOHIDDeviceSetReport(gDev, kIOHIDReportTypeOutput, rid, b, reportLen) == kIOReturnSuccess) ok++;
        k++;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
    }
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    free(b);
    *outKBps = ok * (double)reportLen / dt / 1024.0;
    *inRate = inputCount / dt;
    printf("   выход: %d x %d B за %.2f c -> %.2f КБ/с\n", ok, reportLen, dt, *outKBps);
    printf("   вход:  %.1f отчётов/с, %.2f КБ/с\n", inputCount / dt, inputBytes / dt / 1024.0);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        crcInit();
        gDev = findDS4();
        if (!gDev) { printf("DS4 не найден\n"); return 1; }
        uint8_t *inbuf = calloc(1, 1024);
        IOHIDDeviceRegisterInputReportCallback(gDev, inbuf, 1024, inputCB, NULL);
        IOHIDDeviceScheduleWithRunLoop(gDev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

        IOBluetoothDevice *d = findBT();
        unsigned short h = d ? handleOf(d) : 0;
        printf("DS4: handle=%u\n", h);

        double kb = 0, inr = 0;
        printf("\n[исходное состояние]\n");
        measureIO(4.0, 526, 0x18, &kb, &inr);

        printf("\n[только DH1/DM1 — мелкие пакеты, 0x0018]\n");
        if (d) setPacketType(h, 0x0018);
        measureIO(4.0, 526, 0x18, &kb, &inr);

        printf("\n[только DH5/DM5 — крупные пакеты, 0xC000]\n");
        if (d) setPacketType(h, 0xC000);
        measureIO(4.0, 526, 0x18, &kb, &inr);

        printf("\n[все разрешённые, 0xCC18]\n");
        if (d) setPacketType(h, 0xCC18);
        measureIO(4.0, 526, 0x18, &kb, &inr);

        printf("\n[политика линка]\n");
        IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
        SEL lp = NSSelectorFromString(@"BluetoothHCIReadLinkPolicySettings:outLinkPolicySettings:");
        if ([hc respondsToSelector:lp]) {
            UInt16 out = 0;
            IOReturn r = ((ReadPolicyFn)[hc methodForSelector:lp])(hc, lp, h, &out);
            printf("   ReadLinkPolicySettings -> %d, policy=0x%04X\n", r, out);
        }
        IOHIDDeviceUnscheduleFromRunLoop(gDev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    }
    return 0;
}
