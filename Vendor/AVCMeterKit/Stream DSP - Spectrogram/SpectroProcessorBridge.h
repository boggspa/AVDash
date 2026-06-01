//
//  SpectroProcessorBridge.h
//  AVCMeter
//
//  Created by Chris Izatt on 30/06/2025.
//


#ifndef SpectroProcessorBridge_h
#define SpectroProcessorBridge_h

#include <stdint.h>

/// Exposes the Swift `SpectroProcessor_HandleInput` function to C.
///
/// @param deviceID The audio device ID.
/// @param channel The audio input channel index.
/// @param windowedBuffer A pointer to a float buffer containing audio samples.
/// @param frameCount The number of samples in the buffer.
void SpectroProcessor_HandleInput(int32_t deviceID, int32_t channel, const float* windowedBuffer, int32_t frameCount);


#endif /* SpectroProcessorBridge_h */
