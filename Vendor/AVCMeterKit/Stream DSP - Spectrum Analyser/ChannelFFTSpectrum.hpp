//  ChannelFFTSpectrum.hpp
//  AVCMeter
//
//  Created by Chris Izatt on 22/06/2025.
//

#ifndef ChannelFFTSpectrum_hpp
#define ChannelFFTSpectrum_hpp

#ifdef __cplusplus
#include <vector>
#include <Accelerate/Accelerate.h>
#include <iostream>

class ChannelFFTSpectrum {
public:
    ChannelFFTSpectrum(size_t fftSize);
    ~ChannelFFTSpectrum();

    void process(float* input, size_t length);
    const std::vector<float>& getPeakMagnitudes() const;
    void setUseCWeighting(bool enabled);

private:
    size_t fftSize;
    size_t log2n;
    FFTSetup fftSetup;
    DSPSplitComplex splitComplex;
    std::vector<float> window;
    std::vector<float> magnitudes;
    std::vector<float> peakMagnitudes;
    float* realp;
    float* imagp;

    void applyWindow(float* input, size_t length);

    bool useCWeighting;
    void applyCWeighting(std::vector<float>& mags);
};
#endif // __cplusplus

#endif /* ChannelFFTSpectrum_hpp */
