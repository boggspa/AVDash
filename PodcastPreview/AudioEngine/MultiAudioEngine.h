//
//  MultiAudioEngine.h
//  PodcastPreview
//
//  Created by Chris Izatt on 17/03/2026.
//
//  Multi-instance audio engine for simultaneous device monitoring.
//

#ifndef MultiAudioEngine_h
#define MultiAudioEngine_h

#include <CoreAudio/CoreAudio.h>
#include "RingBuffer.h"

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle for an audio engine instance
typedef struct AudioEngineInstance* AudioEngineHandle;

/**
 * Create a new audio engine instance for a specific device.
 *
 * @param deviceID The CoreAudio device ID to monitor
 * @param bufferSizeFrames Ring buffer size in frames
 * @param inputChannels Number of input channels to capture
 * @param outputChannels Number of output channels (usually 0 for monitoring)
 * @return Handle to the engine instance, or NULL on failure
 */
AudioEngineHandle AudioEngine_Create(AudioDeviceID deviceID,
                                      UInt32 bufferSizeFrames,
                                      UInt32 inputChannels,
                                      UInt32 outputChannels);

/**
 * Start monitoring on an engine instance.
 *
 * @param handle The engine instance handle
 * @return 0 on success, negative on error
 */
int AudioEngine_StartInstance(AudioEngineHandle handle);

/**
 * Stop monitoring on an engine instance.
 *
 * @param handle The engine instance handle
 */
void AudioEngine_StopInstance(AudioEngineHandle handle);

/**
 * Check if an engine instance is running.
 *
 * @param handle The engine instance handle
 * @return true if running, false otherwise
 */
Boolean AudioEngine_IsInstanceRunning(AudioEngineHandle handle);

/**
 * Get the ring buffer for an engine instance.
 *
 * @param handle The engine instance handle
 * @return Pointer to the ring buffer, or NULL if not available
 */
RingBuffer* AudioEngine_GetInstanceRingBuffer(AudioEngineHandle handle);

/**
 * Destroy an audio engine instance and free resources.
 *
 * @param handle The engine instance handle (will be stopped first if running)
 */
void AudioEngine_Destroy(AudioEngineHandle handle);

#ifdef __cplusplus
}
#endif

#endif /* MultiAudioEngine_h */
