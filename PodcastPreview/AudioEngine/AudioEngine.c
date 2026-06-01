//
//  AudioEngine.c
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdlib.h>
#include <string.h>

#include "RingBuffer.h"
#include "AudioEngine.h"

// Engine state
typedef struct {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    RingBuffer *ringBuffer;
    UInt32 inputChannels;
    UInt32 outputChannels;
    Boolean isRunning;
    AudioStreamBasicDescription inputASBD;

    // Preallocated scratch buffers to avoid malloc/free in the real-time IOProc.
    float **scratch;                // [inputChannels][scratchFrameCapacity]
    size_t scratchFrameCapacity;    // max frames we can process per callback
    UInt32 scratchChannels;         // number of scratch channel buffers allocated
} AudioEngineState;

static AudioEngineState globalEngine = {0};

// Forward declaration of IOProc
OSStatus AudioEngine_IOProc(AudioObjectID inDevice,
                            const AudioTimeStamp *inNow,
                            const AudioBufferList *inInputData,
                            const AudioTimeStamp *inInputTime,
                            AudioBufferList *outOutputData,
                            const AudioTimeStamp *inOutputTime,
                            void *inClientData);

int AudioEngine_Start(AudioDeviceID deviceID,
                      UInt32 bufferSizeFrames,
                      UInt32 inputChannels,
                      UInt32 outputChannels)
{
    if (globalEngine.isRunning) return -1;

    globalEngine.deviceID      = deviceID;
    globalEngine.inputChannels = inputChannels;
    globalEngine.outputChannels = outputChannels;

    // Query and store the device's input stream format (for proper scaling to float)
    memset(&globalEngine.inputASBD, 0, sizeof(globalEngine.inputASBD));
    AudioObjectPropertyAddress fmtAddr = (AudioObjectPropertyAddress){
        kAudioDevicePropertyStreamFormat,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    UInt32 fmtSize = sizeof(AudioStreamBasicDescription);
    OSStatus fmtErr = AudioObjectGetPropertyData(deviceID, &fmtAddr, 0, NULL, &fmtSize, &globalEngine.inputASBD);
    if (fmtErr != noErr) {
        // Fallback to a sensible default if query fails: 32-bit float, non-interleaved
        globalEngine.inputASBD.mFormatID = kAudioFormatLinearPCM;
        globalEngine.inputASBD.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        globalEngine.inputASBD.mBitsPerChannel = 32;
        globalEngine.inputASBD.mChannelsPerFrame = inputChannels;
        globalEngine.inputASBD.mBytesPerFrame = 4;
        globalEngine.inputASBD.mFramesPerPacket = 1;
        globalEngine.inputASBD.mBytesPerPacket = globalEngine.inputASBD.mBytesPerFrame * globalEngine.inputASBD.mFramesPerPacket;
        globalEngine.inputASBD.mSampleRate = 48000.0;
    }

    // Allocate ring buffer with some headroom
    globalEngine.ringBuffer = RingBuffer_Create(bufferSizeFrames * 4, inputChannels);
    if (!globalEngine.ringBuffer) {
        return -2;
    }

    // Preallocate per-channel scratch buffers (no allocations in IOProc)
    globalEngine.scratchChannels = inputChannels;
    globalEngine.scratchFrameCapacity = (size_t)bufferSizeFrames;
    globalEngine.scratch = (float **)calloc(globalEngine.scratchChannels, sizeof(float *));
    if (!globalEngine.scratch) {
        RingBuffer_Destroy(globalEngine.ringBuffer);
        globalEngine.ringBuffer = NULL;
        return -2;
    }
    for (UInt32 ch = 0; ch < globalEngine.scratchChannels; ++ch) {
        globalEngine.scratch[ch] = (float *)malloc(sizeof(float) * globalEngine.scratchFrameCapacity);
        if (!globalEngine.scratch[ch]) {
            for (UInt32 i = 0; i < ch; ++i) free(globalEngine.scratch[i]);
            free(globalEngine.scratch);
            globalEngine.scratch = NULL;
            RingBuffer_Destroy(globalEngine.ringBuffer);
            globalEngine.ringBuffer = NULL;
            return -2;
        }
    }

    OSStatus err = AudioDeviceCreateIOProcID(deviceID,
                                             (AudioDeviceIOProc)AudioEngine_IOProc,
                                             NULL,
                                             &globalEngine.ioProcID);
    if (err != noErr) {
        if (globalEngine.scratch) {
            for (UInt32 ch = 0; ch < globalEngine.scratchChannels; ++ch) free(globalEngine.scratch[ch]);
            free(globalEngine.scratch);
            globalEngine.scratch = NULL;
        }
        globalEngine.scratchChannels = 0;
        globalEngine.scratchFrameCapacity = 0;

        RingBuffer_Destroy(globalEngine.ringBuffer);
        globalEngine.ringBuffer = NULL;
        return -3;
    }

    err = AudioDeviceStart(deviceID, globalEngine.ioProcID);
    if (err != noErr) {
        AudioDeviceDestroyIOProcID(deviceID, globalEngine.ioProcID);

        if (globalEngine.scratch) {
            for (UInt32 ch = 0; ch < globalEngine.scratchChannels; ++ch) free(globalEngine.scratch[ch]);
            free(globalEngine.scratch);
            globalEngine.scratch = NULL;
        }
        globalEngine.scratchChannels = 0;
        globalEngine.scratchFrameCapacity = 0;

        RingBuffer_Destroy(globalEngine.ringBuffer);
        globalEngine.ringBuffer = NULL;
        return -4;
    }

    globalEngine.isRunning = true;
    return 0;
}

void AudioEngine_Stop(void)
{
    if (!globalEngine.isRunning) return;

    AudioDeviceStop(globalEngine.deviceID, globalEngine.ioProcID);
    AudioDeviceDestroyIOProcID(globalEngine.deviceID, globalEngine.ioProcID);

    RingBuffer_Destroy(globalEngine.ringBuffer);

    if (globalEngine.scratch) {
        for (UInt32 ch = 0; ch < globalEngine.scratchChannels; ++ch) free(globalEngine.scratch[ch]);
        free(globalEngine.scratch);
        globalEngine.scratch = NULL;
    }
    globalEngine.scratchChannels = 0;
    globalEngine.scratchFrameCapacity = 0;

    globalEngine = (AudioEngineState){0};
}

static inline float convert_int16_to_float(int16_t s) {
    return (float)((double)s / 32768.0);
}

static inline float convert_int32_to_float(int32_t s) {
    return (float)((double)s / 2147483648.0); // 2^31
}

// IOProc callback: write input audio into per-channel ring buffer for analysis/metering
OSStatus AudioEngine_IOProc(AudioObjectID inDevice,
                            const AudioTimeStamp *inNow,
                            const AudioBufferList *inInputData,
                            const AudioTimeStamp *inInputTime,
                            AudioBufferList *outOutputData,
                            const AudioTimeStamp *inOutputTime,
                            void *inClientData)
{
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;
    (void)inClientData;

    if (!inInputData || !globalEngine.ringBuffer) return noErr;

    UInt32 numBuffers = inInputData->mNumberBuffers;
    UInt32 inputChans = globalEngine.inputChannels;

    // Determine format characteristics
    AudioStreamBasicDescription asbd = globalEngine.inputASBD;
    Boolean isFloat = (asbd.mFormatID == kAudioFormatLinearPCM) && ((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0);
    Boolean isSignedInt = (asbd.mFormatID == kAudioFormatLinearPCM) && ((asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0);
    Boolean isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bits = asbd.mBitsPerChannel;

    // Case A: Non-interleaved buffers (one buffer per channel)
    if (isNonInterleaved && numBuffers >= 1 && inInputData->mBuffers[0].mNumberChannels == 1) {
        for (UInt32 ch = 0; ch < numBuffers && ch < inputChans; ++ch) {
            const AudioBuffer *buf = &inInputData->mBuffers[ch];
            UInt32 frames = buf->mDataByteSize / (bits / 8);

            // Use preallocated scratch buffer (no malloc in IOProc)
            if (!globalEngine.scratch || ch >= globalEngine.scratchChannels) continue;
            size_t maxFrames = globalEngine.scratchFrameCapacity;
            if (maxFrames == 0) continue;
            if ((size_t)frames > maxFrames) frames = (UInt32)maxFrames;

            float *temp = globalEngine.scratch[ch];

            if (isFloat && bits == 32) {
                // Direct copy (Float32)
                memcpy(temp, buf->mData, (size_t)frames * sizeof(float));
            } else if (isSignedInt && bits == 16) {
                const int16_t *src = (const int16_t *)buf->mData;
                for (UInt32 f = 0; f < frames; ++f) temp[f] = convert_int16_to_float(src[f]);
            } else if (isSignedInt && bits == 32) {
                const int32_t *src = (const int32_t *)buf->mData;
                for (UInt32 f = 0; f < frames; ++f) temp[f] = convert_int32_to_float(src[f]);
            } else {
                // Unsupported/unknown format; zero out
                for (UInt32 f = 0; f < frames; ++f) temp[f] = 0.0f;
            }

            RingBuffer_Write(globalEngine.ringBuffer, temp, (size_t)frames * sizeof(float), ch);
        }
    }
    // Case B: Interleaved buffer (single buffer with N channels)
    else if (!isNonInterleaved && numBuffers == 1 && inInputData->mBuffers[0].mNumberChannels == inputChans) {
        const AudioBuffer *buf = &inInputData->mBuffers[0];
        UInt32 channels = buf->mNumberChannels;
        if (channels == 0) { return noErr; }
        UInt32 bytesPerSample = bits / 8;
        UInt32 frames = buf->mDataByteSize / (bytesPerSample * channels);

        // Use preallocated scratch buffers (no malloc/calloc in IOProc)
        if (!globalEngine.scratch || globalEngine.scratchChannels == 0 || globalEngine.scratchFrameCapacity == 0) {
            return noErr;
        }

        // Clamp to what we have scratch for
        UInt32 maxCh = channels;
        if (maxCh > inputChans) maxCh = inputChans;
        if (maxCh > globalEngine.scratchChannels) maxCh = globalEngine.scratchChannels;

        size_t maxFrames = globalEngine.scratchFrameCapacity;
        if ((size_t)frames > maxFrames) frames = (UInt32)maxFrames;

        if (isFloat && bits == 32) {
            const float *src = (const float *)buf->mData;
            for (UInt32 f = 0; f < frames; ++f) {
                UInt32 base = f * channels;
                for (UInt32 ch = 0; ch < maxCh; ++ch) {
                    globalEngine.scratch[ch][f] = src[base + ch];
                }
            }
        } else if (isSignedInt && bits == 16) {
            const int16_t *src = (const int16_t *)buf->mData;
            for (UInt32 f = 0; f < frames; ++f) {
                UInt32 base = f * channels;
                for (UInt32 ch = 0; ch < maxCh; ++ch) {
                    globalEngine.scratch[ch][f] = convert_int16_to_float(src[base + ch]);
                }
            }
        } else if (isSignedInt && bits == 32) {
            const int32_t *src = (const int32_t *)buf->mData;
            for (UInt32 f = 0; f < frames; ++f) {
                UInt32 base = f * channels;
                for (UInt32 ch = 0; ch < maxCh; ++ch) {
                    globalEngine.scratch[ch][f] = convert_int32_to_float(src[base + ch]);
                }
            }
        } else {
            // Unsupported/unknown format; zero
            for (UInt32 ch = 0; ch < maxCh; ++ch) {
                for (UInt32 f = 0; f < frames; ++f) globalEngine.scratch[ch][f] = 0.0f;
            }
        }

        for (UInt32 ch = 0; ch < maxCh; ++ch) {
            RingBuffer_Write(globalEngine.ringBuffer, globalEngine.scratch[ch], (size_t)frames * sizeof(float), ch);
        }
    }
    // Fallback: preserve previous behavior but convert best-effort
    else {
        for (UInt32 i = 0; i < numBuffers && i < inputChans; ++i) {
            const AudioBuffer *buf = &inInputData->mBuffers[i];
            UInt32 frames = 0;
            if (bits >= 8) frames = buf->mDataByteSize / (bits / 8);

            if (!globalEngine.scratch || i >= globalEngine.scratchChannels) continue;
            size_t maxFrames = globalEngine.scratchFrameCapacity;
            if (maxFrames == 0) continue;
            if ((size_t)frames > maxFrames) frames = (UInt32)maxFrames;

            float *temp = globalEngine.scratch[i];

            if (isFloat && bits == 32) {
                memcpy(temp, buf->mData, (size_t)frames * sizeof(float));
            } else if (isSignedInt && bits == 16) {
                const int16_t *src = (const int16_t *)buf->mData;
                for (UInt32 f = 0; f < frames; ++f) temp[f] = convert_int16_to_float(src[f]);
            } else if (isSignedInt && bits == 32) {
                const int32_t *src = (const int32_t *)buf->mData;
                for (UInt32 f = 0; f < frames; ++f) temp[f] = convert_int32_to_float(src[f]);
            } else {
                for (UInt32 f = 0; f < frames; ++f) temp[f] = 0.0f;
            }

            RingBuffer_Write(globalEngine.ringBuffer, temp, (size_t)frames * sizeof(float), i);
        }
    }

    return noErr;
}

// C API for Swift
AudioDeviceID AudioEngine_GetCurrentDevice(void)
{
    return globalEngine.deviceID;
}

bool AudioEngine_IsRunning(void)
{
    return globalEngine.isRunning ? true : false;
}

RingBuffer *AudioEngine_GetRingBuffer(void)
{
    return globalEngine.ringBuffer;
}
