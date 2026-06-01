#include "PodcastPreviewLoopbackRouter.h"

#include <CoreAudio/HostTime.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "AudioEngine.h"
#include "PodcastPreviewLoopbackTransport.h"

enum {
    kPPLoopbackRouterTapBufferMultiplier = 64
};

typedef struct {
    float *samples;
    uint32_t channels;
    uint32_t capacityFrames;
    _Atomic uint64_t readFrameIndex;
    _Atomic uint64_t writeFrameIndex;
} PPLoopbackRouterOutputFIFO;

typedef struct {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    PPVirtualLoopbackReaderRef reader;
    RingBuffer *tapRingBuffer;
    PPLoopbackRouterOutputFIFO outputFIFO;
    PPLoopbackRouterOutputFIFO tapFIFO;
    float *interleavedScratch;
    float *workerScratch;
    float *analysisScratch;
    float **channelScratch;
    pthread_t workerThread;
    pthread_t analysisThread;
    semaphore_t workerWakeSemaphore;
    semaphore_t analysisWakeSemaphore;
    uint32_t channels;
    uint32_t actualBufferFrames;
    uint32_t scratchFrameCapacity;
    uint32_t outputFIFOTargetFrames;
    uint32_t outputFIFOLowWaterFrames;
    uint32_t originalDeviceBufferFrames;
    bool shouldRestoreDeviceBufferFrames;
    bool workerThreadCreated;
    bool analysisThreadCreated;
    bool workerWakeInitialized;
    bool analysisWakeInitialized;
    double sampleRate;
    AudioStreamBasicDescription outputASBD;
    _Atomic uint64_t framesRendered;
    _Atomic uint64_t underruns;
    _Atomic bool isRunning;
    _Atomic bool workerShouldStop;
    _Atomic bool analysisShouldStop;
    _Atomic bool workerWakePending;
    _Atomic bool analysisWakePending;
    _Atomic bool tapAnalysisEnabled;
    _Atomic bool outputTimelinePrimed;
    _Atomic uint64_t outputTimelineBaseHostTime;
    _Atomic uint64_t outputHostTicksPerFrameQ32;
    uint64_t lastOutputStartHostTime;
    uint32_t lastOutputFrameCount;
    double outputHostTicksPerFrame;
    char activeOutputDeviceUID[PP_LOOPBACK_DEVICE_UID_MAX];
    pthread_mutex_t lock;
} PPVirtualLoopbackRouterState;

static PPVirtualLoopbackRouterState gRouter = {
    .deviceID = kAudioObjectUnknown,
    .tapAnalysisEnabled = true,
    .lock = PTHREAD_MUTEX_INITIALIZER
};

static void pp_router_prepare_realtime_memory(void *memory, size_t byteCount);

static void pp_router_signal_worker(PPVirtualLoopbackRouterState *router)
{
    if (!router || !router->workerWakeInitialized) {
        return;
    }

    if (!atomic_exchange_explicit(&router->workerWakePending, true, memory_order_acq_rel)) {
        semaphore_signal(router->workerWakeSemaphore);
    }
}

static void pp_router_signal_analysis(PPVirtualLoopbackRouterState *router)
{
    if (!router || !router->analysisWakeInitialized) {
        return;
    }

    if (!atomic_exchange_explicit(&router->analysisWakePending, true, memory_order_acq_rel)) {
        semaphore_signal(router->analysisWakeSemaphore);
    }
}

static uint64_t pp_router_host_ticks_per_frame_to_q32(double hostTicksPerFrame)
{
    if (hostTicksPerFrame <= 0.0) {
        return 0;
    }
    return (uint64_t)llround(hostTicksPerFrame * 4294967296.0);
}

static double pp_router_q32_to_host_ticks_per_frame(uint64_t q32Value)
{
    if (q32Value == 0) {
        return 0.0;
    }
    return (double)q32Value / 4294967296.0;
}

static void pp_router_promote_current_thread_to_time_constraint(double periodHostTicks,
                                                                double computationFraction,
                                                                double constraintFraction)
{
    if (periodHostTicks <= 0.0) {
        return;
    }

    if (computationFraction <= 0.0) {
        computationFraction = 0.20;
    }
    if (constraintFraction <= computationFraction) {
        constraintFraction = computationFraction + 0.10;
    }
    if (constraintFraction > 0.95) {
        constraintFraction = 0.95;
    }

    double computationTicks = periodHostTicks * computationFraction;
    double constraintTicks = periodHostTicks * constraintFraction;
    if (computationTicks < 1.0) {
        computationTicks = 1.0;
    }
    if (constraintTicks < computationTicks + 1.0) {
        constraintTicks = computationTicks + 1.0;
    }

    if (periodHostTicks > (double)UINT32_MAX) {
        periodHostTicks = (double)UINT32_MAX;
    }
    if (computationTicks > (double)UINT32_MAX) {
        computationTicks = (double)UINT32_MAX;
    }
    if (constraintTicks > (double)UINT32_MAX) {
        constraintTicks = (double)UINT32_MAX;
    }

    thread_time_constraint_policy_data_t policy;
    policy.period = (uint32_t)llround(periodHostTicks);
    policy.computation = (uint32_t)llround(computationTicks);
    policy.constraint = (uint32_t)llround(constraintTicks);
    policy.preemptible = TRUE;

    thread_port_t threadPort = pthread_mach_thread_np(pthread_self());
    if (threadPort == MACH_PORT_NULL) {
        return;
    }

    (void)thread_policy_set(threadPort,
                            THREAD_TIME_CONSTRAINT_POLICY,
                            (thread_policy_t)&policy,
                            THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static uint32_t pp_router_output_fifo_frames_available_to_read(const PPLoopbackRouterOutputFIFO *fifo)
{
    if (!fifo || fifo->capacityFrames == 0) {
        return 0;
    }

    uint64_t writeFrameIndex = atomic_load_explicit(&fifo->writeFrameIndex, memory_order_acquire);
    uint64_t readFrameIndex = atomic_load_explicit(&fifo->readFrameIndex, memory_order_acquire);
    if (writeFrameIndex <= readFrameIndex) {
        return 0;
    }

    uint64_t availableFrames = writeFrameIndex - readFrameIndex;
    if (availableFrames > fifo->capacityFrames) {
        availableFrames = fifo->capacityFrames;
    }
    return (uint32_t)availableFrames;
}

static uint32_t pp_router_output_fifo_frames_available_to_write(const PPLoopbackRouterOutputFIFO *fifo)
{
    if (!fifo || fifo->capacityFrames == 0) {
        return 0;
    }

    uint32_t availableToRead = pp_router_output_fifo_frames_available_to_read(fifo);
    if (availableToRead >= fifo->capacityFrames) {
        return 0;
    }
    return fifo->capacityFrames - availableToRead;
}

static bool pp_router_output_fifo_allocate(PPLoopbackRouterOutputFIFO *fifo,
                                           uint32_t capacityFrames,
                                           uint32_t channels)
{
    if (!fifo || capacityFrames == 0 || channels == 0) {
        return false;
    }

    fifo->samples = (float *)calloc((size_t)capacityFrames * channels, sizeof(float));
    if (!fifo->samples) {
        return false;
    }

    fifo->channels = channels;
    fifo->capacityFrames = capacityFrames;
    atomic_store_explicit(&fifo->readFrameIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&fifo->writeFrameIndex, 0, memory_order_relaxed);
    pp_router_prepare_realtime_memory(fifo->samples,
                                      (size_t)capacityFrames * channels * sizeof(float));
    return true;
}

static void pp_router_output_fifo_destroy(PPLoopbackRouterOutputFIFO *fifo)
{
    if (!fifo) {
        return;
    }

    free(fifo->samples);
    memset(fifo, 0, sizeof(*fifo));
}

static uint32_t pp_router_output_fifo_write_interleaved(PPLoopbackRouterOutputFIFO *fifo,
                                                        const float *samples,
                                                        uint32_t frames)
{
    if (!fifo || !fifo->samples || !samples || frames == 0 || fifo->channels == 0 || fifo->capacityFrames == 0) {
        return 0;
    }

    uint64_t writeFrameIndex = atomic_load_explicit(&fifo->writeFrameIndex, memory_order_relaxed);
    uint64_t readFrameIndex = atomic_load_explicit(&fifo->readFrameIndex, memory_order_acquire);
    uint64_t inFlightFrames = writeFrameIndex > readFrameIndex ? (writeFrameIndex - readFrameIndex) : 0;
    if (inFlightFrames > fifo->capacityFrames) {
        inFlightFrames = fifo->capacityFrames;
    }

    uint32_t availableToWrite = fifo->capacityFrames - (uint32_t)inFlightFrames;
    if (frames > availableToWrite) {
        frames = availableToWrite;
    }
    if (frames == 0) {
        return 0;
    }

    uint32_t firstChunkFrames = frames;
    uint32_t startFrame = (uint32_t)(writeFrameIndex % fifo->capacityFrames);
    uint32_t framesUntilWrap = fifo->capacityFrames - startFrame;
    if (firstChunkFrames > framesUntilWrap) {
        firstChunkFrames = framesUntilWrap;
    }

    memcpy(fifo->samples + ((size_t)startFrame * fifo->channels),
           samples,
           (size_t)firstChunkFrames * fifo->channels * sizeof(float));

    uint32_t remainingFrames = frames - firstChunkFrames;
    if (remainingFrames > 0) {
        memcpy(fifo->samples,
               samples + ((size_t)firstChunkFrames * fifo->channels),
               (size_t)remainingFrames * fifo->channels * sizeof(float));
    }

    atomic_store_explicit(&fifo->writeFrameIndex,
                          writeFrameIndex + frames,
                          memory_order_release);
    return frames;
}

static uint32_t pp_router_output_fifo_write_interleaved_overwrite_oldest(PPLoopbackRouterOutputFIFO *fifo,
                                                                         const float *samples,
                                                                         uint32_t frames)
{
    if (!fifo || !fifo->samples || !samples || frames == 0 || fifo->channels == 0 || fifo->capacityFrames == 0) {
        return 0;
    }

    if (frames >= fifo->capacityFrames) {
        samples += ((size_t)(frames - fifo->capacityFrames) * fifo->channels);
        frames = fifo->capacityFrames;
    }

    uint64_t writeFrameIndex = atomic_load_explicit(&fifo->writeFrameIndex, memory_order_relaxed);
    uint64_t readFrameIndex = atomic_load_explicit(&fifo->readFrameIndex, memory_order_acquire);
    uint64_t inFlightFrames = writeFrameIndex > readFrameIndex ? (writeFrameIndex - readFrameIndex) : 0;
    if (inFlightFrames > fifo->capacityFrames) {
        inFlightFrames = fifo->capacityFrames;
    }

    if (inFlightFrames + frames > fifo->capacityFrames) {
        uint64_t framesToDrop = (inFlightFrames + frames) - fifo->capacityFrames;
        atomic_store_explicit(&fifo->readFrameIndex,
                              readFrameIndex + framesToDrop,
                              memory_order_release);
    }

    return pp_router_output_fifo_write_interleaved(fifo, samples, frames);
}

static uint32_t pp_router_output_fifo_read_interleaved(PPLoopbackRouterOutputFIFO *fifo,
                                                       float *outSamples,
                                                       uint32_t frames)
{
    if (!fifo || !fifo->samples || !outSamples || frames == 0 || fifo->channels == 0 || fifo->capacityFrames == 0) {
        return 0;
    }

    uint64_t writeFrameIndex = atomic_load_explicit(&fifo->writeFrameIndex, memory_order_acquire);
    uint64_t readFrameIndex = atomic_load_explicit(&fifo->readFrameIndex, memory_order_relaxed);
    uint64_t availableFrames = writeFrameIndex > readFrameIndex ? (writeFrameIndex - readFrameIndex) : 0;
    if (availableFrames > fifo->capacityFrames) {
        availableFrames = fifo->capacityFrames;
    }
    if (frames > availableFrames) {
        frames = (uint32_t)availableFrames;
    }
    if (frames == 0) {
        return 0;
    }

    uint32_t firstChunkFrames = frames;
    uint32_t startFrame = (uint32_t)(readFrameIndex % fifo->capacityFrames);
    uint32_t framesUntilWrap = fifo->capacityFrames - startFrame;
    if (firstChunkFrames > framesUntilWrap) {
        firstChunkFrames = framesUntilWrap;
    }

    memcpy(outSamples,
           fifo->samples + ((size_t)startFrame * fifo->channels),
           (size_t)firstChunkFrames * fifo->channels * sizeof(float));

    uint32_t remainingFrames = frames - firstChunkFrames;
    if (remainingFrames > 0) {
        memcpy(outSamples + ((size_t)firstChunkFrames * fifo->channels),
               fifo->samples,
               (size_t)remainingFrames * fifo->channels * sizeof(float));
    }

    atomic_store_explicit(&fifo->readFrameIndex,
                          readFrameIndex + frames,
                          memory_order_release);
    return frames;
}

static uint64_t pp_router_host_time_advanced_by_frames(uint64_t startHostTime,
                                                       double hostTicksPerFrame,
                                                       uint32_t frames)
{
    if (startHostTime == 0 || hostTicksPerFrame <= 0.0 || frames == 0) {
        return startHostTime;
    }
    return startHostTime + (uint64_t)llround(hostTicksPerFrame * (double)frames);
}

static void pp_router_prepare_realtime_memory(void *memory, size_t byteCount)
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

static bool pp_router_query_device_property(AudioDeviceID deviceID,
                                            AudioObjectPropertySelector selector,
                                            AudioObjectPropertyScope scope,
                                            void *outData,
                                            UInt32 *ioSize)
{
    if (deviceID == kAudioObjectUnknown || !outData || !ioSize) {
        return false;
    }

    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain
    };

    return AudioObjectGetPropertyData(deviceID, &address, 0, NULL, ioSize, outData) == noErr;
}

static bool pp_router_set_device_property(AudioDeviceID deviceID,
                                          AudioObjectPropertySelector selector,
                                          AudioObjectPropertyScope scope,
                                          const void *data,
                                          UInt32 dataSize)
{
    if (deviceID == kAudioObjectUnknown || !data || dataSize == 0) {
        return false;
    }

    AudioObjectPropertyAddress address = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain
    };

    return AudioObjectSetPropertyData(deviceID, &address, 0, NULL, dataSize, data) == noErr;
}

static bool pp_router_query_output_stream_format(AudioDeviceID deviceID,
                                                 AudioStreamBasicDescription *outASBD)
{
    UInt32 size = sizeof(AudioStreamBasicDescription);
    return pp_router_query_device_property(deviceID,
                                           kAudioDevicePropertyStreamFormat,
                                           kAudioDevicePropertyScopeOutput,
                                           outASBD,
                                           &size);
}

static bool pp_router_query_buffer_frame_size(AudioDeviceID deviceID, UInt32 *outFrames)
{
    UInt32 size = sizeof(UInt32);
    return pp_router_query_device_property(deviceID,
                                           kAudioDevicePropertyBufferFrameSize,
                                           kAudioObjectPropertyScopeGlobal,
                                           outFrames,
                                           &size);
}

static bool pp_router_query_buffer_frame_size_range(AudioDeviceID deviceID, AudioValueRange *outRange)
{
    UInt32 size = sizeof(AudioValueRange);
    return pp_router_query_device_property(deviceID,
                                           kAudioDevicePropertyBufferFrameSizeRange,
                                           kAudioObjectPropertyScopeGlobal,
                                           outRange,
                                           &size);
}

static uint32_t pp_router_clamp_buffer_frames(uint32_t requestedFrames, const AudioValueRange *range)
{
    if (!range) {
        return requestedFrames;
    }

    Float64 minimum = range->mMinimum > 0.0 ? range->mMinimum : 1.0;
    Float64 maximum = range->mMaximum >= minimum ? range->mMaximum : minimum;
    Float64 clamped = requestedFrames;
    if (clamped < minimum) {
        clamped = minimum;
    }
    if (clamped > maximum) {
        clamped = maximum;
    }
    return (uint32_t)clamped;
}

static double pp_router_default_host_ticks_per_frame(double sampleRate)
{
    double hostFrequency = AudioGetHostClockFrequency();
    if (hostFrequency <= 0.0 || sampleRate <= 0.0) {
        return 0.0;
    }
    return hostFrequency / sampleRate;
}

static float pp_router_clamp_sample(float sample)
{
    if (sample > 1.0f) {
        return 1.0f;
    }
    if (sample < -1.0f) {
        return -1.0f;
    }
    return sample;
}

static int16_t pp_router_float_to_int16(float sample)
{
    float clamped = pp_router_clamp_sample(sample);
    return (int16_t)(clamped * 32767.0f);
}

static int32_t pp_router_float_to_int32(float sample)
{
    float clamped = pp_router_clamp_sample(sample);
    return (int32_t)(clamped * 2147483647.0f);
}

static uint32_t pp_router_frames_requested(const PPVirtualLoopbackRouterState *router,
                                           const AudioBufferList *bufferList)
{
    if (!router || !bufferList || bufferList->mNumberBuffers == 0) {
        return router ? router->actualBufferFrames : 0;
    }

    UInt32 bytesPerSample = router->outputASBD.mBitsPerChannel / 8;
    if (bytesPerSample == 0) {
        return router->actualBufferFrames;
    }

    bool isNonInterleaved = (router->outputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 framesRequested = UINT32_MAX;

    for (UInt32 index = 0; index < bufferList->mNumberBuffers; ++index) {
        const AudioBuffer *buffer = &bufferList->mBuffers[index];
        UInt32 bufferChannels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
        UInt32 divisor = bytesPerSample * ((isNonInterleaved && bufferChannels == 1) ? 1U : bufferChannels);
        if (divisor == 0) {
            continue;
        }
        UInt32 bufferFrames = buffer->mDataByteSize / divisor;
        if (framesRequested == UINT32_MAX || bufferFrames < framesRequested) {
            framesRequested = bufferFrames;
        }
    }

    if (framesRequested == UINT32_MAX || framesRequested == 0) {
        return router->actualBufferFrames;
    }
    return framesRequested;
}

static void pp_router_zero_output(AudioBufferList *outOutputData)
{
    if (!outOutputData) {
        return;
    }

    for (UInt32 index = 0; index < outOutputData->mNumberBuffers; ++index) {
        AudioBuffer *buffer = &outOutputData->mBuffers[index];
        if (buffer->mData && buffer->mDataByteSize > 0) {
            memset(buffer->mData, 0, buffer->mDataByteSize);
        }
    }
}

static bool pp_router_can_memcpy_float_output(const PPVirtualLoopbackRouterState *router,
                                              const AudioBufferList *outOutputData)
{
    if (!router || !outOutputData || outOutputData->mNumberBuffers != 1) {
        return false;
    }

    if (router->outputASBD.mFormatID != kAudioFormatLinearPCM ||
        (router->outputASBD.mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
        router->outputASBD.mBitsPerChannel != 32 ||
        (router->outputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) {
        return false;
    }

    const AudioBuffer *buffer = &outOutputData->mBuffers[0];
    return buffer->mData != NULL &&
        buffer->mNumberChannels == router->channels;
}

static void pp_router_write_float_output(const PPVirtualLoopbackRouterState *router,
                                         AudioBufferList *outOutputData,
                                         uint32_t framesRequested)
{
    if (pp_router_can_memcpy_float_output(router, outOutputData)) {
        memcpy(outOutputData->mBuffers[0].mData,
               router->interleavedScratch,
               (size_t)framesRequested * router->channels * sizeof(float));
        return;
    }

    UInt32 globalChannel = 0;
    bool isNonInterleaved = (router->outputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

    for (UInt32 bufferIndex = 0; bufferIndex < outOutputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outOutputData->mBuffers[bufferIndex];
        if (!buffer->mData) {
            globalChannel += buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
            continue;
        }

        float *dest = (float *)buffer->mData;
        UInt32 bufferChannels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
        size_t frameStride = (isNonInterleaved && bufferChannels == 1) ? 1u : (size_t)bufferChannels;

        for (UInt32 frame = 0; frame < framesRequested; ++frame) {
            size_t sourceBase = (size_t)frame * router->channels;
            for (UInt32 channel = 0; channel < bufferChannels; ++channel) {
                UInt32 sourceChannel = globalChannel + channel;
                dest[(size_t)frame * frameStride + channel] =
                    (sourceChannel < router->channels)
                        ? router->interleavedScratch[sourceBase + sourceChannel]
                        : 0.0f;
            }
        }

        globalChannel += bufferChannels;
    }
}

static void pp_router_write_int16_output(const PPVirtualLoopbackRouterState *router,
                                         AudioBufferList *outOutputData,
                                         uint32_t framesRequested)
{
    UInt32 globalChannel = 0;
    bool isNonInterleaved = (router->outputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

    for (UInt32 bufferIndex = 0; bufferIndex < outOutputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outOutputData->mBuffers[bufferIndex];
        if (!buffer->mData) {
            globalChannel += buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
            continue;
        }

        int16_t *dest = (int16_t *)buffer->mData;
        UInt32 bufferChannels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
        size_t frameStride = (isNonInterleaved && bufferChannels == 1) ? 1u : (size_t)bufferChannels;

        for (UInt32 frame = 0; frame < framesRequested; ++frame) {
            size_t sourceBase = (size_t)frame * router->channels;
            for (UInt32 channel = 0; channel < bufferChannels; ++channel) {
                UInt32 sourceChannel = globalChannel + channel;
                float sample = (sourceChannel < router->channels)
                    ? router->interleavedScratch[sourceBase + sourceChannel]
                    : 0.0f;
                dest[(size_t)frame * frameStride + channel] = pp_router_float_to_int16(sample);
            }
        }

        globalChannel += bufferChannels;
    }
}

static void pp_router_write_int32_output(const PPVirtualLoopbackRouterState *router,
                                         AudioBufferList *outOutputData,
                                         uint32_t framesRequested)
{
    UInt32 globalChannel = 0;
    bool isNonInterleaved = (router->outputASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;

    for (UInt32 bufferIndex = 0; bufferIndex < outOutputData->mNumberBuffers; ++bufferIndex) {
        AudioBuffer *buffer = &outOutputData->mBuffers[bufferIndex];
        if (!buffer->mData) {
            globalChannel += buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
            continue;
        }

        int32_t *dest = (int32_t *)buffer->mData;
        UInt32 bufferChannels = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
        size_t frameStride = (isNonInterleaved && bufferChannels == 1) ? 1u : (size_t)bufferChannels;

        for (UInt32 frame = 0; frame < framesRequested; ++frame) {
            size_t sourceBase = (size_t)frame * router->channels;
            for (UInt32 channel = 0; channel < bufferChannels; ++channel) {
                UInt32 sourceChannel = globalChannel + channel;
                float sample = (sourceChannel < router->channels)
                    ? router->interleavedScratch[sourceBase + sourceChannel]
                    : 0.0f;
                dest[(size_t)frame * frameStride + channel] = pp_router_float_to_int32(sample);
            }
        }

        globalChannel += bufferChannels;
    }
}

static void pp_router_push_tap_frames(PPVirtualLoopbackRouterState *router,
                                      const float *interleavedSamples,
                                      uint32_t framesRequested)
{
    if (!router || !router->tapRingBuffer || !router->channelScratch || !interleavedSamples) {
        return;
    }

    for (uint32_t channel = 0; channel < router->channels; ++channel) {
        float *scratch = router->channelScratch[channel];
        if (!scratch) {
            continue;
        }

        if (router->channels == 1) {
            memcpy(scratch, interleavedSamples, (size_t)framesRequested * sizeof(float));
        } else {
            for (uint32_t frame = 0; frame < framesRequested; ++frame) {
                scratch[frame] = interleavedSamples[(size_t)frame * router->channels + channel];
            }
        }

        RingBuffer_Write(router->tapRingBuffer,
                         scratch,
                         (size_t)framesRequested * sizeof(float),
                         channel);
    }
}

static void *pp_router_worker_main(void *context)
{
    PPVirtualLoopbackRouterState *router = (PPVirtualLoopbackRouterState *)context;
    if (!router) {
        return NULL;
    }

    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    pp_router_promote_current_thread_to_time_constraint(router->outputHostTicksPerFrame *
                                                            (double)(router->actualBufferFrames > 0
                                                                         ? router->actualBufferFrames
                                                                         : 512u),
                                                        0.25,
                                                        0.90);

    while (!atomic_load_explicit(&router->workerShouldStop, memory_order_acquire)) {
        if (router->workerWakeInitialized) {
            while (!atomic_exchange_explicit(&router->workerWakePending, false, memory_order_acq_rel) &&
                   !atomic_load_explicit(&router->workerShouldStop, memory_order_acquire)) {
                kern_return_t waitStatus = semaphore_wait(router->workerWakeSemaphore);
                if (waitStatus != KERN_SUCCESS &&
                    waitStatus != KERN_ABORTED) {
                    break;
                }
            }
        }

        if (atomic_load_explicit(&router->workerShouldStop, memory_order_acquire)) {
            break;
        }

        if (!atomic_load_explicit(&router->isRunning, memory_order_acquire) ||
            !router->reader ||
            !router->workerScratch) {
            continue;
        }

        if (!atomic_load_explicit(&router->outputTimelinePrimed, memory_order_acquire)) {
            continue;
        }

        while (!atomic_load_explicit(&router->workerShouldStop, memory_order_acquire)) {
            uint32_t fifoFramesAvailable = pp_router_output_fifo_frames_available_to_read(&router->outputFIFO);
            if (fifoFramesAvailable >= router->outputFIFOTargetFrames) {
                break;
            }

            uint32_t fifoFramesWritable = pp_router_output_fifo_frames_available_to_write(&router->outputFIFO);
            if (fifoFramesWritable == 0) {
                break;
            }

            double outputHostTicksPerFrame = pp_router_q32_to_host_ticks_per_frame(
                atomic_load_explicit(&router->outputHostTicksPerFrameQ32, memory_order_acquire));
            uint64_t outputTimelineBaseHostTime = atomic_load_explicit(&router->outputTimelineBaseHostTime,
                                                                       memory_order_acquire);
            if (outputTimelineBaseHostTime == 0 || outputHostTicksPerFrame <= 0.0) {
                break;
            }

            uint32_t framesToRender = router->scratchFrameCapacity;
            if (framesToRender > fifoFramesWritable) {
                framesToRender = fifoFramesWritable;
            }
            if (framesToRender == 0) {
                break;
            }

            uint64_t renderStartHostTime = outputTimelineBaseHostTime +
                (uint64_t)llround(outputHostTicksPerFrame * (double)fifoFramesAvailable);
            size_t framesRendered = PPVirtualLoopbackTransport_ReadInterleavedWithTiming(router->reader,
                                                                                         router->workerScratch,
                                                                                         framesToRender,
                                                                                         router->channels,
                                                                                         renderStartHostTime,
                                                                                         outputHostTicksPerFrame,
                                                                                         router->sampleRate);
            if (framesRendered == 0) {
                break;
            }

            pp_router_output_fifo_write_interleaved(&router->outputFIFO,
                                                    router->workerScratch,
                                                    (uint32_t)framesRendered);
            if (atomic_load_explicit(&router->tapAnalysisEnabled, memory_order_acquire)) {
                pp_router_output_fifo_write_interleaved_overwrite_oldest(&router->tapFIFO,
                                                                         router->workerScratch,
                                                                         (uint32_t)framesRendered);
                pp_router_signal_analysis(router);
            }
        }
    }

    return NULL;
}

static void *pp_router_analysis_main(void *context)
{
    PPVirtualLoopbackRouterState *router = (PPVirtualLoopbackRouterState *)context;
    if (!router) {
        return NULL;
    }

    pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);

    while (!atomic_load_explicit(&router->analysisShouldStop, memory_order_acquire)) {
        if (router->analysisWakeInitialized) {
            while (!atomic_exchange_explicit(&router->analysisWakePending, false, memory_order_acq_rel) &&
                   !atomic_load_explicit(&router->analysisShouldStop, memory_order_acquire)) {
                kern_return_t waitStatus = semaphore_wait(router->analysisWakeSemaphore);
                if (waitStatus != KERN_SUCCESS &&
                    waitStatus != KERN_ABORTED) {
                    break;
                }
            }
        }

        if (atomic_load_explicit(&router->analysisShouldStop, memory_order_acquire)) {
            break;
        }

        if (!atomic_load_explicit(&router->tapAnalysisEnabled, memory_order_acquire)) {
            continue;
        }

        while (!atomic_load_explicit(&router->analysisShouldStop, memory_order_acquire)) {
            if (!atomic_load_explicit(&router->tapAnalysisEnabled, memory_order_acquire)) {
                break;
            }
            uint32_t framesAvailable = pp_router_output_fifo_frames_available_to_read(&router->tapFIFO);
            if (framesAvailable == 0) {
                break;
            }

            uint32_t framesToDrain = router->scratchFrameCapacity;
            if (framesToDrain > framesAvailable) {
                framesToDrain = framesAvailable;
            }
            if (framesToDrain == 0 || !router->analysisScratch) {
                break;
            }

            uint32_t framesRead = pp_router_output_fifo_read_interleaved(&router->tapFIFO,
                                                                         router->analysisScratch,
                                                                         framesToDrain);
            if (framesRead == 0) {
                break;
            }

            pp_router_push_tap_frames(router, router->analysisScratch, framesRead);
        }
    }

    return NULL;
}

static OSStatus pp_router_output_io_proc(AudioObjectID inDevice,
                                         const AudioTimeStamp *inNow,
                                         const AudioBufferList *inInputData,
                                         const AudioTimeStamp *inInputTime,
                                         AudioBufferList *outOutputData,
                                         const AudioTimeStamp *inOutputTime,
                                         void *inClientData)
{
    (void)inDevice;
    (void)inNow;
    (void)inInputData;
    (void)inInputTime;
    (void)inOutputTime;

    PPVirtualLoopbackRouterState *router = (PPVirtualLoopbackRouterState *)inClientData;
    if (!router || !outOutputData) {
        return noErr;
    }

    if (!atomic_load_explicit(&router->isRunning, memory_order_acquire) ||
        !router->reader ||
        !router->interleavedScratch) {
        pp_router_zero_output(outOutputData);
        return noErr;
    }

    uint32_t framesRequested = pp_router_frames_requested(router, outOutputData);
    if (framesRequested == 0 || framesRequested > router->scratchFrameCapacity) {
        atomic_fetch_add_explicit(&router->underruns, framesRequested, memory_order_relaxed);
        pp_router_zero_output(outOutputData);
        return noErr;
    }

    uint64_t outputStartHostTime = 0;
    if (inOutputTime && (inOutputTime->mFlags & kAudioTimeStampHostTimeValid) != 0) {
        outputStartHostTime = inOutputTime->mHostTime;
    } else if (inNow && (inNow->mFlags & kAudioTimeStampHostTimeValid) != 0) {
        outputStartHostTime = inNow->mHostTime;
    } else {
        outputStartHostTime = AudioGetCurrentHostTime();
    }

    double outputHostTicksPerFrame = router->outputHostTicksPerFrame > 0.0
        ? router->outputHostTicksPerFrame
        : pp_router_default_host_ticks_per_frame(router->sampleRate);
    if (router->lastOutputStartHostTime > 0 &&
        outputStartHostTime > router->lastOutputStartHostTime &&
        router->lastOutputFrameCount > 0) {
        double observedOutputHostTicksPerFrame =
            (double)(outputStartHostTime - router->lastOutputStartHostTime) /
            (double)router->lastOutputFrameCount;
        if (observedOutputHostTicksPerFrame > 0.0) {
            outputHostTicksPerFrame = outputHostTicksPerFrame > 0.0
                ? ((outputHostTicksPerFrame * 0.8) + (observedOutputHostTicksPerFrame * 0.2))
                : observedOutputHostTicksPerFrame;
        }
    }
    if (outputHostTicksPerFrame <= 0.0) {
        outputHostTicksPerFrame = 1.0;
    }
    router->lastOutputStartHostTime = outputStartHostTime;
    router->lastOutputFrameCount = framesRequested;
    router->outputHostTicksPerFrame = outputHostTicksPerFrame;
    atomic_store_explicit(&router->outputHostTicksPerFrameQ32,
                          pp_router_host_ticks_per_frame_to_q32(outputHostTicksPerFrame),
                          memory_order_release);

    size_t framesRead = 0;
    bool outputTimelinePrimed = atomic_load_explicit(&router->outputTimelinePrimed, memory_order_acquire);
    if (!outputTimelinePrimed) {
        framesRead = PPVirtualLoopbackTransport_ReadInterleavedWithTiming(router->reader,
                                                                          router->interleavedScratch,
                                                                          framesRequested,
                                                                          router->channels,
                                                                          outputStartHostTime,
                                                                          outputHostTicksPerFrame,
                                                                          router->sampleRate);
        if (framesRead == 0) {
            atomic_fetch_add_explicit(&router->underruns, framesRequested, memory_order_relaxed);
            pp_router_zero_output(outOutputData);
            return noErr;
        }

        atomic_store_explicit(&router->outputTimelineBaseHostTime,
                              pp_router_host_time_advanced_by_frames(outputStartHostTime,
                                                                     outputHostTicksPerFrame,
                                                                     framesRequested),
                              memory_order_release);
        atomic_store_explicit(&router->outputTimelinePrimed, true, memory_order_release);
        pp_router_signal_worker(router);
    } else {
        framesRead = pp_router_output_fifo_read_interleaved(&router->outputFIFO,
                                                            router->interleavedScratch,
                                                            framesRequested);
        if (framesRead < framesRequested) {
            size_t offset = framesRead * router->channels;
            size_t remainingSamples = ((size_t)framesRequested - framesRead) * router->channels;
            memset(router->interleavedScratch + offset, 0, remainingSamples * sizeof(float));
            atomic_fetch_add_explicit(&router->underruns,
                                      (uint64_t)(framesRequested - framesRead),
                                      memory_order_relaxed);
        }

        atomic_store_explicit(&router->outputTimelineBaseHostTime,
                              pp_router_host_time_advanced_by_frames(outputStartHostTime,
                                                                     outputHostTicksPerFrame,
                                                                     framesRequested),
                              memory_order_release);
        if (pp_router_output_fifo_frames_available_to_read(&router->outputFIFO) <= router->outputFIFOLowWaterFrames) {
            pp_router_signal_worker(router);
        }
    }

    if (router->outputASBD.mFormatID == kAudioFormatLinearPCM &&
        (router->outputASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        router->outputASBD.mBitsPerChannel == 32) {
        pp_router_write_float_output(router, outOutputData, framesRequested);
    } else if (router->outputASBD.mFormatID == kAudioFormatLinearPCM &&
               (router->outputASBD.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
               router->outputASBD.mBitsPerChannel == 16) {
        pp_router_write_int16_output(router, outOutputData, framesRequested);
    } else if (router->outputASBD.mFormatID == kAudioFormatLinearPCM &&
               (router->outputASBD.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
               router->outputASBD.mBitsPerChannel == 32) {
        pp_router_write_int32_output(router, outOutputData, framesRequested);
    } else {
        pp_router_zero_output(outOutputData);
        atomic_fetch_add_explicit(&router->underruns, framesRequested, memory_order_relaxed);
        return noErr;
    }

    atomic_fetch_add_explicit(&router->framesRendered, framesRequested, memory_order_relaxed);
    return noErr;
}

static int pp_router_allocate_buffers_locked(void)
{
    gRouter.outputFIFOTargetFrames = gRouter.scratchFrameCapacity * 8u;
    if (gRouter.outputFIFOTargetFrames < 4096u) {
        gRouter.outputFIFOTargetFrames = 4096u;
    }
    gRouter.outputFIFOLowWaterFrames = gRouter.outputFIFOTargetFrames - (gRouter.outputFIFOTargetFrames / 4u);
    uint32_t minimumLowWaterFrames = gRouter.scratchFrameCapacity * 2u;
    if (gRouter.outputFIFOLowWaterFrames < minimumLowWaterFrames) {
        gRouter.outputFIFOLowWaterFrames = minimumLowWaterFrames;
    }
    if (gRouter.outputFIFOLowWaterFrames >= gRouter.outputFIFOTargetFrames) {
        gRouter.outputFIFOLowWaterFrames = gRouter.outputFIFOTargetFrames > gRouter.scratchFrameCapacity
            ? (gRouter.outputFIFOTargetFrames - gRouter.scratchFrameCapacity)
            : gRouter.scratchFrameCapacity;
    }

    uint32_t outputFIFOCapacityFrames = gRouter.outputFIFOTargetFrames * 4u;
    if (outputFIFOCapacityFrames < gRouter.scratchFrameCapacity * 4u) {
        outputFIFOCapacityFrames = gRouter.scratchFrameCapacity * 4u;
    }
    if (outputFIFOCapacityFrames > 65536u) {
        outputFIFOCapacityFrames = 65536u;
    }

    if (!pp_router_output_fifo_allocate(&gRouter.outputFIFO,
                                        outputFIFOCapacityFrames,
                                        gRouter.channels)) {
        return -1;
    }

    if (!pp_router_output_fifo_allocate(&gRouter.tapFIFO,
                                        outputFIFOCapacityFrames,
                                        gRouter.channels)) {
        return -1;
    }

    gRouter.tapRingBuffer = RingBuffer_Create((size_t)gRouter.scratchFrameCapacity * kPPLoopbackRouterTapBufferMultiplier,
                                              gRouter.channels);
    if (!gRouter.tapRingBuffer) {
        return -2;
    }

    gRouter.interleavedScratch = (float *)calloc((size_t)gRouter.scratchFrameCapacity * gRouter.channels,
                                                 sizeof(float));
    if (!gRouter.interleavedScratch) {
        return -3;
    }
    pp_router_prepare_realtime_memory(gRouter.interleavedScratch,
                                      (size_t)gRouter.scratchFrameCapacity * gRouter.channels * sizeof(float));

    gRouter.workerScratch = (float *)calloc((size_t)gRouter.scratchFrameCapacity * gRouter.channels,
                                            sizeof(float));
    if (!gRouter.workerScratch) {
        return -4;
    }
    pp_router_prepare_realtime_memory(gRouter.workerScratch,
                                      (size_t)gRouter.scratchFrameCapacity * gRouter.channels * sizeof(float));

    gRouter.analysisScratch = (float *)calloc((size_t)gRouter.scratchFrameCapacity * gRouter.channels,
                                              sizeof(float));
    if (!gRouter.analysisScratch) {
        return -4;
    }
    pp_router_prepare_realtime_memory(gRouter.analysisScratch,
                                      (size_t)gRouter.scratchFrameCapacity * gRouter.channels * sizeof(float));

    gRouter.channelScratch = (float **)calloc(gRouter.channels, sizeof(float *));
    if (!gRouter.channelScratch) {
        return -5;
    }
    pp_router_prepare_realtime_memory(gRouter.channelScratch, gRouter.channels * sizeof(float *));

    for (uint32_t channel = 0; channel < gRouter.channels; ++channel) {
        gRouter.channelScratch[channel] = (float *)calloc(gRouter.scratchFrameCapacity, sizeof(float));
        if (!gRouter.channelScratch[channel]) {
            return -6;
        }
        pp_router_prepare_realtime_memory(gRouter.channelScratch[channel],
                                          (size_t)gRouter.scratchFrameCapacity * sizeof(float));
    }

    return 0;
}

static void pp_router_restore_device_buffer_frames_locked(void)
{
    if (gRouter.deviceID == kAudioObjectUnknown ||
        !gRouter.shouldRestoreDeviceBufferFrames ||
        gRouter.originalDeviceBufferFrames == 0) {
        return;
    }

    pp_router_set_device_property(gRouter.deviceID,
                                  kAudioDevicePropertyBufferFrameSize,
                                  kAudioObjectPropertyScopeGlobal,
                                  &gRouter.originalDeviceBufferFrames,
                                  sizeof(gRouter.originalDeviceBufferFrames));
    gRouter.shouldRestoreDeviceBufferFrames = false;
    gRouter.originalDeviceBufferFrames = 0;
}

static void pp_router_clear_state_locked(void)
{
    atomic_store_explicit(&gRouter.isRunning, false, memory_order_release);
    atomic_store_explicit(&gRouter.workerShouldStop, true, memory_order_release);
    atomic_store_explicit(&gRouter.analysisShouldStop, true, memory_order_release);
    pp_router_signal_worker(&gRouter);
    pp_router_signal_analysis(&gRouter);

    if (gRouter.deviceID != kAudioObjectUnknown && gRouter.ioProcID != NULL) {
        AudioDeviceStop(gRouter.deviceID, gRouter.ioProcID);
        AudioDeviceDestroyIOProcID(gRouter.deviceID, gRouter.ioProcID);
        gRouter.ioProcID = NULL;
    }

    if (gRouter.workerThreadCreated) {
        pthread_join(gRouter.workerThread, NULL);
        gRouter.workerThreadCreated = false;
    }

    if (gRouter.analysisThreadCreated) {
        pthread_join(gRouter.analysisThread, NULL);
        gRouter.analysisThreadCreated = false;
    }

    if (gRouter.workerWakeInitialized) {
        semaphore_destroy(mach_task_self(), gRouter.workerWakeSemaphore);
        gRouter.workerWakeInitialized = false;
    }

    if (gRouter.analysisWakeInitialized) {
        semaphore_destroy(mach_task_self(), gRouter.analysisWakeSemaphore);
        gRouter.analysisWakeInitialized = false;
    }

    pp_router_restore_device_buffer_frames_locked();

    if (gRouter.reader) {
        PPVirtualLoopbackTransport_CloseReader(gRouter.reader);
        gRouter.reader = NULL;
    }

    if (gRouter.tapRingBuffer) {
        RingBuffer_Destroy(gRouter.tapRingBuffer);
        gRouter.tapRingBuffer = NULL;
    }

    pp_router_output_fifo_destroy(&gRouter.outputFIFO);
    pp_router_output_fifo_destroy(&gRouter.tapFIFO);

    if (gRouter.channelScratch) {
        for (uint32_t channel = 0; channel < gRouter.channels; ++channel) {
            free(gRouter.channelScratch[channel]);
        }
        free(gRouter.channelScratch);
        gRouter.channelScratch = NULL;
    }

    free(gRouter.interleavedScratch);
    gRouter.interleavedScratch = NULL;
    free(gRouter.workerScratch);
    gRouter.workerScratch = NULL;
    free(gRouter.analysisScratch);
    gRouter.analysisScratch = NULL;

    memset(gRouter.activeOutputDeviceUID, 0, sizeof(gRouter.activeOutputDeviceUID));
    memset(&gRouter.outputASBD, 0, sizeof(gRouter.outputASBD));
    gRouter.deviceID = kAudioObjectUnknown;
    gRouter.channels = 0;
    gRouter.actualBufferFrames = 0;
    gRouter.scratchFrameCapacity = 0;
    gRouter.outputFIFOTargetFrames = 0;
    gRouter.outputFIFOLowWaterFrames = 0;
    gRouter.sampleRate = 0.0;
    gRouter.lastOutputStartHostTime = 0;
    gRouter.lastOutputFrameCount = 0;
    gRouter.outputHostTicksPerFrame = 0.0;
    atomic_store_explicit(&gRouter.outputTimelinePrimed, false, memory_order_relaxed);
    atomic_store_explicit(&gRouter.outputTimelineBaseHostTime, 0, memory_order_relaxed);
    atomic_store_explicit(&gRouter.outputHostTicksPerFrameQ32, 0, memory_order_relaxed);
    atomic_store_explicit(&gRouter.framesRendered, 0, memory_order_relaxed);
    atomic_store_explicit(&gRouter.underruns, 0, memory_order_relaxed);
    atomic_store_explicit(&gRouter.analysisWakePending, false, memory_order_relaxed);
    PPVirtualLoopbackTransport_SetRouterState(false, "");
}

int PPVirtualLoopbackRouter_Start(const char *outputDeviceUID, uint32_t preferredBufferFrames)
{
    pthread_mutex_lock(&gRouter.lock);

    pp_router_clear_state_locked();

    gRouter.reader = PPVirtualLoopbackTransport_OpenReader();
    if (!gRouter.reader) {
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to open loopback transport reader.");
        return -1;
    }

    PPVirtualLoopbackStreamDescription description;
    if (PPVirtualLoopbackTransport_GetStreamDescription(gRouter.reader, &description) != 0) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to fetch loopback transport format.");
        return -2;
    }

    gRouter.channels = description.channels > 0 ? description.channels : 2;
    if (gRouter.channels > PP_LOOPBACK_MAX_CHANNELS) {
        gRouter.channels = PP_LOOPBACK_MAX_CHANNELS;
    }
    double transportSampleRate = description.sampleRate > 0.0 ? description.sampleRate : 48000.0;
    gRouter.sampleRate = transportSampleRate;
    gRouter.outputHostTicksPerFrame = pp_router_default_host_ticks_per_frame(gRouter.sampleRate);

    gRouter.deviceID = (outputDeviceUID && outputDeviceUID[0] != '\0')
        ? AudioDevices_FindDeviceByUID(outputDeviceUID)
        : AudioDevices_GetDefaultOutputDevice();
    if (gRouter.deviceID == kAudioObjectUnknown) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to resolve downstream output device.");
        return -3;
    }

    if (AudioDevices_GetDeviceUID(gRouter.deviceID,
                                  gRouter.activeOutputDeviceUID,
                                  sizeof(gRouter.activeOutputDeviceUID)) != noErr) {
        snprintf(gRouter.activeOutputDeviceUID,
                 sizeof(gRouter.activeOutputDeviceUID),
                 "%s",
                 outputDeviceUID ? outputDeviceUID : "");
    }

    UInt32 currentBufferFrames = 0;
    if (!pp_router_query_buffer_frame_size(gRouter.deviceID, &currentBufferFrames) || currentBufferFrames == 0) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to query downstream device buffer size.");
        return -4;
    }

    AudioValueRange bufferFrameRange = { 0 };
    if (pp_router_query_buffer_frame_size_range(gRouter.deviceID, &bufferFrameRange) && preferredBufferFrames > 0) {
        UInt32 desiredBufferFrames = pp_router_clamp_buffer_frames(preferredBufferFrames, &bufferFrameRange);
        if (desiredBufferFrames > 0 && desiredBufferFrames != currentBufferFrames) {
            if (pp_router_set_device_property(gRouter.deviceID,
                                              kAudioDevicePropertyBufferFrameSize,
                                              kAudioObjectPropertyScopeGlobal,
                                              &desiredBufferFrames,
                                              sizeof(desiredBufferFrames))) {
                gRouter.originalDeviceBufferFrames = currentBufferFrames;
                gRouter.shouldRestoreDeviceBufferFrames = true;
                currentBufferFrames = desiredBufferFrames;
            }
        }
    }

    if (!pp_router_query_buffer_frame_size(gRouter.deviceID, &gRouter.actualBufferFrames) ||
        gRouter.actualBufferFrames == 0) {
        gRouter.actualBufferFrames = currentBufferFrames;
    }

    if (!pp_router_query_output_stream_format(gRouter.deviceID, &gRouter.outputASBD)) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to query downstream output format.");
        return -5;
    }

    if (gRouter.outputASBD.mSampleRate > 0.0) {
        gRouter.sampleRate = gRouter.outputASBD.mSampleRate;
        gRouter.outputHostTicksPerFrame = pp_router_default_host_ticks_per_frame(gRouter.sampleRate);
    }

    if (gRouter.outputASBD.mFormatID != kAudioFormatLinearPCM ||
        !(((gRouter.outputASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
           gRouter.outputASBD.mBitsPerChannel == 32) ||
          ((gRouter.outputASBD.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 &&
           (gRouter.outputASBD.mBitsPerChannel == 16 || gRouter.outputASBD.mBitsPerChannel == 32)))) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Downstream output format is unsupported for direct IO routing.");
        return -6;
    }

    gRouter.scratchFrameCapacity = gRouter.actualBufferFrames > 0 ? gRouter.actualBufferFrames : 512;
    if (pp_router_allocate_buffers_locked() != 0) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to allocate loopback router buffers.");
        return -7;
    }

    atomic_store_explicit(&gRouter.workerShouldStop, false, memory_order_release);
    atomic_store_explicit(&gRouter.analysisShouldStop, false, memory_order_release);
    atomic_store_explicit(&gRouter.workerWakePending, false, memory_order_release);
    atomic_store_explicit(&gRouter.analysisWakePending, false, memory_order_release);
    atomic_store_explicit(&gRouter.outputTimelinePrimed, false, memory_order_release);
    atomic_store_explicit(&gRouter.outputTimelineBaseHostTime, 0, memory_order_release);
    atomic_store_explicit(&gRouter.outputHostTicksPerFrameQ32,
                          pp_router_host_ticks_per_frame_to_q32(gRouter.outputHostTicksPerFrame),
                          memory_order_release);

    if (semaphore_create(mach_task_self(), &gRouter.workerWakeSemaphore, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to initialize loopback worker semaphore.");
        return -8;
    }
    gRouter.workerWakeInitialized = true;

    if (semaphore_create(mach_task_self(), &gRouter.analysisWakeSemaphore, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to initialize loopback analysis semaphore.");
        return -8;
    }
    gRouter.analysisWakeInitialized = true;

    OSStatus status = AudioDeviceCreateIOProcID(gRouter.deviceID,
                                                (AudioDeviceIOProc)pp_router_output_io_proc,
                                                &gRouter,
                                                &gRouter.ioProcID);
    if (status != noErr) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to create downstream output IO callback.");
        return -9;
    }

    if (pthread_create(&gRouter.workerThread, NULL, pp_router_worker_main, &gRouter) != 0) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to start loopback render worker.");
        return -10;
    }
    gRouter.workerThreadCreated = true;

    if (pthread_create(&gRouter.analysisThread, NULL, pp_router_analysis_main, &gRouter) != 0) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to start loopback analysis worker.");
        return -10;
    }
    gRouter.analysisThreadCreated = true;

    pp_router_signal_worker(&gRouter);

    atomic_store_explicit(&gRouter.isRunning, true, memory_order_release);
    status = AudioDeviceStart(gRouter.deviceID, gRouter.ioProcID);
    if (status != noErr) {
        pp_router_clear_state_locked();
        pthread_mutex_unlock(&gRouter.lock);
        PPVirtualLoopbackTransport_SetLastError("Unable to start downstream output device.");
        return -11;
    }

    PPVirtualLoopbackTransport_SetRequestedOutputDeviceUID(outputDeviceUID);
    PPVirtualLoopbackTransport_SetRouterState(true, gRouter.activeOutputDeviceUID);
    PPVirtualLoopbackTransport_SetLastError("");
    pthread_mutex_unlock(&gRouter.lock);
    return 0;
}

void PPVirtualLoopbackRouter_Stop(void)
{
    pthread_mutex_lock(&gRouter.lock);
    pp_router_clear_state_locked();
    pthread_mutex_unlock(&gRouter.lock);
    PPVirtualLoopbackTransport_SetLastError("");
}

bool PPVirtualLoopbackRouter_IsRunning(void)
{
    return atomic_load_explicit(&gRouter.isRunning, memory_order_acquire);
}

RingBuffer *PPVirtualLoopbackRouter_GetTapRingBuffer(void)
{
    return gRouter.tapRingBuffer;
}

uint32_t PPVirtualLoopbackRouter_GetTapChannelCount(void)
{
    return gRouter.channels;
}

double PPVirtualLoopbackRouter_GetTapSampleRate(void)
{
    return gRouter.sampleRate;
}

void PPVirtualLoopbackRouter_SetTapAnalysisEnabled(bool enabled)
{
    atomic_store_explicit(&gRouter.tapAnalysisEnabled, enabled, memory_order_release);

    if (!enabled) {
        uint64_t writeFrameIndex = atomic_load_explicit(&gRouter.tapFIFO.writeFrameIndex, memory_order_acquire);
        atomic_store_explicit(&gRouter.tapFIFO.readFrameIndex, writeFrameIndex, memory_order_release);
    } else {
        pp_router_signal_analysis(&gRouter);
    }
}

bool PPVirtualLoopbackRouter_IsTapAnalysisEnabled(void)
{
    return atomic_load_explicit(&gRouter.tapAnalysisEnabled, memory_order_acquire);
}

void PPVirtualLoopbackRouter_GetStatus(PPVirtualLoopbackRouterStatus *outStatus)
{
    if (!outStatus) {
        return;
    }

    memset(outStatus, 0, sizeof(*outStatus));

    PPVirtualLoopbackStatus transportStatus;
    PPVirtualLoopbackTransport_GetStatus(&transportStatus);

    pthread_mutex_lock(&gRouter.lock);
    outStatus->isRunning = atomic_load_explicit(&gRouter.isRunning, memory_order_acquire);
    outStatus->writerConnected = transportStatus.writerConnected;
    outStatus->sampleRate = gRouter.sampleRate > 0.0 ? gRouter.sampleRate : transportStatus.sampleRate;
    outStatus->channels = gRouter.channels > 0 ? gRouter.channels : transportStatus.channels;
    outStatus->bufferFrames = gRouter.actualBufferFrames;
    outStatus->framesRendered = atomic_load_explicit(&gRouter.framesRendered, memory_order_relaxed);
    outStatus->framesAvailable = pp_router_output_fifo_frames_available_to_read(&gRouter.outputFIFO);
    outStatus->overruns = transportStatus.overruns;
    outStatus->underruns = atomic_load_explicit(&gRouter.underruns, memory_order_relaxed);
    pthread_mutex_unlock(&gRouter.lock);
}
