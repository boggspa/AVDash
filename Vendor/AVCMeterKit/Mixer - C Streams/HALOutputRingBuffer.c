//
//  HALOutputRingBuffer.c
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

// NOTE: These APIs now require the caller to manage an OutputChannelRingBuffer array per device.

#include "IOStreams.h"
#include "Mixer.h"

#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>

#define DEBUG_OUTPUT_READ

#define MAX_OUTPUT_CHANNELS 64
#define MAX_BUFFER_FRAMES 1024

// Removed static global outputBuffers array to support per-device buffer arrays

void InitOutputRingBuffer(OutputChannelRingBuffer* outputBuffer, size_t channelCount, size_t bufferSize) {
    if (outputBuffer == NULL) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: outputBuffer pointer is NULL in InitOutputRingBuffer\n");
        abort();
    }
    for (size_t i = 0; i < channelCount && i < MAX_OUTPUT_CHANNELS; ++i) {
        if (outputBuffer[i].buffer != NULL) {
            free(outputBuffer[i].buffer);
            outputBuffer[i].buffer = NULL;
            outputBuffer[i].size = 0;
        }
        outputBuffer[i].buffer = (float*)calloc(bufferSize, sizeof(float));
        if (outputBuffer[i].buffer == NULL) {
            fprintf(stderr, "[HALOutputRingBuffer] ERROR: failed to allocate buffer for channel %zu in InitOutputRingBuffer\n", i);
            abort();
        }
        outputBuffer[i].size = bufferSize;
        atomic_store(&outputBuffer[i].writeIndex, 0);
        atomic_store(&outputBuffer[i].readIndex, 0);
    }
}

void WriteToOutputBuffer(OutputChannelRingBuffer* outputBuffer, size_t channel, const float* input, size_t frameCount) {
    if (outputBuffer == NULL) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: outputBuffer pointer is NULL in WriteToOutputBuffer\n");
        abort();
    }
    if (channel >= MAX_OUTPUT_CHANNELS) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: channel index %zu out of range in WriteToOutputBuffer\n", channel);
        abort();
    }
    if (input == NULL) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: input pointer is NULL in WriteToOutputBuffer\n");
        abort();
    }

    OutputChannelRingBuffer* rb = &outputBuffer[channel];
    size_t writeIndex = atomic_load(&rb->writeIndex);
    if (rb->buffer != NULL && rb->size > 0) {
        for (size_t i = 0; i < frameCount; ++i) {
            if (rb->buffer == NULL) {
                fprintf(stderr, "[ringbuffer] ERROR: buffer not allocated for channel %zu in WriteToOutputBuffer\n", channel);
                abort();
            }
            rb->buffer[(writeIndex + i) % rb->size] = input[i];
        }
        atomic_store(&rb->writeIndex, (writeIndex + frameCount) % rb->size);
    } else {
        fprintf(stderr, "[ringbuffer] ERROR: buffer not allocated or size is zero for channel %zu in WriteToOutputBuffer\n", channel);
        abort();
    }
}

void ReadFromOutputBuffer(OutputChannelRingBuffer* outputBuffer, size_t channel, float* output, size_t frameCount) {
    if (outputBuffer == NULL) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: outputBuffer pointer is NULL in ReadFromOutputBuffer\n");
        abort();
    }
    if (channel >= MAX_OUTPUT_CHANNELS) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: channel index %zu out of range in ReadFromOutputBuffer\n", channel);
        abort();
    }
    if (output == NULL) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: output pointer is NULL in ReadFromOutputBuffer\n");
        abort();
    }

    OutputChannelRingBuffer* rb = &outputBuffer[channel];
    if (rb->buffer == NULL || rb->size == 0) {
        fprintf(stderr, "[ringbuffer] ERROR: buffer not allocated or size is zero for channel %zu in ReadFromOutputBuffer\n", channel);
        abort();
    }

    size_t readIndex = atomic_load(&rb->readIndex);
    for (size_t i = 0; i < frameCount; ++i) {
        output[i] = rb->buffer[(readIndex + i) % rb->size];
    }
/*
#ifdef DEBUG_OUTPUT_READ
    fprintf(stderr, "[HALOutputRingBuffer] Read %zu frames from output channel %zu (first 5 samples): ", frameCount, channel);
    for (size_t i = 0; i < frameCount && i < 5; ++i) {
        fprintf(stderr, "%.4f ", output[i]);
    }
    fprintf(stderr, "\n");
#endif
*/
    atomic_store(&rb->readIndex, (readIndex + frameCount) % rb->size);
}

void ClearOutputBuffers(OutputChannelRingBuffer* outputBuffer, size_t channelCount) {
    if (outputBuffer == NULL) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: outputBuffers pointer is NULL in ClearOutputBuffers\n");
        abort();
    }
    // Only clear channels that were actually initialized
    for (size_t i = 0; i < channelCount && i < MAX_OUTPUT_CHANNELS; ++i) {
        if (outputBuffer[i].buffer != NULL) {
            memset(outputBuffer[i].buffer, 0, outputBuffer[i].size * sizeof(float));
            atomic_store(&outputBuffer[i].writeIndex, 0);
            atomic_store(&outputBuffer[i].readIndex, 0);
        }
    }
}

void FreeOutputBuffers(OutputChannelRingBuffer* outputBuffer, size_t channelCount) {
    if (outputBuffer == NULL) {
        fprintf(stderr, "[HALOutputRingBuffer] ERROR: outputBuffers pointer is NULL in FreeOutputBuffers\n");
        abort();
    }
    // Only free channels that were actually initialized
    for (size_t i = 0; i < channelCount && i < MAX_OUTPUT_CHANNELS; ++i) {
        free(outputBuffer[i].buffer);
        outputBuffer[i].buffer = NULL;
        outputBuffer[i].size = 0;
    }
}
