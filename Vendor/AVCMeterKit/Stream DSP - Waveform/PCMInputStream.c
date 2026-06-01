#include "PCMInputStream.h"
#include "PCMRingBuffer.h"
#include <CoreAudio/CoreAudio.h>
#include <pthread.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// PCMInputStream.c
// Handles setup and real-time streaming of audio input data via HAL.
// Converts interleaved float PCM input from CoreAudio into per-channel buffers.
// Feeds waveform buffers and ring buffers for downstream use (e.g., metering and waveform display).

#define MAX_CHANNELS 64
extern float* sampleArrays[MAX_CHANNELS];

static void PCMInputStream_FreeBuffers(PCMInputStream* stream) {
    if (!stream) return;

    if (stream->ringBuffer) {
        destroyPCMRingBuffer(stream->ringBuffer);
        stream->ringBuffer = NULL;
    }

    if (stream->waveformBuffer) {
        for (int i = 0; i < MAX_CHANNELS; ++i) {
            if (stream->waveformBuffer[i]) {
                free(stream->waveformBuffer[i]);
                stream->waveformBuffer[i] = NULL;
            }
        }
        free(stream->waveformBuffer);
        stream->waveformBuffer = NULL;
    }

    if (stream->sampleArrays) {
        for (int i = 0; i < MAX_CHANNELS; ++i) {
            if (stream->sampleArrays[i]) {
                free(stream->sampleArrays[i]);
                stream->sampleArrays[i] = NULL;
            }
        }
        free(stream->sampleArrays);
        stream->sampleArrays = NULL;
    }
}

static OSStatus PCMIOProc(AudioDeviceID inDevice,
                          const AudioTimeStamp* inNow,
                          const AudioBufferList* inInputData,
                          const AudioTimeStamp* inInputTime,
                          AudioBufferList* outOutputData,
                          const AudioTimeStamp* inOutputTime,
                          void* inClientData)
{
    PCMInputStream* stream = (PCMInputStream*)inClientData;
    if (!stream || !inInputData) return noErr;

    UInt32 numFrames = inInputData->mBuffers[0].mDataByteSize / stream->streamFormat.mBytesPerFrame;
    UInt32 channelCount = stream->streamFormat.mChannelsPerFrame;
    if (inInputData->mBuffers[0].mDataByteSize == 0 || channelCount > MAX_CHANNELS) return noErr;

    float* interleaved = (float*)inInputData->mBuffers[0].mData;
    float peaks[MAX_CHANNELS] = {0};
    float sums[MAX_CHANNELS] = {0};

    // Process incoming interleaved audio and deinterleave into per-channel format
    // Compute RMS and peak values for each channel
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
    pthread_mutex_lock(&stream->lock);
    for (UInt32 ch = 0; ch < channelCount; ++ch) {
        stream->peak[ch] = peaks[ch];
        stream->rms[ch] = sqrtf(sums[ch] * invFrames);
    }
    // Write per-channel samples to shared ring buffer (used by waveform pipeline)
    if (stream->ringBuffer) {
        bool silent = true;
        for (UInt32 i = 0; i < numFrames * channelCount; ++i) {
            if (fabsf(interleaved[i]) > 1e-6f) {
                silent = false;
                break;
            }
        }

        // Deinterleave and write each channel's samples to the ring buffer
        float* channelSamples = malloc(sizeof(float) * numFrames);
        for (UInt32 ch = 0; ch < channelCount; ++ch) {
            for (UInt32 frame = 0; frame < numFrames; ++frame) {
                channelSamples[frame] = interleaved[frame * channelCount + ch];
            }
            writeSingleChannelToRingBuffer(
                stream->ringBuffer,
                ch,
                channelSamples,
                numFrames,
                1 // Non-interleaved
            );
            if (stream->waveformBuffer) {
                memcpy(stream->waveformBuffer[ch], channelSamples, sizeof(float) * numFrames);
            }
        }
        free(channelSamples);
    }
    if (stream->pcmCallback) {
        // Copy deinterleaved audio into temporary buffers for callback (used by Swift metering manager)
        for (UInt32 ch = 0; ch < channelCount; ++ch) {
            if (!stream->sampleArrays[ch]) {
                stream->sampleArrays[ch] = malloc(sizeof(float) * numFrames);
            }
        }

        for (UInt32 frame = 0; frame < numFrames; ++frame) {
            for (UInt32 ch = 0; ch < channelCount; ++ch) {
                stream->sampleArrays[ch][frame] = interleaved[frame * channelCount + ch];
            }
        }

        // Call Swift-side callback with extracted per-channel data
        stream->pcmCallback(stream->sampleArrays, numFrames, channelCount, stream->callbackContext);

        for (UInt32 ch = 0; ch < channelCount; ++ch) {
            free(stream->sampleArrays[ch]);
            stream->sampleArrays[ch] = NULL;
        }
    }
    pthread_mutex_unlock(&stream->lock);

    // fprintf(stderr, "[PCMIOProc] Completed callback for device %u with %u frames and %u channels\n", inDevice, numFrames, channelCount);

    return noErr;
}

PCMInputStream* createPCMInputStream(AudioDeviceID deviceID,
                                     void (*callback)(float** samples, UInt32 numFrames, UInt32 channelCount, void* context),
                                     void* context)
{
    // Allocate and initialize the PCMInputStream struct
    PCMInputStream* stream = (PCMInputStream*)malloc(sizeof(PCMInputStream));
    if (!stream) return NULL;

    memset(stream, 0, sizeof(PCMInputStream));
    stream->deviceID = deviceID;
    stream->pcmCallback = callback;
    // fprintf(stderr, "[createPCMInputStream] Stream created for device %u\n", deviceID);
    stream->callbackContext = context;
    pthread_mutex_init(&stream->lock, NULL);

    // Allocate waveform buffer (used by UI or debug tools)
    stream->waveformBuffer = (float**)malloc(sizeof(float*) * MAX_CHANNELS);
    if (!stream->waveformBuffer) {
        // fprintf(stderr, "[createPCMInputStream] Failed to allocate waveformBuffer pointer array\n");
        pthread_mutex_destroy(&stream->lock);
        free(stream);
        return NULL;
    }

    memset(stream->waveformBuffer, 0, sizeof(float*) * MAX_CHANNELS);

    for (int i = 0; i < MAX_CHANNELS; ++i) {
        stream->waveformBuffer[i] = (float*)malloc(sizeof(float) * 2048);
        if (!stream->waveformBuffer[i]) {
            // fprintf(stderr, "[createPCMInputStream] Failed to allocate waveformBuffer[%d]\n", i);
            PCMInputStream_FreeBuffers(stream);
            pthread_mutex_destroy(&stream->lock);
            free(stream);
            return NULL;
        }
        memset(stream->waveformBuffer[i], 0, sizeof(float) * 2048);
    }

    // Allocate sample arrays (used in callback)
    stream->sampleArrays = (float**)malloc(sizeof(float*) * MAX_CHANNELS);
    if (!stream->sampleArrays) {
        // fprintf(stderr, "[createPCMInputStream] Failed to allocate sampleArrays\n");
        PCMInputStream_FreeBuffers(stream);
        pthread_mutex_destroy(&stream->lock);
        free(stream);
        return NULL;
    }
    for (int i = 0; i < MAX_CHANNELS; ++i) {
        stream->sampleArrays[i] = NULL;
    }

    // Fetch stream format for input device
    UInt32 size = sizeof(stream->streamFormat);
    AudioDeviceGetProperty(deviceID, 0, true, kAudioDevicePropertyStreamFormat, &size, &stream->streamFormat);

    // Create ring buffer for persistent per-channel samples
    stream->ringBuffer = createPCMRingBuffer(4096, stream->streamFormat.mChannelsPerFrame);

    // Attach and start input IOProc
    OSStatus err = AudioDeviceCreateIOProcID(deviceID, PCMIOProc, stream, &stream->ioProcID);
    if (err != noErr) {
        PCMInputStream_FreeBuffers(stream);
        pthread_mutex_destroy(&stream->lock);
        free(stream);
        return NULL;
    }

    err = AudioDeviceStart(deviceID, stream->ioProcID);
    if (err != noErr) {
        AudioDeviceDestroyIOProcID(deviceID, stream->ioProcID);
        PCMInputStream_FreeBuffers(stream);
        pthread_mutex_destroy(&stream->lock);
        free(stream);
        return NULL;
    }

    return stream;
}

void destroyPCMInputStream(PCMInputStream* stream)
{
    // Tear down stream and free resources
    if (!stream) return;
    // fprintf(stderr, "[destroyPCMInputStream] Destroying stream for device %u\n", stream->deviceID);
    AudioDeviceStop(stream->deviceID, stream->ioProcID);
    AudioDeviceDestroyIOProcID(stream->deviceID, stream->ioProcID);
    PCMInputStream_FreeBuffers(stream);
    pthread_mutex_destroy(&stream->lock);
    free(stream);
}

void PCMInputStream_Clear(PCMInputStream* stream) {
    if (!stream) return;
    // fprintf(stderr, "[PCMInputStream_Clear] Clear called on stream for device %u\n", stream->deviceID);
    // Future: clear internal buffer
}

int PCMInputStream_Filled(PCMInputStream* stream) {
    if (!stream) return 0;
    // Throttle this log to a single occurrence
    static int hasLoggedFilled = 0;
    if (!hasLoggedFilled) {
        // fprintf(stderr, "[PCMInputStream.Filled] Filled check on device %u\n", stream->deviceID);
        hasLoggedFilled = 1;
    }
    // Future: return number of available frames in buffer
    return 0;
}

int PCMInputStream_Read(PCMInputStream* stream, float* outBuffer, int frameCount) {
    if (!stream || !outBuffer) return 0;
    // fprintf(stderr, "[PCMInputStream_Read] Read requested for device %u, frameCount: %d\n", stream->deviceID, frameCount);
    // Future: read up to frameCount samples into outBuffer
    return 0;
}

void PCMInputStream_Write(PCMInputStream* stream, const float* samples, int frameCount) {
    if (!stream || !samples) return;
    // fprintf(stderr, "[PCMInputStream_Write] Write requested for device %u, frameCount: %d\n", stream->deviceID, frameCount);
    // Future: write samples into internal buffer
}

int PCMInputStream_ReadChannel(PCMInputStream* stream, float* outBuffer, int frameCount, int channelIndex) {
    if (!stream || !outBuffer || channelIndex < 0 || channelIndex >= MAX_CHANNELS) return 0;

    // Pull audio data from the ring buffer into the output buffer.
    return readSingleChannelFromRingBuffer(stream->ringBuffer, channelIndex, outBuffer, frameCount);
}
