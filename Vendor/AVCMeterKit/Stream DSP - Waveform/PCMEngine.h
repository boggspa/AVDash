//
//  PCMEngine.h
//  AVCMeter
//
//  Created by Chris Izatt on 24/06/2025.
//

#ifndef PCMEngine_h
#define PCMEngine_h

#include <AudioToolbox/AudioToolbox.h>
#include "PCMRingBuffer.h"

#define MAX_CHANNELS 64

// Callback to receive raw PCM samples per device
// float** pcm: array of channel pointers
// UInt32 numFrames: number of frames in buffer
// UInt32 channelCount: number of channels
// void* context: user-defined context
typedef void (*PCMCallback)(float** pcm, UInt32 numFrames, UInt32 channelCount, void* context);

// Internal stream object (used to track stream state per device)
typedef struct PCMStream {
    AudioDeviceID deviceID;
    PCMCallback pcmCallback;
    void* context;
    PCMRingBuffer* ringBuffer;
    struct PCMStream* next;
} PCMStream;

extern float* sampleArrays[MAX_CHANNELS];

// Start PCM stream for a device and register callback
OSStatus startPCMStreamWithCallback(AudioDeviceID deviceID,
                                    PCMCallback callback,
                                    void* context);

// Stop and release PCM stream for a device
OSStatus stopPCMStream(AudioDeviceID deviceID);

// Get access to ring buffer for a specific channel
PCMRingBuffer* getPCMRingBufferForChannel(AudioDeviceID deviceID, int channel);

// Fetch the latest samples from the ring buffer into a float array
int fetchLatestSamples(AudioDeviceID deviceID, int channel, float* outSamples, int frameCount);

#endif /* PCMEngine_h */
