// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PodcastPreviewShared",
    platforms: [.iOS(.v17), .macOS(.v11)],
    products: [
        .library(name: "PodcastPreviewShared", targets: ["PodcastPreviewShared"]),
    ],
    targets: [
        .target(name: "PodcastPreviewShared", dependencies: []),
    ]
)
