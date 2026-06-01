//
//  MultiAudioEngine.c
//  PodcastPreview
//
//  Created by Chris Izatt on 17/03/2026.
//
//  Multi-instance audio engine for simultaneous device monitoring.
//

#include "MultiAudioEngine.h"
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdlib.h>

// Internal structure for an audio engine instance
struct AudioEngineInstance {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    RingBuffer *ringBuffer;
    UInt32 inputChannels;
    UInt32 outputChannels;
    Boolean isRunning;
    pthread_mutex_t lock;
    
    // Scratch buffers for de-interleaving (avoid malloc in IOProc)
    float **scratch;
    size_t scratchFrameCapacity;
};

// Audio I/O callback for this instance
static OSStatus audioIOProc(
    AudioDeviceID inDevice,
    const AudioTimeStamp *inNow,
    const AudioBufferList *inInputData,
    const AudioTimeStamp *inInputTime,
    AudioBufferList *outOutputData,
    const AudioTimeStamp *inOutputTime,
    void *inClientData)
{
    AudioEngineHandle handle = (AudioEngineHandle)inClientData;
    if (!handle || !handle->ringBuffer || !inInputData) {
        // Zero output if needed
        if (outOutputData) {
            for (UInt32 i = 0; i < outOutputData->mNumberBuffers; i++) {
                memset(outOutputData->mBuffers[i].mData, 0, outOutputData->mBuffers[i].mDataByteSize);
            }
        }
        return noErr;
    }
    
    // Process input data - assume non-interleaved Float32 (most common for Core Audio)
    UInt32 numBuffers = inInputData->mNumberBuffers;
    
    // Non-interleaved: one buffer per channel
    if (numBuffers >= 1 && inInputData->mBuffers[0].mNumberChannels == 1) {
        for (UInt32 ch = 0; ch < numBuffers && ch < handle->inputChannels; ++ch) {
            const AudioBuffer *buffer = &inInputData->mBuffers[ch];
            const float *samples = (const float *)buffer->mData;
            size_t bytes = buffer->mDataByteSize;
            
            if (samples && bytes > 0) {
                RingBuffer_Write(handle->ringBuffer, samples, bytes, ch);
            }
        }
    }
    // Interleaved: single buffer with multiple channels - need to de-interleave
    else if (numBuffers == 1 && inInputData->mBuffers[0].mNumberChannels == handle->inputChannels) {
        const AudioBuffer *buffer = &inInputData->mBuffers[0];
        const float *samples = (const float *)buffer->mData;
        UInt32 channels = buffer->mNumberChannels;
        UInt32 frameCount = buffer->mDataByteSize / (channels * sizeof(float));
        
        // Clamp to scratch buffer capacity
        if (frameCount > handle->scratchFrameCapacity) {
            frameCount = (UInt32)handle->scratchFrameCapacity;
        }
        
        // De-interleave into scratch buffers
        if (samples && frameCount > 0 && handle->scratch) {
            for (UInt32 f = 0; f < frameCount; ++f) {
                for (UInt32 ch = 0; ch < channels && ch < handle->inputChannels; ++ch) {
                    handle->scratch[ch][f] = samples[f * channels + ch];
                }
            }
            
            // Write each channel to ring buffer
            for (UInt32 ch = 0; ch < channels && ch < handle->inputChannels; ++ch) {
                RingBuffer_Write(handle->ringBuffer, handle->scratch[ch], frameCount * sizeof(float), ch);
            }
        }
    }
    
    // Zero output if needed
    if (outOutputData) {
        for (UInt32 i = 0; i < outOutputData->mNumberBuffers; i++) {
            memset(outOutputData->mBuffers[i].mData, 0, outOutputData->mBuffers[i].mDataByteSize);
        }
    }
    
    return noErr;
}

AudioEngineHandle AudioEngine_Create(AudioDeviceID deviceID,
                                      UInt32 bufferSizeFrames,
                                      UInt32 inputChannels,
                                      UInt32 outputChannels)
{
    if (inputChannels == 0) {
        return NULL;
    }
    
    // Allocate instance
    AudioEngineHandle handle = (AudioEngineHandle)calloc(1, sizeof(struct AudioEngineInstance));
    if (!handle) {
        return NULL;
    }
    
    handle->deviceID = deviceID;
    handle->inputChannels = inputChannels;
    handle->outputChannels = outputChannels;
    handle->isRunning = false;
    handle->scratchFrameCapacity = bufferSizeFrames;
    pthread_mutex_init(&handle->lock, NULL);
    
    // Create ring buffer
    handle->ringBuffer = RingBuffer_Create(bufferSizeFrames * 4, inputChannels);
    if (!handle->ringBuffer) {
        free(handle);
        return NULL;
    }
    
    // Allocate scratch buffers for de-interleaving
    handle->scratch = (float **)calloc(inputChannels, sizeof(float *));
    if (!handle->scratch) {
        RingBuffer_Destroy(handle->ringBuffer);
        free(handle);
        return NULL;
    }
    
    for (UInt32 ch = 0; ch < inputChannels; ++ch) {
        handle->scratch[ch] = (float *)malloc(bufferSizeFrames * sizeof(float));
        if (!handle->scratch[ch]) {
            // Cleanup already allocated scratch buffers
            for (UInt32 i = 0; i < ch; ++i) {
                free(handle->scratch[i]);
            }
            free(handle->scratch);
            RingBuffer_Destroy(handle->ringBuffer);
            free(handle);
            return NULL;
        }
    }
    
    return handle;
}

int AudioEngine_StartInstance(AudioEngineHandle handle)
{
    if (!handle) {
        return -1;
    }
    
    pthread_mutex_lock(&handle->lock);
    
    if (handle->isRunning) {
        pthread_mutex_unlock(&handle->lock);
        return 0; // Already running
    }
    
    // Add I/O proc to device
    OSStatus status = AudioDeviceCreateIOProcID(
        handle->deviceID,
        audioIOProc,
        handle,
        &handle->ioProcID
    );
    
    if (status != noErr) {
        pthread_mutex_unlock(&handle->lock);
        return -2;
    }
    
    // Start the device
    status = AudioDeviceStart(handle->deviceID, audioIOProc);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(handle->deviceID, handle->ioProcID);
        pthread_mutex_unlock(&handle->lock);
        return -3;
    }
    
    handle->isRunning = true;
    pthread_mutex_unlock(&handle->lock);
    
    return 0;
}

void AudioEngine_StopInstance(AudioEngineHandle handle)
{
    if (!handle) {
        return;
    }
    
    pthread_mutex_lock(&handle->lock);
    
    if (!handle->isRunning) {
        pthread_mutex_unlock(&handle->lock);
        return;
    }
    
    // Stop the device
    AudioDeviceStop(handle->deviceID, audioIOProc);
    
    // Remove I/O proc
    AudioDeviceDestroyIOProcID(handle->deviceID, handle->ioProcID);
    
    handle->isRunning = false;
    pthread_mutex_unlock(&handle->lock);
}

Boolean AudioEngine_IsInstanceRunning(AudioEngineHandle handle)
{
    if (!handle) {
        return false;
    }
    
    pthread_mutex_lock(&handle->lock);
    Boolean running = handle->isRunning;
    pthread_mutex_unlock(&handle->lock);
    
    return running;
}

RingBuffer* AudioEngine_GetInstanceRingBuffer(AudioEngineHandle handle)
{
    if (!handle) {
        return NULL;
    }
    
    return handle->ringBuffer;
}

void AudioEngine_Destroy(AudioEngineHandle handle)
{
    if (!handle) {
        return;
    }
    
    // Stop if running
    AudioEngine_StopInstance(handle);
    
    // Destroy scratch buffers
    if (handle->scratch) {
        for (UInt32 ch = 0; ch < handle->inputChannels; ++ch) {
            if (handle->scratch[ch]) {
                free(handle->scratch[ch]);
            }
        }
        free(handle->scratch);
        handle->scratch = NULL;
    }
    
    // Destroy ring buffer
    if (handle->ringBuffer) {
        RingBuffer_Destroy(handle->ringBuffer);
        handle->ringBuffer = NULL;
    }
    
    // Destroy mutex
    pthread_mutex_destroy(&handle->lock);
    
    // Free instance
    free(handle);
}
