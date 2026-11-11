// inrate.c — как меняется частота входящих отчётов DS4 без нашей записи.
// 66/с = окно 15 мс, 89/с = 11.25 мс, 133/с = 7.5 мс (бины sniff из bluetoothd).
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdio.h>
#include <stdlib.h>

static volatile int cnt = 0, bytes = 0;
static void cb(void *c, IOReturn r, void *s, IOHIDReportType t, uint32_t rid,
               uint8_t *rep, CFIndex len) { cnt++; bytes += (int)len; }

int main(int argc, char **argv) {
    double secs = argc > 1 ? atof(argv[1]) : 15.0;
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef m = CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int vid=0x054C,pid=0x09CC;
    CFNumberRef nv=CFNumberCreate(NULL,kCFNumberIntType,&vid), np=CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFDictionarySetValue(m,CFSTR(kIOHIDVendorIDKey),nv);
    CFDictionarySetValue(m,CFSTR(kIOHIDProductIDKey),np);
    IOHIDManagerSetDeviceMatching(mgr,m);
    IOHIDManagerOpen(mgr,kIOHIDOptionsTypeNone);
    CFSetRef set=IOHIDManagerCopyDevices(mgr);
    IOHIDDeviceRef dev=NULL;
    if(set){CFIndex n=CFSetGetCount(set);IOHIDDeviceRef*a=calloc(n,sizeof(IOHIDDeviceRef));CFSetGetValues(set,(const void**)a);
        for(CFIndex i=0;i<n;i++){CFTypeRef t=IOHIDDeviceGetProperty(a[i],CFSTR("Transport"));
            if(t&&CFGetTypeID(t)==CFStringGetTypeID()&&CFStringCompare((CFStringRef)t,CFSTR("Bluetooth"),0)==0){dev=a[i];break;}}
        free(a);CFRelease(set);}
    if(!dev){printf("нет DS4\n");return 1;}
    static uint8_t buf[4096];
    IOHIDDeviceRegisterInputReportCallback(dev, buf, sizeof(buf), cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    printf("%-6s %-9s %-9s %-9s %s\n","t,с","отч/с","мс/отч","КБ/с","что это значит");
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - start < secs) {
        cnt = 0; bytes = 0;
        CFAbsoluteTime w0 = CFAbsoluteTimeGetCurrent();
        while (CFAbsoluteTimeGetCurrent() - w0 < 1.0)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
        double dt = CFAbsoluteTimeGetCurrent() - w0;
        double rate = cnt / dt, ms = 1000.0 / rate;
        const char *hint = ms < 9 ? "очень быстро" : ms < 12.5 ? "11.25 мс" :
                           ms < 16.5 ? "15 мс" : "медленнее 15 мс";
        printf("%-6.0f %-9.1f %-9.2f %-9.2f %s\n",
               CFAbsoluteTimeGetCurrent() - start, rate, ms, bytes / dt / 1024.0, hint);
    }
    IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    return 0;
}
