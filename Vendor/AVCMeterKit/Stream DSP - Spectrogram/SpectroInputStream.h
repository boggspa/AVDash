//
//  SpectroInputStream.h
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//

#ifndef SpectroInputStream_h
#define SpectroInputStream_h

#include <CoreAudio/CoreAudio.h>

///
/// @header SpectroInputStream
/// @brief Manages audio input streaming for real-time spectrogram processing using Core Audio.
/// @discussion
/// This header defines the interface for setting up, controlling, and destroying input streams
/// that route live audio data into the spectrogram processing pipeline. Input data is passed
/// from Core Audio’s HAL (Hardware Abstraction Layer) using IOProc callbacks and dispatched per channel.
///
/// The API supports multiple input streams per device and safely handles interleaved and
/// non-interleaved audio formats.
///

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque structure representing a managed input stream instance.
typedef struct SpectroInputStream SpectroInputStream;

#pragma mark - Lifecycle

/// @function SpectroInputStream_Create
/// @brief Creates and registers a new input stream for a given device.
/// @param deviceID The AudioDeviceID of the input device.
/// @param channelCount The number of input channels to process.
/// @return A pointer to the created SpectroInputStream instance, or NULL on failure.
SpectroInputStream* SpectroInputStream_Create(AudioDeviceID deviceID, UInt32 channelCount);

/// @function SpectroInputStream_Destroy
/// @brief Destroys and unregisters a previously created input stream.
/// @param stream Pointer to the SpectroInputStream to destroy.
void SpectroInputStream_Destroy(SpectroInputStream* stream);

#pragma mark - Streaming Control

/// @function SpectroInputStream_Start
/// @brief Starts the input stream for the specified stream/device.
/// @param stream Pointer to the SpectroInputStream instance.
/// @return An OSStatus result code (noErr on success).
OSStatus SpectroInputStream_Start(SpectroInputStream* stream);

/// @function SpectroInputStream_Stop
/// @brief Stops the input stream for the specified stream/device.
/// @param stream Pointer to the SpectroInputStream instance.
/// @return An OSStatus result code (noErr on success).
OSStatus SpectroInputStream_Stop(SpectroInputStream* stream);

#pragma mark - Utility

/// @function SpectroInputStream_Clear
/// @brief Clears any internal buffers associated with the stream (no-op if none exist).
/// @param stream Pointer to the SpectroInputStream instance.
void SpectroInputStream_Clear(SpectroInputStream* stream);

/// @function SpectroInputStream_Read
/// @brief Reads audio samples from the specified channel of the stream.
/// @param stream Pointer to the SpectroInputStream instance.
/// @param channel Channel index to read from.
/// @param buffer Pointer to an output buffer to receive audio data.
/// @param frames Number of frames to read.
/// @return Number of frames actually read.
int SpectroInputStream_Read(SpectroInputStream* stream, int channel, float* buffer, int frames);

/// @function SpectroInputStream_Filled
/// @brief Returns the number of filled frames for a given channel.
/// @param stream Pointer to the SpectroInputStream instance.
/// @param channel Channel index to query.
/// @return Number of available frames.
int SpectroInputStream_Filled(SpectroInputStream* stream, int channel);

#ifdef __cplusplus
}
#endif

#endif /* SpectroInputStream_h */
