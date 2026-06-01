//
//  IOStreams.h
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//
//  Header summary:
//  This file defines a simple thread-safe ring buffer structure used for
//  audio level data storage. It allows fixed-size circular buffering of
//  float values, commonly used to store recent audio RMS or peak values
//  for metering and analysis.
//
//  Core features include:
//  - Thread-safe write access via mutex
//  - Calculation of average and max values
//  - Optional full buffer readout for visualization
//

#ifndef IOStreams_h
#define IOStreams_h

#ifdef __cplusplus
extern "C" {
#endif

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdatomic.h>

#ifndef MAX_CHANNELS
#define MAX_CHANNELS 64 // Or set to the correct value for your app
#endif



// MARK: Typedefs


typedef void (*HALInputCallback)(float* rms, float* peak, UInt32 channelCount, void* context);
/// Starts capturing input from the specified AudioDeviceID using an IOProc.
///
/// // **Struct Definition**
/// Internal structure holding device ID, stream callback, level buffers,
/// and locking for thread safety.
typedef struct HALInputStream {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    pthread_mutex_t lock;
    float rms[MAX_CHANNELS];
    float peak[MAX_CHANNELS];
    UInt32 channelCount;
    void (*levelCallback)(float* rms, float* peak, UInt32 channelCount, void* context);
    void* callbackContext;
    AudioStreamBasicDescription streamFormat;
    // Pre-allocated buffer for deinterleaving one channel in HALIOProc.
    // Avoids VLA stack allocation on the real-time audio thread.
    float *deinterleaveBuf;
    uint32_t deinterleaveBufFrames;
} HALInputStream;

typedef struct HALInputStreamDevice {
    int deviceId;
    int numChannels;
    // Other device-specific members
} HALInputStreamDevice;

// These ensure that implementations can link to the globals.

struct RingBuffer {
    float* buffer;
    int capacity;
    int writeIndex;
    int readIndex;
    int filled;
    pthread_mutex_t lock;
};
typedef struct RingBuffer RingBuffer;

typedef struct {
    float* buffer;
    atomic_size_t writeIndex;
    atomic_size_t readIndex;
    size_t size;
} OutputChannelRingBuffer;

// **Callback Definition**
// Defines a function pointer type for audio metering callbacks.
// These callbacks receive arrays of RMS and peak levels for each channel.
typedef void (*MeteringCallback)(const float* rms,
                                 const float* peak,
                                 int channelCount,
                                 AudioDeviceID deviceID,
                                 void* context);


// MARK: HAL Input Stream Functions

/// Creates and starts a new input stream from the given audio device.
/// It uses a callback to deliver real-time peak and RMS audio levels for each channel.
/// The context pointer is passed back to the callback for reference.
HALInputStream* createHALInputStream(AudioDeviceID deviceID,
                                     HALInputCallback callback,
                                     void* context);

void destroyHALInputStream(HALInputStream* stream);

float getHALInputStreamRMS(HALInputStream* stream);
float getHALInputStreamPeak(HALInputStream* stream);

RingBuffer* getGlobalPeakRingBuffer(void);

void writeToSharedRingBuffers(HALInputStream* stream, const float* interleaved, UInt32 numFrames);

int HALInputStream_Open(HALInputStreamDevice *device);

void HALInputStream_Close(HALInputStreamDevice *device);

int HALInputStream_Read(HALInputStreamDevice *device, int channel, void *buffer, int frames);

int HALInputStream_AttachRingBuffer(HALInputStreamDevice *device, int channel, RingBuffer *ringBuffer);


// MARK: RingBuffer Functions

extern _Atomic float gPostGain[MAX_CHANNELS];



// RingBuffer creation and destruction
RingBuffer* createRingBuffer(int capacity);
void destroyRingBuffer(RingBuffer* rb);

// Write operations
void writeRingBuffer(RingBuffer* rb, float value);
void deinterleaveAndWriteToRingBuffers(const float* interleaved, int numFrames, int numChannels, RingBuffer** channelBuffers);

// Analytics operations
float averageRingBuffer(RingBuffer* rb);
float maxRingBuffer(RingBuffer* rb);
void clearRingBuffer(RingBuffer* rb);
int getRingBufferFillCount(RingBuffer* rb);
float mostRecentRingBuffer(RingBuffer* buffer);

int ringbuffer_read(RingBuffer* rb, float* outputArray, int maxCount);
int ringbuffer_read_latest(RingBuffer* rb, float* outputArray, int maxCount);

// Bulk access for visualization or debug
void ringbuffer_read_all(RingBuffer* buffer, float* outputArray, int maxCount);

// Post-gain control (for per-channel audio gain)
void RingBuffer_SetPostGain(int channel, float gain);
void RingBuffer_ApplyPostGain(int channel, float* buffer, size_t frames);
void RingBuffer_GlobalInit(void);


// MARK: HAL Output Stream Functions

// Expose this function to Swift via bridging header
OSStatus HALOutputStreamPerform(AudioDeviceID deviceID, AudioBufferList *outputData, UInt32 *ioNumFrames);
OSStatus HAL_StartOutputStream(AudioDeviceID deviceID);
OSStatus HAL_StopOutputStream(AudioDeviceID deviceID);
int getAllOutputAudioDeviceIDs(AudioDeviceID* outDevices, int maxDevices);
void InitOutputRingBuffer(OutputChannelRingBuffer*, size_t channelCount, size_t bufferSize);


// MARK: Metering Engine Functions

// **Metering Control**
// Start metering without a callback, suitable for simple use cases.
OSStatus startMetering(AudioDeviceID deviceID);

// Stops ongoing metering for the given device.
OSStatus stopMetering(AudioDeviceID deviceID);

// Start metering and specify a callback to handle real-time level updates.
OSStatus startMeteringWithCallback(AudioDeviceID deviceID,
                                   MeteringCallback callback,
                                   void* context);

// **Ring Buffer Access**
// Returns the average peak value from the shared ring buffer.
float getBufferedPeakAverage(void);

// Provides access to the global peak ring buffer instance.
RingBuffer* getGlobalPeakRingBuffer(void);

// Returns the most recent peak value for a given channel in the shared ring buffer.
float getMostRecentPeakForChannel(AudioDeviceID deviceID, int channel);


#ifdef __cplusplus
}
#endif

#endif /* IOStreams_h */
