// bwbench2.m — какие рычаги реально меняют пропускную способность HID-канала DS4.
//
// 1) сколько потоков-писателей нужно, чтобы выйти за 5 КБ/с;
// 2) даёт ли что-то эксклюзивный захват (kIOHIDOptionsTypeSeizeDevice);
// 3) влияет ли ReportInterval;
// 4) в каком link policy / packet type живёт линк (HCI).

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOBluetooth/IOBluetooth.h>
#import <objc/message.h>

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
            if (!t || CFGetTypeID(t) != CFStringGetTypeID() ||
                [(__bridge NSString *)t isEqualToString:@"Bluetooth"]) { if (!dev) dev = arr[i]; }
        }
        free(arr); CFRelease(set);
    }
    return dev;
}

static void benchThreads(IOHIDDeviceRef dev, int threads, int perThread, int len, uint8_t rid, double *outSecs) {
    double t0 = CFAbsoluteTimeGetCurrent();
    dispatch_apply(threads, DISPATCH_APPLY_AUTO, ^(size_t t) {
        uint8_t *b = calloc(1, len);
        for (int k = 0; k < perThread; k++) {
            memset(b, 0, len); b[0] = rid; b[1] = 0x40; b[2] = 0xA0;
            uint16_t c = (uint16_t)(k + t * perThread); b[3] = c & 0xFF; b[4] = c >> 8; b[5] = 0x02;
            uint32_t crc = crcOf(b, len - 4, 0xA2); memcpy(b + len - 4, &crc, 4);
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, rid, b, len);
        }
        free(b);
    });
    *outSecs = CFAbsoluteTimeGetCurrent() - t0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        crcInit();
        IOHIDDeviceRef dev = findDS4();
        if (!dev) { printf("DS4 не найден\n"); return 1; }
        printf("DS4 найден. transport=%s\n",
               [(__bridge NSString *)IOHIDDeviceGetProperty(dev, CFSTR("Transport")) UTF8String]);

        printf("\n=== 1. масштабирование по потокам (0x19, 547 B) ===\n");
        printf("%-8s %-8s %-9s %-9s %-9s\n", "потоков", "записей", "секунд", "отч/с", "КБ/с");
        int per = argc > 1 ? atoi(argv[1]) : 12;
        for (int th = 1; th <= 8; th *= 2) {
            double s = 0;
            benchThreads(dev, th, per, 547, 0x19, &s);
            int total = th * per;
            printf("%-8d %-8d %-9.2f %-9.1f %-9.2f\n", th, total, s, total / s, total * 547.0 / s / 1024.0);
        }

        printf("\n=== 2. ReportInterval на устройстве ===\n");
        CFTypeRef before = IOHIDDeviceGetProperty(dev, CFSTR("ReportInterval"));
        printf("было: %s\n", before ? [(__bridge id)before description].UTF8String : "nil");
        IOReturn pr = IOHIDDeviceSetProperty(dev, CFSTR("ReportInterval"), (__bridge CFTypeRef)@(1000));
        printf("set 1000 -> %d\n", pr);
        double s2 = 0;
        benchThreads(dev, 1, per, 547, 0x19, &s2);
        printf("после: %.1f отч/с, %.2f КБ/с\n", per / s2, per * 547.0 / s2 / 1024.0);

        printf("\n=== 3. эксклюзивный захват (SeizeDevice) ===\n");
        IOReturn cl = IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
        IOReturn op = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeSeizeDevice);
        printf("close=%d open(seize)=%d\n", cl, op);
        if (op == kIOReturnSuccess) {
            double s3 = 0;
            benchThreads(dev, 1, per, 547, 0x19, &s3);
            printf("seized: %.1f отч/с, %.2f КБ/с\n", per / s3, per * 547.0 / s3 / 1024.0);
            IOHIDDeviceClose(dev, kIOHIDOptionsTypeSeizeDevice);
            op = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
            printf("reopen(normal)=%d\n", op);
        }

        printf("\n=== 4. HCI: link policy / sniff / packet type ===\n");
        IOBluetoothDevice *d = nil;
        NSString *wantedAddress = [NSString stringWithUTF8String:getenv("DS4_ADDRESS") ?: "aa-bb-cc-dd-ee-ff"];
        for (IOBluetoothDevice *x in [IOBluetoothDevice pairedDevices])
            if ([[[x addressString] lowercaseString] containsString:wantedAddress.lowercaseString]) d = x;
        if (!d) { printf("IOBluetooth: DS4 не найден\n"); return 0; }
        IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
        BOOL hp = NO;
        SEL hpSel = NSSelectorFromString(@"highPriority");
        if ([d respondsToSelector:hpSel]) {
            typedef BOOL (*BFn)(id, SEL);
            hp = ((BFn)[d methodForSelector:hpSel])(d, hpSel);
        }
        printf("connectionHandle=%u  highPriority=%d\n", (unsigned)[d connectionHandle], (int)hp);

        SEL lp = NSSelectorFromString(@"BluetoothHCIReadLinkPolicySettings:outLinkPolicySettings:");
        if ([hc respondsToSelector:lp]) {
            UInt16 out = 0;
            typedef IOReturn (*Fn)(id, SEL, UInt16, UInt16 *);
            IOReturn r = ((Fn)[hc methodForSelector:lp])(hc, lp, (UInt16)[d connectionHandle], &out);
            printf("ReadLinkPolicySettings -> %d, policy=0x%04X (sniff=%d hold=%d park=%d)\n",
                   r, out, !!(out & 1), !!(out & 2), !!(out & 4));
        } else printf("ReadLinkPolicySettings: нет\n");

        SEL pt = NSSelectorFromString(@"BluetoothHCIChangeConnectionPacketType:inPacketType:outConnectionPacketTypeChangedResults:");
        if ([hc respondsToSelector:pt]) {
            // 0xCC18 = DH5|DM5|DH3|DM3|DH1|DM1 (2-DH/3-DH вне маски)
            typedef IOReturn (*Fn)(id, SEL, UInt16, UInt16, void *);
            unsigned char out[8] = {0};
            IOReturn r = ((Fn)[hc methodForSelector:pt])(hc, pt, (UInt16)[d connectionHandle], 0xCC18, out);
            printf("ChangeConnectionPacketType(0xCC18) -> %d\n", r);
            double s4 = 0;
            benchThreads(dev, 1, per, 547, 0x19, &s4);
            printf("после смены packet type: %.1f отч/с, %.2f КБ/с\n", per / s4, per * 547.0 / s4 / 1024.0);
        } else printf("ChangeConnectionPacketType: нет\n");

        SEL es = NSSelectorFromString(@"BluetoothHCIExitSniffMode:outModeChangeResults:");
        if ([hc respondsToSelector:es]) {
            typedef IOReturn (*Fn)(id, SEL, UInt16, void *);
            unsigned char out[8] = {0};
            IOReturn r = ((Fn)[hc methodForSelector:es])(hc, es, (UInt16)[d connectionHandle], out);
            printf("ExitSniffMode -> %d\n", r);
        }
    }
    return 0;
}
