//
//  StaticInfoFetcher.c
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//

// MARK: - StaticInfoFetcher.c
// This file contains utility functions that fetch static information about audio devices,
// such as their name, sample rate, and transport type using CoreAudio APIs.

#include "AudioUtilities.h"
#include <CoreFoundation/CoreFoundation.h>

// MARK: - Get Device Name
// Returns the human-readable name of the given audio device.
const char* getDeviceName(AudioDeviceID deviceID) {
    static char name[128] = "Unknown";
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return name;
    CFStringRef cfName = NULL;
    UInt32 size = sizeof(cfName);

    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };

    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &cfName) == noErr && cfName) {
        CFStringGetCString(cfName, name, sizeof(name), kCFStringEncodingUTF8);
        CFRelease(cfName);
    }

    return name;
}

// MARK: - Device Validity Check
// Returns true if the specified device ID corresponds to a currently connected and available device.
bool isDeviceValid(AudioDeviceID deviceID) {
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return false;
    UInt32 dataSize = 0;
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };

    return (AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &dataSize) == noErr);
}

// MARK: - Get Sample Rate
// Returns the nominal sample rate (in Hz) of the specified audio device.
Float64 getSampleRate(AudioDeviceID deviceID) {
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return 0;
    Float64 sampleRate = 0;
    UInt32 size = sizeof(sampleRate);
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };

    AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &sampleRate);
    return sampleRate;
}

// MARK: - Get Transport Type
// Returns a descriptive string for the transport type of the specified audio device,
// such as USB, Bluetooth, or Built-in.
const char* getDeviceTransportType(AudioDeviceID deviceID) {
    static char transport[64] = "Unknown";
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return transport;
    UInt32 transportType = 0;
    UInt32 size = sizeof(transportType);

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };

    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &transportType) == noErr) {
        switch (transportType) {
            case kAudioDeviceTransportTypeBuiltIn: return "Built-in";
            case kAudioDeviceTransportTypeAggregate: return "Aggregate";
            case kAudioDeviceTransportTypeAutoAggregate: return "AutoAggregate";
            case kAudioDeviceTransportTypeVirtual: return "Virtual";
            case kAudioDeviceTransportTypePCI: return "PCI";
            case kAudioDeviceTransportTypeUSB: return "USB";
            case kAudioDeviceTransportTypeFireWire: return "FireWire";
            case kAudioDeviceTransportTypeBluetooth: return "Bluetooth";
            case kAudioDeviceTransportTypeHDMI: return "HDMI";
            case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort";
            default: return "Other";
        }
    }

    return transport;
}
