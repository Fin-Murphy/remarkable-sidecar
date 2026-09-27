// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RM2Sidecar",
    platforms: [.macOS(.v14)],
    targets: [
        // Private CGVirtualDisplay declarations + zlib.
        .target(name: "CPrivate", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "RM2Sidecar", dependencies: ["CPrivate"]),
    ]
)
