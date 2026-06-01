//
//  WaveformAnalyser.c
//  PodcastPreview
//
//  Created by Chris Izatt on 18/03/2026.
//

#include "WaveformAnalyser.h"
#include "RingBuffer.h"
#include <string.h>

int RingBuffer_ReadChannel(RingBuffer *rb, int32_t channel, float *outSamples, uint32_t sampleCount) {
    if (!rb || !outSamples || sampleCount == 0) {
        return -1;
    }
    
    if (channel < 0) {
        return -2;
    }
    
    // Read samples from the ring buffer for the specified channel
    size_t framesRead = RingBuffer_Read(rb, outSamples, (size_t)sampleCount, (uint32_t)channel);
    
    // If we read fewer frames than requested, zero-pad the rest
    if (framesRead < sampleCount) {
        memset(outSamples + framesRead, 0, (sampleCount - framesRead) * sizeof(float));
    }
    
    return 0;
}
