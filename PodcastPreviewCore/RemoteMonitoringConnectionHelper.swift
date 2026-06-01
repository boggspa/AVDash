import Foundation
import Network

public enum RemoteMonitoringConnectionHelper {
    /// Builds NWParameters with TLS using a pre-shared key derived from the passcode.
    /// Both sides must use the same passcode for the TLS handshake to succeed —
    /// this replaces application-layer auth with transport-layer security.
    public static func makeTLSParameters(passcode: String) -> NWParameters {
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
