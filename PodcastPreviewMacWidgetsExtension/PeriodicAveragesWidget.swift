import SwiftUI
import WidgetKit
import PodcastPreviewShared

struct PeriodicAveragesWidget: Widget {
    let kind: String = "PeriodicAveragesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PeriodicAveragesProvider()) { entry in
            PeriodicAveragesEntryView(entry: entry)
        }
        .configurationDisplayName("Periodic Averages")
        .description("Shows hardware averages over time")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct PeriodicAveragesEntryView: View {
    let entry: PeriodicAveragesProvider.Entry

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
                ForEach(entry.series.prefix(3), id: \.id) { series in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(red: series.colorRed, green: series.colorGreen, blue: series.colorBlue))
                            .frame(width: 6, height: 6)

                        Text(series.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let latestOptional = series.values.last, let latest = latestOptional {
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

struct PeriodicAveragesProvider: TimelineProvider {
    func placeholder(in context: Context) -> PeriodicAveragesEntry {
        PeriodicAveragesEntry(date: Date(), period: "24h", series: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (PeriodicAveragesEntry) -> Void) {
        if let data = WidgetStorage.loadPeriodicAveragesData() {
            let entry = PeriodicAveragesEntry(
                date: data.timestamp,
                period: data.period,
                series: data.series
            )
            completion(entry)
        } else {
            completion(PeriodicAveragesEntry(date: Date(), period: "24h", series: []))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PeriodicAveragesEntry>) -> Void) {
        if let data = WidgetStorage.loadPeriodicAveragesData() {
            let entry = PeriodicAveragesEntry(
                date: data.timestamp,
                period: data.period,
                series: data.series
            )
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            completion(timeline)
        } else {
            let entry = PeriodicAveragesEntry(date: Date(), period: "24h", series: [])
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            completion(timeline)
        }
    }
}

struct PeriodicAveragesEntry: TimelineEntry {
    let date: Date
    let period: String
    let series: [PeriodicAveragesWidgetData.SeriesData]
}
