//
//  AudioBridge.mm
//  AVCMeter
//
// Acts as an Objective-C++ bridge between Swift/Obj-C layers and low-level C CoreAudio metering logic.
// This file links in several C headers related to CoreAudio device handling, stream management, and metering.
// Provides a unified interface for starting audio metering on a specific device via `startMeteringWithCallback`.
//

#import "AudioBridge.h"

// ===== CoreAudio C Header Links =====
extern "C" {
#include "../CoreAudioUtilities/AudioUtilities.h"
#include "../Mixer - C Streams/IOStreams.h"





// ===== Device Enumeration Helper =====
int getAllInputAudioDeviceIDs(AudioDeviceID* outDevices, int maxDevices) {
    // Query system for all audio devices using CoreAudio API
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };

    AudioDeviceID deviceList[64];
    UInt32 dataSize = sizeof(deviceList);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &dataSize, deviceList) != noErr)
        return 0;

    int deviceCount = dataSize / sizeof(AudioDeviceID);
    int inputCount = 0;

    // Filter out non-input devices and populate the output list
    for (int i = 0; i < deviceCount && inputCount < maxDevices; ++i) {
        if (deviceList[i] == 0 || deviceList[i] == kAudioObjectUnknown) continue;
        if (deviceHasInput(deviceList[i])) {
            outDevices[inputCount++] = deviceList[i];         }
    }

    // Return the total number of input-capable devices found
    return inputCount;
}

}
