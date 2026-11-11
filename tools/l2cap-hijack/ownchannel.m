// ownchannel.m — забрать HIDP interrupt-канал DS4 себе.
//
// Зачем: IOHIDDeviceSetReport = HIDP SET_REPORT по control-каналу, а он на
// macOS отдаёт ~170 B за ~30 мс (~5.5 КБ/с). Windows пишет output-отчёт как
// HIDP DATA (0xA2) прямо в interrupt-канал — без транзакции SET_REPORT.
// Пока жив IOBluetoothHIDDriver, PSM 0x11/0x13 заняты ядром и открыть их
// нельзя. IOBluetoothIgnoreHIDDevice() просит стек не поднимать HID-профиль
// для устройства — тогда каналы свободны.
//
// Использование:
//   ownchannel --probe     показать, что видно сейчас (ничего не меняет)
//   ownchannel --take      игнорировать HID, переподключиться, забрать 0x11/0x13
//   ownchannel --restore   вернуть HID-профиль и переподключиться
//   ownchannel --take --bench  (после захвата) замер 0x19 x N

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <dlfcn.h>

static NSString *normAddr(NSString *s) {
    NSString *t = [s stringByReplacingOccurrencesOfString:@":" withString:@""];
    t = [t stringByReplacingOccurrencesOfString:@"-" withString:@""];
    return [t lowercaseString];
}

static IOBluetoothDevice *findDevice(NSString *addr) {
    NSString *key = normAddr(addr);
    for (IOBluetoothDevice *d in [IOBluetoothDevice pairedDevices])
        if ([normAddr([d addressString]) isEqualToString:key]) return d;
    return nil;
}

static IOReturn (*pIgnore)(IOBluetoothDeviceRef) = NULL;
static IOReturn (*pUnignore)(IOBluetoothDeviceRef) = NULL;

static void loadFns(void) {
    void *h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW);
    if (!h) { printf("dlopen: %s\n", dlerror()); return; }
    pIgnore = (IOReturn (*)(IOBluetoothDeviceRef))dlsym(h, "IOBluetoothIgnoreHIDDevice");
    pUnignore = (IOReturn (*)(IOBluetoothDeviceRef))dlsym(h, "IOBluetoothRemoveIgnoredHIDDevice");
}

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

/// Полный HIDP output-отчёт: [0xA2][report...]. Размер буфера = len + 1.
static uint8_t *makeHidp(int len, uint8_t rid, uint16_t counter) {
    uint8_t *b = calloc(1, len + 1);
    b[0] = 0xA2;                 // HIDP: DATA | Output report
    b[1] = rid;
    b[2] = 0x40;
    b[3] = 0xA0;
    b[4] = counter & 0xFF;       // [3..4] счётчик кадров внутри отчёта
    b[5] = counter >> 8;
    b[6] = 0x02;                 // динамик
    uint32_t crc = crcOf(b + 1, len - 4, 0xA2);
    memcpy(b + 1 + len - 4, &crc, 4);
    return b;
}

static id findChannel(IOBluetoothDevice *d, unsigned psm) {
    NSArray *chs = nil;
    SEL s = NSSelectorFromString(@"l2capChannels");
    if ([d respondsToSelector:s]) chs = [d performSelector:s];
    for (id ch in chs) {
        SEL ps = NSSelectorFromString(@"PSM");
        if ([ch respondsToSelector:ps] && (unsigned)[ch performSelector:ps] == psm) return ch;
    }
    return nil;
}

static void showChannels(IOBluetoothDevice *d) {
    NSArray *chs = nil;
    SEL s = NSSelectorFromString(@"l2capChannels");
    if ([d respondsToSelector:s]) chs = [d performSelector:s];
    printf("l2capChannels: %lu\n", (unsigned long)chs.count);
    for (id ch in chs) {
        SEL ps = NSSelectorFromString(@"PSM");
        SEL lc = NSSelectorFromString(@"localChannelID");
        SEL rc = NSSelectorFromString(@"remoteChannelID");
        SEL mt = NSSelectorFromString(@"outgoingMTU");
        printf("  PSM=0x%04X lcid=%u rcid=%u mtu=%u\n",
               [ch respondsToSelector:ps] ? (unsigned)[ch performSelector:ps] : 0,
               [ch respondsToSelector:lc] ? (unsigned)[ch performSelector:lc] : 0,
               [ch respondsToSelector:rc] ? (unsigned)[ch performSelector:rc] : 0,
               [ch respondsToSelector:mt] ? (unsigned)[ch performSelector:mt] : 0);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        crcInit();
        loadFns();
        NSString *addr = @"AA:BB:CC:DD:EE:FF";
        BOOL take = NO, restore = NO, bench = NO, probe = NO;
        int count = 100;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--take")) take = YES;
            else if (!strcmp(argv[i], "--restore")) restore = YES;
            else if (!strcmp(argv[i], "--bench")) bench = YES;
            else if (!strcmp(argv[i], "--probe")) probe = YES;
            else if (!strcmp(argv[i], "--count") && i + 1 < argc) count = atoi(argv[++i]);
            else if (argv[i][0] != '-') addr = @(argv[i]);
        }
        printf("ignore=%p unignore=%p\n", (void *)pIgnore, (void *)pUnignore);

        IOBluetoothDevice *d = findDevice(addr);
        if (!d) { printf("DS4 не найден в pairedDevices\n"); return 1; }
        printf("device: %s  connected=%d\n", addr.UTF8String, [d isConnected]);
        showChannels(d);

        if (probe || (!take && !restore)) return 0;

        IOBluetoothDeviceRef ref = NULL;
        SEL gr = NSSelectorFromString(@"getDeviceRef");
        if ([d respondsToSelector:gr]) {
            typedef IOBluetoothDeviceRef (*RefFn)(id, SEL);
            ref = ((RefFn)[d methodForSelector:gr])(d, gr);
        }
        printf("deviceRef=%p\n", (void *)ref);
        if (!ref) { printf("нет deviceRef — приватный вызов недоступен\n"); return 1; }

        if (restore) {
            if (pUnignore) {
                IOReturn r = pUnignore(ref);
                printf("RemoveIgnoredHIDDevice -> %d\n", r);
            }
            [d closeConnection];
            [NSThread sleepForTimeInterval:1.0];
            IOReturn o = [d openConnection];
            printf("reconnect -> %d\n", o);
            for (int i = 0; i < 40 && ![d isConnected]; i++) [NSThread sleepForTimeInterval:0.25];
            printf("connected=%d\n", [d isConnected]);
            showChannels(d);
            return 0;
        }

        // --take
        if (pIgnore) {
            IOReturn r = pIgnore(ref);
            printf("IgnoreHIDDevice -> %d\n", r);
        }
        printf("закрываю соединение...\n");
        [d closeConnection];
        [NSThread sleepForTimeInterval:1.5];
        printf("открываю соединение без HID-профиля...\n");
        IOReturn o = [d openConnection];
        printf("openConnection -> %d\n", o);
        for (int i = 0; i < 60 && ![d isConnected]; i++) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
        }
        printf("connected=%d\n", [d isConnected]);
        showChannels(d);

        IOBluetoothL2CAPChannel *ctl = nil, *itr = nil;
        IOReturn r1 = [d openL2CAPChannelSync:&ctl withPSM:0x11 delegate:nil];
        printf("openL2CAP 0x11 -> %d\n", r1);
        IOReturn r2 = [d openL2CAPChannelSync:&itr withPSM:0x13 delegate:nil];
        printf("openL2CAP 0x13 -> %d\n", r2);
        if (r2 != kIOReturnSuccess || !itr) {
            printf("interrupt-канал не открылся; вернуть HID: --restore\n");
            return 2;
        }
        printf("0x13: lcid=%u rcid=%u outMTU=%u\n",
               [itr localChannelID], [itr remoteChannelID], [itr outgoingMTU]);

        if (!bench) { printf("канал захвачен; --bench для замера\n"); return 0; }

        // ARM: report 0x11 (78 B) в interrupt-канал как HIDP DATA
        uint8_t *arm = makeHidp(78, 0x11, 0);
        IOReturn ra = [itr writeSync:arm length:79];
        printf("arm 0x11 -> %d\n", ra);
        free(arm);

        int len = 547;
        uint8_t *buf = makeHidp(len, 0x19, 0);
        double t0 = CFAbsoluteTimeGetCurrent();
        int ok = 0, fail = 0;
        for (int i = 0; i < count; i++) {
            IOReturn r = [itr writeSync:buf length:len + 1];
            if (r == kIOReturnSuccess) ok++; else fail++;
        }
        double dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("0x19 x%d: ok=%d fail=%d  %.2f c -> %.1f отч/с, %.2f КБ/с\n",
               count, ok, fail, dt, ok / dt, ok * len / dt / 1024.0);
        free(buf);
        printf("вернуть HID: ownchannel --restore\n");
    }
    return 0;
}
