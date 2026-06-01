//
//  FFTAnalyser.c
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

#include "AudioEngine.h"
#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

// Simple global analyser state (one shared analyser for now)
static FFTSetup gFFTSetup = NULL;
static DSPSplitComplex gSplit = {0};
static float *gWindow = NULL;
static float *gTempBuffer = NULL;
static size_t gFFTSize = 0;
static size_t gLog2N = 0;
static double gSampleRate = 48000.0;

static float gWindowSum = 0.0f;
static float gAmpScale = 1.0f;   // amplitude normalization scale based on window
static float gPowerScale = 1.0f; // power normalization scale (gAmpScale^2)
static float gSpectrumSensitivityDB = 0.0f; // additional dB offset applied to spectrum only
static int   gWindowType = 0;    // 0 = Hann (default), 1 = FlatTop
static float gFFTCalibrationGain = 1.0f; // calibration gain applied before FFT (linear)

// Configurable frequency range for spectrum display
static double gMinFreqHz = 20.0;   // default 20 Hz
static double gMaxFreqHz = 20000.0; // default 20 kHz

// Reusable power buffer to avoid repeated allocations
static float *gPowerBuffer = NULL;

// Thread-safe channel selection using atomic
static _Atomic uint32_t gSelectedChannel = 0;

// Precomputed band-to-bin mapping for the spectrum visualisation.
// Each band corresponds to a range of FFT bins [binLo, binHi].
typedef struct {
    size_t binLo;
    size_t binHi;
} FFTBandRange;

static FFTBandRange *gBandRanges = NULL;
static size_t gBandRangeCount = 0;
static size_t gBandLastOutCount = 0;
static double gBandLastSampleRate = 0.0;
static size_t gBandLastFFTSize = 0;
static size_t gBandLastMinBin = 0;
static size_t gBandLastMaxBin = 0;
static void FFTAnalyser_EnsureBandMap(size_t outCount, double binHz, size_t minBin, size_t maxBin);

static void FFTAnalyser_BuildWindowAndScales(void) {
    if (!gWindow || gFFTSize == 0) { return; }

    // Build selected window
    if (gWindowType == 1) {
        // 5-term flat-top (Harris)
        const double a0 = 1.0;
        const double a1 = 1.93;
        const double a2 = 1.29;
        const double a3 = 0.388;
        const double a4 = 0.028;
        for (size_t n = 0; n < gFFTSize; ++n) {
            double x = (2.0 * M_PI * n) / (double)(gFFTSize - 1);
            gWindow[n] = (float)(a0
                                 - a1 * cos(x)
                                 + a2 * cos(2.0 * x)
                                 - a3 * cos(3.0 * x)
                                 + a4 * cos(4.0 * x));
        }
    } else {
        // Hann (normalized)
        vDSP_hann_window(gWindow, gFFTSize, vDSP_HANN_NORM);
    }

    // Compute window sum and derive amplitude normalization scale.
    double sum = 0.0;
    for (size_t i = 0; i < gFFTSize; ++i) sum += gWindow[i];
    gWindowSum = (float)sum;

    // Coherent gain approximation via sum; derive amplitude normalization
    if (gWindowSum > 0.0f) {
        // Normalize by window coherent gain only; single-sided correction is applied later per-bin.
        gAmpScale = 1.0f / gWindowSum;
    } else {
        gAmpScale = 1.0f;
    }
    gPowerScale = gAmpScale * gAmpScale;
}

void FFTAnalyser_SetSensitivityDB(float db) {
    gSpectrumSensitivityDB = db;
}

void FFTAnalyser_SetCalibrationDB(float db) {
    // Convert dB to linear gain (same as MeteringDSP)
    gFFTCalibrationGain = powf(10.0f, db / 20.0f);
}

void FFTAnalyser_SetWindowType(int type) {
    gWindowType = (type == 1) ? 1 : 0;
    FFTAnalyser_BuildWindowAndScales();
}

void FFTAnalyser_SetFrequencyRange(double minHz, double maxHz) {
    // Validate and clamp to reasonable bounds
    if (minHz < 1.0) minHz = 1.0;
    if (maxHz > gSampleRate / 2.0) maxHz = gSampleRate / 2.0;
    if (maxHz <= minHz) maxHz = minHz + 100.0;
    
    gMinFreqHz = minHz;
    gMaxFreqHz = maxHz;
    
    // Force band map rebuild on next compute by invalidating cached state
    gBandLastSampleRate = 0.0;
}

// Set which channel to analyze (thread-safe)
void FFTAnalyser_SetSelectedChannel(uint32_t channel) {
    atomic_store_explicit(&gSelectedChannel, channel, memory_order_relaxed);
}

// Get current selected channel (thread-safe)
uint32_t FFTAnalyser_GetSelectedChannel(void) {
    return atomic_load_explicit(&gSelectedChannel, memory_order_relaxed);
}

static void FFTAnalyser_Cleanup(void) {
    if (gFFTSetup) {
        vDSP_destroy_fftsetup(gFFTSetup);
        gFFTSetup = NULL;
    }
    if (gSplit.realp) {
        free(gSplit.realp);
        gSplit.realp = NULL;
    }
    if (gSplit.imagp) {
        free(gSplit.imagp);
        gSplit.imagp = NULL;
    }
    if (gWindow) {
        free(gWindow);
        gWindow = NULL;
    }
    if (gTempBuffer) {
        free(gTempBuffer);
        gTempBuffer = NULL;
    }
    if (gPowerBuffer) {
        free(gPowerBuffer);
        gPowerBuffer = NULL;
    }

    gWindowSum = 0.0f;
    gAmpScale = 1.0f;
    gPowerScale = 1.0f;
    gSpectrumSensitivityDB = 0.0f;
    gWindowType = 0;
    gFFTCalibrationGain = 1.0f;
    gMinFreqHz = 20.0;
    gMaxFreqHz = 20000.0;

    if (gBandRanges) {
        free(gBandRanges);
        gBandRanges = NULL;
    }
    gBandRangeCount = 0;
    gBandLastOutCount = 0;
    gBandLastSampleRate = 0.0;
    gBandLastFFTSize = 0;
    gBandLastMinBin = 0;
    gBandLastMaxBin = 0;
    gFFTSize = 0;
    gLog2N = 0;
}

// Configure FFT size and sample rate
void FFTAnalyser_Configure(size_t fftSize, double sampleRate) {
    if (fftSize == 0) return;

    // Only powers of two are valid for vDSP_fft_zrip
    size_t n = fftSize;
    size_t log2n = 0;
    while ((1u << log2n) < n) {
        log2n++;
    }
    if ((1u << log2n) != n) {
        // Not a power of two; clamp to nearest lower power
        n = (size_t)1u << (log2n - 1);
        log2n -= 1;
    }

    // If configuration is unchanged, nothing to do
    if (gFFTSize == n && fabs(sampleRate - gSampleRate) < 1.0) {
        return;
    }

    FFTAnalyser_Cleanup();

    gFFTSize = n;
    gLog2N = log2n;
    gSampleRate = (sampleRate > 0.0) ? sampleRate : 48000.0;

    // Allocate FFT setup
    gFFTSetup = vDSP_create_fftsetup((vDSP_Length)gLog2N, kFFTRadix2);
    if (!gFFTSetup) {
        FFTAnalyser_Cleanup();
        return;
    }

    // Allocate split-complex buffers (N/2 complex bins)
    size_t halfN = gFFTSize / 2;
    gSplit.realp = (float *)calloc(halfN, sizeof(float));
    gSplit.imagp = (float *)calloc(halfN, sizeof(float));
    if (!gSplit.realp || !gSplit.imagp) {
        FFTAnalyser_Cleanup();
        return;
    }

    // Allocate Hann window and temp buffer
    gWindow = (float *)calloc(gFFTSize, sizeof(float));
    gTempBuffer = (float *)calloc(gFFTSize, sizeof(float));
    gPowerBuffer = (float *)calloc(halfN, sizeof(float));  // Reusable power buffer
    if (!gWindow || !gTempBuffer || !gPowerBuffer) {
        FFTAnalyser_Cleanup();
        return;
    }

    // Build window and normalization scales according to current window type
    FFTAnalyser_BuildWindowAndScales();
}

static void FFTAnalyser_EnsureBandMap(size_t outCount, double binHz, size_t minBin, size_t maxBin) {
    // Rebuild only if configuration changed or no existing map
    int needsRebuild = 0;
    if (!gBandRanges) {
        needsRebuild = 1;
    } else if (gBandRangeCount != outCount) {
        needsRebuild = 1;
    } else if (gBandLastSampleRate != gSampleRate) {
        needsRebuild = 1;
    } else if (gBandLastFFTSize != gFFTSize) {
        needsRebuild = 1;
    } else if (gBandLastMinBin != minBin || gBandLastMaxBin != maxBin) {
        needsRebuild = 1;
    }

    if (!needsRebuild) {
        return;
    }

    // Free any existing map
    if (gBandRanges) {
        free(gBandRanges);
        gBandRanges = NULL;
    }
    gBandRangeCount = 0;

    if (outCount == 0 || binHz <= 0.0) {
        return;
    }

    // Allocate new ranges
    gBandRanges = (FFTBandRange *)calloc(outCount, sizeof(FFTBandRange));
    if (!gBandRanges) {
        return;
    }

    // Determine frequency bounds for mapping
    // Use the actual configured min/max frequencies (gMinFreqHz, gMaxFreqHz)
    // instead of computing from bins to ensure exact range coverage
    double fMin = gMinFreqHz;
    double fMax = gMaxFreqHz;
    
    // Clamp to valid Nyquist bounds
    if (fMin < binHz) {
        fMin = binHz; // avoid log(0) and ensure we're above DC
    }
    if (fMax > gSampleRate / 2.0) {
        fMax = gSampleRate / 2.0;
    }
    if (fMax < fMin) {
        fMax = fMin;
    }

    // Precompute logs for logarithmic spacing using log10 (base-10)
    // This matches professional DAW analyzers (Logic Pro, Pro Tools, etc.)
    // and creates a more intuitive frequency distribution where 1 kHz appears near center
    double log10FMin = log10(fMin);
    double log10FMax = log10(fMax);
    double log10Range = (log10FMax - log10FMin);
    if (log10Range <= 0.0) {
        log10Range = 1.0; // fallback to avoid division by zero
    }

    // Compute logarithmically-spaced frequency bands
    // Each band represents a frequency range that grows exponentially
    for (size_t i = 0; i < outCount; ++i) {
        // Calculate the frequency boundaries for this band using log10 spacing
        double tLo = (double)i / (double)outCount;
        double tHi = (double)(i + 1) / (double)outCount;

        // Use pow(10, x) for base-10 logarithmic spacing (matches professional EQs)
        double fLo = pow(10.0, log10FMin + tLo * log10Range);
        double fHi = pow(10.0, log10FMin + tHi * log10Range);

        // Convert frequencies to bin indices
        // Use round() instead of ceil/floor for more accurate center-frequency mapping
        size_t binLo = (size_t)round(fLo / binHz);
        size_t binHi = (size_t)round(fHi / binHz);

        // Clamp to valid FFT bin range
        if (binLo < minBin) binLo = minBin;
        if (binHi > maxBin) binHi = maxBin;
        
        // Ensure each band has at least one bin
        if (binHi < binLo) binHi = binLo;

        gBandRanges[i].binLo = binLo;
        gBandRanges[i].binHi = binHi;
    }

    // REMOVED: The "gap-filling" second pass was destroying the logarithmic spacing!
    // It's OK for bands to overlap or have gaps - we're mapping continuous frequency
    // ranges to discrete bins, so some quantization is expected and correct.

    gBandRangeCount = outCount;
    gBandLastOutCount = outCount;
    gBandLastSampleRate = gSampleRate;
    gBandLastFFTSize = gFFTSize;
    gBandLastMinBin = minBin;
    gBandLastMaxBin = maxBin;

#if DEBUG
    // Debug: Log the first and last few bands to verify frequency coverage
    if (outCount > 0 && binHz > 0.0) {
        // First band
        double firstFreqLo = gBandRanges[0].binLo * binHz;
        double firstFreqHi = gBandRanges[0].binHi * binHz;
        // Last band
        double lastFreqLo = gBandRanges[outCount-1].binLo * binHz;
        double lastFreqHi = gBandRanges[outCount-1].binHi * binHz;
        
        fprintf(stderr, "[FFT Band Map] First band: %.1f-%.1f Hz (bins %zu-%zu)\n",
                firstFreqLo, firstFreqHi, gBandRanges[0].binLo, gBandRanges[0].binHi);
        fprintf(stderr, "[FFT Band Map] Last band: %.1f-%.1f Hz (bins %zu-%zu)\n",
                lastFreqLo, lastFreqHi, gBandRanges[outCount-1].binLo, gBandRanges[outCount-1].binHi);
        fprintf(stderr, "[FFT Band Map] Target range: %.1f-%.1f Hz (%.1f Hz/bin, %zu bins total)\n",
                gMinFreqHz, gMaxFreqHz, binHz, outCount);
    }
#endif
}

// Compute a downsampled magnitude spectrum in dB
int FFTAnalyser_Compute(RingBuffer *rb, uint32_t channel, float *outMagnitudes, size_t outCount) {
    if (!rb || !outMagnitudes || outCount == 0) return -1;
    if (gFFTSize == 0 || !gFFTSetup || !gWindow || !gTempBuffer || !gSplit.realp || !gSplit.imagp) {
        return -2;
    }

    // Read the latest gFFTSize samples for the requested channel
    size_t framesRead = RingBuffer_Read(rb, gTempBuffer, gFFTSize, channel);
    if (framesRead == 0) return -3;

    // If we got fewer frames than requested, zero-pad the rest to avoid analyzing stale data
    if (framesRead < gFFTSize) {
        memset(gTempBuffer + framesRead, 0, (gFFTSize - framesRead) * sizeof(float));
    }

    // Apply calibration gain (BEFORE windowing, to match MeteringDSP behavior)
    if (gFFTCalibrationGain != 1.0f) {
        vDSP_vsmul(gTempBuffer, 1, &gFFTCalibrationGain, gTempBuffer, 1, gFFTSize);
    }

    // OPTIONAL: Apply high-pass filter to remove DC and subsonic content (< 10 Hz)
    // This prevents DC offset and low-frequency rumble from causing spectral leakage
    // Simple first-order HPF: y[n] = alpha * (y[n-1] + x[n] - x[n-1])
    // where alpha = 1 / (1 + 2*pi*fc/fs)
    // For fc=10Hz at fs=48kHz: alpha ≈ 0.9987
    // Uncomment the following lines to enable DC removal:
    /*
    const float hpfAlpha = 0.9987f;
    float prev_x = gTempBuffer[0];
    float prev_y = 0.0f;
    for (size_t i = 0; i < gFFTSize; ++i) {
        float x = gTempBuffer[i];
        float y = hpfAlpha * (prev_y + x - prev_x);
        gTempBuffer[i] = y;
        prev_x = x;
        prev_y = y;
    }
    */

    // Apply window
    vDSP_vmul(gTempBuffer, 1, gWindow, 1, gTempBuffer, 1, gFFTSize);

    // Pack real input into split-complex format for in-place FFT
    size_t halfN = gFFTSize / 2;
    vDSP_ctoz((DSPComplex *)gTempBuffer, 2, &gSplit, 1, halfN);

    // Perform in-place forward FFT
    vDSP_fft_zrip(gFFTSetup, &gSplit, 1, (vDSP_Length)gLog2N, kFFTDirection_Forward);

    // Compute magnitudes squared (power) for each bin
    // Use pre-allocated global buffer to avoid malloc/free overhead
    static const float kEpsilon = 1e-12f;
    if (!gPowerBuffer) return -4;
    vDSP_zvmags(&gSplit, 1, gPowerBuffer, 1, halfN); // mag^2 (power)

    // Force DC and very low bins to zero to prevent DC offset and subsonic rumble
    // from causing spectral leakage into visible spectrum
    gPowerBuffer[0] = 0.0f;  // DC bin
    
    // Only zero bins below 5 Hz (reduced from 10 Hz to preserve low-end visibility)
    // This removes only DC and extreme subsonic content
    double binHz = (gFFTSize > 0) ? (gSampleRate / (double)gFFTSize) : 0.0;
    if (binHz > 0.0) {
        size_t numSubsonicBins = (size_t)floor(5.0 / binHz);  // Changed from 10.0 to 5.0
        for (size_t b = 0; b <= numSubsonicBins && b < halfN; ++b) {
            gPowerBuffer[b] = 0.0f;
        }
    }

    // Use configurable frequency range for display
    size_t minBin = 0;
    size_t maxBin = halfN - 1;

    if (binHz > 0.0) {
        minBin = (size_t)ceil(gMinFreqHz / binHz);
        maxBin = (size_t)floor(gMaxFreqHz / binHz);
        if (minBin > halfN - 1) minBin = halfN - 1;
        if (maxBin > halfN - 1) maxBin = halfN - 1;
        if (maxBin < minBin) maxBin = minBin;
    }

    size_t usableBins = maxBin - minBin + 1;
    if (usableBins == 0) usableBins = halfN;

    float minDB = -120.0f;
    float maxDB =  0.0f;

    if (binHz <= 0.0) {
        return -5;
    }

    // Single-sided: double interior bins (exclude DC and Nyquist)
    if (halfN >= 2) {
        for (size_t b = 1; b < halfN - 1; ++b) {
            gPowerBuffer[b] *= 2.0f;
        }
    }

    // Apply amplitude normalization in power domain
    if (gPowerScale != 1.0f) {
        float pscale = gPowerScale;
        vDSP_vsmul(gPowerBuffer, 1, &pscale, gPowerBuffer, 1, halfN);
    }

    // Ensure we have a precomputed band map for this configuration.
    FFTAnalyser_EnsureBandMap(outCount, binHz, minBin, maxBin);
    if (!gBandRanges || gBandRangeCount != outCount) {
        return -6;
    }

    for (size_t i = 0; i < outCount; ++i) {
        FFTBandRange br = gBandRanges[i];

        // Average power across bins in [br.binLo, br.binHi]
        double sumPower = 0.0;
        size_t count = 0;
        for (size_t b = br.binLo; b <= br.binHi; ++b) {
            sumPower += gPowerBuffer[b];
            count++;
        }

        float db;
        if (count > 0) {
            float meanPower = (float)(sumPower / (double)count);
            float magRMS = sqrtf(meanPower);
            db = 20.0f * log10f(magRMS + kEpsilon);
        } else {
            db = minDB;
        }

        // Apply optional spectrum sensitivity (negative values reduce sensitivity)
        db += gSpectrumSensitivityDB;

        if (db < minDB) db = minDB;
        if (db > maxDB) db = maxDB;
        outMagnitudes[i] = db;
    }

    return 0;
}

