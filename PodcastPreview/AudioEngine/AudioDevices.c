//
//  AudioDevices.c
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <stdlib.h>

AudioDeviceID AudioDevices_FindDeviceByUID(const char *uidCString);

// Helper: check whether a device has any input channels
static Boolean AudioDevices_DeviceHasInput(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size);
    if (err != noErr || size == 0) {
        return false;
    }

    AudioBufferList *bufferList = (AudioBufferList *)malloc(size);
    if (!bufferList) {
        return false;
    }

    err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, bufferList);
    if (err != noErr) {
        free(bufferList);
        return false;
    }

    UInt32 channelCount = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        channelCount += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return (channelCount > 0);
}

static Boolean AudioDevices_DeviceHasOutput(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size);
    if (err != noErr || size == 0) {
        return false;
    }

    AudioBufferList *bufferList = (AudioBufferList *)malloc(size);
    if (!bufferList) {
        return false;
    }

    err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, bufferList);
    if (err != noErr) {
        free(bufferList);
        return false;
    }

    UInt32 channelCount = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        channelCount += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return (channelCount > 0);
}

// Return the total number of input channels for a device.
// Returns 0 if the device has no input channels or on error.
UInt32 AudioDevices_GetInputChannelCount(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress){
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size);
    if (err != noErr || size == 0) {
        return 0;
    }

    AudioBufferList *bufferList = (AudioBufferList *)malloc(size);
    if (!bufferList) {
        return 0;
    }

    err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, bufferList);
    if (err != noErr) {
        free(bufferList);
        return 0;
    }

    UInt32 channelCount = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        channelCount += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return channelCount;
}

// Return the total number of output channels for a device.
// Returns 0 if the device has no output channels or on error.
UInt32 AudioDevices_GetOutputChannelCount(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress){
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size);
    if (err != noErr || size == 0) {
        return 0;
    }

    AudioBufferList *bufferList = (AudioBufferList *)malloc(size);
    if (!bufferList) {
        return 0;
    }

    err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, bufferList);
    if (err != noErr) {
        free(bufferList);
        return 0;
    }

    UInt32 channelCount = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        channelCount += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return channelCount;
}

// Return the device's nominal sample rate in Hz (as a double). Returns 0.0 on error.
double AudioDevices_GetDeviceSampleRate(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress){
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    Float64 sampleRate = 0.0;
    UInt32 size = sizeof(Float64);
    OSStatus err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &sampleRate);
    if (err != noErr) {
        return 0.0;
    }
    return (double)sampleRate;
}

OSStatus AudioDevices_SetDeviceSampleRate(AudioDeviceID deviceID, double sampleRate) {
    if (deviceID == kAudioObjectUnknown || sampleRate <= 0.0) {
        return kAudio_ParamError;
    }

    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress){
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    Float64 requestedRate = sampleRate;
    UInt32 size = sizeof(Float64);
    return AudioObjectSetPropertyData(deviceID, &addr, 0, NULL, size, &requestedRate);
}

OSStatus AudioDevices_SetDeviceSampleRateByUID(const char *uidCString, double sampleRate) {
    AudioDeviceID deviceID = AudioDevices_FindDeviceByUID(uidCString);
    if (deviceID == kAudioObjectUnknown) {
        return kAudioHardwareBadObjectError;
    }
    return AudioDevices_SetDeviceSampleRate(deviceID, sampleRate);
}

// Copy the device manufacturer name into outName (UTF-8). maxLen includes the null terminator.
OSStatus AudioDevices_GetDeviceManufacturer(AudioDeviceID deviceID, char *outName, UInt32 maxLen) {
    if (!outName || maxLen == 0) {
        return kAudio_ParamError;
    }

    AudioObjectPropertyAddress addr = {
        kAudioObjectPropertyManufacturer,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFStringRef manufacturerRef = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &manufacturerRef);
    if (err != noErr || !manufacturerRef) {
        return err != noErr ? err : kAudio_ParamError;
    }

    Boolean ok = CFStringGetCString(manufacturerRef, outName, maxLen, kCFStringEncodingUTF8);
    CFRelease(manufacturerRef);

    if (!ok) {
        return kAudio_ParamError;
    }

    return noErr;
}

// Simplified transport type for UI: 0 = unknown, 1 = built-in, 2 = USB, 3 = FireWire, 4 = Network, 5 = Aggregate, 6 = Virtual/ASP
UInt32 AudioDevices_GetDeviceTransportType(AudioDeviceID deviceID) {
    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress){
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 transport = 0;
    UInt32 size = sizeof(UInt32);
    OSStatus err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &transport);
    if (err != noErr) {
        return 0; // unknown
    }

    switch (transport) {
        case kAudioDeviceTransportTypeBuiltIn:   return 1;
        case kAudioDeviceTransportTypeUSB:       return 2;
        case kAudioDeviceTransportTypeFireWire:  return 3;
#ifdef kAudioDeviceTransportTypeAVB
        case kAudioDeviceTransportTypeAVB:       return 4; // treat AVB as network
#endif
        case kAudioDeviceTransportTypeAggregate: return 5;
        case kAudioDeviceTransportTypeVirtual:   return 6;
        default:                                 return 0;
    }
}

// Return all input-capable devices. The function writes up to maxDevices IDs into outDevices
// and returns the number of input devices found (which may be <= maxDevices).
UInt32 AudioDevices_GetAllInputDevices(AudioDeviceID *outDevices, UInt32 maxDevices) {
    if (!outDevices || maxDevices == 0) {
        return 0;
    }

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    if (err != noErr || size == 0) {
        return 0;
    }

    UInt32 deviceCount = size / sizeof(AudioDeviceID);
    AudioDeviceID *allDevices = (AudioDeviceID *)malloc(size);
    if (!allDevices) {
        return 0;
    }

    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, allDevices);
    if (err != noErr) {
        free(allDevices);
        return 0;
    }

    UInt32 inputCount = 0;
    for (UInt32 i = 0; i < deviceCount && inputCount < maxDevices; ++i) {
        if (AudioDevices_DeviceHasInput(allDevices[i])) {
            outDevices[inputCount++] = allDevices[i];
        }
    }

    free(allDevices);
    return inputCount;
}

UInt32 AudioDevices_GetAllOutputDevices(AudioDeviceID *outDevices, UInt32 maxDevices) {
    if (!outDevices || maxDevices == 0) {
        return 0;
    }

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    if (err != noErr || size == 0) {
        return 0;
    }

    UInt32 deviceCount = size / sizeof(AudioDeviceID);
    AudioDeviceID *allDevices = (AudioDeviceID *)malloc(size);
    if (!allDevices) {
        return 0;
    }

    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, allDevices);
    if (err != noErr) {
        free(allDevices);
        return 0;
    }

    UInt32 outputCount = 0;
    for (UInt32 i = 0; i < deviceCount && outputCount < maxDevices; ++i) {
        if (AudioDevices_DeviceHasOutput(allDevices[i])) {
            outDevices[outputCount++] = allDevices[i];
        }
    }

    free(allDevices);
    return outputCount;
}

// Get the current default input device (may return kAudioObjectUnknown on error)
AudioDeviceID AudioDevices_GetDefaultInputDevice(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = sizeof(AudioDeviceID);
    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID);
    if (err != noErr) {
        return kAudioObjectUnknown;
    }

    return deviceID;
}

AudioDeviceID AudioDevices_GetDefaultOutputDevice(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = sizeof(AudioDeviceID);
    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID);
    if (err != noErr) {
        return kAudioObjectUnknown;
    }

    return deviceID;
}

// Copy a human-readable device name into outName (UTF-8). maxLen includes the null terminator.
OSStatus AudioDevices_GetDeviceName(AudioDeviceID deviceID, char *outName, UInt32 maxLen) {
    if (!outName || maxLen == 0) {
        return kAudio_ParamError;
    }

    AudioObjectPropertyAddress addr = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFStringRef nameRef = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &nameRef);
    if (err != noErr || !nameRef) {
        return err != noErr ? err : kAudio_ParamError;
    }

    Boolean ok = CFStringGetCString(nameRef, outName, maxLen, kCFStringEncodingUTF8);
    CFRelease(nameRef);

    if (!ok) {
        return kAudio_ParamError;
    }

    return noErr;
}

// Copy the device UID into outUID (UTF-8). maxLen includes the null terminator.
OSStatus AudioDevices_GetDeviceUID(AudioDeviceID deviceID, char *outUID, UInt32 maxLen) {
    if (!outUID || maxLen == 0) {
        return kAudio_ParamError;
    }

    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    CFStringRef uidRef = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus err = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &uidRef);
    if (err != noErr || !uidRef) {
        return err != noErr ? err : kAudio_ParamError;
    }

    Boolean ok = CFStringGetCString(uidRef, outUID, maxLen, kCFStringEncodingUTF8);
    CFRelease(uidRef);

    if (!ok) {
        return kAudio_ParamError;
    }

    return noErr;
}

// Find a device by its UID (as a C string). Returns kAudioObjectUnknown if not found.
AudioDeviceID AudioDevices_FindDeviceByUID(const char *uidCString) {
    if (!uidCString) {
        return kAudioObjectUnknown;
    }

    // Enumerate all devices and compare their UIDs
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    if (err != noErr || size == 0) {
        return kAudioObjectUnknown;
    }

    UInt32 deviceCount = size / sizeof(AudioDeviceID);
    AudioDeviceID *allDevices = (AudioDeviceID *)malloc(size);
    if (!allDevices) {
        return kAudioObjectUnknown;
    }

    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, allDevices);
    if (err != noErr) {
        free(allDevices);
        return kAudioObjectUnknown;
    }

    AudioDeviceID result = kAudioObjectUnknown;

    for (UInt32 i = 0; i < deviceCount; ++i) {
        char uidBuffer[256];
        if (AudioDevices_GetDeviceUID(allDevices[i], uidBuffer, sizeof(uidBuffer)) == noErr) {
            if (strcmp(uidBuffer, uidCString) == 0) {
                result = allDevices[i];
                break;
            }
        }
    }

    free(allDevices);
    return result;
}
