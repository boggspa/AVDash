#if os(macOS)
//
//  RemoteMonitoringServer.swift
//  PodcastPreviewCore
//
//  Bonjour-advertised Network.framework listener that streams hardware
//  telemetry to authenticated host machines on the local network.
//

import Foundation
import Network
import Combine
import os.log
import PodcastPreviewShared

@MainActor
public final class RemoteMonitoringServer: ObservableObject {
    private let logger = Logger(subsystem: "com.chrisizatt.PodcastPreview", category: "RemoteMonitoringServer")

    // MARK: - Published State

    @Published public private(set) var isRunning = false
    @Published public private(set) var connectedHosts: [ConnectedHost] = []
    @Published public private(set) var pendingAuthRequest: PendingAuthRequest?
    @Published public private(set) var listeningPort: UInt16?
    /// The current passcode shown to the user. Rotated each time the server starts.
    @Published public private(set) var currentPasscode: String = RemotePasscodeGenerator.generate()

    public struct ConnectedHost: Identifiable, Equatable {
        public let id: String  // hostMachineID
        public let name: String
        public let connectedAt: Date
    }

    public struct PendingAuthRequest: Identifiable {
        public let id = UUID()
        public let hostName: String
        public let hostMachineID: String
        let connection: NWConnection
        let nonce: String
    }

    // MARK: - Private State

    private var listener: NWListener?
    private var activeConnections: [String: NWConnection] = [:]  // hostMachineID → connection
    private var streamingTimers: [String: DispatchSourceTimer] = [:]
    private let machineIdentity: RemoteMachineIdentity
    private var collectorService: HardwareCollectorService?
    private let eventStore: HardwareEventStore?

    // MARK: - Init

    public init(machineIdentity: RemoteMachineIdentity) {
        self.machineIdentity = machineIdentity
        if let database = try? HardwareHistoryDatabase() {
            self.eventStore = HardwareEventStore(database: database)
        } else {
            self.eventStore = nil
        }
    }

    /// Generates a fresh passcode without restarting the server.
    /// Call this when the user taps "Refresh Passcode".
    public func rotatePasscode() {
        guard !isRunning else {
            // Restart with new passcode so TLS parameters update
            stop()
            currentPasscode = RemotePasscodeGenerator.generate()
            if let cs = collectorService { start(collectorService: cs) }
            return
        }
        currentPasscode = RemotePasscodeGenerator.generate()
    }

    // MARK: - Lifecycle

    public func start(collectorService: HardwareCollectorService) {
        guard !isRunning else { return }
        self.collectorService = collectorService

        do {
            let parameters = Self.makeTLSParameters(passcode: currentPasscode)
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)

            // Advertise via Bonjour
            var txtRecord = NWTXTRecord()
            txtRecord[RemoteMonitoringConstants.txtKeyModel] = machineIdentity.modelIdentifier
            txtRecord[RemoteMonitoringConstants.txtKeyVersion] = String(RemoteMonitoringConstants.protocolVersion)
            txtRecord[RemoteMonitoringConstants.txtKeyHostname] = machineIdentity.displayName
            listener.service = NWListener.Service(
                name: machineIdentity.displayName,
                type: RemoteMonitoringConstants.bonjourServiceType,
                domain: RemoteMonitoringConstants.bonjourServiceDomain,
                txtRecord: txtRecord
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleNewConnection(connection)
                }
            }

            listener.start(queue: .main)
            self.listener = listener
            isRunning = true
            logger.info("Remote monitoring server started, advertising as '\(self.machineIdentity.displayName)'")
        } catch {
            logger.error("Failed to start remote monitoring server: \(error.localizedDescription)")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        pendingAuthRequest = nil

        stopAllStreaming()

        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        connectedHosts.removeAll()
        listeningPort = nil
        collectorService?.stopHardwareStatsMonitoring()

        isRunning = false
        logger.info("Remote monitoring server stopped")
    }

    // MARK: - Auth Response

    /// Called by the companion UI when the user approves a connection request.
    public func approveAuth(_ request: PendingAuthRequest, remember: Bool = true) {
        guard pendingAuthRequest?.id == request.id else { return }
        pendingAuthRequest = nil

        if remember {
            RemoteAuthKeychain.setApproved(hostMachineID: request.hostMachineID, hostName: request.hostName)
        }

        approvePendingConnection(
            hostMachineID: request.hostMachineID,
            hostName: request.hostName,
            connection: request.connection
        )
        logger.info("Approved connection from host '\(request.hostName)' (remember: \(remember))")
    }

    /// Called by the companion UI when the user denies a connection request.
    public func denyAuth(_ request: PendingAuthRequest) {
        guard pendingAuthRequest?.id == request.id else { return }
        pendingAuthRequest = nil

        let result = RemoteAuthResult(accepted: false, reason: "Connection denied by user")
        sendMessage(kind: .authResult, payload: result, on: request.connection)
        request.connection.cancel()
        logger.info("Denied connection from host '\(request.hostName)'")
    }

    public func disconnectHost(_ hostID: String) {
        disconnectHost(hostID, matching: nil)
    }

    // MARK: - Listener State

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            listeningPort = listener?.port?.rawValue
            logger.info("Listener ready")
        case .failed(let error):
            listeningPort = nil
            logger.error("Listener failed: \(error.localizedDescription)")
            isRunning = false
        case .cancelled:
            listeningPort = nil
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.beginAuth(on: connection)
                case .failed, .cancelled:
                    self?.cleanupConnection(connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func beginAuth(on connection: NWConnection) {
        let challenge = RemoteAuthChallenge(
            machineID: machineIdentity.machineID,
            machineName: machineIdentity.displayName,
            machineModel: machineIdentity.modelIdentifier
        )
        sendMessage(kind: .authChallenge, payload: challenge, on: connection)

        // Listen for auth response
        receiveMessage(on: connection) { [weak self] envelope in
            Task { @MainActor [weak self] in
                self?.handleAuthResponse(envelope, on: connection, nonce: challenge.nonce)
            }
        }
    }

    private func handleAuthResponse(_ envelope: RemoteMonitoringEnvelope?, on connection: NWConnection, nonce: String) {
        guard let envelope, envelope.kind == .authRequest,
              let request = try? RemoteMonitoringWire.decodePayload(RemoteAuthRequest.self, from: envelope) else {
            logger.warning("Invalid auth response received")
            connection.cancel()
            return
        }

        // TLS-PSK already verified the passcode at the transport layer.
        // Just verify the nonce echo to prevent replay, then ask for user consent.
        guard request.nonce == nonce else {
            let result = RemoteAuthResult(accepted: false, reason: "Nonce mismatch")
            sendMessage(kind: .authResult, payload: result, on: connection)
            connection.cancel()
            return
        }

        // Check if this host is already approved (Keychain allowlist)
        if RemoteAuthKeychain.isApproved(hostMachineID: request.hostMachineID) {
            logger.info("Auto-approving previously trusted host '\(request.hostName)'")
            approvePendingConnection(
                hostMachineID: request.hostMachineID,
                hostName: request.hostName,
                connection: connection
            )
        } else {
            // Present consent dialog to user
            pendingAuthRequest = PendingAuthRequest(
                hostName: request.hostName,
                hostMachineID: request.hostMachineID,
                connection: connection,
                nonce: nonce
            )
        }
    }

    private func approvePendingConnection(hostMachineID: String, hostName: String, connection: NWConnection) {
        replaceActiveConnectionIfNeeded(for: hostMachineID)

        let result = RemoteAuthResult(accepted: true, sessionToken: UUID().uuidString)
        sendMessage(kind: .authResult, payload: result, on: connection)

        activeConnections[hostMachineID] = connection
        connectedHosts.append(ConnectedHost(id: hostMachineID, name: hostName, connectedAt: Date()))
        recordRemoteViewerEvent(
            type: "remote-viewer-connected",
            title: "Remote viewer connected",
            detail: hostName,
            severity: .info
        )

        sendMessage(kind: .machineIdentity, payload: machineIdentity, on: connection)
        startStreaming(to: hostMachineID, connection: connection)
        logger.info("Connected host '\(hostName)'")
    }

    // MARK: - Streaming

    private func startStreaming(to hostID: String, connection: NWConnection) {
        // Start the collector if not already running
        collectorService?.startHardwareStatsMonitoring()

        // Prime the client immediately so the remote detail view has something
        // to hydrate from before the recurring timers settle in.
        sendTelemetryFrame(to: hostID, on: connection)
        sendPollingSnapshot(to: hostID, on: connection)

        // Send telemetry frames every second
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.sendTelemetryFrame(to: hostID, on: connection)
            }
        }
        timer.resume()
        streamingTimers[hostID] = timer

        // Also send polling snapshots every 5 seconds
        let pollingTimer = DispatchSource.makeTimerSource(queue: .main)
        pollingTimer.schedule(deadline: .now() + 2, repeating: 5.0)
        pollingTimer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.sendPollingSnapshot(to: hostID, on: connection)
            }
        }
        pollingTimer.resume()
        streamingTimers[pollingTimerKey(for: hostID)] = pollingTimer

        // Keep receiving messages (for ping/stop)
        receiveMessages(on: connection, hostID: hostID)
    }

    private func sendTelemetryFrame(to hostID: String, on connection: NWConnection) {
        guard let frame = collectorService?.latestTelemetryFrame else { return }
        let payload = RemoteTelemetryPayload(machineID: machineIdentity.machineID, frame: frame)
        sendMessage(kind: .telemetryFrame, payload: payload, on: connection)
    }

    private func sendPollingSnapshot(to hostID: String, on connection: NWConnection) {
        guard let snapshot = collectorService?.pollingSnapshot else { return }
        let payload = RemotePollingPayload(machineID: machineIdentity.machineID, snapshot: snapshot)
        sendMessage(kind: .pollingSnapshot, payload: payload, on: connection)
    }

    private func receiveMessages(on connection: NWConnection, hostID: String) {
        receiveMessage(on: connection) { [weak self] envelope in
            Task { @MainActor [weak self] in
                guard let self, let envelope else {
                    self?.disconnectHost(hostID, matching: connection)
                    return
                }
                switch envelope.kind {
                case .ping:
                    self.sendMessage(kind: .pong, payload: Optional<String>.none, on: connection)
                case .stopStreaming:
                    self.disconnectHost(hostID, matching: connection)
                default:
                    break
                }
                // Keep receiving
                self.receiveMessages(on: connection, hostID: hostID)
            }
        }
    }

    // MARK: - Wire Helpers

    private func sendMessage<T: Encodable>(kind: RemoteMonitoringMessageKind, payload: T, on connection: NWConnection) {
        do {
            let envelope = try RemoteMonitoringWire.envelope(kind: kind, payload: payload)
            let data = try RemoteMonitoringWire.encode(envelope)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.logger.error("Send error for \(kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            })
        } catch {
            logger.error("Encoding error for \(kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func receiveMessage(on connection: NWConnection, handler: @escaping (RemoteMonitoringEnvelope?) -> Void) {
        // First read the 4-byte length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, error in
            if let error {
                self.logger.error("Failed reading message length: \(error.localizedDescription, privacy: .public)")
                handler(nil)
                return
            }

            guard let data else {
                self.logger.error("Connection closed while reading message length")
                handler(nil)
                return
            }

            guard let length = RemoteMonitoringWire.readLength(from: data) else {
                self.logger.error("Received invalid message length prefix")
                handler(nil)
                return
            }

            // Then read the body
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { bodyData, _, _, error in
                if let error {
                    self.logger.error("Failed reading \(length) byte message body: \(error.localizedDescription, privacy: .public)")
                    handler(nil)
                    return
                }

                guard let bodyData else {
                    self.logger.error("Connection closed while reading a \(length) byte message body")
                    handler(nil)
                    return
                }

                do {
                    let envelope = try RemoteMonitoringWire.decodeEnvelope(from: bodyData)
                    if envelope.version != RemoteMonitoringConstants.protocolVersion {
                        self.logger.warning(
                            "Received protocol version \(envelope.version, privacy: .public) while expecting \(RemoteMonitoringConstants.protocolVersion, privacy: .public)"
                        )
                    }
                    handler(envelope)
                } catch {
                    self.logger.error(
                        "Failed decoding envelope for \(length) byte message: \(error.localizedDescription, privacy: .public)"
                    )
                    handler(nil)
                }
            }
        }
    }

    private func cleanupConnection(_ connection: NWConnection) {
        clearPendingAuthRequest(for: connection)
        if let hostID = activeConnections.first(where: { $0.value === connection })?.key {
            disconnectHost(hostID, matching: connection)
        }
    }

    private func disconnectHost(_ hostID: String, matching connection: NWConnection?) {
        if let connection {
            clearPendingAuthRequest(for: connection)
        }

        guard let trackedConnection = activeConnections[hostID] else { return }
        guard connection == nil || trackedConnection === connection else { return }

        stopStreaming(for: hostID)
        activeConnections.removeValue(forKey: hostID)
        let disconnectedHost = connectedHosts.first { $0.id == hostID }
        connectedHosts.removeAll { $0.id == hostID }
        trackedConnection.cancel()
        recordRemoteViewerEvent(
            type: "remote-viewer-disconnected",
            title: "Remote viewer disconnected",
            detail: disconnectedHost?.name ?? hostID,
            severity: .info
        )

        if activeConnections.isEmpty {
            collectorService?.stopHardwareStatsMonitoring()
        }
    }

    private func replaceActiveConnectionIfNeeded(for hostID: String) {
        stopStreaming(for: hostID)
        connectedHosts.removeAll { $0.id == hostID }

        if let existingConnection = activeConnections.removeValue(forKey: hostID) {
            existingConnection.cancel()
        }
    }

    private func clearPendingAuthRequest(for connection: NWConnection) {
        guard pendingAuthRequest?.connection === connection else { return }
        pendingAuthRequest = nil
    }

    private func stopStreaming(for hostID: String) {
        streamingTimers[hostID]?.cancel()
        streamingTimers.removeValue(forKey: hostID)
        streamingTimers[pollingTimerKey(for: hostID)]?.cancel()
        streamingTimers.removeValue(forKey: pollingTimerKey(for: hostID))
    }

    private func stopAllStreaming() {
        for (_, timer) in streamingTimers {
            timer.cancel()
        }
        streamingTimers.removeAll()
    }

    private func recordRemoteViewerEvent(
        type: String,
        title: String,
        detail: String?,
        severity: HardwareEventSeverity
    ) {
        guard let eventStore else { return }
        Task {
            await eventStore.append(
                category: .remote,
                type: type,
                title: title,
                detail: detail,
                severity: severity
            )
        }
    }

    private func pollingTimerKey(for hostID: String) -> String {
        "\(hostID)_polling"
    }

    // MARK: - TLS Parameters

    /// Builds NWParameters with TLS using a pre-shared key derived from the passcode.
    /// Both sides must use the same passcode for the TLS handshake to succeed —
    /// this replaces application-layer auth with transport-layer security.
    static func makeTLSParameters(passcode: String) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        let passcodeData = Data(RemotePasscodeGenerator.normalized(passcode).utf8)
        let identityData = Data("PodcastPreviewRemoteMonitoring".utf8)
        let pskDispatch = passcodeData.withUnsafeBytes { DispatchData(bytes: $0) }
        let identDispatch = identityData.withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            tlsOptions.securityProtocolOptions,
            pskDispatch as __DispatchData,
            identDispatch as __DispatchData
        )

        // Network.framework PSK handshakes succeed reliably here under TLS 1.2.
        // Forcing TLS 1.3 causes the handshake to fail before app-layer auth.
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        return NWParameters(tls: tlsOptions, tcp: tcpOptions)
    }
}

#endif