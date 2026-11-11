// bwbench.m — измерение бюджета исходящего HID-канала DS4 на macOS.
//
// Гипотеза: задержка записи = ceil(len / Q) * T, где Q ≈ 75 B, T ≈ 15.7 мс,
// то есть канал отдаёт фиксированное число байт за событие связи, а не
// «одну транзакцию за 15 мс». Проверяем: (1) кривую байт/с по размерам,
// (2) распределение задержек (квант T), (3) пайплайн асинхронных записей,
// (4) агрегат при двух конкурентных писателях.

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>

static uint32_t crc32_table[256];
static void crc32_init(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320 : (c >> 1);
        crc32_table[i] = c;
    }
}
static uint32_t crc32_data(const uint8_t *p, size_t n, uint8_t prefix) {
    uint32_t crc = 0xFFFFFFFF;
    crc = (crc >> 8) ^ crc32_table[(crc ^ prefix) & 0xFF];
    for (size_t i = 0; i < n; i++) crc = (crc >> 8) ^ crc32_table[(crc ^ p[i]) & 0xFF];
    return ~crc;
}

/// Собирает валидный по CRC отчёт заданной длины.
static void makeReport(uint8_t *buf, int len, uint8_t reportID, uint16_t counter, uint8_t target) {
    memset(buf, 0, len);
    buf[0] = reportID;
    buf[1] = 0x40;
    buf[2] = 0xA0;
    buf[3] = counter & 0xFF;
    buf[4] = counter >> 8;
    buf[5] = target;
    uint32_t crc = crc32_data(buf, len - 4, 0xA2);
    memcpy(buf + len - 4, &crc, 4);
}

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
                [(__bridge NSString *)t isEqualToString:@"Bluetooth"]) {
                if (!dev) dev = arr[i];
            }
        }
        free(arr);
        CFRelease(set);
    }
    return dev;
}

typedef struct { double *v; int n; } Samples;

static void onReportSent(void *ctx, IOReturn res, void *sender, IOHIDReportType type,
                         uint32_t id, uint8_t *report, CFIndex len) {
    (void)res; (void)sender; (void)type; (void)id; (void)report; (void)len;
    if (ctx) (*(int *)ctx)++;
}

static int cmpDouble(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}
static double pct(Samples s, double p) {
    double *c = malloc(sizeof(double) * s.n);
    memcpy(c, s.v, sizeof(double) * s.n);
    qsort(c, s.n, sizeof(double), cmpDouble);
    double r = c[(int)(p * (s.n - 1))];
    free(c);
    return r;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        crc32_init();
        IOHIDDeviceRef dev = findDS4();
        if (!dev) { printf("DS4 по Bluetooth не найден\n"); return 1; }
        printf("DS4 найден\n");

        int sizes[] = {78, 142, 206, 270, 334, 398, 462, 526, 547};
        uint8_t ids[]  = {0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19};
        int nsizes = 9;
        int reps = argc > 1 ? atoi(argv[1]) : 6;
        int samplesPerSize = argc > 2 ? atoi(argv[2]) : 24;

        // 1) Кривая байт/с: пишем «как можно быстрее», с замером каждой записи.
        printf("\n=== 1. бюджет канала по размерам (%d записей на размер) ===\n", samplesPerSize);
        printf("%-6s %-4s %-10s %-9s %-9s %-9s %-9s\n",
               "len", "ID", "ms/write", "p50", "min", "отч/с", "КБ/с");
        double quantum[32]; int nq = 0;

        for (int i = 0; i < nsizes; i++) {
            int len = sizes[i];
            uint8_t *buf = calloc(1, len);
            Samples s = { .v = calloc(samplesPerSize, sizeof(double)), .n = 0 };
            double t0 = CFAbsoluteTimeGetCurrent();
            for (int k = 0; k < samplesPerSize; k++) {
                makeReport(buf, len, ids[i], (uint16_t)k, 0x02);
                double a = CFAbsoluteTimeGetCurrent();
                IOReturn r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, ids[i], buf, len);
                double b = CFAbsoluteTimeGetCurrent();
                if (r == kIOReturnSuccess) s.v[s.n++] = (b - a) * 1000.0;
            }
            double total = CFAbsoluteTimeGetCurrent() - t0;
            if (s.n == 0) { printf("%-6d %-4x ЗАПИСЬ НЕ ПРОШЛА\n", len, ids[i]); free(buf); free(s.v); continue; }
            double avg = 0; for (int k = 0; k < s.n; k++) avg += s.v[k];
            avg /= s.n;
            printf("%-6d 0x%-2x %-10.2f %-9.2f %-9.2f %-9.1f %-9.2f\n",
                   len, ids[i], avg, pct(s, 0.5), pct(s, 0.0), s.n / total, s.n * len / total / 1024.0);
            if (s.n > 4) quantum[nq++] = pct(s, 0.0);
            free(buf); free(s.v);
        }

        // 2) Асинхронный пайплайн: 16 записей подряд, не дожидаясь завершения.
        printf("\n=== 2. пайплайн: 16 асинхронных записей 0x19 подряд ===\n");
        int done = 0;
        int len = 547;
        uint8_t *buf = calloc(1, len);
        makeReport(buf, len, 0x19, 0, 0x02);
        double t0 = CFAbsoluteTimeGetCurrent();
        for (int k = 0; k < 16; k++) {
            IOHIDDeviceSetReportWithCallback(dev, kIOHIDReportTypeOutput, 0x19, buf, len, 5000.0,
                onReportSent, &done);
        }
        while (done < 16 && CFAbsoluteTimeGetCurrent() - t0 < 6.0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        double dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("завершилось %d/16 за %.2f c -> %.1f отч/с, %.2f КБ/с\n",
               done, dt, done / dt, done * len / dt / 1024.0);
        free(buf);

        // 3) Два конкурентных писателя: если предел глобальный по байтам — сумма та же.
        printf("\n=== 3. два потока по 16 записей 0x19 ===\n");
        t0 = CFAbsoluteTimeGetCurrent();
        dispatch_group_t g = dispatch_group_create();
        dispatch_apply(2, DISPATCH_APPLY_AUTO, ^(size_t t) {
            uint8_t *b = calloc(1, 547);
            for (int k = 0; k < 16; k++) {
                makeReport(b, 547, 0x19, (uint16_t)(k + t * 16), 0x02);
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x19, b, 547);
            }
            free(b);
        });
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        dt = CFAbsoluteTimeGetCurrent() - t0;
        printf("32 записи за %.2f c -> %.1f отч/с, %.2f КБ/с суммарно\n", dt, 32 / dt, 32 * 547.0 / dt / 1024.0);

        // 4) Мелкие против крупных при равном объёме: 54700 байт каждым способом.
        printf("\n=== 4. равный объём: 100x547 B против 370x147 B (≈54.7 КБ) ===\n");
        {
            uint8_t *b = calloc(1, 547);
            t0 = CFAbsoluteTimeGetCurrent();
            for (int k = 0; k < 100; k++) { makeReport(b, 547, 0x19, k, 0x02);
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x19, b, 547); }
            double d1 = CFAbsoluteTimeGetCurrent() - t0;
            free(b);
            uint8_t *b2 = calloc(1, 270);
            t0 = CFAbsoluteTimeGetCurrent();
            for (int k = 0; k < 202; k++) { makeReport(b2, 270, 0x14, k, 0x02);
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x14, b2, 270); }
            double d2 = CFAbsoluteTimeGetCurrent() - t0;
            free(b2);
            printf("547 B x100: %.2f c -> %.2f КБ/с\n", d1, 100 * 547.0 / d1 / 1024.0);
            printf("270 B x202: %.2f c -> %.2f КБ/с\n", d2, 202 * 270.0 / d2 / 1024.0);
        }
        printf("\nmin-задержки по размерам (кванты):");
        for (int i = 0; i < nq; i++) printf(" %.1f", quantum[i]);
        printf("\n");
    }
    return 0;
}
