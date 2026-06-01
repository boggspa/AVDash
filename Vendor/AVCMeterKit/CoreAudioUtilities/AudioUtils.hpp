//
//  AudioUtils.hpp
//  AVCMeter
//
//  Created by Chris Izatt on 13/07/2025.
//

#ifndef AudioUtils_hpp
#define AudioUtils_hpp

#include <stdio.h>
#include <AudioToolbox/AudioToolbox.h>

#ifdef __cplusplus
extern "C" {
#endif

int GetInputChannelCount(AudioDeviceID deviceID);
int GetOutputChannelCount(AudioDeviceID deviceID);

#ifdef __cplusplus
}
#endif


#endif /* AudioUtils_hpp */
