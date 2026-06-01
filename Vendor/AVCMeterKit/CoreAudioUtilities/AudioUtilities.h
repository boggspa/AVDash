/**
 * AudioUtilitiesh
 * Utility functions for querying CoreAudio device capabilities in AVCMeter.
 *
 * Provides simple Boolean checks for whether a device supports input/output,
 * and retrieves the number of input/output channels for a given device.
 *
 * Key Functions:
 * - deviceHasInput
 * - deviceHasOutput
 * - getDeviceInputChannelCount
 * - getDeviceOutputChannelCount
 */

//
//  CoreAudioUtils.h
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//

#ifndef AudioUtilities_h
#define AudioUtilities_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

// MARK: Core Audio Utilities


/**
 * Checks if the given audio device has any input channels.
 */
Boolean deviceHasInput(AudioDeviceID deviceID);

/**
 * Checks if the given audio device has any output channels.
 */
Boolean deviceHasOutput(AudioDeviceID deviceID);

/**
 * Gets the number of input channels available on the specified device.
 */
UInt32 getDeviceInputChannelCount(AudioDeviceID deviceID);

/**
 * Gets the number of output channels available on the specified device.
 */
UInt32 getDeviceOutputChannelCount(AudioDeviceID deviceID);

// MARK: Static Info Fetcher:


const char* getDeviceName(AudioDeviceID deviceID);

Float64 getSampleRate(AudioDeviceID deviceID);

const char* getDeviceTransportType(AudioDeviceID deviceID);

bool isDeviceValid(AudioDeviceID deviceID);


#endif /* AudioUtilities_h */
