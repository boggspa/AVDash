/**
 * @file MixerControlProperty.c
 * @brief Control property accessors and mutators for MixerChannel.
 *
 * This file contains functions to set and get properties such as gain, fader, pan,
 * mute, and solo for mixer channels identified by a global channel index.
 *
 * @author Chris Izatt
 * @date 2025-07-23
 *
 * @details
 * These functions provide thread-safe access to channel properties within the global mixer
 * structure gMixer. Each channel is mapped to its owning device by the global channel index.
 * Locks are used to protect concurrent access.
 *
 * @note Early or premature calls with out-of-range indices now emit warnings and return safely
 * without aborting. These calls are treated as no-ops or return defensible defaults.
 */

#include "Mixer.h"
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>

extern void MixerConfigShadow_PublishChannelEQ(uint32_t globalChannelIndex, MixerEQConfig config);
extern void MixerConfigShadow_PublishChannelDynamics(uint32_t globalChannelIndex, MixerDynamicsConfig config);
extern void MixerConfigShadow_PublishVirtualBusEQ(uint32_t busType, uint32_t busIndex, MixerEQConfig config);
extern void MixerConfigShadow_PublishVirtualBusDynamics(uint32_t busType, uint32_t busIndex, MixerDynamicsConfig config);

static float Mixer_Clamp(float value, float minValue, float maxValue) {
    if (value < minValue) {
        return minValue;
    }
    if (value > maxValue) {
        return maxValue;
    }
    return value;
}

static MixerChannel *Mixer_FindChannelByGlobalIndexLocked(Mixer *mixer, uint32_t globalChannelIndex) {
    if (!mixer || globalChannelIndex >= mixer->totalGlobalChannels) {
        return NULL;
    }

    for (uint32_t deviceIndex = 0; deviceIndex < mixer->numDevices; deviceIndex++) {
        MixerDevice *device = &mixer->devices[deviceIndex];
        if (!device->active) {
            continue;
        }

        for (uint32_t channelIndex = 0; channelIndex < device->numChannels; channelIndex++) {
            MixerChannel *channel = &device->channels[channelIndex];
            if (channel->globalChannelIndex == globalChannelIndex) {
                return channel;
            }
        }
    }

    return NULL;
}

static MixerChannel *Mixer_GetVirtualBusChannelLocked(Mixer *mixer, uint32_t busType, uint32_t busIndex) {
    if (!mixer) {
        return NULL;
    }

    switch ((MixerVirtualBusType)busType) {
        case MIXER_VIRTUAL_BUS_AUX_SEND:
            return busIndex < MIXER_MAX_AUX_SEND_BUSES ? &mixer->auxSendBusChannels[busIndex] : NULL;
        case MIXER_VIRTUAL_BUS_FX_SEND:
            return busIndex < MIXER_MAX_FX_SEND_BUSES ? &mixer->fxSendBusChannels[busIndex] : NULL;
        case MIXER_VIRTUAL_BUS_AUX_RETURN:
            return busIndex < MIXER_MAX_AUX_RETURN_BUSES ? &mixer->auxReturnBusChannels[busIndex] : NULL;
        case MIXER_VIRTUAL_BUS_FX_RETURN:
            return busIndex < MIXER_MAX_FX_RETURN_BUSES ? &mixer->fxReturnBusChannels[busIndex] : NULL;
        default:
            return NULL;
    }
}

static int Mixer_HasAnySoloLocked(Mixer *mixer) {
    if (!mixer) {
        return 0;
    }

    for (uint32_t deviceIndex = 0; deviceIndex < mixer->numDevices; deviceIndex++) {
        MixerDevice *device = &mixer->devices[deviceIndex];
        if (!device->active) {
            continue;
        }

        for (uint32_t channelIndex = 0; channelIndex < device->numChannels; channelIndex++) {
            if (device->channels[channelIndex].solo) {
                return 1;
            }
        }
    }

    return 0;
}

/**
 * @brief Set the gain for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @param gain The gain value to set.
 *
 * @note Thread-safe: uses gMixer mutex to protect modifications.
 * @warning If globalChannelIndex is out of range, function logs a warning and returns.
 */
void Mixer_SetChannelGain(uint32_t globalChannelIndex, float gain)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->gain = fmaxf(0.0f, gain);
    }
    pthread_mutex_unlock(&mixer->mutex);
}

/**
 * @brief Set the fader level for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @param fader The fader level to set.
 *
 * @note Thread-safe: uses gMixer mutex to protect modifications.
 * @warning If globalChannelIndex is out of range, function logs a warning and returns.
 */
void Mixer_SetChannelFader(uint32_t globalChannelIndex, float fader)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->fader = Mixer_Clamp(fader, 0.0f, 1.2f);
    }
    pthread_mutex_unlock(&mixer->mutex);
}

/**
 * @brief Set the pan value for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @param pan The pan value to set.
 *
 * @note Thread-safe: uses gMixer mutex to protect modifications.
 * @warning If globalChannelIndex is out of range, function logs a warning and returns.
 */
void Mixer_SetChannelPan(uint32_t globalChannelIndex, float pan)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->pan = Mixer_Clamp(pan, 0.0f, 1.0f);
    }
    pthread_mutex_unlock(&mixer->mutex);
}

void Mixer_SetChannelEQConfig(uint32_t globalChannelIndex, MixerEQConfig config)
{
    if (globalChannelIndex >= MIXER_MAX_GLOBAL_CHANNELS) {
        return;
    }

    MixerConfigShadow_PublishChannelEQ(globalChannelIndex, config);
}

void Mixer_SetChannelDynamicsConfig(uint32_t globalChannelIndex, MixerDynamicsConfig config)
{
    if (globalChannelIndex >= MIXER_MAX_GLOBAL_CHANNELS) {
        return;
    }

    MixerConfigShadow_PublishChannelDynamics(globalChannelIndex, config);
}

void Mixer_SetVirtualBusEQConfig(uint32_t busType, uint32_t busIndex, MixerEQConfig config)
{
    MixerConfigShadow_PublishVirtualBusEQ(busType, busIndex, config);
}

void Mixer_SetVirtualBusDynamicsConfig(uint32_t busType, uint32_t busIndex, MixerDynamicsConfig config)
{
    MixerConfigShadow_PublishVirtualBusDynamics(busType, busIndex, config);
}

void Mixer_SetChannelAuxSend(uint32_t globalChannelIndex, float sendLevel)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->auxSend = Mixer_Clamp(sendLevel, 0.0f, 1.0f);
    }
    pthread_mutex_unlock(&mixer->mutex);
}

void Mixer_SetChannelFXSend(uint32_t globalChannelIndex, float sendLevel)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->fxSend = Mixer_Clamp(sendLevel, 0.0f, 1.0f);
    }
    pthread_mutex_unlock(&mixer->mutex);
}

void Mixer_SetChannelAuxSendBus(uint32_t globalChannelIndex, uint32_t busIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->auxSendBusIndex = busIndex < MIXER_MAX_AUX_SEND_BUSES
            ? busIndex
            : (MIXER_MAX_AUX_SEND_BUSES - 1);
    }
    pthread_mutex_unlock(&mixer->mutex);
}

void Mixer_SetChannelFXSendBus(uint32_t globalChannelIndex, uint32_t busIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->fxSendBusIndex = busIndex < MIXER_MAX_FX_SEND_BUSES
            ? busIndex
            : (MIXER_MAX_FX_SEND_BUSES - 1);
    }
    pthread_mutex_unlock(&mixer->mutex);
}

/**
 * @brief Set the aux send pre/post fade state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @param preFade Boolean pre-fade state: 0=post-fade, 1=pre-fade.
 *
 * @note Thread-safe: uses gMixer mutex to protect modifications.
 * @warning If globalChannelIndex is out of range, function logs a warning and returns.
 */
void Mixer_SetChannelAuxSendPreFade(uint32_t globalChannelIndex, int preFade)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->auxSendPreFade = preFade ? 1 : 0;
    }
    pthread_mutex_unlock(&mixer->mutex);
}

/**
 * @brief Set the FX send pre/post fade state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @param preFade Boolean pre-fade state: 0=post-fade, 1=pre-fade.
 *
 * @note Thread-safe: uses gMixer mutex to protect modifications.
 * @warning If globalChannelIndex is out of range, function logs a warning and returns.
 */
void Mixer_SetChannelFXSendPreFade(uint32_t globalChannelIndex, int preFade)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->fxSendPreFade = preFade ? 1 : 0;
    }
    pthread_mutex_unlock(&mixer->mutex);
}

/**
 * @brief Get the aux send pre/post fade state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @return 0=post-fade, 1=pre-fade.
 *
 * @note Thread-safe: uses gMixer mutex to protect reads.
 * @warning If globalChannelIndex is out of range, returns 0 (post-fade).
 */
int Mixer_GetChannelAuxSendPreFade(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    int preFade = channel ? channel->auxSendPreFade : 0;
    pthread_mutex_unlock(&mixer->mutex);

    return preFade;
}

/**
 * @brief Get the FX send pre/post fade state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @return 0=post-fade, 1=pre-fade.
 *
 * @note Thread-safe: uses gMixer mutex to protect reads.
 * @warning If globalChannelIndex is out of range, returns 0 (post-fade).
 */
int Mixer_GetChannelFXSendPreFade(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    int preFade = channel ? channel->fxSendPreFade : 0;
    pthread_mutex_unlock(&mixer->mutex);

    return preFade;
}

/**
 * @brief Set the mute state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @param mute Boolean mute state: non-zero to mute, zero to unmute.
 *
 * @note Thread-safe: uses gMixer mutex to protect modifications.
 * @warning If globalChannelIndex is out of range, function logs a warning and returns.
 */
void Mixer_SetChannelMute(uint32_t globalChannelIndex, int mute)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->mute = mute != 0;
    }
    pthread_mutex_unlock(&mixer->mutex);
}

/**
 * @brief Get the mute state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @return int Returns 1 if muted, 0 if unmuted.
 *
 * @note Thread-safe: uses gMixer mutex to protect access.
 * @note If any channel is soloed, only soloed channels are unmuted, others forced muted.
 * @warning Returns 1 (muted) if index out of range or not found.
 */
int Mixer_GetChannelMute(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return 1;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (!channel) {
        pthread_mutex_unlock(&mixer->mutex);
        return 1;
    }

    int isMuted = channel->mute != 0;
    if (Mixer_HasAnySoloLocked(mixer)) {
        isMuted = channel->solo ? 0 : 1;
    }

    pthread_mutex_unlock(&mixer->mutex);
    return isMuted;
}

/**
 * @brief Set the solo state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @param solo Boolean solo state: non-zero to solo, zero to unsolo.
 *
 * @note Thread-safe: uses gMixer mutex to protect modifications.
 * @warning If globalChannelIndex is out of range, function logs a warning and returns.
 */
void Mixer_SetChannelSolo(int globalChannelIndex, int solo)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, (uint32_t)globalChannelIndex);
    if (channel) {
        channel->solo = solo != 0;
    }
    pthread_mutex_unlock(&mixer->mutex);
}

/**
 * @brief Get the solo state for a specified global channel index.
 *
 * @param globalChannelIndex The global channel index identifying the channel.
 * @return int Returns 1 if soloed, 0 if not.
 *
 * @note Thread-safe: uses gMixer mutex to protect access.
 * @warning Returns 0 (not soloed) if index out of range or not found.
 */
int Mixer_GetChannelSolo(int globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return 0;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, (uint32_t)globalChannelIndex);
    int isSolo = channel ? (channel->solo != 0) : 0;
    pthread_mutex_unlock(&mixer->mutex);
    return isSolo;
}

float Mixer_GetChannelGainReduction(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return 0.0f;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    float gainReductionDB = channel ? channel->lastGainReductionDB : 0.0f;
    pthread_mutex_unlock(&mixer->mutex);
    return gainReductionDB;
}

float Mixer_GetVirtualBusGainReduction(uint32_t busType, uint32_t busIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) {
        return 0.0f;
    }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_GetVirtualBusChannelLocked(mixer, busType, busIndex);
    float gainReductionDB = channel ? channel->lastGainReductionDB : 0.0f;
    pthread_mutex_unlock(&mixer->mutex);
    return gainReductionDB;
}

void Mixer_SetChannelPolarity(uint32_t globalChannelIndex, int flipped)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) { return; }
    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        channel->polarityFlipped = (flipped != 0) ? 1 : 0;
    }
    pthread_mutex_unlock(&mixer->mutex);
}

int Mixer_GetChannelPolarity(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) { return 0; }
    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    int result = channel ? channel->polarityFlipped : 0;
    pthread_mutex_unlock(&mixer->mutex);
    return result;
}

void Mixer_SetChannelDelay(uint32_t globalChannelIndex, uint32_t delaySamples)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) { return; }
    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (channel) {
        if (delaySamples == 0) {
            channel->delaySamples = 0;
            channel->delayWritePos = 0;
            if (channel->delayBuffer && channel->delayBufferCapacity > 0) {
                memset(channel->delayBuffer, 0, channel->delayBufferCapacity * sizeof(float));
            }
        } else {
            uint32_t needed = delaySamples + 1;
            if (channel->delayBuffer == NULL || channel->delayBufferCapacity < needed) {
                free(channel->delayBuffer);
                channel->delayBuffer = (float *)calloc(needed, sizeof(float));
                channel->delayBufferCapacity = channel->delayBuffer ? needed : 0;
                channel->delayWritePos = 0;
            } else {
                memset(channel->delayBuffer, 0, channel->delayBufferCapacity * sizeof(float));
                channel->delayWritePos = 0;
            }
            channel->delaySamples = channel->delayBuffer ? delaySamples : 0;
        }
    }
    pthread_mutex_unlock(&mixer->mutex);
}

uint32_t Mixer_GetChannelDelay(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) { return 0; }
    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    uint32_t result = channel ? channel->delaySamples : 0;
    pthread_mutex_unlock(&mixer->mutex);
    return result;
}

// ============================================================================
// POST-EQ BUFFER ACCESS (for FFT analysis of post-EQ audio)
// ============================================================================

int Mixer_ReadPostEQBuffer(uint32_t globalChannelIndex, float *outputArray, int maxCount)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer || !outputArray || maxCount <= 0) { return 0; }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (!channel || !channel->postEQRingBuffer) {
        pthread_mutex_unlock(&mixer->mutex);
        return 0;
    }
    pthread_mutex_unlock(&mixer->mutex);

    // Use read_latest to avoid stuttering when the UI thread falls behind the audio thread.
    return ringbuffer_read_latest(channel->postEQRingBuffer, outputArray, maxCount);
}

int Mixer_PostEQBufferFilled(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) { return 0; }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (!channel || !channel->postEQRingBuffer) {
        pthread_mutex_unlock(&mixer->mutex);
        return 0;
    }
    int filled = getRingBufferFillCount(channel->postEQRingBuffer);
    pthread_mutex_unlock(&mixer->mutex);
    return filled;
}

int Mixer_ReadPostDynamicsBuffer(uint32_t globalChannelIndex, float *outputArray, int maxCount)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer || !outputArray || maxCount <= 0) { return 0; }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (!channel || !channel->postDynamicsRingBuffer) {
        pthread_mutex_unlock(&mixer->mutex);
        return 0;
    }
    pthread_mutex_unlock(&mixer->mutex);

    return ringbuffer_read(channel->postDynamicsRingBuffer, outputArray, maxCount);
}

int Mixer_PostDynamicsBufferFilled(uint32_t globalChannelIndex)
{
    Mixer *mixer = GetGlobalMixerPointer();
    if (!mixer) { return 0; }

    pthread_mutex_lock(&mixer->mutex);
    MixerChannel *channel = Mixer_FindChannelByGlobalIndexLocked(mixer, globalChannelIndex);
    if (!channel || !channel->postDynamicsRingBuffer) {
        pthread_mutex_unlock(&mixer->mutex);
        return 0;
    }
    int filled = getRingBufferFillCount(channel->postDynamicsRingBuffer);
    pthread_mutex_unlock(&mixer->mutex);
    return filled;
}
