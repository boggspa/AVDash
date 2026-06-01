import Foundation
import CoreMIDI
import Combine
#if os(macOS)
import AppKit
#endif

/// Manages MIDI device enumeration and state notifications.
/// Operates independently from the audio polling engine to avoid hot-path interference.
final class MIDIStateManager: ObservableObject {
    private static let midiQueueKey = DispatchSpecificKey<Bool>()

    @Published var availableDevices: [MIDIDeviceModel] = []

    // Tracks current routing intent: SourceEndpointName -> TargetEndpointName
    private var activeRoutes: [String: String] = [:]

    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private let midiQueue = DispatchQueue(label: "com.avcmeter.MIDIStateManager", qos: .utility)
    private var callbackBox: UnsafeMutableRawPointer?
    private var connectedSources = Set<MIDIEndpointRef>()
    private var refreshWorkItem: DispatchWorkItem?
    private var isDisposed = false
    #if os(macOS)
    private var sleepWakeObservers: [NSObjectProtocol] = []
    #endif

    init() {
        midiQueue.setSpecific(key: Self.midiQueueKey, value: true)
        setupMIDIClient()
        registerSleepWakeObservers()
        refreshDevices()
    }

    deinit {
        #if os(macOS)
        for observer in sleepWakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        #endif

        if let callbackBox {
            Unmanaged<MIDIStateManagerCallbackBox>.fromOpaque(callbackBox).takeUnretainedValue().manager = nil
        }

        let disposeMIDIResources = { [self] in
            self.isDisposed = true
            self.refreshWorkItem?.cancel()
            self.refreshWorkItem = nil
            self.connectedSources.removeAll()

            if self.inputPort != 0 {
                MIDIPortDispose(self.inputPort)
                self.inputPort = 0
            }

            if self.outputPort != 0 {
                MIDIPortDispose(self.outputPort)
                self.outputPort = 0
            }

            if self.midiClient != 0 {
                MIDIClientDispose(self.midiClient)
                self.midiClient = 0
            }
        }

        if DispatchQueue.getSpecific(key: Self.midiQueueKey) == true {
            disposeMIDIResources()
        } else {
            midiQueue.sync(execute: disposeMIDIResources)
        }

        if let callbackBox {
            Unmanaged<MIDIStateManagerCallbackBox>.fromOpaque(callbackBox).release()
        }
    }

    private func setupMIDIClient() {
        let clientName = "com.avcmeter.MIDIClient" as CFString
        let callbackBox = Unmanaged.passRetained(MIDIStateManagerCallbackBox(manager: self)).toOpaque()
        let clientStatus = MIDIClientCreate(clientName, midiNotifyCallback, callbackBox, &midiClient)
        guard clientStatus == noErr else {
            Unmanaged<MIDIStateManagerCallbackBox>.fromOpaque(callbackBox).release()
            print("[MIDIStateManager] Failed to create MIDI client: \(clientStatus)")
            return
        }
        self.callbackBox = callbackBox

        // Create an input port for receiving MIDI events
        MIDIInputPortCreate(midiClient, "com.avcmeter.InputPort" as CFString, { (pktlist, readProcRefCon, srcConnRefCon) in
            guard let readProcRefCon = readProcRefCon else { return }
            guard Unmanaged<MIDIStateManagerCallbackBox>.fromOpaque(readProcRefCon).takeUnretainedValue().manager != nil else {
                return
            }

            let packets = pktlist.pointee
            var packet = packets.packet

            for _ in 0..<packets.numPackets {
                let data = packet.data
                let status = data.0
                let data1 = data.1
                let data2 = data.2

                // Forward to UtilityInstrumentManager
                UtilityInstrumentManager.shared.handleMIDIMessage(
                    status: status,
                    data1: data1,
                    data2: data2,
                    sourceEndpoint: "unknown" // We could lookup name if needed
                )

                let nextPacket = withUnsafePointer(to: &packet) { ptr in
                    MIDIPacketNext(ptr)
                }
                packet = nextPacket.pointee
            }
        }, callbackBox, &inputPort)

        // Create an output port for sending MIDI events
        MIDIOutputPortCreate(midiClient, "com.avcmeter.OutputPort" as CFString, &outputPort)
    }

    private func registerSleepWakeObservers() {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        sleepWakeObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleSystemWillSleep()
            }
        )
        sleepWakeObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.handleSystemDidWake()
            }
        )
        #endif
    }

    private func handleSystemWillSleep() {
        midiQueue.async { [weak self] in
            self?.refreshWorkItem?.cancel()
            self?.refreshWorkItem = nil
        }
    }

    private func handleSystemDidWake() {
        scheduleDeviceRefresh(after: 1.0)
    }

    func connectSource(_ endpoint: MIDIEndpointRef) {
        let name = getEndpointName(endpoint)
        activeRoutes[name] = "default"
        midiQueue.async { [weak self] in
            guard let self, !self.isDisposed, self.inputPort != 0, endpoint != 0 else { return }
            self.connectedSources.insert(endpoint)
            MIDIPortConnectSource(self.inputPort, endpoint, nil)
        }
        print("[MIDIStateManager] Connected source endpoint: \(name)")
    }

    func reconcileRoutes() {
        print("[MIDIStateManager] Reconciling routes after setup change...")
        scheduleDeviceRefresh(after: 0.25)
    }

    func refreshDevices() {
        scheduleDeviceRefresh(after: 0)
    }

    private func scheduleDeviceRefresh(after delay: TimeInterval) {
        midiQueue.async { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.refreshWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.refreshDevicesNow()
            }
            self.refreshWorkItem = workItem
            self.midiQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func refreshDevicesNow() {
        guard !isDisposed, midiClient != 0 else { return }

        var devices: [MIDIDeviceModel] = []
        var nextConnectedSources = Set<MIDIEndpointRef>()
        let deviceCount = MIDIGetNumberOfDevices()

        for i in 0..<deviceCount {
            let deviceRef = MIDIGetDevice(i)
            guard deviceRef != 0 else { continue }

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(deviceRef, kMIDIPropertyUniqueID, &uniqueID)

            var isOffline: Int32 = 0
            MIDIObjectGetIntegerProperty(deviceRef, kMIDIPropertyOffline, &isOffline)

            var inputEndpoints: [MIDIEndpointRef] = []
            var outputEndpoints: [MIDIEndpointRef] = []

            let entityCount = MIDIDeviceGetNumberOfEntities(deviceRef)
            for j in 0..<entityCount {
                let entity = MIDIDeviceGetEntity(deviceRef, j)

                let sourceCount = MIDIEntityGetNumberOfSources(entity)
                for k in 0..<sourceCount {
                    let source = MIDIEntityGetSource(entity, k)
                    guard source != 0 else { continue }
                    inputEndpoints.append(source)
                    nextConnectedSources.insert(source)
                    if inputPort != 0, connectedSources.contains(source) == false {
                        MIDIPortConnectSource(inputPort, source, UnsafeMutableRawPointer(bitPattern: Int(source)))
                    }
                }

                let destinationCount = MIDIEntityGetNumberOfDestinations(entity)
                for k in 0..<destinationCount {
                    let destination = MIDIEntityGetDestination(entity, k)
                    guard destination != 0 else { continue }
                    outputEndpoints.append(destination)
                }
            }

            let deviceModel = MIDIDeviceModel(
                id: uniqueID,
                name: stringProperty(deviceRef, kMIDIPropertyName),
                manufacturer: stringProperty(deviceRef, kMIDIPropertyManufacturer),
                model: stringProperty(deviceRef, kMIDIPropertyModel),
                isOnline: isOffline == 0,
                inputEndpoints: inputEndpoints,
                outputEndpoints: outputEndpoints
            )
            devices.append(deviceModel)
        }
        connectedSources = nextConnectedSources

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDisposed else { return }
            self.availableDevices = devices
        }
    }

    func getEndpointName(_ endpoint: MIDIEndpointRef) -> String {
        stringProperty(endpoint, kMIDIPropertyName)
    }

    private func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String {
        var nameRef: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(object, property, &nameRef)
        guard status == noErr else { return "Unknown" }
        return nameRef?.takeRetainedValue() as String? ?? "Unknown"
    }

    /// Send MIDI note on message to a specific output endpoint
    func sendNoteOn(to endpoint: MIDIEndpointRef, note: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) {
        guard outputPort != 0 else { return }
        let statusByte = UInt8(0x90 | (channel & 0x0F))
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        var bytes: [UInt8] = [statusByte, note, velocity]
        bytes.withUnsafeBufferPointer { ptr in
            packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, 3, ptr.baseAddress!)
        }
        MIDISend(outputPort, endpoint, &packetList)
    }

    /// Send MIDI note off message to a specific output endpoint
    func sendNoteOff(to endpoint: MIDIEndpointRef, note: UInt8, channel: UInt8 = 0) {
        guard outputPort != 0 else { return }
        let statusByte = UInt8(0x80 | (channel & 0x0F))
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        var bytes: [UInt8] = [statusByte, note, 0]
        bytes.withUnsafeBufferPointer { ptr in
            packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, 3, ptr.baseAddress!)
        }
        MIDISend(outputPort, endpoint, &packetList)
    }

    /// Send MIDI Control Change message to a specific output endpoint
    func sendCC(to endpoint: MIDIEndpointRef, cc: UInt8, value: UInt8, channel: UInt8 = 0) {
        guard outputPort != 0 else { return }
        let statusByte = UInt8(0xB0 | (channel & 0x0F))
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        var bytes: [UInt8] = [statusByte, cc, value]
        bytes.withUnsafeBufferPointer { ptr in
            packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, 3, ptr.baseAddress!)
        }
        MIDISend(outputPort, endpoint, &packetList)
    }

    /// Send MIDI Pitch Bend message to a specific output endpoint
    /// - Parameters:
    ///   - value: 14-bit value (0-16383, 8192 is center)
    func sendPitchBend(to endpoint: MIDIEndpointRef, value: UInt16, channel: UInt8 = 0) {
        guard outputPort != 0 else { return }
        let statusByte = UInt8(0xE0 | (channel & 0x0F))
        let lsb = UInt8(value & 0x7F)
        let msb = UInt8((value >> 7) & 0x7F)
        var packetList = MIDIPacketList()
        var packet = MIDIPacketListInit(&packetList)
        var bytes: [UInt8] = [statusByte, lsb, msb]
        bytes.withUnsafeBufferPointer { ptr in
            packet = MIDIPacketListAdd(&packetList, 1024, packet, 0, 3, ptr.baseAddress!)
        }
        MIDISend(outputPort, endpoint, &packetList)
    }
}

private final class MIDIStateManagerCallbackBox {
    weak var manager: MIDIStateManager?

    init(manager: MIDIStateManager) {
        self.manager = manager
    }
}

/// Callback for MIDI system notifications (device added/removed).
private func midiNotifyCallback(_ message: UnsafePointer<MIDINotification>, _ refCon: UnsafeMutableRawPointer?) {
    guard let refCon = refCon else { return }
    guard let manager = Unmanaged<MIDIStateManagerCallbackBox>.fromOpaque(refCon).takeUnretainedValue().manager else {
        return
    }

    manager.reconcileRoutes()
}
