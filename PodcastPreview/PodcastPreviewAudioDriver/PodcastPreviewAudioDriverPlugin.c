#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/HostTime.h>
#include <CoreFoundation/CFPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "../AudioEngine/PodcastPreviewLoopbackTransport.h"

#define PP_DRIVER_FACTORY_UUID "0D81542D-E6F4-4B06-B0CF-449FFEB3E8CB"
#define PP_DRIVER_BUNDLE_ID CFSTR("com.chrisizatt.PodcastPreviewAudioDriver")
#define PP_DRIVER_PLUGIN_NAME CFSTR("Podcast Preview Audio Driver")
#define PP_DRIVER_MANUFACTURER CFSTR("Podcast Preview")
#define PP_DRIVER_DEVICE_NAME CFSTR("Podcast Preview Virtual Output")
#define PP_DRIVER_STREAM_NAME CFSTR("Main Output")
#define PP_DRIVER_DEVICE_UID CFSTR("com.chrisizatt.PodcastPreviewAudioDriver.device")
#define PP_DRIVER_MODEL_UID CFSTR("com.chrisizatt.PodcastPreviewAudioDriver.model")

enum {
    kPPDriverDeviceObjectID = 2,
    kPPDriverOutputStreamObjectID = 3,
    kPPDriverChannelCount = 2,
    kPPDriverDefaultBufferFrames = 512,
    kPPDriverMinBufferFrames = 64,
    kPPDriverMaxBufferFrames = 4096,
    kPPDriverZeroTimeStampPeriod = 16384,
    kPPDriverClockDomain = 0x50504456
};

enum {
    kPPDriverTransportRingMultiplier = 128
};

enum {
    kPPDriverPropertyLogLimit = 64
};

static const Float64 kPPDriverSupportedSampleRates[] = {
    44100.0,
    48000.0,
    88200.0,
    96000.0
};

static _Atomic UInt32 gPPDriverPropertyLogCount = 0;

typedef struct {
    AudioServerPlugInDriverInterface *interface;
    _Atomic UInt32 refCount;
    AudioServerPlugInHostRef host;
    PPVirtualLoopbackWriterRef writer;
    Float64 sampleRate;
    UInt32 bufferFrameSize;
    _Atomic UInt32 streamIsActive;
    _Atomic UInt32 ioClientCount;
    _Atomic UInt32 isRunning;
    _Atomic UInt64 anchorHostTime;
    _Atomic UInt64 zeroTimeStampSeed;
    _Atomic UInt64 lastSubmittedCycle;
    _Atomic UInt32 ioLogCount;
    _Atomic UInt32 ioWillDoLogCount;
    _Atomic UInt32 ioBeginLogCount;
} PodcastPreviewAudioDriverPlugin;

static void pp_configure_transport(PodcastPreviewAudioDriverPlugin *driver);

static HRESULT STDMETHODCALLTYPE PodcastPreviewAudioDriver_QueryInterface(void *inDriver,
                                                                          REFIID inUUID,
                                                                          LPVOID *outInterface);
static ULONG STDMETHODCALLTYPE PodcastPreviewAudioDriver_AddRef(void *inDriver);
static ULONG STDMETHODCALLTYPE PodcastPreviewAudioDriver_Release(void *inDriver);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_Initialize(AudioServerPlugInDriverRef inDriver,
                                                                       AudioServerPlugInHostRef inHost);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                                                         CFDictionaryRef inDescription,
                                                                         const AudioServerPlugInClientInfo *inClientInfo,
                                                                         AudioObjectID *outDeviceObjectID);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                                                          AudioObjectID inDeviceObjectID);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inDeviceObjectID,
                                                                            const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                                               AudioObjectID inDeviceObjectID,
                                                                               const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                                             AudioObjectID inDeviceObjectID,
                                                                                             UInt64 inChangeAction,
                                                                                             void *inChangeInfo);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                                           AudioObjectID inDeviceObjectID,
                                                                                           UInt64 inChangeAction,
                                                                                           void *inChangeInfo);
static Boolean STDMETHODCALLTYPE PodcastPreviewAudioDriver_HasProperty(AudioServerPlugInDriverRef inDriver,
                                                                       AudioObjectID inObjectID,
                                                                       pid_t inClientProcessID,
                                                                       const AudioObjectPropertyAddress *inAddress);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                                               AudioObjectID inObjectID,
                                                                               pid_t inClientProcessID,
                                                                               const AudioObjectPropertyAddress *inAddress,
                                                                               Boolean *outIsSettable);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                                                AudioObjectID inObjectID,
                                                                                pid_t inClientProcessID,
                                                                                const AudioObjectPropertyAddress *inAddress,
                                                                                UInt32 inQualifierDataSize,
                                                                                const void *inQualifierData,
                                                                                UInt32 *outDataSize);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inObjectID,
                                                                            pid_t inClientProcessID,
                                                                            const AudioObjectPropertyAddress *inAddress,
                                                                            UInt32 inQualifierDataSize,
                                                                            const void *inQualifierData,
                                                                            UInt32 inDataSize,
                                                                            UInt32 *outDataSize,
                                                                            void *outData);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inObjectID,
                                                                            pid_t inClientProcessID,
                                                                            const AudioObjectPropertyAddress *inAddress,
                                                                            UInt32 inQualifierDataSize,
                                                                            const void *inQualifierData,
                                                                            UInt32 inDataSize,
                                                                            const void *inData);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_StartIO(AudioServerPlugInDriverRef inDriver,
                                                                    AudioObjectID inDeviceObjectID,
                                                                    UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_StopIO(AudioServerPlugInDriverRef inDriver,
                                                                   AudioObjectID inDeviceObjectID,
                                                                   UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                                                             AudioObjectID inDeviceObjectID,
                                                                             UInt32 inClientID,
                                                                             Float64 *outSampleTime,
                                                                             UInt64 *outHostTime,
                                                                             UInt64 *outSeed);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                              AudioObjectID inDeviceObjectID,
                                                                              UInt32 inClientID,
                                                                              UInt32 inOperationID,
                                                                              Boolean *outWillDo,
                                                                              Boolean *outWillDoInPlace);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                             AudioObjectID inDeviceObjectID,
                                                                             UInt32 inClientID,
                                                                             UInt32 inOperationID,
                                                                             UInt32 inIOBufferFrameSize,
                                                                             const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                          AudioObjectID inDeviceObjectID,
                                                                          AudioObjectID inStreamObjectID,
                                                                          UInt32 inClientID,
                                                                          UInt32 inOperationID,
                                                                          UInt32 inIOBufferFrameSize,
                                                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                                                          void *ioMainBuffer,
                                                                          void *ioSecondaryBuffer);
static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                           AudioObjectID inDeviceObjectID,
                                                                           UInt32 inClientID,
                                                                           UInt32 inOperationID,
                                                                           UInt32 inIOBufferFrameSize,
                                                                           const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gPodcastPreviewAudioDriverInterface = {
    NULL,
    PodcastPreviewAudioDriver_QueryInterface,
    PodcastPreviewAudioDriver_AddRef,
    PodcastPreviewAudioDriver_Release,
    PodcastPreviewAudioDriver_Initialize,
    PodcastPreviewAudioDriver_CreateDevice,
    PodcastPreviewAudioDriver_DestroyDevice,
    PodcastPreviewAudioDriver_AddDeviceClient,
    PodcastPreviewAudioDriver_RemoveDeviceClient,
    PodcastPreviewAudioDriver_PerformDeviceConfigurationChange,
    PodcastPreviewAudioDriver_AbortDeviceConfigurationChange,
    PodcastPreviewAudioDriver_HasProperty,
    PodcastPreviewAudioDriver_IsPropertySettable,
    PodcastPreviewAudioDriver_GetPropertyDataSize,
    PodcastPreviewAudioDriver_GetPropertyData,
    PodcastPreviewAudioDriver_SetPropertyData,
    PodcastPreviewAudioDriver_StartIO,
    PodcastPreviewAudioDriver_StopIO,
    PodcastPreviewAudioDriver_GetZeroTimeStamp,
    PodcastPreviewAudioDriver_WillDoIOOperation,
    PodcastPreviewAudioDriver_BeginIOOperation,
    PodcastPreviewAudioDriver_DoIOOperation,
    PodcastPreviewAudioDriver_EndIOOperation
};

static PodcastPreviewAudioDriverPlugin *pp_driver(AudioServerPlugInDriverRef inDriver)
{
    return (PodcastPreviewAudioDriverPlugin *)inDriver;
}

static os_log_t pp_driver_log(void)
{
    static os_log_t sLog = NULL;
    if (sLog == NULL) {
        sLog = os_log_create("com.chrisizatt.PodcastPreviewAudioDriver", "driver");
    }
    return sLog;
}

static void pp_log_message(const char *message)
{
    os_log_with_type(pp_driver_log(), OS_LOG_TYPE_DEFAULT, "%{public}s", message);
}

static void pp_log_transport_failure(const char *message)
{
    os_log_with_type(pp_driver_log(), OS_LOG_TYPE_ERROR, "%{public}s", message);
}

static const char *pp_io_operation_name(UInt32 operationID)
{
    switch (operationID) {
        case kAudioServerPlugInIOOperationThread:
            return "Thread";
        case kAudioServerPlugInIOOperationCycle:
            return "Cycle";
        case kAudioServerPlugInIOOperationReadInput:
            return "ReadInput";
        case kAudioServerPlugInIOOperationConvertInput:
            return "ConvertInput";
        case kAudioServerPlugInIOOperationProcessInput:
            return "ProcessInput";
        case kAudioServerPlugInIOOperationProcessOutput:
            return "ProcessOutput";
        case kAudioServerPlugInIOOperationMixOutput:
            return "MixOutput";
        case kAudioServerPlugInIOOperationProcessMix:
            return "ProcessMix";
        case kAudioServerPlugInIOOperationConvertMix:
            return "ConvertMix";
        case kAudioServerPlugInIOOperationWriteMix:
            return "WriteMix";
        default:
            return "Unknown";
    }
}

static Boolean pp_is_supported_output_operation(UInt32 operationID)
{
    switch (operationID) {
        case kAudioServerPlugInIOOperationProcessOutput:
        case kAudioServerPlugInIOOperationMixOutput:
        case kAudioServerPlugInIOOperationProcessMix:
        case kAudioServerPlugInIOOperationConvertMix:
        case kAudioServerPlugInIOOperationWriteMix:
            return true;
        default:
            return false;
    }
}

static void pp_log_io_operation(PodcastPreviewAudioDriverPlugin *driver,
                                UInt32 operationID,
                                UInt32 frameCount,
                                UInt64 cycleCounter)
{
    if (!driver) {
        return;
    }

    UInt32 logIndex = atomic_fetch_add_explicit(&driver->ioLogCount, 1, memory_order_relaxed);
    if (logIndex >= 16) {
        return;
    }

    os_log_with_type(pp_driver_log(),
                     OS_LOG_TYPE_DEFAULT,
                     "IO op %{public}s (0x%08x) frames=%{public}u cycle=%{public}llu",
                     pp_io_operation_name(operationID),
                     (unsigned int)operationID,
                     (unsigned int)frameCount,
                     (unsigned long long)cycleCounter);
}

static void pp_log_will_do_operation(PodcastPreviewAudioDriverPlugin *driver,
                                     UInt32 operationID,
                                     Boolean willDo)
{
    if (!driver) {
        return;
    }

    UInt32 logIndex = atomic_fetch_add_explicit(&driver->ioWillDoLogCount, 1, memory_order_relaxed);
    if (logIndex >= 24) {
        return;
    }

    os_log_with_type(pp_driver_log(),
                     OS_LOG_TYPE_DEFAULT,
                     "WillDo op %{public}s (0x%08x) willDo=%{public}d",
                     pp_io_operation_name(operationID),
                     (unsigned int)operationID,
                     (int)willDo);
}

static void pp_log_begin_operation(PodcastPreviewAudioDriverPlugin *driver,
                                   UInt32 operationID,
                                   UInt32 frameCount,
                                   UInt64 cycleCounter)
{
    if (!driver) {
        return;
    }

    UInt32 logIndex = atomic_fetch_add_explicit(&driver->ioBeginLogCount, 1, memory_order_relaxed);
    if (logIndex >= 32) {
        return;
    }

    os_log_with_type(pp_driver_log(),
                     OS_LOG_TYPE_DEFAULT,
                     "Begin op %{public}s (0x%08x) frames=%{public}u cycle=%{public}llu",
                     pp_io_operation_name(operationID),
                     (unsigned int)operationID,
                     (unsigned int)frameCount,
                     (unsigned long long)cycleCounter);
}

static void pp_log_property_event(const char *context,
                                  AudioObjectID objectID,
                                  const AudioObjectPropertyAddress *address,
                                  OSStatus status)
{
    UInt32 logIndex = atomic_fetch_add_explicit(&gPPDriverPropertyLogCount, 1, memory_order_relaxed);
    if (logIndex >= kPPDriverPropertyLogLimit) {
        return;
    }

    if (!address) {
        os_log_with_type(pp_driver_log(),
                         OS_LOG_TYPE_ERROR,
                         "%{public}s object=%{public}u status=%{public}d",
                         context,
                         (unsigned int)objectID,
                         (int)status);
    } else {
        os_log_with_type(pp_driver_log(),
                         OS_LOG_TYPE_ERROR,
                         "%{public}s object=%{public}u selector=0x%08x scope=0x%08x element=%{public}u status=%{public}d",
                         context,
                         (unsigned int)objectID,
                         (unsigned int)address->mSelector,
                         (unsigned int)address->mScope,
                         (unsigned int)address->mElement,
                         (int)status);
    }

    if (logIndex + 1 == kPPDriverPropertyLogLimit) {
        os_log_with_type(pp_driver_log(),
                         OS_LOG_TYPE_ERROR,
                         "Further unsupported property errors suppressed");
    }
}

static void pp_fill_stream_description(AudioStreamBasicDescription *outDescription, Float64 sampleRate)
{
    if (!outDescription) {
        return;
    }

    memset(outDescription, 0, sizeof(*outDescription));
    outDescription->mSampleRate = sampleRate;
    outDescription->mFormatID = kAudioFormatLinearPCM;
    outDescription->mFormatFlags = kAudioFormatFlagIsFloat |
        kAudioFormatFlagIsPacked |
        kAudioFormatFlagsNativeEndian;
    outDescription->mFramesPerPacket = 1;
    outDescription->mChannelsPerFrame = kPPDriverChannelCount;
    outDescription->mBitsPerChannel = 32;
    outDescription->mBytesPerFrame = sizeof(Float32) * kPPDriverChannelCount;
    outDescription->mBytesPerPacket = outDescription->mBytesPerFrame;
}

static OSStatus pp_copy_cfstring(CFStringRef value, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (!outDataSize || !outData) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDataSize < sizeof(CFStringRef)) {
        return kAudioHardwareBadPropertySizeError;
    }
    *((CFStringRef *)outData) = (CFStringRef)CFRetain(value);
    *outDataSize = sizeof(CFStringRef);
    return kAudioHardwareNoError;
}

static OSStatus pp_copy_bytes(const void *source, UInt32 sourceSize, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (!source || !outDataSize || !outData) {
        return kAudioHardwareIllegalOperationError;
    }
    if (inDataSize < sourceSize) {
        return kAudioHardwareBadPropertySizeError;
    }
    memcpy(outData, source, sourceSize);
    *outDataSize = sourceSize;
    return kAudioHardwareNoError;
}

static OSStatus pp_copy_stereo_channel_layout(UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    AudioChannelLayout layout;
    memset(&layout, 0, sizeof(layout));
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
    layout.mChannelBitmap = 0;
    layout.mNumberChannelDescriptions = 0;

    return pp_copy_bytes(&layout,
                         (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions),
                         inDataSize,
                         outDataSize,
                         outData);
}

static void pp_notify_device_running(PodcastPreviewAudioDriverPlugin *driver)
{
    if (!driver || !driver->host || !driver->host->PropertiesChanged) {
        return;
    }

    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyDeviceIsRunning,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    driver->host->PropertiesChanged(driver->host, kPPDriverDeviceObjectID, 1, &address);
}

static UInt32 pp_supported_sample_rate_count(void)
{
    return (UInt32)(sizeof(kPPDriverSupportedSampleRates) / sizeof(kPPDriverSupportedSampleRates[0]));
}

static Float64 pp_normalize_supported_sample_rate(Float64 requestedRate)
{
    if (requestedRate <= 0.0) {
        return 48000.0;
    }

    Float64 bestRate = kPPDriverSupportedSampleRates[0];
    Float64 bestDistance = fabs(requestedRate - bestRate);
    for (UInt32 index = 1; index < pp_supported_sample_rate_count(); ++index) {
        Float64 candidateRate = kPPDriverSupportedSampleRates[index];
        Float64 candidateDistance = fabs(requestedRate - candidateRate);
        if (candidateDistance < bestDistance) {
            bestRate = candidateRate;
            bestDistance = candidateDistance;
        }
    }
    return bestRate;
}

static void pp_notify_sample_rate_changed(PodcastPreviewAudioDriverPlugin *driver)
{
    if (!driver || !driver->host || !driver->host->PropertiesChanged) {
        return;
    }

    AudioObjectPropertyAddress deviceAddresses[] = {
        {
            .mSelector = kAudioDevicePropertyNominalSampleRate,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        },
        {
            .mSelector = kAudioDevicePropertyAvailableNominalSampleRates,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain
        }
    };
    driver->host->PropertiesChanged(driver->host,
                                    kPPDriverDeviceObjectID,
                                    (UInt32)(sizeof(deviceAddresses) / sizeof(deviceAddresses[0])),
                                    deviceAddresses);

    AudioObjectPropertyAddress streamAddresses[] = {
        {
            .mSelector = kAudioStreamPropertyVirtualFormat,
            .mScope = kAudioObjectPropertyScopeOutput,
            .mElement = kAudioObjectPropertyElementMain
        },
        {
            .mSelector = kAudioStreamPropertyPhysicalFormat,
            .mScope = kAudioObjectPropertyScopeOutput,
            .mElement = kAudioObjectPropertyElementMain
        },
        {
            .mSelector = kAudioStreamPropertyAvailableVirtualFormats,
            .mScope = kAudioObjectPropertyScopeOutput,
            .mElement = kAudioObjectPropertyElementMain
        },
        {
            .mSelector = kAudioStreamPropertyAvailablePhysicalFormats,
            .mScope = kAudioObjectPropertyScopeOutput,
            .mElement = kAudioObjectPropertyElementMain
        }
    };
    driver->host->PropertiesChanged(driver->host,
                                    kPPDriverOutputStreamObjectID,
                                    (UInt32)(sizeof(streamAddresses) / sizeof(streamAddresses[0])),
                                    streamAddresses);
}

static OSStatus pp_update_driver_sample_rate(PodcastPreviewAudioDriverPlugin *driver, Float64 requestedRate)
{
    if (!driver) {
        return kAudioHardwareIllegalOperationError;
    }

    Float64 normalizedRate = pp_normalize_supported_sample_rate(requestedRate);
    if (fabs(driver->sampleRate - normalizedRate) < 0.5) {
        return kAudioHardwareNoError;
    }

    driver->sampleRate = normalizedRate;
    pp_configure_transport(driver);
    atomic_store_explicit(&driver->anchorHostTime, AudioGetCurrentHostTime(), memory_order_release);
    atomic_fetch_add_explicit(&driver->zeroTimeStampSeed, 1, memory_order_acq_rel);
    pp_notify_sample_rate_changed(driver);
    return kAudioHardwareNoError;
}

static void pp_configure_transport(PodcastPreviewAudioDriverPlugin *driver)
{
    if (!driver) {
        return;
    }

    if (!driver->writer) {
        driver->writer = PPVirtualLoopbackTransport_OpenWriterForSource(kPPVirtualLoopbackSourceSystem);
        if (!driver->writer) {
            char transportError[PP_LOOPBACK_ERROR_TEXT_MAX];
            transportError[0] = '\0';
            PPVirtualLoopbackTransport_CopyLastError(transportError, sizeof(transportError));
            if (transportError[0] == '\0') {
                PPVirtualLoopbackTransport_SetLastError("Audio driver failed to open the loopback transport writer.");
                pp_log_transport_failure("Failed to open the loopback transport writer.");
            } else {
                PPVirtualLoopbackTransport_SetLastError(transportError);
                pp_log_transport_failure(transportError);
            }
            return;
        }
        PPVirtualLoopbackTransport_SetLastError("");
    }

    if (PPVirtualLoopbackTransport_ConfigureWriter(driver->writer,
                                                   driver->sampleRate,
                                                   kPPDriverChannelCount,
                                                   driver->bufferFrameSize * kPPDriverTransportRingMultiplier,
                                                   driver->bufferFrameSize) != 0) {
        PPVirtualLoopbackTransport_SetLastError("Audio driver failed to configure the loopback transport writer.");
        pp_log_transport_failure("Failed to configure the loopback transport writer.");
        return;
    }

    PPVirtualLoopbackTransport_SetLastError("");
}

static Boolean pp_is_supported_plugin_property(AudioObjectPropertySelector selector)
{
    switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCreator:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            return true;
        default:
            return false;
    }
}

static Boolean pp_is_supported_device_property(const AudioObjectPropertyAddress *address)
{
    if (!address) {
        return false;
    }

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCreator:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyStreamConfiguration:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioDevicePropertyClockIsStable:
            return true;
        default:
            return false;
    }
}

static Boolean pp_is_supported_stream_property(AudioObjectPropertySelector selector)
{
    switch (selector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyCreator:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

void *PodcastPreviewAudioDriverFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;

    if (!requestedTypeUUID || !CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    PodcastPreviewAudioDriverPlugin *driver = (PodcastPreviewAudioDriverPlugin *)calloc(1, sizeof(*driver));
    if (!driver) {
        return NULL;
    }

    driver->interface = &gPodcastPreviewAudioDriverInterface;
    atomic_store_explicit(&driver->refCount, 1, memory_order_relaxed);
    driver->sampleRate = 48000.0;
    driver->bufferFrameSize = kPPDriverDefaultBufferFrames;
    atomic_store_explicit(&driver->streamIsActive, 1, memory_order_relaxed);
    atomic_store_explicit(&driver->zeroTimeStampSeed, 1, memory_order_relaxed);
    atomic_store_explicit(&driver->lastSubmittedCycle, 0, memory_order_relaxed);
    atomic_store_explicit(&driver->ioLogCount, 0, memory_order_relaxed);
    atomic_store_explicit(&driver->ioBeginLogCount, 0, memory_order_relaxed);

    pp_log_message("Factory created driver instance.");
    return driver;
}

static HRESULT STDMETHODCALLTYPE PodcastPreviewAudioDriver_QueryInterface(void *inDriver,
                                                                          REFIID inUUID,
                                                                          LPVOID *outInterface)
{
    if (!outInterface) {
        return E_POINTER;
    }

    *outInterface = NULL;
    if (!inDriver) {
        return E_POINTER;
    }

    CFUUIDRef interfaceUUID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    if (!interfaceUUID) {
        return E_NOINTERFACE;
    }

    Boolean supported = CFEqual(interfaceUUID, IUnknownUUID) ||
        CFEqual(interfaceUUID, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(interfaceUUID);

    if (!supported) {
        return E_NOINTERFACE;
    }

    PodcastPreviewAudioDriver_AddRef(inDriver);
    *outInterface = inDriver;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE PodcastPreviewAudioDriver_AddRef(void *inDriver)
{
    PodcastPreviewAudioDriverPlugin *driver = (PodcastPreviewAudioDriverPlugin *)inDriver;
    if (!driver) {
        return 0;
    }
    return atomic_fetch_add_explicit(&driver->refCount, 1, memory_order_relaxed) + 1;
}

static ULONG STDMETHODCALLTYPE PodcastPreviewAudioDriver_Release(void *inDriver)
{
    PodcastPreviewAudioDriverPlugin *driver = (PodcastPreviewAudioDriverPlugin *)inDriver;
    if (!driver) {
        return 0;
    }

    UInt32 newCount = atomic_fetch_sub_explicit(&driver->refCount, 1, memory_order_acq_rel) - 1;
    if (newCount == 0) {
        if (driver->writer) {
            PPVirtualLoopbackTransport_CloseWriter(driver->writer);
            driver->writer = NULL;
        }

        free(driver);
    }
    return newCount;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_Initialize(AudioServerPlugInDriverRef inDriver,
                                                                       AudioServerPlugInHostRef inHost)
{
    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    if (!driver) {
        return kAudioHardwareIllegalOperationError;
    }

    driver->host = inHost;
    atomic_store_explicit(&driver->anchorHostTime, AudioGetCurrentHostTime(), memory_order_release);
    pp_configure_transport(driver);
    pp_log_message("Initialize completed.");
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                                                         CFDictionaryRef inDescription,
                                                                         const AudioServerPlugInClientInfo *inClientInfo,
                                                                         AudioObjectID *outDeviceObjectID)
{
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    if (!outDeviceObjectID) {
        return kAudioHardwareIllegalOperationError;
    }
    *outDeviceObjectID = kPPDriverDeviceObjectID;
    pp_log_message("CreateDevice returned the virtual output device.");
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                                                          AudioObjectID inDeviceObjectID)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inDeviceObjectID,
                                                                            const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                                               AudioObjectID inDeviceObjectID,
                                                                               const AudioServerPlugInClientInfo *inClientInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                                             AudioObjectID inDeviceObjectID,
                                                                                             UInt64 inChangeAction,
                                                                                             void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                                           AudioObjectID inDeviceObjectID,
                                                                                           UInt64 inChangeAction,
                                                                                           void *inChangeInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inChangeAction;
    (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static Boolean STDMETHODCALLTYPE PodcastPreviewAudioDriver_HasProperty(AudioServerPlugInDriverRef inDriver,
                                                                       AudioObjectID inObjectID,
                                                                       pid_t inClientProcessID,
                                                                       const AudioObjectPropertyAddress *inAddress)
{
    (void)inDriver;
    (void)inClientProcessID;
    if (!inAddress) {
        return false;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            return pp_is_supported_plugin_property(inAddress->mSelector);
        case kPPDriverDeviceObjectID:
            return pp_is_supported_device_property(inAddress);
        case kPPDriverOutputStreamObjectID:
            return pp_is_supported_stream_property(inAddress->mSelector);
        default:
            return false;
    }
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                                               AudioObjectID inObjectID,
                                                                               pid_t inClientProcessID,
                                                                               const AudioObjectPropertyAddress *inAddress,
                                                                               Boolean *outIsSettable)
{
    (void)inDriver;
    (void)inObjectID;
    (void)inClientProcessID;
    if (!inAddress || !outIsSettable) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!PodcastPreviewAudioDriver_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (inObjectID == kPPDriverOutputStreamObjectID &&
        inAddress->mSelector == kAudioStreamPropertyIsActive) {
        *outIsSettable = true;
        return kAudioHardwareNoError;
    }
    if (inObjectID == kPPDriverDeviceObjectID &&
        inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outIsSettable = true;
        return kAudioHardwareNoError;
    }
    if (inObjectID == kPPDriverOutputStreamObjectID &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
         inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        *outIsSettable = true;
        return kAudioHardwareNoError;
    }
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                                                AudioObjectID inObjectID,
                                                                                pid_t inClientProcessID,
                                                                                const AudioObjectPropertyAddress *inAddress,
                                                                                UInt32 inQualifierDataSize,
                                                                                const void *inQualifierData,
                                                                                UInt32 *outDataSize)
{
    (void)inDriver;
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    if (!inAddress || !outDataSize) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyCreator:
                case kAudioPlugInPropertyBundleID:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                default:
                    pp_log_property_event("GetPropertyDataSize unsupported plug-in property",
                                          inObjectID,
                                          inAddress,
                                          kAudioHardwareUnknownPropertyError);
                    return kAudioHardwareUnknownPropertyError;
            }

        case kPPDriverDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyClockAlgorithm:
                case kAudioDevicePropertyClockIsStable:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyCreator:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreams:
                    *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeOutput || inAddress->mScope == kAudioObjectPropertyScopeGlobal)
                        ? sizeof(AudioObjectID)
                        : 0;
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = (UInt32)(sizeof(AudioValueRange) * pp_supported_sample_rate_count());
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyBufferFrameSizeRange:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreamConfiguration:
                    *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeInput)
                        ? (UInt32)offsetof(AudioBufferList, mBuffers)
                        : (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = sizeof(UInt32) * 2;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyPreferredChannelLayout:
                    *outDataSize = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions);
                    return kAudioHardwareNoError;
                default:
                    pp_log_property_event("GetPropertyDataSize unsupported device property",
                                          inObjectID,
                                          inAddress,
                                          kAudioHardwareUnknownPropertyError);
                    return kAudioHardwareUnknownPropertyError;
            }

        case kPPDriverOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioObjectPropertyCreator:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = (UInt32)(sizeof(AudioStreamRangedDescription) * pp_supported_sample_rate_count());
                    return kAudioHardwareNoError;
                default:
                    pp_log_property_event("GetPropertyDataSize unsupported stream property",
                                          inObjectID,
                                          inAddress,
                                          kAudioHardwareUnknownPropertyError);
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            pp_log_property_event("GetPropertyDataSize bad object",
                                  inObjectID,
                                  inAddress,
                                  kAudioHardwareBadObjectError);
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inObjectID,
                                                                            pid_t inClientProcessID,
                                                                            const AudioObjectPropertyAddress *inAddress,
                                                                            UInt32 inQualifierDataSize,
                                                                            const void *inQualifierData,
                                                                            UInt32 inDataSize,
                                                                            UInt32 *outDataSize,
                                                                            void *outData)
{
    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    if (!driver || !inAddress || !outDataSize || !outData) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass: {
                    AudioClassID value = kAudioObjectClassID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyClass: {
                    AudioClassID value = kAudioPlugInClassID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyOwner: {
                    AudioObjectID value = kAudioObjectUnknown;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyName:
                    return pp_copy_cfstring(PP_DRIVER_PLUGIN_NAME, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyManufacturer:
                    return pp_copy_cfstring(PP_DRIVER_MANUFACTURER, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyCreator:
                case kAudioPlugInPropertyBundleID:
                    return pp_copy_cfstring(PP_DRIVER_BUNDLE_ID, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList: {
                    AudioObjectID value = kPPDriverDeviceObjectID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    AudioObjectID value = kAudioObjectUnknown;
                    if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData) {
                        CFStringRef uid = *((const CFStringRef *)inQualifierData);
                        if (uid && CFEqual(uid, PP_DRIVER_DEVICE_UID)) {
                            value = kPPDriverDeviceObjectID;
                        }
                    }
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                default:
                    pp_log_property_event("GetPropertyData unsupported plug-in property",
                                          inObjectID,
                                          inAddress,
                                          kAudioHardwareUnknownPropertyError);
                    return kAudioHardwareUnknownPropertyError;
            }

        case kPPDriverDeviceObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass: {
                    AudioClassID value = kAudioObjectClassID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyClass: {
                    AudioClassID value = kAudioDeviceClassID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyOwner: {
                    AudioObjectID value = kAudioObjectPlugInObject;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyName:
                    return pp_copy_cfstring(PP_DRIVER_DEVICE_NAME, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyModelName:
                    return pp_copy_cfstring(PP_DRIVER_PLUGIN_NAME, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyManufacturer:
                    return pp_copy_cfstring(PP_DRIVER_MANUFACTURER, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyCreator:
                    return pp_copy_cfstring(PP_DRIVER_BUNDLE_ID, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID value = kPPDriverOutputStreamObjectID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyDeviceUID:
                    return pp_copy_cfstring(PP_DRIVER_DEVICE_UID, inDataSize, outDataSize, outData);
                case kAudioDevicePropertyModelUID:
                    return pp_copy_cfstring(PP_DRIVER_MODEL_UID, inDataSize, outDataSize, outData);
                case kAudioDevicePropertyTransportType: {
                    UInt32 value = kAudioDeviceTransportTypeVirtual;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyClockDomain: {
                    UInt32 value = kPPDriverClockDomain;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyDeviceIsAlive: {
                    UInt32 value = 1;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyDeviceIsRunning: {
                    UInt32 value = atomic_load_explicit(&driver->isRunning, memory_order_acquire) ? 1U : 0U;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyDeviceCanBeDefaultDevice: {
                    UInt32 value = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0U : 1U;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: {
                    UInt32 value = (inAddress->mScope == kAudioObjectPropertyScopeInput) ? 0U : 1U;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyIsHidden: {
                    UInt32 value = 0;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset: {
                    UInt32 value = 0;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyStreams: {
                    if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                        *outDataSize = 0;
                        return kAudioHardwareNoError;
                    }
                    AudioObjectID value = kPPDriverOutputStreamObjectID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                    return pp_copy_bytes(&driver->sampleRate, sizeof(driver->sampleRate), inDataSize, outDataSize, outData);
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange values[sizeof(kPPDriverSupportedSampleRates) / sizeof(kPPDriverSupportedSampleRates[0])];
                    for (UInt32 index = 0; index < pp_supported_sample_rate_count(); ++index) {
                        values[index].mMinimum = kPPDriverSupportedSampleRates[index];
                        values[index].mMaximum = kPPDriverSupportedSampleRates[index];
                    }
                    return pp_copy_bytes(values, sizeof(values), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyBufferFrameSize: {
                    UInt32 value = driver->bufferFrameSize;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyBufferFrameSizeRange: {
                    AudioValueRange value = { kPPDriverMinBufferFrames, kPPDriverMaxBufferFrames };
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyStreamConfiguration: {
                    if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                        UInt32 required = (UInt32)offsetof(AudioBufferList, mBuffers);
                        if (inDataSize < required) {
                            return kAudioHardwareBadPropertySizeError;
                        }
                        AudioBufferList *bufferList = (AudioBufferList *)outData;
                        bufferList->mNumberBuffers = 0;
                        *outDataSize = required;
                        return kAudioHardwareNoError;
                    }

                    UInt32 required = (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
                    if (inDataSize < required) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    AudioBufferList *bufferList = (AudioBufferList *)outData;
                    bufferList->mNumberBuffers = 1;
                    bufferList->mBuffers[0].mNumberChannels = kPPDriverChannelCount;
                    bufferList->mBuffers[0].mDataByteSize = 0;
                    bufferList->mBuffers[0].mData = NULL;
                    *outDataSize = required;
                    return kAudioHardwareNoError;
                }
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    UInt32 channels[2] = { 1, 2 };
                    return pp_copy_bytes(channels, sizeof(channels), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyPreferredChannelLayout:
                    return pp_copy_stereo_channel_layout(inDataSize, outDataSize, outData);
                case kAudioDevicePropertyZeroTimeStampPeriod: {
                    UInt32 value = kPPDriverZeroTimeStampPeriod;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyClockAlgorithm: {
                    UInt32 value = kAudioDeviceClockAlgorithmRaw;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioDevicePropertyClockIsStable: {
                    UInt32 value = 1;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                default:
                    pp_log_property_event("GetPropertyData unsupported device property",
                                          inObjectID,
                                          inAddress,
                                          kAudioHardwareUnknownPropertyError);
                    return kAudioHardwareUnknownPropertyError;
            }

        case kPPDriverOutputStreamObjectID:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass: {
                    AudioClassID value = kAudioObjectClassID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyClass: {
                    AudioClassID value = kAudioStreamClassID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyOwner: {
                    AudioObjectID value = kPPDriverDeviceObjectID;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioObjectPropertyName:
                    return pp_copy_cfstring(PP_DRIVER_STREAM_NAME, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyManufacturer:
                    return pp_copy_cfstring(PP_DRIVER_MANUFACTURER, inDataSize, outDataSize, outData);
                case kAudioObjectPropertyCreator:
                    return pp_copy_cfstring(PP_DRIVER_BUNDLE_ID, inDataSize, outDataSize, outData);
                case kAudioStreamPropertyIsActive: {
                    UInt32 value = atomic_load_explicit(&driver->streamIsActive, memory_order_acquire);
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioStreamPropertyDirection: {
                    UInt32 value = 0;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioStreamPropertyTerminalType: {
                    UInt32 value = kAudioStreamTerminalTypeSpeaker;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioStreamPropertyStartingChannel: {
                    UInt32 value = 1;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioStreamPropertyLatency: {
                    UInt32 value = 0;
                    return pp_copy_bytes(&value, sizeof(value), inDataSize, outDataSize, outData);
                }
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    AudioStreamBasicDescription description;
                    pp_fill_stream_description(&description, driver->sampleRate);
                    return pp_copy_bytes(&description, sizeof(description), inDataSize, outDataSize, outData);
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    AudioStreamRangedDescription descriptions[sizeof(kPPDriverSupportedSampleRates) / sizeof(kPPDriverSupportedSampleRates[0])];
                    memset(descriptions, 0, sizeof(descriptions));
                    for (UInt32 index = 0; index < pp_supported_sample_rate_count(); ++index) {
                        pp_fill_stream_description(&descriptions[index].mFormat, kPPDriverSupportedSampleRates[index]);
                        descriptions[index].mSampleRateRange.mMinimum = kPPDriverSupportedSampleRates[index];
                        descriptions[index].mSampleRateRange.mMaximum = kPPDriverSupportedSampleRates[index];
                    }
                    return pp_copy_bytes(descriptions, sizeof(descriptions), inDataSize, outDataSize, outData);
                }
                default:
                    pp_log_property_event("GetPropertyData unsupported stream property",
                                          inObjectID,
                                          inAddress,
                                          kAudioHardwareUnknownPropertyError);
                    return kAudioHardwareUnknownPropertyError;
            }

        default:
            pp_log_property_event("GetPropertyData bad object",
                                  inObjectID,
                                  inAddress,
                                  kAudioHardwareBadObjectError);
            return kAudioHardwareBadObjectError;
    }
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                                            AudioObjectID inObjectID,
                                                                            pid_t inClientProcessID,
                                                                            const AudioObjectPropertyAddress *inAddress,
                                                                            UInt32 inQualifierDataSize,
                                                                            const void *inQualifierData,
                                                                            UInt32 inDataSize,
                                                                            const void *inData)
{
    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    (void)inClientProcessID;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    if (!driver || !inAddress || !inData) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inObjectID == kPPDriverOutputStreamObjectID &&
        inAddress->mSelector == kAudioStreamPropertyIsActive) {
        if (inDataSize < sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }

        UInt32 isActive = *((const UInt32 *)inData) ? 1U : 0U;
        atomic_store_explicit(&driver->streamIsActive, isActive, memory_order_release);
        return kAudioHardwareNoError;
    }

    if (inObjectID == kPPDriverDeviceObjectID &&
        inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }
        return pp_update_driver_sample_rate(driver, *((const Float64 *)inData));
    }

    if (inObjectID == kPPDriverOutputStreamObjectID &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
         inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        const AudioStreamBasicDescription *description = (const AudioStreamBasicDescription *)inData;
        if (description->mSampleRate <= 0.0) {
            return kAudioHardwareIllegalOperationError;
        }
        return pp_update_driver_sample_rate(driver, description->mSampleRate);
    }

    pp_log_property_event("SetPropertyData rejected",
                          inObjectID,
                          inAddress,
                          kAudioHardwareIllegalOperationError);
    return kAudioHardwareIllegalOperationError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_StartIO(AudioServerPlugInDriverRef inDriver,
                                                                    AudioObjectID inDeviceObjectID,
                                                                    UInt32 inClientID)
{
    (void)inDeviceObjectID;
    (void)inClientID;
    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    if (!driver) {
        return kAudioHardwareIllegalOperationError;
    }

    pp_configure_transport(driver);
    atomic_store_explicit(&driver->lastSubmittedCycle, 0, memory_order_release);
    atomic_store_explicit(&driver->ioLogCount, 0, memory_order_release);
    atomic_store_explicit(&driver->ioWillDoLogCount, 0, memory_order_release);
    atomic_store_explicit(&driver->ioBeginLogCount, 0, memory_order_release);
    UInt32 previousCount = atomic_fetch_add_explicit(&driver->ioClientCount, 1, memory_order_acq_rel);
    if (previousCount == 0) {
        atomic_store_explicit(&driver->anchorHostTime, AudioGetCurrentHostTime(), memory_order_release);
        atomic_fetch_add_explicit(&driver->zeroTimeStampSeed, 1, memory_order_acq_rel);
        atomic_store_explicit(&driver->isRunning, 1, memory_order_release);
        pp_notify_device_running(driver);
        pp_log_message("StartIO transitioned the device to running.");
    }
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_StopIO(AudioServerPlugInDriverRef inDriver,
                                                                   AudioObjectID inDeviceObjectID,
                                                                   UInt32 inClientID)
{
    (void)inDeviceObjectID;
    (void)inClientID;
    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    if (!driver) {
        return kAudioHardwareIllegalOperationError;
    }

    UInt32 currentCount = atomic_load_explicit(&driver->ioClientCount, memory_order_acquire);
    while (currentCount > 0 &&
           !atomic_compare_exchange_weak_explicit(&driver->ioClientCount,
                                                  &currentCount,
                                                  currentCount - 1,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire)) {
    }

    if (currentCount == 1) {
        atomic_store_explicit(&driver->isRunning, 0, memory_order_release);
        pp_notify_device_running(driver);
        pp_log_message("StopIO transitioned the device to stopped.");
    }
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                                                             AudioObjectID inDeviceObjectID,
                                                                             UInt32 inClientID,
                                                                             Float64 *outSampleTime,
                                                                             UInt64 *outHostTime,
                                                                             UInt64 *outSeed)
{
    (void)inDeviceObjectID;
    (void)inClientID;
    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    if (!driver || !outSampleTime || !outHostTime || !outSeed) {
        return kAudioHardwareIllegalOperationError;
    }

    UInt64 hostTime = AudioGetCurrentHostTime();
    UInt64 anchorHostTime = atomic_load_explicit(&driver->anchorHostTime, memory_order_acquire);
    Float64 hostFrequency = AudioGetHostClockFrequency();
    Float64 sampleTime = 0.0;

    if (hostFrequency > 0.0 && hostTime >= anchorHostTime) {
        sampleTime = ((Float64)(hostTime - anchorHostTime) / hostFrequency) * driver->sampleRate;
    }

    *outSampleTime = sampleTime;
    *outHostTime = hostTime;
    *outSeed = atomic_load_explicit(&driver->zeroTimeStampSeed, memory_order_acquire);
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                              AudioObjectID inDeviceObjectID,
                                                                              UInt32 inClientID,
                                                                              UInt32 inOperationID,
                                                                              Boolean *outWillDo,
                                                                              Boolean *outWillDoInPlace)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    if (!outWillDo || !outWillDoInPlace) {
        return kAudioHardwareIllegalOperationError;
    }

    Boolean willDo = pp_is_supported_output_operation(inOperationID);
    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    pp_log_will_do_operation(driver, inOperationID, willDo);
    *outWillDo = willDo;
    *outWillDoInPlace = willDo;
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                             AudioObjectID inDeviceObjectID,
                                                                             UInt32 inClientID,
                                                                             UInt32 inOperationID,
                                                                             UInt32 inIOBufferFrameSize,
                                                                             const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDeviceObjectID;
    (void)inClientID;

    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    UInt64 cycleCounter = inIOCycleInfo ? inIOCycleInfo->mIOCycleCounter : 0;
    pp_log_begin_operation(driver, inOperationID, inIOBufferFrameSize, cycleCounter);
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                          AudioObjectID inDeviceObjectID,
                                                                          AudioObjectID inStreamObjectID,
                                                                          UInt32 inClientID,
                                                                          UInt32 inOperationID,
                                                                          UInt32 inIOBufferFrameSize,
                                                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                                                          void *ioMainBuffer,
                                                                          void *ioSecondaryBuffer)
{
    (void)inDeviceObjectID;
    (void)inStreamObjectID;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;

    PodcastPreviewAudioDriverPlugin *driver = pp_driver(inDriver);
    if (!driver) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!pp_is_supported_output_operation(inOperationID)) {
        return kAudioHardwareUnsupportedOperationError;
    }
    void *buffer = ioMainBuffer ? ioMainBuffer : ioSecondaryBuffer;
    if (!buffer) {
        return kAudioHardwareIllegalOperationError;
    }
    if (!driver->writer) {
        return kAudioHardwareNoError;
    }

    UInt64 cycleCounter = inIOCycleInfo ? inIOCycleInfo->mIOCycleCounter : 0;
    pp_log_io_operation(driver, inOperationID, inIOBufferFrameSize, cycleCounter);

    if (cycleCounter != 0) {
        UInt64 previousCycle = atomic_load_explicit(&driver->lastSubmittedCycle, memory_order_acquire);
        if (previousCycle == cycleCounter) {
            return kAudioHardwareNoError;
        }
        atomic_store_explicit(&driver->lastSubmittedCycle, cycleCounter, memory_order_release);
    }

    UInt64 outputStartHostTime = 0;
    double hostTicksPerFrame = 0.0;

    if (inIOCycleInfo) {
        if ((inIOCycleInfo->mOutputTime.mFlags & kAudioTimeStampHostTimeValid) != 0) {
            outputStartHostTime = inIOCycleInfo->mOutputTime.mHostTime;
        } else if ((inIOCycleInfo->mCurrentTime.mFlags & kAudioTimeStampHostTimeValid) != 0) {
            outputStartHostTime = inIOCycleInfo->mCurrentTime.mHostTime;
        }
        hostTicksPerFrame = inIOCycleInfo->mDeviceHostTicksPerFrame;
    }
    if (outputStartHostTime == 0) {
        outputStartHostTime = AudioGetCurrentHostTime();
    }

    PPVirtualLoopbackTransport_WriteInterleavedWithTiming(driver->writer,
                                                          (const float *)buffer,
                                                          inIOBufferFrameSize,
                                                          kPPDriverChannelCount,
                                                          outputStartHostTime,
                                                          hostTicksPerFrame);
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE PodcastPreviewAudioDriver_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                                                           AudioObjectID inDeviceObjectID,
                                                                           UInt32 inClientID,
                                                                           UInt32 inOperationID,
                                                                           UInt32 inIOBufferFrameSize,
                                                                           const AudioServerPlugInIOCycleInfo *inIOCycleInfo)
{
    (void)inDriver;
    (void)inDeviceObjectID;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}
