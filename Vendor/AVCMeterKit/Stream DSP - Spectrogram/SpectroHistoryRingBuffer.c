//
//  SpectroHistoryRingBuffer.c
//  AVCMeter
//
//  Created by Chris Izatt on 30/06/2025.
//

#include "SpectroHistoryRingBuffer.h"

#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>

struct SpectroHistoryRingBuffer {
    float* buffer;
    size_t width;      // Time axis (number of frames)
    size_t height;     // Frequency bins (Y-axis)
    atomic_int writeIndex;
    pthread_mutex_t lock;
    float* snapshotData;     // Per-instance snapshot buffer (avoids static/race condition)
    size_t snapshotCapacity;
};

SpectroHistoryRingBuffer* SpectroHistoryRingBuffer_Create(size_t numBins, size_t numFrames) {
    SpectroHistoryRingBuffer* rb = (SpectroHistoryRingBuffer*)malloc(sizeof(SpectroHistoryRingBuffer));
    if (!rb) return NULL;
    rb->width = numFrames;
    rb->height = numBins;
    rb->buffer = (float*)calloc(numFrames * numBins, sizeof(float));
    if (!rb->buffer) {
        free(rb);
        return NULL;
    }
    atomic_init(&rb->writeIndex, 0);
    pthread_mutex_init(&rb->lock, NULL);
    rb->snapshotData = NULL;
    rb->snapshotCapacity = 0;
    return rb;
}

void SpectroHistoryRingBuffer_WriteFrame(SpectroHistoryRingBuffer* rb, const float* frame) {
    if (!rb || !frame) return;
    int index = atomic_fetch_add(&rb->writeIndex, 1) % (int)rb->width;
    pthread_mutex_lock(&rb->lock);
    for (size_t y = 0; y < rb->height; ++y) {
        rb->buffer[y * rb->width + index] = frame[y];
    }
    pthread_mutex_unlock(&rb->lock);
}

const float* SpectroHistoryRingBuffer_GetSnapshot(SpectroHistoryRingBuffer* rb, int delayFrames, size_t* outWidth, size_t* outHeight) {
    if (!rb || !outWidth || !outHeight) return NULL;
    pthread_mutex_lock(&rb->lock);
    int currentWriteIndex = atomic_load(&rb->writeIndex);
    int delayedIndex = (currentWriteIndex - delayFrames - 2 + (int)rb->width) % (int)rb->width;
    static float* snapshotBuffer = NULL;
    static size_t snapshotCapacity = 0;
    size_t totalSize = rb->width * rb->height;
    if (snapshotCapacity < totalSize) {
        free(snapshotBuffer);
        snapshotBuffer = (float*)malloc(sizeof(float) * totalSize);
        snapshotCapacity = totalSize;
    }
    for (size_t x = 0; x < rb->width; ++x) {
        int srcCol = (delayedIndex + x) % (int)rb->width;
        for (size_t y = 0; y < rb->height; ++y) {
            snapshotBuffer[y * rb->width + x] = rb->buffer[y * rb->width + srcCol];
        }
    }
    pthread_mutex_unlock(&rb->lock);
    *outWidth = rb->width;
    *outHeight = rb->height;
    return (const float*)snapshotBuffer;
}

int SpectroHistoryRingBuffer_GetWriteIndex(SpectroHistoryRingBuffer* rb) {
    if (!rb) return 0;
    return atomic_load(&rb->writeIndex);
}

const float* SpectroHistoryRingBuffer_GetLinearSnapshot(SpectroHistoryRingBuffer* rb, size_t maxFrames, size_t* outFrames, size_t* outHeight) {
    if (!rb || !outFrames || !outHeight) return NULL;
    pthread_mutex_lock(&rb->lock);

    int writeIdx = atomic_load(&rb->writeIndex);
    size_t filled = (writeIdx >= (int)rb->width) ? rb->width : (size_t)writeIdx;

    // Clamp to requested display window
    size_t returnFrames = (maxFrames > 0 && maxFrames < filled) ? maxFrames : filled;

    if (returnFrames == 0) {
        pthread_mutex_unlock(&rb->lock);
        *outFrames = 0;
        *outHeight = rb->height;
        return NULL;
    }

    size_t totalSize = returnFrames * rb->height;
    if (rb->snapshotCapacity < totalSize) {
        free(rb->snapshotData);
        rb->snapshotData = (float*)malloc(sizeof(float) * totalSize);
        rb->snapshotCapacity = totalSize;
    }

    // Oldest of the last returnFrames: (writeIdx - returnFrames) mod width
    int startCol = ((writeIdx - (int)returnFrames) % (int)rb->width + (int)rb->width) % (int)rb->width;

    for (size_t x = 0; x < returnFrames; x++) {
        int srcCol = (startCol + (int)x) % (int)rb->width;
        for (size_t y = 0; y < rb->height; y++) {
            rb->snapshotData[y * returnFrames + x] = rb->buffer[y * rb->width + srcCol];
        }
    }

    pthread_mutex_unlock(&rb->lock);
    *outFrames = returnFrames;
    *outHeight = rb->height;
    return (const float*)rb->snapshotData;
}

void SpectroHistoryRingBuffer_Destroy(SpectroHistoryRingBuffer* rb) {
    if (!rb) return;
    pthread_mutex_destroy(&rb->lock);
    free(rb->buffer);
    free(rb->snapshotData);
    free(rb);
}
