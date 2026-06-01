#if os(macOS)
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

public enum HardwareEnvironmentEvent: Sendable {
    case systemWillSleep
    case systemDidWake
}

public protocol HardwareEnvironmentObserving: AnyObject, Sendable {
    var currentDisplayCount: Int? { get }
    func startObserving(eventHandler: @escaping @Sendable (HardwareEnvironmentEvent) -> Void)
    func stopObserving()
}

public final class SystemHardwareEnvironmentObserver: HardwareEnvironmentObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var notificationPort: IONotificationPortRef?
    private var notificationRunLoopSource: CFRunLoopSource?
    private var rootPowerPort: io_connect_t = 0
    private var notifierObject: io_object_t = 0
    private var eventHandler: (@Sendable (HardwareEnvironmentEvent) -> Void)?

    public init() {}

    deinit {
        stopObserving()
    }

    public var currentDisplayCount: Int? {
        Self.onlineDisplayCount()
    }

    public func startObserving(eventHandler: @escaping @Sendable (HardwareEnvironmentEvent) -> Void) {
        stopObserving()

        lock.lock()
        self.eventHandler = eventHandler
        lock.unlock()

        var notificationPort: IONotificationPortRef?
        var notifierObject: io_object_t = 0
        let rootPowerPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notificationPort,
            hardwareSystemPowerCallback,
            &notifierObject
        )

        guard rootPowerPort != 0, let notificationPort else {
            lock.lock()
            self.eventHandler = nil
            lock.unlock()
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        lock.lock()
        self.notificationPort = notificationPort
        notificationRunLoopSource = runLoopSource
        self.rootPowerPort = rootPowerPort
        self.notifierObject = notifierObject
        lock.unlock()
    }

    public func stopObserving() {
        let notificationPort: IONotificationPortRef?
        let notificationRunLoopSource: CFRunLoopSource?
        var notifierObject: io_object_t = 0
        let rootPowerPort: io_connect_t

        lock.lock()
        notificationPort = self.notificationPort
        notificationRunLoopSource = self.notificationRunLoopSource
        notifierObject = self.notifierObject
        rootPowerPort = self.rootPowerPort
        self.notificationPort = nil
        self.notificationRunLoopSource = nil
        self.notifierObject = 0
        self.rootPowerPort = 0
        eventHandler = nil
        lock.unlock()

        if let notificationRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationRunLoopSource, .commonModes)
        }
        if notifierObject != 0 {
            IODeregisterForSystemPower(&notifierObject)
        }
        if rootPowerPort != 0 {
            IOServiceClose(rootPowerPort)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
    }

    fileprivate func handleSystemPowerMessage(
        type messageType: natural_t,
        argument: UnsafeMutableRawPointer?
    ) {
        let eventHandler: (@Sendable (HardwareEnvironmentEvent) -> Void)?
        let rootPowerPort: io_connect_t

        lock.lock()
        eventHandler = self.eventHandler
        rootPowerPort = self.rootPowerPort
        lock.unlock()

        switch messageType {
        case Self.canSystemSleepMessage, Self.systemWillSleepMessage:
            if rootPowerPort != 0 {
                IOAllowPowerChange(rootPowerPort, Self.notificationID(from: argument))
            }
            if messageType == Self.systemWillSleepMessage {
                eventHandler?(.systemWillSleep)
            }
        case Self.systemHasPoweredOnMessage:
            eventHandler?(.systemDidWake)
        default:
            break
        }
    }

    private static func notificationID(from pointer: UnsafeMutableRawPointer?) -> Int {
        guard let pointer else { return 0 }
        return Int(bitPattern: pointer)
    }

    private static func onlineDisplayCount() -> Int? {
        var displayCount: UInt32 = 0
        let result = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard result == .success else { return nil }
        return Int(displayCount)
    }

    // These user-space sleep/wake messages are C macros in IOMessage.h that
    // do not import into Swift directly, so we mirror the stable encoded values.
    private static let canSystemSleepMessage: natural_t = 0xE000_0270
    private static let systemWillSleepMessage: natural_t = 0xE000_0280
    private static let systemHasPoweredOnMessage: natural_t = 0xE000_0300
}

private let hardwareSystemPowerCallback: IOServiceInterestCallback = { refCon, _, messageType, messageArgument in
    guard let refCon else { return }
    let observer = Unmanaged<SystemHardwareEnvironmentObserver>.fromOpaque(refCon).takeUnretainedValue()
    observer.handleSystemPowerMessage(type: messageType, argument: messageArgument)
}

#endif