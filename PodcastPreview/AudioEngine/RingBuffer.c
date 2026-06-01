//
//  RingBuffer.c
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//


// --- Implementation start ---
#include "RingBuffer.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>

struct RingBuffer {
    float **channelBuffers;
    size_t frameCapacity;
    uint32_t channels;
    _Atomic size_t *writePositions;
    _Atomic size_t *framesWritten;  // Total frames written (for tracking how much data exists)
};

static void RingBuffer_PrepareRealtimeMemory(void *memory, size_t byteCount) {
    if (!memory || byteCount == 0) return;

#if defined(MADV_WILLNEED)
    madvise(memory, byteCount, MADV_WILLNEED);
#endif
    (void)mlock(memory, byteCount);

    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0) pageSize = 4096;

    volatile unsigned char *cursor = (volatile unsigned char *)memory;
    for (size_t offset = 0; offset < byteCount; offset += (size_t)pageSize) {
        cursor[offset] = cursor[offset];
    }
    cursor[byteCount - 1] = cursor[byteCount - 1];
}

RingBuffer *RingBuffer_Create(size_t frameCapacity, uint32_t channels) {
    if (channels == 0 || frameCapacity == 0) return NULL;
    RingBuffer *rb = (RingBuffer *)calloc(1, sizeof(RingBuffer));
    if (!rb) return NULL;
    rb->frameCapacity = frameCapacity;
    rb->channels = channels;
    rb->channelBuffers = (float **)calloc(channels, sizeof(float*));
    rb->writePositions = (_Atomic size_t *)calloc(channels, sizeof(_Atomic size_t));
    rb->framesWritten = (_Atomic size_t *)calloc(channels, sizeof(_Atomic size_t));
    if (!rb->channelBuffers || !rb->writePositions || !rb->framesWritten) { 
        free(rb->channelBuffers); 
        free(rb->writePositions); 
        free(rb->framesWritten); 
        free(rb); 
        return NULL; 
    }
    RingBuffer_PrepareRealtimeMemory(rb, sizeof(*rb));
    RingBuffer_PrepareRealtimeMemory(rb->channelBuffers, channels * sizeof(float *));
    RingBuffer_PrepareRealtimeMemory(rb->writePositions, channels * sizeof(_Atomic size_t));
    RingBuffer_PrepareRealtimeMemory(rb->framesWritten, channels * sizeof(_Atomic size_t));
    for (uint32_t c = 0; c < channels; ++c) {
        rb->channelBuffers[c] = (float *)calloc(frameCapacity, sizeof(float));
        if (!rb->channelBuffers[c]) {
            for (uint32_t i = 0; i < c; ++i) free(rb->channelBuffers[i]);
            free(rb->channelBuffers); 
            free(rb->writePositions); 
            free(rb->framesWritten); 
            free(rb); 
            return NULL;
        }
        RingBuffer_PrepareRealtimeMemory(rb->channelBuffers[c], frameCapacity * sizeof(float));
    }
    return rb;
}

void RingBuffer_Destroy(RingBuffer *rb) {
    if (!rb) return;
    for (uint32_t c = 0; c < rb->channels; ++c) free(rb->channelBuffers[c]);
    free(rb->channelBuffers);
    free(rb->writePositions);
    free(rb->framesWritten);
    free(rb);
}

void RingBuffer_Write(RingBuffer *rb, const void *data, size_t bytes, uint32_t channel) {
    if (!rb || channel >= rb->channels || !data) return;

    size_t frameCount = bytes / sizeof(float);
    const float *input = (const float *)data;
    float *buffer = rb->channelBuffers[channel];

    // Single-producer: load current write position (relaxed is fine for the producer).
    size_t pos = atomic_load_explicit(&rb->writePositions[channel], memory_order_relaxed);

    for (size_t i = 0; i < frameCount; ++i) {
        buffer[pos] = input[i];
        pos = (pos + 1) % rb->frameCapacity;
    }

    // Update total frames written (for tracking available data)
    atomic_fetch_add_explicit(&rb->framesWritten[channel], frameCount, memory_order_relaxed);

    // Publish the new write position after writing samples.
    atomic_store_explicit(&rb->writePositions[channel], pos, memory_order_release);
}

void RingBuffer_WriteInterleaved(RingBuffer *rb, const float *data, size_t frames, uint32_t channels) {
    if (!rb || !data || frames == 0 || channels == 0) return;

    uint32_t channelCount = channels < rb->channels ? channels : rb->channels;
    for (uint32_t channel = 0; channel < channelCount; ++channel) {
        size_t frameCount = frames;
        float *buffer = rb->channelBuffers[channel];
        size_t pos = atomic_load_explicit(&rb->writePositions[channel], memory_order_relaxed);

        for (size_t frame = 0; frame < frameCount; ++frame) {
            buffer[pos] = data[(frame * channelCount) + channel];
            pos = (pos + 1) % rb->frameCapacity;
        }

        atomic_fetch_add_explicit(&rb->framesWritten[channel], frameCount, memory_order_relaxed);
        atomic_store_explicit(&rb->writePositions[channel], pos, memory_order_release);
    }
}

// Read audio data from the buffer for the specified channel. Returns number of frames read.
// 'dest' is a float pointer, 'frames' is number of frames to read, 'channel' is channel index.
size_t RingBuffer_Read(RingBuffer *rb, float *dest, size_t frames, uint32_t channel) {
    if (!rb || channel >= rb->channels || !dest) return 0;
    
    size_t cap = rb->frameCapacity;
    // Single-consumer: acquire ensures we see samples written before the published writePos.
    size_t writePos = atomic_load_explicit(&rb->writePositions[channel], memory_order_acquire);
    size_t totalWritten = atomic_load_explicit(&rb->framesWritten[channel], memory_order_acquire);
    float *buffer = rb->channelBuffers[channel];

    // Determine how many frames are actually available
    size_t available = (totalWritten < cap) ? totalWritten : cap;
    
    // Clamp requested frames to what's actually available
    if (frames > available) frames = available;
    if (frames == 0) return 0;

    // Read backwards from the write position to get the most recent samples
    size_t start = (writePos + cap - frames) % cap;
    for (size_t i = 0; i < frames; ++i) {
        size_t idx = (start + i) % cap;
        dest[i] = buffer[idx];
    }
    return frames;
}
// --- Implementation end ---
