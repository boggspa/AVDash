#include "PodcastPreviewLoopbackTransport.h"

#include <CoreAudio/HostTime.h>
#include <AudioToolbox/AudioToolbox.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define PP_LOOPBACK_SHARED_PATH "/tmp/ppprevloop.v1"
#define PP_LOOPBACK_MAGIC 0x50504C42u
#define PP_LOOPBACK_VERSION 4u
#define PP_LOOPBACK_SHARED_CAPACITY_FRAMES 65536u
#define PP_LOOPBACK_Q32_ONE 4294967296.0
#define PP_LOOPBACK_SRC_TAP_COUNT 32u
#define PP_LOOPBACK_SRC_HALF_TAPS (PP_LOOPBACK_SRC_TAP_COUNT / 2u)
#define PP_LOOPBACK_SRC_PHASE_COUNT 2048u
#define PP_LOOPBACK_SRC_PHASE_TABLE_SIZE (PP_LOOPBACK_SRC_PHASE_COUNT + 1u)
#define PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT 16u
#define PP_LOOPBACK_SRC_MIN_CUTOFF 0.40
#define PP_LOOPBACK_OUTPUT_HEADROOM 0.96f
#define PP_LOOPBACK_OUTPUT_LIMIT_THRESHOLD 0.98f
#define PP_LOOPBACK_OUTPUT_LIMIT_INPUT 1.10f
#define PP_LOOPBACK_OUTPUT_LIMIT_CEILING 0.995f
#define PP_LOOPBACK_FAST_PATH_MIN_DEADBAND_FRAMES 128.0
#define PP_LOOPBACK_FAST_PATH_MAX_DEADBAND_FRAMES 1024.0
#define PP_LOOPBACK_FAST_PATH_TARGET_FRACTION 0.25
#define PP_LOOPBACK_BLOCK_SRC_RATE_EPSILON 1.0

typedef struct {
    _Atomic uint32_t writerConnected;
    _Atomic uint32_t sourceEnabled;
    _Atomic uint32_t channels;
    _Atomic uint32_t ringCapacityFrames;
    _Atomic uint32_t preferredIOBufferFrames;
    _Atomic float sourceGain;
    _Atomic float recentPeak;
    double sampleRate;
    _Atomic uint64_t latestEndHostTime;
    _Atomic uint64_t hostTicksPerFrameQ32;
    _Atomic uint64_t framesWritten;
    _Atomic uint64_t framesRead;
    _Atomic uint64_t overruns;
    _Atomic uint64_t underruns;
    float interleavedSamples[PP_LOOPBACK_SHARED_CAPACITY_FRAMES * PP_LOOPBACK_MAX_CHANNELS];
} PPVirtualLoopbackSourceState;

typedef struct {
    uint32_t magic;
    uint32_t version;
    _Atomic uint32_t initialized;
    _Atomic uint32_t routerRunning;
    char requestedOutputDeviceUID[PP_LOOPBACK_DEVICE_UID_MAX];
    char activeOutputDeviceUID[PP_LOOPBACK_DEVICE_UID_MAX];
    char lastError[PP_LOOPBACK_ERROR_TEXT_MAX];
    PPVirtualLoopbackSourceState sources[kPPVirtualLoopbackSourceCount];
} PPVirtualLoopbackSharedState;

struct PPVirtualLoopbackWriter {
    int fd;
    PPVirtualLoopbackSourceID sourceID;
    PPVirtualLoopbackSharedState *shared;
    uint64_t lastWriteStartHostTime;
    uint64_t lastWriteStartFrame;
    double hostTicksPerFrameEstimate;
    bool hasTimingHistory;
};

typedef struct {
    double readCursorFrames;
    double readRateRatio;
    uint32_t targetBufferFrames;
    bool primed;
    AudioConverterRef converter;
    AudioStreamBasicDescription converterInputASBD;
    AudioStreamBasicDescription converterOutputASBD;
    float *converterInputScratch;
    uint32_t converterInputScratchCapacityFrames;
    float *converterOutputScratch;
    uint32_t converterOutputScratchCapacityFrames;
} PPVirtualLoopbackReaderSourceState;

typedef struct {
    const PPVirtualLoopbackSourceState *source;
    uint64_t oldestFrame;
    uint64_t newestFrame;
    uint32_t sourceChannels;
    float *inputScratch;
    uint32_t inputScratchCapacityFrames;
    uint64_t nextFrame;
} PPVirtualLoopbackConverterInputContext;

struct PPVirtualLoopbackReader {
    int fd;
    PPVirtualLoopbackSharedState *shared;
    PPVirtualLoopbackReaderSourceState sources[kPPVirtualLoopbackSourceCount];
};

static char gPPProcessLocalLastError[PP_LOOPBACK_ERROR_TEXT_MAX];
static pthread_once_t gPPLoopbackSRCTableOnce = PTHREAD_ONCE_INIT;
static float gPPLoopbackSRCTable[PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT]
                                [PP_LOOPBACK_SRC_PHASE_TABLE_SIZE]
                                [PP_LOOPBACK_SRC_TAP_COUNT];

static float pp_source_sample_at_frame_index(const PPVirtualLoopbackSourceState *source,
                                             uint32_t sourceChannels,
                                             uint32_t outputChannel,
                                             uint64_t frameIndex);

static double pp_src_normalized_sinc(double value)
{
    if (fabs(value) < 1.0e-12) {
        return 1.0;
    }

    double scaled = M_PI * value;
    return sin(scaled) / scaled;
}

static double pp_src_blackman_window(uint32_t tapIndex)
{
    if (PP_LOOPBACK_SRC_TAP_COUNT <= 1u) {
        return 1.0;
    }

    double position = (double)tapIndex / (double)(PP_LOOPBACK_SRC_TAP_COUNT - 1u);
    return 0.42
        - (0.5 * cos(2.0 * M_PI * position))
        + (0.08 * cos(4.0 * M_PI * position));
}

static double pp_src_cutoff_for_band(uint32_t bandIndex)
{
    if (PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT <= 1u) {
        return 1.0;
    }

    double normalizedBand = (double)bandIndex / (double)(PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT - 1u);
    return PP_LOOPBACK_SRC_MIN_CUTOFF +
        ((1.0 - PP_LOOPBACK_SRC_MIN_CUTOFF) * normalizedBand);
}

static void pp_src_initialize_kernel_table(void)
{
    for (uint32_t bandIndex = 0; bandIndex < PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT; ++bandIndex) {
        double cutoff = pp_src_cutoff_for_band(bandIndex);

        for (uint32_t phaseIndex = 0; phaseIndex < PP_LOOPBACK_SRC_PHASE_TABLE_SIZE; ++phaseIndex) {
            double fractionalDelay = (double)phaseIndex / (double)PP_LOOPBACK_SRC_PHASE_COUNT;
            double coefficients[PP_LOOPBACK_SRC_TAP_COUNT];
            double coefficientSum = 0.0;

            for (uint32_t tapIndex = 0; tapIndex < PP_LOOPBACK_SRC_TAP_COUNT; ++tapIndex) {
                double tapOffset = (double)((int32_t)tapIndex - ((int32_t)PP_LOOPBACK_SRC_HALF_TAPS - 1)) -
                    fractionalDelay;
                double coefficient = cutoff *
                    pp_src_normalized_sinc(cutoff * tapOffset) *
                    pp_src_blackman_window(tapIndex);
                coefficients[tapIndex] = coefficient;
                coefficientSum += coefficient;
            }

            if (fabs(coefficientSum) < 1.0e-18) {
                coefficientSum = 1.0;
            }

            for (uint32_t tapIndex = 0; tapIndex < PP_LOOPBACK_SRC_TAP_COUNT; ++tapIndex) {
                gPPLoopbackSRCTable[bandIndex][phaseIndex][tapIndex] =
                    (float)(coefficients[tapIndex] / coefficientSum);
            }
        }
    }
}

static void pp_src_ensure_kernel_table_ready(void)
{
    pthread_once(&gPPLoopbackSRCTableOnce, pp_src_initialize_kernel_table);
}

static void pp_prepare_realtime_memory(void *memory, size_t byteCount)
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

static double pp_default_host_ticks_per_frame(double sampleRate)
{
    double hostFrequency = AudioGetHostClockFrequency();
    if (hostFrequency <= 0.0 || sampleRate <= 0.0) {
        return 0.0;
    }
    return hostFrequency / sampleRate;
}

static uint64_t pp_host_ticks_per_frame_to_q32(double hostTicksPerFrame)
{
    if (hostTicksPerFrame <= 0.0) {
        return 0;
    }
    return (uint64_t)llround(hostTicksPerFrame * PP_LOOPBACK_Q32_ONE);
}

static double pp_q32_to_host_ticks_per_frame(uint64_t q32Value)
{
    if (q32Value == 0) {
        return 0.0;
    }
    return (double)q32Value / PP_LOOPBACK_Q32_ONE;
}

static bool pp_is_valid_source_id(PPVirtualLoopbackSourceID sourceID)
{
    return sourceID >= kPPVirtualLoopbackSourceInput &&
           sourceID < kPPVirtualLoopbackSourceCount;
}

static PPVirtualLoopbackSourceState *pp_source_state(PPVirtualLoopbackSharedState *shared,
                                                     PPVirtualLoopbackSourceID sourceID)
{
    if (!shared || !pp_is_valid_source_id(sourceID)) {
        return NULL;
    }
    return &shared->sources[sourceID];
}

static const PPVirtualLoopbackSourceState *pp_source_state_const(const PPVirtualLoopbackSharedState *shared,
                                                                 PPVirtualLoopbackSourceID sourceID)
{
    if (!shared || !pp_is_valid_source_id(sourceID)) {
        return NULL;
    }
    return &shared->sources[sourceID];
}

static void pp_copy_cstring(char *dest, size_t destSize, const char *src)
{
    if (!dest || destSize == 0) {
        return;
    }
    if (!src) {
        dest[0] = '\0';
        return;
    }
    snprintf(dest, destSize, "%s", src);
}

static void pp_set_process_local_error(const char *errorText)
{
    pp_copy_cstring(gPPProcessLocalLastError, sizeof(gPPProcessLocalLastError), errorText);
}

static void pp_set_process_local_errno_error(const char *stage)
{
    char buffer[PP_LOOPBACK_ERROR_TEXT_MAX];
    snprintf(buffer,
             sizeof(buffer),
             "%s failed (%d: %s)",
             stage ? stage : "transport",
             errno,
             strerror(errno));
    pp_set_process_local_error(buffer);
}

static void pp_initialize_source_state(PPVirtualLoopbackSourceState *source)
{
    if (!source) {
        return;
    }

    memset(source, 0, sizeof(*source));
    source->sampleRate = 48000.0;
    atomic_store_explicit(&source->sourceEnabled, 1, memory_order_relaxed);
    atomic_store_explicit(&source->channels, 2, memory_order_relaxed);
    atomic_store_explicit(&source->ringCapacityFrames, PP_LOOPBACK_SHARED_CAPACITY_FRAMES, memory_order_relaxed);
    atomic_store_explicit(&source->preferredIOBufferFrames, 512, memory_order_relaxed);
    atomic_store_explicit(&source->sourceGain, 1.0f, memory_order_relaxed);
    atomic_store_explicit(&source->recentPeak, 0.0f, memory_order_relaxed);
    atomic_store_explicit(&source->latestEndHostTime, 0, memory_order_relaxed);
    atomic_store_explicit(&source->hostTicksPerFrameQ32,
                          pp_host_ticks_per_frame_to_q32(pp_default_host_ticks_per_frame(source->sampleRate)),
                          memory_order_relaxed);
}

static int pp_map_shared_state(int *outFD, PPVirtualLoopbackSharedState **outState)
{
    if (!outFD || !outState) {
        pp_set_process_local_error("Invalid shared state mapping arguments.");
        return -1;
    }

    int fd = open(PP_LOOPBACK_SHARED_PATH, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        pp_set_process_local_errno_error("open");
        return -2;
    }

    struct stat fileStat;
    if (fstat(fd, &fileStat) != 0) {
        pp_set_process_local_errno_error("fstat");
        close(fd);
        return -3;
    }

    const mode_t desiredMode = S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH;
    if ((fileStat.st_mode & 0777) != desiredMode) {
        if (fchmod(fd, desiredMode) != 0) {
            pp_set_process_local_errno_error("fchmod");
            close(fd);
            return -4;
        }
    }

    if (ftruncate(fd, (off_t)sizeof(PPVirtualLoopbackSharedState)) != 0) {
        pp_set_process_local_errno_error("ftruncate");
        close(fd);
        return -5;
    }

    void *mapped = mmap(NULL,
                        sizeof(PPVirtualLoopbackSharedState),
                        PROT_READ | PROT_WRITE,
                        MAP_SHARED,
                        fd,
                        0);
    if (mapped == MAP_FAILED) {
        pp_set_process_local_errno_error("mmap");
        close(fd);
        return -6;
    }

    pp_set_process_local_error("");
    pp_prepare_realtime_memory(mapped, sizeof(PPVirtualLoopbackSharedState));
    *outFD = fd;
    *outState = (PPVirtualLoopbackSharedState *)mapped;
    return 0;
}

static void pp_unmap_shared_state(int fd, PPVirtualLoopbackSharedState *state)
{
    if (state) {
        munmap(state, sizeof(PPVirtualLoopbackSharedState));
    }
    if (fd >= 0) {
        close(fd);
    }
}

static void pp_initialize_shared_state_if_needed(PPVirtualLoopbackSharedState *shared)
{
    if (!shared) {
        return;
    }

    uint32_t initialized = atomic_load_explicit(&shared->initialized, memory_order_acquire);
    if (initialized == 1 &&
        shared->magic == PP_LOOPBACK_MAGIC &&
        shared->version == PP_LOOPBACK_VERSION) {
        return;
    }

    memset(shared, 0, sizeof(*shared));
    shared->magic = PP_LOOPBACK_MAGIC;
    shared->version = PP_LOOPBACK_VERSION;
    for (uint32_t sourceIndex = 0; sourceIndex < kPPVirtualLoopbackSourceCount; ++sourceIndex) {
        pp_initialize_source_state(&shared->sources[sourceIndex]);
    }
    atomic_store_explicit(&shared->initialized, 1, memory_order_release);
}

static uint32_t pp_effective_source_channels(const PPVirtualLoopbackSourceState *source)
{
    uint32_t channels = source
        ? atomic_load_explicit(&source->channels, memory_order_acquire)
        : 0;
    if (channels == 0) {
        channels = 2;
    }
    if (channels > PP_LOOPBACK_MAX_CHANNELS) {
        channels = PP_LOOPBACK_MAX_CHANNELS;
    }
    return channels;
}

static uint32_t pp_effective_source_capacity(const PPVirtualLoopbackSourceState *source)
{
    uint32_t capacity = source
        ? atomic_load_explicit(&source->ringCapacityFrames, memory_order_acquire)
        : 0;
    if (capacity == 0 || capacity > PP_LOOPBACK_SHARED_CAPACITY_FRAMES) {
        capacity = PP_LOOPBACK_SHARED_CAPACITY_FRAMES;
    }
    return capacity;
}

static double pp_effective_source_sample_rate(const PPVirtualLoopbackSourceState *source)
{
    if (!source || source->sampleRate <= 0.0) {
        return 48000.0;
    }
    return source->sampleRate;
}

static uint32_t pp_effective_source_preferred_io_buffer(const PPVirtualLoopbackSourceState *source)
{
    uint32_t preferredFrames = source
        ? atomic_load_explicit(&source->preferredIOBufferFrames, memory_order_acquire)
        : 0;
    return preferredFrames > 0 ? preferredFrames : 512;
}

static double pp_effective_source_host_ticks_per_frame(const PPVirtualLoopbackSourceState *source)
{
    double hostTicksPerFrame = source
        ? pp_q32_to_host_ticks_per_frame(
            atomic_load_explicit(&source->hostTicksPerFrameQ32, memory_order_acquire))
        : 0.0;
    if (hostTicksPerFrame <= 0.0) {
        hostTicksPerFrame = pp_default_host_ticks_per_frame(pp_effective_source_sample_rate(source));
    }
    return hostTicksPerFrame;
}

static double pp_writer_resolve_host_ticks_per_frame(PPVirtualLoopbackWriterRef writer,
                                                     const PPVirtualLoopbackSourceState *source,
                                                     uint64_t startFrame,
                                                     uint64_t startHostTime,
                                                     double providedHostTicksPerFrame)
{
    if (!writer || !source) {
        return 0.0;
    }

    double estimate = writer->hostTicksPerFrameEstimate;
    if (estimate <= 0.0) {
        estimate = pp_default_host_ticks_per_frame(pp_effective_source_sample_rate(source));
    }

    double observed = 0.0;
    if (providedHostTicksPerFrame > 0.0) {
        observed = providedHostTicksPerFrame;
    } else if (writer->hasTimingHistory &&
               startHostTime > writer->lastWriteStartHostTime &&
               startFrame > writer->lastWriteStartFrame) {
        observed = (double)(startHostTime - writer->lastWriteStartHostTime) /
            (double)(startFrame - writer->lastWriteStartFrame);
    }

    if (observed > 0.0) {
        double blend = providedHostTicksPerFrame > 0.0 ? 0.30 : 0.10;
        estimate = (estimate > 0.0)
            ? ((estimate * (1.0 - blend)) + (observed * blend))
            : observed;
    }

    if (estimate <= 0.0) {
        estimate = pp_default_host_ticks_per_frame(pp_effective_source_sample_rate(source));
    }

    writer->hostTicksPerFrameEstimate = estimate;
    return estimate;
}

static bool pp_source_is_connected(const PPVirtualLoopbackSourceState *source)
{
    return source && atomic_load_explicit(&source->writerConnected, memory_order_acquire) != 0;
}

static bool pp_source_is_enabled(const PPVirtualLoopbackSourceState *source)
{
    return source && atomic_load_explicit(&source->sourceEnabled, memory_order_acquire) != 0;
}

static float pp_source_gain(const PPVirtualLoopbackSourceState *source)
{
    float gain = source ? atomic_load_explicit(&source->sourceGain, memory_order_acquire) : 1.0f;
    if (gain < 0.0f) {
        gain = 0.0f;
    }
    if (gain > 4.0f) {
        gain = 4.0f;
    }
    return gain;
}

static float pp_source_peak(const PPVirtualLoopbackSourceState *source)
{
    float peak = source ? atomic_load_explicit(&source->recentPeak, memory_order_acquire) : 0.0f;
    if (peak < 0.0f) {
        peak = 0.0f;
    }
    if (peak > 1.0f) {
        peak = 1.0f;
    }
    return peak;
}

static uint64_t pp_source_frames_available(const PPVirtualLoopbackSourceState *source)
{
    if (!source) {
        return 0;
    }

    uint32_t capacity = pp_effective_source_capacity(source);
    uint64_t written = atomic_load_explicit(&source->framesWritten, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&source->framesRead, memory_order_acquire);
    if (written > read + capacity) {
        read = written - capacity;
    }
    return (written > read) ? (written - read) : 0;
}

static double pp_mixed_sample_rate(const PPVirtualLoopbackSharedState *shared)
{
    const PPVirtualLoopbackSourceState *systemSource = pp_source_state_const(shared, kPPVirtualLoopbackSourceSystem);
    if (pp_source_is_connected(systemSource)) {
        return pp_effective_source_sample_rate(systemSource);
    }

    const PPVirtualLoopbackSourceState *inputSource = pp_source_state_const(shared, kPPVirtualLoopbackSourceInput);
    if (pp_source_is_connected(inputSource)) {
        return pp_effective_source_sample_rate(inputSource);
    }

    if (systemSource) {
        return pp_effective_source_sample_rate(systemSource);
    }
    if (inputSource) {
        return pp_effective_source_sample_rate(inputSource);
    }
    return 48000.0;
}

static uint32_t pp_mixed_channels(const PPVirtualLoopbackSharedState *shared)
{
    const PPVirtualLoopbackSourceState *systemSource = pp_source_state_const(shared, kPPVirtualLoopbackSourceSystem);
    if (pp_source_is_connected(systemSource)) {
        return pp_effective_source_channels(systemSource);
    }

    const PPVirtualLoopbackSourceState *inputSource = pp_source_state_const(shared, kPPVirtualLoopbackSourceInput);
    if (pp_source_is_connected(inputSource)) {
        return pp_effective_source_channels(inputSource);
    }

    if (systemSource) {
        return pp_effective_source_channels(systemSource);
    }
    if (inputSource) {
        return pp_effective_source_channels(inputSource);
    }
    return 2;
}

static uint32_t pp_mixed_capacity(const PPVirtualLoopbackSharedState *shared)
{
    uint32_t mixedCapacity = 0;
    for (uint32_t sourceIndex = 0; sourceIndex < kPPVirtualLoopbackSourceCount; ++sourceIndex) {
        uint32_t sourceCapacity = pp_effective_source_capacity(&shared->sources[sourceIndex]);
        if (sourceCapacity > mixedCapacity) {
            mixedCapacity = sourceCapacity;
        }
    }
    return mixedCapacity > 0 ? mixedCapacity : PP_LOOPBACK_SHARED_CAPACITY_FRAMES;
}

static uint32_t pp_mixed_preferred_io_buffer(const PPVirtualLoopbackSharedState *shared)
{
    uint32_t preferredFrames = 0;
    for (uint32_t sourceIndex = 0; sourceIndex < kPPVirtualLoopbackSourceCount; ++sourceIndex) {
        uint32_t sourcePreferred = pp_effective_source_preferred_io_buffer(&shared->sources[sourceIndex]);
        if (sourcePreferred > preferredFrames) {
            preferredFrames = sourcePreferred;
        }
    }
    return preferredFrames > 0 ? preferredFrames : 512;
}

static uint32_t pp_source_channel_for_output_channel(uint32_t sourceChannels, uint32_t outputChannel)
{
    if (sourceChannels == 0) {
        return UINT32_MAX;
    }
    if (sourceChannels == 1) {
        return 0;
    }
    return outputChannel < sourceChannels ? outputChannel : UINT32_MAX;
}

static float pp_clamp_sample(float sample)
{
    if (sample > 1.0f) {
        return 1.0f;
    }
    if (sample < -1.0f) {
        return -1.0f;
    }
    return sample;
}

static float pp_soft_limit_sample(float sample)
{
    float magnitude = fabsf(sample);
    if (magnitude <= PP_LOOPBACK_OUTPUT_LIMIT_THRESHOLD) {
        return sample;
    }

    float sign = copysignf(1.0f, sample);
    if (magnitude >= PP_LOOPBACK_OUTPUT_LIMIT_INPUT) {
        return sign * PP_LOOPBACK_OUTPUT_LIMIT_CEILING;
    }

    float normalized = (magnitude - PP_LOOPBACK_OUTPUT_LIMIT_THRESHOLD) /
        (PP_LOOPBACK_OUTPUT_LIMIT_INPUT - PP_LOOPBACK_OUTPUT_LIMIT_THRESHOLD);
    float curve = ((-normalized + 1.0f) * normalized + 1.0f) * normalized;
    float limited = PP_LOOPBACK_OUTPUT_LIMIT_THRESHOLD +
        ((PP_LOOPBACK_OUTPUT_LIMIT_CEILING - PP_LOOPBACK_OUTPUT_LIMIT_THRESHOLD) * curve);
    return sign * limited;
}

static void pp_reader_dispose_converter(PPVirtualLoopbackReaderSourceState *state)
{
    if (!state) {
        return;
    }

    if (state->converter) {
        AudioConverterDispose(state->converter);
        state->converter = NULL;
    }

    free(state->converterInputScratch);
    state->converterInputScratch = NULL;
    state->converterInputScratchCapacityFrames = 0;
    free(state->converterOutputScratch);
    state->converterOutputScratch = NULL;
    state->converterOutputScratchCapacityFrames = 0;
    memset(&state->converterInputASBD, 0, sizeof(state->converterInputASBD));
    memset(&state->converterOutputASBD, 0, sizeof(state->converterOutputASBD));
}

static AudioStreamBasicDescription pp_loopback_float_asbd(double sampleRate, uint32_t channels)
{
    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBitsPerChannel = 32;
    asbd.mChannelsPerFrame = channels;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = channels * sizeof(float);
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    return asbd;
}

static double pp_output_sample_rate_from_host_ticks_per_frame(double outputHostTicksPerFrame,
                                                              double fallbackSampleRate)
{
    double hostFrequency = AudioGetHostClockFrequency();
    if (hostFrequency > 0.0 && outputHostTicksPerFrame > 0.0) {
        double sampleRate = hostFrequency / outputHostTicksPerFrame;
        if (sampleRate > 0.0) {
            return sampleRate;
        }
    }
    return fallbackSampleRate > 0.0 ? fallbackSampleRate : 48000.0;
}

static bool pp_should_use_block_src(double sourceSampleRate, double outputSampleRate)
{
    return fabs(sourceSampleRate - outputSampleRate) >= PP_LOOPBACK_BLOCK_SRC_RATE_EPSILON;
}

static bool pp_should_use_equal_rate_fast_path(double sourceSampleRate,
                                               double outputSampleRate,
                                               double phaseErrorFrames,
                                               uint32_t targetBufferFrames)
{
    (void)phaseErrorFrames;
    (void)targetBufferFrames;

    if (pp_should_use_block_src(sourceSampleRate, outputSampleRate)) {
        return false;
    }

    return true;
}

static OSStatus pp_reader_audio_converter_input_proc(AudioConverterRef inAudioConverter,
                                                     UInt32 *ioNumberDataPackets,
                                                     AudioBufferList *ioData,
                                                     AudioStreamPacketDescription **outDataPacketDescription,
                                                     void *inUserData)
{
    (void)inAudioConverter;
    (void)outDataPacketDescription;

    if (!ioNumberDataPackets || !ioData || !inUserData) {
        return kAudio_ParamError;
    }

    PPVirtualLoopbackConverterInputContext *context = (PPVirtualLoopbackConverterInputContext *)inUserData;
    if (!context->source || !context->inputScratch || context->inputScratchCapacityFrames == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    uint32_t framesRequested = *ioNumberDataPackets;
    if (framesRequested > context->inputScratchCapacityFrames) {
        framesRequested = context->inputScratchCapacityFrames;
    }

    if (context->nextFrame < context->oldestFrame) {
        context->nextFrame = context->oldestFrame;
    }

    uint32_t availableFrames = 0;
    if (context->nextFrame <= context->newestFrame) {
        uint64_t remainingFrames = (context->newestFrame - context->nextFrame) + 1u;
        availableFrames = remainingFrames > UINT32_MAX ? UINT32_MAX : (uint32_t)remainingFrames;
    }

    if (framesRequested > availableFrames) {
        framesRequested = availableFrames;
    }

    if (framesRequested == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    for (uint32_t frame = 0; frame < framesRequested; ++frame) {
        uint64_t frameIndex = context->nextFrame + frame;
        size_t baseIndex = (size_t)frame * context->sourceChannels;
        for (uint32_t channel = 0; channel < context->sourceChannels; ++channel) {
            context->inputScratch[baseIndex + channel] =
                pp_source_sample_at_frame_index(context->source,
                                                context->sourceChannels,
                                                channel,
                                                frameIndex);
        }
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = context->sourceChannels;
    ioData->mBuffers[0].mDataByteSize = framesRequested * context->sourceChannels * sizeof(float);
    ioData->mBuffers[0].mData = context->inputScratch;
    context->nextFrame += framesRequested;
    *ioNumberDataPackets = framesRequested;
    return noErr;
}

static bool pp_reader_ensure_block_src(PPVirtualLoopbackReaderSourceState *readerSource,
                                       double sourceSampleRate,
                                       double outputSampleRate,
                                       uint32_t sourceChannels,
                                       uint32_t maxOutputFrames)
{
    if (!readerSource || sourceChannels == 0 || maxOutputFrames == 0) {
        return false;
    }

    AudioStreamBasicDescription inputASBD = pp_loopback_float_asbd(sourceSampleRate, sourceChannels);
    AudioStreamBasicDescription outputASBD = pp_loopback_float_asbd(outputSampleRate, sourceChannels);

    bool needsNewConverter = readerSource->converter == NULL ||
        fabs(readerSource->converterInputASBD.mSampleRate - inputASBD.mSampleRate) >= PP_LOOPBACK_BLOCK_SRC_RATE_EPSILON ||
        fabs(readerSource->converterOutputASBD.mSampleRate - outputASBD.mSampleRate) >= PP_LOOPBACK_BLOCK_SRC_RATE_EPSILON ||
        readerSource->converterInputASBD.mChannelsPerFrame != inputASBD.mChannelsPerFrame ||
        readerSource->converterOutputASBD.mChannelsPerFrame != outputASBD.mChannelsPerFrame;

    if (needsNewConverter) {
        pp_reader_dispose_converter(readerSource);

        AudioConverterRef converter = NULL;
        if (AudioConverterNew(&inputASBD, &outputASBD, &converter) != noErr || !converter) {
            return false;
        }

        UInt32 quality = kAudioConverterQuality_Max;
        (void)AudioConverterSetProperty(converter,
                                        kAudioConverterSampleRateConverterQuality,
                                        sizeof(quality),
                                        &quality);

        readerSource->converter = converter;
        readerSource->converterInputASBD = inputASBD;
        readerSource->converterOutputASBD = outputASBD;
    }

    uint32_t requiredScratchFrames = (uint32_t)ceil((double)maxOutputFrames *
                                                    (sourceSampleRate / outputSampleRate)) + 64u;
    if (requiredScratchFrames < maxOutputFrames) {
        requiredScratchFrames = maxOutputFrames;
    }

    if (readerSource->converterInputScratchCapacityFrames < requiredScratchFrames ||
        !readerSource->converterInputScratch) {
        float *scratch = (float *)realloc(readerSource->converterInputScratch,
                                          (size_t)requiredScratchFrames * sourceChannels * sizeof(float));
        if (!scratch) {
            pp_reader_dispose_converter(readerSource);
            return false;
        }
        readerSource->converterInputScratch = scratch;
        readerSource->converterInputScratchCapacityFrames = requiredScratchFrames;
    }

    if (readerSource->converterOutputScratchCapacityFrames < maxOutputFrames ||
        !readerSource->converterOutputScratch) {
        float *scratch = (float *)realloc(readerSource->converterOutputScratch,
                                          (size_t)maxOutputFrames * sourceChannels * sizeof(float));
        if (!scratch) {
            pp_reader_dispose_converter(readerSource);
            return false;
        }
        readerSource->converterOutputScratch = scratch;
        readerSource->converterOutputScratchCapacityFrames = maxOutputFrames;
    }

    return true;
}

static uint32_t pp_reader_mix_source_via_block_src(PPVirtualLoopbackReaderSourceState *readerSource,
                                                   const PPVirtualLoopbackSourceState *source,
                                                   uint64_t oldestReadableFrame,
                                                   uint64_t writtenFrames,
                                                   uint32_t sourceChannels,
                                                   uint32_t effectiveChannels,
                                                   double sourceSampleRate,
                                                   double outputSampleRate,
                                                   uint32_t maxFrames,
                                                   float sourceGain,
                                                   float *outSamples)
{
    if (!readerSource || !source || !outSamples || sourceChannels == 0 || effectiveChannels == 0 || maxFrames == 0) {
        return 0;
    }

    if (!pp_reader_ensure_block_src(readerSource,
                                    sourceSampleRate,
                                    outputSampleRate,
                                    sourceChannels,
                                    maxFrames)) {
        return 0;
    }

    if (readerSource->readCursorFrames < (double)oldestReadableFrame) {
        readerSource->readCursorFrames = (double)oldestReadableFrame;
    }

    uint64_t nextFrame = (uint64_t)floor(readerSource->readCursorFrames);
    uint64_t newestReadableFrame = writtenFrames > 0 ? (writtenFrames - 1u) : 0u;
    if (nextFrame > newestReadableFrame) {
        nextFrame = newestReadableFrame;
    }

    PPVirtualLoopbackConverterInputContext context = {
        .source = source,
        .oldestFrame = oldestReadableFrame,
        .newestFrame = newestReadableFrame,
        .sourceChannels = sourceChannels,
        .inputScratch = readerSource->converterInputScratch,
        .inputScratchCapacityFrames = readerSource->converterInputScratchCapacityFrames,
        .nextFrame = nextFrame
    };

    AudioBufferList outputBufferList;
    memset(&outputBufferList, 0, sizeof(outputBufferList));
    outputBufferList.mNumberBuffers = 1;
    outputBufferList.mBuffers[0].mNumberChannels = sourceChannels;
    outputBufferList.mBuffers[0].mDataByteSize = maxFrames * sourceChannels * sizeof(float);
    outputBufferList.mBuffers[0].mData = readerSource->converterOutputScratch;

    UInt32 outputPackets = maxFrames;
    if (AudioConverterFillComplexBuffer(readerSource->converter,
                                        pp_reader_audio_converter_input_proc,
                                        &context,
                                        &outputPackets,
                                        &outputBufferList,
                                        NULL) != noErr ||
        outputPackets == 0) {
        return 0;
    }

    for (UInt32 frame = 0; frame < outputPackets; ++frame) {
        size_t sourceBase = (size_t)frame * sourceChannels;
        size_t destBase = (size_t)frame * effectiveChannels;
        for (uint32_t channel = 0; channel < effectiveChannels; ++channel) {
            uint32_t sourceChannel = pp_source_channel_for_output_channel(sourceChannels, channel);
            float sample = sourceChannel == UINT32_MAX
                ? 0.0f
                : readerSource->converterOutputScratch[sourceBase + sourceChannel];
            outSamples[destBase + channel] += sample * sourceGain;
        }
    }

    readerSource->readCursorFrames = (double)context.nextFrame;
    readerSource->readRateRatio = sourceSampleRate / outputSampleRate;
    return outputPackets;
}

static uint32_t pp_reader_mix_source_via_direct_copy(PPVirtualLoopbackReaderSourceState *readerSource,
                                                     const PPVirtualLoopbackSourceState *source,
                                                     uint64_t oldestReadableFrame,
                                                     uint64_t writtenFrames,
                                                     uint32_t sourceChannels,
                                                     uint32_t effectiveChannels,
                                                     uint32_t maxFrames,
                                                     float sourceGain,
                                                     bool sourceEnabled,
                                                     double phaseErrorFrames,
                                                     float *outSamples)
{
    if (!readerSource || !source || !outSamples || sourceChannels == 0 || effectiveChannels == 0 || maxFrames == 0) {
        return 0;
    }

    if (writtenFrames == 0) {
        return 0;
    }

    uint64_t readStartFrame = (uint64_t)floor(readerSource->readCursorFrames);
    if (readStartFrame < oldestReadableFrame) {
        readStartFrame = oldestReadableFrame;
    }
    if (readStartFrame >= writtenFrames) {
        readerSource->readCursorFrames = (double)writtenFrames;
        readerSource->readRateRatio = 1.0;
        return 0;
    }

    uint64_t availableFrames64 = writtenFrames - readStartFrame;
    uint32_t framesMixed = availableFrames64 > maxFrames ? maxFrames : (uint32_t)availableFrames64;
    if (framesMixed == 0) {
        return 0;
    }

    if (sourceEnabled && sourceGain > 0.0f) {
        for (uint32_t frame = 0; frame < framesMixed; ++frame) {
            size_t destBase = (size_t)frame * effectiveChannels;
            uint64_t frameIndex = readStartFrame + frame;
            for (uint32_t channel = 0; channel < effectiveChannels; ++channel) {
                float sample = pp_source_sample_at_frame_index(source,
                                                               sourceChannels,
                                                               channel,
                                                               frameIndex);
                outSamples[destBase + channel] += sample * sourceGain;
            }
        }
    }

    int64_t nextReadFrame = (int64_t)readStartFrame + (int64_t)framesMixed;

    if (nextReadFrame < (int64_t)oldestReadableFrame) {
        nextReadFrame = (int64_t)oldestReadableFrame;
    }
    if (nextReadFrame > (int64_t)writtenFrames) {
        nextReadFrame = (int64_t)writtenFrames;
    }

    readerSource->readCursorFrames = (double)nextReadFrame;
    readerSource->readRateRatio = 1.0;
    return framesMixed;
}

static void pp_reader_reset_source_state(PPVirtualLoopbackReaderSourceState *state)
{
    if (!state) {
        return;
    }

    pp_reader_dispose_converter(state);
    memset(state, 0, sizeof(*state));
    state->readRateRatio = 1.0;
}

static uint32_t pp_reader_target_buffer_frames(const PPVirtualLoopbackSourceState *source,
                                               uint32_t requestedFrames)
{
    uint32_t preferredFrames = pp_effective_source_preferred_io_buffer(source);
    uint32_t capacity = pp_effective_source_capacity(source);

    uint32_t targetFrames = preferredFrames * 8;
    uint32_t minimumTarget = requestedFrames * 6;
    if (targetFrames < minimumTarget) {
        targetFrames = minimumTarget;
    }
    if (targetFrames < 2048) {
        targetFrames = 2048;
    }

    if (capacity > 0) {
        uint32_t maximumTarget = (capacity * 3) / 4;
        if (maximumTarget == 0) {
            maximumTarget = capacity;
        }
        if (targetFrames > maximumTarget) {
            targetFrames = maximumTarget;
        }
    }

    if (targetFrames < requestedFrames) {
        targetFrames = requestedFrames;
    }

    return targetFrames > 0 ? targetFrames : requestedFrames;
}

static double pp_reader_target_rate_ratio(double baseRateRatio,
                                          double phaseErrorFrames,
                                          uint32_t targetBufferFrames)
{
    if (targetBufferFrames == 0 || baseRateRatio <= 0.0) {
        return baseRateRatio > 0.0 ? baseRateRatio : 1.0;
    }

    double normalizedError = phaseErrorFrames / (double)targetBufferFrames;
    if (normalizedError > 1.0) {
        normalizedError = 1.0;
    } else if (normalizedError < -1.0) {
        normalizedError = -1.0;
    }

    // Keep drift trims in the low-ppm range. This tracks independent clocks
    // without audible pitch wobble when the machine is under load.
    double correctionPPM = normalizedError * 200.0;
    double maximumCorrectionPPM = 800.0;
    if (correctionPPM > maximumCorrectionPPM) {
        correctionPPM = maximumCorrectionPPM;
    } else if (correctionPPM < -maximumCorrectionPPM) {
        correctionPPM = -maximumCorrectionPPM;
    }

    double targetRatio = baseRateRatio * (1.0 + (correctionPPM * 0.000001));
    double minimumRatio = baseRateRatio * (1.0 - (maximumCorrectionPPM * 0.000001));
    double maximumRatio = baseRateRatio * (1.0 + (maximumCorrectionPPM * 0.000001));

    if (targetRatio < minimumRatio) {
        targetRatio = minimumRatio;
    } else if (targetRatio > maximumRatio) {
        targetRatio = maximumRatio;
    }
    return targetRatio;
}

static float pp_source_sample_at_frame_index(const PPVirtualLoopbackSourceState *source,
                                             uint32_t sourceChannels,
                                             uint32_t outputChannel,
                                             uint64_t frameIndex)
{
    if (!source) {
        return 0.0f;
    }

    uint32_t sourceChannel = pp_source_channel_for_output_channel(sourceChannels, outputChannel);
    if (sourceChannel == UINT32_MAX) {
        return 0.0f;
    }

    uint32_t capacity = pp_effective_source_capacity(source);
    if (capacity == 0) {
        return 0.0f;
    }

    size_t sampleIndex = ((size_t)(frameIndex % capacity) * PP_LOOPBACK_MAX_CHANNELS) + sourceChannel;
    return source->interleavedSamples[sampleIndex];
}

static double pp_src_desired_cutoff(double readRateRatio)
{
    if (readRateRatio <= 1.0) {
        return 1.0;
    }

    double cutoff = 1.0 / readRateRatio;
    if (cutoff > 1.0) {
        cutoff = 1.0;
    }
    if (cutoff < PP_LOOPBACK_SRC_MIN_CUTOFF) {
        cutoff = PP_LOOPBACK_SRC_MIN_CUTOFF;
    }
    return cutoff;
}

static void pp_src_resolve_kernel(double readRateRatio,
                                  double fractionalDelay,
                                  uint32_t *outBandIndex0,
                                  uint32_t *outBandIndex1,
                                  double *outBandBlend,
                                  uint32_t *outPhaseIndex0,
                                  uint32_t *outPhaseIndex1,
                                  double *outPhaseBlend)
{
    if (!outBandIndex0 || !outBandIndex1 || !outBandBlend ||
        !outPhaseIndex0 || !outPhaseIndex1 || !outPhaseBlend) {
        return;
    }

    double cutoff = pp_src_desired_cutoff(readRateRatio);
    double cutoffRange = 1.0 - PP_LOOPBACK_SRC_MIN_CUTOFF;
    double bandPosition = 0.0;
    if (cutoffRange > 0.0 && PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT > 1u) {
        bandPosition = ((cutoff - PP_LOOPBACK_SRC_MIN_CUTOFF) / cutoffRange) *
            (double)(PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT - 1u);
    }

    if (bandPosition < 0.0) {
        bandPosition = 0.0;
    }
    double maximumBandPosition = (double)(PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT - 1u);
    if (bandPosition > maximumBandPosition) {
        bandPosition = maximumBandPosition;
    }

    uint32_t bandIndex0 = (uint32_t)floor(bandPosition);
    uint32_t bandIndex1 = bandIndex0 < (PP_LOOPBACK_SRC_CUTOFF_BAND_COUNT - 1u)
        ? (bandIndex0 + 1u)
        : bandIndex0;
    double bandBlend = bandPosition - (double)bandIndex0;

    if (fractionalDelay < 0.0) {
        fractionalDelay = 0.0;
    }
    if (fractionalDelay > 1.0) {
        fractionalDelay = 1.0;
    }

    double phasePosition = fractionalDelay * (double)PP_LOOPBACK_SRC_PHASE_COUNT;
    if (phasePosition < 0.0) {
        phasePosition = 0.0;
    }
    double maximumPhasePosition = (double)PP_LOOPBACK_SRC_PHASE_COUNT;
    if (phasePosition > maximumPhasePosition) {
        phasePosition = maximumPhasePosition;
    }

    uint32_t phaseIndex0 = (uint32_t)floor(phasePosition);
    uint32_t phaseIndex1 = phaseIndex0 < PP_LOOPBACK_SRC_PHASE_COUNT
        ? (phaseIndex0 + 1u)
        : phaseIndex0;
    double phaseBlend = phasePosition - (double)phaseIndex0;

    *outBandIndex0 = bandIndex0;
    *outBandIndex1 = bandIndex1;
    *outBandBlend = bandBlend;
    *outPhaseIndex0 = phaseIndex0;
    *outPhaseIndex1 = phaseIndex1;
    *outPhaseBlend = phaseBlend;
}

static bool pp_reader_prepare_source(PPVirtualLoopbackReaderSourceState *readerSource,
                                     const PPVirtualLoopbackSourceState *source,
                                     uint64_t writtenFrames,
                                     uint32_t requestedFrames,
                                     double *outOldestReadableFrame,
                                     double *outFramesAhead)
{
    if (!readerSource || !source || !outOldestReadableFrame || !outFramesAhead) {
        return false;
    }

    uint32_t capacity = pp_effective_source_capacity(source);
    uint64_t oldestReadableFrame = (writtenFrames > capacity) ? (writtenFrames - capacity) : 0;
    readerSource->targetBufferFrames = pp_reader_target_buffer_frames(source, requestedFrames);

    if (writtenFrames == 0) {
        pp_reader_reset_source_state(readerSource);
        *outOldestReadableFrame = 0.0;
        *outFramesAhead = 0.0;
        return false;
    }

    if (!readerSource->primed) {
        uint64_t availableFrames = writtenFrames - oldestReadableFrame;
        uint32_t minimumPrimeFrames = readerSource->targetBufferFrames / 2;
        if (minimumPrimeFrames < requestedFrames) {
            minimumPrimeFrames = requestedFrames;
        }
        if (availableFrames < minimumPrimeFrames) {
            *outOldestReadableFrame = (double)oldestReadableFrame;
            *outFramesAhead = (double)availableFrames;
            return false;
        }

        double initialCursor = writtenFrames > readerSource->targetBufferFrames
            ? (double)(writtenFrames - readerSource->targetBufferFrames)
            : (double)oldestReadableFrame;
        if (initialCursor < (double)oldestReadableFrame) {
            initialCursor = (double)oldestReadableFrame;
        }
        readerSource->readCursorFrames = initialCursor;
        readerSource->readRateRatio = 1.0;
        readerSource->primed = true;
    }

    if (readerSource->readCursorFrames < (double)oldestReadableFrame) {
        readerSource->readCursorFrames = writtenFrames > readerSource->targetBufferFrames
            ? (double)(writtenFrames - readerSource->targetBufferFrames)
            : (double)oldestReadableFrame;
    }

    if (readerSource->readCursorFrames > (double)writtenFrames) {
        readerSource->readCursorFrames = writtenFrames > requestedFrames
            ? (double)(writtenFrames - requestedFrames)
            : (double)oldestReadableFrame;
    }

    double framesAhead = (double)writtenFrames - readerSource->readCursorFrames;
    if (framesAhead < 0.0) {
        framesAhead = 0.0;
    }

    *outOldestReadableFrame = (double)oldestReadableFrame;
    *outFramesAhead = framesAhead;
    return true;
}

static float pp_reader_sample_source_at_position(const PPVirtualLoopbackSourceState *source,
                                                 double oldestReadableFrame,
                                                 uint64_t writtenFrames,
                                                 uint32_t sourceChannels,
                                                 uint32_t outputChannel,
                                                 double positionFrames,
                                                 double readRateRatio)
{
    if (!source) {
        return 0.0f;
    }

    uint32_t sourceChannel = pp_source_channel_for_output_channel(sourceChannels, outputChannel);
    if (sourceChannel == UINT32_MAX) {
        return 0.0f;
    }

    uint32_t capacity = pp_effective_source_capacity(source);
    if (capacity == 0) {
        return 0.0f;
    }

    if (positionFrames < 0.0) {
        positionFrames = 0.0;
    }

    if (writtenFrames == 0) {
        return 0.0f;
    }

    double maximumReadableFrame = writtenFrames > 1 ? (double)(writtenFrames - 1) : 0.0;
    if (positionFrames > maximumReadableFrame) {
        positionFrames = maximumReadableFrame;
    }
    if (positionFrames < oldestReadableFrame) {
        positionFrames = oldestReadableFrame;
    }

    uint64_t frameIndex1 = (uint64_t)floor(positionFrames);
    double fraction = positionFrames - (double)frameIndex1;
    uint64_t oldestFrame = oldestReadableFrame > 0.0 ? (uint64_t)floor(oldestReadableFrame) : 0u;
    uint64_t newestFrame = writtenFrames > 0u ? (writtenFrames - 1u) : 0u;

    pp_src_ensure_kernel_table_ready();

    uint32_t bandIndex0 = 0;
    uint32_t bandIndex1 = 0;
    uint32_t phaseIndex0 = 0;
    uint32_t phaseIndex1 = 0;
    double bandBlend = 0.0;
    double phaseBlend = 0.0;
    pp_src_resolve_kernel(readRateRatio,
                          fraction,
                          &bandIndex0,
                          &bandIndex1,
                          &bandBlend,
                          &phaseIndex0,
                          &phaseIndex1,
                          &phaseBlend);

    int64_t tapStartFrame = (int64_t)frameIndex1 - ((int64_t)PP_LOOPBACK_SRC_HALF_TAPS - 1);
    double accumulatedSample = 0.0;

    for (uint32_t tapIndex = 0; tapIndex < PP_LOOPBACK_SRC_TAP_COUNT; ++tapIndex) {
        int64_t sampleFrame = tapStartFrame + (int64_t)tapIndex;
        if (sampleFrame < (int64_t)oldestFrame) {
            sampleFrame = (int64_t)oldestFrame;
        } else if (sampleFrame > (int64_t)newestFrame) {
            sampleFrame = (int64_t)newestFrame;
        }

        float band0Phase0 = gPPLoopbackSRCTable[bandIndex0][phaseIndex0][tapIndex];
        float band0Phase1 = gPPLoopbackSRCTable[bandIndex0][phaseIndex1][tapIndex];
        double coefficient0 = (double)band0Phase0 + (((double)band0Phase1 - (double)band0Phase0) * phaseBlend);

        double coefficient = coefficient0;
        if (bandIndex1 != bandIndex0) {
            float band1Phase0 = gPPLoopbackSRCTable[bandIndex1][phaseIndex0][tapIndex];
            float band1Phase1 = gPPLoopbackSRCTable[bandIndex1][phaseIndex1][tapIndex];
            double coefficient1 = (double)band1Phase0 + (((double)band1Phase1 - (double)band1Phase0) * phaseBlend);
            coefficient = coefficient0 + ((coefficient1 - coefficient0) * bandBlend);
        }

        float sample = pp_source_sample_at_frame_index(source,
                                                       sourceChannels,
                                                       outputChannel,
                                                       (uint64_t)sampleFrame);
        accumulatedSample += (double)sample * coefficient;
    }

    return (float)accumulatedSample;
}

static void pp_fill_status_from_shared(PPVirtualLoopbackSharedState *shared, PPVirtualLoopbackStatus *outStatus)
{
    if (!shared || !outStatus) {
        return;
    }

    memset(outStatus, 0, sizeof(*outStatus));
    const PPVirtualLoopbackSourceState *inputSource = pp_source_state_const(shared, kPPVirtualLoopbackSourceInput);
    const PPVirtualLoopbackSourceState *systemSource = pp_source_state_const(shared, kPPVirtualLoopbackSourceSystem);

    outStatus->inputWriterConnected = pp_source_is_connected(inputSource);
    outStatus->systemWriterConnected = pp_source_is_connected(systemSource);
    outStatus->inputSourceEnabled = pp_source_is_enabled(inputSource);
    outStatus->systemSourceEnabled = pp_source_is_enabled(systemSource);
    outStatus->writerConnected = outStatus->inputWriterConnected || outStatus->systemWriterConnected;
    outStatus->routerRunning = atomic_load_explicit(&shared->routerRunning, memory_order_acquire) != 0;
    outStatus->sampleRate = pp_mixed_sample_rate(shared);
    outStatus->channels = pp_mixed_channels(shared);
    outStatus->ringCapacityFrames = pp_mixed_capacity(shared);
    outStatus->preferredIOBufferFrames = pp_mixed_preferred_io_buffer(shared);
    outStatus->inputFramesWritten = inputSource
        ? atomic_load_explicit(&inputSource->framesWritten, memory_order_acquire)
        : 0;
    outStatus->inputFramesRead = inputSource
        ? atomic_load_explicit(&inputSource->framesRead, memory_order_acquire)
        : 0;
    outStatus->inputFramesAvailable = pp_source_frames_available(inputSource);
    outStatus->inputSourceGain = pp_source_gain(inputSource);
    outStatus->inputSourcePeak = pp_source_peak(inputSource);
    outStatus->systemFramesWritten = systemSource
        ? atomic_load_explicit(&systemSource->framesWritten, memory_order_acquire)
        : 0;
    outStatus->systemFramesRead = systemSource
        ? atomic_load_explicit(&systemSource->framesRead, memory_order_acquire)
        : 0;
    outStatus->systemFramesAvailable = pp_source_frames_available(systemSource);
    outStatus->systemSourceGain = pp_source_gain(systemSource);
    outStatus->systemSourcePeak = pp_source_peak(systemSource);
    outStatus->framesWritten = outStatus->inputFramesWritten + outStatus->systemFramesWritten;
    outStatus->framesRead = outStatus->inputFramesRead > outStatus->systemFramesRead
        ? outStatus->inputFramesRead
        : outStatus->systemFramesRead;
    outStatus->framesAvailable = outStatus->inputFramesAvailable > outStatus->systemFramesAvailable
        ? outStatus->inputFramesAvailable
        : outStatus->systemFramesAvailable;
    outStatus->overruns = (inputSource
        ? atomic_load_explicit(&inputSource->overruns, memory_order_acquire)
        : 0) +
        (systemSource
            ? atomic_load_explicit(&systemSource->overruns, memory_order_acquire)
            : 0);
    outStatus->underruns = (inputSource
        ? atomic_load_explicit(&inputSource->underruns, memory_order_acquire)
        : 0) +
        (systemSource
            ? atomic_load_explicit(&systemSource->underruns, memory_order_acquire)
            : 0);
    pp_copy_cstring(outStatus->requestedOutputDeviceUID,
                    sizeof(outStatus->requestedOutputDeviceUID),
                    shared->requestedOutputDeviceUID);
    pp_copy_cstring(outStatus->activeOutputDeviceUID,
                    sizeof(outStatus->activeOutputDeviceUID),
                    shared->activeOutputDeviceUID);
    pp_copy_cstring(outStatus->lastError,
                    sizeof(outStatus->lastError),
                    shared->lastError);
}

PPVirtualLoopbackWriterRef PPVirtualLoopbackTransport_OpenWriterForSource(PPVirtualLoopbackSourceID sourceID)
{
    if (!pp_is_valid_source_id(sourceID)) {
        pp_set_process_local_error("Invalid loopback source.");
        return NULL;
    }

    PPVirtualLoopbackWriterRef writer = (PPVirtualLoopbackWriterRef)calloc(1, sizeof(struct PPVirtualLoopbackWriter));
    if (!writer) {
        return NULL;
    }
    writer->sourceID = sourceID;

    int status = pp_map_shared_state(&writer->fd, &writer->shared);
    if (status != 0) {
        free(writer);
        return NULL;
    }

    pp_initialize_shared_state_if_needed(writer->shared);
    PPVirtualLoopbackSourceState *source = pp_source_state(writer->shared, writer->sourceID);
    if (!source) {
        pp_unmap_shared_state(writer->fd, writer->shared);
        free(writer);
        pp_set_process_local_error("Unable to resolve loopback source.");
        return NULL;
    }

    atomic_store_explicit(&source->writerConnected, 1, memory_order_release);
    return writer;
}

PPVirtualLoopbackWriterRef PPVirtualLoopbackTransport_OpenWriter(void)
{
    return PPVirtualLoopbackTransport_OpenWriterForSource(kPPVirtualLoopbackSourceInput);
}

void PPVirtualLoopbackTransport_CloseWriter(PPVirtualLoopbackWriterRef writer)
{
    if (!writer) {
        return;
    }

    if (writer->shared) {
        PPVirtualLoopbackSourceState *source = pp_source_state(writer->shared, writer->sourceID);
        if (source) {
            atomic_store_explicit(&source->writerConnected, 0, memory_order_release);
            atomic_store_explicit(&source->recentPeak, 0.0f, memory_order_release);
        }
    }
    pp_unmap_shared_state(writer->fd, writer->shared);
    free(writer);
}

int PPVirtualLoopbackTransport_ConfigureWriter(PPVirtualLoopbackWriterRef writer,
                                               double sampleRate,
                                               uint32_t channels,
                                               uint32_t ringCapacityFrames,
                                               uint32_t preferredIOBufferFrames)
{
    if (!writer || !writer->shared) {
        return -1;
    }

    PPVirtualLoopbackSourceState *source = pp_source_state(writer->shared, writer->sourceID);
    if (!source) {
        return -1;
    }

    if (channels == 0 || channels > PP_LOOPBACK_MAX_CHANNELS) {
        return -2;
    }

    if (ringCapacityFrames == 0 || ringCapacityFrames > PP_LOOPBACK_SHARED_CAPACITY_FRAMES) {
        ringCapacityFrames = PP_LOOPBACK_SHARED_CAPACITY_FRAMES;
    }

    if (preferredIOBufferFrames == 0) {
        preferredIOBufferFrames = 512;
    }

    source->sampleRate = sampleRate > 0.0 ? sampleRate : 48000.0;
    atomic_store_explicit(&source->channels, channels, memory_order_release);
    atomic_store_explicit(&source->ringCapacityFrames, ringCapacityFrames, memory_order_release);
    atomic_store_explicit(&source->preferredIOBufferFrames, preferredIOBufferFrames, memory_order_release);
    writer->hostTicksPerFrameEstimate = pp_default_host_ticks_per_frame(source->sampleRate);
    writer->lastWriteStartHostTime = 0;
    writer->lastWriteStartFrame = 0;
    writer->hasTimingHistory = false;
    atomic_store_explicit(&source->hostTicksPerFrameQ32,
                          pp_host_ticks_per_frame_to_q32(writer->hostTicksPerFrameEstimate),
                          memory_order_release);
    atomic_store_explicit(&source->latestEndHostTime, 0, memory_order_release);
    return 0;
}

size_t PPVirtualLoopbackTransport_WriteInterleaved(PPVirtualLoopbackWriterRef writer,
                                                   const float *interleavedSamples,
                                                   uint32_t frames,
                                                   uint32_t channels)
{
    return PPVirtualLoopbackTransport_WriteInterleavedWithTiming(writer,
                                                                 interleavedSamples,
                                                                 frames,
                                                                 channels,
                                                                 0,
                                                                 0.0);
}

size_t PPVirtualLoopbackTransport_WriteInterleavedWithTiming(PPVirtualLoopbackWriterRef writer,
                                                             const float *interleavedSamples,
                                                             uint32_t frames,
                                                             uint32_t channels,
                                                             uint64_t startHostTime,
                                                             double hostTicksPerFrame)
{
    if (!writer || !writer->shared || !interleavedSamples || frames == 0 || channels == 0) {
        return 0;
    }

    PPVirtualLoopbackSourceState *source = pp_source_state(writer->shared, writer->sourceID);
    if (!source) {
        return 0;
    }

    uint32_t sharedChannels = pp_effective_source_channels(source);
    uint32_t effectiveChannels = channels;
    if (effectiveChannels == 0 || effectiveChannels > sharedChannels) {
        effectiveChannels = sharedChannels;
    }

    uint32_t capacity = pp_effective_source_capacity(source);
    uint64_t baseFrame = atomic_load_explicit(&source->framesWritten, memory_order_relaxed);
    double resolvedHostTicksPerFrame = pp_writer_resolve_host_ticks_per_frame(writer,
                                                                              source,
                                                                              baseFrame,
                                                                              startHostTime,
                                                                              hostTicksPerFrame);
    uint64_t effectiveStartHostTime = startHostTime;
    if (effectiveStartHostTime == 0) {
        if (writer->hasTimingHistory && resolvedHostTicksPerFrame > 0.0) {
            uint64_t frameDelta = baseFrame - writer->lastWriteStartFrame;
            effectiveStartHostTime = writer->lastWriteStartHostTime +
                (uint64_t)llround((double)frameDelta * resolvedHostTicksPerFrame);
        } else {
            effectiveStartHostTime = AudioGetCurrentHostTime();
        }
    }
    float peak = 0.0f;

    for (uint32_t frame = 0; frame < frames; ++frame) {
        uint32_t slot = (uint32_t)((baseFrame + frame) % capacity);
        uint32_t baseIndex = slot * PP_LOOPBACK_MAX_CHANNELS;
        uint32_t sourceIndex = frame * channels;

        for (uint32_t ch = 0; ch < sharedChannels; ++ch) {
            float sample = 0.0f;
            if (ch < effectiveChannels) {
                sample = interleavedSamples[sourceIndex + ch];
                float magnitude = sample < 0.0f ? -sample : sample;
                if (magnitude > peak) {
                    peak = magnitude;
                }
            }
            source->interleavedSamples[baseIndex + ch] = sample;
        }
    }

    uint64_t newWritten = baseFrame + (uint64_t)frames;
    uint64_t readCount = atomic_load_explicit(&source->framesRead, memory_order_acquire);
    uint64_t minimumReadable = (baseFrame > capacity) ? (baseFrame - capacity) : 0;
    if (readCount < minimumReadable) {
        readCount = minimumReadable;
    }
    if (newWritten > readCount + capacity) {
        atomic_fetch_add_explicit(&source->overruns,
                                  (newWritten - readCount - capacity),
                                  memory_order_relaxed);
    }
    uint64_t endHostTime = effectiveStartHostTime;
    if (resolvedHostTicksPerFrame > 0.0) {
        endHostTime += (uint64_t)llround((double)frames * resolvedHostTicksPerFrame);
    }
    atomic_store_explicit(&source->hostTicksPerFrameQ32,
                          pp_host_ticks_per_frame_to_q32(resolvedHostTicksPerFrame),
                          memory_order_release);
    atomic_store_explicit(&source->latestEndHostTime, endHostTime, memory_order_release);
    atomic_store_explicit(&source->framesWritten, newWritten, memory_order_release);
    atomic_store_explicit(&source->recentPeak, peak, memory_order_release);
    writer->lastWriteStartHostTime = effectiveStartHostTime;
    writer->lastWriteStartFrame = baseFrame;
    writer->hasTimingHistory = true;
    return frames;
}

PPVirtualLoopbackReaderRef PPVirtualLoopbackTransport_OpenReader(void)
{
    PPVirtualLoopbackReaderRef reader = (PPVirtualLoopbackReaderRef)calloc(1, sizeof(struct PPVirtualLoopbackReader));
    if (!reader) {
        return NULL;
    }

    int status = pp_map_shared_state(&reader->fd, &reader->shared);
    if (status != 0) {
        free(reader);
        return NULL;
    }

    pp_initialize_shared_state_if_needed(reader->shared);
    pp_src_ensure_kernel_table_ready();
    for (uint32_t sourceIndex = 0; sourceIndex < kPPVirtualLoopbackSourceCount; ++sourceIndex) {
        pp_reader_reset_source_state(&reader->sources[sourceIndex]);
    }
    return reader;
}

void PPVirtualLoopbackTransport_CloseReader(PPVirtualLoopbackReaderRef reader)
{
    if (!reader) {
        return;
    }

    for (uint32_t sourceIndex = 0; sourceIndex < kPPVirtualLoopbackSourceCount; ++sourceIndex) {
        pp_reader_dispose_converter(&reader->sources[sourceIndex]);
    }
    pp_unmap_shared_state(reader->fd, reader->shared);
    free(reader);
}

int PPVirtualLoopbackTransport_GetStreamDescription(PPVirtualLoopbackReaderRef reader,
                                                    PPVirtualLoopbackStreamDescription *outDescription)
{
    if (!reader || !reader->shared || !outDescription) {
        return -1;
    }

    outDescription->sampleRate = pp_mixed_sample_rate(reader->shared);
    outDescription->channels = pp_mixed_channels(reader->shared);
    outDescription->ringCapacityFrames = pp_mixed_capacity(reader->shared);
    outDescription->preferredIOBufferFrames = pp_mixed_preferred_io_buffer(reader->shared);
    return 0;
}

size_t PPVirtualLoopbackTransport_ReadInterleaved(PPVirtualLoopbackReaderRef reader,
                                                  float *outSamples,
                                                  uint32_t maxFrames,
                                                  uint32_t maxChannels)
{
    return PPVirtualLoopbackTransport_ReadInterleavedWithTiming(reader,
                                                                outSamples,
                                                                maxFrames,
                                                                maxChannels,
                                                                0,
                                                                0.0,
                                                                0.0);
}

size_t PPVirtualLoopbackTransport_ReadInterleavedWithTiming(PPVirtualLoopbackReaderRef reader,
                                                            float *outSamples,
                                                            uint32_t maxFrames,
                                                            uint32_t maxChannels,
                                                            uint64_t outputStartHostTime,
                                                            double outputHostTicksPerFrame,
                                                            double outputSampleRate)
{
    if (!reader || !reader->shared || !outSamples || maxFrames == 0 || maxChannels == 0) {
        return 0;
    }

    PPVirtualLoopbackSharedState *shared = reader->shared;
    uint32_t channels = pp_mixed_channels(shared);
    uint32_t effectiveChannels = channels < maxChannels ? channels : maxChannels;
    size_t totalSamples = (size_t)maxFrames * effectiveChannels;
    memset(outSamples, 0, totalSamples * sizeof(float));

    if (outputHostTicksPerFrame <= 0.0) {
        outputHostTicksPerFrame = pp_default_host_ticks_per_frame(pp_mixed_sample_rate(shared));
    }
    if (outputHostTicksPerFrame <= 0.0) {
        outputHostTicksPerFrame = 1.0;
    }

    uint32_t contributingSources = 0;
    double nominalOutputSampleRate = outputSampleRate > 0.0
        ? outputSampleRate
        : pp_output_sample_rate_from_host_ticks_per_frame(outputHostTicksPerFrame,
                                                          pp_mixed_sample_rate(shared));

    for (uint32_t sourceIndex = 0; sourceIndex < kPPVirtualLoopbackSourceCount; ++sourceIndex) {
        PPVirtualLoopbackSourceState *source = &shared->sources[sourceIndex];
        PPVirtualLoopbackReaderSourceState *readerSource = &reader->sources[sourceIndex];
        bool sourceEnabled = pp_source_is_enabled(source);
        float sourceGain = pp_source_gain(source);
        uint32_t sourceChannels = pp_effective_source_channels(source);
        uint64_t written = atomic_load_explicit(&source->framesWritten, memory_order_acquire);
        double oldestReadableFrame = 0.0;
        double framesAhead = 0.0;

        bool ready = pp_reader_prepare_source(readerSource,
                                              source,
                                              written,
                                              maxFrames,
                                              &oldestReadableFrame,
                                              &framesAhead);
        if (!ready) {
            atomic_store_explicit(&source->framesRead,
                                  (uint64_t)readerSource->readCursorFrames,
                                  memory_order_release);
            continue;
        }

        double desiredReadPosition = written > readerSource->targetBufferFrames
            ? (double)(written - readerSource->targetBufferFrames)
            : oldestReadableFrame;
        double sourceHostTicksPerFrame = pp_effective_source_host_ticks_per_frame(source);
        if (sourceHostTicksPerFrame <= 0.0) {
            sourceHostTicksPerFrame = outputHostTicksPerFrame;
        }

        double bufferedFramesInTime = framesAhead;
        uint64_t latestEndHostTime = atomic_load_explicit(&source->latestEndHostTime, memory_order_acquire);
        if (outputStartHostTime > 0 && latestEndHostTime > 0 && sourceHostTicksPerFrame > 0.0) {
            if (latestEndHostTime >= outputStartHostTime) {
                bufferedFramesInTime = (double)(latestEndHostTime - outputStartHostTime) / sourceHostTicksPerFrame;
            } else {
                bufferedFramesInTime = -((double)(outputStartHostTime - latestEndHostTime) / sourceHostTicksPerFrame);
            }
        }

        double baseRateRatio = outputHostTicksPerFrame / sourceHostTicksPerFrame;
        double phaseErrorFrames = bufferedFramesInTime - (double)readerSource->targetBufferFrames;
        double equalRatePhaseErrorFrames = framesAhead - (double)readerSource->targetBufferFrames;
        double targetRateRatio = pp_reader_target_rate_ratio(baseRateRatio,
                                                             phaseErrorFrames,
                                                             readerSource->targetBufferFrames);
        double sourceSampleRate = pp_effective_source_sample_rate(source);
        bool useBlockSRC = pp_should_use_block_src(sourceSampleRate, nominalOutputSampleRate);
        bool useEqualRateFastPath = !useBlockSRC &&
            pp_should_use_equal_rate_fast_path(sourceSampleRate,
                                               nominalOutputSampleRate,
                                               equalRatePhaseErrorFrames,
                                               readerSource->targetBufferFrames);

        if (!readerSource->primed ||
            readerSource->readCursorFrames < oldestReadableFrame ||
            readerSource->readCursorFrames > (double)written) {
            readerSource->readCursorFrames = desiredReadPosition;
        } else {
            double cursorError = desiredReadPosition - readerSource->readCursorFrames;
            if (fabs(cursorError) > (double)readerSource->targetBufferFrames) {
                readerSource->readCursorFrames = desiredReadPosition;
            } else if (!useEqualRateFastPath) {
                readerSource->readCursorFrames += cursorError * 0.002;
            }
        }

        if (readerSource->readRateRatio <= 0.0) {
            readerSource->readRateRatio = useEqualRateFastPath ? 1.0 : baseRateRatio;
        }
        if (!useEqualRateFastPath) {
            readerSource->readRateRatio = (readerSource->readRateRatio * 0.995) + (targetRateRatio * 0.005);
        } else {
            readerSource->readRateRatio = 1.0;
        }

        double readPosition = readerSource->readCursorFrames;
        uint32_t framesMixed = 0;

        if (useBlockSRC) {
            framesMixed = pp_reader_mix_source_via_block_src(readerSource,
                                                             source,
                                                             (uint64_t)oldestReadableFrame,
                                                             written,
                                                             sourceChannels,
                                                             effectiveChannels,
                                                             sourceSampleRate,
                                                             nominalOutputSampleRate,
                                                             maxFrames,
                                                             sourceEnabled ? sourceGain : 0.0f,
                                                             outSamples);
            readPosition = readerSource->readCursorFrames;
            if (framesMixed < maxFrames && sourceEnabled && sourceGain > 0.0f && readerSource->primed) {
                atomic_fetch_add_explicit(&source->underruns,
                                          (uint64_t)(maxFrames - framesMixed),
                                          memory_order_relaxed);
            }
        } else if (useEqualRateFastPath) {
            framesMixed = pp_reader_mix_source_via_direct_copy(readerSource,
                                                               source,
                                                               (uint64_t)oldestReadableFrame,
                                                               written,
                                                               sourceChannels,
                                                               effectiveChannels,
                                                               maxFrames,
                                                               sourceGain,
                                                               sourceEnabled,
                                                               equalRatePhaseErrorFrames,
                                                               outSamples);
            readPosition = readerSource->readCursorFrames;
            if (framesMixed < maxFrames && sourceEnabled && sourceGain > 0.0f && readerSource->primed) {
                atomic_fetch_add_explicit(&source->underruns,
                                          (uint64_t)(maxFrames - framesMixed),
                                          memory_order_relaxed);
            }
        } else {
            for (uint32_t frame = 0; frame < maxFrames; ++frame) {
                double samplePosition = readPosition;
                if (samplePosition < oldestReadableFrame) {
                    samplePosition = oldestReadableFrame;
                }

                if (samplePosition + 1.0 >= (double)written) {
                    if (sourceEnabled && sourceGain > 0.0f && readerSource->primed) {
                        atomic_fetch_add_explicit(&source->underruns,
                                                  (uint64_t)(maxFrames - frame),
                                                  memory_order_relaxed);
                    }
                    break;
                }

                if (sourceEnabled && sourceGain > 0.0f) {
                    uint32_t destIndex = frame * effectiveChannels;
                    for (uint32_t ch = 0; ch < effectiveChannels; ++ch) {
                        float sample = pp_reader_sample_source_at_position(source,
                                                                          oldestReadableFrame,
                                                                          written,
                                                                          sourceChannels,
                                                                          ch,
                                                                          samplePosition,
                                                                          readerSource->readRateRatio);
                        outSamples[destIndex + ch] += sample * sourceGain;
                    }
                }

                readPosition += readerSource->readRateRatio;
                framesMixed = frame + 1;
            }
        }

        double maximumReadableCursor = written > 2 ? (double)(written - 2) : 0.0;
        if (readPosition < oldestReadableFrame) {
            readPosition = oldestReadableFrame;
        }
        if (readPosition > maximumReadableCursor) {
            readPosition = maximumReadableCursor;
        }
        readerSource->readCursorFrames = readPosition;

        uint64_t safeReadFrame = 0;
        if (readPosition > 2.0) {
            safeReadFrame = (uint64_t)floor(readPosition - 2.0);
        }
        if ((double)safeReadFrame < oldestReadableFrame) {
            safeReadFrame = (uint64_t)oldestReadableFrame;
        }
        if (safeReadFrame > written) {
            safeReadFrame = written;
        }
        atomic_store_explicit(&source->framesRead,
                              safeReadFrame,
                              memory_order_release);

        if (sourceEnabled && sourceGain > 0.0f && framesMixed > 0) {
            contributingSources += 1;
        }
    }

    if (contributingSources == 0) {
        return 0;
    }

    float mixGain = contributingSources > 1 ? (1.0f / (float)contributingSources) : 1.0f;
    mixGain *= PP_LOOPBACK_OUTPUT_HEADROOM;
    for (size_t sampleIndex = 0; sampleIndex < (size_t)maxFrames * effectiveChannels; ++sampleIndex) {
        float mixedSample = outSamples[sampleIndex] * mixGain;
        outSamples[sampleIndex] = pp_clamp_sample(pp_soft_limit_sample(mixedSample));
    }

    return maxFrames;
}

void PPVirtualLoopbackTransport_GetStatus(PPVirtualLoopbackStatus *outStatus)
{
    if (!outStatus) {
        return;
    }

    int fd = -1;
    PPVirtualLoopbackSharedState *shared = NULL;
    if (pp_map_shared_state(&fd, &shared) != 0) {
        memset(outStatus, 0, sizeof(*outStatus));
        return;
    }

    pp_initialize_shared_state_if_needed(shared);
    pp_fill_status_from_shared(shared, outStatus);
    pp_unmap_shared_state(fd, shared);
}

int PPVirtualLoopbackTransport_SetRequestedOutputDeviceUID(const char *uidCString)
{
    int fd = -1;
    PPVirtualLoopbackSharedState *shared = NULL;
    if (pp_map_shared_state(&fd, &shared) != 0) {
        return -1;
    }

    pp_initialize_shared_state_if_needed(shared);
    pp_copy_cstring(shared->requestedOutputDeviceUID,
                    sizeof(shared->requestedOutputDeviceUID),
                    uidCString);
    pp_unmap_shared_state(fd, shared);
    return 0;
}

int PPVirtualLoopbackTransport_CopyRequestedOutputDeviceUID(char *outUID, uint32_t maxLen)
{
    if (!outUID || maxLen == 0) {
        return -1;
    }

    PPVirtualLoopbackStatus status;
    PPVirtualLoopbackTransport_GetStatus(&status);
    pp_copy_cstring(outUID, maxLen, status.requestedOutputDeviceUID);
    return 0;
}

int PPVirtualLoopbackTransport_CopyLastError(char *outError, uint32_t maxLen)
{
    if (!outError || maxLen == 0) {
        return -1;
    }

    int fd = -1;
    PPVirtualLoopbackSharedState *shared = NULL;
    if (pp_map_shared_state(&fd, &shared) != 0) {
        pp_copy_cstring(outError, maxLen, gPPProcessLocalLastError);
        return 0;
    }

    pp_initialize_shared_state_if_needed(shared);
    pp_copy_cstring(outError, maxLen, shared->lastError);
    pp_unmap_shared_state(fd, shared);
    return 0;
}

void PPVirtualLoopbackTransport_SetRouterState(bool isRunning, const char *activeOutputDeviceUID)
{
    int fd = -1;
    PPVirtualLoopbackSharedState *shared = NULL;
    if (pp_map_shared_state(&fd, &shared) != 0) {
        return;
    }

    pp_initialize_shared_state_if_needed(shared);
    atomic_store_explicit(&shared->routerRunning, isRunning ? 1u : 0u, memory_order_release);
    pp_copy_cstring(shared->activeOutputDeviceUID,
                    sizeof(shared->activeOutputDeviceUID),
                    activeOutputDeviceUID);
    pp_unmap_shared_state(fd, shared);
}

void PPVirtualLoopbackTransport_SetLastError(const char *errorText)
{
    pp_set_process_local_error(errorText ? errorText : "");

    int fd = -1;
    PPVirtualLoopbackSharedState *shared = NULL;
    if (pp_map_shared_state(&fd, &shared) != 0) {
        return;
    }

    pp_initialize_shared_state_if_needed(shared);
    pp_copy_cstring(shared->lastError, sizeof(shared->lastError), errorText);
    pp_unmap_shared_state(fd, shared);
}

int PPVirtualLoopbackTransport_SetSourceEnabled(PPVirtualLoopbackSourceID sourceID, bool isEnabled)
{
    if (!pp_is_valid_source_id(sourceID)) {
        return -1;
    }

    int fd = -1;
    PPVirtualLoopbackSharedState *shared = NULL;
    if (pp_map_shared_state(&fd, &shared) != 0) {
        return -2;
    }

    pp_initialize_shared_state_if_needed(shared);
    PPVirtualLoopbackSourceState *source = pp_source_state(shared, sourceID);
    if (!source) {
        pp_unmap_shared_state(fd, shared);
        return -3;
    }

    atomic_store_explicit(&source->sourceEnabled, isEnabled ? 1u : 0u, memory_order_release);
    if (!isEnabled) {
        atomic_store_explicit(&source->recentPeak, 0.0f, memory_order_release);
    }
    pp_unmap_shared_state(fd, shared);
    return 0;
}

int PPVirtualLoopbackTransport_SetSourceGain(PPVirtualLoopbackSourceID sourceID, float linearGain)
{
    if (!pp_is_valid_source_id(sourceID)) {
        return -1;
    }

    if (linearGain < 0.0f) {
        linearGain = 0.0f;
    }
    if (linearGain > 4.0f) {
        linearGain = 4.0f;
    }

    int fd = -1;
    PPVirtualLoopbackSharedState *shared = NULL;
    if (pp_map_shared_state(&fd, &shared) != 0) {
        return -2;
    }

    pp_initialize_shared_state_if_needed(shared);
    PPVirtualLoopbackSourceState *source = pp_source_state(shared, sourceID);
    if (!source) {
        pp_unmap_shared_state(fd, shared);
        return -3;
    }

    atomic_store_explicit(&source->sourceGain, linearGain, memory_order_release);
    pp_unmap_shared_state(fd, shared);
    return 0;
}
