//
//  FFTInputStream.c
//  AVCMeter
//
//  Created by Chris Izatt on 28/06/2025.
//


#include <CoreAudio/CoreAudio.h>
#include "FFTInputStream.h"
#include "FFTRingBuffer.h"
#include <pthread.h>

// Linked list of active streams
static FFTInputStream* gStreamList = NULL;
static pthread_mutex_t gStreamListLock = PTHREAD_MUTEX_INITIALIZER;

typedef struct FFTInputStream {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    FFTBuffer* ringBuffers[64];
    UInt32 channelCount;
    FFTInputStream* next;
} FFTInputStream;

static OSStatus FFTIOProc(AudioDeviceID inDevice,
                          const AudioTimeStamp* inNow,
                          const AudioBufferList* inInputData,
                          const AudioTimeStamp* inInputTime,
                          AudioBufferList* outOutputData,
                          const AudioTimeStamp* inOutputTime,
                          void* clientData)
{
    (void)clientData;
    pthread_mutex_lock(&gStreamListLock);
    FFTInputStream* cur = gStreamList;
    while (cur) {
        if (cur->deviceID == inDevice && inInputData) {
            UInt32 channelCount = cur->channelCount;
            // Handle interleaved vs non-interleaved input
            if (inInputData->mNumberBuffers == 1) {
                // Interleaved audio: single buffer contains all channels
                AudioBuffer *buf0 = &inInputData->mBuffers[0];
                UInt32 frames = buf0->mDataByteSize / (sizeof(float) * channelCount);
                float *interleaved = (float*)buf0->mData;
                for (UInt32 ch = 0; ch < channelCount; ++ch) {
                    // Deinterleave channel ch by stepping through interleaved data
                    // Write frames samples with stride = channelCount
                    for (UInt32 i = 0; i < frames; ++i) {
                        float sample = interleaved[i * channelCount + ch];
                        fftWriteToBuffer(cur->ringBuffers[ch], &sample, 1);
                    }
                }
            } else {
                // Non-interleaved: one buffer per channel
                for (UInt32 ch = 0; ch < channelCount; ++ch) {
                    if (ch >= inInputData->mNumberBuffers) break;
                    AudioBuffer *buffer = &inInputData->mBuffers[ch];
                    UInt32 frames = buffer->mDataByteSize / sizeof(float);
                    fftWriteToBuffer(cur->ringBuffers[ch], (const float*)buffer->mData, frames);
                }
            }
        }
        cur = cur->next;
    }
    pthread_mutex_unlock(&gStreamListLock);
    return noErr;
}

FFTInputStream* FFTInputStream_Create(AudioDeviceID deviceID, UInt32 channelCount, UInt32 sampleRate, UInt32 bufferSize)
{
    FFTInputStream* ctx = (FFTInputStream*)calloc(1, sizeof(FFTInputStream));
    if (!ctx)
        return NULL;
    ctx->deviceID = deviceID;
    ctx->channelCount = channelCount;
    (void)sampleRate;
    for (UInt32 ch = 0; ch < channelCount; ++ch) {
        ctx->ringBuffers[ch] = createFFTBuffer(bufferSize);
        if (!ctx->ringBuffers[ch]) {
            for (UInt32 i = 0; i < ch; ++i) {
                destroyFFTBuffer(ctx->ringBuffers[i]);
            }
            free(ctx);
            return NULL;
        }
    }
    pthread_mutex_lock(&gStreamListLock);
    // Insert at head
    ctx->next = gStreamList;
    gStreamList = ctx;
    // If this is the first stream for this device, register IOProc
    FFTInputStream* cur = gStreamList;
    int count = 0;
    while (cur) {
        if (cur->deviceID == deviceID) count++;
        cur = cur->next;
    }
    if (count == 1) {
        AudioDeviceAddIOProc(deviceID, FFTIOProc, NULL);
    }
    pthread_mutex_unlock(&gStreamListLock);
    // Note: AudioDeviceIOProcID is not used here, but could be for newer APIs.
    ctx->ioProcID = NULL;
    return ctx;
}

void FFTInputStream_Destroy(FFTInputStream* stream)
{
    if (!stream)
        return;
    pthread_mutex_lock(&gStreamListLock);
    FFTInputStream **ptr = &gStreamList;
    while (*ptr) {
        if (*ptr == stream) {
            *ptr = stream->next;
            break;
        }
        ptr = &(*ptr)->next;
    }
    // If no more streams for this device, remove IOProc
    FFTInputStream* cur = gStreamList;
    bool stillHas = false;
    while (cur) {
        if (cur->deviceID == stream->deviceID) { stillHas = true; break; }
        cur = cur->next;
    }
    if (!stillHas) {
        AudioDeviceRemoveIOProc(stream->deviceID, FFTIOProc);
    }
    pthread_mutex_unlock(&gStreamListLock);
    for (UInt32 ch = 0; ch < stream->channelCount; ++ch) {
        destroyFFTBuffer(stream->ringBuffers[ch]);
    }
    free(stream);
}

void FFTInputStream_Clear(FFTInputStream* stream)
{
    if (!stream)
        return;
    for (UInt32 ch = 0; ch < stream->channelCount; ++ch) {
        FFTBuffer* rb = stream->ringBuffers[ch];
        atomic_store(&rb->fillCount, 0);
        atomic_store(&rb->readIndex, 0);
        atomic_store(&rb->writeIndex, 0);
    }
}

int FFTInputStream_Read(FFTInputStream* stream, int channelIndex, float* outBuffer, int frameCount) {
    if (!stream || channelIndex < 0 || channelIndex >= stream->channelCount || !outBuffer || frameCount <= 0)
        return 0;
    FFTBuffer* rb = stream->ringBuffers[channelIndex];
    return (int)fftReadFromBuffer(rb, outBuffer, (UInt32)frameCount);
}

int FFTInputStream_Filled(FFTInputStream* stream, int channelIndex) {
    if (!stream || channelIndex < 0 || channelIndex >= stream->channelCount)
        return 0;
    FFTBuffer* rb = stream->ringBuffers[channelIndex];
    return (int)fftGetBufferFillLevel(rb);
}

OSStatus FFTInputStream_Start(FFTInputStream* stream) {
    if (!stream)
        return kAudio_ParamError;
    return AudioDeviceStart(stream->deviceID, FFTIOProc);
}

OSStatus FFTInputStream_Stop(FFTInputStream* stream) {
    if (!stream)
        return kAudio_ParamError;
    return AudioDeviceStop(stream->deviceID, FFTIOProc);
}
