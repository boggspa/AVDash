#ifndef PCM_INPUT_STREAM_H
#define PCM_INPUT_STREAM_H

#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

#include <pthread.h>
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include "PCMRingBuffer.h"


typedef struct PCMInputStream {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    pthread_mutex_t lock;
    float rms[64];
    float peak[64];
    UInt32 channelCount;
    void (*levelCallback)(float* rms, float* peak, UInt32 channelCount, void* context);
    void* callbackContext;
    AudioStreamBasicDescription streamFormat;
    void (*pcmCallback)(float** samples, UInt32 numFrames, UInt32 channelCount, void* context);
    PCMRingBuffer* ringBuffer;
    float** waveformBuffer; // Per-channel waveform buffer for visualization (dynamically allocated)
    float** sampleArrays; // Per-channel PCM buffer used in callbacks
} PCMInputStream;


/**
 * Creates a new PCM input stream for the specified AudioDeviceID.
 *
 * @param deviceID The CoreAudio device to stream from.
 * @param callback A callback function to receive RMS and Peak levels.
 * @param context A user-defined context pointer passed to the callback.
 * @return A pointer to the created PCMInputStream or NULL on failure.
 */
PCMInputStream* createPCMInputStream(AudioDeviceID deviceID,
                                     void (*callback)(float** samples, UInt32 numFrames, UInt32 channelCount, void* context),
                                     void* context);

/**
 * Destroys a previously created PCM input stream and frees all resources.
 *
 * @param stream The stream to destroy.
 */
void destroyPCMInputStream(PCMInputStream* stream);

void PCMInputStream_Clear(PCMInputStream* stream);
int PCMInputStream_Filled(PCMInputStream* stream);
int PCMInputStream_Read(PCMInputStream* stream, float* outBuffer, int frameCount);
void PCMInputStream_Write(PCMInputStream* stream, const float* samples, int frameCount);

int PCMInputStream_ReadChannel(PCMInputStream* stream, float* outBuffer, int frameCount, int channelIndex);

#ifdef __cplusplus
}
#endif

#endif // PCM_INPUT_STREAM_H
