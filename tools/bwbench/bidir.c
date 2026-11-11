// bidir.c — вход и выход одновременно, с прокачкой run loop между записями.
// Если линк в sniff с окном 15 мс, суммарный бюджет ~2 пакета (по одному
// в каждую сторону) за окно, и насыщение выхода не «съедает» вход.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

static volatile int inCount = 0;
static volatile long inBytes = 0;
static void inCB(void *c, IOReturn r, void *s, IOHIDReportType t, uint32_t rid, uint8_t *rep, CFIndex len) {
    inCount++; inBytes += len;
}
static IOHIDDeviceRef gDev;

static IOHIDDeviceRef findDS4(void) {
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
    return dev;
}

static void run(const char *label, int outLen, int sendOutput, double secs) {
    inCount = 0; inBytes = 0;
    uint8_t *b = calloc(1, outLen);
    int ok = 0, k = 0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    while (CFAbsoluteTimeGetCurrent() - t0 < secs) {
        if (sendOutput) {
            memset(b,0,outLen); b[0]=0x11; b[1]=0x40; b[2]=0xA0;
            b[3]=k&0xFF; b[4]=(k>>8)&0xFF;
            uint32_t crc=crcOf(b,outLen-4,0xA2); memcpy(b+outLen-4,&crc,4);
            if (IOHIDDeviceSetReport(gDev,kIOHIDReportTypeOutput,0x11,b,outLen)==kIOReturnSuccess) ok++;
            k++;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.001, true);
    }
    double dt = CFAbsoluteTimeGetCurrent()-t0;
    free(b);
    printf("%-30s вход %5.1f отч/с (%5.2f КБ/с)  выход %5.2f КБ/с  сумма %5.2f КБ/с\n",
           label, inCount/dt, inBytes/dt/1024.0, ok*(double)outLen/dt/1024.0,
           (inBytes + ok*(double)outLen)/dt/1024.0);
}

int main(void) {
    crcInit();
    gDev = findDS4();
    if (!gDev) { printf("нет DS4\n"); return 1; }
    static uint8_t buf[4096];
    IOHIDDeviceRegisterInputReportCallback(gDev, buf, sizeof(buf), inCB, NULL);
    IOHIDDeviceScheduleWithRunLoop(gDev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, true);
    run("только вход", 78, 0, 4.0);
    run("вход + выход 78 B", 78, 1, 4.0);
    run("вход + выход 526 B", 526, 1, 4.0);
    run("только вход (контроль)", 78, 0, 4.0);
    IOHIDDeviceUnscheduleFromRunLoop(gDev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    return 0;
}
