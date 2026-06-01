import SwiftUI
import WidgetKit
import PodcastPreviewShared

struct ActivityHeatmapWidgetForiOS: Widget {
    let kind: String = "ActivityHeatmapWidgetForiOS"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ActivityHeatmapProviderForiOS()) { entry in
            ActivityHeatmapEntryViewForiOS(entry: entry)
        }
        .configurationDisplayName("Activity Heatmap")
        .description("Shows activity heatmap over time")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ActivityHeatmapEntryViewForiOS: View {
    let entry: ActivityHeatmapProviderForiOS.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.metric)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entry.cells.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Simplified heatmap visualization for widget
                HStack(spacing: 1) {
                    ForEach(0..<min(entry.cells.count, 7), id: \.self) { dayIndex in
                        VStack(spacing: 1) {
                            ForEach(0..<min(entry.cells[dayIndex].count, 5), id: \.self) { hourIndex in
                                let intensity = entry.cells[dayIndex][hourIndex]
                                Rectangle()
                                    .fill(cellColor(for: intensity))
                            }
                        }
                    }
                }

                Text("\(entry.columnCount) days")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func cellColor(for intensity: Double) -> Color {
        guard intensity > 0.01 else {
            return Color.gray.opacity(0.3)
        }
        return Color.blue.opacity(intensity * 0.8 + 0.2)
    }
}

struct ActivityHeatmapProviderForiOS: TimelineProvider {
    func placeholder(in context: Context) -> ActivityHeatmapEntryForiOS {
        ActivityHeatmapEntryForiOS(date: Date(), metric: "All", cells: [], columnCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (ActivityHeatmapEntryForiOS) -> Void) {
        if let data = WidgetStorage.loadActivityHeatmapData() {
            let entry = ActivityHeatmapEntryForiOS(
                date: data.timestamp,
                metric: data.metric,
                cells: data.cells,
                columnCount: data.columnCount
            )
            completion(entry)
        } else {
            completion(ActivityHeatmapEntryForiOS(date: Date(), metric: "All", cells: [], columnCount: 0))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ActivityHeatmapEntryForiOS>) -> Void) {
        if let data = WidgetStorage.loadActivityHeatmapData() {
            let entry = ActivityHeatmapEntryForiOS(
                date: data.timestamp,
                metric: data.metric,
                cells: data.cells,
                columnCount: data.columnCount
            )
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            completion(timeline)
        } else {
            let entry = ActivityHeatmapEntryForiOS(date: Date(), metric: "All", cells: [], columnCount: 0)
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            completion(timeline)
        }
    }
}

struct ActivityHeatmapEntryForiOS: TimelineEntry {
    let date: Date
    let metric: String
    let cells: [[Double]]
    let columnCount: Int
}
