// RingBuffer.h
// PodcastPreview
// Simple multi-channel audio ring buffer for analysis/metering pipelines

#ifndef RINGBUFFER_H
#define RINGBUFFER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RingBuffer RingBuffer;

// Create a ring buffer for the given number of frames and channels. Returns NULL on failure.
RingBuffer *RingBuffer_Create(size_t frameCapacity, uint32_t channels);

// Destroy the buffer and free resources.
void RingBuffer_Destroy(RingBuffer *buffer);

// Write audio data into the buffer for the specified channel.
// 'data' is PCM samples, 'bytes' is number of bytes, 'channel' is channel index.
void RingBuffer_Write(RingBuffer *buffer, const void *data, size_t bytes, uint32_t channel);

// Write interleaved float PCM into all channels of the ring buffer.
// 'data' must contain frames * channels float samples.
void RingBuffer_WriteInterleaved(RingBuffer *buffer, const float *data, size_t frames, uint32_t channels);

// Read audio data from the buffer for the specified channel. Returns number of frames read.
// 'dest' is a float pointer, 'frames' is number of frames to read, 'channel' is channel index.
size_t RingBuffer_Read(RingBuffer *buffer, float *dest, size_t frames, uint32_t channel);

#ifdef __cplusplus
}
#endif

#endif // RINGBUFFER_H
