#include "PodcastPreviewVirtualCameraDriverRuntime.h"

#include <CoreMedia/CMSampleBuffer.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <CoreVideo/CVPixelBufferIOSurface.h>
#include <IOSurface/IOSurfaceRef.h>
#include <os/log.h>
#include <math.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define PPVC_INPUT_DIRECTION 1U
#define PPVC_DEVICE_CAN_BE_DEFAULT 1U
#define PPVC_EXCLUDE_NON_DAL_ACCESS 1U
#define PPVC_TERMINAL_TYPE 0x0200U
#define PPVC_TRANSPORT_TYPE 'virt'
#define PPVC_TIMING_TIMESCALE 600000

typedef enum {
    kPPVCObjectRoleNone = 0,
    kPPVCObjectRolePlugIn,
    kPPVCObjectRoleDevice,
    kPPVCObjectRoleStream
} PPVCObjectRole;

typedef struct {
    bool valid;
    bool hasFrameSequence;
    IOSurfaceID surfaceID;
    UInt32 width;
    UInt32 height;
    Float64 frameRate;
    UInt32 layerCount;
    UInt64 frameSequence;
} PPVCPublishedFrameState;

static PodcastPreviewVirtualCameraDriver *ppvc_driver(CMIOHardwarePlugInRef self)
{
    return (PodcastPreviewVirtualCameraDriver *)self;
}

static os_log_t ppvc_driver_log(void)
{
    static os_log_t logHandle = NULL;
    if (logHandle == NULL) {
        logHandle = os_log_create("com.chrisizatt.PodcastPreviewVirtualCameraDriver", "driver");
    }
    return logHandle;
}

void PPVCRuntime_LogMessage(const char *message)
{
    os_log_with_type(ppvc_driver_log(), OS_LOG_TYPE_DEFAULT, "%{public}s", message != NULL ? message : "(null)");
}

static void ppvc_log_error_status(const char *message, OSStatus status)
{
    os_log_with_type(ppvc_driver_log(), OS_LOG_TYPE_ERROR, "%{public}s (status=%{public}d)", message != NULL ? message : "(null)", (int)status);
}

static void ppvc_reset_stream_state_locked(PodcastPreviewVirtualCameraDriver *driver)
{
    driver->width = PPVC_DEFAULT_WIDTH;
    driver->height = PPVC_DEFAULT_HEIGHT;
    driver->frameRate = PPVC_DEFAULT_FRAME_RATE;
    driver->layerCount = 0;
}

static Float64 ppvc_sanitized_frame_rate(Float64 frameRate)
{
    if (!isfinite(frameRate) || frameRate < PPVC_MIN_FRAME_RATE) {
        return PPVC_DEFAULT_FRAME_RATE;
    }
    if (frameRate > PPVC_MAX_FRAME_RATE) {
        return PPVC_MAX_FRAME_RATE;
    }
    return frameRate;
}

static UInt32 ppvc_stream_count_for_scope(CMIOObjectPropertyScope scope)
{
    switch (scope) {
        case kCMIOObjectPropertyScopeGlobal:
        case kCMIODevicePropertyScopeInput:
        case kCMIOObjectPropertyScopeWildcard:
            return 1;
        default:
            return 0;
    }
}

static size_t ppvc_stream_configuration_size(UInt32 streamCount)
{
    return sizeof(CMIODeviceStreamConfiguration) + (sizeof(UInt32) * streamCount);
}

static bool ppvc_matches_owned_object_qualifier(CMIOClassID classID, UInt32 qualifierDataSize, const void *qualifierData)
{
    if (qualifierData == NULL || qualifierDataSize == 0) {
        return true;
    }

    if ((qualifierDataSize % sizeof(CMIOClassID)) != 0) {
        return false;
    }

    const CMIOClassID *classes = (const CMIOClassID *)qualifierData;
    UInt32 count = qualifierDataSize / (UInt32)sizeof(CMIOClassID);
    for (UInt32 index = 0; index < count; ++index) {
        if (classes[index] == classID || classes[index] == kCMIOObjectClassIDWildcard) {
            return true;
        }
    }

    return false;
}

static PPVCObjectRole ppvc_object_role(const PodcastPreviewVirtualCameraDriver *driver, CMIOObjectID objectID)
{
    if (driver == NULL || objectID == kCMIOObjectUnknown) {
        return kPPVCObjectRoleNone;
    }
    if (objectID == driver->objectID) {
        return kPPVCObjectRolePlugIn;
    }
    if (objectID == driver->deviceObjectID) {
        return kPPVCObjectRoleDevice;
    }
    if (objectID == driver->streamObjectID) {
        return kPPVCObjectRoleStream;
    }
    return kPPVCObjectRoleNone;
}

static CMIOClassID ppvc_class_id_for_role(PPVCObjectRole role)
{
    switch (role) {
        case kPPVCObjectRolePlugIn:
            return kCMIOPlugInClassID;
        case kPPVCObjectRoleDevice:
            return kCMIODeviceClassID;
        case kPPVCObjectRoleStream:
            return kCMIOStreamClassID;
        default:
            return kCMIOObjectClassIDWildcard;
    }
}

static CMIOObjectID ppvc_owner_for_role(const PodcastPreviewVirtualCameraDriver *driver, PPVCObjectRole role)
{
    switch (role) {
        case kPPVCObjectRolePlugIn:
            return kCMIOObjectSystemObject;
        case kPPVCObjectRoleDevice:
            return driver->objectID;
        case kPPVCObjectRoleStream:
            return driver->deviceObjectID;
        default:
            return kCMIOObjectUnknown;
    }
}

static CFStringRef ppvc_name_for_role(PPVCObjectRole role)
{
    switch (role) {
        case kPPVCObjectRolePlugIn:
            return PPVC_PLUGIN_NAME;
        case kPPVCObjectRoleDevice:
            return PPVC_DEVICE_NAME;
        case kPPVCObjectRoleStream:
            return PPVC_STREAM_NAME;
        default:
            return NULL;
    }
}

static Boolean ppvc_common_selector_supported(UInt32 selector)
{
    switch (selector) {
        case kCMIOObjectPropertyClass:
        case kCMIOObjectPropertyOwner:
        case kCMIOObjectPropertyCreator:
        case kCMIOObjectPropertyName:
        case kCMIOObjectPropertyManufacturer:
        case kCMIOObjectPropertyOwnedObjects:
        case kCMIOObjectPropertyListenerAdded:
        case kCMIOObjectPropertyListenerRemoved:
            return true;
        default:
            return false;
    }
}

static Boolean ppvc_device_selector_supported(UInt32 selector)
{
    switch (selector) {
        case kCMIODevicePropertyPlugIn:
        case kCMIODevicePropertyDeviceUID:
        case kCMIODevicePropertyModelUID:
        case kCMIODevicePropertyTransportType:
        case kCMIODevicePropertyDeviceIsAlive:
        case kCMIODevicePropertyDeviceHasChanged:
        case kCMIODevicePropertyDeviceIsRunning:
        case kCMIODevicePropertyDeviceIsRunningSomewhere:
        case kCMIODevicePropertyDeviceCanBeDefaultDevice:
        case kCMIODevicePropertyLatency:
        case kCMIODevicePropertyStreams:
        case kCMIODevicePropertyStreamConfiguration:
        case kCMIODevicePropertyExcludeNonDALAccess:
            return true;
        default:
            return false;
    }
}

static Boolean ppvc_stream_selector_supported(UInt32 selector)
{
    switch (selector) {
        case kCMIOStreamPropertyDirection:
        case kCMIOStreamPropertyTerminalType:
        case kCMIOStreamPropertyStartingChannel:
        case kCMIOStreamPropertyLatency:
        case kCMIOStreamPropertyFormatDescription:
        case kCMIOStreamPropertyFormatDescriptions:
        case kCMIOStreamPropertyFrameRate:
        case kCMIOStreamPropertyMinimumFrameRate:
        case kCMIOStreamPropertyFrameRates:
        case kCMIOStreamPropertyPreferredFormatDescription:
        case kCMIOStreamPropertyPreferredFrameRate:
            return true;
        default:
            return false;
    }
}

static Boolean ppvc_selector_supported_for_role(PPVCObjectRole role, UInt32 selector)
{
    if (ppvc_common_selector_supported(selector)) {
        return true;
    }

    switch (role) {
        case kPPVCObjectRoleDevice:
            return ppvc_device_selector_supported(selector);
        case kPPVCObjectRoleStream:
            return ppvc_stream_selector_supported(selector);
        default:
            return false;
    }
}

static OSStatus ppvc_copy_cf_property(CFTypeRef value, UInt32 dataSize, UInt32 *dataUsed, void *data)
{
    if (value == NULL || data == NULL || dataSize < sizeof(CFTypeRef)) {
        return kCMIOHardwareBadPropertySizeError;
    }

    CFRetain(value);
    *((CFTypeRef *)data) = value;
    if (dataUsed != NULL) {
        *dataUsed = sizeof(CFTypeRef);
    }
    return kCMIOHardwareNoError;
}

static OSStatus ppvc_copy_object_id_property(CMIOObjectID value, UInt32 dataSize, UInt32 *dataUsed, void *data)
{
    if (data == NULL || dataSize < sizeof(CMIOObjectID)) {
        return kCMIOHardwareBadPropertySizeError;
    }

    *((CMIOObjectID *)data) = value;
    if (dataUsed != NULL) {
        *dataUsed = sizeof(CMIOObjectID);
    }
    return kCMIOHardwareNoError;
}

static OSStatus ppvc_copy_u32_property(UInt32 value, UInt32 dataSize, UInt32 *dataUsed, void *data)
{
    if (data == NULL || dataSize < sizeof(UInt32)) {
        return kCMIOHardwareBadPropertySizeError;
    }

    *((UInt32 *)data) = value;
    if (dataUsed != NULL) {
        *dataUsed = sizeof(UInt32);
    }
    return kCMIOHardwareNoError;
}

static OSStatus ppvc_copy_f64_property(Float64 value, UInt32 dataSize, UInt32 *dataUsed, void *data)
{
    if (data == NULL || dataSize < sizeof(Float64)) {
        return kCMIOHardwareBadPropertySizeError;
    }

    *((Float64 *)data) = value;
    if (dataUsed != NULL) {
        *dataUsed = sizeof(Float64);
    }
    return kCMIOHardwareNoError;
}

static OSStatus ppvc_ensure_queue_locked(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver->sampleQueue != NULL) {
        return kCMIOHardwareNoError;
    }

    OSStatus status = CMSimpleQueueCreate(kCFAllocatorDefault, PPVC_QUEUE_CAPACITY, &driver->sampleQueue);
    if (status != kCMIOHardwareNoError) {
        ppvc_log_error_status("Failed to create stream queue.", status);
    }
    return status;
}

static void ppvc_drain_queue_locked(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver->sampleQueue == NULL) {
        return;
    }

    while (CMSimpleQueueGetCount(driver->sampleQueue) > 0) {
        const void *token = CMSimpleQueueDequeue(driver->sampleQueue);
        if (token != NULL) {
            CFRelease((CFTypeRef)token);
        }
    }
}

static OSStatus ppvc_ensure_format_description_locked(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver->width == 0 || driver->height == 0) {
        ppvc_reset_stream_state_locked(driver);
    }

    CMVideoFormatDescriptionRef newDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault,
        kCVPixelFormatType_32BGRA,
        (int32_t)driver->width,
        (int32_t)driver->height,
        NULL,
        &newDescription
    );
    if (status != kCMIOHardwareNoError || newDescription == NULL) {
        ppvc_log_error_status("Failed to create video format description.", status);
        return status != kCMIOHardwareNoError ? status : kCMIOHardwareUnspecifiedError;
    }

    if (driver->formatDescription != NULL) {
        CFRelease(driver->formatDescription);
    }
    driver->formatDescription = newDescription;
    return kCMIOHardwareNoError;
}

static bool ppvc_copy_session_state_path(char *buffer, size_t bufferSize)
{
    if (buffer == NULL || bufferSize == 0) {
        return false;
    }

    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        return false;
    }

    int written = snprintf(buffer, bufferSize, "%s/%s", home, PPVC_SESSION_STATE_RELATIVE_PATH);
    return written > 0 && (size_t)written < bufferSize;
}

static bool ppvc_copy_frame_state_path(char *buffer, size_t bufferSize)
{
    if (buffer == NULL || bufferSize == 0) {
        return false;
    }

    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        return false;
    }

    int written = snprintf(buffer, bufferSize, "%s/%s", home, PPVC_FRAME_STATE_RELATIVE_PATH);
    return written > 0 && (size_t)written < bufferSize;
}

static bool ppvc_cfnumber_to_u32(CFTypeRef value, UInt32 *outValue)
{
    if (value == NULL || outValue == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }

    int64_t parsedValue = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &parsedValue) || parsedValue < 0 || parsedValue > UINT32_MAX) {
        return false;
    }

    *outValue = (UInt32)parsedValue;
    return true;
}

static bool ppvc_cfnumber_to_f64(CFTypeRef value, Float64 *outValue)
{
    if (value == NULL || outValue == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }

    return CFNumberGetValue((CFNumberRef)value, kCFNumberFloat64Type, outValue);
}

static bool ppvc_cfnumber_to_u64(CFTypeRef value, UInt64 *outValue)
{
    if (value == NULL || outValue == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }

    int64_t parsedValue = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &parsedValue) || parsedValue < 0) {
        return false;
    }

    *outValue = (UInt64)parsedValue;
    return true;
}

static bool ppvc_load_published_frame_state_locked(PodcastPreviewVirtualCameraDriver *driver, PPVCPublishedFrameState *frameState)
{
    if (driver == NULL || frameState == NULL) {
        return false;
    }

    frameState->valid = false;
    frameState->hasFrameSequence = false;
    frameState->surfaceID = 0;
    frameState->width = driver->width;
    frameState->height = driver->height;
    frameState->frameRate = driver->frameRate;
    frameState->layerCount = driver->layerCount;
    frameState->frameSequence = 0;

    char path[PATH_MAX];
    if (!ppvc_copy_frame_state_path(path, sizeof(path))) {
        return false;
    }

    struct stat fileInfo;
    if (stat(path, &fileInfo) != 0 || fileInfo.st_size <= 0) {
        return false;
    }

    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return false;
    }

    size_t fileSize = (size_t)fileInfo.st_size;
    UInt8 *bytes = (UInt8 *)malloc(fileSize);
    if (bytes == NULL) {
        fclose(file);
        return false;
    }

    size_t bytesRead = fread(bytes, 1, fileSize, file);
    fclose(file);
    if (bytesRead != fileSize) {
        free(bytes);
        return false;
    }

    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)fileSize);
    free(bytes);
    if (data == NULL) {
        return false;
    }

    CFErrorRef error = NULL;
    CFPropertyListRef propertyList = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, &error);
    CFRelease(data);
    if (propertyList == NULL || CFGetTypeID(propertyList) != CFDictionaryGetTypeID()) {
        if (propertyList != NULL) {
            CFRelease(propertyList);
        }
        if (error != NULL) {
            CFRelease(error);
        }
        return false;
    }

    CFDictionaryRef dictionary = (CFDictionaryRef)propertyList;

    UInt32 parsedSurfaceID = 0;
    UInt32 parsedWidth = frameState->width;
    UInt32 parsedHeight = frameState->height;
    UInt32 parsedLayerCount = frameState->layerCount;
    Float64 parsedFrameRate = frameState->frameRate;
    UInt64 parsedFrameSequence = 0;

    bool hasSurfaceID = ppvc_cfnumber_to_u32(CFDictionaryGetValue(dictionary, CFSTR("surfaceID")), &parsedSurfaceID) && parsedSurfaceID != 0;
    ppvc_cfnumber_to_u32(CFDictionaryGetValue(dictionary, CFSTR("width")), &parsedWidth);
    ppvc_cfnumber_to_u32(CFDictionaryGetValue(dictionary, CFSTR("height")), &parsedHeight);
    ppvc_cfnumber_to_u32(CFDictionaryGetValue(dictionary, CFSTR("layerCount")), &parsedLayerCount);
    if (ppvc_cfnumber_to_f64(CFDictionaryGetValue(dictionary, CFSTR("frameRate")), &parsedFrameRate)) {
        parsedFrameRate = ppvc_sanitized_frame_rate(parsedFrameRate);
    } else {
        parsedFrameRate = frameState->frameRate;
    }
    bool hasFrameSequence = ppvc_cfnumber_to_u64(CFDictionaryGetValue(dictionary, CFSTR("frameSequence")), &parsedFrameSequence);

    CFRelease(propertyList);
    if (error != NULL) {
        CFRelease(error);
    }

    if (!hasSurfaceID || parsedWidth == 0 || parsedHeight == 0) {
        return false;
    }

    driver->width = parsedWidth;
    driver->height = parsedHeight;
    driver->frameRate = parsedFrameRate;
    driver->layerCount = parsedLayerCount;
    ppvc_ensure_format_description_locked(driver);

    frameState->valid = true;
    frameState->hasFrameSequence = hasFrameSequence;
    frameState->surfaceID = parsedSurfaceID;
    frameState->width = parsedWidth;
    frameState->height = parsedHeight;
    frameState->frameRate = parsedFrameRate;
    frameState->layerCount = parsedLayerCount;
    frameState->frameSequence = parsedFrameSequence;
    return true;
}

static void ppvc_load_publisher_state_locked(PodcastPreviewVirtualCameraDriver *driver)
{
    UInt32 width = PPVC_DEFAULT_WIDTH;
    UInt32 height = PPVC_DEFAULT_HEIGHT;
    Float64 frameRate = PPVC_DEFAULT_FRAME_RATE;
    UInt32 layerCount = 0;

    char path[PATH_MAX];
    if (!ppvc_copy_session_state_path(path, sizeof(path))) {
        driver->width = width;
        driver->height = height;
        driver->frameRate = frameRate;
        driver->layerCount = layerCount;
        ppvc_ensure_format_description_locked(driver);
        return;
    }

    struct stat fileInfo;
    if (stat(path, &fileInfo) != 0 || fileInfo.st_size <= 0) {
        driver->width = width;
        driver->height = height;
        driver->frameRate = frameRate;
        driver->layerCount = layerCount;
        ppvc_ensure_format_description_locked(driver);
        return;
    }

    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        driver->width = width;
        driver->height = height;
        driver->frameRate = frameRate;
        driver->layerCount = layerCount;
        ppvc_ensure_format_description_locked(driver);
        return;
    }

    size_t fileSize = (size_t)fileInfo.st_size;
    UInt8 *bytes = (UInt8 *)malloc(fileSize);
    if (bytes == NULL) {
        fclose(file);
        driver->width = width;
        driver->height = height;
        driver->frameRate = frameRate;
        driver->layerCount = layerCount;
        ppvc_ensure_format_description_locked(driver);
        return;
    }

    size_t bytesRead = fread(bytes, 1, fileSize, file);
    fclose(file);
    if (bytesRead != fileSize) {
        free(bytes);
        driver->width = width;
        driver->height = height;
        driver->frameRate = frameRate;
        driver->layerCount = layerCount;
        ppvc_ensure_format_description_locked(driver);
        return;
    }

    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)fileSize);
    free(bytes);
    if (data == NULL) {
        driver->width = width;
        driver->height = height;
        driver->frameRate = frameRate;
        driver->layerCount = layerCount;
        ppvc_ensure_format_description_locked(driver);
        return;
    }

    CFErrorRef error = NULL;
    CFPropertyListRef propertyList = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, &error);
    CFRelease(data);
    if (propertyList == NULL || CFGetTypeID(propertyList) != CFDictionaryGetTypeID()) {
        if (propertyList != NULL) {
            CFRelease(propertyList);
        }
        if (error != NULL) {
            CFRelease(error);
        }
        driver->width = width;
        driver->height = height;
        driver->frameRate = frameRate;
        driver->layerCount = layerCount;
        ppvc_ensure_format_description_locked(driver);
        return;
    }

    CFDictionaryRef dictionary = (CFDictionaryRef)propertyList;

    CFTypeRef resolutionValue = CFDictionaryGetValue(dictionary, CFSTR("resolution"));
    if (resolutionValue != NULL && CFGetTypeID(resolutionValue) == CFStringGetTypeID()) {
        char resolutionBuffer[64];
        if (CFStringGetCString((CFStringRef)resolutionValue, resolutionBuffer, sizeof(resolutionBuffer), kCFStringEncodingUTF8)) {
            unsigned int parsedWidth = 0;
            unsigned int parsedHeight = 0;
            if ((sscanf(resolutionBuffer, "%ux%u", &parsedWidth, &parsedHeight) == 2 || sscanf(resolutionBuffer, "%uX%u", &parsedWidth, &parsedHeight) == 2) && parsedWidth > 0 && parsedHeight > 0) {
                width = parsedWidth;
                height = parsedHeight;
            }
        }
    }

    CFTypeRef frameRateValue = CFDictionaryGetValue(dictionary, CFSTR("frameRate"));
    if (frameRateValue != NULL && CFGetTypeID(frameRateValue) == CFNumberGetTypeID()) {
        Float64 parsedFrameRate = frameRate;
        if (CFNumberGetValue((CFNumberRef)frameRateValue, kCFNumberFloat64Type, &parsedFrameRate)) {
            frameRate = ppvc_sanitized_frame_rate(parsedFrameRate);
        }
    }

    CFTypeRef layersValue = CFDictionaryGetValue(dictionary, CFSTR("layers"));
    if (layersValue != NULL && CFGetTypeID(layersValue) == CFArrayGetTypeID()) {
        CFIndex count = CFArrayGetCount((CFArrayRef)layersValue);
        if (count > 0) {
            layerCount = (UInt32)count;
        }
    }

    CFRelease(propertyList);
    if (error != NULL) {
        CFRelease(error);
    }

    driver->width = width;
    driver->height = height;
    driver->frameRate = ppvc_sanitized_frame_rate(frameRate);
    driver->layerCount = layerCount;
    ppvc_ensure_format_description_locked(driver);
}

static void ppvc_fill_test_pattern(uint8_t *baseAddress, size_t bytesPerRow, UInt32 width, UInt32 height, UInt32 layerCount, UInt64 frameSequence)
{
    if (baseAddress == NULL || width == 0 || height == 0) {
        return;
    }

    uint8_t phase = (uint8_t)(frameSequence & 0xFF);
    uint8_t accent = (uint8_t)((layerCount * 37U) & 0xFF);
    UInt32 safeWidth = width > 1 ? width - 1 : 1;
    UInt32 safeHeight = height > 1 ? height - 1 : 1;

    for (UInt32 y = 0; y < height; ++y) {
        uint8_t *row = baseAddress + (bytesPerRow * y);
        uint8_t green = (uint8_t)((255U * y) / safeHeight);
        uint8_t movingBand = (((y / 32U) + (UInt32)(frameSequence / 4U)) % 2U) == 0U ? 32U : 0U;

        for (UInt32 x = 0; x < width; ++x) {
            size_t pixelOffset = (size_t)x * 4U;
            uint8_t blue = (uint8_t)(((255U * x) / safeWidth) ^ phase);
            uint8_t red = (uint8_t)((((x / 24U) * 19U) + ((y / 24U) * 11U) + accent + (phase * 2U)) & 0xFFU);
            row[pixelOffset + 0] = blue;
            row[pixelOffset + 1] = (uint8_t)((green + movingBand) & 0xFFU);
            row[pixelOffset + 2] = red;
            row[pixelOffset + 3] = 255U;
        }
    }

    UInt32 bannerHeight = height < 80U ? height : 80U;
    uint8_t bannerRed = (uint8_t)((64U + (layerCount * 23U)) & 0xFFU);
    uint8_t bannerGreen = (uint8_t)((32U + (layerCount * 41U)) & 0xFFU);
    for (UInt32 y = 0; y < bannerHeight; ++y) {
        uint8_t *row = baseAddress + (bytesPerRow * y);
        for (UInt32 x = 0; x < width; ++x) {
            size_t pixelOffset = (size_t)x * 4U;
            row[pixelOffset + 0] = (uint8_t)(phase + (x % 64U));
            row[pixelOffset + 1] = bannerGreen;
            row[pixelOffset + 2] = bannerRed;
            row[pixelOffset + 3] = 255U;
        }
    }
}

static OSStatus ppvc_create_sample_buffer(UInt32 width,
                                          UInt32 height,
                                          Float64 frameRate,
                                          UInt32 layerCount,
                                          UInt64 frameSequence,
                                          CMVideoFormatDescriptionRef formatDescription,
                                          CMSampleBufferRef *sampleBufferOut)
{
    if (formatDescription == NULL || sampleBufferOut == NULL) {
        return kCMIOHardwareIllegalOperationError;
    }

    *sampleBufferOut = NULL;

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn pixelStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        NULL,
        &pixelBuffer
    );
    if (pixelStatus != kCVReturnSuccess || pixelBuffer == NULL) {
        return kCMIOHardwareUnspecifiedError;
    }

    pixelStatus = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (pixelStatus != kCVReturnSuccess) {
        CFRelease(pixelBuffer);
        return kCMIOHardwareUnspecifiedError;
    }

    uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    ppvc_fill_test_pattern(baseAddress, bytesPerRow, width, height, layerCount, frameSequence);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    Float64 sanitizedFrameRate = ppvc_sanitized_frame_rate(frameRate);
    CMSampleTimingInfo timing = {
        .duration = CMTimeMakeWithSeconds(1.0 / sanitizedFrameRate, PPVC_TIMING_TIMESCALE),
        .presentationTimeStamp = CMTimeMakeWithSeconds(((Float64)frameSequence) / sanitizedFrameRate, PPVC_TIMING_TIMESCALE),
        .decodeTimeStamp = kCMTimeInvalid
    };

    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        formatDescription,
        &timing,
        sampleBufferOut
    );
    CFRelease(pixelBuffer);
    return status;
}

static OSStatus ppvc_create_sample_buffer_from_surface(IOSurfaceID surfaceID,
                                                       Float64 frameRate,
                                                       UInt64 frameSequence,
                                                       CMVideoFormatDescriptionRef formatDescription,
                                                       CMSampleBufferRef *sampleBufferOut)
{
    if (surfaceID == 0 || formatDescription == NULL || sampleBufferOut == NULL) {
        return kCMIOHardwareIllegalOperationError;
    }

    *sampleBufferOut = NULL;

    IOSurfaceRef surface = IOSurfaceLookup(surfaceID);
    if (surface == NULL) {
        return kCMIOHardwareUnspecifiedError;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn pixelStatus = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault,
        surface,
        NULL,
        &pixelBuffer
    );
    CFRelease(surface);
    if (pixelStatus != kCVReturnSuccess || pixelBuffer == NULL) {
        return kCMIOHardwareUnspecifiedError;
    }

    Float64 sanitizedFrameRate = ppvc_sanitized_frame_rate(frameRate);
    CMSampleTimingInfo timing = {
        .duration = CMTimeMakeWithSeconds(1.0 / sanitizedFrameRate, PPVC_TIMING_TIMESCALE),
        .presentationTimeStamp = CMTimeMakeWithSeconds(((Float64)frameSequence) / sanitizedFrameRate, PPVC_TIMING_TIMESCALE),
        .decodeTimeStamp = kCMTimeInvalid
    };

    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        formatDescription,
        &timing,
        sampleBufferOut
    );
    CFRelease(pixelBuffer);
    return status;
}

static void ppvc_mkdir_recursive(const char *path)
{
    char tmp[PATH_MAX];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp), "%s", path);
    len = strlen(tmp);
    if (len == 0) return;
    if (tmp[len - 1] == '/') tmp[len - 1] = 0;
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, S_IRWXU | S_IRWXG | S_IROTH | S_IXOTH);
            *p = '/';
        }
    }
    mkdir(tmp, S_IRWXU | S_IRWXG | S_IROTH | S_IXOTH);
}

static void ppvc_set_cf_string(CFMutableDictionaryRef dict, CFStringRef key, const char *value)
{
    if (value == NULL) return;
    CFStringRef cfValue = CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
    if (cfValue) {
        CFDictionarySetValue(dict, key, cfValue);
        CFRelease(cfValue);
    }
}

static void ppvc_set_cf_number_s32(CFMutableDictionaryRef dict, CFStringRef key, SInt32 value)
{
    CFNumberRef cfValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (cfValue) {
        CFDictionarySetValue(dict, key, cfValue);
        CFRelease(cfValue);
    }
}

static void ppvc_set_cf_number_s64(CFMutableDictionaryRef dict, CFStringRef key, SInt64 value)
{
    CFNumberRef cfValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    if (cfValue) {
        CFDictionarySetValue(dict, key, cfValue);
        CFRelease(cfValue);
    }
}

static void ppvc_set_cf_number_f64(CFMutableDictionaryRef dict, CFStringRef key, Float64 value)
{
    CFNumberRef cfValue = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &value);
    if (cfValue) {
        CFDictionarySetValue(dict, key, cfValue);
        CFRelease(cfValue);
    }
}

static void ppvc_set_cf_boolean(CFMutableDictionaryRef dict, CFStringRef key, bool value)
{
    CFDictionarySetValue(dict, key, value ? kCFBooleanTrue : kCFBooleanFalse);
}

static void ppvc_write_runtime_status_locked(PodcastPreviewVirtualCameraDriver *driver,
                                             bool force,
                                             bool usedPublishedSurface,
                                             bool usedFallbackFrame,
                                             bool hasPublishedFrameSequence,
                                             UInt64 publishedFrameSequence,
                                             UInt64 driverFrameSequence)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!force && (now - driver->lastRuntimeStatusWriteTime) < 0.25) {
        return;
    }
    driver->lastRuntimeStatusWriteTime = now;

    char path[PATH_MAX];
    if (!ppvc_copy_session_state_path(path, sizeof(path))) { // Reuse session path to get base dir
        return;
    }
    // Get directory of path
    char *dir = strdup(path);
    char *last_slash = strrchr(dir, '/');
    if (last_slash) *last_slash = 0;
    ppvc_mkdir_recursive(dir);
    free(dir);

    if (!ppvc_copy_frame_state_path(path, sizeof(path))) { // Wait, I need the runtime-status path
         // Actually let's just build it
         const char *home = getenv("HOME");
         if (home == NULL) return;
         snprintf(path, sizeof(path), "%s/%s", home, PPVC_RUNTIME_STATUS_RELATIVE_PATH);
    }

    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (dict == NULL) return;

    UInt32 startCount = atomic_load_explicit(&driver->startCount, memory_order_acquire);
    const char *state = "idle";
    if (startCount > 0) {
        state = driver->suspended ? "suspended" : "running";
    }

    ppvc_set_cf_string(dict, CFSTR("state"), state);
    ppvc_set_cf_number_f64(dict, CFSTR("updatedAt"), now + kCFAbsoluteTimeIntervalSince1970);
    ppvc_set_cf_number_s32(dict, CFSTR("startCount"), (SInt32)startCount);
    ppvc_set_cf_boolean(dict, CFSTR("suspended"), driver->suspended);
    ppvc_set_cf_boolean(dict, CFSTR("usingPublishedFrames"), usedPublishedSurface);
    ppvc_set_cf_boolean(dict, CFSTR("fallbackActive"), usedFallbackFrame);
    ppvc_set_cf_number_s64(dict, CFSTR("driverFrameSequence"), (SInt64)driverFrameSequence);

    if (hasPublishedFrameSequence) {
        ppvc_set_cf_number_s64(dict, CFSTR("lastConsumedPublisherFrameSequence"), (SInt64)publishedFrameSequence);
    }

    ppvc_set_cf_number_s32(dict, CFSTR("width"), (SInt32)driver->width);
    ppvc_set_cf_number_s32(dict, CFSTR("height"), (SInt32)driver->height);
    ppvc_set_cf_number_f64(dict, CFSTR("frameRate"), driver->frameRate);
    ppvc_set_cf_number_s32(dict, CFSTR("layerCount"), (SInt32)driver->layerCount);

    CFErrorRef error = NULL;
    CFDataRef data = CFPropertyListCreateData(kCFAllocatorDefault, dict, kCFPropertyListBinaryFormat_v1_0, 0, &error);
    CFRelease(dict);

    if (data) {
        FILE *file = fopen(path, "wb");
        if (file) {
            fwrite(CFDataGetBytePtr(data), 1, CFDataGetLength(data), file);
            fclose(file);
        }
        CFRelease(data);
    }
    if (error) CFRelease(error);
}

static void ppvc_sleep_for_frame_interval(Float64 frameRate)
{
    Float64 sanitizedFrameRate = ppvc_sanitized_frame_rate(frameRate);
    Float64 seconds = 1.0 / sanitizedFrameRate;
    struct timespec interval;
    interval.tv_sec = (time_t)seconds;
    interval.tv_nsec = (long)((seconds - (Float64)interval.tv_sec) * 1000000000.0);
    if (interval.tv_nsec < 0) {
        interval.tv_nsec = 0;
    }
    nanosleep(&interval, NULL);
}

static void *ppvc_frame_thread_main(void *context)
{
    PodcastPreviewVirtualCameraDriver *driver = (PodcastPreviewVirtualCameraDriver *)context;
    if (driver == NULL) {
        return NULL;
    }

    while (atomic_load_explicit(&driver->frameThreadShouldRun, memory_order_acquire)) {
        CMSimpleQueueRef queue = NULL;
        CMVideoFormatDescriptionRef formatDescription = NULL;
        CMIODeviceStreamQueueAlteredProc queueAlteredProc = NULL;
        void *queueAlteredRefCon = NULL;
        CMIOStreamID streamID = kCMIOStreamUnknown;
        PPVCPublishedFrameState publishedFrame = {0};
        UInt32 width = 0;
        UInt32 height = 0;
        UInt32 layerCount = 0;
        UInt64 frameSequence = 0;
        Float64 frameRate = PPVC_DEFAULT_FRAME_RATE;
        bool shouldProduce = false;
        bool usedPublishedSurface = false;
        bool usedFallbackFrame = false;
        bool hasPublishedFrameSequence = false;
        UInt64 publishedFrameSequence = 0;

        pthread_mutex_lock(&driver->stateMutex);
        shouldProduce = !driver->suspended && atomic_load_explicit(&driver->startCount, memory_order_acquire) > 0 && driver->sampleQueue != NULL;
        if (shouldProduce) {
            ppvc_load_published_frame_state_locked(driver, &publishedFrame);
            if (driver->formatDescription == NULL) {
                ppvc_ensure_format_description_locked(driver);
            }
            shouldProduce = (driver->sampleQueue != NULL && driver->formatDescription != NULL);
        }
        if (shouldProduce) {
            queue = driver->sampleQueue;
            formatDescription = driver->formatDescription;
            CFRetain(queue);
            CFRetain(formatDescription);
            queueAlteredProc = driver->queueAlteredProc;
            queueAlteredRefCon = driver->queueAlteredRefCon;
            streamID = driver->streamObjectID;
            width = driver->width;
            height = driver->height;
            layerCount = publishedFrame.valid ? publishedFrame.layerCount : driver->layerCount;
            frameRate = publishedFrame.valid ? publishedFrame.frameRate : driver->frameRate;
            frameSequence = driver->frameSequence;
            driver->frameSequence += 1;
            hasPublishedFrameSequence = publishedFrame.hasFrameSequence;
            publishedFrameSequence = publishedFrame.frameSequence;
        }
        pthread_mutex_unlock(&driver->stateMutex);

        if (!shouldProduce) {
            ppvc_sleep_for_frame_interval(PPVC_DEFAULT_FRAME_RATE);
            continue;
        }

        CMSampleBufferRef sampleBuffer = NULL;
        OSStatus status = kCMIOHardwareUnspecifiedError;
        if (publishedFrame.valid) {
            status = ppvc_create_sample_buffer_from_surface(publishedFrame.surfaceID, frameRate, frameSequence, formatDescription, &sampleBuffer);
            usedPublishedSurface = (status == kCMIOHardwareNoError && sampleBuffer != NULL);
        }
        if (status != kCMIOHardwareNoError || sampleBuffer == NULL) {
            status = ppvc_create_sample_buffer(width, height, frameRate, layerCount, frameSequence, formatDescription, &sampleBuffer);
            usedFallbackFrame = (status == kCMIOHardwareNoError && sampleBuffer != NULL);
        }
        CFRelease(formatDescription);
        if (status != kCMIOHardwareNoError || sampleBuffer == NULL) {
            if (queue != NULL) {
                CFRelease(queue);
            }
            ppvc_sleep_for_frame_interval(frameRate);
            continue;
        }

        bool enqueued = false;
        pthread_mutex_lock(&driver->stateMutex);
        if (driver->sampleQueue == queue && !driver->suspended && atomic_load_explicit(&driver->startCount, memory_order_acquire) > 0) {
            while (CMSimpleQueueGetCount(driver->sampleQueue) >= PPVC_QUEUE_CAPACITY) {
                const void *token = CMSimpleQueueDequeue(driver->sampleQueue);
                if (token != NULL) {
                    CFRelease((CFTypeRef)token);
                }
            }

            OSStatus enqueueStatus = CMSimpleQueueEnqueue(driver->sampleQueue, sampleBuffer);
            if (enqueueStatus == kCMSimpleQueueError_QueueIsFull) {
                const void *token = CMSimpleQueueDequeue(driver->sampleQueue);
                if (token != NULL) {
                    CFRelease((CFTypeRef)token);
                }
                enqueueStatus = CMSimpleQueueEnqueue(driver->sampleQueue, sampleBuffer);
            }
            enqueued = (enqueueStatus == kCMIOHardwareNoError);
        }
        pthread_mutex_unlock(&driver->stateMutex);

        if (queue != NULL) {
            CFRelease(queue);
        }

        if (enqueued) {
            if (queueAlteredProc != NULL) {
                queueAlteredProc(streamID, sampleBuffer, queueAlteredRefCon);
            }
        } else {
            CFRelease(sampleBuffer);
        }

        ppvc_write_runtime_status_locked(
            driver,
            false,
            usedPublishedSurface,
            usedFallbackFrame,
            hasPublishedFrameSequence,
            publishedFrameSequence,
            frameSequence
        );

        ppvc_sleep_for_frame_interval(frameRate);
    }

    return NULL;
}

static OSStatus ppvc_start_frame_thread(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver->frameThreadCreated) {
        atomic_store_explicit(&driver->frameThreadShouldRun, true, memory_order_release);
        return kCMIOHardwareNoError;
    }

    atomic_store_explicit(&driver->frameThreadShouldRun, true, memory_order_release);
    int pthreadStatus = pthread_create(&driver->frameThread, NULL, ppvc_frame_thread_main, driver);
    if (pthreadStatus != 0) {
        atomic_store_explicit(&driver->frameThreadShouldRun, false, memory_order_release);
        return kCMIOHardwareUnspecifiedError;
    }

    driver->frameThreadCreated = true;
    return kCMIOHardwareNoError;
}

static void ppvc_stop_frame_thread(PodcastPreviewVirtualCameraDriver *driver)
{
    atomic_store_explicit(&driver->frameThreadShouldRun, false, memory_order_release);
    if (driver->frameThreadCreated) {
        pthread_join(driver->frameThread, NULL);
        driver->frameThreadCreated = false;
    }
}

static OSStatus ppvc_publish_objects(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver == NULL || driver->objectID == kCMIOObjectUnknown) {
        return kCMIOHardwareBadObjectError;
    }

    pthread_mutex_lock(&driver->stateMutex);
    ppvc_load_publisher_state_locked(driver);
    OSStatus status = ppvc_ensure_queue_locked(driver);
    pthread_mutex_unlock(&driver->stateMutex);
    if (status != kCMIOHardwareNoError) {
        return status;
    }

    if (driver->deviceObjectID == kCMIODeviceUnknown) {
        status = CMIOObjectCreate((CMIOHardwarePlugInRef)driver, driver->objectID, kCMIODeviceClassID, &driver->deviceObjectID);
        if (status != kCMIOHardwareNoError) {
            ppvc_log_error_status("Failed to create virtual camera device object.", status);
            return status;
        }
    }

    if (!driver->devicePublished) {
        CMIOObjectID publishedDevice = driver->deviceObjectID;
        status = CMIOObjectsPublishedAndDied((CMIOHardwarePlugInRef)driver, driver->objectID, 1, &publishedDevice, 0, NULL);
        if (status != kCMIOHardwareNoError) {
            ppvc_log_error_status("Failed to publish virtual camera device object.", status);
            return status;
        }
        driver->devicePublished = true;
    }

    if (driver->streamObjectID == kCMIOStreamUnknown) {
        status = CMIOObjectCreate((CMIOHardwarePlugInRef)driver, driver->deviceObjectID, kCMIOStreamClassID, &driver->streamObjectID);
        if (status != kCMIOHardwareNoError) {
            ppvc_log_error_status("Failed to create virtual camera stream object.", status);
            return status;
        }
    }

    if (!driver->streamPublished) {
        CMIOObjectID publishedStream = driver->streamObjectID;
        status = CMIOObjectsPublishedAndDied((CMIOHardwarePlugInRef)driver, driver->deviceObjectID, 1, &publishedStream, 0, NULL);
        if (status != kCMIOHardwareNoError) {
            ppvc_log_error_status("Failed to publish virtual camera stream object.", status);
            return status;
        }
        driver->streamPublished = true;
    }

    return kCMIOHardwareNoError;
}

static void ppvc_unpublish_objects(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver == NULL) {
        return;
    }

    if (driver->streamPublished && driver->streamObjectID != kCMIOStreamUnknown && driver->deviceObjectID != kCMIODeviceUnknown) {
        CMIOObjectID deadStream = driver->streamObjectID;
        CMIOObjectsPublishedAndDied((CMIOHardwarePlugInRef)driver, driver->deviceObjectID, 0, NULL, 1, &deadStream);
    }
    driver->streamPublished = false;
    driver->streamObjectID = kCMIOStreamUnknown;

    if (driver->devicePublished && driver->deviceObjectID != kCMIODeviceUnknown && driver->objectID != kCMIOObjectUnknown) {
        CMIOObjectID deadDevice = driver->deviceObjectID;
        CMIOObjectsPublishedAndDied((CMIOHardwarePlugInRef)driver, driver->objectID, 0, NULL, 1, &deadDevice);
    }
    driver->devicePublished = false;
    driver->deviceObjectID = kCMIODeviceUnknown;
}

void PPVCRuntime_InitializeDriverState(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver == NULL) {
        return;
    }

    driver->objectID = kCMIOObjectUnknown;
    driver->deviceObjectID = kCMIODeviceUnknown;
    driver->streamObjectID = kCMIOStreamUnknown;
    driver->devicePublished = false;
    driver->streamPublished = false;
    driver->sampleQueue = NULL;
    driver->formatDescription = NULL;
    driver->queueAlteredProc = NULL;
    driver->queueAlteredRefCon = NULL;
    pthread_mutex_init(&driver->stateMutex, NULL);
    driver->frameThreadCreated = false;
    atomic_store_explicit(&driver->frameThreadShouldRun, false, memory_order_release);
    atomic_store_explicit(&driver->startCount, 0, memory_order_release);
    driver->suspended = false;
    driver->frameSequence = 0;
    driver->lastRuntimeStatusWriteTime = 0;
    ppvc_reset_stream_state_locked(driver);
}

void PPVCRuntime_DestroyDriverState(PodcastPreviewVirtualCameraDriver *driver)
{
    if (driver == NULL) {
        return;
    }

    PPVCRuntime_Teardown((CMIOHardwarePlugInRef)driver);
    pthread_mutex_destroy(&driver->stateMutex);
}

OSStatus PPVCRuntime_Initialize(CMIOHardwarePlugInRef self)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL) {
        return kCMIOHardwareBadObjectError;
    }

    PPVCRuntime_LogMessage("Initialize called for virtual camera DAL driver.");
    return kCMIOHardwareNoError;
}

OSStatus PPVCRuntime_InitializeWithObjectID(CMIOHardwarePlugInRef self, CMIOObjectID objectID)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL) {
        return kCMIOHardwareBadObjectError;
    }

    driver->objectID = objectID;
    PPVCRuntime_LogMessage("InitializeWithObjectID assigned DAL plug-in object ID.");
    return ppvc_publish_objects(driver);
}

OSStatus PPVCRuntime_Teardown(CMIOHardwarePlugInRef self)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL) {
        return kCMIOHardwareBadObjectError;
    }

    ppvc_stop_frame_thread(driver);
    pthread_mutex_lock(&driver->stateMutex);
    atomic_store_explicit(&driver->startCount, 0, memory_order_release);
    driver->queueAlteredProc = NULL;
    driver->queueAlteredRefCon = NULL;
    ppvc_drain_queue_locked(driver);
    if (driver->sampleQueue != NULL) {
        CFRelease(driver->sampleQueue);
        driver->sampleQueue = NULL;
    }
    if (driver->formatDescription != NULL) {
        CFRelease(driver->formatDescription);
        driver->formatDescription = NULL;
    }
    ppvc_reset_stream_state_locked(driver);
    ppvc_write_runtime_status_locked(driver, true, false, false, false, 0, driver->frameSequence);
    pthread_mutex_unlock(&driver->stateMutex);
    ppvc_unpublish_objects(driver);
    driver->objectID = kCMIOObjectUnknown;
    PPVCRuntime_LogMessage("Teardown called for virtual camera DAL driver.");
    return kCMIOHardwareNoError;
}

void PPVCRuntime_ObjectShow(CMIOHardwarePlugInRef self, CMIOObjectID objectID)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL) {
        return;
    }

    os_log_with_type(ppvc_driver_log(), OS_LOG_TYPE_DEFAULT, "ObjectShow for object %{public}u (plug-in=%{public}u, device=%{public}u, stream=%{public}u)", (unsigned int)objectID, (unsigned int)driver->objectID, (unsigned int)driver->deviceObjectID, (unsigned int)driver->streamObjectID);
}

Boolean PPVCRuntime_ObjectHasProperty(CMIOHardwarePlugInRef self, CMIOObjectID objectID, const CMIOObjectPropertyAddress *address)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || address == NULL) {
        return false;
    }

    PPVCObjectRole role = ppvc_object_role(driver, objectID);
    return role != kPPVCObjectRoleNone && ppvc_selector_supported_for_role(role, address->mSelector);
}

OSStatus PPVCRuntime_ObjectIsPropertySettable(CMIOHardwarePlugInRef self, CMIOObjectID objectID, const CMIOObjectPropertyAddress *address, Boolean *isSettable)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || address == NULL || isSettable == NULL) {
        return kCMIOHardwareIllegalOperationError;
    }

    PPVCObjectRole role = ppvc_object_role(driver, objectID);
    if (role == kPPVCObjectRoleNone || !ppvc_selector_supported_for_role(role, address->mSelector)) {
        return kCMIOHardwareUnknownPropertyError;
    }

    *isSettable = (address->mSelector == kCMIOObjectPropertyListenerAdded || address->mSelector == kCMIOObjectPropertyListenerRemoved);
    return kCMIOHardwareNoError;
}

OSStatus PPVCRuntime_ObjectGetPropertyDataSize(CMIOHardwarePlugInRef self,
                                               CMIOObjectID objectID,
                                               const CMIOObjectPropertyAddress *address,
                                               UInt32 qualifierDataSize,
                                               const void *qualifierData,
                                               UInt32 *dataSize)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || address == NULL || dataSize == NULL) {
        return kCMIOHardwareIllegalOperationError;
    }

    PPVCObjectRole role = ppvc_object_role(driver, objectID);
    if (role == kPPVCObjectRoleNone || !ppvc_selector_supported_for_role(role, address->mSelector)) {
        return kCMIOHardwareUnknownPropertyError;
    }

    switch (address->mSelector) {
        case kCMIOObjectPropertyClass:
            *dataSize = sizeof(CMIOClassID);
            return kCMIOHardwareNoError;
        case kCMIOObjectPropertyOwner:
            *dataSize = sizeof(CMIOObjectID);
            return kCMIOHardwareNoError;
        case kCMIOObjectPropertyCreator:
        case kCMIOObjectPropertyName:
        case kCMIOObjectPropertyManufacturer:
            *dataSize = sizeof(CFStringRef);
            return kCMIOHardwareNoError;
        case kCMIOObjectPropertyOwnedObjects: {
            UInt32 ownedCount = 0;
            if (role == kPPVCObjectRolePlugIn && driver->deviceObjectID != kCMIODeviceUnknown && ppvc_matches_owned_object_qualifier(kCMIODeviceClassID, qualifierDataSize, qualifierData)) {
                ownedCount = 1;
            } else if (role == kPPVCObjectRoleDevice && driver->streamObjectID != kCMIOStreamUnknown && ppvc_matches_owned_object_qualifier(kCMIOStreamClassID, qualifierDataSize, qualifierData)) {
                ownedCount = 1;
            }
            *dataSize = ownedCount * sizeof(CMIOObjectID);
            return kCMIOHardwareNoError;
        }
        case kCMIOObjectPropertyListenerAdded:
        case kCMIOObjectPropertyListenerRemoved:
            *dataSize = sizeof(CMIOObjectPropertyAddress);
            return kCMIOHardwareNoError;
        case kCMIODevicePropertyPlugIn:
            *dataSize = sizeof(CMIOObjectID);
            return kCMIOHardwareNoError;
        case kCMIODevicePropertyDeviceUID:
        case kCMIODevicePropertyModelUID:
            *dataSize = sizeof(CFStringRef);
            return kCMIOHardwareNoError;
        case kCMIODevicePropertyTransportType:
        case kCMIODevicePropertyDeviceIsAlive:
        case kCMIODevicePropertyDeviceHasChanged:
        case kCMIODevicePropertyDeviceIsRunning:
        case kCMIODevicePropertyDeviceIsRunningSomewhere:
        case kCMIODevicePropertyDeviceCanBeDefaultDevice:
        case kCMIODevicePropertyLatency:
        case kCMIODevicePropertyExcludeNonDALAccess:
            *dataSize = sizeof(UInt32);
            return kCMIOHardwareNoError;
        case kCMIODevicePropertyStreams:
            *dataSize = ppvc_stream_count_for_scope(address->mScope) * sizeof(CMIOStreamID);
            return kCMIOHardwareNoError;
        case kCMIODevicePropertyStreamConfiguration:
            *dataSize = (UInt32)ppvc_stream_configuration_size(ppvc_stream_count_for_scope(address->mScope));
            return kCMIOHardwareNoError;
        case kCMIOStreamPropertyDirection:
        case kCMIOStreamPropertyTerminalType:
        case kCMIOStreamPropertyStartingChannel:
            *dataSize = sizeof(UInt32);
            return kCMIOHardwareNoError;
        case kCMIOStreamPropertyFormatDescription:
        case kCMIOStreamPropertyPreferredFormatDescription:
            *dataSize = sizeof(CMFormatDescriptionRef);
            return kCMIOHardwareNoError;
        case kCMIOStreamPropertyFormatDescriptions:
            *dataSize = sizeof(CFArrayRef);
            return kCMIOHardwareNoError;
        case kCMIOStreamPropertyFrameRate:
        case kCMIOStreamPropertyMinimumFrameRate:
        case kCMIOStreamPropertyPreferredFrameRate:
            *dataSize = sizeof(Float64);
            return kCMIOHardwareNoError;
        case kCMIOStreamPropertyFrameRates:
            *dataSize = sizeof(Float64);
            return kCMIOHardwareNoError;
        default:
            return kCMIOHardwareUnknownPropertyError;
    }
}

OSStatus PPVCRuntime_ObjectGetPropertyData(CMIOHardwarePlugInRef self,
                                           CMIOObjectID objectID,
                                           const CMIOObjectPropertyAddress *address,
                                           UInt32 qualifierDataSize,
                                           const void *qualifierData,
                                           UInt32 dataSize,
                                           UInt32 *dataUsed,
                                           void *data)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || address == NULL) {
        return kCMIOHardwareIllegalOperationError;
    }

    if (dataUsed != NULL) {
        *dataUsed = 0;
    }

    PPVCObjectRole role = ppvc_object_role(driver, objectID);
    if (role == kPPVCObjectRoleNone || !ppvc_selector_supported_for_role(role, address->mSelector)) {
        return kCMIOHardwareUnknownPropertyError;
    }

    switch (address->mSelector) {
        case kCMIOObjectPropertyClass:
            return ppvc_copy_u32_property(ppvc_class_id_for_role(role), dataSize, dataUsed, data);
        case kCMIOObjectPropertyOwner:
            return ppvc_copy_object_id_property(ppvc_owner_for_role(driver, role), dataSize, dataUsed, data);
        case kCMIOObjectPropertyCreator:
            return ppvc_copy_cf_property(PPVC_DRIVER_BUNDLE_ID, dataSize, dataUsed, data);
        case kCMIOObjectPropertyName:
            return ppvc_copy_cf_property(ppvc_name_for_role(role), dataSize, dataUsed, data);
        case kCMIOObjectPropertyManufacturer:
            return ppvc_copy_cf_property(PPVC_DRIVER_MANUFACTURER, dataSize, dataUsed, data);
        case kCMIOObjectPropertyOwnedObjects: {
            CMIOObjectID ownedObjects[1];
            UInt32 ownedCount = 0;
            if (role == kPPVCObjectRolePlugIn && driver->deviceObjectID != kCMIODeviceUnknown && ppvc_matches_owned_object_qualifier(kCMIODeviceClassID, qualifierDataSize, qualifierData)) {
                ownedObjects[ownedCount++] = driver->deviceObjectID;
            } else if (role == kPPVCObjectRoleDevice && driver->streamObjectID != kCMIOStreamUnknown && ppvc_matches_owned_object_qualifier(kCMIOStreamClassID, qualifierDataSize, qualifierData)) {
                ownedObjects[ownedCount++] = driver->streamObjectID;
            }

            UInt32 requiredSize = ownedCount * sizeof(CMIOObjectID);
            if (data == NULL || dataSize < requiredSize) {
                return requiredSize == 0 ? kCMIOHardwareNoError : kCMIOHardwareBadPropertySizeError;
            }
            if (ownedCount > 0) {
                memcpy(data, ownedObjects, requiredSize);
            }
            if (dataUsed != NULL) {
                *dataUsed = requiredSize;
            }
            return kCMIOHardwareNoError;
        }
        case kCMIOObjectPropertyListenerAdded:
        case kCMIOObjectPropertyListenerRemoved:
            if (data == NULL || dataSize < sizeof(CMIOObjectPropertyAddress)) {
                return kCMIOHardwareBadPropertySizeError;
            }
            memset(data, 0, sizeof(CMIOObjectPropertyAddress));
            if (dataUsed != NULL) {
                *dataUsed = sizeof(CMIOObjectPropertyAddress);
            }
            return kCMIOHardwareNoError;
        case kCMIODevicePropertyPlugIn:
            return ppvc_copy_object_id_property(driver->objectID, dataSize, dataUsed, data);
        case kCMIODevicePropertyDeviceUID:
            return ppvc_copy_cf_property(PPVC_DEVICE_UID, dataSize, dataUsed, data);
        case kCMIODevicePropertyModelUID:
            return ppvc_copy_cf_property(PPVC_MODEL_UID, dataSize, dataUsed, data);
        case kCMIODevicePropertyTransportType:
            return ppvc_copy_u32_property(PPVC_TRANSPORT_TYPE, dataSize, dataUsed, data);
        case kCMIODevicePropertyDeviceIsAlive:
            return ppvc_copy_u32_property(1U, dataSize, dataUsed, data);
        case kCMIODevicePropertyDeviceHasChanged:
            return ppvc_copy_u32_property(0U, dataSize, dataUsed, data);
        case kCMIODevicePropertyDeviceIsRunning:
        case kCMIODevicePropertyDeviceIsRunningSomewhere: {
            UInt32 running = atomic_load_explicit(&driver->startCount, memory_order_acquire) > 0 ? 1U : 0U;
            return ppvc_copy_u32_property(running, dataSize, dataUsed, data);
        }
        case kCMIODevicePropertyDeviceCanBeDefaultDevice:
            return ppvc_copy_u32_property(PPVC_DEVICE_CAN_BE_DEFAULT, dataSize, dataUsed, data);
        case kCMIODevicePropertyLatency:
            return ppvc_copy_u32_property(0U, dataSize, dataUsed, data);
        case kCMIODevicePropertyStreams: {
            UInt32 streamCount = ppvc_stream_count_for_scope(address->mScope);
            UInt32 requiredSize = streamCount * sizeof(CMIOStreamID);
            if (data == NULL || dataSize < requiredSize) {
                return requiredSize == 0 ? kCMIOHardwareNoError : kCMIOHardwareBadPropertySizeError;
            }
            if (streamCount > 0) {
                ((CMIOStreamID *)data)[0] = driver->streamObjectID;
            }
            if (dataUsed != NULL) {
                *dataUsed = requiredSize;
            }
            return kCMIOHardwareNoError;
        }
        case kCMIODevicePropertyStreamConfiguration: {
            UInt32 streamCount = ppvc_stream_count_for_scope(address->mScope);
            UInt32 requiredSize = (UInt32)ppvc_stream_configuration_size(streamCount);
            if (data == NULL || dataSize < requiredSize) {
                return kCMIOHardwareBadPropertySizeError;
            }
            CMIODeviceStreamConfiguration *configuration = (CMIODeviceStreamConfiguration *)data;
            configuration->mNumberStreams = streamCount;
            for (UInt32 index = 0; index < streamCount; ++index) {
                configuration->mNumberChannels[index] = 1U;
            }
            if (dataUsed != NULL) {
                *dataUsed = requiredSize;
            }
            return kCMIOHardwareNoError;
        }
        case kCMIODevicePropertyExcludeNonDALAccess:
            return ppvc_copy_u32_property(PPVC_EXCLUDE_NON_DAL_ACCESS, dataSize, dataUsed, data);
        case kCMIOStreamPropertyDirection:
            return ppvc_copy_u32_property(PPVC_INPUT_DIRECTION, dataSize, dataUsed, data);
        case kCMIOStreamPropertyTerminalType:
            return ppvc_copy_u32_property(PPVC_TERMINAL_TYPE, dataSize, dataUsed, data);
        case kCMIOStreamPropertyStartingChannel:
            return ppvc_copy_u32_property(1U, dataSize, dataUsed, data);
        case kCMIOStreamPropertyFormatDescription:
        case kCMIOStreamPropertyPreferredFormatDescription: {
            OSStatus status = kCMIOHardwareNoError;
            pthread_mutex_lock(&driver->stateMutex);
            if (driver->formatDescription == NULL) {
                status = ppvc_ensure_format_description_locked(driver);
            }
            CMVideoFormatDescriptionRef formatDescription = driver->formatDescription;
            if (status == kCMIOHardwareNoError && formatDescription != NULL) {
                status = ppvc_copy_cf_property(formatDescription, dataSize, dataUsed, data);
            } else if (status == kCMIOHardwareNoError) {
                status = kCMIOHardwareUnspecifiedError;
            }
            pthread_mutex_unlock(&driver->stateMutex);
            return status;
        }
        case kCMIOStreamPropertyFormatDescriptions: {
            OSStatus status = kCMIOHardwareNoError;
            pthread_mutex_lock(&driver->stateMutex);
            if (driver->formatDescription == NULL) {
                status = ppvc_ensure_format_description_locked(driver);
            }
            CMVideoFormatDescriptionRef formatDescription = driver->formatDescription;
            if (status == kCMIOHardwareNoError && formatDescription != NULL) {
                const void *values[1] = { formatDescription };
                CFArrayRef descriptions = CFArrayCreate(kCFAllocatorDefault, values, 1, &kCFTypeArrayCallBacks);
                if (descriptions == NULL) {
                    status = kCMIOHardwareUnspecifiedError;
                } else {
                    status = ppvc_copy_cf_property(descriptions, dataSize, dataUsed, data);
                    CFRelease(descriptions);
                }
            } else if (status == kCMIOHardwareNoError) {
                status = kCMIOHardwareUnspecifiedError;
            }
            pthread_mutex_unlock(&driver->stateMutex);
            return status;
        }
        case kCMIOStreamPropertyFrameRate:
        case kCMIOStreamPropertyMinimumFrameRate:
        case kCMIOStreamPropertyPreferredFrameRate: {
            Float64 frameRate = PPVC_DEFAULT_FRAME_RATE;
            pthread_mutex_lock(&driver->stateMutex);
            frameRate = address->mSelector == kCMIOStreamPropertyMinimumFrameRate ? PPVC_MIN_FRAME_RATE : driver->frameRate;
            pthread_mutex_unlock(&driver->stateMutex);
            return ppvc_copy_f64_property(frameRate, dataSize, dataUsed, data);
        }
        case kCMIOStreamPropertyFrameRates: {
            Float64 frameRate = PPVC_DEFAULT_FRAME_RATE;
            pthread_mutex_lock(&driver->stateMutex);
            frameRate = driver->frameRate;
            pthread_mutex_unlock(&driver->stateMutex);
            return ppvc_copy_f64_property(frameRate, dataSize, dataUsed, data);
        }
        default:
            return kCMIOHardwareUnknownPropertyError;
    }
}

OSStatus PPVCRuntime_ObjectSetPropertyData(CMIOHardwarePlugInRef self,
                                           CMIOObjectID objectID,
                                           const CMIOObjectPropertyAddress *address,
                                           UInt32 qualifierDataSize,
                                           const void *qualifierData,
                                           UInt32 dataSize,
                                           const void *data)
{
    (void)qualifierDataSize;
    (void)qualifierData;
    (void)dataSize;
    (void)data;

    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || address == NULL) {
        return kCMIOHardwareIllegalOperationError;
    }

    PPVCObjectRole role = ppvc_object_role(driver, objectID);
    if (role == kPPVCObjectRoleNone || !ppvc_selector_supported_for_role(role, address->mSelector)) {
        return kCMIOHardwareUnknownPropertyError;
    }

    switch (address->mSelector) {
        case kCMIOObjectPropertyListenerAdded:
        case kCMIOObjectPropertyListenerRemoved:
            return kCMIOHardwareNoError;
        default:
            return kCMIOHardwareIllegalOperationError;
    }
}

OSStatus PPVCRuntime_DeviceSuspend(CMIOHardwarePlugInRef self, CMIODeviceID device)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || device != driver->deviceObjectID) {
        return kCMIOHardwareBadObjectError;
    }

    pthread_mutex_lock(&driver->stateMutex);
    driver->suspended = true;
    pthread_mutex_unlock(&driver->stateMutex);
    return kCMIOHardwareNoError;
}

OSStatus PPVCRuntime_DeviceResume(CMIOHardwarePlugInRef self, CMIODeviceID device)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || device != driver->deviceObjectID) {
        return kCMIOHardwareBadObjectError;
    }

    pthread_mutex_lock(&driver->stateMutex);
    driver->suspended = false;
    ppvc_write_runtime_status_locked(driver, true, false, false, false, 0, driver->frameSequence);
    pthread_mutex_unlock(&driver->stateMutex);
    return kCMIOHardwareNoError;
}

OSStatus PPVCRuntime_DeviceStartStream(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIOStreamID stream)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || device != driver->deviceObjectID || stream != driver->streamObjectID) {
        return kCMIOHardwareBadObjectError;
    }

    pthread_mutex_lock(&driver->stateMutex);
    ppvc_load_publisher_state_locked(driver);
    OSStatus status = ppvc_ensure_queue_locked(driver);
    if (status == kCMIOHardwareNoError) {
        ppvc_drain_queue_locked(driver);
        driver->frameSequence = 0;
    }
    pthread_mutex_unlock(&driver->stateMutex);
    if (status != kCMIOHardwareNoError) {
        return status;
    }

    UInt32 previousStartCount = atomic_fetch_add_explicit(&driver->startCount, 1, memory_order_acq_rel);
    if (previousStartCount == 0) {
        status = ppvc_start_frame_thread(driver);
        if (status != kCMIOHardwareNoError) {
            atomic_fetch_sub_explicit(&driver->startCount, 1, memory_order_acq_rel);
            return status;
        }
    }

    pthread_mutex_lock(&driver->stateMutex);
    ppvc_write_runtime_status_locked(driver, true, false, false, false, 0, driver->frameSequence);
    pthread_mutex_unlock(&driver->stateMutex);

    return kCMIOHardwareNoError;
}

OSStatus PPVCRuntime_DeviceStopStream(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIOStreamID stream)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || device != driver->deviceObjectID || stream != driver->streamObjectID) {
        return kCMIOHardwareBadObjectError;
    }

    UInt32 previousStartCount = atomic_load_explicit(&driver->startCount, memory_order_acquire);
    while (previousStartCount > 0) {
        if (atomic_compare_exchange_weak_explicit(&driver->startCount, &previousStartCount, previousStartCount - 1, memory_order_acq_rel, memory_order_acquire)) {
            if (previousStartCount == 1) {
                ppvc_stop_frame_thread(driver);
                pthread_mutex_lock(&driver->stateMutex);
                ppvc_drain_queue_locked(driver);
                ppvc_write_runtime_status_locked(driver, true, false, false, false, 0, driver->frameSequence);
                pthread_mutex_unlock(&driver->stateMutex);
            }
            return kCMIOHardwareNoError;
        }
    }

    return kCMIOHardwareNoError;
}

OSStatus PPVCRuntime_DeviceProcessAVCCommand(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIODeviceAVCCommand *ioAVCCommand)
{
    (void)ioAVCCommand;

    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || device != driver->deviceObjectID) {
        return kCMIOHardwareBadObjectError;
    }
    return kCMIOHardwareIllegalOperationError;
}

OSStatus PPVCRuntime_DeviceProcessRS422Command(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIODeviceRS422Command *ioRS422Command)
{
    (void)ioRS422Command;

    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || device != driver->deviceObjectID) {
        return kCMIOHardwareBadObjectError;
    }
    return kCMIOHardwareIllegalOperationError;
}

OSStatus PPVCRuntime_StreamCopyBufferQueue(CMIOHardwarePlugInRef self,
                                           CMIOStreamID stream,
                                           CMIODeviceStreamQueueAlteredProc queueAlteredProc,
                                           void *queueAlteredRefCon,
                                           CMSimpleQueueRef *queue)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || stream != driver->streamObjectID || queue == NULL) {
        if (queue != NULL) {
            *queue = NULL;
        }
        return kCMIOHardwareBadObjectError;
    }

    pthread_mutex_lock(&driver->stateMutex);
    OSStatus status = ppvc_ensure_queue_locked(driver);
    if (status == kCMIOHardwareNoError) {
        driver->queueAlteredProc = queueAlteredProc;
        driver->queueAlteredRefCon = queueAlteredRefCon;
        CFRetain(driver->sampleQueue);
        *queue = driver->sampleQueue;
    } else {
        *queue = NULL;
    }
    pthread_mutex_unlock(&driver->stateMutex);

    return status;
}

OSStatus PPVCRuntime_StreamDeckPlay(CMIOHardwarePlugInRef self, CMIOStreamID stream)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || stream != driver->streamObjectID) {
        return kCMIOHardwareBadObjectError;
    }
    return kCMIOHardwareIllegalOperationError;
}

OSStatus PPVCRuntime_StreamDeckStop(CMIOHardwarePlugInRef self, CMIOStreamID stream)
{
    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || stream != driver->streamObjectID) {
        return kCMIOHardwareBadObjectError;
    }
    return kCMIOHardwareIllegalOperationError;
}

OSStatus PPVCRuntime_StreamDeckJog(CMIOHardwarePlugInRef self, CMIOStreamID stream, SInt32 speed)
{
    (void)speed;

    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || stream != driver->streamObjectID) {
        return kCMIOHardwareBadObjectError;
    }
    return kCMIOHardwareIllegalOperationError;
}

OSStatus PPVCRuntime_StreamDeckCueTo(CMIOHardwarePlugInRef self, CMIOStreamID stream, Float64 frameNumber, Boolean playOnCue)
{
    (void)frameNumber;
    (void)playOnCue;

    PodcastPreviewVirtualCameraDriver *driver = ppvc_driver(self);
    if (driver == NULL || stream != driver->streamObjectID) {
        return kCMIOHardwareBadObjectError;
    }
    return kCMIOHardwareIllegalOperationError;
}
