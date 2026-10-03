// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipboardArchive",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ClipboardArchiveCore", targets: ["ClipboardArchiveCore"]),
        .executable(name: "clipboard-archive", targets: ["clipboard-archive"]),
        .executable(name: "clipboard-archive-checks", targets: ["ClipboardArchiveChecks"]),
        .executable(name: "ClipboardArchiveMenuBar", targets: ["ClipboardArchiveMenuBar"]),
        .executable(name: "ClipboardArchiveUpdater", targets: ["ClipboardArchiveUpdater"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.3-RELEASE"
        ),
        // Linked by the update helper only. The app that reads the clipboard
        // never links it; scripts/check-local-only.sh enforces that split.
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.10.0"
        )
    ],
    targets: [
        .target(
            name: "ClipboardArchiveCore"
        ),
        // Pure decisions about updates, shared by the app and the helper.
        // No network, no Sparkle, no clipboard.
        .target(
            name: "ClipboardArchiveUpdateRules"
        ),
        .executableTarget(
            name: "clipboard-archive",
            dependencies: ["ClipboardArchiveCore"]
        ),
        .executableTarget(
            name: "ClipboardArchiveChecks",
            dependencies: ["ClipboardArchiveCore"]
        ),
        .executableTarget(
            name: "ClipboardArchiveMenuBar",
            dependencies: ["ClipboardArchiveCore", "ClipboardArchiveUpdateRules"]
        ),
        // The separate process that checks for, downloads and installs
        // updates. It must never depend on ClipboardArchiveCore.
        .executableTarget(
            name: "ClipboardArchiveUpdater",
            dependencies: [
                "ClipboardArchiveUpdateRules",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "ClipboardArchiveCoreTests",
            dependencies: [
                "ClipboardArchiveCore",
                "ClipboardArchiveUpdateRules",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
