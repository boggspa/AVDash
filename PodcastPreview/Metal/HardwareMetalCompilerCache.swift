import Metal
import MetalKit

public enum HardwareMetalBlendingMode: Int {
    case opaque = 0
    case alphaBlend = 1
    case preMultipliedAlpha = 2
}

final class HardwareMetalCompilerCache {
    static let shared = HardwareMetalCompilerCache()

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    private let library: MTLLibrary?

    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var computePipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    private init() {
        let defaultDevice = MTLCreateSystemDefaultDevice()
        self.device = defaultDevice
        self.commandQueue = defaultDevice?.makeCommandQueue()
        self.library = defaultDevice?.makeDefaultLibrary()
    }

    func computePipelineState(functionName: String) -> MTLComputePipelineState? {
        guard let device = device else { return nil }

        lock.lock()
        if let existing = computePipelines[functionName] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let library = library,
              let function = library.makeFunction(name: functionName) else {
            return nil
        }

        do {
            let state = try device.makeComputePipelineState(function: function)
            lock.lock()
            computePipelines[functionName] = state
            lock.unlock()
            return state
        } catch {
            return nil
        }
    }

    func pipelineState(
        vertexFunctionName: String,
        fragmentFunctionName: String,
        pixelFormat: MTLPixelFormat,
        blendingMode: HardwareMetalBlendingMode
    ) -> MTLRenderPipelineState? {
        guard let device = device else { return nil }

        let cacheKey = "\(vertexFunctionName)-\(fragmentFunctionName)-\(pixelFormat.rawValue)-\(blendingMode.rawValue)"

        lock.lock()
        if let existing = pipelines[cacheKey] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let library = library,
              let vertexFunction = library.makeFunction(name: vertexFunctionName),
              let fragmentFunction = library.makeFunction(name: fragmentFunctionName) else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        if blendingMode != .opaque, let ca = descriptor.colorAttachments[0] {
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            if blendingMode == .preMultipliedAlpha {
                // keep alpha at 1 over an opaque clear
                ca.sourceAlphaBlendFactor = .one
            } else {
                ca.sourceAlphaBlendFactor = .sourceAlpha
            }
        }

        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            lock.lock()
            pipelines[cacheKey] = state
            lock.unlock()
            return state
        } catch {
            return nil
        }
    }
}
