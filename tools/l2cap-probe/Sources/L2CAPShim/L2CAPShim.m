#import "include/L2CAPShim.h"

IOReturn L2CAPFindExistingChannel(IOBluetoothDevice *device,
                                  BluetoothL2CAPPSM psm,
                                  IOBluetoothL2CAPChannel **outChannel)
{
    return [device openL2CAPChannel:psm findExisting:YES newChannel:outChannel];
}
