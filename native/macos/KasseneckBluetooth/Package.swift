// swift-tools-version:5.9
// Bluetooth-Hilfsprogramm für Kasseneck Connect (macOS). Der Agent startet es als Kindprozess und spricht
// JSON-Zeilen über stdin/stdout (Protokoll: docs/bluetooth-protokoll.md im Repo).
import PackageDescription

let package = Package(
    name: "KasseneckBluetooth",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "kasseneck-bluetooth", targets: ["kasseneck-bluetooth"]),
    ],
    targets: [
        .target(name: "BluetoothCore"),
        .executableTarget(name: "kasseneck-bluetooth", dependencies: ["BluetoothCore"]),
        .testTarget(name: "BluetoothCoreTests", dependencies: ["BluetoothCore"]),
    ]
)
