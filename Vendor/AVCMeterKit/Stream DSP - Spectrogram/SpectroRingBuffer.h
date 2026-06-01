#ifndef SpectroRingBuffer_h
#define SpectroRingBuffer_h

#include <stdio.h>

///
/// @header SpectroRingBuffer
/// @brief Per-device, per-channel ring buffer system for storing FFT magnitude history.
/// @discussion
/// The SpectroRingBuffer module provides circular buffers used to store FFT magnitude frames
/// for each audio device and channel. It supports writing raw and interleaved frames, as well
/// as retrieving historical frames for visualization or analysis.
///

///
/// @function SpectroRingBuffer_Init
/// @brief Initializes a ring buffer for FFT magnitude history per device and channel.
/// @discussion Each channel receives a circular buffer that stores `historyLengthFrames`
/// FFT frames, each containing `fftSize` magnitude values.
/// @param numDevices Number of audio devices.
/// @param channelsPerDevice Pointer to an array containing the number of channels for each device.
/// @param numFrames Number of historical FFT frames to retain per channel.
/// @param fftSize Number of FFT bins per frame (typically half the FFT window size).
///
void SpectroRingBuffer_Init(int numDevices, int *channelsPerDevice, int numFrames, int fftSize);

///
/// @function SpectroRingBuffer_Write
/// @brief Writes a single FFT magnitude frame into the buffer for a specific channel.
/// @discussion This call writes `fftSize` magnitudes to the ring buffer, overwriting old frames as needed.
/// @param deviceID Audio device identifier.
/// @param channel Channel index to write to.
/// @param fftMagnitudes Pointer to an array of floats of length `fftSize`.
///
void SpectroRingBuffer_Write(int deviceID, int channel, const float* fftMagnitudes);

///
/// @function SpectroRingBuffer_ReadFrame
/// @brief Retrieves a specific FFT magnitude frame from the ring buffer.
/// @discussion Returns a pointer to the frame at a given historical offset, where 0 is most recent.
/// @param deviceID Audio device identifier.
/// @param channel Channel index to read from.
/// @param frameOffset Frame offset from the most recent (0 = latest frame).
/// @return Const pointer to the FFT frame, or NULL if unavailable.
///
const float* SpectroRingBuffer_ReadFrame(int deviceID, int channel, int frameOffset);

///
/// @function SpectroRingBuffer_WriteInterleaved
/// @brief Writes interleaved FFT magnitude data for all channels into their respective buffers.
/// @discussion The interleaved input should be of size (`fftSize` × `numChannels`), arranged as:
/// [bin0_ch0, bin0_ch1, ..., bin1_ch0, bin1_ch1, ..., ...].
/// @param deviceID Target audio device ID.
/// @param interleaved Pointer to the interleaved float array of FFT magnitudes.
/// @param numChannels Number of audio channels in the input.
/// @param fftSize Number of FFT bins per frame.
///
void SpectroRingBuffer_WriteInterleaved(int deviceID, const float* interleaved, int numChannels, int fftSize);

#endif /* SpectroRingBuffer_h */
