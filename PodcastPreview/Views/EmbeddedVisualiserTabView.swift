import SwiftUI

#if INCLUDE_AUDIO_VISUALISER && canImport(AudioVisualiserConverterKit)
import AudioVisualiserConverterKit
#endif

struct EmbeddedVisualiserTabView: View {
    var body: some View {
        Group {
#if INCLUDE_AUDIO_VISUALISER && canImport(AudioVisualiserConverterKit)
            AudioVisualiserFrameworkView()
#else
            VStack(spacing: 10) {
                Text("Audio Visualiser")
                    .font(.title3.weight(.semibold))
                Text("This build does not include the optional Audio Visualiser integration.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
        }
    }
}
