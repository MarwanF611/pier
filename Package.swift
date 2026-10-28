// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Pier",
    platforms: [.macOS(.v26)],
    targets: [
        // Thin C shim over the IOHID event system, which is where Apple Silicon
        // exposes its die temperature sensors.
        .target(
            name: "CSensors",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "Pier",
            dependencies: ["CSensors"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Vision"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
