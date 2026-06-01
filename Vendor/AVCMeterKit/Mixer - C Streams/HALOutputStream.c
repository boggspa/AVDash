//
//  HALOutputStream.c
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

// NOTE: All output ring buffer allocation/free is managed by Mixer.c.
// This file must NEVER allocate or free RingBuffers directly.
// Always use Mixer_GetOutputRingBufferByGlobalIndex and never cache pointers.

#ifdef __cplusplus
extern "C++" {
}
#endif
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <pthread.h>
#include <stdio.h>

#include "IOStreams.h"
#include "Mixer.h"

// Forward declaration for Swift mute check
extern bool IsOutputChannelMuted(AudioDeviceID deviceID, int channelIndex);

// Forward declaration for output ring buffer access from Mixer.c
// RingBuffer* Mixer_GetOutputRingBufferByGlobalIndex(int globalChannelIndex); // Removed usage for output channel

// Static IOProc ID for output stream
//#define single static AudioDeviceIOProcID outputIOProcID = NULL;  // Removed single static IOProcID

#define MAX_OUTPUT_STREAMS 16
#define OUTPUT_IOPROC_CHUNK_FRAMES 1024

static struct {
    AudioDeviceID deviceID;
    AudioDeviceIOProcID ioProcID;
    int flatIndices[128];
    RingBuffer* ringBuffers[128];
    UInt32 numChannels;
    AudioStreamBasicDescription streamFormat;
    bool hasStreamFormat;
} outputStreams[MAX_OUTPUT_STREAMS] = {0};


// MARK: Find/Allocation Output Stream Index Function

static int findOutputStreamIndex(AudioDeviceID deviceID) {
    for (int i = 0; i < MAX_OUTPUT_STREAMS; ++i) {
        if (outputStreams[i].deviceID == deviceID)
            return i;
    }
    return -1;
}
static int allocOutputStreamIndex(AudioDeviceID deviceID) {
    for (int i = 0; i < MAX_OUTPUT_STREAMS; ++i) {
        if (outputStreams[i].deviceID == 0) {
            memset(&outputStreams[i], 0, sizeof(outputStreams[i]));
            outputStreams[i].deviceID = deviceID;
            return i;
        }
    }
    return -1;
}

static bool queryOutputStreamFormat(AudioDeviceID deviceID, AudioStreamBasicDescription* outFormat) {
    if (!outFormat) {
        return false;
    }

    UInt32 size = (UInt32)sizeof(AudioStreamBasicDescription);
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyStreamFormat,
        .mScope = kAudioDevicePropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, outFormat);
    return (status == noErr);
}

static float clamp_unit_float(float value) {
    if (value > 1.0f) return 1.0f;
    if (value < -1.0f) return -1.0f;
    return value;
}

static bool mapLogicalChannelToBuffer(const AudioBufferList* outputData,
                                      UInt32 logicalChannel,
                                      UInt32* outBufferIndex,
                                      UInt32* outChannelInBuffer) {
    if (!outputData || !outBufferIndex || !outChannelInBuffer) {
        return false;
    }

    UInt32 channelCursor = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < outputData->mNumberBuffers; ++bufferIndex) {
        UInt32 channelsInBuffer = outputData->mBuffers[bufferIndex].mNumberChannels;
        if (logicalChannel < channelCursor + channelsInBuffer) {
            *outBufferIndex = bufferIndex;
            *outChannelInBuffer = logicalChannel - channelCursor;
            return true;
        }
        channelCursor += channelsInBuffer;
    }

    return false;
}

static void writeFloatChunkToOutputBuffer(AudioBuffer* buffer,
                                          const AudioStreamBasicDescription* streamFormat,
                                          UInt32 channelInBuffer,
                                          UInt32 frameOffset,
                                          const float* source,
                                          UInt32 frameCount) {
    if (!buffer || !streamFormat || !source || !buffer->mData) {
        return;
    }

    UInt32 channelsInBuffer = buffer->mNumberChannels > 0 ? buffer->mNumberChannels : 1;
    AudioFormatFlags formatFlags = streamFormat->mFormatFlags;

    if ((formatFlags & kAudioFormatFlagIsFloat) &&
        streamFormat->mBitsPerChannel == 32) {
        Float32* destination = (Float32*)buffer->mData;
        for (UInt32 frame = 0; frame < frameCount; ++frame) {
            UInt32 sampleIndex = (frameOffset + frame) * channelsInBuffer + channelInBuffer;
            destination[sampleIndex] = source[frame];
        }
        return;
    }

    if ((formatFlags & kAudioFormatFlagIsSignedInteger) &&
        streamFormat->mBitsPerChannel == 16) {
        SInt16* destination = (SInt16*)buffer->mData;
        for (UInt32 frame = 0; frame < frameCount; ++frame) {
            float sample = clamp_unit_float(source[frame]);
            SInt16 quantized = (SInt16)lrintf(sample * 32767.0f);
            UInt32 sampleIndex = (frameOffset + frame) * channelsInBuffer + channelInBuffer;
            destination[sampleIndex] = quantized;
        }
        return;
    }

    if ((formatFlags & kAudioFormatFlagIsSignedInteger) &&
        streamFormat->mBitsPerChannel == 32) {
        SInt32* destination = (SInt32*)buffer->mData;
        for (UInt32 frame = 0; frame < frameCount; ++frame) {
            float sample = clamp_unit_float(source[frame]);
            SInt32 quantized = (SInt32)lrintf(sample * 2147483647.0f);
            UInt32 sampleIndex = (frameOffset + frame) * channelsInBuffer + channelInBuffer;
            destination[sampleIndex] = quantized;
        }
        return;
    }
}

// MARK: IO PROC for Main Output Streams (Post-Mix)

// NOTE: Device registration with Mixer must NEVER be performed from within this IOProc. Registration is done in HAL_StartOutputStream only.
// The outputStreams struct caches flatIndices and ringBuffers to avoid repeated calls during IOProc.
static OSStatus OutputDeviceIOProc(AudioDeviceID inDevice,
                                    const AudioTimeStamp* inNow,
                                    const AudioBufferList* inInputData,
                                    const AudioTimeStamp* inInputTime,
                                    AudioBufferList* outOutputData,
                                    const AudioTimeStamp* inOutputTime,
                                    void* inClientData) {
    int index = findOutputStreamIndex(inDevice);
    if (index < 0) {
        return noErr;
    }

    if (outOutputData != NULL) {
        const AudioStreamBasicDescription* streamFormat = &outputStreams[index].streamFormat;
        if (!outputStreams[index].hasStreamFormat ||
            streamFormat->mBytesPerFrame == 0) {
            return noErr;
        }

        UInt32 frameCount = 0;
        if (outOutputData->mNumberBuffers > 0) {
            frameCount = outOutputData->mBuffers[0].mDataByteSize / streamFormat->mBytesPerFrame;
        }
        if (frameCount == 0) {
            return noErr;
        }

        for (UInt32 bufferIndex = 0; bufferIndex < outOutputData->mNumberBuffers; ++bufferIndex) {
            AudioBuffer* outputBuffer = &outOutputData->mBuffers[bufferIndex];
            if (outputBuffer->mData && outputBuffer->mDataByteSize > 0) {
                memset(outputBuffer->mData, 0, outputBuffer->mDataByteSize);
            }
        }

        UInt32 numCachedChannels = outputStreams[index].numChannels;
        float readScratch[OUTPUT_IOPROC_CHUNK_FRAMES];

        for (UInt32 logicalChannel = 0; logicalChannel < numCachedChannels; ++logicalChannel) {
            if (IsOutputChannelMuted(inDevice, (int)logicalChannel)) {
                continue;
            }

            UInt32 bufferIndex = 0;
            UInt32 channelInBuffer = 0;
            if (!mapLogicalChannelToBuffer(outOutputData,
                                           logicalChannel,
                                           &bufferIndex,
                                           &channelInBuffer)) {
                continue;
            }

            RingBuffer* ringBuffer = outputStreams[index].ringBuffers[logicalChannel];
            if (!ringBuffer) {
                continue;
            }

            AudioBuffer* destinationBuffer = &outOutputData->mBuffers[bufferIndex];
            UInt32 framesRemaining = frameCount;
            UInt32 frameOffset = 0;

            while (framesRemaining > 0) {
                UInt32 chunkFrames = framesRemaining > OUTPUT_IOPROC_CHUNK_FRAMES ? OUTPUT_IOPROC_CHUNK_FRAMES : framesRemaining;
                int framesRead = ringbuffer_read(ringBuffer, readScratch, (int)chunkFrames);
                if (framesRead < 0) {
                    framesRead = 0;
                }
                if ((UInt32)framesRead < chunkFrames) {
                    memset(readScratch + framesRead, 0, sizeof(float) * (chunkFrames - (UInt32)framesRead));
                }

                writeFloatChunkToOutputBuffer(destinationBuffer,
                                              streamFormat,
                                              channelInBuffer,
                                              frameOffset,
                                              readScratch,
                                              chunkFrames);

                frameOffset += chunkFrames;
                framesRemaining -= chunkFrames;
            }
        }
    }
    return noErr;
}


// MARK: C-side call for acquiring Output Device IDs & Channel Counts

/** @Section -- Output Device enumeration call - C-Side Function -- */
int getAllOutputAudioDeviceIDs(AudioDeviceID* outDevices, int maxDevices) {
    if (maxDevices <= 0) return 0;

    UInt32 propsize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
        &(AudioObjectPropertyAddress) {
            .mSelector = kAudioHardwarePropertyDevices,
            .mScope    = kAudioObjectPropertyScopeGlobal,
            .mElement  = kAudioObjectPropertyElementMain
        },
        0, NULL, &propsize);

    if (status != noErr || propsize == 0) return 0;
    int deviceCount = propsize / sizeof(AudioDeviceID);
    if (deviceCount <= 0) return 0;

    AudioDeviceID allDevices[deviceCount];
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
        &(AudioObjectPropertyAddress) {
            .mSelector = kAudioHardwarePropertyDevices,
            .mScope    = kAudioObjectPropertyScopeGlobal,
            .mElement  = kAudioObjectPropertyElementMain
        },
        0, NULL, &propsize, allDevices);

    if (status != noErr) return 0;

    int numOutputs = 0;
    for (int i = 0; i < deviceCount && numOutputs < maxDevices; ++i) {
        AudioDeviceID dev = allDevices[i];

        /** -- Query the number of output channels -- */
        UInt32 chansize = 0;
        AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyStreamConfiguration,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };

        status = AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &chansize);
        if (status != noErr || chansize == 0) continue;
        AudioBufferList* bufList = (AudioBufferList*)malloc(chansize);
        if (!bufList) continue;
        status = AudioObjectGetPropertyData(dev, &addr, 0, NULL, &chansize, bufList);
        if (status == noErr) {
            UInt32 outChannels = 0;
            for (UInt32 b = 0; b < bufList->mNumberBuffers; ++b) {
                outChannels += bufList->mBuffers[b].mNumberChannels;
            }
            if (outChannels > 0) {
                if (outDevices) {
                    outDevices[numOutputs] = dev;
                }
                ++numOutputs;
            }
        }
        free(bufList);
    }
    return numOutputs;
}

/** @Section -- Channel Count for Output Devices - C-Side Function -- */
static UInt32 getDeviceOutputChannelCount(AudioDeviceID deviceID) {
    UInt32 chansize = 0;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, NULL, &chansize);
    if (status != noErr || chansize == 0) return 0;

    AudioBufferList* bufList = (AudioBufferList*)malloc(chansize);
    if (!bufList) return 0;

    status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &chansize, bufList);
    if (status != noErr) {
        free(bufList);
        return 0;
    }

    UInt32 outChannels = 0;
    for (UInt32 b = 0; b < bufList->mNumberBuffers; ++b) {
        outChannels += bufList->mBuffers[b].mNumberChannels;
    }
    free(bufList);
    return outChannels;
}

// MARK: HAL Output Stream Start / Stop

OSStatus HAL_StartOutputStream(AudioDeviceID deviceID) {
    OSStatus status;

    int index = findOutputStreamIndex(deviceID);
    if (index >= 0 && outputStreams[index].ioProcID != NULL) {
        return noErr;
    }
    index = allocOutputStreamIndex(deviceID);
    if (index < 0) {
        return kAudio_ParamError;
    }

    // Register output device with mixer
    UInt32 numOutputChannels = getDeviceOutputChannelCount(deviceID);
    outputStreams[index].numChannels = numOutputChannels;
    if (numOutputChannels == 0) {
        outputStreams[index].deviceID = 0;
        return kAudio_ParamError;
    }

    outputStreams[index].hasStreamFormat = queryOutputStreamFormat(deviceID, &outputStreams[index].streamFormat);
    if (!outputStreams[index].hasStreamFormat) {
        memset(&outputStreams[index].streamFormat, 0, sizeof(AudioStreamBasicDescription));
        outputStreams[index].streamFormat.mFormatID = kAudioFormatLinearPCM;
        outputStreams[index].streamFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        outputStreams[index].streamFormat.mBitsPerChannel = 32;
        outputStreams[index].streamFormat.mChannelsPerFrame = numOutputChannels;
        outputStreams[index].streamFormat.mFramesPerPacket = 1;
        outputStreams[index].streamFormat.mBytesPerFrame = sizeof(float) * numOutputChannels;
        outputStreams[index].streamFormat.mBytesPerPacket = outputStreams[index].streamFormat.mBytesPerFrame;
        outputStreams[index].hasStreamFormat = true;
    }

    printf("[HALOutput] device=%u formatID=%u flags=0x%08x channels=%u bits=%u bytesPerFrame=%u\n",
           (unsigned)deviceID,
           (unsigned)outputStreams[index].streamFormat.mFormatID,
           (unsigned)outputStreams[index].streamFormat.mFormatFlags,
           (unsigned)outputStreams[index].streamFormat.mChannelsPerFrame,
           (unsigned)outputStreams[index].streamFormat.mBitsPerChannel,
           (unsigned)outputStreams[index].streamFormat.mBytesPerFrame);

    int mixerRegistrationResult = Mixer_RegisterDevice(deviceID, MIXER_CHANNEL_OUTPUT, numOutputChannels);
    if (mixerRegistrationResult != 0) {
        outputStreams[index].deviceID = 0;
        outputStreams[index].numChannels = 0;
        return kAudio_ParamError;
    }

    for (UInt32 channelIndex = 0; channelIndex < numOutputChannels; ++channelIndex) {
        outputStreams[index].flatIndices[channelIndex] = (int)channelIndex;
        outputStreams[index].ringBuffers[channelIndex] = Mixer_GetOutputChannelRingBuffer(deviceID, channelIndex);
    }

    // Register IOProc for this device
    status = AudioDeviceCreateIOProcID(deviceID, OutputDeviceIOProc, NULL, &outputStreams[index].ioProcID);
    if (status != noErr) {
        outputStreams[index].deviceID = 0;
        outputStreams[index].ioProcID = NULL;
        outputStreams[index].numChannels = 0;
        return status;
    }

    // Start the device
    status = AudioDeviceStart(deviceID, outputStreams[index].ioProcID);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(deviceID, outputStreams[index].ioProcID);
        outputStreams[index].deviceID = 0;
        outputStreams[index].ioProcID = NULL;
        outputStreams[index].numChannels = 0;
        return status;
    }
    return noErr;
}

OSStatus HAL_StopOutputStream(AudioDeviceID deviceID) {
    int index = findOutputStreamIndex(deviceID);
    if (index < 0) {
        return noErr;
    }

    if (outputStreams[index].ioProcID != NULL) {
        AudioDeviceStop(deviceID, outputStreams[index].ioProcID);
        AudioDeviceDestroyIOProcID(deviceID, outputStreams[index].ioProcID);
        outputStreams[index].ioProcID = NULL;
    }
    outputStreams[index].numChannels = 0;
    outputStreams[index].hasStreamFormat = false;
    memset(&outputStreams[index].streamFormat, 0, sizeof(AudioStreamBasicDescription));
    memset(outputStreams[index].flatIndices, 0, sizeof(outputStreams[index].flatIndices));
    memset(outputStreams[index].ringBuffers, 0, sizeof(outputStreams[index].ringBuffers));
    outputStreams[index].deviceID = 0;
    return noErr;
}


/** End of HALOutputStream.c. All output buffer pointer lifecycle is managed in Mixer.c only.
 */
