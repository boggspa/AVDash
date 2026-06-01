//
//  ChannelFFTSpectrum.cpp
//  AVCMeter
//
//  Created by Chris Izatt on 22/06/2025.
//

#include "ChannelFFTSpectrum.hpp"
#include <cmath>
#include <algorithm>
#include <cstring>
#include <Accelerate/Accelerate.h>
#include <iostream>

ChannelFFTSpectrum::ChannelFFTSpectrum(size_t fftSize)
    : fftSize(fftSize), log2n(static_cast<size_t>(log2(fftSize))), realp(nullptr), imagp(nullptr) {

    fftSetup = vDSP_create_fftsetup(log2n, kFFTRadix2);

    realp = (float*)calloc(fftSize, sizeof(float));
    imagp = (float*)calloc(fftSize, sizeof(float));

    splitComplex.realp = realp;
    splitComplex.imagp = imagp;

    window.resize(fftSize);
    vDSP_hann_window(window.data(), fftSize, vDSP_HANN_NORM);

    magnitudes.resize(fftSize, 0.0f);
    peakMagnitudes.resize(fftSize, 0.0f);
}

ChannelFFTSpectrum::~ChannelFFTSpectrum() {
    vDSP_destroy_fftsetup(fftSetup);
    free(realp);
    free(imagp);
}

void ChannelFFTSpectrum::applyWindow(float* input, size_t length) {
    vDSP_vmul(input, 1, window.data(), 1, input, 1, length);
}

void ChannelFFTSpectrum::process(float* input, size_t length) {
    if (length != fftSize || !input) {
        return;
    }

    std::vector<float> tempInput(input, input + length);
    if (tempInput.size() != fftSize) {
        tempInput.resize(fftSize, 0.0f);
    }
    applyWindow(tempInput.data(), fftSize);

    // SAFER: real-to-split conversion
    vDSP_ctoz(reinterpret_cast<const DSPComplex*>(tempInput.data()), 2, &splitComplex, 1, fftSize / 2);

    std::fill(imagp, imagp + fftSize, 0.0f);
    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFT_FORWARD);

    vDSP_zvmags(&splitComplex, 1, magnitudes.data(), 1, fftSize);

    float scale = 1.0f / static_cast<float>(fftSize);
    vDSP_vsmul(magnitudes.data(), 1, &scale, magnitudes.data(), 1, fftSize);
    size_t fftSizeHalf = fftSize;
    vvsqrtf(magnitudes.data(), magnitudes.data(), (int *)&fftSizeHalf);
    for (float& mag : magnitudes) {
        mag = std::max(mag, 1e-10f);
    }
    for (float& mag : magnitudes) {
        if (std::isnan(mag) || std::isinf(mag)) {
            mag = 0.0f;
        }
    }

    for (size_t i = 0; i < magnitudes.size(); ++i) {
        peakMagnitudes[i] = std::max(peakMagnitudes[i], magnitudes[i]);
    }
}

const std::vector<float>& ChannelFFTSpectrum::getPeakMagnitudes() const {
    return magnitudes;
}
