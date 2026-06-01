//
//  RemoteMonitoringClient.swift
//  PodcastPreviewCore
//
//  Bonjour browser + Network.framework client that discovers and connects
//  to remote Macs running the companion monitoring server.
//

import Foundation
import Network
import Combine
import os.log
import PodcastPreviewShared

public typealias DiscoveredRemoteMachine = RemoteMonitoringClient.DiscoveredMachine

@MainActor
public final class RemoteMonitoringClient: ObservableObject {
    private let logger = Logger(subsystem: "com.chrisizatt.PodcastPreview", category: "RemoteMonitoringClient")

    // MARK: - Published State

    @Published public private(set) var discoveredServers: [DiscoveredMachine] = []
    @Published public private(set) var isScanning = false
    @Published public private(set) var connections: [RemoteMachineConnection] = []

    // Type alias for consuming code compatibility
    public typealias DiscoveredRemoteMachine = DiscoveredMachine

    public struct DiscoveredMachine: Identifiable, Equatable {
        public var id: String { endpoint.debugDescription }
        public let name: String
        public let modelIdentifier: String?
        public let hostname: String?
        let endpoint: NWEndpoint

        public var displayName: String {
            if let hostname, !hostname.isEmpty { return hostname }
            return name
        }
    }

    // MARK: - Private State

    private var browser: NWBrowser?

    // MARK: - Lifecycle

    public init() {}

    public func startScanning() {
        guard !isScanning else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: RemoteMonitoringConstants.bonjourServiceType, domain: RemoteMonitoringConstants.bonjourServiceDomain),
            using: parameters
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
        isScanning = true
        logger.info("Started scanning for remote machines")
    }

    public func stopScanning() {
        browser?.cancel()
        browser = nil
        discoveredServers.removeAll()
        isScanning = false
        logger.info("Stopped scanning")
    }

    // MARK: - Browsing Method Aliases for Consuming Code

    public func startBrowsing() {
        startScanning()
    }

    public func stopBrowsing() {
        stopScanning()
    }

    // MARK: - Connection Management

    public func connect(to machine: DiscoveredMachine, passcode: String) -> RemoteMachineConnection {
        let connection = RemoteMachineConnection(machineIdentity: RemoteMachineIdentity(
            machineID: machine.id,
            displayName: machine.displayName,
            modelIdentifier: machine.modelIdentifier ?? "",
            cpuName: nil,
            gpuName: nil,
            totalRAMGB: nil,
            macOSVersion: nil,
            chipType: nil
        ))
        connections.append(connection)
        connection.connect(to: machine, passcode: passcode)
        return connection
    }

    public func connect(toHost host: String, port: UInt16, passcode: String, displayName: String? = nil) -> RemoteMachineConnection? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty,
              port > 0,
              let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }

        let machine = DiscoveredMachine(
            name: displayName ?? normalizedHost,
            modelIdentifier: nil,
            hostname: normalizedHost,
            endpoint: .hostPort(host: NWEndpoint.Host(normalizedHost), port: endpointPort)
        )
        return connect(to: machine, passcode: passcode)
    }

    public func disconnect(_ connection: RemoteMachineConnection) {
        connection.disconnect()
        connections.removeAll { $0.id == connection.id }
    }

    // MARK: - Handlers

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        discoveredServers = results.map { result in
            var model: String?
            var hostname: String?

            if case .bonjour(let txtRecord) = result.metadata {
                model = txtRecord[RemoteMonitoringConstants.txtKeyModel]
                hostname = txtRecord[RemoteMonitoringConstants.txtKeyHostname]
            }

            let name: String
            if case .service(let serviceName, _, _, _) = result.endpoint {
                name = serviceName
            } else {
                name = result.endpoint.debugDescription
            }

            return DiscoveredMachine(
                name: name,
                modelIdentifier: model,
                hostname: hostname,
                endpoint: result.endpoint
            )
        }.sorted { $0.displayName < $1.displayName }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            logger.error("Browser failed: \(error.localizedDescription)")
            isScanning = false
        case .cancelled:
            isScanning = false
        default:
            break
        }
    }
}

// MARK: - Connection

@MainActor
public final class RemoteMachineConnection: ObservableObject, Identifiable {
    private let logger = Logger(subsystem: "com.chrisizatt.PodcastPreview", category: "RemoteMachineConnection")

    public enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case authenticating
        case awaitingApproval
        case connected
        case failed(RemoteConnectionError)
    }

    // MARK: - Published State

    @Published public private(set) var status: ConnectionStatus = .disconnected
    @Published public private(set) var latestTelemetryFrame: HardwareTelemetryFrame?
    @Published public private(set) var latestPollingSnapshot: HardwareCollectorPollingSnapshot?
    @Published public private(set) var machineIdentity: RemoteMachineIdentity?

    // Richer properties for consuming code - @Published for SwiftUI binding
    @Published public private(set) var sessionStartDate: Date?
    @Published public private(set) var connectionID: String = UUID().uuidString
    @Published public private(set) var connectionIdentity: RemoteMachineIdentity?
    @Published public private(set) var connectionMachineName: String = "Unknown Machine"

    // Computed properties for consuming code
    public var id: String {
        connectionID.isEmpty ? (machineIdentity?.machineID ?? UUID().uuidString) : connectionID
    }

    public var identity: RemoteMachineIdentity? {
        connectionIdentity ?? machineIdentity
    }

    public var machineName: String {
        connectionMachineName.isEmpty ? (machineIdentity?.displayName ?? "Unknown Machine") : connectionMachineName
    }

    public var state: ConnectionStatus {
        status
    }

    // MARK: - Private State

    private var nwConnection: NWConnection?
    private let machineIdentityIn: RemoteMachineIdentity
    private var pingTimer: DispatchSourceTimer?
    private var lastPingDate: Date?
    private var currentPasscode: String?

    public init(machineIdentity: RemoteMachineIdentity) {
        self.machineIdentityIn = machineIdentity
        self.connectionID = machineIdentity.machineID
        self.connectionIdentity = machineIdentity
        self.connectionMachineName = machineIdentity.displayName
    }

    // MARK: - Actions

    public func connect(to machine: RemoteMonitoringClient.DiscoveredMachine, passcode: String) {
        guard status == .disconnected || status == .connecting else { return }
        status = .connecting
        currentPasscode = passcode

        let parameters = RemoteMonitoringConnectionHelper.makeTLSParameters(passcode: passcode)
        parameters.includePeerToPeer = true

        let connection = NWConnection(to: machine.endpoint, using: parameters)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(state)
            }
        }

        connection.start(queue: .main)
        self.nwConnection = connection
        logger.info("Connecting to '\(machine.displayName)'...")
    }

    public func disconnect() {
        stopPingTimer()
        nwConnection?.cancel()
        nwConnection = nil
        status = .disconnected
        machineIdentity = nil
        latestTelemetryFrame = nil
        latestPollingSnapshot = nil
        sessionStartDate = nil
        currentPasscode = nil
    }

    // MARK: - Handlers

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Connection ready, waiting for auth challenge")
            status = .authenticating
            receiveMessages()
        case .failed(let error):
            logger.error("Connection failed: \(error.localizedDescription)")
            status = .failed(.network(error))
            disconnect()
        case .cancelled:
            status = .disconnected
        default:
            break
        }
    }

    private func handleMessage(_ envelope: RemoteMonitoringEnvelope) {
        switch envelope.kind {
        case .authChallenge:
            do {
                let challenge = try RemoteMonitoringWire.decodePayload(RemoteAuthChallenge.self, from: envelope)
                sendAuthResponse(challenge: challenge)
            } catch {
                handleConnectionFailure(.protocolViolation("Invalid auth challenge"))
            }

        case .authResult:
            do {
                let result = try RemoteMonitoringWire.decodePayload(RemoteAuthResult.self, from: envelope)
                if result.accepted {
                    logger.info("Authentication accepted")
                    status = .connected
                    sessionStartDate = Date()
                    startPingTimer()
                } else {
                    handleConnectionFailure(.authDenied(result.reason ?? "Denied"))
                }
            } catch {
                handleConnectionFailure(.protocolViolation("Invalid auth result"))
            }

        case .machineIdentity:
            machineIdentity = try? RemoteMonitoringWire.decodePayload(RemoteMachineIdentity.self, from: envelope)
            if let identity = machineIdentity {
                connectionIdentity = identity
                connectionMachineName = identity.displayName
            }

        case .telemetryFrame:
            do {
                let payload = try RemoteMonitoringWire.decodePayload(RemoteTelemetryPayload.self, from: envelope)
                latestTelemetryFrame = payload.frame
            } catch {
                logger.error("Failed to decode telemetry frame")
            }

        case .pollingSnapshot:
            do {
                let payload = try RemoteMonitoringWire.decodePayload(RemotePollingPayload.self, from: envelope)
                latestPollingSnapshot = payload.snapshot
            } catch {
                logger.error("Failed to decode polling snapshot")
            }

        case .pong:
            if let lastPingDate {
                let latency = Date().timeIntervalSince(lastPingDate) * 1000
                logger.debug("Pong received: \(latency, privacy: .public)ms")
            }

        default:
            break
        }
    }

    private func receiveMessages() {
        receiveMessage { [weak self] envelope in
            Task { @MainActor [weak self] in
                guard let self, let envelope else {
                    self?.handleConnectionFailure(.disconnected)
                    return
                }
                self.handleMessage(envelope)
                self.receiveMessages()
            }
        }
    }

    private func sendAuthResponse(challenge: RemoteAuthChallenge) {
        let request = RemoteAuthRequest(
            hostMachineID: machineIdentityIn.machineID,
            hostName: machineIdentityIn.displayName,
            nonce: challenge.nonce,
            passcode: currentPasscode ?? ""
        )
        sendMessage(kind: .authRequest, payload: request)
    }

    private func handleConnectionFailure(_ error: RemoteConnectionError) {
        logger.error("Connection error: \(error.localizedDescription)")
        status = .failed(error)
        disconnect()
    }

    // MARK: - Wire Helpers

    private func sendMessage<T: Encodable>(kind: RemoteMonitoringMessageKind, payload: T) {
        guard let connection = nwConnection else { return }
        do {
            let envelope = try RemoteMonitoringWire.envelope(kind: kind, payload: payload)
            let data = try RemoteMonitoringWire.encode(envelope)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.error("Send error: \(error.localizedDescription)")
                }
            })
        } catch {
            logger.error("Encoding error: \(error.localizedDescription)")
        }
    }

    private func receiveMessage(handler: @escaping (RemoteMonitoringEnvelope?) -> Void) {
        guard let connection = nwConnection else { return }

        // Read 4-byte length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
            if let error {
                self.logger.error("Failed reading message length: \(error.localizedDescription)")
                handler(nil)
                return
            }

            guard let data, let length = RemoteMonitoringWire.readLength(from: data) else {
                handler(nil)
                return
            }

            // Read body
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { bodyData, _, _, error in
                if let error {
                    self.logger.error("Failed reading message body: \(error.localizedDescription)")
                    handler(nil)
                    return
                }

                guard let bodyData else {
                    handler(nil)
                    return
                }

                do {
                    let envelope = try RemoteMonitoringWire.decodeEnvelope(from: bodyData)
                    handler(envelope)
                } catch {
                    self.logger.error("Failed decoding envelope: \(error.localizedDescription)")
                    handler(nil)
                }
            }
        }
    }

    // MARK: - Pings

    private func startPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.sendPing()
            }
        }
        timer.resume()
        self.pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() {
        lastPingDate = Date()
        sendMessage(kind: .ping, payload: Optional<String>.none)
    }
}

public enum RemoteConnectionError: Error, Equatable {
    case disconnected
    case network(Error)
    case authDenied(String)
    case protocolViolation(String)

    public static func == (lhs: RemoteConnectionError, rhs: RemoteConnectionError) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected): return true
        case (.authDenied(let a), .authDenied(let b)): return a == b
        case (.protocolViolation(let a), .protocolViolation(let b)): return a == b
        default: return false
        }
    }

    public var localizedDescription: String {
        switch self {
        case .disconnected: return "Connection lost."
        case .network(let error): return error.localizedDescription
        case .authDenied(let reason): return "Access denied: \(reason)"
        case .protocolViolation(let reason): return "Protocol error: \(reason)"
        }
    }
}
