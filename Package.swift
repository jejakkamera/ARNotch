// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ARNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ARNotch",
            path: "Sources/ARNotch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
