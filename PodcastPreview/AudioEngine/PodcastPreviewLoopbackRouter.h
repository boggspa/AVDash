#ifndef PodcastPreviewLoopbackRouter_h
#define PodcastPreviewLoopbackRouter_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "RingBuffer.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool isRunning;
    bool writerConnected;
    double sampleRate;
    uint32_t channels;
    uint32_t bufferFrames;
    uint64_t framesRendered;
    uint64_t framesAvailable;
    uint64_t overruns;
    uint64_t underruns;
} PPVirtualLoopbackRouterStatus;

int PPVirtualLoopbackRouter_Start(const char *outputDeviceUID, uint32_t preferredBufferFrames);
void PPVirtualLoopbackRouter_Stop(void);
bool PPVirtualLoopbackRouter_IsRunning(void);

RingBuffer *PPVirtualLoopbackRouter_GetTapRingBuffer(void);
uint32_t PPVirtualLoopbackRouter_GetTapChannelCount(void);
double PPVirtualLoopbackRouter_GetTapSampleRate(void);
void PPVirtualLoopbackRouter_SetTapAnalysisEnabled(bool enabled);
bool PPVirtualLoopbackRouter_IsTapAnalysisEnabled(void);

void PPVirtualLoopbackRouter_GetStatus(PPVirtualLoopbackRouterStatus *outStatus);

#ifdef __cplusplus
}
#endif

#endif
