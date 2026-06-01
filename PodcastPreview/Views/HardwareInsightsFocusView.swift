import SwiftUI
import PodcastPreviewCore
import PodcastPreviewShared

struct HardwareInsightsFocusState: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let window: HardwareInsightWindow
    let isAIEnhancing: Bool
    let sessionStory: HardwareInsightsFocusStory?
    let rows: [HardwareInsightsFocusRow]
    let storyThreads: [String]

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(subtitle ?? "")
        hasher.combine(window.rawValue)
        hasher.combine(isAIEnhancing)
        if let sessionStory {
            hasher.combine(sessionStory.iconName)
            hasher.combine(sessionStory.headline)
            hasher.combine(sessionStory.detail)
        } else {
            hasher.combine("no-session-story")
        }
        for row in rows {
            hasher.combine(row.id)
            hasher.combine(row.title)
            hasher.combine(row.iconName)
            hasher.combine(row.coverageText)
            hasher.combine(row.headline)
            hasher.combine(row.detail)
            hasher.combine(row.isAIEnhanced)
            for stat in row.stats {
                hasher.combine(stat.id)
                hasher.combine(stat.label)
                hasher.combine(stat.value)
            }
            for fact in row.contextFacts {
                hasher.combine(fact)
            }
        }
        for thread in storyThreads {
            hasher.combine(thread)
        }
        return hasher.finalize()
    }
}

struct HardwareInsightsFocusStory {
    let iconName: String
    let accentColor: Color
    let headline: String
    let detail: String
}

struct HardwareInsightsFocusRow: Identifiable {
    let id: String
    let title: String
    let iconName: String
    let accentColor: Color
    let coverageText: String
    let headline: String
    let detail: String
    let isAIEnhanced: Bool
    let stats: [HardwareInsightsFocusStat]
    let contextFacts: [String]
}

struct HardwareInsightsFocusStat: Identifiable {
    let id: String
    let label: String
    let value: String

    init(label: String, value: String) {
        self.id = "\(label)-\(value)"
        self.label = label
        self.value = value
    }
}

struct HardwareInsightsFocusView: View {
    @Environment(\.appUIScale) private var appUIScale

    let focus: HardwareInsightsFocusState
    let onBack: () -> Void

    private var scaledOverlayHorizontalPadding: CGFloat { 40 * appUIScale }
    private var scaledOverlayVerticalPadding: CGFloat { 22 * appUIScale }
    private var scaledCardPadding: CGFloat { 16 * appUIScale }
    private var scaledSectionSpacing: CGFloat { 18 * appUIScale }
    private var scaledCardSpacing: CGFloat { 14 * appUIScale }
    private var scaledHeaderTitleSize: CGFloat { 21 * appUIScale }
    private var scaledSubtitleSize: CGFloat { 12.5 * appUIScale }
    private var scaledStoryTitleSize: CGFloat { 16 * appUIScale }
    private var scaledStoryBodySize: CGFloat { 13 * appUIScale }
    private var scaledBadgeSize: CGFloat { 11 * appUIScale }
    private var overlayCornerRadius: CGFloat { 22 * appUIScale }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(320, geometry.size.width - (scaledOverlayHorizontalPadding * 2))
            let availableHeight = max(320, geometry.size.height - (scaledOverlayVerticalPadding * 2))
            let railWidth = min(max(280 * appUIScale, availableWidth * 0.28), 360 * appUIScale)
            let overlayWidth = min(availableWidth, 1540 * appUIScale)
            let overlayHeight = min(availableHeight, 1040 * appUIScale)
            let contentWidth = overlayWidth - (scaledCardPadding * 2)
            let shellShape = ThemeRoundedRectangle(cornerRadius: overlayCornerRadius, style: .continuous)

            ZStack {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()

                GlassBackground(.hud, cornerRadius: overlayCornerRadius, shape: shellShape)
                    .overlay(
                        shellShape
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .frame(width: overlayWidth, height: overlayHeight)
                    .overlay(
                        VStack(alignment: .leading, spacing: scaledSectionSpacing) {
                            header

                            HStack(alignment: .top, spacing: scaledSectionSpacing) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: scaledSectionSpacing) {
                                        sessionStorySection
                                        insightGrid(availableWidth: contentWidth - railWidth - scaledSectionSpacing)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                                detailRail
                                    .frame(width: railWidth)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                        .padding(scaledCardPadding)
                    )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12 * appUIScale) {
            Button(action: onBack) {
                HStack(spacing: 5 * appUIScale) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: scaledSubtitleSize, weight: .semibold))
                    Text("Back")
                        .font(.system(size: scaledSubtitleSize, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.82))
                .padding(.horizontal, 10 * appUIScale)
                .padding(.vertical, 7 * appUIScale)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                Text(focus.title)
                    .font(.system(size: scaledHeaderTitleSize, weight: .semibold))
                Text(focus.subtitle ?? "Expanded insight narrative for the selected hardware history window")
                    .font(.system(size: scaledSubtitleSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8 * appUIScale) {
                if focus.isAIEnhancing {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(focus.window.shortLabel)
                    .font(.system(size: scaledBadgeSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                    .padding(.horizontal, 9 * appUIScale)
                    .padding(.vertical, 5 * appUIScale)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                Text("Insights View")
                    .font(.system(size: scaledBadgeSize, weight: .semibold))
                    .foregroundColor(Color(red: 0.88, green: 0.92, blue: 1.0).opacity(0.9))
                    .padding(.horizontal, 10 * appUIScale)
                    .padding(.vertical, 5 * appUIScale)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.25, green: 0.46, blue: 0.95).opacity(0.18))
                    )
            }
        }
    }

    @ViewBuilder
    private var sessionStorySection: some View {
        if let story = focus.sessionStory {
            roundedPanel {
                HStack(alignment: .top, spacing: 12 * appUIScale) {
                    ZStack {
                        Circle()
                            .fill(story.accentColor.opacity(0.18))
                        Image(systemName: story.iconName)
                            .font(.system(size: 17 * appUIScale, weight: .semibold))
                            .foregroundColor(story.accentColor)
                    }
                    .frame(width: 42 * appUIScale, height: 42 * appUIScale)

                    VStack(alignment: .leading, spacing: 5 * appUIScale) {
                        Text("Session Story")
                            .font(.system(size: scaledBadgeSize, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(story.headline)
                            .font(.system(size: scaledStoryTitleSize, weight: .semibold))
                        Text(story.detail)
                            .font(.system(size: scaledStoryBodySize, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func insightGrid(availableWidth: CGFloat) -> some View {
        let columns = [
            GridItem(.adaptive(minimum: max(280 * appUIScale, min(availableWidth, 340 * appUIScale))), spacing: scaledCardSpacing, alignment: .top)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: scaledCardSpacing) {
            ForEach(focus.rows) { row in
                roundedPanel {
                    VStack(alignment: .leading, spacing: 12 * appUIScale) {
                        HStack(alignment: .top, spacing: 10 * appUIScale) {
                            ZStack {
                                Circle()
                                    .fill(row.accentColor.opacity(0.18))
                                Image(systemName: row.iconName)
                                    .font(.system(size: 14 * appUIScale, weight: .semibold))
                                    .foregroundColor(row.accentColor)
                            }
                            .frame(width: 34 * appUIScale, height: 34 * appUIScale)

                            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                                HStack(alignment: .firstTextBaseline, spacing: 8 * appUIScale) {
                                    Text(row.title)
                                        .font(.system(size: scaledStoryTitleSize - 1, weight: .semibold))
                                    if row.isAIEnhanced {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: scaledBadgeSize, weight: .medium))
                                            .foregroundColor(.secondary.opacity(0.7))
                                    }
                                    Spacer(minLength: 6 * appUIScale)
                                    coverageBadge(text: row.coverageText)
                                }

                                Text(row.headline)
                                    .font(.system(size: scaledStoryBodySize, weight: .semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Text(row.detail)
                            .font(.system(size: scaledStoryBodySize, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !row.stats.isEmpty {
                            statsWrap(for: row)
                        }

                        if !row.contextFacts.isEmpty {
                            Divider()
                                .overlay(Color.white.opacity(0.06))

                            VStack(alignment: .leading, spacing: 7 * appUIScale) {
                                Text("Story Threads")
                                    .font(.system(size: scaledBadgeSize, weight: .semibold))
                                    .foregroundColor(.secondary)

                                ForEach(Array(row.contextFacts.prefix(6).enumerated()), id: \.offset) { _, fact in
                                    HStack(alignment: .top, spacing: 8 * appUIScale) {
                                        Circle()
                                            .fill(row.accentColor.opacity(0.88))
                                            .frame(width: 5 * appUIScale, height: 5 * appUIScale)
                                            .padding(.top, 6 * appUIScale)

                                        Text(fact)
                                            .font(.system(size: scaledSubtitleSize, weight: .regular))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var detailRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scaledCardSpacing) {
                roundedPanel {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        Text("Window")
                            .font(.system(size: scaledBadgeSize, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(focus.window.shortLabel)
                            .font(.system(size: scaledStoryTitleSize, weight: .semibold))
                        Text("This overlay expands every insight row at once so the session reads more like a coherent hardware story than a compact sidebar.")
                            .font(.system(size: scaledSubtitleSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !focus.storyThreads.isEmpty {
                    roundedPanel {
                        VStack(alignment: .leading, spacing: 10 * appUIScale) {
                            Text("Cross-System Threads")
                                .font(.system(size: scaledBadgeSize, weight: .semibold))
                                .foregroundColor(.secondary)

                            ForEach(Array(focus.storyThreads.prefix(10).enumerated()), id: \.offset) { _, fact in
                                HStack(alignment: .top, spacing: 8 * appUIScale) {
                                    ThemeRoundedRectangle(cornerRadius: 2 * appUIScale, style: .continuous)
                                        .fill(Color.white.opacity(0.30))
                                        .frame(width: 3 * appUIScale, height: 16 * appUIScale)
                                        .padding(.top, 2 * appUIScale)

                                    Text(fact)
                                        .font(.system(size: scaledSubtitleSize, weight: .regular))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                roundedPanel {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        Text("Coverage")
                            .font(.system(size: scaledBadgeSize, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("The focused view keeps each subsystem’s coverage badge visible so it’s obvious which storylines are fully observed and which ones are still warming up.")
                            .font(.system(size: scaledSubtitleSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func statsWrap(for row: HardwareInsightsFocusRow) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 86 * appUIScale), spacing: 8 * appUIScale)],
            alignment: .leading,
            spacing: 8 * appUIScale
        ) {
            ForEach(row.stats) { stat in
                VStack(alignment: .leading, spacing: 3 * appUIScale) {
                    Text(stat.label)
                        .font(.system(size: scaledBadgeSize - 0.5, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(stat.value)
                        .font(.system(size: scaledSubtitleSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9 * appUIScale)
                .padding(.vertical, 8 * appUIScale)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                        .fill(row.accentColor.opacity(0.12))
                )
            }
        }
    }

    private func roundedPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(14 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16 * appUIScale, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 16 * appUIScale, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func coverageBadge(text: String) -> some View {
        Text(text)
            .font(.system(size: scaledBadgeSize, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8 * appUIScale)
            .padding(.vertical, 4 * appUIScale)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }
}
