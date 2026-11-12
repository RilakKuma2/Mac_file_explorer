// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacExplorer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacExplorer", targets: ["MacExplorer"])
    ],
    targets: [
        .executableTarget(
            name: "MacExplorer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("Security"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "MacExplorerTests",
            dependencies: ["MacExplorer"]
        )
    ],
    swiftLanguageModes: [.v5]
)
