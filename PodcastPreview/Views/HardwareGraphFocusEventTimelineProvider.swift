import SwiftUI
import PodcastPreviewCore

struct HardwareGraphFocusEventTimelineSnapshot {
    let title: String
    let subtitle: String
    let startLabel: String
    let endLabel: String
    let events: [HardwareGraphFocusEventMarker]
}

struct HardwareGraphFocusEventMarker: Identifiable {
    let id: Int64
    let title: String
    let detail: String?
    let timestampText: String
    let position: Double
    let tint: Color
}

@MainActor
struct HardwareGraphFocusEventTimelineProvider {
    let reader: any HardwareEventQuerying

    func snapshot(
        for focus: HardwareGraphFocusState,
        window: HardwareInsightWindow,
        anchorDate: Date
    ) async -> HardwareGraphFocusEventTimelineSnapshot? {
        let range = window.range(anchoredAt: anchorDate)
        let events = await reader.events(
            in: range,
            categories: categories(for: focus),
            limit: 28
        )
        guard !events.isEmpty else { return nil }

        return HardwareGraphFocusEventTimelineSnapshot(
            title: "Event Timeline",
            subtitle: "System and service events captured during the selected window.",
            startLabel: axisLabel(for: range.start, range: range),
            endLabel: axisLabel(for: range.end, range: range),
            events: events.map { event in
                let position = range.duration > 0
                    ? min(max(event.timestamp.timeIntervalSince(range.start) / range.duration, 0), 1)
                    : 0
                return HardwareGraphFocusEventMarker(
                    id: event.id,
                    title: event.title,
                    detail: event.detail,
                    timestampText: timestampLabel(for: event.timestamp, range: range),
                    position: position,
                    tint: tint(for: event)
                )
            }
        )
    }

    private func categories(for focus: HardwareGraphFocusState) -> [HardwareEventCategory]? {
        if focus.processTarget != nil {
            return nil
        }

        switch focus.insightTarget {
        case .gpu:
            return [.media, .display, .thermal, .power, .remote, .system]
        case .power:
            return [.power, .thermal, .media, .display, .remote, .system]
        case .network:
            return [.remote, .power, .system]
        case .disk:
            return [.system, .power, .display]
        default:
            return nil
        }
    }

    private func tint(for event: HardwareTimelineEvent) -> Color {
        switch event.category {
        case .system:
            return event.severity == .highlight ? Color(red: 0.48, green: 0.74, blue: 0.98) : Color(red: 0.35, green: 0.62, blue: 0.96)
        case .power:
            return .orange
        case .thermal:
            return event.severity == .highlight ? .red : Color(red: 0.92, green: 0.40, blue: 0.25)
        case .display:
            return Color(red: 0.70, green: 0.62, blue: 0.95)
        case .media:
            return Color(red: 0.86, green: 0.26, blue: 0.26)
        case .remote:
            return .green
        @unknown default:
            return .secondary
        }
    }

    private func axisLabel(for date: Date, range: DateInterval) -> String {
        timestampLabel(for: date, range: range)
    }

    private func timestampLabel(for date: Date, range: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if range.duration <= 24 * 60 * 60 {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }
}
