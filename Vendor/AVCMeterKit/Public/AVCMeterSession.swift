import Foundation
import Combine

@MainActor
public final class AVCMeterSession: ObservableObject {
    public let configuration: AVCMeterConfiguration

    @Published public private(set) var isRunning = false

    private var didInitialize = false

    public init(configuration: AVCMeterConfiguration = .init()) {
        self.configuration = configuration
    }

    public func start() {
        if !didInitialize {
            RingBuffer_GlobalInit()
            didInitialize = true
        }

        if !isRunning {
            ChannelStateManager.shared.nudgeAllPanValues()
            isRunning = true
        }
    }

    public func stop() {
        isRunning = false
    }
}
