/**
 * @file MixerRegistration.c
 * @brief Mixer device registration and ring buffer management
 *
 * @author Chris Izatt
 * @date 2025-07-23
 *
 * @note Simplified implementation for basic device registration
 */

#include "Mixer.h"
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>

extern void MixerConfigShadow_ResetAll(void);

// ============================================================================
// GLOBAL MIXER INSTANCE
// ============================================================================

static _Atomic(Mixer *) gMixer = NULL;
static pthread_mutex_t gMixerInitLock = PTHREAD_MUTEX_INITIALIZER;

static Mixer *Mixer_LoadGlobalMixer(void) {
    return atomic_load_explicit(&gMixer, memory_order_acquire);
}

static MixerDevice *Mixer_FindDeviceLocked(Mixer *mixer, uint32_t deviceID, MixerChannelType type) {
    if (!mixer) {
        return NULL;
    }

    for (uint32_t deviceIndex = 0; deviceIndex < mixer->numDevices; deviceIndex++) {
        MixerDevice *device = &mixer->devices[deviceIndex];
        if (device->deviceID == deviceID && device->type == type) {
            return device;
        }
    }

    return NULL;
}

static uint32_t Mixer_OutputRingBufferFrames(uint32_t bufferFrames) {
    uint32_t ringBufferFrames = bufferFrames * 8;
    if (ringBufferFrames < 1024) {
        ringBufferFrames = 1024;
    }
    return ringBufferFrames;
}

static uint32_t Mixer_VisualRingBufferFrames(uint32_t bufferFrames) {
    uint32_t ringBufferFrames = bufferFrames * 64;
    if (ringBufferFrames < 16384) {
        ringBufferFrames = 16384;
    }
    return ringBufferFrames;
}

static int Mixer_EnsureVirtualBusBuffersLocked(Mixer *mixer) {
    if (!mixer) {
        return -1;
    }

    const uint32_t capacity = Mixer_VisualRingBufferFrames(mixer->bufferFrames);

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_SEND_BUSES; busIndex++) {
        if (!mixer->auxSendRingBuffers[busIndex]) {
            mixer->auxSendRingBuffers[busIndex] = createRingBuffer((int)capacity);
            if (!mixer->auxSendRingBuffers[busIndex]) {
                return -1;
            }
        }
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_SEND_BUSES; busIndex++) {
        if (!mixer->fxSendRingBuffers[busIndex]) {
            mixer->fxSendRingBuffers[busIndex] = createRingBuffer((int)capacity);
            if (!mixer->fxSendRingBuffers[busIndex]) {
                return -1;
            }
        }
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_RETURN_BUSES; busIndex++) {
        if (!mixer->auxReturnRingBuffers[busIndex]) {
            mixer->auxReturnRingBuffers[busIndex] = createRingBuffer((int)capacity);
            if (!mixer->auxReturnRingBuffers[busIndex]) {
                return -1;
            }
        }
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_RETURN_BUSES; busIndex++) {
        if (!mixer->fxReturnRingBuffers[busIndex]) {
            mixer->fxReturnRingBuffers[busIndex] = createRingBuffer((int)capacity);
            if (!mixer->fxReturnRingBuffers[busIndex]) {
                return -1;
            }
        }
    }

    return 0;
}

static void Mixer_InitVirtualBusChannel(MixerChannel *channel, MixerVirtualBusType busType, uint32_t busIndex) {
    if (!channel) {
        return;
    }

    memset(channel, 0, sizeof(MixerChannel));
    channel->deviceID = 0;
    channel->type = MIXER_CHANNEL_INPUT;
    channel->deviceChannelIndex = busIndex;
    channel->globalChannelIndex = UINT32_MAX;
    channel->gain = 1.0f;
    channel->fader = 1.0f;
    channel->pan = 0.5f;
    channel->auxSend = 0.0f;
    channel->fxSend = 0.0f;
    channel->auxSendBusIndex = 0;
    channel->fxSendBusIndex = 0;
    channel->auxSendPreFade = 0;
    channel->fxSendPreFade = 0;
    channel->mute = 0;
    channel->solo = 0;
    channel->outputRoutingMask = ~0ULL;
    channel->lastPeak = 0.0f;
    channel->lastRMS = 0.0f;
    channel->lastGainReductionDB = 0.0f;
    channel->delaySamples = 0;
    channel->delayBuffer = NULL;
    channel->delayBufferCapacity = 0;
    channel->delayWritePos = 0;

    // Tag bus type in deviceID range for diagnostics (no routing semantics).
    switch (busType) {
        case MIXER_VIRTUAL_BUS_AUX_SEND:
            channel->deviceID = 800000 + busIndex;
            break;
        case MIXER_VIRTUAL_BUS_FX_SEND:
            channel->deviceID = 810000 + busIndex;
            break;
        case MIXER_VIRTUAL_BUS_AUX_RETURN:
            channel->deviceID = 820000 + busIndex;
            break;
        case MIXER_VIRTUAL_BUS_FX_RETURN:
            channel->deviceID = 830000 + busIndex;
            break;
    }
}

static void Mixer_InitializeVirtualBusChannels(Mixer *mixer) {
    if (!mixer) {
        return;
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_SEND_BUSES; busIndex++) {
        Mixer_InitVirtualBusChannel(&mixer->auxSendBusChannels[busIndex], MIXER_VIRTUAL_BUS_AUX_SEND, busIndex);
    }
    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_SEND_BUSES; busIndex++) {
        Mixer_InitVirtualBusChannel(&mixer->fxSendBusChannels[busIndex], MIXER_VIRTUAL_BUS_FX_SEND, busIndex);
    }
    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_RETURN_BUSES; busIndex++) {
        Mixer_InitVirtualBusChannel(&mixer->auxReturnBusChannels[busIndex], MIXER_VIRTUAL_BUS_AUX_RETURN, busIndex);
    }
    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_RETURN_BUSES; busIndex++) {
        Mixer_InitVirtualBusChannel(&mixer->fxReturnBusChannels[busIndex], MIXER_VIRTUAL_BUS_FX_RETURN, busIndex);
    }
}

static int Mixer_EnsureOutputResourcesLocked(Mixer *mixer, MixerDevice *device) {
    if (!mixer || !device || device->type != MIXER_CHANNEL_OUTPUT) {
        return 0;
    }

    const uint32_t outputRingBufferFrames = Mixer_OutputRingBufferFrames(mixer->bufferFrames);
    const uint32_t visualRingBufferFrames = Mixer_VisualRingBufferFrames(mixer->bufferFrames);

    for (uint32_t channelIndex = 0; channelIndex < device->numChannels; channelIndex++) {
        MixerChannel *channel = &device->channels[channelIndex];
        if (channel->outputRingBuffer == NULL) {
            channel->outputRingBuffer = createRingBuffer((int)outputRingBufferFrames);
            if (channel->outputRingBuffer == NULL) {
                printf("[Mixer] ERROR: Failed to allocate output ring buffer for device=%u channel=%u\n",
                       device->deviceID, channelIndex);
                return -1;
            }
        }

        if (channel->visualizationRingBuffer == NULL) {
            channel->visualizationRingBuffer = createRingBuffer((int)visualRingBufferFrames);
            if (channel->visualizationRingBuffer == NULL) {
                printf("[Mixer] ERROR: Failed to allocate visual ring buffer for output device=%u channel=%u\n",
                       device->deviceID, channelIndex);
                return -1;
            }
        }

        if (channel->postEQRingBuffer == NULL) {
            channel->postEQRingBuffer = createRingBuffer(4096);
            if (channel->postEQRingBuffer == NULL) {
                printf("[Mixer] ERROR: Failed to allocate post-EQ ring buffer for output device=%u channel=%u\n",
                       device->deviceID, channelIndex);
                return -1;
            }
        }

        if (channel->postDynamicsRingBuffer == NULL) {
            channel->postDynamicsRingBuffer = createRingBuffer(4096);
            if (channel->postDynamicsRingBuffer == NULL) {
                printf("[Mixer] ERROR: Failed to allocate post-dynamics ring buffer for output device=%u channel=%u\n",
                       device->deviceID, channelIndex);
                return -1;
            }
        }
    }

    return 0;
}

// ============================================================================
// INITIALIZATION & SHUTDOWN
// ============================================================================

OSStatus Mixer_Init(uint32_t sampleRate, uint32_t bufferFrames) {
    pthread_mutex_lock(&gMixerInitLock);

    if (Mixer_LoadGlobalMixer() != NULL) {
        printf("[Mixer] Already initialized\n");
        pthread_mutex_unlock(&gMixerInitLock);
        return 0;  // Already initialized
    }

    // Allocate mixer structure
    Mixer *mixer = (Mixer *)malloc(sizeof(Mixer));
    if (!mixer) {
        printf("[Mixer] ERROR: Failed to allocate mixer\n");
        pthread_mutex_unlock(&gMixerInitLock);
        return -1;
    }

    // Initialize mixer state
    memset(mixer, 0, sizeof(Mixer));
    mixer->sampleRate = sampleRate;
    mixer->bufferFrames = bufferFrames;
    mixer->numDevices = 0;
    mixer->totalGlobalChannels = 0;
    MixerConfigShadow_ResetAll();
    Mixer_InitializeVirtualBusChannels(mixer);

    // Initialize recursive mutex for nested locking
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&mixer->mutex, &attr);
    pthread_mutexattr_destroy(&attr);

    // Pre-allocate scratch buffers for ProcessBlock — eliminates all malloc/free from the audio path.
    mixer->scratchInputCount = MIXER_MAX_GLOBAL_CHANNELS;
    mixer->scratchInputBuffers = (float **)calloc(MIXER_MAX_GLOBAL_CHANNELS, sizeof(float *));
    for (uint32_t i = 0; i < MIXER_MAX_GLOBAL_CHANNELS; i++) {
        mixer->scratchInputBuffers[i] = (float *)calloc(bufferFrames, sizeof(float));
    }
    mixer->scratchAuxSendBuses = (float **)calloc(MIXER_MAX_AUX_SEND_BUSES, sizeof(float *));
    for (uint32_t i = 0; i < MIXER_MAX_AUX_SEND_BUSES; i++) {
        mixer->scratchAuxSendBuses[i] = (float *)calloc(bufferFrames, sizeof(float));
    }
    mixer->scratchFxSendBuses = (float **)calloc(MIXER_MAX_FX_SEND_BUSES, sizeof(float *));
    for (uint32_t i = 0; i < MIXER_MAX_FX_SEND_BUSES; i++) {
        mixer->scratchFxSendBuses[i] = (float *)calloc(bufferFrames, sizeof(float));
    }
    mixer->scratchAuxReturnBuses = (float **)calloc(MIXER_MAX_AUX_RETURN_BUSES, sizeof(float *));
    for (uint32_t i = 0; i < MIXER_MAX_AUX_RETURN_BUSES; i++) {
        mixer->scratchAuxReturnBuses[i] = (float *)calloc(bufferFrames, sizeof(float));
    }
    mixer->scratchFxReturnBuses = (float **)calloc(MIXER_MAX_FX_RETURN_BUSES, sizeof(float *));
    for (uint32_t i = 0; i < MIXER_MAX_FX_RETURN_BUSES; i++) {
        mixer->scratchFxReturnBuses[i] = (float *)calloc(bufferFrames, sizeof(float));
    }

    if (Mixer_EnsureVirtualBusBuffersLocked(mixer) != 0) {
        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_SEND_BUSES; busIndex++) {
            if (mixer->auxSendRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->auxSendRingBuffers[busIndex]);
                mixer->auxSendRingBuffers[busIndex] = NULL;
            }
        }
        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_SEND_BUSES; busIndex++) {
            if (mixer->fxSendRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->fxSendRingBuffers[busIndex]);
                mixer->fxSendRingBuffers[busIndex] = NULL;
            }
        }
        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_RETURN_BUSES; busIndex++) {
            if (mixer->auxReturnRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->auxReturnRingBuffers[busIndex]);
                mixer->auxReturnRingBuffers[busIndex] = NULL;
            }
        }
        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_RETURN_BUSES; busIndex++) {
            if (mixer->fxReturnRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->fxReturnRingBuffers[busIndex]);
                mixer->fxReturnRingBuffers[busIndex] = NULL;
            }
        }
        pthread_mutex_destroy(&mixer->mutex);
        free(mixer);
        pthread_mutex_unlock(&gMixerInitLock);
        return -1;
    }

    atomic_store_explicit(&gMixer, mixer, memory_order_release);

    printf("[Mixer] Initialized: sampleRate=%u bufferFrames=%u\n", sampleRate, bufferFrames);

    pthread_mutex_unlock(&gMixerInitLock);
    return 0;
}

void Mixer_Shutdown(void) {
    Mixer_StopProcessingThread();

    pthread_mutex_lock(&gMixerInitLock);

    Mixer *mixer = atomic_exchange_explicit(&gMixer, NULL, memory_order_acq_rel);
    if (mixer) {
        MixerConfigShadow_ResetAll();
        for (uint32_t deviceIndex = 0; deviceIndex < mixer->numDevices; deviceIndex++) {
            MixerDevice *device = &mixer->devices[deviceIndex];
            for (uint32_t channelIndex = 0; channelIndex < device->numChannels; channelIndex++) {
                MixerChannel *channel = &device->channels[channelIndex];
                free(channel->outputBuffer);
                channel->outputBuffer = NULL;
                channel->inputRingBuffer = NULL;
                if (channel->outputRingBuffer) {
                    destroyRingBuffer(channel->outputRingBuffer);
                }
                channel->outputRingBuffer = NULL;
                if (channel->visualizationRingBuffer) {
                    destroyRingBuffer(channel->visualizationRingBuffer);
                }
                channel->visualizationRingBuffer = NULL;
                if (channel->postEQRingBuffer) {
                    destroyRingBuffer(channel->postEQRingBuffer);
                }
                channel->postEQRingBuffer = NULL;
                if (channel->postDynamicsRingBuffer) {
                    destroyRingBuffer(channel->postDynamicsRingBuffer);
                }
                channel->postDynamicsRingBuffer = NULL;
                free(channel->delayBuffer);
                channel->delayBuffer = NULL;
                channel->delayBufferCapacity = 0;
                channel->delayWritePos = 0;
            }
        }

        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_SEND_BUSES; busIndex++) {
            if (mixer->auxSendRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->auxSendRingBuffers[busIndex]);
                mixer->auxSendRingBuffers[busIndex] = NULL;
            }
        }
        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_SEND_BUSES; busIndex++) {
            if (mixer->fxSendRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->fxSendRingBuffers[busIndex]);
                mixer->fxSendRingBuffers[busIndex] = NULL;
            }
        }
        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_RETURN_BUSES; busIndex++) {
            if (mixer->auxReturnRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->auxReturnRingBuffers[busIndex]);
                mixer->auxReturnRingBuffers[busIndex] = NULL;
            }
        }
        for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_RETURN_BUSES; busIndex++) {
            if (mixer->fxReturnRingBuffers[busIndex]) {
                destroyRingBuffer(mixer->fxReturnRingBuffers[busIndex]);
                mixer->fxReturnRingBuffers[busIndex] = NULL;
            }
        }

        pthread_mutex_destroy(&mixer->mutex);
        free(mixer);
        printf("[Mixer] Shutdown complete\n");
    }

    pthread_mutex_unlock(&gMixerInitLock);
}

// ============================================================================
// ACCESSOR FUNCTIONS
// ============================================================================

Mixer* GetGlobalMixerPointer(void) {
    return Mixer_LoadGlobalMixer();
}

MixerChannel* GetGlobalInputChannelsPointer(void) {
    // Flattened input channel storage is not currently exposed.
    return NULL;
}

MixerChannel* GetGlobalOutputChannelsPointer(void) {
    // Flattened output channel storage is not currently exposed.
    return NULL;
}

int32_t Mixer_GetGlobalChannelIndex(uint32_t deviceID, uint32_t type, uint32_t deviceChannelIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return -1;
    }

    pthread_mutex_lock(&mixer->mutex);

    for (uint32_t deviceIndex = 0; deviceIndex < mixer->numDevices; deviceIndex++) {
        MixerDevice *device = &mixer->devices[deviceIndex];
        if (device->deviceID != deviceID || device->type != (MixerChannelType)type) {
            continue;
        }

        if (deviceChannelIndex >= device->numChannels) {
            pthread_mutex_unlock(&mixer->mutex);
            return -1;
        }

        int32_t globalChannelIndex = (int32_t)device->channels[deviceChannelIndex].globalChannelIndex;
        pthread_mutex_unlock(&mixer->mutex);
        return globalChannelIndex;
    }

    pthread_mutex_unlock(&mixer->mutex);
    return -1;
}

RingBuffer* Mixer_GetOutputChannelRingBuffer(uint32_t deviceID, uint32_t deviceChannelIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return NULL;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerDevice *device = Mixer_FindDeviceLocked(mixer, deviceID, MIXER_CHANNEL_OUTPUT);
    if (!device || deviceChannelIndex >= device->numChannels) {
        pthread_mutex_unlock(&mixer->mutex);
        return NULL;
    }

    RingBuffer *outputRingBuffer = device->channels[deviceChannelIndex].outputRingBuffer;
    pthread_mutex_unlock(&mixer->mutex);
    return outputRingBuffer;
}

float Mixer_GetOutputChannelPeak(uint32_t deviceID, uint32_t deviceChannelIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerDevice *device = Mixer_FindDeviceLocked(mixer, deviceID, MIXER_CHANNEL_OUTPUT);
    if (!device || deviceChannelIndex >= device->numChannels) {
        pthread_mutex_unlock(&mixer->mutex);
        return 0.0f;
    }

    float peak = device->channels[deviceChannelIndex].lastPeak;
    pthread_mutex_unlock(&mixer->mutex);
    return peak;
}

float Mixer_GetOutputChannelRMS(uint32_t deviceID, uint32_t deviceChannelIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerDevice *device = Mixer_FindDeviceLocked(mixer, deviceID, MIXER_CHANNEL_OUTPUT);
    if (!device || deviceChannelIndex >= device->numChannels) {
        pthread_mutex_unlock(&mixer->mutex);
        return 0.0f;
    }

    float rms = device->channels[deviceChannelIndex].lastRMS;
    pthread_mutex_unlock(&mixer->mutex);
    return rms;
}

static float Mixer_GetMeterValueLocked(const float *values, uint32_t busIndex, uint32_t maxCount) {
    if (!values || busIndex >= maxCount) {
        return 0.0f;
    }
    return values[busIndex];
}

float Mixer_GetAuxSendPeak(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->auxSendPeak, busIndex, MIXER_MAX_AUX_SEND_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

float Mixer_GetAuxSendRMS(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->auxSendRMS, busIndex, MIXER_MAX_AUX_SEND_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

float Mixer_GetFXSendPeak(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->fxSendPeak, busIndex, MIXER_MAX_FX_SEND_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

float Mixer_GetFXSendRMS(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->fxSendRMS, busIndex, MIXER_MAX_FX_SEND_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

float Mixer_GetAuxReturnPeak(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->auxReturnPeak, busIndex, MIXER_MAX_AUX_RETURN_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

float Mixer_GetAuxReturnRMS(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->auxReturnRMS, busIndex, MIXER_MAX_AUX_RETURN_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

float Mixer_GetFXReturnPeak(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->fxReturnPeak, busIndex, MIXER_MAX_FX_RETURN_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

float Mixer_GetFXReturnRMS(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0.0f;
    }
    pthread_mutex_lock(&mixer->mutex);
    float value = Mixer_GetMeterValueLocked(mixer->fxReturnRMS, busIndex, MIXER_MAX_FX_RETURN_BUSES);
    pthread_mutex_unlock(&mixer->mutex);
    return value;
}

static int Mixer_ReadLatestFromRingBuffer(RingBuffer *ringBuffer, float *outputArray, int maxCount) {
    if (!ringBuffer || !outputArray || maxCount <= 0) {
        return 0;
    }
    return ringbuffer_read_latest(ringBuffer, outputArray, maxCount);
}

static int Mixer_GetRingBufferFillLevel(RingBuffer *ringBuffer) {
    if (!ringBuffer) {
        return 0;
    }
    return getRingBufferFillCount(ringBuffer);
}

int Mixer_ReadOutputChannelVisualBuffer(uint32_t deviceID, uint32_t deviceChannelIndex, float *outputArray, int maxCount) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || !outputArray || maxCount <= 0) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerDevice *device = Mixer_FindDeviceLocked(mixer, deviceID, MIXER_CHANNEL_OUTPUT);
    RingBuffer *ringBuffer = NULL;
    if (device && deviceChannelIndex < device->numChannels) {
        ringBuffer = device->channels[deviceChannelIndex].visualizationRingBuffer;
    }
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_ReadLatestFromRingBuffer(ringBuffer, outputArray, maxCount);
}

int Mixer_OutputChannelVisualBufferFilled(uint32_t deviceID, uint32_t deviceChannelIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerDevice *device = Mixer_FindDeviceLocked(mixer, deviceID, MIXER_CHANNEL_OUTPUT);
    RingBuffer *ringBuffer = NULL;
    if (device && deviceChannelIndex < device->numChannels) {
        ringBuffer = device->channels[deviceChannelIndex].visualizationRingBuffer;
    }
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_GetRingBufferFillLevel(ringBuffer);
}

int Mixer_ReadAuxSendBuffer(uint32_t busIndex, float *outputArray, int maxCount) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_AUX_SEND_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->auxSendRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_ReadLatestFromRingBuffer(ringBuffer, outputArray, maxCount);
}

int Mixer_AuxSendBufferFilled(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_AUX_SEND_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->auxSendRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_GetRingBufferFillLevel(ringBuffer);
}

int Mixer_ReadFXSendBuffer(uint32_t busIndex, float *outputArray, int maxCount) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_FX_SEND_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->fxSendRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_ReadLatestFromRingBuffer(ringBuffer, outputArray, maxCount);
}

int Mixer_FXSendBufferFilled(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_FX_SEND_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->fxSendRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_GetRingBufferFillLevel(ringBuffer);
}

int Mixer_ReadAuxReturnBuffer(uint32_t busIndex, float *outputArray, int maxCount) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_AUX_RETURN_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->auxReturnRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_ReadLatestFromRingBuffer(ringBuffer, outputArray, maxCount);
}

int Mixer_AuxReturnBufferFilled(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_AUX_RETURN_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->auxReturnRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_GetRingBufferFillLevel(ringBuffer);
}

int Mixer_ReadFXReturnBuffer(uint32_t busIndex, float *outputArray, int maxCount) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_FX_RETURN_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->fxReturnRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_ReadLatestFromRingBuffer(ringBuffer, outputArray, maxCount);
}

int Mixer_FXReturnBufferFilled(uint32_t busIndex) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || busIndex >= MIXER_MAX_FX_RETURN_BUSES) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    RingBuffer *ringBuffer = mixer->fxReturnRingBuffers[busIndex];
    pthread_mutex_unlock(&mixer->mutex);

    return Mixer_GetRingBufferFillLevel(ringBuffer);
}

/**
 * Register a device with the mixer
 * @param deviceID Unique device identifier
 * @param type Input or output (0=input, 1=output)
 * @param numChannels Number of channels
 * @return 0 on success, -1 on error
 */
int Mixer_RegisterDevice(uint32_t deviceID, uint32_t type, uint32_t numChannels) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        printf("[Mixer] ERROR: Mixer not initialized\n");
        return -1;
    }

    if (numChannels == 0) {
        printf("[Mixer] Warning: Registering device with zero channels\n");
        return 0;
    }

    if (numChannels > MIXER_MAX_CHANNELS_PER_DEVICE) {
        printf("[Mixer] Error: Too many channels (%u > %u)\n", numChannels, MIXER_MAX_CHANNELS_PER_DEVICE);
        return -1;
    }

    pthread_mutex_lock(&mixer->mutex);

    // Check if device already registered
    MixerDevice *existingDevice = Mixer_FindDeviceLocked(mixer, deviceID, (MixerChannelType)type);
    if (existingDevice) {
        existingDevice->active = 1;
        if (existingDevice->type == MIXER_CHANNEL_OUTPUT && Mixer_EnsureOutputResourcesLocked(mixer, existingDevice) != 0) {
            pthread_mutex_unlock(&mixer->mutex);
            return -1;
        }

        printf("[Mixer] Device already registered: deviceID=%u type=%u\n", deviceID, type);
        pthread_mutex_unlock(&mixer->mutex);
        return 0;
    }

    // Check if we have room for another device
    if (mixer->numDevices >= MIXER_MAX_DEVICES) {
        printf("[Mixer] ERROR: Max devices (%u) reached\n", MIXER_MAX_DEVICES);
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    // Check if we have room for the channels globally
    if (mixer->totalGlobalChannels + numChannels > MIXER_MAX_GLOBAL_CHANNELS) {
        printf("[Mixer] ERROR: Max global channels exceeded\n");
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    // Register the device
    MixerDevice *device = &mixer->devices[mixer->numDevices];
    device->deviceID = deviceID;
    device->type = type;
    device->numChannels = numChannels;
    device->globalChannelStartIndex = mixer->totalGlobalChannels;
    device->active = 1;

    // Initialize channels
    for (uint32_t i = 0; i < numChannels; i++) {
        MixerChannel *channel = &device->channels[i];
        memset(channel, 0, sizeof(MixerChannel));
        channel->deviceID = deviceID;
        channel->type = type;
        channel->deviceChannelIndex = i;
        channel->globalChannelIndex = mixer->totalGlobalChannels + i;
        channel->gain = 1.0f;      // Unity gain by default
        channel->fader = 1.0f;     // Fader at unity
        channel->pan = 0.5f;       // Center pan
        channel->mute = 0;         // Unmuted
        channel->solo = 0;         // Not soloed
        channel->outputRoutingMask = ~0ULL;  // Route to all outputs by default

        // Allocate post-EQ ring buffer for input and output channels (used by FFT analyzer views)
        if (type == MIXER_CHANNEL_INPUT || type == MIXER_CHANNEL_OUTPUT) {
            channel->postEQRingBuffer = createRingBuffer(4096);
            channel->postDynamicsRingBuffer = createRingBuffer(4096);
        }
    }

    if (device->type == MIXER_CHANNEL_OUTPUT && Mixer_EnsureOutputResourcesLocked(mixer, device) != 0) {
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    mixer->totalGlobalChannels += numChannels;
    mixer->numDevices++;

    printf("[Mixer] Device registered: deviceID=%u type=%u numChannels=%u globalStart=%u\n",
           deviceID, type, numChannels, device->globalChannelStartIndex);

    pthread_mutex_unlock(&mixer->mutex);
    return 0;
}

/**
 * Attach an input ring buffer to a device/channel
 * @param deviceID Device identifier
 * @param type Input or output (0=input, 1=output)
 * @param deviceChannelIndex Channel index within device
 * @param ringBuffer Ring buffer pointer (type-cast from Swift UnsafeMutableRawPointer)
 * @return 0 on success, -1 on error
 */
int Mixer_AttachInputRingBuffer(uint32_t deviceID, uint32_t type, uint32_t deviceChannelIndex, void *ringBuffer) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        printf("[Mixer] ERROR: Mixer not initialized\n");
        return -1;
    }

    if (!ringBuffer) {
        printf("[Mixer] ERROR: Ring buffer is NULL\n");
        return -1;
    }

    pthread_mutex_lock(&mixer->mutex);

    // Find the device
    MixerDevice *device = NULL;
    for (uint32_t i = 0; i < mixer->numDevices; i++) {
        if (mixer->devices[i].deviceID == deviceID && mixer->devices[i].type == type) {
            device = &mixer->devices[i];
            break;
        }
    }

    if (!device) {
        printf("[Mixer] ERROR: Device not found: deviceID=%u type=%u\n", deviceID, type);
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    if (deviceChannelIndex >= device->numChannels) {
        printf("[Mixer] ERROR: Channel index out of range: %u >= %u\n", deviceChannelIndex, device->numChannels);
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    // Attach the ring buffer to the channel
    MixerChannel *channel = &device->channels[deviceChannelIndex];
    channel->inputRingBuffer = (RingBuffer *)ringBuffer;

    printf("[Mixer] Attached ring buffer to device=%u type=%u channel=%u buffer=%p\n",
           deviceID, type, deviceChannelIndex, ringBuffer);

    pthread_mutex_unlock(&mixer->mutex);
    return 0;
}

/**
 * Unregister a device from the mixer
 * @param deviceID Device identifier
 * @param type Input or output (0=input, 1=output)
 * @return 0 on success, -1 if device not found
 */
int Mixer_UnregisterDevice(uint32_t deviceID, uint32_t type) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer) {
        return -1;
    }

    pthread_mutex_lock(&mixer->mutex);

    int deviceIndex = -1;
    for (uint32_t i = 0; i < mixer->numDevices; i++) {
        if (mixer->devices[i].deviceID == deviceID && mixer->devices[i].type == (MixerChannelType)type) {
            deviceIndex = (int)i;
            break;
        }
    }

    if (deviceIndex == -1) {
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    MixerDevice *device = &mixer->devices[deviceIndex];

    // Clean up channel resources
    for (uint32_t i = 0; i < device->numChannels; i++) {
        MixerChannel *channel = &device->channels[i];
        if (channel->postEQRingBuffer) {
            destroyRingBuffer(channel->postEQRingBuffer);
            channel->postEQRingBuffer = NULL;
        }
        if (channel->postDynamicsRingBuffer) {
            destroyRingBuffer(channel->postDynamicsRingBuffer);
            channel->postDynamicsRingBuffer = NULL;
        }
        if (channel->visualizationRingBuffer) {
            destroyRingBuffer(channel->visualizationRingBuffer);
            channel->visualizationRingBuffer = NULL;
        }
        if (channel->outputRingBuffer) {
            destroyRingBuffer(channel->outputRingBuffer);
            channel->outputRingBuffer = NULL;
        }
        if (channel->outputBuffer) {
            free(channel->outputBuffer);
            channel->outputBuffer = NULL;
        }
    }

    // Shift remaining devices
    for (uint32_t i = (uint32_t)deviceIndex; i < mixer->numDevices - 1; i++) {
        mixer->devices[i] = mixer->devices[i + 1];
    }

    mixer->numDevices--;

    // Re-calculate all globalChannelIndices to keep them contiguous
    mixer->totalGlobalChannels = 0;
    for (uint32_t i = 0; i < mixer->numDevices; i++) {
        mixer->devices[i].globalChannelStartIndex = mixer->totalGlobalChannels;
        for (uint32_t ch = 0; ch < mixer->devices[i].numChannels; ch++) {
            mixer->devices[i].channels[ch].globalChannelIndex = mixer->totalGlobalChannels + ch;
        }
        mixer->totalGlobalChannels += mixer->devices[i].numChannels;
    }

    printf("[Mixer] Unregistered device: deviceID=%u type=%d. Remaining devices: %u, total channels: %u\n",
           deviceID, type, mixer->numDevices, mixer->totalGlobalChannels);

    pthread_mutex_unlock(&mixer->mutex);
    return 0;
}

/**
 * Append/feed samples to mixer for a channel
 * @param deviceID Device identifier
 * @param type Input or output (0=input, 1=output)
 * @param deviceChannelIndex Channel index within device
 * @param samples Audio sample array
 * @param numFrames Number of frames
 * @return 0 on success
 */
int Mixer_FeedSingleChannelToMixer(uint32_t deviceID, uint32_t type, uint32_t deviceChannelIndex,
                                   const float *samples, uint32_t numFrames) {
    Mixer *mixer = Mixer_LoadGlobalMixer();
    if (!mixer || !samples || numFrames == 0) {
        return -1;
    }

    pthread_mutex_lock(&mixer->mutex);

    MixerDevice *device = Mixer_FindDeviceLocked(mixer, deviceID, (MixerChannelType)type);
    if (!device || deviceChannelIndex >= device->numChannels) {
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    MixerChannel *channel = &device->channels[deviceChannelIndex];
    if (channel->inputRingBuffer == NULL) {
        uint32_t ringBufferFrames = mixer->bufferFrames * 8;
        if (ringBufferFrames < 1024) {
            ringBufferFrames = 1024;
        }

        channel->inputRingBuffer = createRingBuffer((int)ringBufferFrames);
        if (channel->inputRingBuffer == NULL) {
            pthread_mutex_unlock(&mixer->mutex);
            return -1;
        }
    }

    RingBuffer *inputRingBuffer = channel->inputRingBuffer;
    pthread_mutex_unlock(&mixer->mutex);

    for (uint32_t frame = 0; frame < numFrames; frame++) {
        writeRingBuffer(inputRingBuffer, samples[frame]);
    }

    return 0;
}

/**
 * Read audio from ring buffer
 * @param ringBuffer Ring buffer pointer
 * @param channelIndex Channel index
 * @param outBuffer Output buffer for samples
 * @param numFrames Number of frames to read
 * @return Number of frames actually read
 */
int32_t SharedRingBuffer_ReadChannel(void *ringBuffer, int32_t channelIndex, float *outBuffer, int32_t numFrames) {
    if (!ringBuffer || !outBuffer || numFrames <= 0) {
        return 0;
    }

    // Simplified: fill with zeros to represent silence (typical when no audio is being captured)
    memset(outBuffer, 0, numFrames * sizeof(float));
    return numFrames;
}
