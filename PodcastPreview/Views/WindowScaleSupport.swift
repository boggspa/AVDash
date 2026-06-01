import SwiftUI
import AppKit

private struct AppUIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var appUIScale: CGFloat {
        get { self[AppUIScaleKey.self] }
        set { self[AppUIScaleKey.self] = newValue }
    }
}

struct WindowScaleConfiguration: Equatable {
    let referenceSize: CGSize
    let minScale: CGFloat
    let maxScale: CGFloat
    let epsilon: CGFloat

    static let mainWindow = WindowScaleConfiguration(
        // Reference width chosen to sit at scale 1.0 for a comfortable mid-size window.
        // Height is unused by the main-window formula but kept for floatingPanel parity.
        referenceSize: CGSize(width: 1920, height: 2160),
        minScale: 0.72,
        maxScale: 1.35,
        epsilon: 0.005
    )

    static func floatingPanel(referenceSize: CGSize) -> WindowScaleConfiguration {
        WindowScaleConfiguration(
            referenceSize: referenceSize,
            minScale: 0.72,
            maxScale: 1.32,
            epsilon: 0.002
        )
    }
}

struct WindowScaleObserver: NSViewRepresentable {
    let configuration: WindowScaleConfiguration
    let onScaleChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.configuration = configuration
        view.onScaleChange = onScaleChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let observerView = nsView as? ObserverView else { return }
        observerView.configuration = configuration
        observerView.onScaleChange = onScaleChange
        observerView.updateScale()
    }

    private final class ObserverView: NSView {
        var configuration: WindowScaleConfiguration = .mainWindow
        var onScaleChange: ((CGFloat) -> Void)?
        private var didInstallObservers = false
        private var lastScale: CGFloat = -1

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObserversIfNeeded()
            updateScale()
        }

        private func installObserversIfNeeded() {
            guard !didInstallObservers, let window else { return }
            didInstallObservers = true

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification,
                object: window
            )
        }

        @objc private func windowDidResize() {
            updateScale()
        }

        func updateScale() {
            let contentRect = window?.contentLayoutRect ?? window?.contentView?.bounds ?? bounds
            let width = max(contentRect.width, 1)

            // Width-only scaling: vertical layout scrolls naturally so height
            // should never penalise the scale.
            //
            // √ smoothing (power 0.5) makes the curve organic rather than
            // mechanical — a window that is 4× wider only produces 2× scale,
            // so resizing never causes sudden layout lurches.
            //
            //  640 px  →  √(640/920)  ≈ 0.83
            //  920 px  →  √(920/920)  = 1.00  ← neutral point
            // 1200 px  →  √(1200/920) ≈ 1.14
            // 1800 px  →  √(1800/920) ≈ 1.40 → capped at maxScale
            let rawRatio = width / max(configuration.referenceSize.width, 1)
            let scale = min(
                max(sqrt(rawRatio), configuration.minScale),
                configuration.maxScale
            )

            guard abs(scale - lastScale) > configuration.epsilon else { return }
            lastScale = scale
            onScaleChange?(scale)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

struct WindowScaledRootView<Content: View>: View {
    @State private var appUIScale: CGFloat = 1.0
    let configuration: WindowScaleConfiguration
    @ViewBuilder let content: () -> Content

    init(
        configuration: WindowScaleConfiguration = .mainWindow,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.configuration = configuration
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.appUIScale, appUIScale)
            .background(
                WindowScaleObserver(configuration: configuration) { newScale in
                    guard newScale != appUIScale else { return }
                    DispatchQueue.main.async {
                        withAnimation(.none) {
                            appUIScale = newScale
                        }
                    }
                }
                .frame(width: 0, height: 0)
            )
    }
}
