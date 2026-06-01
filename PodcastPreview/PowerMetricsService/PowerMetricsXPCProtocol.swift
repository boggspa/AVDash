// File: PowerMetricsXPCProtocol.swift
// PodcastPreview
// Shared XPC protocol definitions for the Power Metrics helper.
// Include this file in both the app and helper targets.

import Foundation

public struct PowerMetricsHealthSnapshot: Codable, Equatable, Sendable {
    public var isSampling: Bool
    public var lastSampleDate: Date?
    public var lastUsableSampleDate: Date?
    public var consecutiveFailureCount: Int
    public var lastFailureReason: String?
    public var lastExitStatus: Int32?
    public var lastDurationSeconds: TimeInterval?
    public var lastStderrSuffix: String?
    public var lastPayloadTopLevelKeys: [String]

    public init(
        isSampling: Bool = false,
        lastSampleDate: Date? = nil,
        lastUsableSampleDate: Date? = nil,
        consecutiveFailureCount: Int = 0,
        lastFailureReason: String? = nil,
        lastExitStatus: Int32? = nil,
        lastDurationSeconds: TimeInterval? = nil,
        lastStderrSuffix: String? = nil,
        lastPayloadTopLevelKeys: [String] = []
    ) {
        self.isSampling = isSampling
        self.lastSampleDate = lastSampleDate
        self.lastUsableSampleDate = lastUsableSampleDate
        self.consecutiveFailureCount = consecutiveFailureCount
        self.lastFailureReason = lastFailureReason
        self.lastExitStatus = lastExitStatus
        self.lastDurationSeconds = lastDurationSeconds
        self.lastStderrSuffix = lastStderrSuffix
        self.lastPayloadTopLevelKeys = lastPayloadTopLevelKeys
    }
}

@objc public protocol PowerMetricsXPCProtocol {
    /// Returns a one-shot powermetrics sample as raw Property List data, or nil on failure.
    /// The data is expected to be a plist-encoded dictionary matching powermetrics -f plist output.
    func fetchPowerMetricsSample(withReply reply: @escaping (Data?) -> Void)

    /// Returns a plist-encoded ``PowerMetricsHealthSnapshot`` for diagnostics.
    func fetchHealth(withReply reply: @escaping (Data?) -> Void)

    /// Optional: simple status ping to verify connectivity.
    func ping(withReply reply: @escaping (String) -> Void)
}

/// Convenience error domain for client-side failures.
public enum PowerMetricsClientError: Error, LocalizedError {
    case unavailable
    case connectionFailed
    case remoteError

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Power metrics service unavailable on this macOS version."
        case .connectionFailed: return "Failed to connect to power metrics helper."
        case .remoteError: return "Helper failed to provide power metrics sample."
        }
    }
}
