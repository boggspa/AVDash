/**
 * @file MixerProcess.c
 * @brief Core audio mixing engine
 *
 * @author Chris Izatt
 * @date 2025-07-23
 *
 * @details Implements Mixer_ProcessBlock which continuously:
 * 1. Reads audio from input ring buffers
 * 2. Applies per-channel processing (gain, fader, pan, mute)
 * 3. Mixes inputs to outputs
 * 4. Writes to output ring buffers
 *
 * @note Early or premature calls with out-of-range indices emit warnings
 * and return safely without aborting.
 */

#include "Mixer.h"
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>

extern bool MixerRoute_HasAnyRoutes(void);
extern bool MixerRoute_HasExplicitRoutesForOutput(uint32_t outputDeviceID,
                                                  int32_t outputChannelIndex);
extern bool MixerRoute_IsActive(uint32_t inputDeviceID,
                                int32_t inputChannelIndex,
                                uint32_t outputDeviceID,
                                int32_t outputChannelIndex);

static pthread_t gMixerProcessingThread;
static pthread_mutex_t gMixerProcessingThreadLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(bool) gMixerProcessingThreadShouldStop = false;
static _Atomic(bool) gMixerProcessingThreadRunning = false;
static bool gMixerProcessingThreadCreated = false;
static pthread_once_t gMixerClockTimebaseOnce = PTHREAD_ONCE_INIT;
static mach_timebase_info_data_t gMixerClockTimebase = {0, 0};

typedef struct {
    MixerEQConfig slots[2];
    _Atomic(uint32_t) publishedSlot;
    _Atomic(uint32_t) publishedVersion;
} MixerEQShadowState;

typedef struct {
    MixerDynamicsConfig slots[2];
    _Atomic(uint32_t) publishedSlot;
    _Atomic(uint32_t) publishedVersion;
} MixerDynamicsShadowState;

static MixerEQShadowState gChannelEQShadowStates[MIXER_MAX_GLOBAL_CHANNELS];
static MixerDynamicsShadowState gChannelDynamicsShadowStates[MIXER_MAX_GLOBAL_CHANNELS];
static uint32_t gChannelEQAppliedVersions[MIXER_MAX_GLOBAL_CHANNELS];
static uint32_t gChannelDynamicsAppliedVersions[MIXER_MAX_GLOBAL_CHANNELS];

static MixerEQShadowState gAuxSendEQShadowStates[MIXER_MAX_AUX_SEND_BUSES];
static MixerDynamicsShadowState gAuxSendDynamicsShadowStates[MIXER_MAX_AUX_SEND_BUSES];
static uint32_t gAuxSendEQAppliedVersions[MIXER_MAX_AUX_SEND_BUSES];
static uint32_t gAuxSendDynamicsAppliedVersions[MIXER_MAX_AUX_SEND_BUSES];

static MixerEQShadowState gFXSendEQShadowStates[MIXER_MAX_FX_SEND_BUSES];
static MixerDynamicsShadowState gFXSendDynamicsShadowStates[MIXER_MAX_FX_SEND_BUSES];
static uint32_t gFXSendEQAppliedVersions[MIXER_MAX_FX_SEND_BUSES];
static uint32_t gFXSendDynamicsAppliedVersions[MIXER_MAX_FX_SEND_BUSES];

static MixerEQShadowState gAuxReturnEQShadowStates[MIXER_MAX_AUX_RETURN_BUSES];
static MixerDynamicsShadowState gAuxReturnDynamicsShadowStates[MIXER_MAX_AUX_RETURN_BUSES];
static uint32_t gAuxReturnEQAppliedVersions[MIXER_MAX_AUX_RETURN_BUSES];
static uint32_t gAuxReturnDynamicsAppliedVersions[MIXER_MAX_AUX_RETURN_BUSES];

static MixerEQShadowState gFXReturnEQShadowStates[MIXER_MAX_FX_RETURN_BUSES];
static MixerDynamicsShadowState gFXReturnDynamicsShadowStates[MIXER_MAX_FX_RETURN_BUSES];
static uint32_t gFXReturnEQAppliedVersions[MIXER_MAX_FX_RETURN_BUSES];
static uint32_t gFXReturnDynamicsAppliedVersions[MIXER_MAX_FX_RETURN_BUSES];

static void Mixer_ResetEQShadowStates(MixerEQShadowState *states, uint32_t count, uint32_t *appliedVersions) {
    if (!states || !appliedVersions) {
        return;
    }

    memset(states, 0, sizeof(MixerEQShadowState) * count);
    memset(appliedVersions, 0, sizeof(uint32_t) * count);
    for (uint32_t index = 0; index < count; index++) {
        atomic_store_explicit(&states[index].publishedSlot, 0, memory_order_relaxed);
        atomic_store_explicit(&states[index].publishedVersion, 0, memory_order_relaxed);
    }
}

static void Mixer_ResetDynamicsShadowStates(MixerDynamicsShadowState *states,
                                            uint32_t count,
                                            uint32_t *appliedVersions) {
    if (!states || !appliedVersions) {
        return;
    }

    memset(states, 0, sizeof(MixerDynamicsShadowState) * count);
    memset(appliedVersions, 0, sizeof(uint32_t) * count);
    for (uint32_t index = 0; index < count; index++) {
        atomic_store_explicit(&states[index].publishedSlot, 0, memory_order_relaxed);
        atomic_store_explicit(&states[index].publishedVersion, 0, memory_order_relaxed);
    }
}

void MixerConfigShadow_ResetAll(void) {
    Mixer_ResetEQShadowStates(gChannelEQShadowStates,
                              MIXER_MAX_GLOBAL_CHANNELS,
                              gChannelEQAppliedVersions);
    Mixer_ResetDynamicsShadowStates(gChannelDynamicsShadowStates,
                                    MIXER_MAX_GLOBAL_CHANNELS,
                                    gChannelDynamicsAppliedVersions);

    Mixer_ResetEQShadowStates(gAuxSendEQShadowStates,
                              MIXER_MAX_AUX_SEND_BUSES,
                              gAuxSendEQAppliedVersions);
    Mixer_ResetDynamicsShadowStates(gAuxSendDynamicsShadowStates,
                                    MIXER_MAX_AUX_SEND_BUSES,
                                    gAuxSendDynamicsAppliedVersions);

    Mixer_ResetEQShadowStates(gFXSendEQShadowStates,
                              MIXER_MAX_FX_SEND_BUSES,
                              gFXSendEQAppliedVersions);
    Mixer_ResetDynamicsShadowStates(gFXSendDynamicsShadowStates,
                                    MIXER_MAX_FX_SEND_BUSES,
                                    gFXSendDynamicsAppliedVersions);

    Mixer_ResetEQShadowStates(gAuxReturnEQShadowStates,
                              MIXER_MAX_AUX_RETURN_BUSES,
                              gAuxReturnEQAppliedVersions);
    Mixer_ResetDynamicsShadowStates(gAuxReturnDynamicsShadowStates,
                                    MIXER_MAX_AUX_RETURN_BUSES,
                                    gAuxReturnDynamicsAppliedVersions);

    Mixer_ResetEQShadowStates(gFXReturnEQShadowStates,
                              MIXER_MAX_FX_RETURN_BUSES,
                              gFXReturnEQAppliedVersions);
    Mixer_ResetDynamicsShadowStates(gFXReturnDynamicsShadowStates,
                                    MIXER_MAX_FX_RETURN_BUSES,
                                    gFXReturnDynamicsAppliedVersions);
}

static void Mixer_PublishEQShadowState(MixerEQShadowState *state, MixerEQConfig config) {
    if (!state) {
        return;
    }

    uint32_t currentSlot = atomic_load_explicit(&state->publishedSlot, memory_order_relaxed) & 1U;
    uint32_t nextSlot = currentSlot ^ 1U;
    state->slots[nextSlot] = config;
    atomic_store_explicit(&state->publishedSlot, nextSlot, memory_order_release);
    atomic_fetch_add_explicit(&state->publishedVersion, 1U, memory_order_release);
}

static void Mixer_PublishDynamicsShadowState(MixerDynamicsShadowState *state, MixerDynamicsConfig config) {
    if (!state) {
        return;
    }

    uint32_t currentSlot = atomic_load_explicit(&state->publishedSlot, memory_order_relaxed) & 1U;
    uint32_t nextSlot = currentSlot ^ 1U;
    state->slots[nextSlot] = config;
    atomic_store_explicit(&state->publishedSlot, nextSlot, memory_order_release);
    atomic_fetch_add_explicit(&state->publishedVersion, 1U, memory_order_release);
}

void MixerConfigShadow_PublishChannelEQ(uint32_t globalChannelIndex, MixerEQConfig config) {
    if (globalChannelIndex >= MIXER_MAX_GLOBAL_CHANNELS) {
        return;
    }
    Mixer_PublishEQShadowState(&gChannelEQShadowStates[globalChannelIndex], config);
}

void MixerConfigShadow_PublishChannelDynamics(uint32_t globalChannelIndex, MixerDynamicsConfig config) {
    if (globalChannelIndex >= MIXER_MAX_GLOBAL_CHANNELS) {
        return;
    }
    Mixer_PublishDynamicsShadowState(&gChannelDynamicsShadowStates[globalChannelIndex], config);
}

static MixerEQShadowState *Mixer_EQShadowStateForVirtualBus(uint32_t busType, uint32_t busIndex) {
    switch ((MixerVirtualBusType)busType) {
    case MIXER_VIRTUAL_BUS_AUX_SEND:
        return busIndex < MIXER_MAX_AUX_SEND_BUSES ? &gAuxSendEQShadowStates[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_SEND:
        return busIndex < MIXER_MAX_FX_SEND_BUSES ? &gFXSendEQShadowStates[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_AUX_RETURN:
        return busIndex < MIXER_MAX_AUX_RETURN_BUSES ? &gAuxReturnEQShadowStates[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_RETURN:
        return busIndex < MIXER_MAX_FX_RETURN_BUSES ? &gFXReturnEQShadowStates[busIndex] : NULL;
    default:
        return NULL;
    }
}

static MixerDynamicsShadowState *Mixer_DynamicsShadowStateForVirtualBus(uint32_t busType, uint32_t busIndex) {
    switch ((MixerVirtualBusType)busType) {
    case MIXER_VIRTUAL_BUS_AUX_SEND:
        return busIndex < MIXER_MAX_AUX_SEND_BUSES ? &gAuxSendDynamicsShadowStates[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_SEND:
        return busIndex < MIXER_MAX_FX_SEND_BUSES ? &gFXSendDynamicsShadowStates[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_AUX_RETURN:
        return busIndex < MIXER_MAX_AUX_RETURN_BUSES ? &gAuxReturnDynamicsShadowStates[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_RETURN:
        return busIndex < MIXER_MAX_FX_RETURN_BUSES ? &gFXReturnDynamicsShadowStates[busIndex] : NULL;
    default:
        return NULL;
    }
}

void MixerConfigShadow_PublishVirtualBusEQ(uint32_t busType, uint32_t busIndex, MixerEQConfig config) {
    MixerEQShadowState *state = Mixer_EQShadowStateForVirtualBus(busType, busIndex);
    Mixer_PublishEQShadowState(state, config);
}

void MixerConfigShadow_PublishVirtualBusDynamics(uint32_t busType, uint32_t busIndex, MixerDynamicsConfig config) {
    MixerDynamicsShadowState *state = Mixer_DynamicsShadowStateForVirtualBus(busType, busIndex);
    Mixer_PublishDynamicsShadowState(state, config);
}

static bool Mixer_CopyLatestEQShadow(MixerEQShadowState *state,
                                     uint32_t *appliedVersion,
                                     MixerEQConfig *config) {
    if (!state || !appliedVersion || !config) {
        return false;
    }

    uint32_t publishedVersion = atomic_load_explicit(&state->publishedVersion, memory_order_acquire);
    if (publishedVersion == *appliedVersion) {
        return false;
    }

    uint32_t slot = atomic_load_explicit(&state->publishedSlot, memory_order_acquire) & 1U;
    *config = state->slots[slot];

    uint32_t confirmedVersion = atomic_load_explicit(&state->publishedVersion, memory_order_acquire);
    if (confirmedVersion != publishedVersion) {
        slot = atomic_load_explicit(&state->publishedSlot, memory_order_acquire) & 1U;
        *config = state->slots[slot];
        publishedVersion = confirmedVersion;
    }

    *appliedVersion = publishedVersion;
    return true;
}

static bool Mixer_CopyLatestDynamicsShadow(MixerDynamicsShadowState *state,
                                           uint32_t *appliedVersion,
                                           MixerDynamicsConfig *config) {
    if (!state || !appliedVersion || !config) {
        return false;
    }

    uint32_t publishedVersion = atomic_load_explicit(&state->publishedVersion, memory_order_acquire);
    if (publishedVersion == *appliedVersion) {
        return false;
    }

    uint32_t slot = atomic_load_explicit(&state->publishedSlot, memory_order_acquire) & 1U;
    *config = state->slots[slot];

    uint32_t confirmedVersion = atomic_load_explicit(&state->publishedVersion, memory_order_acquire);
    if (confirmedVersion != publishedVersion) {
        slot = atomic_load_explicit(&state->publishedSlot, memory_order_acquire) & 1U;
        *config = state->slots[slot];
        publishedVersion = confirmedVersion;
    }

    *appliedVersion = publishedVersion;
    return true;
}

static void Mixer_SynchronizeChannelShadowConfigs(MixerChannel *channel) {
    if (!channel || channel->globalChannelIndex >= MIXER_MAX_GLOBAL_CHANNELS) {
        return;
    }

    MixerEQConfig eqConfig;
    if (Mixer_CopyLatestEQShadow(&gChannelEQShadowStates[channel->globalChannelIndex],
                                 &gChannelEQAppliedVersions[channel->globalChannelIndex],
                                 &eqConfig)) {
        channel->eqConfig = eqConfig;
    }

    MixerDynamicsConfig dynamicsConfig;
    if (Mixer_CopyLatestDynamicsShadow(&gChannelDynamicsShadowStates[channel->globalChannelIndex],
                                       &gChannelDynamicsAppliedVersions[channel->globalChannelIndex],
                                       &dynamicsConfig)) {
        channel->dynamicsConfig = dynamicsConfig;
    }
}

static uint32_t *Mixer_EQAppliedVersionForVirtualBus(uint32_t busType, uint32_t busIndex) {
    switch ((MixerVirtualBusType)busType) {
    case MIXER_VIRTUAL_BUS_AUX_SEND:
        return busIndex < MIXER_MAX_AUX_SEND_BUSES ? &gAuxSendEQAppliedVersions[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_SEND:
        return busIndex < MIXER_MAX_FX_SEND_BUSES ? &gFXSendEQAppliedVersions[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_AUX_RETURN:
        return busIndex < MIXER_MAX_AUX_RETURN_BUSES ? &gAuxReturnEQAppliedVersions[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_RETURN:
        return busIndex < MIXER_MAX_FX_RETURN_BUSES ? &gFXReturnEQAppliedVersions[busIndex] : NULL;
    default:
        return NULL;
    }
}

static uint32_t *Mixer_DynamicsAppliedVersionForVirtualBus(uint32_t busType, uint32_t busIndex) {
    switch ((MixerVirtualBusType)busType) {
    case MIXER_VIRTUAL_BUS_AUX_SEND:
        return busIndex < MIXER_MAX_AUX_SEND_BUSES ? &gAuxSendDynamicsAppliedVersions[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_SEND:
        return busIndex < MIXER_MAX_FX_SEND_BUSES ? &gFXSendDynamicsAppliedVersions[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_AUX_RETURN:
        return busIndex < MIXER_MAX_AUX_RETURN_BUSES ? &gAuxReturnDynamicsAppliedVersions[busIndex] : NULL;
    case MIXER_VIRTUAL_BUS_FX_RETURN:
        return busIndex < MIXER_MAX_FX_RETURN_BUSES ? &gFXReturnDynamicsAppliedVersions[busIndex] : NULL;
    default:
        return NULL;
    }
}

static void Mixer_SynchronizeVirtualBusShadowConfigs(MixerChannel *channel,
                                                     uint32_t busType,
                                                     uint32_t busIndex) {
    if (!channel) {
        return;
    }

    MixerEQShadowState *eqState = Mixer_EQShadowStateForVirtualBus(busType, busIndex);
    uint32_t *eqAppliedVersion = Mixer_EQAppliedVersionForVirtualBus(busType, busIndex);
    MixerEQConfig eqConfig;
    if (Mixer_CopyLatestEQShadow(eqState, eqAppliedVersion, &eqConfig)) {
        channel->eqConfig = eqConfig;
    }

    MixerDynamicsShadowState *dynamicsState = Mixer_DynamicsShadowStateForVirtualBus(busType, busIndex);
    uint32_t *dynamicsAppliedVersion = Mixer_DynamicsAppliedVersionForVirtualBus(busType, busIndex);
    MixerDynamicsConfig dynamicsConfig;
    if (Mixer_CopyLatestDynamicsShadow(dynamicsState, dynamicsAppliedVersion, &dynamicsConfig)) {
        channel->dynamicsConfig = dynamicsConfig;
    }
}

static void MixerClock_InitializeTimebase(void) {
    mach_timebase_info(&gMixerClockTimebase);
    if (gMixerClockTimebase.numer == 0 || gMixerClockTimebase.denom == 0) {
        gMixerClockTimebase.numer = 1;
        gMixerClockTimebase.denom = 1;
    }
}

static uint64_t MixerClock_NanosecondsToAbsolute(uint64_t nanoseconds) {
    pthread_once(&gMixerClockTimebaseOnce, MixerClock_InitializeTimebase);

    long double absolute = ((long double)nanoseconds * (long double)gMixerClockTimebase.denom)
        / (long double)gMixerClockTimebase.numer;
    if (absolute < 1.0L) {
        return 1;
    }
    if (absolute > (long double)UINT64_MAX) {
        return UINT64_MAX;
    }
    return (uint64_t)llroundl(absolute);
}

static uint64_t MixerClock_IntervalAbsoluteForMixer(const Mixer *mixer) {
    double sampleRate = 48000.0;
    double bufferFrames = 128.0;

    if (mixer && mixer->sampleRate > 0 && mixer->bufferFrames > 0) {
        sampleRate = (double)mixer->sampleRate;
        bufferFrames = (double)mixer->bufferFrames;
    }

    uint64_t intervalNanoseconds = (uint64_t)llround((bufferFrames / sampleRate) * 1000000000.0);
    if (intervalNanoseconds < 250000ULL) {
        intervalNanoseconds = 250000ULL;
    }

    return MixerClock_NanosecondsToAbsolute(intervalNanoseconds);
}

static void MixerClock_ConfigureRealtimeScheduling(uint64_t periodAbsolute) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    if (periodAbsolute == 0 || periodAbsolute > (uint64_t)UINT32_MAX) {
        return;
    }

    uint32_t period = (uint32_t)periodAbsolute;
    uint32_t computation = period / 3U;
    if (computation < 1U) {
        computation = 1U;
    }
    uint32_t constraint = period;
    if (constraint <= computation) {
        constraint = computation + 1U;
    }

    thread_time_constraint_policy_data_t policy;
    memset(&policy, 0, sizeof(policy));
    policy.period = period;
    policy.computation = computation;
    policy.constraint = constraint;
    policy.preemptible = 1;

    thread_port_t thread = pthread_mach_thread_np(pthread_self());
    (void)thread_policy_set(thread,
                            THREAD_TIME_CONSTRAINT_POLICY,
                            (thread_policy_t)&policy,
                            THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static void *MixerProcessingThreadMain(void *context) {
    (void)context;
    pthread_setname_np("com.avcmeter.mixer.clock");

    uint64_t intervalAbsolute = MixerClock_IntervalAbsoluteForMixer(GetGlobalMixerPointer());
    if (intervalAbsolute == 0) {
        intervalAbsolute = MixerClock_NanosecondsToAbsolute(1000000ULL);
    }
    MixerClock_ConfigureRealtimeScheduling(intervalAbsolute);

    atomic_store_explicit(&gMixerProcessingThreadRunning, true, memory_order_release);

    uint64_t nextWakeDeadline = mach_absolute_time();

    while (!atomic_load_explicit(&gMixerProcessingThreadShouldStop, memory_order_acquire)) {
        Mixer *mixer = GetGlobalMixerPointer();
        if (!mixer) {
            break;
        }

        uint64_t updatedInterval = MixerClock_IntervalAbsoluteForMixer(mixer);
        if (updatedInterval != intervalAbsolute && updatedInterval != 0) {
            intervalAbsolute = updatedInterval;
            MixerClock_ConfigureRealtimeScheduling(intervalAbsolute);
        }

        (void)Mixer_ProcessBlock();

        nextWakeDeadline += intervalAbsolute;
        uint64_t now = mach_absolute_time();
        if (now >= nextWakeDeadline) {
            if (intervalAbsolute > 0) {
                uint64_t intervalsLate = ((now - nextWakeDeadline) / intervalAbsolute) + 1;
                if (intervalsLate > 4) {
                    nextWakeDeadline = now + intervalAbsolute;
                } else {
                    nextWakeDeadline += (intervalsLate * intervalAbsolute);
                }
            } else {
                nextWakeDeadline = now;
            }
            continue;
        }

        (void)mach_wait_until(nextWakeDeadline);
    }

    atomic_store_explicit(&gMixerProcessingThreadRunning, false, memory_order_release);
    pthread_mutex_lock(&gMixerProcessingThreadLock);
    gMixerProcessingThreadCreated = false;
    pthread_mutex_unlock(&gMixerProcessingThreadLock);
    return NULL;
}

static int Mixer_EnsureOutputBuffer(MixerChannel *channel, uint32_t bufferFrames) {
    if (channel->outputBuffer != NULL) {
        return 0;
    }

    channel->outputBuffer = (float *)calloc(bufferFrames, sizeof(float));
    if (channel->outputBuffer == NULL) {
        printf("[Mixer] ERROR: Failed to allocate output buffer for device=%u channel=%u\n",
               channel->deviceID, channel->deviceChannelIndex);
        return -1;
    }

    return 0;
}

static void Mixer_UpdateBusMeterArrays(float **buffers,
                                       uint32_t busCount,
                                       uint32_t bufferFrames,
                                       float *peakValues,
                                       float *rmsValues) {
    if (!buffers || !peakValues || !rmsValues || bufferFrames == 0) {
        return;
    }

    for (uint32_t busIndex = 0; busIndex < busCount; busIndex++) {
        float peak = 0.0f;
        double sumSquares = 0.0;

        for (uint32_t frame = 0; frame < bufferFrames; frame++) {
            float sample = buffers[busIndex][frame];
            float magnitude = fabsf(sample);
            if (magnitude > peak) {
                peak = magnitude;
            }
            sumSquares += (double)sample * (double)sample;
        }

        peakValues[busIndex] = peak;
        rmsValues[busIndex] = sqrtf((float)(sumSquares / (double)bufferFrames));
    }
}

static float Mixer_ClampFloat(float value, float minimum, float maximum) {
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static double Mixer_ClampDouble(double value, double minimum, double maximum) {
    if (value < minimum) {
        return minimum;
    }
    if (value > maximum) {
        return maximum;
    }
    return value;
}

static void Mixer_SetFilterInactive(MixerBiquadState *state) {
    if (!state) {
        return;
    }
    state->active = 0;
}

static void Mixer_SetFilterChainInactive(MixerBiquadState *states, uint32_t stageCount) {
    if (!states) {
        return;
    }
    for (uint32_t stage = 0; stage < stageCount; stage++) {
        Mixer_SetFilterInactive(&states[stage]);
    }
}

static uint32_t Mixer_EQStageCountForSlope(uint32_t slope) {
    switch (slope) {
    case MIXER_EQ_SLOPE_DB24:
        return 2;
    case MIXER_EQ_SLOPE_DB48:
        return 4;
    default:
        return 1;
    }
}

static double Mixer_EQSlopeGainScale(uint32_t slope) {
    switch (slope) {
    case MIXER_EQ_SLOPE_DB6:
        return 0.5;
    default:
        return 1.0;
    }
}

static double Mixer_EQFamilyQScale(uint32_t family) {
    switch (family) {
    case MIXER_EQ_FILTER_CHEBYSHEV:
        return 1.18;
    case MIXER_EQ_FILTER_BESSEL:
        return 0.82;
    case MIXER_EQ_FILTER_LINKWITZ_RILEY:
        return 0.707;
    case MIXER_EQ_FILTER_BUTTERWORTH:
    default:
        return 1.0;
    }
}

static double Mixer_EQSlopeQScale(uint32_t slope) {
    switch (slope) {
    case MIXER_EQ_SLOPE_DB6:
        return 0.78;
    case MIXER_EQ_SLOPE_DB24:
        return 1.15;
    case MIXER_EQ_SLOPE_DB48:
        return 1.3;
    case MIXER_EQ_SLOPE_DB12:
    default:
        return 1.0;
    }
}

static void Mixer_ConfigureBiquad(MixerBiquadState *state,
                                  double b0,
                                  double b1,
                                  double b2,
                                  double a0,
                                  double a1,
                                  double a2) {
    if (!state || fabs(a0) < 1.0e-12) {
        return;
    }

    state->b0 = b0 / a0;
    state->b1 = b1 / a0;
    state->b2 = b2 / a0;
    state->a1 = a1 / a0;
    state->a2 = a2 / a0;
    state->active = 1;
}

static void Mixer_ConfigureHighPass(MixerBiquadState *state,
                                    double sampleRate,
                                    double frequency,
                                    double q) {
    if (!state || sampleRate <= 0.0 || frequency <= 0.0) {
        Mixer_SetFilterInactive(state);
        return;
    }

    double omega = 2.0 * M_PI * frequency / sampleRate;
    double alpha = sin(omega) / (2.0 * q);
    double cosine = cos(omega);
    Mixer_ConfigureBiquad(state,
                          (1.0 + cosine) / 2.0,
                          -(1.0 + cosine),
                          (1.0 + cosine) / 2.0,
                          1.0 + alpha,
                          -2.0 * cosine,
                          1.0 - alpha);
}

static void Mixer_ConfigureLowPass(MixerBiquadState *state,
                                   double sampleRate,
                                   double frequency,
                                   double q) {
    if (!state || sampleRate <= 0.0 || frequency <= 0.0) {
        Mixer_SetFilterInactive(state);
        return;
    }

    double omega = 2.0 * M_PI * frequency / sampleRate;
    double alpha = sin(omega) / (2.0 * q);
    double cosine = cos(omega);
    Mixer_ConfigureBiquad(state,
                          (1.0 - cosine) / 2.0,
                          1.0 - cosine,
                          (1.0 - cosine) / 2.0,
                          1.0 + alpha,
                          -2.0 * cosine,
                          1.0 - alpha);
}

static void Mixer_ConfigurePeaking(MixerBiquadState *state,
                                   double sampleRate,
                                   double frequency,
                                   double q,
                                   double gainDB) {
    if (!state || sampleRate <= 0.0 || frequency <= 0.0 || fabs(gainDB) <= 0.05) {
        Mixer_SetFilterInactive(state);
        return;
    }

    double omega = 2.0 * M_PI * frequency / sampleRate;
    double alpha = sin(omega) / (2.0 * q);
    double cosine = cos(omega);
    double amplitude = pow(10.0, gainDB / 40.0);
    Mixer_ConfigureBiquad(state,
                          1.0 + alpha * amplitude,
                          -2.0 * cosine,
                          1.0 - alpha * amplitude,
                          1.0 + alpha / amplitude,
                          -2.0 * cosine,
                          1.0 - alpha / amplitude);
}

static void Mixer_ConfigureHighPassChain(MixerBiquadState *states,
                                         uint32_t maxStages,
                                         double sampleRate,
                                         double frequency,
                                         uint32_t family,
                                         uint32_t slope,
                                         uint32_t enabled) {
    if (!states || maxStages == 0 || !enabled || sampleRate <= 0.0 || frequency <= 0.0) {
        Mixer_SetFilterChainInactive(states, maxStages);
        return;
    }

    uint32_t stageCount = Mixer_EQStageCountForSlope(slope);
    if (stageCount > maxStages) {
        stageCount = maxStages;
    }

    double q = 0.707 * Mixer_EQFamilyQScale(family) * Mixer_EQSlopeQScale(slope);
    q = Mixer_ClampDouble(q, 0.35, 2.5);

    for (uint32_t stage = 0; stage < maxStages; stage++) {
        if (stage < stageCount) {
            Mixer_ConfigureHighPass(&states[stage], sampleRate, frequency, q);
        } else {
            Mixer_SetFilterInactive(&states[stage]);
        }
    }
}

static void Mixer_ConfigureLowPassChain(MixerBiquadState *states,
                                        uint32_t maxStages,
                                        double sampleRate,
                                        double frequency,
                                        uint32_t family,
                                        uint32_t slope,
                                        uint32_t enabled) {
    if (!states || maxStages == 0 || !enabled || sampleRate <= 0.0 || frequency <= 0.0) {
        Mixer_SetFilterChainInactive(states, maxStages);
        return;
    }

    uint32_t stageCount = Mixer_EQStageCountForSlope(slope);
    if (stageCount > maxStages) {
        stageCount = maxStages;
    }

    double q = 0.707 * Mixer_EQFamilyQScale(family) * Mixer_EQSlopeQScale(slope);
    q = Mixer_ClampDouble(q, 0.35, 2.5);

    for (uint32_t stage = 0; stage < maxStages; stage++) {
        if (stage < stageCount) {
            Mixer_ConfigureLowPass(&states[stage], sampleRate, frequency, q);
        } else {
            Mixer_SetFilterInactive(&states[stage]);
        }
    }
}

static void Mixer_ConfigurePeakingChain(MixerBiquadState *states,
                                        uint32_t maxStages,
                                        double sampleRate,
                                        double frequency,
                                        double q,
                                        double gainDB,
                                        uint32_t family,
                                        uint32_t slope,
                                        uint32_t enabled) {
    if (!states || maxStages == 0 || !enabled || sampleRate <= 0.0 || frequency <= 0.0) {
        Mixer_SetFilterChainInactive(states, maxStages);
        return;
    }

    uint32_t stageCount = Mixer_EQStageCountForSlope(slope);
    if (stageCount > maxStages) {
        stageCount = maxStages;
    }

    double qScaled = q * Mixer_EQFamilyQScale(family) * Mixer_EQSlopeQScale(slope);
    qScaled = Mixer_ClampDouble(qScaled, 0.3, 8.0);

    double gainScaled = gainDB * Mixer_EQSlopeGainScale(slope);
    gainScaled = gainScaled / (double)stageCount;

    for (uint32_t stage = 0; stage < maxStages; stage++) {
        if (stage < stageCount) {
            Mixer_ConfigurePeaking(&states[stage], sampleRate, frequency, qScaled, gainScaled);
        } else {
            Mixer_SetFilterInactive(&states[stage]);
        }
    }
}

static float Mixer_ProcessBiquadSample(MixerBiquadState *state, float sample) {
    if (!state || !state->active) {
        return sample;
    }

    double output = (state->b0 * sample) +
                    (state->b1 * state->x1) +
                    (state->b2 * state->x2) -
                    (state->a1 * state->y1) -
                    (state->a2 * state->y2);

    state->x2 = state->x1;
    state->x1 = sample;
    state->y2 = state->y1;
    state->y1 = output;
    return (float)output;
}

static float Mixer_ProcessBiquadChain(MixerBiquadState *states, uint32_t stageCount, float sample) {
    if (!states) {
        return sample;
    }

    float output = sample;
    for (uint32_t stage = 0; stage < stageCount; stage++) {
        output = Mixer_ProcessBiquadSample(&states[stage], output);
    }
    return output;
}

static void Mixer_UpdateEQFilters(MixerChannel *channel, double sampleRate) {
    if (!channel) {
        return;
    }

    MixerEQConfig *config = &channel->eqConfig;
    if (!config->enabled || sampleRate <= 0.0) {
        Mixer_SetFilterChainInactive(channel->highPassFilter, MIXER_EQ_MAX_FILTER_STAGES);
        Mixer_SetFilterChainInactive(channel->lowBandFilter, MIXER_EQ_MAX_FILTER_STAGES);
        Mixer_SetFilterChainInactive(channel->lowMidBandFilter, MIXER_EQ_MAX_FILTER_STAGES);
        Mixer_SetFilterChainInactive(channel->midBandFilter, MIXER_EQ_MAX_FILTER_STAGES);
        Mixer_SetFilterChainInactive(channel->presenceBandFilter, MIXER_EQ_MAX_FILTER_STAGES);
        Mixer_SetFilterChainInactive(channel->highBandFilter, MIXER_EQ_MAX_FILTER_STAGES);
        Mixer_SetFilterChainInactive(channel->lowPassFilter, MIXER_EQ_MAX_FILTER_STAGES);
        return;
    }

    Mixer_ConfigureHighPassChain(channel->highPassFilter,
                                 MIXER_EQ_MAX_FILTER_STAGES,
                                 sampleRate,
                                 Mixer_ClampFloat(config->highPassFrequencyHz, 20.0f, 20000.0f),
                                 config->highPassFilterType,
                                 config->highPassSlope,
                                 config->highPassEnabled);
    Mixer_ConfigurePeakingChain(channel->lowBandFilter,
                                MIXER_EQ_MAX_FILTER_STAGES,
                                sampleRate,
                                Mixer_ClampFloat(config->lowCenterFrequencyHz, 20.0f, 20000.0f),
                                Mixer_ClampFloat(config->lowQ, 0.3f, 4.0f),
                                Mixer_ClampFloat(config->lowGainDB, -24.0f, 24.0f),
                                config->lowFilterType,
                                config->lowSlope,
                                config->lowEnabled);
    Mixer_ConfigurePeakingChain(channel->lowMidBandFilter,
                                MIXER_EQ_MAX_FILTER_STAGES,
                                sampleRate,
                                Mixer_ClampFloat(config->lowMidCenterFrequencyHz, 20.0f, 20000.0f),
                                Mixer_ClampFloat(config->lowMidQ, 0.3f, 6.0f),
                                Mixer_ClampFloat(config->lowMidGainDB, -24.0f, 24.0f),
                                config->lowMidFilterType,
                                config->lowMidSlope,
                                config->lowMidEnabled);
    Mixer_ConfigurePeakingChain(channel->midBandFilter,
                                MIXER_EQ_MAX_FILTER_STAGES,
                                sampleRate,
                                Mixer_ClampFloat(config->midCenterFrequencyHz, 20.0f, 20000.0f),
                                Mixer_ClampFloat(config->midQ, 0.3f, 6.0f),
                                Mixer_ClampFloat(config->midGainDB, -24.0f, 24.0f),
                                config->midFilterType,
                                config->midSlope,
                                config->midEnabled);
    Mixer_ConfigurePeakingChain(channel->presenceBandFilter,
                                MIXER_EQ_MAX_FILTER_STAGES,
                                sampleRate,
                                Mixer_ClampFloat(config->presenceCenterFrequencyHz, 20.0f, 20000.0f),
                                Mixer_ClampFloat(config->presenceQ, 0.3f, 6.0f),
                                Mixer_ClampFloat(config->presenceGainDB, -24.0f, 24.0f),
                                config->presenceFilterType,
                                config->presenceSlope,
                                config->presenceEnabled);
    Mixer_ConfigurePeakingChain(channel->highBandFilter,
                                MIXER_EQ_MAX_FILTER_STAGES,
                                sampleRate,
                                Mixer_ClampFloat(config->highCenterFrequencyHz, 20.0f, 20000.0f),
                                Mixer_ClampFloat(config->highQ, 0.3f, 4.0f),
                                Mixer_ClampFloat(config->highGainDB, -24.0f, 24.0f),
                                config->highFilterType,
                                config->highSlope,
                                config->highEnabled);
    Mixer_ConfigureLowPassChain(channel->lowPassFilter,
                                MIXER_EQ_MAX_FILTER_STAGES,
                                sampleRate,
                                Mixer_ClampFloat(config->lowPassFrequencyHz, 20.0f, 20000.0f),
                                config->lowPassFilterType,
                                config->lowPassSlope,
                                config->lowPassEnabled);
}

static void Mixer_ProcessEQBlock(MixerChannel *channel,
                                 float *buffer,
                                 uint32_t frameCount,
                                 double sampleRate) {
    if (!channel || !buffer || frameCount == 0 || !channel->eqConfig.enabled) {
        return;
    }

    Mixer_UpdateEQFilters(channel, sampleRate);

    for (uint32_t frame = 0; frame < frameCount; frame++) {
        float sample = buffer[frame];
        sample = Mixer_ProcessBiquadChain(channel->highPassFilter, MIXER_EQ_MAX_FILTER_STAGES, sample);
        sample = Mixer_ProcessBiquadChain(channel->lowBandFilter, MIXER_EQ_MAX_FILTER_STAGES, sample);
        sample = Mixer_ProcessBiquadChain(channel->lowMidBandFilter, MIXER_EQ_MAX_FILTER_STAGES, sample);
        sample = Mixer_ProcessBiquadChain(channel->midBandFilter, MIXER_EQ_MAX_FILTER_STAGES, sample);
        sample = Mixer_ProcessBiquadChain(channel->presenceBandFilter, MIXER_EQ_MAX_FILTER_STAGES, sample);
        sample = Mixer_ProcessBiquadChain(channel->highBandFilter, MIXER_EQ_MAX_FILTER_STAGES, sample);
        sample = Mixer_ProcessBiquadChain(channel->lowPassFilter, MIXER_EQ_MAX_FILTER_STAGES, sample);
        buffer[frame] = sample;
    }
}

static float Mixer_ProcessDynamicsSample(MixerChannel *channel, float sample, double sampleRate) {
    if (!channel || !channel->dynamicsConfig.enabled || sampleRate <= 0.0) {
        return sample;
    }

    MixerDynamicsConfig *config = &channel->dynamicsConfig;
    MixerDynamicsState *state = &channel->dynamicsState;

    double magnitude = fabs((double)sample);
    double attackCoefficient = exp(-1.0 / fmax(sampleRate * Mixer_ClampFloat(config->attackMilliseconds, 0.01f, 2000.0f) / 1000.0f, 1.0));
    double releaseCoefficient = exp(-1.0 / fmax(sampleRate * Mixer_ClampFloat(config->releaseMilliseconds, 0.01f, 9000.0f) / 1000.0f, 1.0));

    if (magnitude > state->envelope) {
        state->envelope = attackCoefficient * state->envelope + (1.0 - attackCoefficient) * magnitude;
    } else {
        state->envelope = releaseCoefficient * state->envelope + (1.0 - releaseCoefficient) * magnitude;
    }

    if (state->envelope <= 1.0e-9) {
        state->lastGainReductionDB = 0.0f;
        return sample;
    }

    double thresholdDB = Mixer_ClampFloat(config->thresholdDB, -60.0f, 0.0f);
    double ratio = Mixer_ClampFloat(config->ratio, 1.0f, 20.0f);
    double makeupGainDB = Mixer_ClampFloat(config->makeupGainDB, 0.0f, 36.0f);
    double mix = Mixer_ClampFloat(config->mix, 0.0f, 1.0f);
    double inputDB = 20.0 * log10(state->envelope);
    double overDB = fmax(inputDB - thresholdDB, 0.0);
    double gainReductionDB = (1.0 - (1.0 / ratio)) * overDB;
    double gain = pow(10.0, (-gainReductionDB + makeupGainDB) / 20.0);
    double compressed = sample * gain;

    if ((float)gainReductionDB > channel->lastGainReductionDB) {
        channel->lastGainReductionDB = (float)gainReductionDB;
    }
    state->lastGainReductionDB = (float)gainReductionDB;

    return (float)((sample * (1.0 - mix)) + (compressed * mix));
}

static float Mixer_ProcessLimiterSample(MixerChannel *channel, float sample) {
    if (!channel || !channel->dynamicsConfig.limiterEnabled) {
        return sample;
    }

    double ceilingDB = Mixer_ClampFloat(channel->dynamicsConfig.limiterCeilingDB, -24.0f, 0.0f);
    double ceilingLin = pow(10.0, ceilingDB / 20.0);
    double inMag = fabs((double)sample);
    if (inMag <= ceilingLin || inMag <= 1.0e-9) {
        return sample;
    }

    double limited = (sample >= 0.0f) ? ceilingLin : -ceilingLin;
    double limiterReductionDB = 20.0 * log10(inMag / fmax(fabs(limited), 1.0e-9));
    float reduction = (float)fmax(0.0, limiterReductionDB);
    if (reduction > channel->lastGainReductionDB) {
        channel->lastGainReductionDB = reduction;
    }
    if (reduction > channel->dynamicsState.lastGainReductionDB) {
        channel->dynamicsState.lastGainReductionDB = reduction;
    }

    return (float)limited;
}

static void Mixer_WriteBlockToRingBuffer(RingBuffer *rb, const float *buffer, uint32_t frameCount) {
    if (!rb || !buffer || frameCount == 0) {
        return;
    }

    pthread_mutex_lock(&rb->lock);
    for (uint32_t frame = 0; frame < frameCount; frame++) {
        rb->buffer[rb->writeIndex] = buffer[frame];
        rb->writeIndex = (rb->writeIndex + 1) % rb->capacity;
        if (rb->filled < rb->capacity) {
            rb->filled++;
        } else {
            // Overflow: drop oldest to maintain FIFO order
            rb->readIndex = (rb->readIndex + 1) % rb->capacity;
        }
    }
    pthread_mutex_unlock(&rb->lock);
}

static void Mixer_ProcessDynamicsBlock(MixerChannel *channel,
                                       float *buffer,
                                       uint32_t frameCount,
                                       double sampleRate) {
    if (!channel || !buffer || frameCount == 0) {
        return;
    }

    const int compressionEnabled = channel->dynamicsConfig.enabled != 0;
    const int limiterEnabled = channel->dynamicsConfig.limiterEnabled != 0;

    if (!compressionEnabled && !limiterEnabled) {
        channel->lastGainReductionDB = 0.0f;
        channel->dynamicsState.lastGainReductionDB = 0.0f;
        return;
    }

    channel->lastGainReductionDB = 0.0f;
    if (!compressionEnabled) {
        channel->dynamicsState.lastGainReductionDB = 0.0f;
    }

    for (uint32_t frame = 0; frame < frameCount; frame++) {
        float sample = buffer[frame];
        if (compressionEnabled) {
            sample = Mixer_ProcessDynamicsSample(channel, sample, sampleRate);
        }
        if (limiterEnabled) {
            sample = Mixer_ProcessLimiterSample(channel, sample);
        }
        buffer[frame] = sample;
    }
}

static void Mixer_ProcessVirtualBusBlock(MixerChannel *channel,
                                         uint32_t busType,
                                         uint32_t busIndex,
                                         float *buffer,
                                         uint32_t frameCount,
                                         double sampleRate) {
    if (!channel || !buffer || frameCount == 0) {
        return;
    }

    Mixer_SynchronizeVirtualBusShadowConfigs(channel, busType, busIndex);

    if (channel->mute) {
        memset(buffer, 0, frameCount * sizeof(float));
        channel->lastGainReductionDB = 0.0f;
        channel->dynamicsState.lastGainReductionDB = 0.0f;
        return;
    }

    if (channel->polarityFlipped) {
        for (uint32_t frame = 0; frame < frameCount; frame++) {
            buffer[frame] = -buffer[frame];
        }
    }

    if (channel->gain != 1.0f) {
        for (uint32_t frame = 0; frame < frameCount; frame++) {
            buffer[frame] *= channel->gain;
        }
    }

    Mixer_ProcessEQBlock(channel, buffer, frameCount, sampleRate);
    Mixer_ProcessDynamicsBlock(channel, buffer, frameCount, sampleRate);
    Mixer_WriteBlockToRingBuffer(channel->postDynamicsRingBuffer, buffer, frameCount);

    const float fader = Mixer_ClampFloat(channel->fader, 0.0f, 1.2f);
    if (fader != 1.0f) {
        for (uint32_t frame = 0; frame < frameCount; frame++) {
            buffer[frame] *= fader;
        }
    }
}

/**
 * Main audio processing engine
 * Called repeatedly to process audio blocks through the mixer
 *
 * Processing flow:
 * 1. Lock mixer mutex
 * 2. For each input device: read samples from ring buffer, apply processing
 * 3. For each output device: sum processed inputs, write to ring buffer
 * 4. Unlock mutex
 * 5. Return
 *
 * @return 0 on success, -1 if mixer not initialized
 */
OSStatus Mixer_ProcessBlock(void) {
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return -1;  // Mixer not initialized
    }

    pthread_mutex_lock(&mixer->mutex);

    if (mixer->bufferFrames == 0) {
        pthread_mutex_unlock(&mixer->mutex);
        return 0;
    }

    // Use pre-allocated scratch buffers — zero them instead of malloc/free per block.
    float **inputBuffers = mixer->scratchInputBuffers;
    float **auxSendBuses = mixer->scratchAuxSendBuses;
    float **fxSendBuses = mixer->scratchFxSendBuses;
    float **auxReturnBuses = mixer->scratchAuxReturnBuses;
    float **fxReturnBuses = mixer->scratchFxReturnBuses;

    if (!inputBuffers || !auxSendBuses || !fxSendBuses || !auxReturnBuses || !fxReturnBuses) {
        pthread_mutex_unlock(&mixer->mutex);
        return -1;
    }

    // Zero only the channels we actually use (not the full MIXER_MAX_GLOBAL_CHANNELS)
    const size_t frameBytes = mixer->bufferFrames * sizeof(float);
    for (uint32_t i = 0; i < mixer->totalGlobalChannels && i < mixer->scratchInputCount; i++) {
        memset(inputBuffers[i], 0, frameBytes);
    }
    for (uint32_t i = 0; i < MIXER_MAX_AUX_SEND_BUSES; i++) {
        memset(auxSendBuses[i], 0, frameBytes);
    }
    for (uint32_t i = 0; i < MIXER_MAX_FX_SEND_BUSES; i++) {
        memset(fxSendBuses[i], 0, frameBytes);
    }
    for (uint32_t i = 0; i < MIXER_MAX_AUX_RETURN_BUSES; i++) {
        memset(auxReturnBuses[i], 0, frameBytes);
    }
    for (uint32_t i = 0; i < MIXER_MAX_FX_RETURN_BUSES; i++) {
        memset(fxReturnBuses[i], 0, frameBytes);
    }

    // ========================================================================
    // STEP 1: Read and process all input channels
    // ========================================================================

    for (uint32_t devIdx = 0; devIdx < mixer->numDevices; devIdx++) {
        MixerDevice *device = &mixer->devices[devIdx];

        if (!device->active || device->type != MIXER_CHANNEL_INPUT) {
            continue;  // Skip inactive or non-input devices
        }

        // Process each channel in this input device
        for (uint32_t chIdx = 0; chIdx < device->numChannels; chIdx++) {
            MixerChannel *channel = &device->channels[chIdx];
            uint32_t globalIdx = channel->globalChannelIndex;
            Mixer_SynchronizeChannelShadowConfigs(channel);

            // Read from input ring buffer if attached
            if (channel->inputRingBuffer) {
                ringbuffer_read(channel->inputRingBuffer, inputBuffers[globalIdx], mixer->bufferFrames);
            } else {
                // No buffer attached - silence
                memset(inputBuffers[globalIdx], 0, mixer->bufferFrames * sizeof(float));
            }

            // Apply delay (pre-fader, pre-mute).
            // The delay line is advanced even for muted channels so there is no burst on unmute.
            if (channel->delaySamples > 0 &&
                channel->delayBuffer != NULL &&
                channel->delayBufferCapacity > channel->delaySamples) {
                for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                    channel->delayBuffer[channel->delayWritePos] = inputBuffers[globalIdx][frame];
                    uint32_t readPos = (channel->delayWritePos + channel->delayBufferCapacity - channel->delaySamples)
                                       % channel->delayBufferCapacity;
                    inputBuffers[globalIdx][frame] = channel->delayBuffer[readPos];
                    channel->delayWritePos = (channel->delayWritePos + 1) % channel->delayBufferCapacity;
                }
            }

            // Apply channel processing: mute, gain, fader, pan
            if (channel->mute) {
                // Muted - zero the channel
                memset(inputBuffers[globalIdx], 0, mixer->bufferFrames * sizeof(float));
                channel->lastGainReductionDB = 0.0f;
            } else {
                // Apply polarity flip (pre-fader, pre-gain)
                if (channel->polarityFlipped) {
                    for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                        inputBuffers[globalIdx][frame] = -inputBuffers[globalIdx][frame];
                    }
                }

                // Apply post-gain before insert processing.
                if (channel->gain != 1.0f) {
                    for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                        inputBuffers[globalIdx][frame] *= channel->gain;
                    }
                }

                Mixer_ProcessEQBlock(channel, inputBuffers[globalIdx], mixer->bufferFrames, mixer->sampleRate);

                // Write post-EQ audio to ring buffer for FFT analysis
                if (channel->postEQRingBuffer) {
                    Mixer_WriteBlockToRingBuffer(channel->postEQRingBuffer,
                                                 inputBuffers[globalIdx],
                                                 mixer->bufferFrames);
                }

                Mixer_ProcessDynamicsBlock(channel, inputBuffers[globalIdx], mixer->bufferFrames, mixer->sampleRate);
                Mixer_WriteBlockToRingBuffer(channel->postDynamicsRingBuffer,
                                             inputBuffers[globalIdx],
                                             mixer->bufferFrames);
            }

            if (auxSendBuses && channel->auxSend > 0.0f) {
                uint32_t busIndex = channel->auxSendBusIndex < MIXER_MAX_AUX_SEND_BUSES
                    ? channel->auxSendBusIndex
                    : (MIXER_MAX_AUX_SEND_BUSES - 1);
                float sendGain = channel->auxSendPreFade ? channel->auxSend : (channel->auxSend * channel->fader);
                for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                    auxSendBuses[busIndex][frame] += inputBuffers[globalIdx][frame] * sendGain;
                }
            }

            if (fxSendBuses && channel->fxSend > 0.0f) {
                uint32_t busIndex = channel->fxSendBusIndex < MIXER_MAX_FX_SEND_BUSES
                    ? channel->fxSendBusIndex
                    : (MIXER_MAX_FX_SEND_BUSES - 1);
                float sendGain = channel->fxSendPreFade ? channel->fxSend : (channel->fxSend * channel->fader);
                for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                    fxSendBuses[busIndex][frame] += inputBuffers[globalIdx][frame] * sendGain;
                }
            }
        }
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_SEND_BUSES; busIndex++) {
        Mixer_ProcessVirtualBusBlock(&mixer->auxSendBusChannels[busIndex],
                                     MIXER_VIRTUAL_BUS_AUX_SEND,
                                     busIndex,
                                     auxSendBuses[busIndex],
                                     mixer->bufferFrames,
                                     mixer->sampleRate);
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_SEND_BUSES; busIndex++) {
        Mixer_ProcessVirtualBusBlock(&mixer->fxSendBusChannels[busIndex],
                                     MIXER_VIRTUAL_BUS_FX_SEND,
                                     busIndex,
                                     fxSendBuses[busIndex],
                                     mixer->bufferFrames,
                                     mixer->sampleRate);
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_RETURN_BUSES; busIndex++) {
        if (busIndex < MIXER_MAX_AUX_SEND_BUSES) {
            memcpy(auxReturnBuses[busIndex],
                   auxSendBuses[busIndex],
                   mixer->bufferFrames * sizeof(float));
        } else {
            memset(auxReturnBuses[busIndex], 0, mixer->bufferFrames * sizeof(float));
        }

        Mixer_ProcessVirtualBusBlock(&mixer->auxReturnBusChannels[busIndex],
                                     MIXER_VIRTUAL_BUS_AUX_RETURN,
                                     busIndex,
                                     auxReturnBuses[busIndex],
                                     mixer->bufferFrames,
                                     mixer->sampleRate);
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_RETURN_BUSES; busIndex++) {
        if (busIndex < MIXER_MAX_FX_SEND_BUSES) {
            memcpy(fxReturnBuses[busIndex],
                   fxSendBuses[busIndex],
                   mixer->bufferFrames * sizeof(float));
        } else {
            memset(fxReturnBuses[busIndex], 0, mixer->bufferFrames * sizeof(float));
        }

        Mixer_ProcessVirtualBusBlock(&mixer->fxReturnBusChannels[busIndex],
                                     MIXER_VIRTUAL_BUS_FX_RETURN,
                                     busIndex,
                                     fxReturnBuses[busIndex],
                                     mixer->bufferFrames,
                                     mixer->sampleRate);
    }

    memset(mixer->auxSendPeak, 0, sizeof(mixer->auxSendPeak));
    memset(mixer->auxSendRMS, 0, sizeof(mixer->auxSendRMS));
    memset(mixer->fxSendPeak, 0, sizeof(mixer->fxSendPeak));
    memset(mixer->fxSendRMS, 0, sizeof(mixer->fxSendRMS));
    memset(mixer->auxReturnPeak, 0, sizeof(mixer->auxReturnPeak));
    memset(mixer->auxReturnRMS, 0, sizeof(mixer->auxReturnRMS));
    memset(mixer->fxReturnPeak, 0, sizeof(mixer->fxReturnPeak));
    memset(mixer->fxReturnRMS, 0, sizeof(mixer->fxReturnRMS));

    Mixer_UpdateBusMeterArrays(auxSendBuses,
                               MIXER_MAX_AUX_SEND_BUSES,
                               mixer->bufferFrames,
                               mixer->auxSendPeak,
                               mixer->auxSendRMS);
    Mixer_UpdateBusMeterArrays(fxSendBuses,
                               MIXER_MAX_FX_SEND_BUSES,
                               mixer->bufferFrames,
                               mixer->fxSendPeak,
                               mixer->fxSendRMS);
    Mixer_UpdateBusMeterArrays(auxReturnBuses,
                               MIXER_MAX_AUX_RETURN_BUSES,
                               mixer->bufferFrames,
                               mixer->auxReturnPeak,
                               mixer->auxReturnRMS);
    Mixer_UpdateBusMeterArrays(fxReturnBuses,
                               MIXER_MAX_FX_RETURN_BUSES,
                               mixer->bufferFrames,
                               mixer->fxReturnPeak,
                               mixer->fxReturnRMS);

    // Mirror virtual bus samples into dedicated visualization ring buffers.
    // These buffers are independent from playback paths and support concurrent visualizers.
    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_SEND_BUSES; busIndex++) {
        RingBuffer *sendBuffer = mixer->auxSendRingBuffers[busIndex];
        if (!sendBuffer) {
            continue;
        }
        for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
            writeRingBuffer(sendBuffer, auxSendBuses[busIndex][frame]);
        }
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_SEND_BUSES; busIndex++) {
        RingBuffer *sendBuffer = mixer->fxSendRingBuffers[busIndex];
        if (!sendBuffer) {
            continue;
        }
        for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
            writeRingBuffer(sendBuffer, fxSendBuses[busIndex][frame]);
        }
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_AUX_RETURN_BUSES; busIndex++) {
        RingBuffer *returnBuffer = mixer->auxReturnRingBuffers[busIndex];
        if (!returnBuffer) {
            continue;
        }
        for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
            writeRingBuffer(returnBuffer, auxReturnBuses[busIndex][frame]);
        }
    }

    for (uint32_t busIndex = 0; busIndex < MIXER_MAX_FX_RETURN_BUSES; busIndex++) {
        RingBuffer *returnBuffer = mixer->fxReturnRingBuffers[busIndex];
        if (!returnBuffer) {
            continue;
        }
        for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
            writeRingBuffer(returnBuffer, fxReturnBuses[busIndex][frame]);
        }
    }

    // ========================================================================
    // STEP 2: Mix to outputs
    // ========================================================================

    for (uint32_t devIdx = 0; devIdx < mixer->numDevices; devIdx++) {
        MixerDevice *device = &mixer->devices[devIdx];

        if (!device->active || device->type != MIXER_CHANNEL_OUTPUT) {
            continue;  // Skip inactive or non-output devices
        }

        // Initialize output buffer with zeros
        for (uint32_t chIdx = 0; chIdx < device->numChannels; chIdx++) {
            MixerChannel *channel = &device->channels[chIdx];
            Mixer_SynchronizeChannelShadowConfigs(channel);
            if (Mixer_EnsureOutputBuffer(channel, mixer->bufferFrames) != 0) {
                continue;
            }
            memset(channel->outputBuffer, 0, mixer->bufferFrames * sizeof(float));
        }

        // Mix input channels to this output device
        // For each output channel, sum the routed inputs with appropriate pan

        for (uint32_t inDevIdx = 0; inDevIdx < mixer->numDevices; inDevIdx++) {
            MixerDevice *inDevice = &mixer->devices[inDevIdx];

            if (!inDevice->active || inDevice->type != MIXER_CHANNEL_INPUT) {
                continue;
            }

            // Sum each input channel to the output channels
            for (uint32_t inChIdx = 0; inChIdx < inDevice->numChannels; inChIdx++) {
                MixerChannel *inChannel = &inDevice->channels[inChIdx];
                uint32_t inGlobalIdx = inChannel->globalChannelIndex;
                float *inSamples = inputBuffers[inGlobalIdx];

                // Simple summing for now (full mix to all outputs)
                // Backlog: add per-output routing masks and pan-law handling.

                for (uint32_t outChIdx = 0; outChIdx < device->numChannels; outChIdx++) {
                    MixerChannel *outChannel = &device->channels[outChIdx];
                    if (!outChannel->outputBuffer) {
                        continue;
                    }

                    bool outputHasExplicitRoutes =
                        MixerRoute_HasExplicitRoutesForOutput(outChannel->deviceID,
                                                              (int32_t)outChannel->deviceChannelIndex);
                    bool shouldRoute = !outputHasExplicitRoutes ||
                        MixerRoute_IsActive(inChannel->deviceID,
                                            (int32_t)inChannel->deviceChannelIndex,
                                            outChannel->deviceID,
                                            (int32_t)outChannel->deviceChannelIndex);
                    if (!shouldRoute) {
                        continue;
                    }

                    // Apply pan law if stereo (L/R)
                    float panFactor = 1.0f;
                    if (device->numChannels == 2) {
                        // Simple constant-power pan law
                        if (outChIdx == 0) {
                            // Left channel
                            panFactor = cosf(inChannel->pan * M_PI / 2.0f);
                        } else {
                            // Right channel
                            panFactor = sinf(inChannel->pan * M_PI / 2.0f);
                        }
                    }

                    // Sum input to output
                    float inputFader = inChannel->fader;
                    for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                        outChannel->outputBuffer[frame] += inSamples[frame] * inputFader * panFactor;
                    }
                }
            }
        }

        // Write output buffers to ring buffers
        for (uint32_t chIdx = 0; chIdx < device->numChannels; chIdx++) {
            MixerChannel *channel = &device->channels[chIdx];
            if (!channel->outputBuffer) {
                channel->lastPeak = 0.0f;
                channel->lastRMS = 0.0f;
                continue;
            }

            if (channel->mute) {
                memset(channel->outputBuffer, 0, mixer->bufferFrames * sizeof(float));
                channel->lastGainReductionDB = 0.0f;
                channel->dynamicsState.lastGainReductionDB = 0.0f;
            } else {
                for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                    float sample = channel->outputBuffer[frame];

                    // Apply delay before downstream processing.
                    if (channel->delaySamples > 0 &&
                        channel->delayBuffer != NULL &&
                        channel->delayBufferCapacity > channel->delaySamples) {
                        channel->delayBuffer[channel->delayWritePos] = sample;
                        uint32_t readPos = (channel->delayWritePos + channel->delayBufferCapacity - channel->delaySamples)
                                           % channel->delayBufferCapacity;
                        sample = channel->delayBuffer[readPos];
                        channel->delayWritePos = (channel->delayWritePos + 1) % channel->delayBufferCapacity;
                    }

                    if (channel->polarityFlipped) {
                        sample = -sample;
                    }

                    if (channel->gain != 1.0f) {
                        sample *= channel->gain;
                    }

                    channel->outputBuffer[frame] = sample;
                }

                Mixer_ProcessEQBlock(channel, channel->outputBuffer, mixer->bufferFrames, mixer->sampleRate);

                // Feed post-EQ analyzer buffer for output channels too.
                if (channel->postEQRingBuffer) {
                    Mixer_WriteBlockToRingBuffer(channel->postEQRingBuffer,
                                                 channel->outputBuffer,
                                                 mixer->bufferFrames);
                }

                Mixer_ProcessDynamicsBlock(channel, channel->outputBuffer, mixer->bufferFrames, mixer->sampleRate);
                Mixer_WriteBlockToRingBuffer(channel->postDynamicsRingBuffer,
                                             channel->outputBuffer,
                                             mixer->bufferFrames);

                const float outputFader = Mixer_ClampFloat(channel->fader, 0.0f, 1.2f);
                if (outputFader != 1.0f) {
                    for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                        channel->outputBuffer[frame] *= outputFader;
                    }
                }
            }

            float peak = 0.0f;
            double sumSquares = 0.0;
            for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                const float sample = channel->outputBuffer[frame];
                const float magnitude = fabsf(sample);
                if (magnitude > peak) {
                    peak = magnitude;
                }
                sumSquares += (double)sample * (double)sample;
            }

            channel->lastPeak = peak;
            channel->lastRMS = mixer->bufferFrames > 0
                ? sqrtf((float)(sumSquares / (double)mixer->bufferFrames))
                : 0.0f;

            if (channel->outputRingBuffer) {
                for (uint32_t frame = 0; frame < mixer->bufferFrames; frame++) {
                    float sample = channel->outputBuffer[frame];
                    writeRingBuffer(channel->outputRingBuffer, sample);
                    if (channel->visualizationRingBuffer) {
                        writeRingBuffer(channel->visualizationRingBuffer, sample);
                    }
                }
            }
        }
    }

    // ========================================================================
    // CLEANUP
    // ========================================================================

    // Scratch buffers are pre-allocated — no free needed.

    pthread_mutex_unlock(&mixer->mutex);

    return 0;
}

int Mixer_StartProcessingThread(void) {
    pthread_mutex_lock(&gMixerProcessingThreadLock);

    if (gMixerProcessingThreadCreated) {
        pthread_mutex_unlock(&gMixerProcessingThreadLock);
        return 0;
    }

    if (GetGlobalMixerPointer() == NULL) {
        pthread_mutex_unlock(&gMixerProcessingThreadLock);
        return -1;
    }

    atomic_store_explicit(&gMixerProcessingThreadShouldStop, false, memory_order_release);
    int createResult = pthread_create(&gMixerProcessingThread,
                                      NULL,
                                      MixerProcessingThreadMain,
                                      NULL);
    if (createResult != 0) {
        pthread_mutex_unlock(&gMixerProcessingThreadLock);
        printf("[MixerClock] ERROR: Failed to create processing thread (%d)\n", createResult);
        return -1;
    }

    gMixerProcessingThreadCreated = true;
    pthread_mutex_unlock(&gMixerProcessingThreadLock);
    return 0;
}

void Mixer_StopProcessingThread(void) {
    pthread_t threadToJoin = (pthread_t)0;
    bool shouldJoin = false;

    pthread_mutex_lock(&gMixerProcessingThreadLock);
    if (gMixerProcessingThreadCreated) {
        atomic_store_explicit(&gMixerProcessingThreadShouldStop, true, memory_order_release);
        threadToJoin = gMixerProcessingThread;
        shouldJoin = true;
        gMixerProcessingThreadCreated = false;
    }
    pthread_mutex_unlock(&gMixerProcessingThreadLock);

    if (shouldJoin && !pthread_equal(threadToJoin, pthread_self())) {
        (void)pthread_join(threadToJoin, NULL);
    }

    atomic_store_explicit(&gMixerProcessingThreadRunning, false, memory_order_release);
}

int Mixer_IsProcessingThreadRunning(void) {
    return atomic_load_explicit(&gMixerProcessingThreadRunning, memory_order_acquire) ? 1 : 0;
}
