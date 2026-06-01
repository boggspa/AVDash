//
//  FFTRingBuffer.c
//  AVCMeter
//
//  Created by Chris Izatt on 28/06/2025.
//

#include "FFTRingBuffer.h"

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>


FFTBuffer *FFTBuffer_Create(int capacity) {
    FFTBuffer *b = (FFTBuffer *)malloc(sizeof(FFTBuffer));
    if (!b) return NULL;
    b->buffer = (float *)malloc(sizeof(float) * capacity);
    if (!b->buffer) {
        free(b);
        return NULL;
    }
    b->capacity = capacity;
    b->dropNew = 0;
    atomic_init(&b->readIndex, 0);
    atomic_init(&b->writeIndex, 0);
    atomic_init(&b->fillCount, 0);
    pthread_mutex_init(&b->lock, NULL);
    return b;
}

void FFTBuffer_Destroy(FFTBuffer *b) {
    if (!b) return;
    pthread_mutex_destroy(&b->lock);
    free(b->buffer);
    free(b);
}

void FFTBuffer_Write(FFTBuffer *b, const float *samples, int count) {
    pthread_mutex_lock(&b->lock);
    for (int i = 0; i < count; i++) {
        int fill = atomic_load(&b->fillCount);
        int writeIdx = atomic_load(&b->writeIndex);
        int readIdx = atomic_load(&b->readIndex);
        if (fill < b->capacity) {
            b->buffer[writeIdx] = samples[i];
            atomic_store(&b->writeIndex, (writeIdx + 1) % b->capacity);
            atomic_fetch_add(&b->fillCount, 1);
        } else {
            if (b->dropNew) {
                // drop new sample, do not write or advance indices
                continue;
            } else {
                b->buffer[writeIdx] = samples[i];
                atomic_store(&b->writeIndex, (writeIdx + 1) % b->capacity);
                atomic_store(&b->readIndex, (readIdx + 1) % b->capacity);
            }
        }
    }
    pthread_mutex_unlock(&b->lock);
}

int FFTBuffer_Read(FFTBuffer *b, float *out, int count) {
    pthread_mutex_lock(&b->lock);
    int toRead = 0;
    int fill = atomic_load(&b->fillCount);
    toRead = count < fill ? count : fill;
    int readIdx = atomic_load(&b->readIndex);
    for (int i = 0; i < toRead; i++) {
        out[i] = b->buffer[readIdx];
        readIdx = (readIdx + 1) % b->capacity;
    }
    atomic_store(&b->readIndex, readIdx);
    atomic_fetch_sub(&b->fillCount, toRead);
    pthread_mutex_unlock(&b->lock);
    return toRead;
}

int FFTBuffer_Fill(FFTBuffer *b) {
    if (!b) return 0;
    int fill = atomic_load(&b->fillCount);
    return fill;
}

void FFTBuffer_SetDropNew(FFTBuffer *b, int dropNew) {
    if (!b) return;
    b->dropNew = dropNew ? 1 : 0;
}

// Reads up to 'count' samples without consuming them
int FFTBuffer_Peek(FFTBuffer *b, float *out, int count) {
    if (!b) return 0;
    pthread_mutex_lock(&b->lock);
    int fill = atomic_load(&b->fillCount);
    int toPeek = count < fill ? count : fill;
    int idx = atomic_load(&b->readIndex);
    for (int i = 0; i < toPeek; i++) {
        out[i] = b->buffer[idx];
        idx = (idx + 1) % b->capacity;
    }
    pthread_mutex_unlock(&b->lock);
    return toPeek;
}

// Wrapper functions
FFTBuffer *createFFTBuffer(size_t capacity) {
    return FFTBuffer_Create((int)capacity);
}

void destroyFFTBuffer(FFTBuffer *b) {
    FFTBuffer_Destroy(b);
}

size_t fftGetBufferFillLevel(FFTBuffer *b) {
    return (size_t)FFTBuffer_Fill(b);
}

size_t fftReadFromBuffer(FFTBuffer *b, float *out, size_t count) {
    return (size_t)FFTBuffer_Read(b, out, (int)count);
}

void fftWriteToBuffer(FFTBuffer *b, const float *samples, size_t count) {
    FFTBuffer_Write(b, samples, (int)count);
}
