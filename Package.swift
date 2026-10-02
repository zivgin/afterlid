// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Afterlid",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Afterlid",
            path: "Sources/Afterlid",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]
        )
    ]
)
