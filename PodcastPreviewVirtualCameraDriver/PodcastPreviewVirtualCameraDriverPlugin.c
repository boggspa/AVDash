#include <CoreFoundation/CFPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>

#include "PodcastPreviewVirtualCameraDriverRuntime.h"

static HRESULT STDMETHODCALLTYPE PodcastPreviewVirtualCamera_QueryInterface(void *self, REFIID uuid, LPVOID *interface);
static ULONG STDMETHODCALLTYPE PodcastPreviewVirtualCamera_AddRef(void *self);
static ULONG STDMETHODCALLTYPE PodcastPreviewVirtualCamera_Release(void *self);

static CMIOHardwarePlugInInterface gPodcastPreviewVirtualCameraInterface = {
    NULL,
    PodcastPreviewVirtualCamera_QueryInterface,
    PodcastPreviewVirtualCamera_AddRef,
    PodcastPreviewVirtualCamera_Release,
    PPVCRuntime_Initialize,
    PPVCRuntime_InitializeWithObjectID,
    PPVCRuntime_Teardown,
    PPVCRuntime_ObjectShow,
    PPVCRuntime_ObjectHasProperty,
    PPVCRuntime_ObjectIsPropertySettable,
    PPVCRuntime_ObjectGetPropertyDataSize,
    PPVCRuntime_ObjectGetPropertyData,
    PPVCRuntime_ObjectSetPropertyData,
    PPVCRuntime_DeviceSuspend,
    PPVCRuntime_DeviceResume,
    PPVCRuntime_DeviceStartStream,
    PPVCRuntime_DeviceStopStream,
    PPVCRuntime_DeviceProcessAVCCommand,
    PPVCRuntime_DeviceProcessRS422Command,
    PPVCRuntime_StreamCopyBufferQueue,
    PPVCRuntime_StreamDeckPlay,
    PPVCRuntime_StreamDeckStop,
    PPVCRuntime_StreamDeckJog,
    PPVCRuntime_StreamDeckCueTo
};

void *PodcastPreviewVirtualCameraFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID)
{
    (void)allocator;

    if (requestedTypeUUID == NULL || !CFEqual(requestedTypeUUID, kCMIOHardwarePlugInTypeID)) {
        return NULL;
    }

    PodcastPreviewVirtualCameraDriver *driver = (PodcastPreviewVirtualCameraDriver *)calloc(1, sizeof(PodcastPreviewVirtualCameraDriver));
    if (driver == NULL) {
        return NULL;
    }

    driver->interface = &gPodcastPreviewVirtualCameraInterface;
    atomic_store_explicit(&driver->refCount, 1, memory_order_release);
    PPVCRuntime_InitializeDriverState(driver);
    PPVCRuntime_LogMessage("Factory created virtual camera DAL driver.");
    return driver;
}

static HRESULT STDMETHODCALLTYPE PodcastPreviewVirtualCamera_QueryInterface(void *self, REFIID uuid, LPVOID *interface)
{
    if (interface == NULL) {
        return E_POINTER;
    }
    *interface = NULL;

    if (self == NULL) {
        return E_POINTER;
    }

    CFUUIDRef interfaceUUID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, uuid);
    if (interfaceUUID == NULL) {
        return E_NOINTERFACE;
    }

    Boolean supported = CFEqual(interfaceUUID, IUnknownUUID) || CFEqual(interfaceUUID, kCMIOHardwarePlugInInterfaceID);
    CFRelease(interfaceUUID);

    if (!supported) {
        return E_NOINTERFACE;
    }

    PodcastPreviewVirtualCamera_AddRef(self);
    *interface = self;
    return S_OK;
}

static ULONG STDMETHODCALLTYPE PodcastPreviewVirtualCamera_AddRef(void *self)
{
    PodcastPreviewVirtualCameraDriver *driver = (PodcastPreviewVirtualCameraDriver *)self;
    if (driver == NULL) {
        return 0;
    }
    return atomic_fetch_add_explicit(&driver->refCount, 1, memory_order_acq_rel) + 1;
}

static ULONG STDMETHODCALLTYPE PodcastPreviewVirtualCamera_Release(void *self)
{
    PodcastPreviewVirtualCameraDriver *driver = (PodcastPreviewVirtualCameraDriver *)self;
    if (driver == NULL) {
        return 0;
    }

    UInt32 newCount = atomic_fetch_sub_explicit(&driver->refCount, 1, memory_order_acq_rel) - 1;
    if (newCount == 0) {
        PPVCRuntime_DestroyDriverState(driver);
        free(driver);
    }
    return newCount;
}
