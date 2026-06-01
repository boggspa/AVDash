import Foundation
import CoreGraphics

public struct AVCMeterConfiguration: Sendable {
    public enum ThemeMode: Sendable, Equatable {
        /// Preserve AVCMeter's standalone glass/chrome behavior.
        case native
        /// Blend into the host app's chrome with a neutral graphite palette.
        case mapped
    }

    public var themeMode: ThemeMode
    public var minimumWindowSize: CGSize

    public init(
        themeMode: ThemeMode = .native,
        minimumWindowSize: CGSize = CGSize(width: 720, height: 1100)
    ) {
        self.themeMode = themeMode
        self.minimumWindowSize = minimumWindowSize
    }
}
