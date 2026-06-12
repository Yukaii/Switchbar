// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Switchbar",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Switchbar", targets: ["Switchbar"])
    ],
    targets: [
        .executableTarget(
            name: "Switchbar",
            path: "Sources/Switchbar"
        )
    ]
)
