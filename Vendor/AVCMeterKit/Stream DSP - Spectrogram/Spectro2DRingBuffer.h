///
///  Spectro2DRingBuffer.h
///  AVCMeter
///
///  Created by Chris Izatt on 30/06/2025.
///
///  @fileoverview
///  Header interface for Spectro2DRingBuffer, a fixed-size 2D float buffer with circular write capability
///  along the vertical (Y) axis. Designed for real-time spectrogram rendering with Metal.
///
///  Supports:
///  - Frame-wise vertical writes (each frame is a column of magnitudes)
///  - Ring-style vertical overwrite
///  - Optional render-safe snapshotting for Metal display
///

#ifndef Spectro2DRingBuffer_h
#define Spectro2DRingBuffer_h

#include <stddef.h>
#include <stdatomic.h>
#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque 2D ring buffer structure
typedef struct Spectro2DRingBuffer {
    float* data;                ///< Flat buffer: height × width
    int width;                  ///< Number of frequency bins (X axis)
    int height;                 ///< Number of frames in history (Y axis)
    atomic_int writeIndex;      ///< Current write row index (Y)
    pthread_mutex_t lock;       ///< Mutex for safe access
} Spectro2DRingBuffer;

/// Creates a new 2D ring buffer
/// @param width Number of frequency bins (columns)
/// @param height Number of time frames (rows)
/// @return Pointer to the allocated buffer, or NULL on failure
Spectro2DRingBuffer* Spectro2DRingBuffer_Create(int width, int height);

/// Frees a previously allocated ring buffer
/// @param buffer Pointer to the buffer to destroy
void Spectro2DRingBuffer_Destroy(Spectro2DRingBuffer* buffer);

/// Writes a vertical column of FFT magnitude values into the buffer
/// @param buffer Pointer to the ring buffer
/// @param columnData Array of floats with `height` elements (Y-axis column)
void Spectro2DRingBuffer_WriteColumn(Spectro2DRingBuffer* buffer, const float* columnData);

/// Retrieves a pointer to a delayed snapshot of the 2D buffer for Metal rendering
/// @param buffer Pointer to the buffer
/// @param delay Number of rows to delay the latest frame (e.g., for latency smoothing)
/// @param outWidth Output: number of columns in buffer
/// @param outHeight Output: number of rows in buffer
/// @return Read-only float pointer to flat array of `width × height`
const float* Spectro2DRingBuffer_GetSnapshot(Spectro2DRingBuffer* buffer, int delay, int* outWidth, int* outHeight);

#ifdef __cplusplus
}
#endif

#endif /* Spectro2DRingBuffer_h */
