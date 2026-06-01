import Foundation
import Combine
#if os(macOS)
import SystemConfiguration
#endif

/// Sandbox-safe network interface info (local IP, DNS).
/// Uses SystemConfiguration (available on Big Sur) to probe global network state.
public final class NetworkInterfaceSampler: ObservableObject {
    @Published public var ipv4Address: String = "—"
    @Published public var routerAddress: String = "—"
    @Published public var dnsServers: String = "—"
    @Published public var interfaceName: String = "—"
    @Published public var isVPNActive: Bool = false
    @Published public private(set) var latestSnapshot: NetworkInterfaceSnapshot? = nil

    private var timer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "PodcastPreview.NetworkInterfaceSampler", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private static let refreshIntervalSeconds = 300

    public init(autoRefresh: Bool = true) {
        if autoRefresh {
            start()
        }
    }

    public init() {
        // No auto-refresh
    }

    public func start() {
        stop()
        triggerSample()

        let interval = Self.refreshIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: samplingQueue)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func initializeForExternalClock() {
        stop()
        triggerSample()
    }

    public func triggerSample() {
        samplingQueue.async { [weak self] in
            self?.sample()
        }
    }

    private func sample() {
        #if os(macOS)
        let snapshot = Self.probeNetworkState()

        DispatchQueue.main.async {
            self.latestSnapshot = snapshot
            self.ipv4Address = snapshot.ipv4Address ?? "—"
            self.routerAddress = snapshot.routerAddress ?? "—"
            self.dnsServers = snapshot.dnsServers.isEmpty ? "—" : snapshot.dnsServers.joined(separator: ", ")
            self.interfaceName = snapshot.interfaceName ?? "—"
            self.isVPNActive = snapshot.isVPNActive
        }
        #else
        // Basic stub for iOS
        DispatchQueue.main.async {
            self.latestSnapshot = nil
            self.ipv4Address = "—"
            self.routerAddress = "—"
            self.dnsServers = "—"
            self.interfaceName = "—"
            self.isVPNActive = false
        }
        #endif
    }

    #if os(macOS)
    private static func probeNetworkState() -> NetworkInterfaceSnapshot {
        let scState = collectSCNetworkState()
        let rawInterfaces = collectInterfacesViaGetifaddrs()

        let interfaces = rawInterfaces.compactMap { raw in
            let connectionType = determineConnectionType(interfaceName: raw.name, isActive: !raw.ips.isEmpty)
            let isPrimary = raw.name == scState.primaryInterface

            return NetworkInterfaceDetails(
                name: raw.name,
                displayName: getDisplayName(for: raw.name),
                hardwareAddress: raw.mac,
                type: connectionType,
                isConnected: !raw.ips.isEmpty,
                ipv4Address: raw.ips.first,
                subnetMask: raw.masks.first,
                routerAddress: isPrimary ? scState.router : nil,
                ipv6Addresses: [],
                dnsServers: isPrimary ? scState.dnsServers : [],
                searchDomains: isPrimary ? scState.searchDomains : [],
                ethernetSpeed: raw.baudrate > 0 ? formatSpeed(raw.baudrate) : nil,
                configMethod: NetworkConfigurationMethod(rawValue: isPrimary ? scState.configMethod ?? "DHCP" : "DHCP") ?? .dhcp
            )
        }.sorted { ($0.name, $0.name) < ($1.name, $1.name) }

        let activeInterfaces = interfaces.filter { $0.isConnected }
        let primaryInterface = activeInterfaces.first { $0.routerAddress != nil } ?? activeInterfaces.first
        let connectionTypes = Set(activeInterfaces.compactMap { $0.type })

        var snapshot = NetworkInterfaceSnapshot()
        snapshot.interfaces = interfaces
        snapshot.primaryInterface = primaryInterface
        snapshot.connectionTypes = Array(connectionTypes)
        snapshot.isConnected = !activeInterfaces.isEmpty
        snapshot.ipv4Address = primaryInterface?.ipv4Address
        snapshot.routerAddress = scState.router
        snapshot.dnsServers = scState.dnsServers
        snapshot.searchDomains = scState.searchDomains
        snapshot.interfaceName = scState.primaryInterface
        snapshot.configMethod = scState.configMethod

        // VPN detection
        if let configMethod = scState.configMethod, configMethod.lowercased().contains("vpn") {
            snapshot.isVPNActive = true
        }

        return snapshot
    }

    private struct RawInterfaceData {
        var name: String
        var ips: [String] = []
        var masks: [String] = []
        var mac: String? = nil
        var baudrate: UInt64 = 0
    }

    private static func collectInterfacesViaGetifaddrs() -> [RawInterfaceData] {
        var interfaces: [RawInterfaceData] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return interfaces }
        defer { freeifaddrs(ifaddr) }

        var pointer = ifaddr
        while let addr = pointer?.pointee {
            let interfaceName = String(cString: addr.ifa_name)

            guard let ifa_addr = addr.ifa_addr else {
                pointer = addr.ifa_next
                continue
            }

            let family = ifa_addr.pointee.sa_family

            var rawData = interfaces.first { $0.name == interfaceName } ?? RawInterfaceData(name: interfaceName)

            // Handle IPv4 addresses
            if family == UInt8(AF_INET) {
                var addrData = ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee
                }

                var ipAddress = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                _ = ipAddress.withUnsafeMutableBufferPointer { buffer in
                    inet_ntop(AF_INET, &addrData.sin_addr, buffer.baseAddress, socklen_t(INET_ADDRSTRLEN))
                }
                rawData.ips.append(String(cString: ipAddress))

                if let netmask = addr.ifa_netmask {
                    var netmaskData = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee
                    }

                    var subnetMask = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    _ = subnetMask.withUnsafeMutableBufferPointer { buffer in
                        inet_ntop(AF_INET, &netmaskData.sin_addr, buffer.baseAddress, socklen_t(INET_ADDRSTRLEN))
                    }
                    rawData.masks.append(String(cString: subnetMask))
                }
            }
            // Handle MAC addresses from sockaddr_dl (AF_LINK on macOS)
            else if family == UInt8(AF_LINK) {
                let linkAddr = ifa_addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) {
                    $0.pointee
                }

                let sdl = linkAddr
                let n = Int(sdl.sdl_nlen)
                let alen = Int(sdl.sdl_alen)

                if alen == 6 && n + alen <= Int(sdl.sdl_len) {
                    let addrData = withUnsafeBytes(of: sdl.sdl_data) { rawBuffer -> Data in
                        guard let baseAddress = rawBuffer.baseAddress else {
                            return Data()
                        }
                        return Data(bytes: baseAddress.advanced(by: n), count: alen)
                    }
                    let mac = addrData.map { String(format: "%02x", $0) }.joined(separator: ":").uppercased()
                    rawData.mac = mac
                }

                // Get link speed if available
                if let ifData = addr.ifa_data {
                    rawData.baudrate = UInt64(ifData.assumingMemoryBound(to: if_data.self).pointee.ifi_baudrate)
                }
            }

            if interfaces.contains(where: { $0.name == interfaceName }) {
                if let index = interfaces.firstIndex(where: { $0.name == interfaceName }) {
                    interfaces[index] = rawData
                }
            } else {
                interfaces.append(rawData)
            }

            pointer = addr.ifa_next
        }

        return interfaces
    }

    private struct SCNetworkState {
        var router: String?
        var primaryInterface: String?
        var dnsServers: [String]
        var searchDomains: [String]
        var configMethod: String?
    }

    private static func collectSCNetworkState() -> SCNetworkState {
        guard let store = SCDynamicStoreCreate(nil, "PodcastPreview" as CFString, nil, nil) else {
            return SCNetworkState(router: nil, primaryInterface: nil, dnsServers: [], searchDomains: [], configMethod: nil)
        }

        var router: String?
        var primaryInterface: String?
        if let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            router = ipv4["Router"] as? String
            primaryInterface = ipv4["PrimaryInterface"] as? String
        }

        var dnsServers: [String] = []
        var searchDomains: [String] = []
        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            dnsServers = dns["ServerAddresses"] as? [String] ?? []
            searchDomains = dns["SearchDomains"] as? [String] ?? []
        }

        var configMethod: String?
        if let name = primaryInterface {
            let key = "State:/Network/Interface/\(name)/IPv4" as CFString
            if let dict = SCDynamicStoreCopyValue(store, key) as? [String: Any] {
                configMethod = dict["ConfigMethod"] as? String
            }
        }

        return SCNetworkState(router: router, primaryInterface: primaryInterface, dnsServers: dnsServers, searchDomains: searchDomains, configMethod: configMethod)
    }

    private static func determineConnectionType(interfaceName: String, isActive: Bool) -> NetworkConnectionType {
        let lowercased = interfaceName.lowercased()
        if lowercased.contains("en") && (lowercased.contains("wifi") || lowercased.contains("awdl")) {
            return .wifi
        } else if lowercased.contains("en") {
            return .ethernet
        } else if lowercased.contains("vpn") || lowercased.contains("utun") || lowercased.contains("tun") || lowercased.contains("tap") {
            return .vpn
        } else if lowercased.contains("thunderbolt") {
            return .thunderbolt
        }
        return .unknown
    }

    private static func getDisplayName(for interfaceName: String) -> String {
        let lowercased = interfaceName.lowercased()
        if lowercased.contains("en0") {
            return "Ethernet"
        } else if lowercased.contains("en1") {
            return "Ethernet 2"
        } else if lowercased.contains("wifi") || lowercased.contains("awdl") {
            return "Wi-Fi"
        } else if lowercased.contains("vpn") || lowercased.contains("utun") {
            return "VPN"
        } else if lowercased.contains("bridge") {
            return "Bridge"
        }
        return interfaceName.capitalized
    }

    private static func formatSpeed(_ baudrate: UInt64) -> String {
        if baudrate >= 1_000_000_000 {
            return "\(baudrate / 1_000_000_000) Gb/s"
        } else if baudrate >= 1_000_000 {
            return "\(baudrate / 1_000_000) Mb/s"
        } else if baudrate >= 1_000 {
            return "\(baudrate / 1_000) Kb/s"
        }
        return "\(baudrate) b/s"
    }
    #endif
}

extension NetworkInterfaceSampler {
    public var liveSnapshot: NetworkInterfaceSamplerLiveSnapshot {
        NetworkInterfaceSamplerLiveSnapshot(
            ipv4Address: ipv4Address,
            routerAddress: routerAddress,
            dnsServers: dnsServers,
            interfaceName: interfaceName,
            isVPNActive: isVPNActive,
            latestSnapshot: latestSnapshot
        )
    }

    public func applyRemoteSnapshot(_ snapshot: NetworkInterfaceSamplerLiveSnapshot) {
        ipv4Address = snapshot.ipv4Address
        routerAddress = snapshot.routerAddress
        dnsServers = snapshot.dnsServers
        interfaceName = snapshot.interfaceName
        isVPNActive = snapshot.isVPNActive
        latestSnapshot = snapshot.latestSnapshot
    }

    // Computed properties for consuming code
    public var connectionTypes: [NetworkConnectionType] {
        latestSnapshot?.connectionTypes ?? []
    }

    public var primaryInterface: NetworkInterfaceDetails? {
        latestSnapshot?.primaryInterface
    }
}
