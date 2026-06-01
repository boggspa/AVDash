#ifndef PODCAST_PREVIEW_VIRTUAL_CAMERA_DRIVER_RUNTIME_H
#define PODCAST_PREVIEW_VIRTUAL_CAMERA_DRIVER_RUNTIME_H

#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CMFormatDescription.h>
#include <CoreMedia/CMSimpleQueue.h>
#include <CoreMediaIO/CMIOHardware.h>
#include <CoreMediaIO/CMIOHardwareDevice.h>
#include <CoreMediaIO/CMIOHardwareObject.h>
#include <CoreMediaIO/CMIOHardwarePlugIn.h>
#include <CoreMediaIO/CMIOHardwareStream.h>
#include <CoreMediaIO/CMIOHardwareSystem.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>

#define PPVC_DRIVER_FACTORY_UUID "A7B58B4B-0C6C-4D45-A67A-85F8C8D8E3A1"
#define PPVC_DRIVER_BUNDLE_ID CFSTR("com.chrisizatt.PodcastPreviewVirtualCamera")
#define PPVC_PLUGIN_NAME CFSTR("PodcastPreview Virtual Camera Plug-In")
#define PPVC_DEVICE_NAME CFSTR("PodcastPreview Virtual Camera")
#define PPVC_STREAM_NAME CFSTR("PodcastPreview Virtual Camera Stream")
#define PPVC_DRIVER_MANUFACTURER CFSTR("Podcast Preview")
#define PPVC_DEVICE_UID CFSTR("com.chrisizatt.PodcastPreviewVirtualCamera.device")
#define PPVC_MODEL_UID CFSTR("com.chrisizatt.PodcastPreviewVirtualCamera.model")
#define PPVC_SESSION_STATE_RELATIVE_PATH "Library/Application Support/PodcastPreview/VirtualCamera/publisher-session.plist"
#define PPVC_FRAME_STATE_RELATIVE_PATH "Library/Application Support/PodcastPreview/VirtualCamera/publisher-frame.plist"
#define PPVC_RUNTIME_STATUS_RELATIVE_PATH "Library/Application Support/PodcastPreview/VirtualCamera/runtime-status.plist"
#define PPVC_DEFAULT_WIDTH 1920U
#define PPVC_DEFAULT_HEIGHT 1080U
#define PPVC_DEFAULT_FRAME_RATE 30.0
#define PPVC_MIN_FRAME_RATE 1.0
#define PPVC_MAX_FRAME_RATE 240.0
#define PPVC_QUEUE_CAPACITY 6

typedef struct {
    CMIOHardwarePlugInInterface *interface;
    _Atomic UInt32 refCount;
    CMIOObjectID objectID;
    CMIODeviceID deviceObjectID;
    CMIOStreamID streamObjectID;
    bool devicePublished;
    bool streamPublished;
    CMSimpleQueueRef sampleQueue;
    CMVideoFormatDescriptionRef formatDescription;
    CMIODeviceStreamQueueAlteredProc queueAlteredProc;
    void *queueAlteredRefCon;
    pthread_mutex_t stateMutex;
    pthread_t frameThread;
    bool frameThreadCreated;
    _Atomic bool frameThreadShouldRun;
    _Atomic UInt32 startCount;
    bool suspended;
    UInt32 width;
    UInt32 height;
    Float64 frameRate;
    UInt32 layerCount;
    UInt64 frameSequence;
    CFAbsoluteTime lastRuntimeStatusWriteTime;
} PodcastPreviewVirtualCameraDriver;

void PPVCRuntime_LogMessage(const char *message);
void PPVCRuntime_InitializeDriverState(PodcastPreviewVirtualCameraDriver *driver);
void PPVCRuntime_DestroyDriverState(PodcastPreviewVirtualCameraDriver *driver);

OSStatus PPVCRuntime_Initialize(CMIOHardwarePlugInRef self);
OSStatus PPVCRuntime_InitializeWithObjectID(CMIOHardwarePlugInRef self, CMIOObjectID objectID);
OSStatus PPVCRuntime_Teardown(CMIOHardwarePlugInRef self);
void PPVCRuntime_ObjectShow(CMIOHardwarePlugInRef self, CMIOObjectID objectID);
Boolean PPVCRuntime_ObjectHasProperty(CMIOHardwarePlugInRef self, CMIOObjectID objectID, const CMIOObjectPropertyAddress *address);
OSStatus PPVCRuntime_ObjectIsPropertySettable(CMIOHardwarePlugInRef self, CMIOObjectID objectID, const CMIOObjectPropertyAddress *address, Boolean *isSettable);
OSStatus PPVCRuntime_ObjectGetPropertyDataSize(CMIOHardwarePlugInRef self, CMIOObjectID objectID, const CMIOObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 *dataSize);
OSStatus PPVCRuntime_ObjectGetPropertyData(CMIOHardwarePlugInRef self, CMIOObjectID objectID, const CMIOObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 dataSize, UInt32 *dataUsed, void *data);
OSStatus PPVCRuntime_ObjectSetPropertyData(CMIOHardwarePlugInRef self, CMIOObjectID objectID, const CMIOObjectPropertyAddress *address, UInt32 qualifierDataSize, const void *qualifierData, UInt32 dataSize, const void *data);
OSStatus PPVCRuntime_DeviceSuspend(CMIOHardwarePlugInRef self, CMIODeviceID device);
OSStatus PPVCRuntime_DeviceResume(CMIOHardwarePlugInRef self, CMIODeviceID device);
OSStatus PPVCRuntime_DeviceStartStream(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIOStreamID stream);
OSStatus PPVCRuntime_DeviceStopStream(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIOStreamID stream);
OSStatus PPVCRuntime_DeviceProcessAVCCommand(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIODeviceAVCCommand *ioAVCCommand);
OSStatus PPVCRuntime_DeviceProcessRS422Command(CMIOHardwarePlugInRef self, CMIODeviceID device, CMIODeviceRS422Command *ioRS422Command);
OSStatus PPVCRuntime_StreamCopyBufferQueue(CMIOHardwarePlugInRef self, CMIOStreamID stream, CMIODeviceStreamQueueAlteredProc queueAlteredProc, void *queueAlteredRefCon, CMSimpleQueueRef *queue);
OSStatus PPVCRuntime_StreamDeckPlay(CMIOHardwarePlugInRef self, CMIOStreamID stream);
OSStatus PPVCRuntime_StreamDeckStop(CMIOHardwarePlugInRef self, CMIOStreamID stream);
OSStatus PPVCRuntime_StreamDeckJog(CMIOHardwarePlugInRef self, CMIOStreamID stream, SInt32 speed);
OSStatus PPVCRuntime_StreamDeckCueTo(CMIOHardwarePlugInRef self, CMIOStreamID stream, Float64 frameNumber, Boolean playOnCue);

#endif
