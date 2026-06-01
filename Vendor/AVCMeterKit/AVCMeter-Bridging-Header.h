//
//  AVCMeter-Bridging-Header.h
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//

#ifndef AVCMeter_Bridging_Header_h
#define AVCMeter_Bridging_Header_h



#include "AudioUtils.hpp"
#include "ChannelSpectrumBridge.hpp"

#include "AudioBridge.h"
#include "PCMRingBuffer.h"
#include "PCMInputStream.h"
#include "PCMEngine.h"
#include "FFTRingBuffer.h"
#include "FFTInputStream.h"
#include "SpectroRingBuffer.h"
#include "SpectroInputStream.h"
#include "Spectro2DRingBuffer.h"
#include "SpectroHistoryRingBuffer.h"
#import "IOStreams.h"
#import "Mixer.h"

void RingBuffer_SetPostGain(int channel, float gain);
void Mixer_DebugPrintDevices();


#endif /* AVCMeter_Bridging_Header_h */
