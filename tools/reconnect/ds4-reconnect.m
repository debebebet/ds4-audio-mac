// Держит ACL-соединение с DS4 живым. Запускать: ./ds4-reconnect [секунды]
// Нужен, потому что IOBluetooth-соединение рвётся, когда процесс завершается,
// а DS4 после этого уходит в сон и требует нажатия PS.
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

static IOBluetoothDevice *dev(void){
  BluetoothDeviceAddress a; unsigned char *b = (unsigned char *)&a;
  unsigned v[6]; const char *s = getenv("DS4_ADDRESS");
  if (!s) s = "AA:BB:CC:DD:EE:FF";
  if(sscanf(s, "%x:%x:%x:%x:%x:%x", &v[0],&v[1],&v[2],&v[3],&v[4],&v[5]) != 6) return nil;
  for(int i=0;i<6;i++) b[i] = (unsigned char)v[i];
  return [IOBluetoothDevice withAddress:&a];
}

int main(int argc, char **argv){
  @autoreleasepool{
    setvbuf(stdout, NULL, _IONBF, 0);
    int secs = argc > 1 ? atoi(argv[1]) : 120;
    printf("DS4 reconnect: держу соединение %d c (прервать Ctrl-C)\n", secs);
    for(int t = 0; t < secs; t++){
      IOBluetoothDevice *d = dev();
      if(!d){ printf("не нашёл устройство в базе\n"); sleep(1); continue; }
      if(d.isConnected){
        if(t % 5 == 0) printf("[%3ds] connected\n", t);
        sleep(1);
        continue;
      }
      printf("[%3ds] not connected -> openConnection\n", t);
      IOReturn r = [d openConnection];
      if(r != kIOReturnSuccess) printf("        openConnection = 0x%08x\n", r);
      for(int i = 0; i < 20 && !d.isConnected; i++) usleep(250000);
      printf("        result: connected=%d\n", d.isConnected);
    }
    printf("done, connection left as is (процесс завершится — DS4 может уснуть)\n");
    // не выходим сразу: даём контроллеру время, чтобы не рвать линк в момент close
    sleep(300);
  }
  return 0;
}
