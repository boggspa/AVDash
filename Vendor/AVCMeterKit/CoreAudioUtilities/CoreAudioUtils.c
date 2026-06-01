//
//  CoreAudioUtils.c
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//

/**
 * CoreAudioUtils.c
 * Implements helper functions for querying CoreAudio device stream properties.
 *
 * This file provides basic methods for checking input/output availability
 * and counting audio channels on CoreAudio devices.
 */

#include "AudioUtilities.h"

// **Check for Input Channels**
// Returns true if the audio device has any input streams.
Boolean deviceHasInput(AudioDeviceID deviceID) {
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return false;

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMaster
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &dataSize);
    return (status == noErr && dataSize > 0);
}

// **Check for Output Channels**
// Returns true if the audio device has any output streams.
Boolean deviceHasOutput(AudioDeviceID deviceID) {
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return false;

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMaster
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &dataSize);
    return (status == noErr && dataSize > 0);
}

// **Input Channel Count**
// Retrieves and sums the number of input channels across all input buffers.
UInt32 getDeviceInputChannelCount(AudioDeviceID deviceID) {
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return 0;

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMaster
    };

    UInt32 dataSize = 0;
    AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &dataSize);
    AudioBufferList* bufferList = (AudioBufferList*)malloc(dataSize);

    if (!bufferList) return 0;

    AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &dataSize, bufferList);

    UInt32 channelCount = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        channelCount += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return channelCount;
}

// **Output Channel Count**
// Retrieves and sums the number of output channels across all output buffers.
UInt32 getDeviceOutputChannelCount(AudioDeviceID deviceID) {
    if (deviceID == 0 || deviceID == kAudioObjectUnknown) return 0;

    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMaster
    };

    UInt32 dataSize = 0;
    AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &dataSize);
    AudioBufferList* bufferList = (AudioBufferList*)malloc(dataSize);

    if (!bufferList) return 0;

    AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &dataSize, bufferList);

    UInt32 channelCount = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        channelCount += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return channelCount;
}
