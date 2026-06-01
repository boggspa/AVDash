//
//  AudioBridge.h
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//
//  This header defines the public interface between Swift and the lower-level CoreAudio/HAL input stream layer.
//  It enables starting/stopping audio metering on input devices, retrieving device metadata, and working with ring buffers.
//  It also supports aggregate device creation and input stream callbacks, intended for use in real-time metering and visualization tools.
//

#ifndef AudioBridge_h
#define AudioBridge_h


#include "AudioServerPlugIn.h"
#include "IOStreams.h"

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stddef.h>




#ifdef __cplusplus
class SharedRingBuffer;
extern "C" {
#else
typedef struct SharedRingBuffer SharedRingBuffer;
#endif



#ifdef __cplusplus
extern "C" {
#endif

// **Metering Callback Definition**
// This defines a function pointer type used to receive metering data from the HAL input stream.
typedef void (*MeteringCallback)(const float* rms, const float* peak, int channelCount, AudioDeviceID deviceID, void* context);

// **Metering Control Functions**
// Starts or stops metering on a specific input audio device.
OSStatus startMetering(AudioDeviceID deviceID);
OSStatus stopMetering(AudioDeviceID deviceID);
// Starts metering and provides a callback to receive real-time RMS and peak values per channel.
OSStatus startMeteringWithCallback(AudioDeviceID deviceID,
                                   MeteringCallback callback,
                                   void* context);

// **Device Enumeration**
// Returns a list of all available input audio device IDs on the system.
int getAllInputAudioDeviceIDs(AudioDeviceID* outDevices, int maxDevices);

// **Device Static Info**
// Retrieves metadata such as name, sample rate, transport type, and UID for a given audio device.
const char* getDeviceName(AudioDeviceID deviceID);
Float64 getSampleRate(AudioDeviceID deviceID);
const char* getDeviceTransportType(AudioDeviceID deviceID);
const char* getDeviceUID(AudioDeviceID deviceID);

// **Channel Count Accessors**
// Gets the number of input/output channels for the specified device.
UInt32 getDeviceInputChannelCount(AudioDeviceID deviceID);
UInt32 getDeviceOutputChannelCount(AudioDeviceID deviceID);

// **Aggregate Device Management**
// Allows creating or destroying virtual aggregate input devices for simultaneous metering.
OSStatus createPrivateAggregateDevice(AudioDeviceID* outAggregateDeviceID);
OSStatus destroyAggregateDevice(AudioDeviceID aggregateDeviceID);

// **HAL Input Stream Handling**
// Low-level stream management used to read input buffers from a device with a callback.
HALInputStream* createHALInputStream(AudioDeviceID deviceID, HALInputCallback callback, void* context);
void destroyHALInputStream(HALInputStream*);
// Expose function to Swift for starting a HAL stream
void StartHALStreamFromSwift(AudioDeviceID deviceID);

// **Ring Buffer Integration**
// Includes definitions for managing shared buffer structures for audio levels.


// **Audio Data Ring Buffer Utilities**
// Used for full-resolution audio data transmission between devices.

// === Shared Audio Frame Buffer (C++ interop) ===
// Returns a pointer to the shared buffer used for transmitting audio between MixerEngine and other components
SharedRingBuffer* getSharedRingBuffer(void);
void setSharedRingBuffer(SharedRingBuffer* buffer);

// Write interleaved audio frames into the shared ring buffer (e.g., from HAL or aggregate device)
void writeInterleavedAudioToSharedBuffer(SharedRingBuffer* buffer, const float* data, int frameCount, int numChannels);

// Read interleaved audio frames from the shared ring buffer (e.g., for sending over network or rendering to virtual device)
SharedRingBuffer* getSharedRingBuffer(void);


float SharedRingBuffer_GetPeak(AudioDeviceID deviceID, int channelIndex);

// Channel mute state query from Swift
bool getInputChannelMute(AudioDeviceID deviceID, int channelIndex);


#ifdef __cplusplus
}
#endif

#endif /* AudioBridge_h */

#ifdef __cplusplus
} // extern "C"
#endif

// Swift callback function that receives metering data
// This will be implemented in Swift and called from the C wrapper
extern void SwiftMeterCallback(const float* rmsArray, const float* peakArray, int channelCount, AudioDeviceID deviceID, void* ctx);

// C wrapper that bridges HAL callback to Swift
static inline MeteringCallback GetSwiftCallbackWrapper(void) {
    extern void SwiftCallbackWrapper(float* rms, float* peak, unsigned int channelCount, void* refCon);
    return (MeteringCallback)SwiftCallbackWrapper;
}
