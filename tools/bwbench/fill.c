// fill.c — проверка «плотной упаковки»: длины отчётов 78 + 83k
// заполняют ACL-пакет целиком и дают максимум байт за слот.
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

static void bench(int len, uint8_t rid, double secs, int *okOut, double *dtOut) {
    uint8_t *b = calloc(1, len);
    int ok = 0, fail = 0, k = 0;
    double t0 = CFAbsoluteTimeGetCurrent(), end = t0 + secs;
    while (CFAbsoluteTimeGetCurrent() < end) {
        memset(b,0,len); b[0]=rid; b[1]=0x40; b[2]=0xA0;
        b[3]=k&0xFF; b[4]=(k>>8)&0xFF; b[5]=0x02;
        uint32_t crc=crcOf(b,len-4,0xA2); memcpy(b+len-4,&crc,4);
        if (IOHIDDeviceSetReport(gDev,kIOHIDReportTypeOutput,rid,b,len)==kIOReturnSuccess) ok++; else fail++;
        k++;
    }
    *dtOut = CFAbsoluteTimeGetCurrent()-t0;
    *okOut = ok;
    free(b);
}

int main(int argc, char **argv) {
    crcInit();
    gDev = findDS4();
    if (!gDev) { printf("нет DS4\n"); return 1; }
    double secs = argc > 1 ? atof(argv[1]) : 3.0;
    printf("%-5s %-6s %-9s %-8s %-9s %-10s\n", "B", "ID", "отч/с", "КБ/с", "аудио-Б/с", "% реалтайма(bp12)");
    int lens[] = {78, 161, 244, 327, 410, 493, 462, 526, 547};
    uint8_t ids[] = {0x11,0x11,0x13,0x15,0x17,0x19,0x17,0x18,0x19};
    for (int i = 0; i < 9; i++) {
        int ok = 0; double dt = 0;
        bench(lens[i], ids[i], secs, &ok, &dt);
        int audio = lens[i] - 10;                 // 6 байт заголовка + 4 CRC
        int frames = audio / 37;                  // joint 16 кГц bp12
        double audioMs = frames * 8.0;
        printf("%-5d 0x%-4x %-9.1f %-8.2f %-9.0f %-10.1f\n",
               lens[i], ids[i], ok/dt, ok*(double)lens[i]/dt/1024.0,
               ok*(double)(frames*37)/dt, ok*audioMs/dt*100);
    }
    return 0;
}
