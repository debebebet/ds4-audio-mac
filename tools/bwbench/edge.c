// edge.c — быстрый тест «где край одного окна».
// Меряет время записи отчёта 78 B и 79 B. Если окно 15.2 мс — будет 15.2 / 28.3.
// Если окно уменьшилось вдвое — станет ~7.6 / ~15.2.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static uint32_t tbl[256];
static void crcInit(void){for(uint32_t i=0;i<256;i++){uint32_t c=i;for(int k=0;k<8;k++)c=(c&1)?(c>>1)^0xEDB88320:(c>>1);tbl[i]=c;}}
static uint32_t crcOf(const uint8_t*p,size_t n,uint8_t pre){uint32_t c=0xFFFFFFFF;c=(c>>8)^tbl[(c^pre)&0xFF];for(size_t i=0;i<n;i++)c=(c>>8)^tbl[(c^p[i])&0xFF];return ~c;}

static IOHIDDeviceRef gDev;
static IOHIDDeviceRef findDS4(void){
    IOHIDManagerRef mgr=IOHIDManagerCreate(kCFAllocatorDefault,kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef m=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int vid=0x054C,pid=0x09CC;
    CFNumberRef nv=CFNumberCreate(NULL,kCFNumberIntType,&vid),np=CFNumberCreate(NULL,kCFNumberIntType,&pid);
    CFDictionarySetValue(m,CFSTR(kIOHIDVendorIDKey),nv);CFDictionarySetValue(m,CFSTR(kIOHIDProductIDKey),np);
    IOHIDManagerSetDeviceMatching(mgr,m);IOHIDManagerOpen(mgr,kIOHIDOptionsTypeNone);
    CFSetRef set=IOHIDManagerCopyDevices(mgr);IOHIDDeviceRef dev=NULL;
    if(set){CFIndex n=CFSetGetCount(set);IOHIDDeviceRef*a=calloc(n,sizeof(IOHIDDeviceRef));CFSetGetValues(set,(const void**)a);
        for(CFIndex i=0;i<n;i++){CFTypeRef t=IOHIDDeviceGetProperty(a[i],CFSTR("Transport"));
            if(t&&CFGetTypeID(t)==CFStringGetTypeID()&&CFStringCompare((CFStringRef)t,CFSTR("Bluetooth"),0)==0){dev=a[i];break;}}
        free(a);CFRelease(set);}
    return dev;
}
// Возвращает мс на отчёт для данной длины.
static double measure(int len,uint8_t rid,int nReports){
    uint8_t*b=calloc(1,len);
    int k=0;
    for(int i=0;i<3;i++){ // прогрев
        memset(b,0,len);b[0]=rid;b[1]=0x40;b[2]=0xA0;b[3]=k&0xFF;b[4]=(k>>8)&0xFF;b[5]=0x02;
        uint32_t c=crcOf(b,len-4,0xA2);memcpy(b+len-4,&c,4);
        IOHIDDeviceSetReport(gDev,kIOHIDReportTypeOutput,rid,b,len);k++;
    }
    double t0=CFAbsoluteTimeGetCurrent();
    for(int i=0;i<nReports;i++){
        memset(b,0,len);b[0]=rid;b[1]=0x40;b[2]=0xA0;b[3]=k&0xFF;b[4]=(k>>8)&0xFF;b[5]=0x02;
        uint32_t c=crcOf(b,len-4,0xA2);memcpy(b+len-4,&c,4);
        IOHIDDeviceSetReport(gDev,kIOHIDReportTypeOutput,rid,b,len);k++;
    }
    double dt=CFAbsoluteTimeGetCurrent()-t0;
    free(b);
    return dt/nReports*1000.0;
}
int main(int argc,char**argv){
    crcInit();
    gDev=findDS4();
    if(!gDev){printf("нет DS4\n");return 1;}
    int n=argc>1?atoi(argv[1]):30;
    double a=measure(78,0x16,n), b=measure(79,0x16,n);
    double win = (b > a*1.5) ? a : 0;   // если 79 заметно дороже — a это и есть окно
    printf("78B: %5.1f мс   79B: %5.1f мс   -> окно ~%.1f мс (%.2f x от 15.2)\n", a, b, win, 15.2/win);
    return 0;
}
