// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MagicMouseSwitchMacOS",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DeviceEnumerator", targets: ["DeviceEnumerator"]),
        .executable(name: "DeviceSelector", targets: ["DeviceSelector"]),
        .executable(name: "DeviceDisconnect", targets: ["DeviceDisconnect"]),
        .executable(name: "DeviceReconnect", targets: ["DeviceReconnect"]),
        .executable(name: "DeviceForget", targets: ["DeviceForget"]),
        .executable(name: "DevicePair", targets: ["DevicePair"]),
        .executable(name: "MagicMouseSwitchMac", targets: ["MagicMouseSwitchMac"])
    ],
    targets: [
        .target(
            name: "DeviceSelectionCore",
            path: "DeviceSelectionCore"
        ),
        .target(
            name: "MagicMouseSwitchServices",
            dependencies: ["DeviceSelectionCore"],
            path: "MagicMouseSwitchServices",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "DeviceEnumerator",
            path: "DeviceEnumerator",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "DeviceSelector",
            dependencies: ["DeviceSelectionCore"],
            path: "DeviceSelector",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "DeviceDisconnect",
            dependencies: ["DeviceSelectionCore"],
            path: "DeviceDisconnect",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "DeviceReconnect",
            dependencies: ["DeviceSelectionCore"],
            path: "DeviceReconnect",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "DeviceForget",
            dependencies: ["DeviceSelectionCore", "MagicMouseSwitchServices"],
            path: "DeviceForget",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "DevicePair",
            dependencies: ["DeviceSelectionCore", "MagicMouseSwitchServices"],
            path: "DevicePair",
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .executableTarget(
            name: "MagicMouseSwitchMac",
            dependencies: ["DeviceSelectionCore", "MagicMouseSwitchServices"],
            path: "MagicMouseSwitchMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        .testTarget(
            name: "DeviceSelectionCoreTests",
            dependencies: ["DeviceSelectionCore", "MagicMouseSwitchServices"],
            path: "DeviceSelectionCoreTests"
        )
    ]
)
