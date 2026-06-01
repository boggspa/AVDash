//
//  AudioEngine.h
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdbool.h>
#include "RingBuffer.h"

// MeteringDSP integration
#include <stddef.h>
#include <stdint.h>

typedef struct {
    float peak;
    float rms;
} MeteringResult;

// Computes peak and RMS over the latest frames from the ring buffer for a channel.
// Returns 0 on success, otherwise <0.
int MeteringDSP_Compute(RingBuffer *rb, uint32_t channel, size_t frames, MeteringResult *outMetering);

// Set metering calibration in dB (applied in MeteringDSP before computing peak/RMS)
void MeteringDSP_SetCalibrationDB(float db);


// FFT analyser API
// Configure the global FFT analyser with the desired FFT size and sample rate.
void FFTAnalyser_Configure(size_t fftSize, double sampleRate);

// Compute a magnitude spectrum (in dB) for the given channel into outMagnitudes.
// outCount is the number of visual bins you want (e.g. 64); values are clamped
// to the range [-60 dB, +10 dB] and only cover approximately 20 Hz–20 kHz.
// Returns 0 on success, <0 on error.
int FFTAnalyser_Compute(RingBuffer *rb, uint32_t channel, float *outMagnitudes, size_t outCount);

// Set an additional dB offset applied only to the FFT spectrum output.
// Positive values make the spectrum more sensitive (appear hotter),
// negative values reduce sensitivity.
void FFTAnalyser_SetSensitivityDB(float db);

// Set metering calibration in dB (applied in FFTAnalyser before computing spectrum).
// This should match the calibration applied to metering for consistency.
void FFTAnalyser_SetCalibrationDB(float db);

// Set window type: 0 = Hann (default), 1 = Flat-Top
void FFTAnalyser_SetWindowType(int type);

// Set frequency range for spectrum display (in Hz)
// Default is 20 Hz to 20,000 Hz. Lower minHz to see more low-frequency content.
void FFTAnalyser_SetFrequencyRange(double minHz, double maxHz);

// Set which channel to analyze in the spectrum (thread-safe, lock-free)
void FFTAnalyser_SetSelectedChannel(uint32_t channel);

// Get current selected channel (thread-safe, lock-free)
uint32_t FFTAnalyser_GetSelectedChannel(void);

// Initialize and start the audio engine for a given device.
// bufferSizeFrames: the size of the ring buffer to allocate
// inputChannels/outputChannels: your expected channel config for the device
// Returns 0 on success, <0 on failure.
int AudioEngine_Start(AudioDeviceID deviceID, unsigned int bufferSizeFrames, unsigned int inputChannels, unsigned int outputChannels);

// Stop the audio engine and free resources.
void AudioEngine_Stop(void);

// Get the currently active device ID.
AudioDeviceID AudioEngine_GetCurrentDevice(void);

// Returns true if the audio engine is running.
bool AudioEngine_IsRunning(void);

// Returns the current engine ring buffer pointer for metering/FFT access.
RingBuffer *AudioEngine_GetRingBuffer(void);

// The following RingBuffer API is also available for direct use in Swift if needed.
// See RingBuffer.h for details.

// AudioDevices C API (input device enumeration and lookup)
UInt32 AudioDevices_GetAllInputDevices(AudioDeviceID *outDevices, UInt32 maxDevices);
UInt32 AudioDevices_GetAllOutputDevices(AudioDeviceID *outDevices, UInt32 maxDevices);
AudioDeviceID AudioDevices_GetDefaultInputDevice(void);
AudioDeviceID AudioDevices_GetDefaultOutputDevice(void);
OSStatus AudioDevices_GetDeviceName(AudioDeviceID deviceID, char *outName, UInt32 maxLen);
OSStatus AudioDevices_GetDeviceUID(AudioDeviceID deviceID, char *outUID, UInt32 maxLen);
AudioDeviceID AudioDevices_FindDeviceByUID(const char *uidCString);
UInt32 AudioDevices_GetInputChannelCount(AudioDeviceID deviceID);
UInt32 AudioDevices_GetOutputChannelCount(AudioDeviceID deviceID);

// Extra device metadata helpers
double AudioDevices_GetDeviceSampleRate(AudioDeviceID deviceID);
OSStatus AudioDevices_SetDeviceSampleRate(AudioDeviceID deviceID, double sampleRate);
OSStatus AudioDevices_SetDeviceSampleRateByUID(const char *uidCString, double sampleRate);
OSStatus AudioDevices_GetDeviceManufacturer(AudioDeviceID deviceID, char *outName, UInt32 maxLen);
UInt32 AudioDevices_GetDeviceTransportType(AudioDeviceID deviceID);

#ifdef __cplusplus
extern "C" {
#endif


#ifdef __cplusplus
}
#endif
