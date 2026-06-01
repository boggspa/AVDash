//
//  SpectroInputStream.c
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//

#include <CoreAudio/CoreAudio.h>
#include "SpectroInputStream.h"
#include "SpectroProcessorBridge.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

extern int SpectroProcessor_ShouldProcessChannel(int deviceID, int channel);

static SpectroInputStream* gSpectroStreamList = NULL;
static pthread_mutex_t gSpectroStreamListLock = PTHREAD_MUTEX_INITIALIZER;

typedef struct SpectroInputStream {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    UInt32 channelCount;
    struct SpectroInputStream* next;
} SpectroInputStream;

// Stack buffer size for deinterleaving (avoids malloc for typical audio buffers)
#define SPECTRO_STACK_BUFFER_SIZE 2048

// MARK: - IOProc

/// @function SpectroIOProc
/// @brief Audio IO callback for processing incoming audio data from input devices.
///
/// This callback is invoked by Core Audio when audio data is available from the specified input device.
/// It processes audio buffers either in interleaved or non-interleaved format, extracting per-channel
/// float samples and forwarding them to the SpectroProcessor for spectral analysis.
///
/// Thread safety is ensured by locking the global stream list mutex during processing to access the stream list.
///
/// @param inDevice The AudioDeviceID of the input device producing the audio data.
/// @param inNow The current time stamp for the audio data.
/// @param inInputData The input audio buffer list containing audio samples.
/// @param inInputTime The input time stamp.
/// @param outOutputData The output audio buffer list (unused).
/// @param inOutputTime The output time stamp (unused).
/// @param clientData User-defined client data (unused).
/// @returns noErr on success.
static OSStatus SpectroIOProc(AudioDeviceID inDevice,
                              const AudioTimeStamp* inNow,
                              const AudioBufferList* inInputData,
                              const AudioTimeStamp* inInputTime,
                              AudioBufferList* outOutputData,
                              const AudioTimeStamp* inOutputTime,
                              void* clientData)
{
    (void)clientData;
    pthread_mutex_lock(&gSpectroStreamListLock);
    SpectroInputStream* cur = gSpectroStreamList;
    while (cur) {
        if (cur->deviceID == inDevice && inInputData) {
            UInt32 channelCount = cur->channelCount;
            if (inInputData->mNumberBuffers == 1) {
                // Interleaved audio buffer
                AudioBuffer *buf = &inInputData->mBuffers[0];
                float *interleaved = (float *)buf->mData;
                UInt32 frames = buf->mDataByteSize / (sizeof(float) * channelCount);

                // Deinterleave audio data into separate channel buffers
                for (UInt32 ch = 0; ch < channelCount; ++ch) {
                    if (!SpectroProcessor_ShouldProcessChannel((int)inDevice, (int)ch)) {
                        continue;
                    }
                    // Use stack buffer for small frames (common case), malloc for large
                    float stackBuffer[SPECTRO_STACK_BUFFER_SIZE];
                    float *channelData = (frames <= SPECTRO_STACK_BUFFER_SIZE) ? stackBuffer : (float *)malloc(sizeof(float) * frames);

                    if (!channelData) continue;  // Skip if allocation failed

                    for (UInt32 i = 0; i < frames; ++i) {
                        channelData[i] = interleaved[i * channelCount + ch];
                    }
                    SpectroProcessor_HandleInput((int)inDevice, (int)ch, channelData, (int)frames);

                    // Only free if it was allocated on heap (not stack)
                    if (frames > SPECTRO_STACK_BUFFER_SIZE) {
                        free(channelData);
                    }
                }
            } else {
                // Non-interleaved audio buffers, one per channel
                for (UInt32 ch = 0; ch < channelCount; ++ch) {
                    if (ch >= inInputData->mNumberBuffers) break;
                    if (!SpectroProcessor_ShouldProcessChannel((int)inDevice, (int)ch)) {
                        continue;
                    }
                    AudioBuffer *buf = &inInputData->mBuffers[ch];
                    float *data = (float *)buf->mData;
                    UInt32 frames = buf->mDataByteSize / sizeof(float);

                    // Use stack buffer for small frames (common case), malloc for large
                    #define STACK_BUFFER_SIZE 2048
                    float stackBuffer[STACK_BUFFER_SIZE];
                    float *copy = (frames <= STACK_BUFFER_SIZE) ? stackBuffer : (float *)malloc(sizeof(float) * frames);

                    if (!copy) continue;  // Skip if allocation failed

                    memcpy(copy, data, sizeof(float) * frames);
                    SpectroProcessor_HandleInput((int)inDevice, (int)ch, copy, (int)frames);

                    // Only free if it was allocated on heap (not stack)
                    if (frames > STACK_BUFFER_SIZE) {
                        free(copy);
                    }
                }
            }
        }
        cur = cur->next;
    }
    pthread_mutex_unlock(&gSpectroStreamListLock);
    return noErr;
}

// MARK: - Lifecycle

/// @function SpectroInputStream_Create
/// @brief Initializes a new SpectroInputStream instance for a given device and channel count.
///
/// This function allocates and registers a new stream instance, linking it to the global stream list.
/// If this is the first stream for the device, it also registers the IOProc callback with Core Audio.
///
/// @param deviceID The Core Audio ID of the input device.
/// @param channelCount The number of input channels for the stream.
/// @returns A pointer to the newly created SpectroInputStream, or NULL on failure.
SpectroInputStream* SpectroInputStream_Create(AudioDeviceID deviceID, UInt32 channelCount) {
    SpectroInputStream* stream = (SpectroInputStream*)calloc(1, sizeof(SpectroInputStream));
    if (!stream) return NULL;
    stream->deviceID = deviceID;
    stream->channelCount = channelCount;

    pthread_mutex_lock(&gSpectroStreamListLock);
    // Insert new stream at the head of the global list
    stream->next = gSpectroStreamList;
    gSpectroStreamList = stream;

    // Count how many streams are active for this device
    int count = 0;
    SpectroInputStream* cur = gSpectroStreamList;
    while (cur) {
        if (cur->deviceID == deviceID) count++;
        cur = cur->next;
    }
    // Register IOProc if this is the first stream for the device
    if (count == 1) {
        AudioDeviceAddIOProc(deviceID, SpectroIOProc, NULL);
    }
    pthread_mutex_unlock(&gSpectroStreamListLock);
    return stream;
}

/// @function SpectroInputStream_Destroy
/// @brief Destroys and unregisters a SpectroInputStream instance.
///
/// This function removes the stream from the global list, frees its resources,
/// and unregisters the IOProc from Core Audio if no other streams remain for the device.
///
/// @param stream The SpectroInputStream instance to destroy.
void SpectroInputStream_Destroy(SpectroInputStream* stream) {
    if (!stream) return;
    pthread_mutex_lock(&gSpectroStreamListLock);
    // Remove stream from global list
    SpectroInputStream** ptr = &gSpectroStreamList;
    while (*ptr) {
        if (*ptr == stream) {
            *ptr = stream->next;
            break;
        }
        ptr = &(*ptr)->next;
    }

    // Check if any other streams remain for the same device
    bool stillHas = false;
    SpectroInputStream* cur = gSpectroStreamList;
    while (cur) {
        if (cur->deviceID == stream->deviceID) {
            stillHas = true;
            break;
        }
        cur = cur->next;
    }
    // Unregister IOProc if no streams remain for the device
    if (!stillHas) {
        AudioDeviceRemoveIOProc(stream->deviceID, SpectroIOProc);
    }

    pthread_mutex_unlock(&gSpectroStreamListLock);
    free(stream);
}

// MARK: - Utility

/// @function SpectroInputStream_Clear
/// @brief Clears any buffered data for the stream.
///
/// Currently, no ring buffer is implemented, so this function is a placeholder.
///
/// @param stream The SpectroInputStream instance.
void SpectroInputStream_Clear(SpectroInputStream* stream) {
    (void)stream;
    // No ring buffer implemented here; clear logic would go here if needed.
}

/// @function SpectroInputStream_Read
/// @brief Reads audio data from the stream's buffer for a given channel.
///
/// Currently, no ring buffer is implemented, so this function returns zero.
///
/// @param stream The SpectroInputStream instance.
/// @param channel The channel index to read from.
/// @param buffer The output buffer to fill with audio samples.
/// @param frames The number of frames to read.
/// @returns The number of frames actually read (always 0 currently).
int SpectroInputStream_Read(SpectroInputStream* stream, int channel, float* buffer, int frames) {
    (void)stream; (void)channel; (void)buffer; (void)frames;
    // No ring buffer implemented here; read logic would go here if needed.
    return 0;
}

/// @function SpectroInputStream_Filled
/// @brief Returns the number of filled frames available in the stream's buffer for a given channel.
///
/// Currently, no ring buffer is implemented, so this function returns zero.
///
/// @param stream The SpectroInputStream instance.
/// @param channel The channel index.
/// @returns The number of filled frames (always 0 currently).
int SpectroInputStream_Filled(SpectroInputStream* stream, int channel) {
    (void)stream; (void)channel;
    // No ring buffer implemented here; filled logic would go here if needed.
    return 0;
}

/// @function SpectroInputStream_Start
/// @brief Starts audio input streaming on the specified stream's device.
///
/// This function starts the Core Audio device input and enables the IOProc callback.
///
/// @param stream The SpectroInputStream instance to start.
/// @returns An OSStatus code indicating success or failure.
OSStatus SpectroInputStream_Start(SpectroInputStream* stream) {
    if (!stream) return kAudio_ParamError;
    OSStatus err = AudioDeviceStart(stream->deviceID, SpectroIOProc);
    if (err == noErr) {
        stream->ioProcID = (AudioDeviceIOProcID)(uintptr_t)SpectroIOProc;
    }
    return err;
}

/// @function SpectroInputStream_Stop
/// @brief Stops audio input streaming on the specified stream's device.
///
/// This function stops the Core Audio device input and disables the IOProc callback.
///
/// @param stream The SpectroInputStream instance to stop.
/// @returns An OSStatus code indicating success or failure.
OSStatus SpectroInputStream_Stop(SpectroInputStream* stream) {
    if (!stream) return kAudio_ParamError;
    return AudioDeviceStop(stream->deviceID, SpectroIOProc);
}
