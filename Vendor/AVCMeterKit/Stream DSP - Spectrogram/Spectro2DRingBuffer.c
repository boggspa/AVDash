///
///  Spectro2DRingBuffer.c
///  AVCMeter
///
///  Created by Chris Izatt on 30/06/2025.
///

#include "Spectro2DRingBuffer.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>

// MARK: - Structure Definition

Spectro2DRingBuffer *Spectro2DRingBuffer_Create(int width, int height) {
    Spectro2DRingBuffer *buffer = (Spectro2DRingBuffer *)malloc(sizeof(Spectro2DRingBuffer));
    if (!buffer) return NULL;

    buffer->height = height;
    buffer->width = width;
    buffer->writeIndex = 0;

    buffer->data = (float *)calloc(height * width, sizeof(float));
    if (!buffer->data) {
        free(buffer);
        return NULL;
    }

    pthread_mutex_init(&buffer->lock, NULL);
    return buffer;
}

void Spectro2DRingBuffer_Destroy(Spectro2DRingBuffer *buffer) {
    if (!buffer) return;
    pthread_mutex_destroy(&buffer->lock);
    free(buffer->data);
    free(buffer);
}

void Spectro2DRingBuffer_WriteColumn(Spectro2DRingBuffer *buffer, const float *columnData) {
    if (!buffer || !columnData) return;

    pthread_mutex_lock(&buffer->lock);
    for (int y = 0; y < buffer->height; y++) {
        buffer->data[y * buffer->width + buffer->writeIndex] = columnData[y];
    }
    buffer->writeIndex = (buffer->writeIndex + 1) % buffer->width;
    pthread_mutex_unlock(&buffer->lock);
}

const float* Spectro2DRingBuffer_GetSnapshot(Spectro2DRingBuffer* buffer, int delay, int* outWidth, int* outHeight) {
    if (!buffer) return NULL;

    pthread_mutex_lock(&buffer->lock);
    int width = buffer->width;
    int height = buffer->height;
    int index = (buffer->writeIndex - delay + width) % width;

    static float* snapshot = NULL;
    static size_t snapshotSize = 0;
    size_t requiredSize = width * height;

    if (snapshotSize != requiredSize) {
        free(snapshot);
        snapshot = (float*)malloc(sizeof(float) * requiredSize);
        snapshotSize = requiredSize;
    }

    for (int x = 0; x < width; ++x) {
        int srcX = (index + x) % width;
        for (int y = 0; y < height; ++y) {
            snapshot[y * width + x] = buffer->data[y * width + srcX];
        }
    }

    pthread_mutex_unlock(&buffer->lock);
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return snapshot;
}

int Spectro2DRingBuffer_GetWriteIndex(Spectro2DRingBuffer *buffer) {
    if (!buffer) return 0;
    return buffer->writeIndex;
}
