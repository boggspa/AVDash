//
//  RingBuffer.c
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//
// NOTE: RingBuffer.c implements only the buffer itself. Allocation and freeing of buffer pointers is always owned by the Mixer or central manager. No external module should allocate/free ring buffers directly.
//
//  DESCRIPTION:
//  This file implements a thread-safe circular buffer (ring buffer) for storing and processing
//  floating-point audio data in real-time. It supports operations like writing, clearing,
//  reading all values, and computing average and maximum levels using Accelerate for performance.
//
//  BUFFER SIZE RECOMMENDATION:
//  It is recommended to use a buffer capacity of 4096 frames for better performance and margin,
//  instead of the previous default of 2048 frames. This doubling of buffer size should be managed
//  by the caller (Mixer or central manager), not internally here.
//

#include "IOStreams.h"
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include <Accelerate/Accelerate.h>
#define MAX_CHANNELS 64

// --- Creation and Destruction ---

// Creates a new ring buffer with specified capacity.
RingBuffer* createRingBuffer(int capacity) {
    RingBuffer* rb = (RingBuffer*)malloc(sizeof(RingBuffer));
    if (!rb) {
        printf("[RingBuffer] ERROR: Failed to allocate memory for RingBuffer struct in createRingBuffer.\n");
        abort();
    }
    rb->buffer = (float*)calloc(capacity, sizeof(float));
    if (!rb->buffer) {
        printf("[RingBuffer] ERROR: Failed to allocate memory for buffer in createRingBuffer.\n");
        free(rb);
        abort();
    }
    rb->capacity = capacity;
    rb->writeIndex = 0;
    rb->filled = 0;
    rb->readIndex = 0;
    pthread_mutex_init(&rb->lock, NULL);
    return rb;
}

// Destroys the ring buffer and releases memory.
void destroyRingBuffer(RingBuffer* rb) {
    if (rb) {
        pthread_mutex_destroy(&rb->lock);
        if (rb->buffer) {
            free(rb->buffer);
            rb->buffer = NULL;
        }
        free(rb);
    }
}

// --- Write Operations ---

// Writes a single float value into the buffer.
// On overflow, advances readIndex to drop the oldest sample and preserve FIFO order.
// Without this, overflow corrupts the read ordering and produces audio distortion.
void writeRingBuffer(RingBuffer* rb, float value) {
    // Gracefully handle NULL buffer during shutdown (race condition)
    if (!rb || !rb->buffer) {
        return;
    }
    pthread_mutex_lock(&rb->lock);
    rb->buffer[rb->writeIndex] = value;
    rb->writeIndex = (rb->writeIndex + 1) % rb->capacity;
    if (rb->filled < rb->capacity) {
        rb->filled++;
    } else {
        // Overflow: drop oldest unread sample to maintain temporal order.
        rb->readIndex = (rb->readIndex + 1) % rb->capacity;
    }
    pthread_mutex_unlock(&rb->lock);
}

// Assumes:
//   - interleaved: pointer to [numFrames * numChannels] floats (frame-major order)
//   - channelBuffers: array of RingBuffer* (size = numChannels)
//   - numChannels <= MAX_CHANNELS

void deinterleaveAndWriteToRingBuffers(const float* interleaved, int numFrames, int numChannels, RingBuffer** channelBuffers) {
    _Thread_local static int shown_deinterleaveAndWriteToRingBuffers = 0;
    if (!interleaved || !channelBuffers) {
        if (!shown_deinterleaveAndWriteToRingBuffers) {
            printf("[RingBuffer] ERROR: NULL input pointers in deinterleaveAndWriteToRingBuffers.\n");
            shown_deinterleaveAndWriteToRingBuffers = 1;
        }
        abort();
    } else {
        shown_deinterleaveAndWriteToRingBuffers = 0;
    }
    for (int frame = 0; frame < numFrames; ++frame) {
        for (int ch = 0; ch < numChannels; ++ch) {
            if (!channelBuffers[ch] || !channelBuffers[ch]->buffer) {
                printf("[RingBuffer] ERROR: Attempted to write to NULL or freed ring buffer in deinterleaveAndWriteToRingBuffers at channel %d.\n", ch);
                // Continue writing other channels despite this error (recoverable here)
                continue;
            }
            float sample = interleaved[frame * numChannels + ch];
            writeRingBuffer(channelBuffers[ch], sample);
        }
    }
}
// --- Analysis Operations (Average/Max) ---

// If buffer is empty but valid, return 0.0f (no abort); only abort for null/freed buffers.
float averageRingBuffer(RingBuffer* rb) {
    _Thread_local static int shown_averageRingBuffer = 0;
    if (!rb || !rb->buffer) {
        if (!shown_averageRingBuffer) {
            printf("[RingBuffer] ERROR: Attempted to average NULL or freed ring buffer in averageRingBuffer.\n");
            shown_averageRingBuffer = 1;
        }
        abort();
    } else {
        shown_averageRingBuffer = 0;
    }
    pthread_mutex_lock(&rb->lock);
    if (rb->filled == 0) {
        pthread_mutex_unlock(&rb->lock);
        return 0.0f;
    }
    float avg = 0.0f;
    vDSP_meanv(rb->buffer, 1, &avg, rb->filled);
    pthread_mutex_unlock(&rb->lock);
    return avg;
}

// If buffer is empty but valid, return 0.0f (no abort); only abort for null/freed buffers.
float maxRingBuffer(RingBuffer* rb) {
    _Thread_local static int shown_maxRingBuffer = 0;
    if (!rb || !rb->buffer) {
        if (!shown_maxRingBuffer) {
            printf("[RingBuffer] ERROR: Attempted to max NULL or freed ring buffer in maxRingBuffer.\n");
            shown_maxRingBuffer = 1;
        }
        abort();
    } else {
        shown_maxRingBuffer = 0;
    }
    pthread_mutex_lock(&rb->lock);
    if (rb->filled == 0) {
        pthread_mutex_unlock(&rb->lock);
        return 0.0f;
    }
    float max = 0.0f;
    vDSP_maxv(rb->buffer, 1, &max, rb->filled);
    pthread_mutex_unlock(&rb->lock);
    return max;
}

// --- Utility Operations ---

// Clears all values in the buffer and resets its state.
void clearRingBuffer(RingBuffer* rb) {
    _Thread_local static int shown_clearRingBuffer = 0;
    if (!rb || !rb->buffer) {
        if (!shown_clearRingBuffer) {
            printf("[RingBuffer] ERROR: Attempted to clear NULL or freed ring buffer in clearRingBuffer.\n");
            shown_clearRingBuffer = 1;
        }
        abort();
    } else {
        shown_clearRingBuffer = 0;
    }
    pthread_mutex_lock(&rb->lock);
    memset(rb->buffer, 0, sizeof(float) * rb->capacity);
    rb->writeIndex = 0;
    rb->filled = 0;
    rb->readIndex = 0;
    pthread_mutex_unlock(&rb->lock);
}

// Returns the number of filled slots in the buffer.
int getRingBufferFillCount(RingBuffer* rb) {
    _Thread_local static int shown_getRingBufferFillCount = 0;
    if (!rb || !rb->buffer) {
        if (!shown_getRingBufferFillCount) {
            printf("[RingBuffer] ERROR: Attempted to get fill count from NULL or freed ring buffer in getRingBufferFillCount.\n");
            shown_getRingBufferFillCount = 1;
        }
        abort();
    } else {
        shown_getRingBufferFillCount = 0;
    }
    pthread_mutex_lock(&rb->lock);
    int count = rb->filled;
    pthread_mutex_unlock(&rb->lock);
    return count;
}

// If buffer is empty but valid, return 0.0f (no abort); only abort for null/freed buffers.
float mostRecentRingBuffer(RingBuffer* buffer) {
    _Thread_local static int shown_mostRecentRingBuffer = 0;
    if (!buffer || !buffer->buffer) {
        if (!shown_mostRecentRingBuffer) {
            printf("[RingBuffer] ERROR: Attempted to get most recent sample from NULL or freed ring buffer in mostRecentRingBuffer.\n");
            shown_mostRecentRingBuffer = 1;
        }
        abort();
    } else {
        shown_mostRecentRingBuffer = 0;
    }
    pthread_mutex_lock(&buffer->lock);
    if (buffer->filled == 0) {
        pthread_mutex_unlock(&buffer->lock);
        return 0.0f;
    }
    int index = (buffer->writeIndex - 1 + buffer->capacity) % buffer->capacity;
    float result = buffer->buffer[index];
    pthread_mutex_unlock(&buffer->lock);
    return result;
}

// Reads up to maxCount new samples, advances the read pointer
int ringbuffer_read(RingBuffer* rb, float* outputArray, int maxCount) {
    _Thread_local static int shown_ringbuffer_read = 0;
    if (!rb || !rb->buffer) {
        if (!shown_ringbuffer_read) {
            printf("[RingBuffer] ERROR: Attempted to read from NULL ring buffer or buffer in ringbuffer_read.\n");
            shown_ringbuffer_read = 1;
        }
        abort();
    } else {
        shown_ringbuffer_read = 0;
    }
    pthread_mutex_lock(&rb->lock);
    if (rb->capacity <= 0 || rb->readIndex < 0 || rb->readIndex >= rb->capacity) {
        pthread_mutex_unlock(&rb->lock);
        if (!shown_ringbuffer_read) {
            printf("[RingBuffer] ERROR: Invalid ring buffer state: capacity=%d, readIndex=%d in ringbuffer_read\n", rb->capacity, rb->readIndex);
            shown_ringbuffer_read = 1;
        }
        abort();
    }
    int nRead = (rb->filled < maxCount) ? rb->filled : maxCount;
    for (int i = 0; i < nRead; ++i) {
        if (rb->readIndex < 0 || rb->readIndex >= rb->capacity) {
            printf("[RingBuffer] ERROR: readIndex out of bounds: %d (capacity=%d) in ringbuffer_read\n", rb->readIndex, rb->capacity);
            break;
        }
        outputArray[i] = rb->buffer[rb->readIndex];
        rb->readIndex = (rb->readIndex + 1) % rb->capacity;
    }
    rb->filled -= nRead;
    pthread_mutex_unlock(&rb->lock);
    return nRead;
}

// Reads up to maxCount latest samples without consuming the buffer.
int ringbuffer_read_latest(RingBuffer* rb, float* outputArray, int maxCount) {
    _Thread_local static int shown_ringbuffer_read_latest = 0;
    if (!rb || !rb->buffer || !outputArray || maxCount <= 0) {
        if (!shown_ringbuffer_read_latest) {
            printf("[RingBuffer] ERROR: Invalid arguments in ringbuffer_read_latest.\n");
            shown_ringbuffer_read_latest = 1;
        }
        return 0;
    } else {
        shown_ringbuffer_read_latest = 0;
    }

    pthread_mutex_lock(&rb->lock);
    if (rb->capacity <= 0 || rb->writeIndex < 0 || rb->writeIndex >= rb->capacity) {
        pthread_mutex_unlock(&rb->lock);
        if (!shown_ringbuffer_read_latest) {
            printf("[RingBuffer] ERROR: Invalid ring buffer state in ringbuffer_read_latest (capacity=%d writeIndex=%d).\n",
                   rb->capacity,
                   rb->writeIndex);
            shown_ringbuffer_read_latest = 1;
        }
        return 0;
    }

    int nRead = rb->filled < maxCount ? rb->filled : maxCount;
    if (nRead <= 0) {
        pthread_mutex_unlock(&rb->lock);
        return 0;
    }

    int startIndex = rb->writeIndex - nRead;
    if (startIndex < 0) {
        startIndex += rb->capacity;
    }

    for (int i = 0; i < nRead; ++i) {
        int index = (startIndex + i) % rb->capacity;
        outputArray[i] = rb->buffer[index];
    }

    pthread_mutex_unlock(&rb->lock);
    return nRead;
}

// Copies all values in the buffer into an external array in order.
void ringbuffer_read_all(RingBuffer* buffer, float* outputArray, int maxCount) {
    _Thread_local static int shown_ringbuffer_read_all = 0;
    if (!buffer || !buffer->buffer) {
        if (!shown_ringbuffer_read_all) {
            printf("[RingBuffer] ERROR: Attempted to read_all from NULL ring buffer or buffer in ringbuffer_read_all.\n");
            shown_ringbuffer_read_all = 1;
        }
        abort();
    } else {
        shown_ringbuffer_read_all = 0;
    }
    pthread_mutex_lock(&buffer->lock);
    int count = buffer->filled;
    for (int i = 0; i < count && i < maxCount; i++) {
        int idx = (buffer->writeIndex - count + i + buffer->capacity) % buffer->capacity;
        outputArray[i] = buffer->buffer[idx];
    }
    pthread_mutex_unlock(&buffer->lock);
}

_Atomic float gPostGain[MAX_CHANNELS];
static pthread_once_t gPostGainInitOnce = PTHREAD_ONCE_INIT;

static void initialize_post_gain_defaults(void) {
    for (int i = 0; i < MAX_CHANNELS; ++i) {
        atomic_store(&gPostGain[i], 1.0f);
    }
}

// Initializes post-gain values for all channels to 1.0 (0 dB, linear gain).
// This function should be called once at program or device startup from Swift/Objective-C before first metering use.
void RingBuffer_GlobalInit(void) {
    pthread_once(&gPostGainInitOnce, initialize_post_gain_defaults);
}

void RingBuffer_SetPostGain(int channel, float gain) {
    RingBuffer_GlobalInit();
    if (channel >= 0 && channel < MAX_CHANNELS) atomic_store(&gPostGain[channel], gain);
}

void RingBuffer_ApplyPostGain(int channel, float* buffer, size_t frames) {
    if (channel < 0 || channel >= MAX_CHANNELS || !buffer) {
        printf("[RingBuffer] ERROR: Invalid arguments in RingBuffer_ApplyPostGain.\n");
        abort();
    }
    RingBuffer_GlobalInit();
    float gain = atomic_load(&gPostGain[channel]);
    for (size_t i = 0; i < frames; ++i) {
        buffer[i] *= gain;
    }
}

// End of RingBuffer.c. All buffer pointer lifecycle management is centralized in Mixer.c.

// --- Multi-Channel Ring Buffer Functions (for System Audio) ---

// Multi-channel ring buffer structure
typedef struct {
    RingBuffer** channelBuffers;
    int channelCount;
    int capacity;
} MultiChannelRingBuffer;

// Creates a multi-channel ring buffer
MultiChannelRingBuffer* RingBuffer_Create(int capacity, int channels) {
    MultiChannelRingBuffer* mcb = (MultiChannelRingBuffer*)malloc(sizeof(MultiChannelRingBuffer));
    if (!mcb) return NULL;

    mcb->channelBuffers = (RingBuffer**)malloc(sizeof(RingBuffer*) * channels);
    if (!mcb->channelBuffers) {
        free(mcb);
        return NULL;
    }

    for (int i = 0; i < channels; i++) {
        mcb->channelBuffers[i] = createRingBuffer(capacity);
    }

    mcb->channelCount = channels;
    mcb->capacity = capacity;
    return mcb;
}

// Destroys a multi-channel ring buffer
void RingBuffer_Destroy(MultiChannelRingBuffer* mcb) {
    if (!mcb) return;
    if (mcb->channelBuffers) {
        for (int i = 0; i < mcb->channelCount; i++) {
            destroyRingBuffer(mcb->channelBuffers[i]);
        }
        free(mcb->channelBuffers);
    }
    free(mcb);
}

// Write a single value to a specific channel
void RingBuffer_Write(MultiChannelRingBuffer* mcb, float value, int channel) {
    if (!mcb || channel < 0 || channel >= mcb->channelCount) return;
    writeRingBuffer(mcb->channelBuffers[channel], value);
}

// Write interleaved data to all channels
void RingBuffer_WriteInterleaved(MultiChannelRingBuffer* mcb, const float* data, int frameCount, int channels) {
    if (!mcb || !data) return;
    int chCount = (channels < mcb->channelCount) ? channels : mcb->channelCount;
    for (int frame = 0; frame < frameCount; frame++) {
        for (int ch = 0; ch < chCount; ch++) {
            writeRingBuffer(mcb->channelBuffers[ch], data[frame * channels + ch]);
        }
    }
}

// Read the most recent value from a channel
float RingBuffer_ReadMostRecent(MultiChannelRingBuffer* mcb, int channel) {
    if (!mcb || channel < 0 || channel >= mcb->channelCount) return 0.0f;
    return mostRecentRingBuffer(mcb->channelBuffers[channel]);
}

// Read interleaved samples from a specific channel
int RingBuffer_ReadInterleaved(MultiChannelRingBuffer* mcb, float* data, int frameCount, int channel) {
    if (!mcb || !data || channel < 0 || channel >= mcb->channelCount) return 0;
    return ringbuffer_read_latest(mcb->channelBuffers[channel], data, frameCount);
}

// Read interleaved samples from all channels
int RingBuffer_ReadAllInterleaved(MultiChannelRingBuffer* mcb, float* data, int frameCount) {
    if (!mcb || !data || frameCount <= 0) return 0;

    int channels = mcb->channelCount;
    int totalFrames = 0;

    // Read from each channel and interleave
    for (int ch = 0; ch < channels; ch++) {
        float* channelData = (float*)malloc(frameCount * sizeof(float));
        if (!channelData) continue;

        int framesRead = ringbuffer_read_latest(mcb->channelBuffers[ch], channelData, frameCount);
        if (framesRead > totalFrames) totalFrames = framesRead;

        // Interleave: channel 0 at 0, channels, 2*channels, etc.
        for (int i = 0; i < framesRead; i++) {
            data[i * channels + ch] = channelData[i];
        }

        free(channelData);
    }

    return totalFrames;
}
