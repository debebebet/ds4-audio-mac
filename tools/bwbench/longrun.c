// longrun.c — устойчивый прогон 30 с: не адаптируется ли линк со временем
// (как A2DP Link Adaptive Packet Type) к большим пакетам.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

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

int main(int argc, char **argv) {
    crcInit();
    gDev = findDS4();
    if (!gDev) { printf("нет DS4\n"); return 1; }
    int len = argc > 1 ? atoi(argv[1]) : 400;
    uint8_t rid = argc > 2 ? (uint8_t)strtol(argv[2], NULL, 16) : 0x17;
    double secs = argc > 3 ? atof(argv[3]) : 30.0;

    uint8_t *b = calloc(1, len);
    int k = 0;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent(), winStart = start;
    int winOk = 0;
    printf("%-6s %-9s %-8s %-9s\n", "t,с", "отч/с", "КБ/с", "мс/отч");
    while (CFAbsoluteTimeGetCurrent() - start < secs) {
        memset(b,0,len); b[0]=rid; b[1]=0x40; b[2]=0xA0;
        b[3]=k&0xFF; b[4]=(k>>8)&0xFF; b[5]=0x02;
        uint32_t crc=crcOf(b,len-4,0xA2); memcpy(b+len-4,&crc,4);
        if (IOHIDDeviceSetReport(gDev,kIOHIDReportTypeOutput,rid,b,len)==kIOReturnSuccess) winOk++;
        k++;
        double now = CFAbsoluteTimeGetCurrent();
        if (now - winStart >= 3.0) {
            double dt = now - winStart;
            printf("%-6.0f %-9.1f %-8.2f %-9.1f\n", now - start, winOk/dt,
                   winOk*(double)len/dt/1024.0, dt/winOk*1000);
            winStart = now; winOk = 0;
        }
    }
    free(b);
    return 0;
}
