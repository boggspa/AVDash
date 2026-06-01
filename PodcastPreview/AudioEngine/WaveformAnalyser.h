//
//  WaveformAnalyser.h
//  PodcastPreview
//
//  Created by Chris Izatt on 18/03/2026.
//

#ifndef WaveformAnalyser_h
#define WaveformAnalyser_h

#include <stdint.h>
#include <stddef.h>
#include "RingBuffer.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Read raw audio samples from a specific channel in the ring buffer
/// @param rb Ring buffer instance
/// @param channel Channel index (0-based)
/// @param outSamples Output buffer for samples
/// @param sampleCount Number of samples to read
/// @return 0 on success, non-zero on error
int RingBuffer_ReadChannel(RingBuffer *rb, int32_t channel, float *outSamples, uint32_t sampleCount);

#ifdef __cplusplus
}
#endif

#endif /* WaveformAnalyser_h */
