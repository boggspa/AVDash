//
//  RemoteAuthKeychain.swift
//  PodcastPreviewCore
//
//  Stores the set of approved remote host machine IDs in the Keychain
//  so that previously-approved hosts reconnect without another consent dialog.
//

import Foundation
import Security

public enum RemoteAuthKeychain {
    private static let service = "com.chrisizatt.PodcastPreview.RemoteMonitoring"
    private static let approvedHostsAccount = "approvedHosts"

    // MARK: - Approved Host Management

    public static func isApproved(hostMachineID: String) -> Bool {
        loadApprovedHosts().keys.contains(hostMachineID)
    }

    /// Persists a host approval to the Keychain.
    public static func setApproved(hostMachineID: String, hostName: String) {
        var hosts = loadApprovedHosts()
        hosts[hostMachineID] = hostName
        saveApprovedHosts(hosts)
    }

    public static func revokeApproval(hostMachineID: String) {
        var hosts = loadApprovedHosts()
        hosts.removeValue(forKey: hostMachineID)
        saveApprovedHosts(hosts)
    }

    /// Returns all approved hosts as [machineID: displayName].
    public static func allApprovedHosts() -> [String: String] {
        loadApprovedHosts()
    }

    // MARK: - Private Keychain I/O

    private static func loadApprovedHosts() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: approvedHostsAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveApprovedHosts(_ hosts: [String: String]) {
        guard let data = try? JSONEncoder().encode(hosts) else { return }

        // Try updating first
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: approvedHostsAccount
        ]
        let updateAttrs: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: approvedHostsAccount,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
