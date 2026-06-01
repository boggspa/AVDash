//
//  ChannelSpectrumBridge.mm
//  AVCMeter
//
//  Created by Chris Izatt on 22/06/2025.
//

// FFT constants
static const int kFFTSize = 2048;
static const int kFFTSizeZ = 4096;
static const int kFFTOverlap = kFFTSize / 2; // 50% overlap

#include <CoreAudio/CoreAudio.h>
#import "ChannelSpectrumBridge.hpp"
#import <vector>
#import <unordered_map>

#include "ChannelFFTSpectrum.hpp"

struct pair_hash {
    template <class T1, class T2>
    std::size_t operator()(const std::pair<T1, T2>& p) const {
        auto h1 = std::hash<T1>{}(p.first);
        auto h2 = std::hash<T2>{}(p.second);
        return h1 ^ (h2 << 1);
    }
};

static std::unordered_map<std::pair<AudioDeviceID, int>, ChannelFFTSpectrum*, pair_hash> spectrumMap;
// Rolling buffer for each (deviceID, channel) pair
static std::unordered_map<std::pair<AudioDeviceID, int>, std::vector<float>, pair_hash> channelBuffers;

extern "C" void ChannelSpectrumBridge_ProcessSamples(AudioDeviceID deviceID, int channel, float* samples, int length) {
    std::pair<AudioDeviceID, int> key = { deviceID, channel };
    if (!spectrumMap[key]) {
        spectrumMap[key] = new ChannelFFTSpectrum(kFFTSize);
    }

    // Rolling buffer storage for each key
    std::vector<float>& buffer = channelBuffers[key];
    buffer.insert(buffer.end(), samples, samples + length);

    // Process in chunks of kFFTSize with kFFTOverlap overlap
    while (buffer.size() >= kFFTSize) {
        spectrumMap[key]->process(buffer.data(), kFFTSize);
        buffer.erase(buffer.begin(), buffer.begin() + kFFTOverlap);
    }
}

extern "C" const float* ChannelSpectrumBridge_getPeakMagnitudes(AudioDeviceID deviceID, int channel, int* outLength) {
    std::pair<AudioDeviceID, int> key = { deviceID, channel };
    if (spectrumMap[key]) {
        const auto& mags = spectrumMap[key]->getPeakMagnitudes();
        int count = static_cast<int>(mags.size());
        *outLength = count;
        return mags.data();
    }
    *outLength = 0;
    return nullptr;
}
