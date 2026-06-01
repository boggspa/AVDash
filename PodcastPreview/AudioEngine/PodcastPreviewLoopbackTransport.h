#ifndef PodcastPreviewLoopbackTransport_h
#define PodcastPreviewLoopbackTransport_h

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PP_LOOPBACK_MAX_CHANNELS 8
#define PP_LOOPBACK_DEVICE_UID_MAX 256
#define PP_LOOPBACK_ERROR_TEXT_MAX 128

typedef enum {
    kPPVirtualLoopbackSourceInput = 0,
    kPPVirtualLoopbackSourceSystem = 1,
    kPPVirtualLoopbackSourceCount = 2
} PPVirtualLoopbackSourceID;

typedef struct PPVirtualLoopbackWriter *PPVirtualLoopbackWriterRef;
typedef struct PPVirtualLoopbackReader *PPVirtualLoopbackReaderRef;

typedef struct {
    double sampleRate;
    uint32_t channels;
    uint32_t ringCapacityFrames;
    uint32_t preferredIOBufferFrames;
} PPVirtualLoopbackStreamDescription;

typedef struct {
    bool writerConnected;
    bool inputWriterConnected;
    bool systemWriterConnected;
    bool inputSourceEnabled;
    bool systemSourceEnabled;
    bool routerRunning;
    double sampleRate;
    uint32_t channels;
    uint32_t ringCapacityFrames;
    uint32_t preferredIOBufferFrames;
    uint64_t framesWritten;
    uint64_t framesRead;
    uint64_t framesAvailable;
    uint64_t overruns;
    uint64_t underruns;
    uint64_t inputFramesWritten;
    uint64_t inputFramesRead;
    uint64_t inputFramesAvailable;
    float inputSourceGain;
    float inputSourcePeak;
    uint64_t systemFramesWritten;
    uint64_t systemFramesRead;
    uint64_t systemFramesAvailable;
    float systemSourceGain;
    float systemSourcePeak;
    char requestedOutputDeviceUID[PP_LOOPBACK_DEVICE_UID_MAX];
    char activeOutputDeviceUID[PP_LOOPBACK_DEVICE_UID_MAX];
    char lastError[PP_LOOPBACK_ERROR_TEXT_MAX];
} PPVirtualLoopbackStatus;

// Shared-memory writer API used by the app input engine and the
// AudioServerPlugIn-side system-output feed.
PPVirtualLoopbackWriterRef PPVirtualLoopbackTransport_OpenWriterForSource(PPVirtualLoopbackSourceID sourceID);
PPVirtualLoopbackWriterRef PPVirtualLoopbackTransport_OpenWriter(void);
void PPVirtualLoopbackTransport_CloseWriter(PPVirtualLoopbackWriterRef writer);
int PPVirtualLoopbackTransport_ConfigureWriter(PPVirtualLoopbackWriterRef writer,
                                               double sampleRate,
                                               uint32_t channels,
                                               uint32_t ringCapacityFrames,
                                               uint32_t preferredIOBufferFrames);
size_t PPVirtualLoopbackTransport_WriteInterleaved(PPVirtualLoopbackWriterRef writer,
                                                   const float *interleavedSamples,
                                                   uint32_t frames,
                                                   uint32_t channels);
size_t PPVirtualLoopbackTransport_WriteInterleavedWithTiming(PPVirtualLoopbackWriterRef writer,
                                                             const float *interleavedSamples,
                                                             uint32_t frames,
                                                             uint32_t channels,
                                                             uint64_t startHostTime,
                                                             double hostTicksPerFrame);

// Shared-memory reader API used by the app-side output router today and by a
// future AudioServerPlugIn output implementation when that target is added.
PPVirtualLoopbackReaderRef PPVirtualLoopbackTransport_OpenReader(void);
void PPVirtualLoopbackTransport_CloseReader(PPVirtualLoopbackReaderRef reader);
int PPVirtualLoopbackTransport_GetStreamDescription(PPVirtualLoopbackReaderRef reader,
                                                    PPVirtualLoopbackStreamDescription *outDescription);
size_t PPVirtualLoopbackTransport_ReadInterleaved(PPVirtualLoopbackReaderRef reader,
                                                  float *outSamples,
                                                  uint32_t maxFrames,
                                                  uint32_t maxChannels);
size_t PPVirtualLoopbackTransport_ReadInterleavedWithTiming(PPVirtualLoopbackReaderRef reader,
                                                            float *outSamples,
                                                            uint32_t maxFrames,
                                                            uint32_t maxChannels,
                                                            uint64_t outputStartHostTime,
                                                            double outputHostTicksPerFrame,
                                                            double outputSampleRate);

// Shared status/control surface between the plug-in and the app.
void PPVirtualLoopbackTransport_GetStatus(PPVirtualLoopbackStatus *outStatus);
int PPVirtualLoopbackTransport_SetRequestedOutputDeviceUID(const char *uidCString);
int PPVirtualLoopbackTransport_CopyRequestedOutputDeviceUID(char *outUID, uint32_t maxLen);
int PPVirtualLoopbackTransport_CopyLastError(char *outError, uint32_t maxLen);
void PPVirtualLoopbackTransport_SetRouterState(bool isRunning, const char *activeOutputDeviceUID);
void PPVirtualLoopbackTransport_SetLastError(const char *errorText);
int PPVirtualLoopbackTransport_SetSourceEnabled(PPVirtualLoopbackSourceID sourceID, bool isEnabled);
int PPVirtualLoopbackTransport_SetSourceGain(PPVirtualLoopbackSourceID sourceID, float linearGain);

#ifdef __cplusplus
}
#endif

#endif
