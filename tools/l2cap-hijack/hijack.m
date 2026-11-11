// hijack.m — проверка, можно ли писать HID-отчёты DS4 в уже открытый
// interrupt-канал L2CAP (PSM 0x13), минуя IOHIDDeviceSetReport.
//
// Гипотеза: потолок ~5 КБ/с — это HIDP control-канал: один 64-байтный юнит
// за кадр контроллера (~15.75 мс). Windows льёт отчёты в interrupt-канал
// (WriteFile на HID-хэндле), где HIDP-заголовок 0xA2 = DATA|Output не требует
// handshake. Проверяем, отдаёт ли macOS объект этого канала пользователю.

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>

/// IOBluetooth отдаёт адрес через дефис ("aa-bb-cc-dd-ee-ff"), а пользователь
/// обычно пишет через двоеточие. Приводим оба варианта к «12 hex-символов».
static NSString *normAddr(NSString *s) {
    NSString *t = [s stringByReplacingOccurrencesOfString:@":" withString:@""];
    t = [t stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return [t lowercaseString];
}

static IOBluetoothDevice *findDevice(NSString *addr) {
    NSString *key = normAddr(addr);
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices]) {
        if ([normAddr([d addressString]) isEqualToString:key]) return d;
    }
    for (IOBluetoothDevice *d in [IOBluetoothDevice recentDevices:0]) {
        if ([normAddr([d addressString]) isEqualToString:key]) return d;
    }
    return nil;
}

static id callId(id obj, const char *sel) {
    SEL s = sel_registerName(sel);
    if (![obj respondsToSelector:s]) return nil;
    return [obj performSelector:s];
}

static void describeChannel(id ch) {
    SEL psmS = sel_registerName("PSM");
    SEL lcS = sel_registerName("localChannelID");
    SEL rcS = sel_registerName("remoteChannelID");
    SEL mtS = sel_registerName("outgoingMTU");
    unsigned psm = 0, lc = 0, rc = 0, mt = 0;
    if ([ch respondsToSelector:psmS]) psm = (unsigned)[ch performSelector:psmS];
    if ([ch respondsToSelector:lcS]) lc = (unsigned)[ch performSelector:lcS];
    if ([ch respondsToSelector:rcS]) rc = (unsigned)[ch performSelector:rcS];
    if ([ch respondsToSelector:mtS]) mt = (unsigned)[ch performSelector:mtS];
    printf("    PSM=0x%04X localCID=%u remoteCID=%u outMTU=%u  %s\n",
           psm, lc, rc, mt, [[ch description] UTF8String]);
}

static double writeBench(id ch, int count, int size, uint8_t first, uint8_t second) {
    uint8_t *buf = calloc(1, size);
    buf[0] = first;          // HIDP header: 0xA2 = DATA | Output
    buf[1] = second;         // Report ID
    buf[2] = 0x40;
    buf[3] = 0xA2;
    for (int i = 4; i < size; i++) buf[i] = (uint8_t)i;
    double t0 = CFAbsoluteTimeGetCurrent();
    int ok = 0, fail = 0;
    IOReturn last = 0;
    for (int i = 0; i < count; i++) {
        @autoreleasepool {
            IOReturn r = [ch writeSync:buf length:(UInt16)size];
            if (r == kIOReturnSuccess) ok++; else { fail++; last = r; }
        }
    }
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    printf("    writeSync %d x %d B: ok=%d fail=%d lastErr=%d  %.3f s  -> %.1f отч/с, %.2f КБ/с\n",
           count, size, ok, fail, (int)last, dt,
           dt > 0 ? count / dt : 0.0, dt > 0 ? count * size / dt / 1024.0 : 0.0);
    free(buf);
    return dt;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *addr = argc > 1 ? @(argv[1]) : @"AA:BB:CC:DD:EE:FF";
        int count = argc > 2 ? atoi(argv[2]) : 30;
        int size = argc > 3 ? atoi(argv[3]) : 463;

        IOBluetoothHostController *hc = [IOBluetoothHostController defaultController];
        printf("controller power=%d addr=%s\n", hc ? (int)hc.powerState : -1,
               [[hc addressAsString] UTF8String]);

        IOBluetoothDevice *d = findDevice(addr);
        if (!d) { printf("УСТРОЙСТВО НЕ НАЙДЕНО: %s\n", addr.UTF8String); return 1; }
        printf("device: %s  name=%s  connected=%d\n", addr.UTF8String,
               [[d nameOrAddress] UTF8String], [d isConnected]);

        // connection handle (scalar) — для HCI-команд ниже
        unsigned short handle = 0xFFFF;
        SEL hSel = sel_registerName("connectionHandle");
        if ([d respondsToSelector:hSel]) {
            typedef unsigned short (*UShortFn)(id, SEL);
            UShortFn f = (UShortFn)[d methodForSelector:hSel];
            handle = f(d, hSel);
        }
        printf("connectionHandle = 0x%04X (%u)\n", handle, handle);

        // HID QoS-параметры, которые стек вычитал из SDP
        for (NSString *k in @[@"HIDQoSLatency", @"HIDSSRHostMaxLatency", @"HIDSSRHostMinTimeout",
                              @"HIDSupervisionTimeout", @"HIDProfileSupported", @"isConfiguredHIDDevice"]) {
            @try {
                id v = [d valueForKey:k];
                if (v) printf("  %s = %s\n", k.UTF8String, [[v description] UTF8String]);
            } @catch (NSException *e) {}
        }

        // Какие L2CAP-каналы видит пользовательский процесс?
        NSArray *chs = callId(d, "l2capChannels");
        printf("l2capChannels: %s (%lu)\n", chs ? "array" : "nil", (unsigned long)chs.count);
        for (id ch in chs) describeChannel(ch);

        for (int psm = 0x11; psm <= 0x13; psm += 2) {
            SEL s = sel_registerName("getL2CAPObjectsWithPSM:");
            if (![d respondsToSelector:s]) { printf("getL2CAPObjectsWithPSM: нет\n"); break; }
            typedef NSArray *(*ArrFn)(id, SEL, int);
            ArrFn f = (ArrFn)[d methodForSelector:s];
            NSArray *arr = f(d, s, psm);
            printf("getL2CAPObjectsWithPSM:0x%X -> %s (%lu)\n", psm, arr ? "array" : "nil",
                   (unsigned long)arr.count);
            for (id ch in arr) describeChannel(ch);
        }

        // Выбираем interrupt-канал (PSM 0x13) среди найденных
        id interrupt = nil;
        for (id ch in chs) {
            SEL psmS = sel_registerName("PSM");
            if ([ch respondsToSelector:psmS] && (unsigned)[ch performSelector:psmS] == 0x13) interrupt = ch;
        }
        if (!interrupt) {
            printf("\ninterrupt-канал (PSM 0x13) НЕ виден пользовательскому процессу.\n");
            return 2;
        }

        printf("\n=== замер через interrupt-канал ===\n");
        if ([d respondsToSelector:sel_registerName("setHighPriority:")]) {
            typedef void (*BoolFn)(id, SEL, BOOL);
            BoolFn f = (BoolFn)[d methodForSelector:sel_registerName("setHighPriority:")];
            f(d, sel_registerName("setHighPriority:"), YES);
            printf("setHighPriority:YES\n");
        }
        writeBench(interrupt, count, size, 0xA2, 0x17);
        writeBench(interrupt, count, size, 0xA2, 0x19);
        writeBench(interrupt, 200, 30, 0xA2, 0x12);   // мелкий отчёт: тест частоты
    }
    return 0;
}
