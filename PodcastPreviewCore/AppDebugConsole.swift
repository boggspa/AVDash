//
//  AppDebugConsole.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 14/03/2026.
//


//
//  AppDebugConsole.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 14/03/2026.
//

#if DEBUG && os(macOS)
import SwiftUI
import AppKit
import Combine

public struct AppDebugConsoleEntry: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let category: String
    public let message: String

    private static let renderedLineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public var renderedLine: String {
        "[\(Self.renderedLineFormatter.string(from: timestamp))] [\(category)] \(message)"
    }
}

@MainActor
public final class AppDebugConsoleStore: ObservableObject {
    public static let shared = AppDebugConsoleStore()

    public static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    @Published public private(set) var entries: [AppDebugConsoleEntry] = []

    private let maxEntries = 1000

    private init() {}

    public func append(category: String = "APP", _ message: String) {
        let entry = AppDebugConsoleEntry(
            timestamp: Date(),
            category: category,
            message: message
        )

        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        print(entry.renderedLine)
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    public var combinedText: String {
        entries.map(\.renderedLine).joined(separator: "\n")
    }
}

public enum AppDebugConsole {
    public static let windowID = "app-debug-console"

    @MainActor
    public static func log(_ message: String, category: String = "APP") {
        AppDebugConsoleStore.shared.append(category: category, message)
    }

    @MainActor
    public static func clear() {
        AppDebugConsoleStore.shared.clear()
    }
}

public struct AppDebugConsoleView: View {
    @ObservedObject private var store = AppDebugConsoleStore.shared
    @State private var autoScroll = true
    @Environment(\.presentationMode) private var presentationMode

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if store.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)

                    Text("No debug output yet")
                        .font(.headline)

                    Text("Logs from GPU / power probe buttons will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(store.entries) { entry in
                                Group {
                                    if #available(macOS 12.0, *) {
                                        Text(entry.renderedLine)
                                            .font(consoleFont)
                                            .foregroundColor(.primary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(entry.id)
                                    } else {
                                        Text(entry.renderedLine)
                                            .font(consoleFont)
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .id(entry.id)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.black.opacity(0.06))
                    .onAppear {
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: store.entries.count) { _ in
                        guard autoScroll else { return }
                        scrollToBottom(proxy: proxy)
                    }
                }
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 420, idealHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Debug Console")
                    .font(.headline)

                Text("Bounded in-app log for debug probes and diagnostics")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.caption)

            Button("Copy All") {
                copyAllToPasteboard()
            }
            .buttonStyle(.bordered)

            Button("Clear") {
                AppDebugConsole.clear()
            }
            .buttonStyle(.bordered)
            
            Button("Close") {
                presentationMode.wrappedValue.dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("w", modifiers: .command)
        }
        .padding(12)
    }

    private var consoleFont: Font {
        if #available(macOS 12.0, *) {
            return .system(.caption, design: .monospaced)
        } else {
            return .system(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                           weight: .regular,
                           design: .monospaced)
        }
    }

    private func copyAllToPasteboard() {
        let text = store.combinedText
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = store.entries.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

#else
import Foundation

// No-op stub for non-macOS or non-DEBUG builds so callers can always reference AppDebugConsole.
public enum AppDebugConsole {
    public static let windowID = "app-debug-console"

    @MainActor
    public static func log(_ message: String, category: String = "APP") { }

    @MainActor
    public static func clear() { }
}
#endif
