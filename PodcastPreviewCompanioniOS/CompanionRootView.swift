import PodcastPreviewShared
import SwiftUI

struct CompanionRootView: View {
    @EnvironmentObject private var store: CloudKitCompanionStore

    var body: some View {
        ZStack {
            companionBackdrop
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider()

                if let message = store.lastErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "cloud")
                            .foregroundStyle(GraphiteSlateTheme.secondaryText)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(GraphiteSlateTheme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .graphiteSurface(.row, cornerRadius: 0)
                    .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: 0, style: .continuous)))
                    Divider()
                }

                Group {
                    if store.selectedMachineID == nil {
                        if store.machines.isEmpty {
                            emptyState
                        } else {
                            DeviceSelectionView()
                        }
                    } else if let currentSnapshot = store.selectedCurrentSnapshot,
                              let snapshot = store.selectedSnapshot {
                        HardwareStatsViewForiOS(
                            snapshot: snapshot,
                            currentSnapshot: currentSnapshot,
                            historyMirror: store.historyMirror
                        )
                    } else {
                        emptyState
                    }
                }
            }
        }
        .task {
            store.refresh()
            store.startAutoRefresh(every: 15)
        }
        .onDisappear {
            store.stopAutoRefresh()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hardware Companion")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(GraphiteSlateTheme.primaryText)
                Text("CloudKit snapshots from the source Mac")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
            }

            Spacer()

            if store.selectedMachineID != nil {
                Button {
                    store.selectedMachineID = nil
                } label: {
                    Text("Change")
                }
                .buttonStyle(.plain)
                .companionChromeButton(isAccent: false)
            }

            Button {
                store.refresh()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Text("Refresh")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .companionChromeButton(isAccent: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .graphiteSurface(.control, cornerRadius: 0)
        .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: 0, style: .continuous)))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(store.machines.isEmpty ? "Waiting for CloudKit snapshots" : "Machine found, but no live snapshot yet")
                .font(.headline)
                .foregroundStyle(GraphiteSlateTheme.primaryText)
            Text(
                store.machines.isEmpty
                ? "Launch the macOS companion on your Mac and enable iOS Companion Sync in the Remote Hardware tab."
                : "The source Mac is visible in CloudKit, but its live CurrentSnapshot record has not been published successfully yet."
            )
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(GraphiteSlateTheme.secondaryText)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var companionBackdrop: some View {
        ZStack {
            GraphiteSlateTheme.windowBase
            GraphiteSlateWindowOverlay()
        }
    }
}

private extension View {
    func companionChromeButton(isAccent: Bool = false, cornerRadius: CGFloat = 12) -> some View {
        let shape = ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface: GraphiteSlateSurface = isAccent ? .activeControl : .control
        let fill = GraphiteSlateTheme.fill(for: surface)
        let stroke = isAccent
            ? GraphiteSlateTheme.accentBlue.opacity(0.44)
            : GraphiteSlateTheme.stroke(for: .control)

        return self
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isAccent ? GraphiteSlateTheme.accentBlue : GraphiteSlateTheme.primaryText)
            .background(
                shape.fill(fill)
                    .overlay(shape.stroke(stroke, lineWidth: 1))
                    .overlay(CardBackgroundOverlay(shape: shape))
            )
    }
}
