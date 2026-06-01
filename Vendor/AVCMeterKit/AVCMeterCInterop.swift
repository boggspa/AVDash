import CoreAudio
import AudioToolbox

struct RingBuffer {}
struct PCMRingBuffer {}
struct FFTBuffer {}
struct HALInputStream {}
struct HALInputStreamDevice {}
struct PCMInputStream {}
struct PCMStream {}
struct SharedRingBuffer {}

typealias FFTInputStream = OpaquePointer

struct OutputChannelRingBuffer {
    var buffer: UnsafeMutablePointer<Float>? = nil
    var writeIndex: UInt = 0
    var readIndex: UInt = 0
    var size: UInt = 0
}

struct MixerEQConfig {
    var enabled: UInt32 = 0
    var highPassEnabled: UInt32 = 0
    var highPassFilterType: UInt32 = 0
    var highPassSlope: UInt32 = 0
    var highPassFrequencyHz: Float = 0

    var lowEnabled: UInt32 = 0
    var lowFilterType: UInt32 = 0
    var lowSlope: UInt32 = 0
    var lowGainDB: Float = 0
    var lowCenterFrequencyHz: Float = 0
    var lowQ: Float = 0

    var lowMidEnabled: UInt32 = 0
    var lowMidFilterType: UInt32 = 0
    var lowMidSlope: UInt32 = 0
    var lowMidGainDB: Float = 0
    var lowMidCenterFrequencyHz: Float = 0
    var lowMidQ: Float = 0

    var midEnabled: UInt32 = 0
    var midFilterType: UInt32 = 0
    var midSlope: UInt32 = 0
    var midGainDB: Float = 0
    var midCenterFrequencyHz: Float = 0
    var midQ: Float = 0

    var presenceEnabled: UInt32 = 0
    var presenceFilterType: UInt32 = 0
    var presenceSlope: UInt32 = 0
    var presenceGainDB: Float = 0
    var presenceCenterFrequencyHz: Float = 0
    var presenceQ: Float = 0

    var highEnabled: UInt32 = 0
    var highFilterType: UInt32 = 0
    var highSlope: UInt32 = 0
    var highGainDB: Float = 0
    var highCenterFrequencyHz: Float = 0
    var highQ: Float = 0

    var lowPassEnabled: UInt32 = 0
    var lowPassFilterType: UInt32 = 0
    var lowPassSlope: UInt32 = 0
    var lowPassFrequencyHz: Float = 0
}

struct MixerDynamicsConfig {
    var enabled: UInt32 = 0
    var thresholdDB: Float = 0
    var ratio: Float = 0
    var attackMilliseconds: Float = 0
    var releaseMilliseconds: Float = 0
    var makeupGainDB: Float = 0
    var mix: Float = 0
    var limiterEnabled: UInt32 = 0
    var limiterCeilingDB: Float = 0
}

typealias MeteringCallback = @convention(c) (
    UnsafePointer<Float>?,
    UnsafePointer<Float>?,
    Int32,
    AudioDeviceID,
    UnsafeMutableRawPointer?
) -> Void

@_silgen_name("createRingBuffer")
func createRingBuffer(_ capacity: Int32) -> UnsafeMutablePointer<RingBuffer>?

@_silgen_name("destroyRingBuffer")
func destroyRingBuffer(_ rb: UnsafeMutablePointer<RingBuffer>?)

@_silgen_name("writeRingBuffer")
func writeRingBuffer(_ rb: UnsafeMutablePointer<RingBuffer>, _ value: Float)

@_silgen_name("averageRingBuffer")
func averageRingBuffer(_ rb: UnsafeMutablePointer<RingBuffer>) -> Float

@_silgen_name("clearRingBuffer")
func clearRingBuffer(_ rb: UnsafeMutablePointer<RingBuffer>)

@_silgen_name("ringbuffer_read")
func ringbuffer_read(_ rb: UnsafeMutablePointer<RingBuffer>, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("ringbuffer_read_latest")
func ringbuffer_read_latest(_ rb: UnsafeMutablePointer<RingBuffer>, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("ringbuffer_read_all")
func ringbuffer_read_all(_ rb: UnsafeMutablePointer<RingBuffer>, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32)

@_silgen_name("RingBuffer_GlobalInit")
func RingBuffer_GlobalInit()

@_silgen_name("RingBuffer_SetPostGain")
func RingBuffer_SetPostGain(_ channel: Int32, _ gain: Float)

@_silgen_name("getAllInputAudioDeviceIDs")
func getAllInputAudioDeviceIDs(_ outDevices: UnsafeMutablePointer<AudioDeviceID>?, _ maxDevices: Int32) -> Int32

@_silgen_name("getDeviceName")
func getDeviceName(_ deviceID: AudioDeviceID) -> UnsafePointer<CChar>!

@_silgen_name("getSampleRate")
func getSampleRate(_ deviceID: AudioDeviceID) -> Float64

@_silgen_name("getDeviceTransportType")
func getDeviceTransportType(_ deviceID: AudioDeviceID) -> UnsafePointer<CChar>!

@_silgen_name("getDeviceInputChannelCount")
func getDeviceInputChannelCount(_ deviceID: AudioDeviceID) -> UInt32

@_silgen_name("getDeviceOutputChannelCount")
func getDeviceOutputChannelCount(_ deviceID: AudioDeviceID) -> UInt32

@_silgen_name("startMeteringWithCallback")
func startMeteringWithCallback(
    _ deviceID: AudioDeviceID,
    _ callback: @escaping MeteringCallback,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus

@_silgen_name("stopMetering")
func stopMetering(_ deviceID: AudioDeviceID) -> OSStatus

@_silgen_name("ChannelSpectrumBridge_ProcessSamples")
func ChannelSpectrumBridge_ProcessSamples(_ deviceID: AudioDeviceID, _ channel: Int32, _ samples: UnsafeMutablePointer<Float>, _ length: Int32)

@_silgen_name("ChannelSpectrumBridge_getPeakMagnitudes")
func ChannelSpectrumBridge_getPeakMagnitudes(_ deviceID: AudioDeviceID, _ channel: Int32, _ outLength: UnsafeMutablePointer<Int32>) -> UnsafePointer<Float>!
