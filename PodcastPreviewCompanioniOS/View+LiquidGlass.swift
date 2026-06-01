import SwiftUI
import PodcastPreviewShared

extension View {
    @ViewBuilder
    func glassAdaptive(cornerRadius: CGFloat) -> some View {
        self.background(
            GlassBackground(.panel, cornerRadius: cornerRadius, shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        )
    }
}
