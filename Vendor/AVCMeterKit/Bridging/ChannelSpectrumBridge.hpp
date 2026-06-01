//
//  ChannelSpectrumBridge.hpp
//  AVCMeter
//
//  Created by Chris Izatt on 22/06/2025.
//



#ifndef ChannelSpectrumBridge_h
#define ChannelSpectrumBridge_h

#include <CoreAudio/CoreAudioTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

void ChannelSpectrumBridge_ProcessSamples(AudioDeviceID deviceID, int channel, float* samples, int length);
const float* ChannelSpectrumBridge_getPeakMagnitudes(AudioDeviceID deviceID, int channel, int* outLength);

#ifdef __cplusplus
}
#endif

#endif /* ChannelSpectrumBridge_h */
