// Обход ограничения Swift: openL2CAPChannel:findExisting:newChannel: помечен
// как deprecated (macOS 10.9) и недоступен из Swift, но позволяет получить
// L2CAP-канал, уже открытый стеком macOS (HIDP держит control 0x11 и
// interrupt 0x13).
#import <IOBluetooth/IOBluetooth.h>

IOReturn L2CAPFindExistingChannel(IOBluetoothDevice *device,
                                  BluetoothL2CAPPSM psm,
                                  IOBluetoothL2CAPChannel **outChannel);
