//
//  AudioUtils.cpp
//  AVCMeter
//
//  Created by Chris Izatt on 13/07/2025.
//

#include "AudioUtils.hpp"
#include <CoreAudio/CoreAudio.h>

int GetInputChannelCount(AudioDeviceID deviceID) {
    UInt32 size = 0;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nullptr, &size);

    auto bufferList = (AudioBufferList*)malloc(size);
    AudioObjectGetPropertyData(deviceID, &addr, 0, nullptr, &size, bufferList);

    int count = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        count += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return count;
}

int GetOutputChannelCount(AudioDeviceID deviceID) {
    UInt32 size = 0;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };

    AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nullptr, &size);

    auto bufferList = (AudioBufferList*)malloc(size);
    AudioObjectGetPropertyData(deviceID, &addr, 0, nullptr, &size, bufferList);

    int count = 0;
    for (UInt32 i = 0; i < bufferList->mNumberBuffers; ++i) {
        count += bufferList->mBuffers[i].mNumberChannels;
    }

    free(bufferList);
    return count;
}
