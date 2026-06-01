//
//  FFTRingBuffer.h
//  AVCMeter
//
//  Created by Chris Izatt on 28/06/2025.
//

#ifndef FFTRingBuffer_h
#define FFTRingBuffer_h

#include <stdatomic.h>
#include <stddef.h>
#include <pthread.h>

/**
 * A thread-safe ring buffer for FFT frames.
 */
typedef struct FFTBuffer {
    float *buffer;           // contiguous storage for samples
    int capacity;            // total sample capacity
    atomic_int writeIndex;   // next write position (atomic)
    atomic_int readIndex;    // next read position (atomic)
    atomic_int fillCount;    // number of available samples (atomic)
    int dropNew;             // flag: drop new samples when full
    pthread_mutex_t lock;    // mutex for thread-safe access
} FFTBuffer;

/**
 * Creates a new FFTBuffer with the given capacity.
 *
 * @param capacity The number of float samples the buffer can hold.
 * @return A pointer to the newly created buffer, or NULL on failure.
 */
FFTBuffer *createFFTBuffer(size_t capacity);

/**
 * Destroys an FFTBuffer, freeing all its resources.
 *
 * @param rb The buffer to destroy.
 */
void destroyFFTBuffer(FFTBuffer *rb);

/**
 * Returns the number of samples currently available in the buffer.
 *
 * @param rb The buffer to query.
 * @return The number of available samples.
 */
size_t fftGetBufferFillLevel(FFTBuffer *rb);

/**
 * Reads up to frameCount samples from the ring buffer.
 *
 * @param rb The buffer to read from.
 * @param outData Pre-allocated array to receive samples.
 * @param frameCount Maximum number of samples to read.
 * @return The actual number of samples read.
 */
size_t fftReadFromBuffer(FFTBuffer *rb, float *outData, size_t frameCount);

/**
 * Writes data into the ring buffer, overwriting oldest data if necessary.
 *
 * @param rb The buffer to write into.
 * @param data Pointer to the float samples to write.
 * @param frameCount Number of samples to write.
 */
void fftWriteToBuffer(FFTBuffer *rb, const float *data, size_t frameCount);

#endif /* FFTRingBuffer_h */
