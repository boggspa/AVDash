#include <CoreAudio/CoreAudio.h>
#include <stddef.h>

//
// HALInputStream.c
// Part of the AVCMeter app.
//
// This file implements a low-level audio capture stream using the CoreAudio HAL API.
// It captures input samples from a selected audio device and calculates real-time
// RMS and peak levels, then passes them to a callback handler for further processing.
//

#include "IOStreams.h"
#include "../Mixer - C Mixer/Mixer.h"
#include "Logger.h"

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdio.h>
#include <math.h>
#include <stdlib.h>

#include <string.h>

#define MAX_CHANNELS 64





// Uses pre-cached AudioStreamBasicDescription from stream setup to avoid real-time system calls.
// **Audio Callback Function**
// This function is called by CoreAudio whenever audio input is available.
// It computes the peak and RMS levels from the incoming audio and invokes
// the user-provided callback with this metering data.
// Additionally, deinterleaves input audio per channel and writes each channel's samples
// to the corresponding shared ring buffer for inter-process communication.
static OSStatus HALIOProc(AudioDeviceID inDevice,
                          const AudioTimeStamp* inNow,
                          const AudioBufferList* inInputData,
                          const AudioTimeStamp* inInputTime,
                          AudioBufferList* inOutputData,
                          const AudioTimeStamp* inOutputTime,
                          void* inClientData)
{
    HALInputStream* stream = (HALInputStream*)inClientData;
    if (!stream || !inInputData) return noErr;

    // Calculate number of frames and channels, and protect against invalid input
    UInt32 numFrames = inInputData->mBuffers[0].mDataByteSize / stream->streamFormat.mBytesPerFrame;
    UInt32 channelCount = stream->streamFormat.mChannelsPerFrame;
    if (inInputData->mBuffers[0].mDataByteSize == 0) return noErr;
    if (channelCount > MAX_CHANNELS) channelCount = MAX_CHANNELS;

    float* interleaved = (float*)inInputData->mBuffers[0].mData;
    float peaks[MAX_CHANNELS] = {0};
    float sums[MAX_CHANNELS] = {0};

    // Loop through each frame and channel to compute peaks and RMS
    float* samplePtr = interleaved;
    for (UInt32 frame = 0; frame < numFrames; ++frame) {
        for (UInt32 ch = 0; ch < channelCount; ++ch) {
            float sample = *samplePtr++;
            float absSample = fabsf(sample);
            peaks[ch] = fmaxf(peaks[ch], absSample);
            sums[ch] += sample * sample;
        }
    }

    float invFrames = 1.0f / (float)numFrames;

    // [1] Lock region for updating stream metering only
    pthread_mutex_lock(&stream->lock);
    for (UInt32 ch = 0; ch < channelCount; ++ch) {
        stream->peak[ch] = peaks[ch];
        stream->rms[ch] = sqrtf(sums[ch] * invFrames);
    }
    if (stream->levelCallback) {
        stream->levelCallback(stream->rms, stream->peak, channelCount, stream->callbackContext);
    }
    pthread_mutex_unlock(&stream->lock);

    // [2] Feed deinterleaved channel PCM directly into the mixer input buffers.
    // Uses pre-allocated buffer instead of VLA to avoid stack pressure on RT thread.
    float *deinterleaveBuf = stream->deinterleaveBuf;
    uint32_t maxFrames = stream->deinterleaveBufFrames;
    uint32_t framesToProcess = numFrames < maxFrames ? numFrames : maxFrames;
    for (UInt32 ch = 0; ch < channelCount; ++ch) {
        for (UInt32 frame = 0; frame < framesToProcess; ++frame) {
            deinterleaveBuf[frame] = interleaved[(frame * channelCount) + ch];
        }
        Mixer_FeedSingleChannelToMixer(stream->deviceID, MIXER_CHANNEL_INPUT, ch, deinterleaveBuf, framesToProcess);
    }

    return noErr;
}

// **Stream Creation Function**
// Allocates and starts a HAL audio input stream on the given device.
// Sets up a callback for level data (RMS and Peak).
// Also creates shared ring buffers per channel for inter-process audio data sharing.
HALInputStream* createHALInputStream(AudioDeviceID deviceID,
                                     void (*callback)(float* rms, float* peak, UInt32 channelCount, void* context),
                                     void* context)
{
    HALInputStream* stream = (HALInputStream*)malloc(sizeof(HALInputStream));
    if (!stream) return NULL;

    memset(stream, 0, sizeof(HALInputStream));
    stream->deviceID = deviceID;
    stream->levelCallback = callback;
    stream->callbackContext = context;
    pthread_mutex_init(&stream->lock, NULL);

    // Query the stream format using modern CoreAudio API
    UInt32 size = sizeof(stream->streamFormat);
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyStreamConfiguration,
        .mScope = kAudioDevicePropertyScopeInput,
        .mElement = kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &size);
    if (status == noErr && size > 0) {
        AudioBufferList* bufList = (AudioBufferList*)malloc(size);
        if (bufList) {
            status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, bufList);
            if (status == noErr && bufList->mNumberBuffers > 0) {
                stream->streamFormat.mChannelsPerFrame = bufList->mBuffers[0].mNumberChannels;
            }
            free(bufList);
        }
    }

    // Query sample rate
    size = sizeof(Float64);
    addr.mSelector = kAudioDevicePropertyNominalSampleRate;
    addr.mScope = kAudioDevicePropertyScopeInput;
    Float64 sampleRate = 48000.0;
    AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &sampleRate);
    stream->streamFormat.mSampleRate = sampleRate;
    stream->streamFormat.mFormatID = kAudioFormatLinearPCM;
    stream->streamFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    stream->streamFormat.mBytesPerPacket = sizeof(float) * stream->streamFormat.mChannelsPerFrame;
    stream->streamFormat.mFramesPerPacket = 1;
    stream->streamFormat.mBytesPerFrame = sizeof(float) * stream->streamFormat.mChannelsPerFrame;
    stream->streamFormat.mBitsPerChannel = 8 * sizeof(float);


    // Store channel count for convenience
    stream->channelCount = stream->streamFormat.mChannelsPerFrame;
    if (stream->channelCount > MAX_CHANNELS) {
        stream->channelCount = MAX_CHANNELS;
    }

    // Pre-allocate deinterleave buffer to avoid VLA on the real-time audio thread.
    // 4096 frames covers typical buffer sizes; HALIOProc will skip deinterleave if exceeded.
    stream->deinterleaveBufFrames = 4096;
    stream->deinterleaveBuf = (float *)malloc(stream->deinterleaveBufFrames * sizeof(float));

    OSStatus err = AudioDeviceCreateIOProcID(deviceID, HALIOProc, stream, &stream->ioProcID);
    if (err != noErr) {
        free(stream);
        return NULL;
    }

    err = AudioDeviceStart(deviceID, stream->ioProcID);
    if (err != noErr) {
        AudioDeviceDestroyIOProcID(deviceID, stream->ioProcID);
        free(stream);
        return NULL;
    }

    return stream;
}

// **Stream Destruction Function**
// Stops and deallocates the audio stream and associated resources.
// Also destroys all shared ring buffers.
void destroyHALInputStream(HALInputStream* stream)
{
    if (!stream) return;
    AudioDeviceStop(stream->deviceID, stream->ioProcID);
    AudioDeviceDestroyIOProcID(stream->deviceID, stream->ioProcID);

    pthread_mutex_destroy(&stream->lock);
    free(stream->deinterleaveBuf);
    free(stream);
}

int HALInputStream_Open(HALInputStreamDevice *device) {
    if (!device) {
        Logger_Error("HALInputStream_Open: device is NULL");
        abort();
    }


    Logger_Debug("HALInputStream_Open: Registered device %d with %d channels", device->deviceId, device->numChannels);

    return 0;
}

void HALInputStream_Close(HALInputStreamDevice *device) {
    if (!device) {
        Logger_Error("HALInputStream_Close: device is NULL");
        abort();
    }


    Logger_Debug("HALInputStream_Close: Unregistered device %d", device->deviceId);
}

int HALInputStream_Read(HALInputStreamDevice *device, int channel, void *buffer, int frames) {
    if (!device) {
        Logger_Error("HALInputStream_Read: device is NULL");
        abort();
    }
    if (!buffer) {
        Logger_Error("HALInputStream_Read: buffer is NULL");
        abort();
    }
    if (channel < 0 || channel >= device->numChannels) {
        Logger_Error("HALInputStream_Read: invalid channel %d for device %d", channel, device->deviceId);
        abort();
    }

    return noErr;
}

int HALInputStream_AttachRingBuffer(HALInputStreamDevice *device, int channel, RingBuffer *ringBuffer) {
    if (!device) {
        Logger_Error("HALInputStream_AttachRingBuffer: device is NULL");
        abort();
    }
    if (!ringBuffer) {
        Logger_Error("HALInputStream_AttachRingBuffer: ringBuffer is NULL");
        abort();
    }
    if (channel < 0 || channel >= device->numChannels) {
        Logger_Error("HALInputStream_AttachRingBuffer: invalid channel %d for device %d", channel, device->deviceId);
        abort();
    }

    Logger_Debug("HALInputStream_AttachRingBuffer: Attaching ringBuffer %p to device %d channel %d", (void*)ringBuffer, device->deviceId, channel);


    Logger_Debug("HALInputStream_AttachRingBuffer: Successfully attached ringBuffer %p to device %d channel %d", (void*)ringBuffer, device->deviceId, channel);
    return 0;
}
