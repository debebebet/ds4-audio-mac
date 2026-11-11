// bwproc.c — писатель одного процесса: N секунд отчётов 0x18.
// Нужен, чтобы проверить, растёт ли суммарная скорость от числа процессов
// (у каждого свой IOKit user-client, а значит, возможно, своя очередь).
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

int main(int argc, char **argv) {
    crcInit();
    double secs = argc > 1 ? atof(argv[1]) : 5.0;
    int len = argc > 2 ? atoi(argv[2]) : 526;
    uint8_t rid = argc > 3 ? (uint8_t)strtol(argv[3], NULL, 16) : 0x18;

    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int vid = 0x054C, pid = 0x09CC;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kIOHIDVendorIDKey), nv);
    CFDictionarySetValue(m, CFSTR(kIOHIDProductIDKey), np);
    IOHIDManagerSetDeviceMatching(mgr, m);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    CFSetRef set = IOHIDManagerCopyDevices(mgr);
    IOHIDDeviceRef dev = NULL;
    if (set) {
        CFIndex n = CFSetGetCount(set);
        IOHIDDeviceRef *arr = calloc(n, sizeof(IOHIDDeviceRef));
        CFSetGetValues(set, (const void **)arr);
        for (CFIndex i = 0; i < n; i++) {
            CFTypeRef t = IOHIDDeviceGetProperty(arr[i], CFSTR("Transport"));
            if (t && CFGetTypeID(t) == CFStringGetTypeID() && CFStringCompare((CFStringRef)t, CFSTR("Bluetooth"), 0) == 0) {
                dev = arr[i]; break;
            }
        }
        free(arr); CFRelease(set);
    }
    if (!dev) { printf("pid %d: нет DS4\n", getpid()); return 1; }

    uint8_t *b = calloc(1, len);
    int ok = 0, fail = 0, k = 0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < secs) {
        memset(b, 0, len); b[0] = rid; b[1] = 0x40; b[2] = 0xA0;
        b[3] = k & 0xFF; b[4] = (k >> 8) & 0xFF; b[5] = 0x02;
        uint32_t crc = crcOf(b, len - 4, 0xA2); memcpy(b + len - 4, &crc, 4);
        if (IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, rid, b, len) == kIOReturnSuccess) ok++; else fail++;
        k++;
    }
    double dt = CFAbsoluteTimeGetCurrent() - t0;
    printf("pid %5d: %d ok / %d fail  %.2f КБ/с\n", getpid(), ok, fail, ok * (double)len / dt / 1024.0);
    free(b);
    return 0;
}
