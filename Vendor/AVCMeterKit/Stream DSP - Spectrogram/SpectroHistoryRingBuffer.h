#ifndef SpectroHistoryRingBuffer_h
#define SpectroHistoryRingBuffer_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Forward declaration of internal structure
/// Opaque structure representing a 2D circular ring buffer
typedef struct SpectroHistoryRingBuffer SpectroHistoryRingBuffer;

/// Creates a new 2D history ring buffer with the given dimensions.
///
/// @param numBins     Number of vertical frequency bins (Y-axis).
/// @param numFrames   Number of horizontal time frames to retain (X-axis).
/// @return A pointer to the created buffer, or NULL on failure.
SpectroHistoryRingBuffer *SpectroHistoryRingBuffer_Create(size_t numBins, size_t numFrames);

/// Frees all memory associated with the ring buffer.
///
/// @param buffer The buffer to destroy.
void SpectroHistoryRingBuffer_Destroy(SpectroHistoryRingBuffer *buffer);

/// Returns the current write index (total frames written, not yet modulo'd).
///
/// @param buffer The ring buffer.
/// @return Total number of frames written so far.
int SpectroHistoryRingBuffer_GetWriteIndex(SpectroHistoryRingBuffer *buffer);

/// Returns the most recent frames in chronological order: oldest at x=0, newest at x=outFrames-1.
/// At most maxFrames are returned (the most recent ones). outFrames <= maxFrames.
///
/// @param buffer     The ring buffer.
/// @param maxFrames  Maximum number of frames to return (pass 0 for all filled frames).
/// @param outFrames  Output: number of valid frames returned.
/// @param outHeight  Output: number of frequency bins (Y).
/// @return Pointer to internal array of size (outFrames * outHeight), row-major.
const float *SpectroHistoryRingBuffer_GetLinearSnapshot(SpectroHistoryRingBuffer *buffer, size_t maxFrames, size_t *outFrames, size_t *outHeight);

/// Writes a single vertical frame of FFT magnitudes into the buffer.
///
/// @param buffer      The ring buffer to write into.
/// @param magnitudes  An array of float values of size `numBins`.
void SpectroHistoryRingBuffer_WriteFrame(SpectroHistoryRingBuffer *buffer, const float *magnitudes);

/// Retrieves a delayed snapshot of the full buffer contents, suitable for rendering.
///
/// @param buffer         The ring buffer to snapshot.
/// @param delayFrames    The number of most recent frames to delay (for smoothing).
/// @param outWidth       Output: number of frames (X).
/// @param outHeight      Output: number of bins (Y).
/// @return A pointer to an internal array of size (width * height) in row-major order.
const float *SpectroHistoryRingBuffer_GetSnapshot(SpectroHistoryRingBuffer *buffer, int delayFrames, size_t *outWidth, size_t *outHeight);

#ifdef __cplusplus
}
#endif

#endif /* SpectroHistoryRingBuffer_h */
