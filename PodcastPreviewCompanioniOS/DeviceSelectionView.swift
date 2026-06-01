import PodcastPreviewShared
import SwiftUI

struct DeviceSelectionView: View {
    @EnvironmentObject private var store: CloudKitCompanionStore
    @State private var selectedMachineID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select a Mac")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(GraphiteSlateTheme.primaryText)
                Text("Choose a CloudKit source Mac to mirror in the companion dashboard.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)

            if store.isLoading {
                loadingState
            } else if store.machines.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(store.machines) { machine in
                            MachineCard(
                                machine: machine,
                                isSelected: selectedMachineID == machine.machineID
                            ) {
                                selectedMachineID = machine.machineID
                                store.selectMachine(machine.machineID)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading CloudKit machines...")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(GraphiteSlateTheme.primaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud")
                .font(.system(size: 48))
                .foregroundStyle(GraphiteSlateTheme.secondaryText)

            Text("No Macs Found")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GraphiteSlateTheme.primaryText)

            Text("Launch the macOS companion on your Mac and enable iOS Companion Sync in the Remote Hardware tab.")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(GraphiteSlateTheme.secondaryText)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct MachineCard: View {
    let machine: CompanionMachineIdentity
    let isSelected: Bool
    let onSelect: () -> Void
    private let cardShape = ThemeRoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(machine.displayName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(GraphiteSlateTheme.primaryText)

                    HStack(spacing: 8) {
                        Text(machine.chipType ?? machine.modelIdentifier)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(GraphiteSlateTheme.secondaryText)

                        if let macOSVersion = machine.macOSVersion {
                            Text("•")
                                .foregroundStyle(GraphiteSlateTheme.subduedText)
                            Text(macOSVersion)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(GraphiteSlateTheme.secondaryText)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(GraphiteSlateTheme.accentBlue)
                        .font(.title2)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(GraphiteSlateTheme.subduedText)
                        .font(.title3)
                }
            }
            .padding(16)
            .graphiteSurfaceWithRim(isSelected ? .selectedRow : .row, cornerRadius: 18)
            .overlay {
                if isSelected {
                    cardShape
                        .strokeBorder(GraphiteSlateTheme.accentBlue.opacity(0.35), lineWidth: 1)
                }
            }
            .shadow(color: GraphiteSlateTheme.shadow, radius: isSelected ? 14 : 8, x: 0, y: isSelected ? 8 : 4)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func graphiteSurfaceWithRim(
        _ surface: GraphiteSlateSurface,
        cornerRadius: CGFloat = 12,
        stroke: Color? = nil
    ) -> some View {
        self
            .graphiteSurface(surface, cornerRadius: cornerRadius, stroke: stroke)
            .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}
