//
//  SpectroRingBuffer.c
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//



#include "SpectroRingBuffer.h"
#include <pthread.h>

/*
 ==============================================================================
  SpectroRingBuffer.c
  Mission: This module manages a per-channel, per-frame circular buffer for
  FFT magnitude values. It stores high-resolution spectral data across time
  and supports concurrent access for rendering and processing.

  Responsibilities:
  - Allocate and manage 2D circular buffers (channels × frames × bins).
  - Provide atomic write and read interfaces.
  - Support efficient data decay and thresholding if needed.
  - Optimized for predictable access patterns and low latency.

  Used by: SpectroProcessor.swift, MetalSpectroRenderer.swift
 ==============================================================================
*/

#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <stdio.h>

/// @struct ChannelBuffer
/// @brief Represents a single channel's ring buffer for Spectro (FFT) frames.
/// Each frame is an array of spectral magnitudes over time.
/// @field frames 2D array of spectral frames.
/// @field writeIndex Atomic index for ring buffer writing.
/// @field numFrames Total frames stored (history length).
/// @field fftSize Number of FFT bins per frame.
typedef struct {
    float **frames;     // [frames][bins]
    atomic_int writeIndex;
    int numFrames;
    int fftSize;
} ChannelBuffer;

/// @struct DeviceBufferSet
/// @brief Groups channel buffers under a single device ID.
/// @field channels Array of channel-specific ring buffers.
/// @field totalChannels Number of channels for this device.
typedef struct {
    ChannelBuffer* channels;
    int totalChannels;
} DeviceBufferSet;

static DeviceBufferSet* deviceBuffers = NULL;
static int totalDevices = 0;




// --- SpectroRingBuffer Implementation ---

#include "SpectroRingBuffer.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// ChannelBuffer and DeviceBufferSet already typedef'd above.

// Helper: allocate 2D array for frames
static float **allocate_frames(int numFrames, int fftSize) {
    float **frames = (float **)malloc(numFrames * sizeof(float *));
    if (!frames) return NULL;
    for (int i = 0; i < numFrames; ++i) {
        frames[i] = (float *)calloc(fftSize, sizeof(float));
        if (!frames[i]) {
            // Cleanup already allocated
            for (int j = 0; j < i; ++j) free(frames[j]);
            free(frames);
            return NULL;
        }
    }
    return frames;
}

void SpectroRingBuffer_Init(int numDevices, int *channelsPerDevice, int numFrames, int fftSize) {
    // Free previous buffers if any
    if (deviceBuffers) {
        for (int d = 0; d < totalDevices; ++d) {
            DeviceBufferSet *dev = &deviceBuffers[d];
            if (dev->channels) {
                for (int c = 0; c < dev->totalChannels; ++c) {
                    ChannelBuffer *ch = &dev->channels[c];
                    if (ch->frames) {
                        for (int f = 0; f < ch->numFrames; ++f)
                            free(ch->frames[f]);
                        free(ch->frames);
                    }
                }
                free(dev->channels);
            }
        }
        free(deviceBuffers);
    }
    totalDevices = numDevices;
    deviceBuffers = (DeviceBufferSet *)calloc(numDevices, sizeof(DeviceBufferSet));
    for (int d = 0; d < numDevices; ++d) {
        int nCh = channelsPerDevice[d];
        deviceBuffers[d].channels = (ChannelBuffer *)calloc(nCh, sizeof(ChannelBuffer));
        deviceBuffers[d].totalChannels = nCh;
        for (int c = 0; c < nCh; ++c) {
            ChannelBuffer *ch = &deviceBuffers[d].channels[c];
            ch->frames = allocate_frames(numFrames, fftSize);
            ch->numFrames = numFrames;
            ch->fftSize = fftSize;
            atomic_init(&ch->writeIndex, 0);
        }
    }
}

// Write a single frame (fftSize floats) to the ring buffer for a channel
void SpectroRingBuffer_Write(int deviceIdx, int channelIdx, const float *frame) {
    if (!deviceBuffers || deviceIdx < 0 || deviceIdx >= totalDevices)
        return;
    DeviceBufferSet *dev = &deviceBuffers[deviceIdx];
    if (channelIdx < 0 || channelIdx >= dev->totalChannels)
        return;
    ChannelBuffer *ch = &dev->channels[channelIdx];
    int idx = atomic_load(&ch->writeIndex);
    // Copy frame into buffer
    memcpy(ch->frames[idx], frame, sizeof(float) * ch->fftSize);
    // Move writeIndex forward
    int nextIdx = (idx + 1) % ch->numFrames;
    atomic_store(&ch->writeIndex, nextIdx);
}

// Read a pointer to a historical frame (offset: 0 = most recent, 1 = previous, etc.)
const float *SpectroRingBuffer_ReadFrame(int deviceIdx, int channelIdx, int offset) {
    if (!deviceBuffers || deviceIdx < 0 || deviceIdx >= totalDevices)
        return NULL;
    DeviceBufferSet *dev = &deviceBuffers[deviceIdx];
    if (channelIdx < 0 || channelIdx >= dev->totalChannels)
        return NULL;
    ChannelBuffer *ch = &dev->channels[channelIdx];
    int writeIdx = atomic_load(&ch->writeIndex);
    // The most recent frame is at (writeIdx - 1 + numFrames) % numFrames
    int idx = (writeIdx - 1 - offset + ch->numFrames) % ch->numFrames;
    return ch->frames[idx];
}

// Write interleaved frames: input is [channel0, channel1, ...channelN, channel0, ...] for fftSize bins
void SpectroRingBuffer_WriteInterleaved(int deviceIdx, const float *interleaved, int numChannels, int fftSize) {
    if (!deviceBuffers || deviceIdx < 0 || deviceIdx >= totalDevices)
        return;
    DeviceBufferSet *dev = &deviceBuffers[deviceIdx];
    if (numChannels > dev->totalChannels)
        numChannels = dev->totalChannels;
    // For each channel, build its frame and call Write
    for (int ch = 0; ch < numChannels; ++ch) {
        float *frame = (float *)alloca(sizeof(float) * fftSize);
        for (int bin = 0; bin < fftSize; ++bin) {
            frame[bin] = interleaved[bin * numChannels + ch];
        }
        SpectroRingBuffer_Write(deviceIdx, ch, frame);
    }
}
