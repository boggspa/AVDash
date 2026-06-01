#include "PCMRingBuffer.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>  // Added as per instructions



// Allocate and initialize a new PCM ring buffer with the given capacity and channel count.
PCMRingBuffer* createPCMRingBuffer(int capacity, int channelCount) {
    if (capacity <= 0 || channelCount <= 0) {
        fprintf(stderr, "[PCMRingBuffer] Invalid capacity (%d) or channelCount (%d)\n", capacity, channelCount);
        return NULL;
    }

    PCMRingBuffer* rb = (PCMRingBuffer*)malloc(sizeof(PCMRingBuffer));
    if (!rb) {

        return NULL;
    }
    rb->capacity = capacity;
    rb->channelCount = channelCount;
    pthread_mutex_init(&rb->lock, NULL);

    rb->buffers = (float**)calloc(channelCount, sizeof(float*));
    for (int ch = 0; ch < channelCount; ++ch) {
        rb->buffers[ch] = (float*)calloc(capacity, sizeof(float));
    }

    rb->writeIndices = (int*)calloc(channelCount, sizeof(int));
    rb->readIndices = (int*)calloc(channelCount, sizeof(int));
    rb->fillCounts = (int*)calloc(channelCount, sizeof(int));

    return rb;
}

// Retrieve the current fill level of a specific channel in the ring buffer
int getSingleChannelFillLevel(PCMRingBuffer* rb, int channelIndex) {
    if (!rb || channelIndex < 0 || channelIndex >= rb->channelCount || !rb->fillCounts) return 0;
    pthread_mutex_lock(&rb->lock);
    int fill = rb->fillCounts[channelIndex];
    pthread_mutex_unlock(&rb->lock);
    return fill;
}

// Free all memory associated with the PCM ring buffer, including buffers and index arrays.
void destroyPCMRingBuffer(PCMRingBuffer* rb) {
    if (!rb) return;
    for (int ch = 0; ch < rb->channelCount; ++ch) {
        free(rb->buffers[ch]);
    }
    free(rb->buffers);
    free(rb->writeIndices);
    free(rb->readIndices);
    free(rb->fillCounts);
    pthread_mutex_destroy(&rb->lock);
    free(rb);
}

// Reports aggregate buffer fill across all channels.
int getPCMRingBufferFillLevel(PCMRingBuffer* rb) {
    if (!rb || !rb->fillCounts) return 0;
    int total = 0;
    for (int i = 0; i < rb->channelCount; ++i) {
        total += rb->fillCounts[i];
    }
    return total;
}

// Write interleaved multi-channel PCM data into the ring buffer (frame-wise).
void writePCMToRingBuffer(PCMRingBuffer* rb, float** pcmData, int frames) {
    if (!rb) return;

    pthread_mutex_lock(&rb->lock);
    for (int i = 0; i < frames; ++i) {
        for (int ch = 0; ch < rb->channelCount; ++ch) {
            rb->buffers[ch][rb->writeIndices[ch]] = pcmData[ch][i];
            rb->writeIndices[ch] = (rb->writeIndices[ch] + 1) % rb->capacity;
            if (rb->fillCounts[ch] < rb->capacity) {
                rb->fillCounts[ch]++;
            }
        }
    }
    pthread_mutex_unlock(&rb->lock);
}

// Read interleaved multi-channel PCM data from the ring buffer into provided output arrays.
int readPCMFromRingBuffer(PCMRingBuffer* rb, float** outData, int frames) {
    if (!rb) return 0;

    pthread_mutex_lock(&rb->lock);
    for (int i = 0; i < frames; ++i) {
        for (int ch = 0; ch < rb->channelCount; ++ch) {
            outData[ch][i] = rb->buffers[ch][rb->readIndices[ch]];
            rb->readIndices[ch] = (rb->readIndices[ch] + 1) % rb->capacity;
            if (rb->fillCounts[ch] > 0) {
                rb->fillCounts[ch]--;
            }
        }
    }
    pthread_mutex_unlock(&rb->lock);
    return frames;
}

// Read a single channel of audio from the ring buffer, returning the number of frames actually read.
int readSingleChannelFromRingBuffer(PCMRingBuffer* rb, int channelIndex, float* outData, int frames) {
    if (!rb || !outData || channelIndex < 0 || channelIndex >= rb->channelCount) return 0;

    pthread_mutex_lock(&rb->lock);

    int writeIndex = rb->writeIndices[channelIndex];
    int readIndex = rb->readIndices[channelIndex];
    int available = writeIndex - readIndex;
    if (available < 0) available += rb->capacity;



    int count = (frames < available) ? frames : available;
    for (int i = 0; i < count; ++i) {
        outData[i] = rb->buffers[channelIndex][rb->readIndices[channelIndex]];
        rb->readIndices[channelIndex] = (rb->readIndices[channelIndex] + 1) % rb->capacity;
        if (rb->fillCounts[channelIndex] > 0) {
            rb->fillCounts[channelIndex]--;
        }
    }
    pthread_mutex_unlock(&rb->lock);


    return count;
}

// Reset all read and write indices for the ring buffer, effectively clearing it.
void clearPCMRingBuffer(PCMRingBuffer* rb) {
    if (!rb) return;
    pthread_mutex_lock(&rb->lock);
    for (int ch = 0; ch < rb->channelCount; ++ch) {
        rb->readIndices[ch] = 0;
        rb->writeIndices[ch] = 0;
    }
    pthread_mutex_unlock(&rb->lock);
}

// Write a single channel's PCM data into the ring buffer with a specified stride.
void writeSingleChannelToRingBuffer(PCMRingBuffer* rb, int channelIndex, const float* samples, int frameCount, int stride) {
    if (!rb || !samples || channelIndex < 0 || channelIndex >= rb->channelCount) return;
    if (!rb->buffers || !rb->buffers[channelIndex]) return;
    if (!rb->writeIndices) return;

    pthread_mutex_lock(&rb->lock);

    int writeIndex = rb->writeIndices[channelIndex];

    for (int i = 0; i < frameCount; ++i) {
        rb->buffers[channelIndex][writeIndex] = samples[i * stride];
        writeIndex = (writeIndex + 1) % rb->capacity;
        if (rb->fillCounts[channelIndex] < rb->capacity) {
            rb->fillCounts[channelIndex]++;
        }
    }

    rb->writeIndices[channelIndex] = writeIndex;
    pthread_mutex_unlock(&rb->lock);
}

// Write min and max float values into the first two channels of the buffer for visual metering or diagnostics.
void writeMinMaxToRingBuffer(PCMRingBuffer* buffer, float minValue, float maxValue) {
    if (!buffer || buffer->channelCount < 2) return;

    pthread_mutex_lock(&buffer->lock);

    buffer->buffers[0][buffer->writeIndices[0]] = minValue;
    buffer->buffers[1][buffer->writeIndices[1]] = maxValue;

    buffer->writeIndices[0] = (buffer->writeIndices[0] + 1) % buffer->capacity;
    buffer->writeIndices[1] = (buffer->writeIndices[1] + 1) % buffer->capacity;

    pthread_mutex_unlock(&buffer->lock);
}
