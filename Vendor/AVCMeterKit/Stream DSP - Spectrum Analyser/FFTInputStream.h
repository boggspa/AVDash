//
//  FFTInputStream.h
//  AVCMeter
//
//  Created by Chris Izatt on 28/06/2025.
//

#ifndef FFTInputStream_h
#define FFTInputStream_h

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include "FFTRingBuffer.h"  // Include your ring buffer header

#ifdef __cplusplus
extern "C" {
#endif

// Opaque type for the FFT input stream
typedef struct FFTInputStream FFTInputStream;

/**
 * Creates a new FFT input stream for the specified audio device.
 *
 * @param deviceID The CoreAudio device to stream from.
 * @param channelCount Number of input channels to capture.
 * @param sampleRate Processing sample rate (e.g. 48000).
 * @param bufferSize Capacity (in frames) of the internal ring buffer.
 * @return A pointer to the created FFTInputStream, or NULL on failure.
 */
FFTInputStream* FFTInputStream_Create(
    AudioDeviceID deviceID,
    UInt32 channelCount,
    UInt32 sampleRate,
    UInt32 bufferSize
);

/**
 * Destroys a previously created FFT input stream and frees resources.
 *
 * @param stream The FFT input stream to destroy.
 */
void FFTInputStream_Destroy(FFTInputStream* stream);

/**
 * Starts capturing audio for the FFT input stream.
 *
 * @param stream The FFT input stream to start.
 * @return noErr on success or an OSStatus error code.
 */
OSStatus FFTInputStream_Start(FFTInputStream* stream);

/**
 * Stops capturing audio for the FFT input stream.
 *
 * @param stream The FFT input stream to stop.
 * @return noErr on success or an OSStatus error code.
 */
OSStatus FFTInputStream_Stop(FFTInputStream* stream);

/**
 * Reads up to frameCount samples for a given channel from the ring buffer.
 *
 * @param stream        The FFT input stream.
 * @param channelIndex  Zero-based channel index to read.
 * @param outBuffer     Pointer to a float array to receive samples.
 * @param frameCount    Number of frames to read.
 * @return The number of frames actually read.
 */
int FFTInputStream_Read(
    FFTInputStream* stream,
    int channelIndex,
    float* outBuffer,
    int frameCount
);

/**
 * Returns the number of frames currently available in the ring buffer for a channel.
 *
 * @param stream       The FFT input stream.
 * @param channelIndex Zero-based channel index.
 * @return Number of frames filled in the buffer.
 */
int FFTInputStream_Filled(
    FFTInputStream* stream,
    int channelIndex
);

#ifdef __cplusplus
}
#endif

#endif /* FFTInputStream_h */
