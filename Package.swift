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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "MacExplorer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("QuickLookUI"),
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
