#ifndef PodcastPreviewRouteInputEngine_h
#define PodcastPreviewRouteInputEngine_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "RingBuffer.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool isRunning;
    bool feedingTransport;
    AudioDeviceID deviceID;
    double sampleRate;
    uint32_t channels;
    uint32_t bufferFrames;
    uint64_t framesCaptured;
} PPRouteInputEngineStatus;

int PPRouteInputEngine_Start(AudioDeviceID deviceID, uint32_t bufferFrames, uint32_t inputChannels);
void PPRouteInputEngine_Stop(void);
bool PPRouteInputEngine_IsRunning(void);

RingBuffer *PPRouteInputEngine_GetTapRingBuffer(void);
uint32_t PPRouteInputEngine_GetTapChannelCount(void);
double PPRouteInputEngine_GetTapSampleRate(void);

void PPRouteInputEngine_GetStatus(PPRouteInputEngineStatus *outStatus);

#ifdef __cplusplus
}
#endif

#endif
