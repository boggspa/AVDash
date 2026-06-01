//
//  Mixer.h
//  AVCMeter
//
//  Created by Chris Izatt on 23/07/2025.
//

#ifndef Mixer_h
#define Mixer_h

#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <AudioToolbox/AudioToolbox.h>
#include "IOStreams.h"

// Mixer configuration constants
#define MIXER_MAX_DEVICES 64
#define MIXER_MAX_CHANNELS_PER_DEVICE 32
#define MIXER_MAX_GLOBAL_CHANNELS 1024
#define MIXER_MAX_OUTPUT_PAIRS 64
#define MIXER_MAX_AUX_SEND_BUSES 8
#define MIXER_MAX_FX_SEND_BUSES 4
#define MIXER_MAX_AUX_RETURN_BUSES 16
#define MIXER_MAX_FX_RETURN_BUSES 8
#define MIXER_EQ_MAX_FILTER_STAGES 4

// ============================================================================
// MIXER DATA STRUCTURES
// ============================================================================

typedef enum {
    MIXER_CHANNEL_INPUT = 0,
    MIXER_CHANNEL_OUTPUT = 1
} MixerChannelType;

typedef enum {
    MIXER_VIRTUAL_BUS_AUX_SEND = 0,
    MIXER_VIRTUAL_BUS_FX_SEND = 1,
    MIXER_VIRTUAL_BUS_AUX_RETURN = 2,
    MIXER_VIRTUAL_BUS_FX_RETURN = 3
} MixerVirtualBusType;

typedef enum {
    MIXER_EQ_FILTER_BUTTERWORTH = 0,
    MIXER_EQ_FILTER_CHEBYSHEV = 1,
    MIXER_EQ_FILTER_BESSEL = 2,
    MIXER_EQ_FILTER_LINKWITZ_RILEY = 3
} MixerEQFilterFamily;

typedef enum {
    MIXER_EQ_SLOPE_DB6 = 0,
    MIXER_EQ_SLOPE_DB12 = 1,
    MIXER_EQ_SLOPE_DB24 = 2,
    MIXER_EQ_SLOPE_DB48 = 3
} MixerEQFilterSlope;

// Callback type for input level notifications
typedef void (*MixerInputCallback)(uint32_t deviceID, uint32_t channelIndex, float rmsLevel, void* context);

typedef struct {
    uint32_t enabled;

    uint32_t highPassEnabled;
    uint32_t highPassFilterType;
    uint32_t highPassSlope;
    float highPassFrequencyHz;

    uint32_t lowEnabled;
    uint32_t lowFilterType;
    uint32_t lowSlope;
    float lowGainDB;
    float lowCenterFrequencyHz;
    float lowQ;

    uint32_t lowMidEnabled;
    uint32_t lowMidFilterType;
    uint32_t lowMidSlope;
    float lowMidGainDB;
    float lowMidCenterFrequencyHz;
    float lowMidQ;

    uint32_t midEnabled;
    uint32_t midFilterType;
    uint32_t midSlope;
    float midGainDB;
    float midCenterFrequencyHz;
    float midQ;

    uint32_t presenceEnabled;
    uint32_t presenceFilterType;
    uint32_t presenceSlope;
    float presenceGainDB;
    float presenceCenterFrequencyHz;
    float presenceQ;

    uint32_t highEnabled;
    uint32_t highFilterType;
    uint32_t highSlope;
    float highGainDB;
    float highCenterFrequencyHz;
    float highQ;

    uint32_t lowPassEnabled;
    uint32_t lowPassFilterType;
    uint32_t lowPassSlope;
    float lowPassFrequencyHz;
} MixerEQConfig;

typedef struct {
    uint32_t enabled;
    float thresholdDB;
    float ratio;
    float attackMilliseconds;
    float releaseMilliseconds;
    float makeupGainDB;
    float mix;
    uint32_t limiterEnabled;
    float limiterCeilingDB;
} MixerDynamicsConfig;

typedef struct {
    double b0;
    double b1;
    double b2;
    double a1;
    double a2;
    double x1;
    double x2;
    double y1;
    double y2;
    uint32_t active;
} MixerBiquadState;

typedef struct {
    double envelope;
    float lastGainReductionDB;
} MixerDynamicsState;

// Individual channel state
typedef struct {
    uint32_t deviceID;              // Device this channel belongs to
    MixerChannelType type;          // Input or output
    uint32_t deviceChannelIndex;    // Channel index within device
    uint32_t globalChannelIndex;    // Unique index across all devices

    // Channel parameters
    float gain;                     // Linear gain (0.0-2.0)
    float fader;                    // Fader position (0.0-1.2 with headroom)
    float pan;                      // Pan position (0.0=L, 0.5=C, 1.0=R)
    float auxSend;                  // Aux send level (0.0-1.0)
    float fxSend;                   // FX send level (0.0-1.0)
    uint32_t auxSendBusIndex;       // Selected aux send destination
    uint32_t fxSendBusIndex;        // Selected FX send destination
    int auxSendPreFade;             // 0=post-fade, 1=pre-fade
    int fxSendPreFade;              // 0=post-fade, 1=pre-fade
    int mute;                       // 0=unmuted, 1=muted
    int solo;                       // 0=not soloed, 1=soloed
    MixerEQConfig eqConfig;         // Parametric EQ insert state
    MixerDynamicsConfig dynamicsConfig; // Dynamics insert state
    MixerBiquadState highPassFilter[MIXER_EQ_MAX_FILTER_STAGES];
    MixerBiquadState lowBandFilter[MIXER_EQ_MAX_FILTER_STAGES];
    MixerBiquadState lowMidBandFilter[MIXER_EQ_MAX_FILTER_STAGES];
    MixerBiquadState midBandFilter[MIXER_EQ_MAX_FILTER_STAGES];
    MixerBiquadState presenceBandFilter[MIXER_EQ_MAX_FILTER_STAGES];
    MixerBiquadState highBandFilter[MIXER_EQ_MAX_FILTER_STAGES];
    MixerBiquadState lowPassFilter[MIXER_EQ_MAX_FILTER_STAGES];
    MixerDynamicsState dynamicsState;
    float lastGainReductionDB;

    // Polarity and delay (both applied pre-fader)
    int polarityFlipped;            // 0=normal, 1=phase-inverted
    uint32_t delaySamples;          // Delay in samples (0=off)
    float *delayBuffer;             // Circular delay buffer (allocated on demand)
    uint32_t delayBufferCapacity;   // Allocated size of delayBuffer
    uint32_t delayWritePos;         // Write head position in the circular buffer

    // Routing
    uint64_t outputRoutingMask;     // Bitmask for output pair routing

    // Metering
    float lastPeak;                 // Most recent post-fader peak value
    float lastRMS;                  // Most recent post-fader RMS value

    // Buffers
    RingBuffer *inputRingBuffer;    // Ring buffer for reading input
    float *outputBuffer;            // Temporary processing buffer
    RingBuffer *outputRingBuffer;   // Ring buffer for writing output
    RingBuffer *visualizationRingBuffer; // Dedicated ring buffer for visualizer reads
    RingBuffer *postEQRingBuffer;   // Ring buffer for post-EQ audio (FFT analysis)
    RingBuffer *postDynamicsRingBuffer; // Ring buffer for post-dynamics audio (scope/analysis)
} MixerChannel;

// Device grouping
typedef struct {
    uint32_t deviceID;
    MixerChannelType type;
    uint32_t numChannels;
    uint32_t globalChannelStartIndex;  // Index of first channel in global array
    int active;
    MixerChannel channels[MIXER_MAX_CHANNELS_PER_DEVICE];
} MixerDevice;

// Global mixer state
typedef struct {
    uint32_t sampleRate;
    uint32_t bufferFrames;

    MixerDevice devices[MIXER_MAX_DEVICES];
    uint32_t numDevices;
    uint32_t totalGlobalChannels;

    pthread_mutex_t mutex;  // Recursive mutex for thread safety

    // Callback for input level monitoring
    MixerInputCallback inputCallback;
    void *inputCallbackContext;

    // Meter-first virtual buses for send/return UI.
    float auxSendPeak[MIXER_MAX_AUX_SEND_BUSES];
    float auxSendRMS[MIXER_MAX_AUX_SEND_BUSES];
    float fxSendPeak[MIXER_MAX_FX_SEND_BUSES];
    float fxSendRMS[MIXER_MAX_FX_SEND_BUSES];
    float auxReturnPeak[MIXER_MAX_AUX_RETURN_BUSES];
    float auxReturnRMS[MIXER_MAX_AUX_RETURN_BUSES];
    float fxReturnPeak[MIXER_MAX_FX_RETURN_BUSES];
    float fxReturnRMS[MIXER_MAX_FX_RETURN_BUSES];

    // DSP state for virtual send/return buses.
    MixerChannel auxSendBusChannels[MIXER_MAX_AUX_SEND_BUSES];
    MixerChannel fxSendBusChannels[MIXER_MAX_FX_SEND_BUSES];
    MixerChannel auxReturnBusChannels[MIXER_MAX_AUX_RETURN_BUSES];
    MixerChannel fxReturnBusChannels[MIXER_MAX_FX_RETURN_BUSES];

    // Dedicated visualizer ring buffers for virtual buses.
    RingBuffer *auxSendRingBuffers[MIXER_MAX_AUX_SEND_BUSES];
    RingBuffer *fxSendRingBuffers[MIXER_MAX_FX_SEND_BUSES];
    RingBuffer *auxReturnRingBuffers[MIXER_MAX_AUX_RETURN_BUSES];
    RingBuffer *fxReturnRingBuffers[MIXER_MAX_FX_RETURN_BUSES];

    // Pre-allocated scratch buffers for ProcessBlock — eliminates malloc/free per audio block.
    float **scratchInputBuffers;     // [MIXER_MAX_GLOBAL_CHANNELS][bufferFrames]
    uint32_t scratchInputCount;      // Allocated channel count
    float **scratchAuxSendBuses;     // [MIXER_MAX_AUX_SEND_BUSES][bufferFrames]
    float **scratchFxSendBuses;      // [MIXER_MAX_FX_SEND_BUSES][bufferFrames]
    float **scratchAuxReturnBuses;   // [MIXER_MAX_AUX_RETURN_BUSES][bufferFrames]
    float **scratchFxReturnBuses;    // [MIXER_MAX_FX_RETURN_BUSES][bufferFrames]
} Mixer;

// ============================================================================
// MIXER FUNCTIONS
// ============================================================================

// Initialization
OSStatus Mixer_Init(uint32_t sampleRate, uint32_t bufferFrames);
void Mixer_Shutdown(void);

// Device/Channel registration (from MixerRegistration.c)
int Mixer_RegisterDevice(uint32_t deviceID, uint32_t type, uint32_t numChannels);
int Mixer_UnregisterDevice(uint32_t deviceID, uint32_t type);
int Mixer_AttachInputRingBuffer(uint32_t deviceID, uint32_t type, uint32_t deviceChannelIndex, void *ringBuffer);
int Mixer_FeedSingleChannelToMixer(uint32_t deviceID, uint32_t type, uint32_t deviceChannelIndex, const float *samples, uint32_t numFrames);
RingBuffer* Mixer_GetOutputChannelRingBuffer(uint32_t deviceID, uint32_t deviceChannelIndex);
float Mixer_GetOutputChannelPeak(uint32_t deviceID, uint32_t deviceChannelIndex);
float Mixer_GetOutputChannelRMS(uint32_t deviceID, uint32_t deviceChannelIndex);
float Mixer_GetAuxSendPeak(uint32_t busIndex);
float Mixer_GetAuxSendRMS(uint32_t busIndex);
float Mixer_GetFXSendPeak(uint32_t busIndex);
float Mixer_GetFXSendRMS(uint32_t busIndex);
float Mixer_GetAuxReturnPeak(uint32_t busIndex);
float Mixer_GetAuxReturnRMS(uint32_t busIndex);
float Mixer_GetFXReturnPeak(uint32_t busIndex);
float Mixer_GetFXReturnRMS(uint32_t busIndex);
int Mixer_ReadOutputChannelVisualBuffer(uint32_t deviceID, uint32_t deviceChannelIndex, float *outputArray, int maxCount);
int Mixer_OutputChannelVisualBufferFilled(uint32_t deviceID, uint32_t deviceChannelIndex);
int Mixer_ReadAuxSendBuffer(uint32_t busIndex, float *outputArray, int maxCount);
int Mixer_AuxSendBufferFilled(uint32_t busIndex);
int Mixer_ReadFXSendBuffer(uint32_t busIndex, float *outputArray, int maxCount);
int Mixer_FXSendBufferFilled(uint32_t busIndex);
int Mixer_ReadAuxReturnBuffer(uint32_t busIndex, float *outputArray, int maxCount);
int Mixer_AuxReturnBufferFilled(uint32_t busIndex);
int Mixer_ReadFXReturnBuffer(uint32_t busIndex, float *outputArray, int maxCount);
int Mixer_FXReturnBufferFilled(uint32_t busIndex);

// Core audio processing
OSStatus Mixer_ProcessBlock(void);  // Main audio processing engine
int Mixer_StartProcessingThread(void);
void Mixer_StopProcessingThread(void);
int Mixer_IsProcessingThreadRunning(void);

// Channel control
void Mixer_SetChannelGain(uint32_t globalChannelIndex, float gain);
void Mixer_SetChannelFader(uint32_t globalChannelIndex, float fader);
void Mixer_SetChannelPan(uint32_t globalChannelIndex, float pan);
void Mixer_SetChannelEQConfig(uint32_t globalChannelIndex, MixerEQConfig config);
void Mixer_SetChannelDynamicsConfig(uint32_t globalChannelIndex, MixerDynamicsConfig config);
void Mixer_SetChannelAuxSend(uint32_t globalChannelIndex, float sendLevel);
void Mixer_SetChannelFXSend(uint32_t globalChannelIndex, float sendLevel);
void Mixer_SetChannelAuxSendBus(uint32_t globalChannelIndex, uint32_t busIndex);
void Mixer_SetChannelFXSendBus(uint32_t globalChannelIndex, uint32_t busIndex);
void Mixer_SetChannelAuxSendPreFade(uint32_t globalChannelIndex, int preFade);
void Mixer_SetChannelFXSendPreFade(uint32_t globalChannelIndex, int preFade);
int Mixer_GetChannelAuxSendPreFade(uint32_t globalChannelIndex);
int Mixer_GetChannelFXSendPreFade(uint32_t globalChannelIndex);
void Mixer_SetChannelMute(uint32_t globalChannelIndex, int mute);
int Mixer_GetChannelMute(uint32_t globalChannelIndex);
void Mixer_SetChannelSolo(int globalChannelIndex, int solo);
int Mixer_GetChannelSolo(int globalChannelIndex);
float Mixer_CustomFaderDB(float value, float minDB, float maxDB);
float Mixer_GetChannelGainReduction(uint32_t globalChannelIndex);
void Mixer_SetChannelPolarity(uint32_t globalChannelIndex, int flipped);
int Mixer_GetChannelPolarity(uint32_t globalChannelIndex);
void Mixer_SetChannelDelay(uint32_t globalChannelIndex, uint32_t delaySamples);
uint32_t Mixer_GetChannelDelay(uint32_t globalChannelIndex);
void Mixer_SetVirtualBusEQConfig(uint32_t busType, uint32_t busIndex, MixerEQConfig config);
void Mixer_SetVirtualBusDynamicsConfig(uint32_t busType, uint32_t busIndex, MixerDynamicsConfig config);
float Mixer_GetVirtualBusGainReduction(uint32_t busType, uint32_t busIndex);

// Post-EQ buffer access (for real-time FFT analysis of post-EQ audio)
int Mixer_ReadPostEQBuffer(uint32_t globalChannelIndex, float *outputArray, int maxCount);
int Mixer_PostEQBufferFilled(uint32_t globalChannelIndex);

// Post-dynamics buffer access (for dynamics visualization)
int Mixer_ReadPostDynamicsBuffer(uint32_t globalChannelIndex, float *outputArray, int maxCount);
int Mixer_PostDynamicsBufferFilled(uint32_t globalChannelIndex);

// Accessor functions
Mixer* GetGlobalMixerPointer(void);
MixerChannel* GetGlobalInputChannelsPointer(void);
MixerChannel* GetGlobalOutputChannelsPointer(void);
int32_t Mixer_GetGlobalChannelIndex(uint32_t deviceID, uint32_t type, uint32_t deviceChannelIndex);


#endif /* Mixer_h */
