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
        .executable(name: "ClipboardArchiveMenuBar", targets: ["ClipboardArchiveMenuBar"])
    ],
    targets: [
        .target(
            name: "ClipboardArchiveCore"
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
            dependencies: ["ClipboardArchiveCore"]
        )
    ]
)
