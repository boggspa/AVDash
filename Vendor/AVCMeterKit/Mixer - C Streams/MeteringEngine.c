//
//  MeteringEngine.c
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//

#include "IOStreams.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include "IOStreams.h"
#include "Mixer.h"

#define MAX_CHANNELS 64
#define MAX_DEVICES 8

// Mutex and initialization flag to protect gDevices array and DeviceMeteringState accesses.
// Pattern and purpose is identical to EnsureMixerMutexRecursive but for gDevicesLock.
static pthread_mutex_t gDevicesLock;
static int gDevicesLockInitialized = 0;

static void EnsureGDevicesMutexRecursive(void) {
    if (!gDevicesLockInitialized) {
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&gDevicesLock, &attr);
        pthread_mutexattr_destroy(&attr);
        gDevicesLockInitialized = 1;
    }
}

typedef struct {
    AudioDeviceID deviceID;
    HALInputStream* stream;
    RingBuffer* peakBuffers[MAX_CHANNELS];
    // Atomic callback+context: read lock-free from the RT audio thread,
    // written under gDevicesLock from the main thread.
    _Atomic(MeteringCallback) callback;
    _Atomic(void*) context;
    int numChannels;
    bool inUse;
} DeviceMeteringState;

// Global device metering state array
static DeviceMeteringState gDevices[MAX_DEVICES];

static DeviceMeteringState* findDevice(AudioDeviceID deviceID) {
    EnsureGDevicesMutexRecursive();
    pthread_mutex_lock(&gDevicesLock);
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (gDevices[i].inUse && gDevices[i].deviceID == deviceID) {
            pthread_mutex_unlock(&gDevicesLock);
            return &gDevices[i];
        }
    }
    pthread_mutex_unlock(&gDevicesLock);
    return NULL;
}

static DeviceMeteringState* allocateDevice(AudioDeviceID deviceID) {
    EnsureGDevicesMutexRecursive();
    pthread_mutex_lock(&gDevicesLock);
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (!gDevices[i].inUse) {
            gDevices[i].deviceID = deviceID;
            gDevices[i].numChannels = MAX_CHANNELS; // can be dynamic later
            gDevices[i].inUse = true;
            pthread_mutex_unlock(&gDevicesLock);
            return &gDevices[i];
        }
    }
    pthread_mutex_unlock(&gDevicesLock);
    fprintf(stderr, "ERROR: allocateDevice failed, no free device slots for device %u\n", deviceID);
    abort();
    return NULL; // unreachable but silences warnings
}

// Called from the CoreAudio HAL audio thread — must be real-time safe.
// Uses atomic loads to read callback/context without any mutex.
static void HALCallbackDispatcher(float* rms, float* peak, unsigned int channelCount, void* refCon) {
    if (!refCon || !peak) return;

    DeviceMeteringState* device = (DeviceMeteringState*)refCon;
    MeteringCallback callbackCopy = atomic_load_explicit(&device->callback, memory_order_acquire);
    void* contextCopy = atomic_load_explicit(&device->context, memory_order_acquire);
    AudioDeviceID deviceIDCopy = device->deviceID;

    if (!callbackCopy) return;

    // Apply post-gain to each channel's peak value before metering callback.
    for (unsigned int i = 0; i < channelCount; i++) {
        RingBuffer_ApplyPostGain(i, &peak[i], 1);
    }

    callbackCopy(rms, peak, (int)channelCount, deviceIDCopy, contextCopy);
}

OSStatus startMeteringWithCallback(AudioDeviceID deviceID,
                                   MeteringCallback callback,
                                   void* context) {
    if (!callback) {
        fprintf(stderr, "ERROR: startMeteringWithCallback called with NULL callback for device %u\n", deviceID);
        abort();
    }

    EnsureGDevicesMutexRecursive();
    pthread_mutex_lock(&gDevicesLock);
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (gDevices[i].inUse && gDevices[i].deviceID == deviceID) {
            atomic_store_explicit(&gDevices[i].context, context, memory_order_release);
            atomic_store_explicit(&gDevices[i].callback, callback, memory_order_release);
            pthread_mutex_unlock(&gDevicesLock);
            return noErr;
        }
    }
    // Allocate slot and set callback/context before any stream/mixer call.
    DeviceMeteringState* device = allocateDevice(deviceID);
    atomic_store_explicit(&device->context, context, memory_order_release);
    atomic_store_explicit(&device->callback, callback, memory_order_release);
    pthread_mutex_unlock(&gDevicesLock);

    // 1) Create the HAL stream so we can query its real channel count
    device->stream = createHALInputStream(deviceID, HALCallbackDispatcher, device);
    if (!device->stream) {
        fprintf(stderr, "ERROR: Failed to create HAL input stream for device %u\n", deviceID);
        stopMetering(deviceID);
        abort();
    }

    // 2) Now read back the actual channel count
    UInt32 actualChannels = ((HALInputStream*)device->stream)->channelCount;
    if (actualChannels == 0 || actualChannels > MAX_CHANNELS) {
        fprintf(stderr, "ERROR: Invalid channel count %u for device %u\n", actualChannels, deviceID);
        stopMetering(deviceID);
        abort();
    }
    pthread_mutex_lock(&gDevicesLock);
    device->numChannels = actualChannels;
    pthread_mutex_unlock(&gDevicesLock);


    // 4) Allocate peak buffers for each channel
    for (int i = 0; i < (int)actualChannels; i++) {
        RingBuffer* rb = createRingBuffer(10);
        if (!rb) {
            fprintf(stderr, "ERROR: Failed to allocate peak buffer for device %u channel %d\n", deviceID, i);
            stopMetering(deviceID);
            abort();
        }
        pthread_mutex_lock(&gDevicesLock);
        device->peakBuffers[i] = rb;
        pthread_mutex_unlock(&gDevicesLock);
    }
    return noErr;
}

OSStatus stopMetering(AudioDeviceID deviceID) {
    EnsureGDevicesMutexRecursive();
    pthread_mutex_lock(&gDevicesLock);
    DeviceMeteringState* device = NULL;
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (gDevices[i].inUse && gDevices[i].deviceID == deviceID) {
            device = &gDevices[i];
            break;
        }
    }
    if (!device) {
        pthread_mutex_unlock(&gDevicesLock);
        return noErr; // harmless early exit if device is not found (already stopped)
    }

    // Clear callback atomically FIRST so the RT thread stops calling it
    // before we tear down the stream and buffers.
    atomic_store_explicit(&device->callback, NULL, memory_order_release);
    atomic_store_explicit(&device->context, NULL, memory_order_release);

    // Temporarily hold peakBuffers and stream references to free after unlocking
    HALInputStream* streamToDestroy = device->stream;
    int channels = device->numChannels;
    RingBuffer* buffersToDestroy[MAX_CHANNELS];
    for (int i = 0; i < channels; i++) {
        buffersToDestroy[i] = device->peakBuffers[i];
        device->peakBuffers[i] = NULL;
    }
    device->stream = NULL;
    device->inUse = false;
    pthread_mutex_unlock(&gDevicesLock);

    if (streamToDestroy) {
        destroyHALInputStream(streamToDestroy);
    }

    for (int i = 0; i < channels; i++) {
        if (buffersToDestroy[i]) {
            destroyRingBuffer(buffersToDestroy[i]);
        }
    }

    return noErr;
}

float getBufferedPeakAverageForChannel(AudioDeviceID deviceID, int channel) {
    EnsureGDevicesMutexRecursive();
    pthread_mutex_lock(&gDevicesLock);
    DeviceMeteringState* device = NULL;
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (gDevices[i].inUse && gDevices[i].deviceID == deviceID) {
            device = &gDevices[i];
            break;
        }
    }
    if (!device) {
        pthread_mutex_unlock(&gDevicesLock);
        fprintf(stderr, "ERROR: getBufferedPeakAverageForChannel called for unknown device %u\n", deviceID);
        abort();
    }
    if (channel < 0 || channel >= device->numChannels) {
        pthread_mutex_unlock(&gDevicesLock);
        fprintf(stderr, "ERROR: getBufferedPeakAverageForChannel channel index %d out of range for device %u\n", channel, deviceID);
        abort();
    }
    RingBuffer* buffer = device->peakBuffers[channel];
    pthread_mutex_unlock(&gDevicesLock);

    if (!buffer) {
        fprintf(stderr, "ERROR: getBufferedPeakAverageForChannel peak buffer NULL for device %u channel %d\n", deviceID, channel);
        abort();
    }
    return averageRingBuffer(buffer);
}

RingBuffer* getPeakRingBufferForChannel(AudioDeviceID deviceID, int channel) {
    EnsureGDevicesMutexRecursive();
    pthread_mutex_lock(&gDevicesLock);
    DeviceMeteringState* device = NULL;
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (gDevices[i].inUse && gDevices[i].deviceID == deviceID) {
            device = &gDevices[i];
            break;
        }
    }
    if (!device) {
        pthread_mutex_unlock(&gDevicesLock);
        fprintf(stderr, "ERROR: getPeakRingBufferForChannel called for unknown device %u\n", deviceID);
        abort();
    }
    if (channel < 0 || channel >= device->numChannels) {
        pthread_mutex_unlock(&gDevicesLock);
        fprintf(stderr, "ERROR: getPeakRingBufferForChannel channel index %d out of range for device %u\n", channel, deviceID);
        abort();
    }
    RingBuffer* buffer = device->peakBuffers[channel];
    pthread_mutex_unlock(&gDevicesLock);

    if (!buffer) {
        fprintf(stderr, "ERROR: getPeakRingBufferForChannel peak buffer NULL for device %u channel %d\n", deviceID, channel);
        abort();
    }
    return buffer;
}

float getMostRecentPeakForChannel(AudioDeviceID deviceID, int channel) {
    EnsureGDevicesMutexRecursive();
    pthread_mutex_lock(&gDevicesLock);
    DeviceMeteringState* device = NULL;
    for (int i = 0; i < MAX_DEVICES; i++) {
        if (gDevices[i].inUse && gDevices[i].deviceID == deviceID) {
            device = &gDevices[i];
            break;
        }
    }
    if (!device) {
        pthread_mutex_unlock(&gDevicesLock);
        fprintf(stderr, "ERROR: getMostRecentPeakForChannel called for unknown device %u\n", deviceID);
        abort();
    }
    if (channel < 0 || channel >= device->numChannels) {
        pthread_mutex_unlock(&gDevicesLock);
        fprintf(stderr, "ERROR: getMostRecentPeakForChannel channel index %d out of range for device %u\n", channel, deviceID);
        abort();
    }
    RingBuffer* buffer = device->peakBuffers[channel];
    pthread_mutex_unlock(&gDevicesLock);

    if (!buffer) {
        fprintf(stderr, "ERROR: getMostRecentPeakForChannel peak buffer NULL for device %u channel %d\n", deviceID, channel);
        abort();
    }
    return mostRecentRingBuffer(buffer);
}


// Swift bridge callback - receives metering data and dispatches to Swift layer
extern void SwiftMeterCallback(const float* rmsArray, const float* peakArray, int channelCount, AudioDeviceID deviceID, void* ctx);

// C wrapper that bridges HAL callback to Swift
static void SwiftBridgeCallback(float* rms, float* peak, unsigned int channelCount, void* refCon) {
    fprintf(stderr, "[SwiftBridgeCallback] Forwarding to Swift for device callback\n");
    SwiftMeterCallback((const float*)rms, (const float*)peak, (int)channelCount, *(AudioDeviceID*)refCon, refCon);
}
