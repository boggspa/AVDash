#include "PodcastPreviewRouteInputEngine.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "PodcastPreviewLoopbackTransport.h"

enum {
    kPPRouteInputTapBufferMultiplier = 64,
    kPPRouteInputTransportRingMultiplier = 128
};

typedef struct {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    RingBuffer *tapRingBuffer;
    PPVirtualLoopbackWriterRef writer;
    UInt32 inputChannels;
    UInt32 bufferFrames;
    AudioStreamBasicDescription inputASBD;
    float **scratch;
    float *interleavedScratch;
    size_t scratchFrameCapacity;
    _Atomic uint64_t framesCaptured;
    _Atomic bool isRunning;
} PPRouteInputEngineState;

static PPRouteInputEngineState gRouteInput = {0};

static void pp_route_prepare_realtime_memory(void *memory, size_t byteCount)
{
    if (!memory || byteCount == 0) {
        return;
    }

#if defined(MADV_WILLNEED)
    madvise(memory, byteCount, MADV_WILLNEED);
#endif
    (void)mlock(memory, byteCount);

    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0) {
        pageSize = 4096;
    }

    volatile unsigned char *cursor = (volatile unsigned char *)memory;
    for (size_t offset = 0; offset < byteCount; offset += (size_t)pageSize) {
        cursor[offset] = cursor[offset];
    }
    cursor[byteCount - 1] = cursor[byteCount - 1];
}

static inline float pp_route_int16_to_float(int16_t sample)
{
    return (float)((double)sample / 32768.0);
}

static inline float pp_route_int32_to_float(int32_t sample)
{
    return (float)((double)sample / 2147483648.0);
}

static void pp_route_input_clear_state(void)
{
    if (gRouteInput.tapRingBuffer) {
        RingBuffer_Destroy(gRouteInput.tapRingBuffer);
        gRouteInput.tapRingBuffer = NULL;
    }

    if (gRouteInput.writer) {
        PPVirtualLoopbackTransport_CloseWriter(gRouteInput.writer);
        gRouteInput.writer = NULL;
    }

    if (gRouteInput.scratch) {
        for (UInt32 ch = 0; ch < gRouteInput.inputChannels; ++ch) {
            free(gRouteInput.scratch[ch]);
        }
        free(gRouteInput.scratch);
        gRouteInput.scratch = NULL;
    }

    free(gRouteInput.interleavedScratch);
    gRouteInput.interleavedScratch = NULL;

    gRouteInput = (PPRouteInputEngineState){0};
}

static OSStatus pp_route_input_io_proc(AudioObjectID inDevice,
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

    if (!inInputData ||
        !gRouteInput.tapRingBuffer ||
        !gRouteInput.writer ||
        !atomic_load_explicit(&gRouteInput.isRunning, memory_order_acquire)) {
        return noErr;
    }

    UInt32 numBuffers = inInputData->mNumberBuffers;
    UInt32 inputChans = gRouteInput.inputChannels;

    AudioStreamBasicDescription asbd = gRouteInput.inputASBD;
    Boolean isFloat = (asbd.mFormatID == kAudioFormatLinearPCM) && ((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0);
    Boolean isSignedInt = (asbd.mFormatID == kAudioFormatLinearPCM) && ((asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0);
    Boolean isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 bits = asbd.mBitsPerChannel;
    UInt32 maxFrames = (UInt32)gRouteInput.scratchFrameCapacity;
    UInt64 inputStartHostTime = 0;

    if (inInputTime && (inInputTime->mFlags & kAudioTimeStampHostTimeValid) != 0) {
        inputStartHostTime = inInputTime->mHostTime;
    } else if (inNow && (inNow->mFlags & kAudioTimeStampHostTimeValid) != 0) {
        inputStartHostTime = inNow->mHostTime;
    }

    if (isNonInterleaved && numBuffers >= 1 && inInputData->mBuffers[0].mNumberChannels == 1) {
        UInt32 framesForTransport = 0;

        for (UInt32 ch = 0; ch < numBuffers && ch < inputChans; ++ch) {
            const AudioBuffer *buffer = &inInputData->mBuffers[ch];
            UInt32 frames = buffer->mDataByteSize / (bits / 8);
            if (frames > maxFrames) {
                frames = maxFrames;
            }

            float *scratch = gRouteInput.scratch[ch];
            if (isFloat && bits == 32) {
                memcpy(scratch, buffer->mData, (size_t)frames * sizeof(float));
            } else if (isSignedInt && bits == 16) {
                const int16_t *source = (const int16_t *)buffer->mData;
                for (UInt32 frame = 0; frame < frames; ++frame) {
                    scratch[frame] = pp_route_int16_to_float(source[frame]);
                }
            } else if (isSignedInt && bits == 32) {
                const int32_t *source = (const int32_t *)buffer->mData;
                for (UInt32 frame = 0; frame < frames; ++frame) {
                    scratch[frame] = pp_route_int32_to_float(source[frame]);
                }
            } else {
                memset(scratch, 0, (size_t)frames * sizeof(float));
            }

            RingBuffer_Write(gRouteInput.tapRingBuffer,
                             scratch,
                             (size_t)frames * sizeof(float),
                             ch);
            if (frames > framesForTransport) {
                framesForTransport = frames;
            }
        }

        if (framesForTransport > 0) {
            for (UInt32 frame = 0; frame < framesForTransport; ++frame) {
                for (UInt32 ch = 0; ch < inputChans; ++ch) {
                    gRouteInput.interleavedScratch[frame * inputChans + ch] = gRouteInput.scratch[ch][frame];
                }
            }

            PPVirtualLoopbackTransport_WriteInterleavedWithTiming(gRouteInput.writer,
                                                                  gRouteInput.interleavedScratch,
                                                                  framesForTransport,
                                                                  inputChans,
                                                                  inputStartHostTime,
                                                                  0.0);
            atomic_fetch_add_explicit(&gRouteInput.framesCaptured,
                                      framesForTransport,
                                      memory_order_relaxed);
        }
    } else if (!isNonInterleaved && numBuffers == 1 && inInputData->mBuffers[0].mNumberChannels == inputChans) {
        const AudioBuffer *buffer = &inInputData->mBuffers[0];
        UInt32 channels = buffer->mNumberChannels;
        UInt32 bytesPerSample = bits / 8;
        UInt32 frames = buffer->mDataByteSize / (bytesPerSample * channels);
        if (frames > maxFrames) {
            frames = maxFrames;
        }

        if (isFloat && bits == 32) {
            const float *source = (const float *)buffer->mData;
            memcpy(gRouteInput.interleavedScratch, source, (size_t)frames * channels * sizeof(float));
        } else if (isSignedInt && bits == 16) {
            const int16_t *source = (const int16_t *)buffer->mData;
            for (UInt32 frame = 0; frame < frames; ++frame) {
                UInt32 base = frame * channels;
                for (UInt32 ch = 0; ch < channels; ++ch) {
                    gRouteInput.interleavedScratch[base + ch] = pp_route_int16_to_float(source[base + ch]);
                }
            }
        } else if (isSignedInt && bits == 32) {
            const int32_t *source = (const int32_t *)buffer->mData;
            for (UInt32 frame = 0; frame < frames; ++frame) {
                UInt32 base = frame * channels;
                for (UInt32 ch = 0; ch < channels; ++ch) {
                    gRouteInput.interleavedScratch[base + ch] = pp_route_int32_to_float(source[base + ch]);
                }
            }
        } else {
            memset(gRouteInput.interleavedScratch, 0, (size_t)frames * channels * sizeof(float));
        }

        for (UInt32 ch = 0; ch < channels; ++ch) {
            for (UInt32 frame = 0; frame < frames; ++frame) {
                gRouteInput.scratch[ch][frame] = gRouteInput.interleavedScratch[frame * channels + ch];
            }
            RingBuffer_Write(gRouteInput.tapRingBuffer,
                             gRouteInput.scratch[ch],
                             (size_t)frames * sizeof(float),
                             ch);
        }

        PPVirtualLoopbackTransport_WriteInterleavedWithTiming(gRouteInput.writer,
                                                              gRouteInput.interleavedScratch,
                                                              frames,
                                                              channels,
                                                              inputStartHostTime,
                                                              0.0);
        atomic_fetch_add_explicit(&gRouteInput.framesCaptured, frames, memory_order_relaxed);
    }

    return noErr;
}

int PPRouteInputEngine_Start(AudioDeviceID deviceID, uint32_t bufferFrames, uint32_t inputChannels)
{
    if (atomic_load_explicit(&gRouteInput.isRunning, memory_order_acquire)) {
        return -1;
    }

    if (deviceID == kAudioObjectUnknown || inputChannels == 0 || bufferFrames == 0) {
        return -2;
    }

    gRouteInput.deviceID = deviceID;
    gRouteInput.inputChannels = inputChannels;
    gRouteInput.bufferFrames = bufferFrames;
    gRouteInput.scratchFrameCapacity = bufferFrames;

    AudioObjectPropertyAddress fmtAddr = (AudioObjectPropertyAddress){
        kAudioDevicePropertyStreamFormat,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    UInt32 fmtSize = sizeof(AudioStreamBasicDescription);
    memset(&gRouteInput.inputASBD, 0, sizeof(gRouteInput.inputASBD));
    OSStatus fmtErr = AudioObjectGetPropertyData(deviceID, &fmtAddr, 0, NULL, &fmtSize, &gRouteInput.inputASBD);
    if (fmtErr != noErr) {
        gRouteInput.inputASBD.mFormatID = kAudioFormatLinearPCM;
        gRouteInput.inputASBD.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        gRouteInput.inputASBD.mBitsPerChannel = 32;
        gRouteInput.inputASBD.mChannelsPerFrame = inputChannels;
        gRouteInput.inputASBD.mBytesPerFrame = 4;
        gRouteInput.inputASBD.mFramesPerPacket = 1;
        gRouteInput.inputASBD.mBytesPerPacket = 4;
        gRouteInput.inputASBD.mSampleRate = 48000.0;
    }

    gRouteInput.tapRingBuffer = RingBuffer_Create((size_t)bufferFrames * kPPRouteInputTapBufferMultiplier,
                                                  inputChannels);
    if (!gRouteInput.tapRingBuffer) {
        pp_route_input_clear_state();
        return -3;
    }

    gRouteInput.scratch = (float **)calloc(inputChannels, sizeof(float *));
    if (!gRouteInput.scratch) {
        pp_route_input_clear_state();
        return -4;
    }
    pp_route_prepare_realtime_memory(gRouteInput.scratch, inputChannels * sizeof(float *));

    for (UInt32 ch = 0; ch < inputChannels; ++ch) {
        gRouteInput.scratch[ch] = (float *)calloc(bufferFrames, sizeof(float));
        if (!gRouteInput.scratch[ch]) {
            pp_route_input_clear_state();
            return -5;
        }
        pp_route_prepare_realtime_memory(gRouteInput.scratch[ch], (size_t)bufferFrames * sizeof(float));
    }

    gRouteInput.interleavedScratch = (float *)calloc((size_t)bufferFrames * inputChannels, sizeof(float));
    if (!gRouteInput.interleavedScratch) {
        pp_route_input_clear_state();
        return -6;
    }
    pp_route_prepare_realtime_memory(gRouteInput.interleavedScratch,
                                     (size_t)bufferFrames * inputChannels * sizeof(float));

    gRouteInput.writer = PPVirtualLoopbackTransport_OpenWriterForSource(kPPVirtualLoopbackSourceInput);
    if (!gRouteInput.writer) {
        pp_route_input_clear_state();
        return -7;
    }

    if (PPVirtualLoopbackTransport_ConfigureWriter(gRouteInput.writer,
                                                   gRouteInput.inputASBD.mSampleRate,
                                                   inputChannels,
                                                   bufferFrames * kPPRouteInputTransportRingMultiplier,
                                                   bufferFrames) != 0) {
        pp_route_input_clear_state();
        return -8;
    }

    OSStatus ioErr = AudioDeviceCreateIOProcID(deviceID,
                                               (AudioDeviceIOProc)pp_route_input_io_proc,
                                               NULL,
                                               &gRouteInput.ioProcID);
    if (ioErr != noErr) {
        pp_route_input_clear_state();
        return -9;
    }

    atomic_store_explicit(&gRouteInput.isRunning, true, memory_order_release);
    ioErr = AudioDeviceStart(deviceID, gRouteInput.ioProcID);
    if (ioErr != noErr) {
        atomic_store_explicit(&gRouteInput.isRunning, false, memory_order_release);
        AudioDeviceDestroyIOProcID(deviceID, gRouteInput.ioProcID);
        pp_route_input_clear_state();
        return -10;
    }

    PPVirtualLoopbackTransport_SetLastError("");
    return 0;
}

void PPRouteInputEngine_Stop(void)
{
    bool wasRunning = atomic_load_explicit(&gRouteInput.isRunning, memory_order_acquire);
    atomic_store_explicit(&gRouteInput.isRunning, false, memory_order_release);

    if (wasRunning) {
        AudioDeviceStop(gRouteInput.deviceID, gRouteInput.ioProcID);
        AudioDeviceDestroyIOProcID(gRouteInput.deviceID, gRouteInput.ioProcID);
    }

    pp_route_input_clear_state();
}

bool PPRouteInputEngine_IsRunning(void)
{
    return atomic_load_explicit(&gRouteInput.isRunning, memory_order_acquire);
}

RingBuffer *PPRouteInputEngine_GetTapRingBuffer(void)
{
    return gRouteInput.tapRingBuffer;
}

uint32_t PPRouteInputEngine_GetTapChannelCount(void)
{
    return gRouteInput.inputChannels;
}

double PPRouteInputEngine_GetTapSampleRate(void)
{
    return gRouteInput.inputASBD.mSampleRate;
}

void PPRouteInputEngine_GetStatus(PPRouteInputEngineStatus *outStatus)
{
    if (!outStatus) {
        return;
    }

    memset(outStatus, 0, sizeof(*outStatus));
    outStatus->isRunning = atomic_load_explicit(&gRouteInput.isRunning, memory_order_acquire);
    outStatus->feedingTransport = gRouteInput.writer != NULL;
    outStatus->deviceID = gRouteInput.deviceID;
    outStatus->sampleRate = gRouteInput.inputASBD.mSampleRate;
    outStatus->channels = gRouteInput.inputChannels;
    outStatus->bufferFrames = gRouteInput.bufferFrames;
    outStatus->framesCaptured = atomic_load_explicit(&gRouteInput.framesCaptured, memory_order_relaxed);
}
