//
//  MeteringDSP.c
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

// Use shared MeteringResult and RingBuffer from AudioEngine.h
#include "AudioEngine.h"   // brings in RingBuffer.h and MeteringResult
#include <math.h>
#include <stdlib.h>

// Global metering calibration gain (linear). Default 1.0 (0 dB).
static float gMeteringCalibrationGain = 1.0f;

// Set metering calibration in dB (applied before peak/RMS computation)
void MeteringDSP_SetCalibrationDB(float db) {
    // gain = 10^(db/20)
    gMeteringCalibrationGain = powf(10.0f, db / 20.0f);
}


// Returns 0 on success; fills outMetering with results
int MeteringDSP_Compute(RingBuffer *rb, uint32_t channel, size_t frames, MeteringResult *outMetering) {
    if (!rb || !outMetering || frames == 0) return -1;
    float *buffer = (float*)malloc(frames * sizeof(float));
    if (!buffer) return -2;
    size_t read = RingBuffer_Read(rb, buffer, frames, channel);
    if (read == 0) { free(buffer); return -3; }
    float sumSquares = 0.0f;
    float peak = 0.0f;
    for (size_t i = 0; i < read; ++i) {
        float val = buffer[i] * gMeteringCalibrationGain;
        sumSquares += val * val;
        float absVal = fabsf(val);
        if (absVal > peak) peak = absVal;
    }
    outMetering->peak = peak;
    outMetering->rms = sqrtf(sumSquares / read);
    free(buffer);
    return 0;
}

