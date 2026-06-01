import Foundation

// MARK: - Connection Types

public enum NetworkConnectionType: String, Codable, Equatable, Sendable {
    case wifi
    case ethernet
    case cellular
    case vpn
    case bluetooth
    case thunderbolt
    case firewire
    case other
    case unknown

    public var sfSymbol: String {
        switch self {
        case .wifi:
            return "wifi"
        case .ethernet:
            return "cable.connector"
        case .cellular:
            return "antenna.radiowaves.left.and.right"
        case .vpn:
            return "lock.shield"
        case .bluetooth:
            return "dot.radiowaves.left.and.right"
        case .thunderbolt:
            return "bolt.horizontal"
        case .firewire:
            return "bolt.horizontal.circle"
        case .other, .unknown:
            return "network"
        }
    }
}

public enum NetworkConfigurationMethod: String, Codable, Equatable, Sendable {
    case dhcp = "DHCP"
    case manual = "Manual"
    case bootp = "BOOTP"
    case linkLocal = "Link-local"
    case pppoe = "PPPoE"
    case vpn = "VPN"
    case other = "Other"

    public init(systemValue: String?) {
        guard let systemValue, !systemValue.isEmpty else {
            self = .other
            return
        }

        let normalized = systemValue.lowercased()
        switch normalized {
        case let value where value.contains("dhcp"):
            self = .dhcp
        case let value where value.contains("manual"):
            self = .manual
        case let value where value.contains("bootp"):
            self = .bootp
        case let value where value.contains("link"):
            self = .linkLocal
        case let value where value.contains("pppoe"):
            self = .pppoe
        case let value where value.contains("vpn"):
            self = .vpn
        default:
            self = .other
        }
    }
}

// MARK: - Interface Details

public struct NetworkInterfaceDetails: Codable, Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let hardwareAddress: String?
    public let type: NetworkConnectionType
    public let isConnected: Bool
    public let ipv4Address: String?
    public let subnetMask: String?
    public let routerAddress: String?
    public let ipv6Addresses: [String]
    public let dnsServers: [String]
    public let searchDomains: [String]
    public let ethernetSpeed: String?
    public let configMethod: NetworkConfigurationMethod

    public init(
        name: String,
        displayName: String,
        hardwareAddress: String? = nil,
        type: NetworkConnectionType = .unknown,
        isConnected: Bool = false,
        ipv4Address: String? = nil,
        subnetMask: String? = nil,
        routerAddress: String? = nil,
        ipv6Addresses: [String] = [],
        dnsServers: [String] = [],
        searchDomains: [String] = [],
        ethernetSpeed: String? = nil,
        configMethod: NetworkConfigurationMethod = .other
    ) {
        self.name = name
        self.displayName = displayName
        self.hardwareAddress = hardwareAddress
        self.type = type
        self.isConnected = isConnected
        self.ipv4Address = ipv4Address
        self.subnetMask = subnetMask
        self.routerAddress = routerAddress
        self.ipv6Addresses = ipv6Addresses
        self.dnsServers = dnsServers
        self.searchDomains = searchDomains
        self.ethernetSpeed = ethernetSpeed
        self.configMethod = configMethod
    }

    public var interfaceName: String {
        name
    }

    public var connectionType: NetworkConnectionType {
        type
    }

    public var isActive: Bool {
        isConnected
    }

    public var primaryLocalIP: String? {
        ipv4Address
    }

    public var primarySubnetMask: String? {
        subnetMask
    }

    public var router: String? {
        routerAddress
    }

    public var macAddress: String? {
        hardwareAddress
    }

    enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case hardwareAddress
        case type
        case isConnected
        case ipv4Address
        case subnetMask
        case routerAddress
        case ipv6Addresses
        case dnsServers
        case searchDomains
        case ethernetSpeed
        case configMethod
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.hardwareAddress = try container.decodeIfPresent(String.self, forKey: .hardwareAddress)
        self.type = try container.decodeIfPresent(NetworkConnectionType.self, forKey: .type) ?? .unknown
        self.isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
        self.ipv4Address = try container.decodeIfPresent(String.self, forKey: .ipv4Address)
        self.subnetMask = try container.decodeIfPresent(String.self, forKey: .subnetMask)
        self.routerAddress = try container.decodeIfPresent(String.self, forKey: .routerAddress)
        self.ipv6Addresses = try container.decodeIfPresent([String].self, forKey: .ipv6Addresses) ?? []
        self.dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        self.searchDomains = try container.decodeIfPresent([String].self, forKey: .searchDomains) ?? []
        self.ethernetSpeed = try container.decodeIfPresent(String.self, forKey: .ethernetSpeed)
        self.configMethod = NetworkConfigurationMethod(
            systemValue: try container.decodeIfPresent(String.self, forKey: .configMethod)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(hardwareAddress, forKey: .hardwareAddress)
        try container.encode(type, forKey: .type)
        try container.encode(isConnected, forKey: .isConnected)
        try container.encodeIfPresent(ipv4Address, forKey: .ipv4Address)
        try container.encodeIfPresent(subnetMask, forKey: .subnetMask)
        try container.encodeIfPresent(routerAddress, forKey: .routerAddress)
        try container.encode(ipv6Addresses, forKey: .ipv6Addresses)
        try container.encode(dnsServers, forKey: .dnsServers)
        try container.encode(searchDomains, forKey: .searchDomains)
        try container.encodeIfPresent(ethernetSpeed, forKey: .ethernetSpeed)
        try container.encode(configMethod, forKey: .configMethod)
    }
}

// MARK: - Network Interface Snapshot

public struct NetworkInterfaceSnapshot: Codable, Equatable, Sendable {
    // Simplified fields for iOS/CloudKit compatibility
    public var ipv4Address: String?
    public var routerAddress: String?
    public var dnsServers: [String]
    public var interfaceName: String?
    public var isVPNActive: Bool

    // Richer fields for macOS consuming code
    public var interfaces: [NetworkInterfaceDetails]
    public var connectionTypes: [NetworkConnectionType]
    public var primaryInterface: NetworkInterfaceDetails?
    public var isConnected: Bool
    public var localIP: String?
    public var subnetMask: String?
    public var searchDomains: [String]
    public var ethernetSpeed: String?
    public var configMethod: String?

    public init(
        ipv4Address: String? = nil,
        routerAddress: String? = nil,
        dnsServers: [String] = [],
        interfaceName: String? = nil,
        isVPNActive: Bool = false,
        interfaces: [NetworkInterfaceDetails] = [],
        connectionTypes: [NetworkConnectionType] = [],
        primaryInterface: NetworkInterfaceDetails? = nil,
        isConnected: Bool = false,
        localIP: String? = nil,
        subnetMask: String? = nil,
        searchDomains: [String] = [],
        ethernetSpeed: String? = nil,
        configMethod: String? = nil
    ) {
        self.ipv4Address = ipv4Address
        self.routerAddress = routerAddress
        self.dnsServers = dnsServers
        self.interfaceName = interfaceName
        self.isVPNActive = isVPNActive
        self.interfaces = interfaces
        self.connectionTypes = connectionTypes
        self.primaryInterface = primaryInterface
        self.isConnected = isConnected
        self.localIP = localIP
        self.subnetMask = subnetMask
        self.searchDomains = searchDomains
        self.ethernetSpeed = ethernetSpeed
        self.configMethod = configMethod
    }

    // Computed property for connection label used by consuming code
    public var connectionLabel: String {
        if let primaryInterface = primaryInterface {
            return primaryInterface.type.rawValue.capitalized
        } else if let interfaceName = interfaceName {
            return interfaceName
        } else {
            return "Unknown"
        }
    }
}

public struct NetworkInterfaceSamplerLiveSnapshot: Codable, Equatable, Sendable {
    public var ipv4Address: String
    public var routerAddress: String
    public var dnsServers: String
    public var interfaceName: String
    public var isVPNActive: Bool
    public var latestSnapshot: NetworkInterfaceSnapshot?

    public init(
        ipv4Address: String,
        routerAddress: String,
        dnsServers: String,
        interfaceName: String,
        isVPNActive: Bool,
        latestSnapshot: NetworkInterfaceSnapshot?
    ) {
        self.ipv4Address = ipv4Address
        self.routerAddress = routerAddress
        self.dnsServers = dnsServers
        self.interfaceName = interfaceName
        self.isVPNActive = isVPNActive
        self.latestSnapshot = latestSnapshot
    }
}
