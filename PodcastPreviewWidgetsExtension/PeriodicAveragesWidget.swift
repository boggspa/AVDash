import SwiftUI
import WidgetKit
import PodcastPreviewShared

struct PeriodicAveragesWidgetForiOS: Widget {
    let kind: String = "PeriodicAveragesWidgetForiOS"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PeriodicAveragesProviderForiOS()) { entry in
            PeriodicAveragesEntryViewForiOS(entry: entry)
        }
        .configurationDisplayName("Periodic Averages")
        .description("Shows hardware averages over time")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PeriodicAveragesEntryViewForiOS: View {
    let entry: PeriodicAveragesProviderForiOS.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.period)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entry.series.isEmpty {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.series.prefix(3).enumerated()), id: \.offset) { _, series in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(red: series.colorRed, green: series.colorGreen, blue: series.colorBlue))
                            .frame(width: 6, height: 6)

                        Text(series.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let latest = series.values.compactMap({ $0 }).last {
                            Text("\(Int(latest * 100))%")
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct PeriodicAveragesProviderForiOS: TimelineProvider {
    func placeholder(in context: Context) -> PeriodicAveragesEntryForiOS {
        PeriodicAveragesEntryForiOS(date: Date(), period: "24h", series: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (PeriodicAveragesEntryForiOS) -> Void) {
        if let data = WidgetStorage.loadPeriodicAveragesData() {
            let entry = PeriodicAveragesEntryForiOS(
                date: data.timestamp,
                period: data.period,
                series: data.series
            )
            completion(entry)
        } else {
            completion(PeriodicAveragesEntryForiOS(date: Date(), period: "24h", series: []))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PeriodicAveragesEntryForiOS>) -> Void) {
        if let data = WidgetStorage.loadPeriodicAveragesData() {
            let entry = PeriodicAveragesEntryForiOS(
                date: data.timestamp,
                period: data.period,
                series: data.series
            )
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            completion(timeline)
        } else {
            let entry = PeriodicAveragesEntryForiOS(date: Date(), period: "24h", series: [])
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            completion(timeline)
        }
    }
}

struct PeriodicAveragesEntryForiOS: TimelineEntry {
    let date: Date
    let period: String
    let series: [PeriodicAveragesWidgetData.SeriesData]
}
