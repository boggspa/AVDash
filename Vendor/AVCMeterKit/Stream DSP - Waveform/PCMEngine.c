//
//  PCMEngine.c
//  AVCMeter
//
//  Created by Chris Izatt on 24/06/2025.
//

#include "PCMEngine.h"
#include "PCMInputStream.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>
#include "PCMRingBuffer.h"

#define MAX_CHANNELS 64
#define MAX_DEVICES 8
#define BUFFER_CAPACITY_FRAMES 1024

float* sampleArrays[MAX_CHANNELS] = {0};

// Per-device PCM stream state
typedef struct {
    AudioDeviceID deviceID;
    PCMInputStream* stream;
    PCMRingBuffer* pcmBuffers[MAX_CHANNELS]; // stores raw float samples per channel
    PCMCallback callback;
    void* context;
    int numChannels;
    bool inUse;
} DevicePCMState;

// Static storage for up to MAX_DEVICES PCM stream states
static DevicePCMState gPCMDevices[MAX_DEVICES];

// Lookup helpers
static DevicePCMState* findDevice(AudioDeviceID deviceID) {
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (gPCMDevices[i].inUse && gPCMDevices[i].deviceID == deviceID) {
            return &gPCMDevices[i];
        }
    }
    return NULL;
}

static DevicePCMState* allocateDevice(AudioDeviceID deviceID) {
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (!gPCMDevices[i].inUse) {
            gPCMDevices[i].deviceID = deviceID;
            gPCMDevices[i].numChannels = MAX_CHANNELS;
            gPCMDevices[i].inUse = true;
            return &gPCMDevices[i];
        }
    }
    return NULL;
}


// HAL raw PCM delivery callback.
static void PCM_HALCallback(float** pcm, UInt32 numFrames, UInt32 channelCount, void* refCon) {
    DevicePCMState* device = (DevicePCMState*)refCon;
    if (!device) return;

    static bool initialized = false;
    if (!initialized) {
        for (int i = 0; i < MAX_CHANNELS; ++i) {
            sampleArrays[i] = malloc(sizeof(float) * BUFFER_CAPACITY_FRAMES);
        }
        initialized = true;
    }

    for (UInt32 ch = 0; ch < channelCount && ch < MAX_CHANNELS; ++ch) {
        if (device->pcmBuffers[ch]) {
            memcpy(sampleArrays[ch], pcm[ch], sizeof(float) * numFrames);
            writePCMToRingBuffer(device->pcmBuffers[ch], sampleArrays[ch], numFrames);
        }
    }

    if (device->callback) {
        device->callback(pcm, numFrames, channelCount, device->context);
    }
    // Note: We keep sampleArrays in memory for reuse. They will persist across callbacks.
}

// Public API: start PCM stream with callback
OSStatus startPCMStreamWithCallback(AudioDeviceID deviceID,
                                    PCMCallback callback,
                                    void* context) {
    DevicePCMState* device = findDevice(deviceID);
    if (device) return noErr; // Already started

    device = allocateDevice(deviceID);
    if (!device) {
        return -1;
    }

    for (int i = 0; i < device->numChannels; i++) {
        device->pcmBuffers[i] = createPCMRingBuffer(BUFFER_CAPACITY_FRAMES, MAX_CHANNELS); // stores float samples
    }

    device->callback = callback;
    device->context = context;

    // Use PCM HALInputStream version with correct callback signature
    device->stream = createPCMInputStream(deviceID, (PCMCallback)PCM_HALCallback, device);
    if (!device->stream) {
        stopPCMStream(deviceID);
        return -1;
    }

    return noErr;
}

// Stop and clean up PCM stream
OSStatus stopPCMStream(AudioDeviceID deviceID) {
    DevicePCMState* device = findDevice(deviceID);
    if (!device) return noErr;

    if (device->stream) {
        destroyPCMInputStream(device->stream);
        device->stream = NULL;
    }

    for (int i = 0; i < device->numChannels; i++) {
        if (device->pcmBuffers[i]) {
            destroyPCMRingBuffer(device->pcmBuffers[i]);
            device->pcmBuffers[i] = NULL;
        }
    }

    for (int i = 0; i < MAX_CHANNELS; ++i) {
        if (sampleArrays[i]) {
            free(sampleArrays[i]);
            sampleArrays[i] = NULL;
        }
    }

    device->inUse = false;
    return noErr;
}

// Accessor to get a PCM ring buffer for waveform rendering
PCMRingBuffer* getPCMRingBufferForChannel(AudioDeviceID deviceID, int channel) {
    DevicePCMState* device = findDevice(deviceID);
    if (!device || channel < 0 || channel >= device->numChannels) return NULL;
    return device->pcmBuffers[channel];
}

// Fetch the latest samples from the ring buffer
int fetchLatestSamples(AudioDeviceID deviceID, int channel, float* outSamples, int frameCount) {
    PCMRingBuffer* buffer = getPCMRingBufferForChannel(deviceID, channel);
    if (!buffer || !outSamples) return 0;
    return (int)readPCMFromRingBuffer(buffer, outSamples, frameCount);
}
