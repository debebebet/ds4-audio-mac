// boundary.c — найти точную границу «1 пакет / 2 пакета».
// Гипотеза: ACL-пакет несёт 83 байта = 5 (L2CAP+HIDP) + 78 (отчёт).
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
    printf("%-5s %-8s %-9s %-8s %s\n", "B", "мс/отч", "отч/с", "КБ/с", "пакетов(модель)");
    for (int len = 72; len <= 100; len++) {
        uint8_t *b = calloc(1, len);
        int ok = 0, k = 0;
        double t0 = CFAbsoluteTimeGetCurrent();
        while (CFAbsoluteTimeGetCurrent() - t0 < 1.2) {
            memset(b,0,len); b[0]=0x11; b[1]=0x40; b[2]=0xA0;
            b[3]=k&0xFF; b[4]=(k>>8)&0xFF;
            uint32_t crc=crcOf(b,len-4,0xA2); memcpy(b+len-4,&crc,4);
            if (IOHIDDeviceSetReport(gDev,kIOHIDReportTypeOutput,0x11,b,len)==kIOReturnSuccess) ok++;
            k++;
        }
        double dt = CFAbsoluteTimeGetCurrent()-t0;
        int pk = (len + 5 + 82) / 83;
        printf("%-5d %-8.1f %-9.1f %-8.2f %d\n", len, dt/ok*1000, ok/dt, ok*(double)len/dt/1024.0, pk);
        free(b);
    }
    return 0;
}
